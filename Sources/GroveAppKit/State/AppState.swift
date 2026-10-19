// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import SwiftUI
import AppKit
import GroveCore

/// A project's views: Workspaces · Graph · Stats. What its Claude tab did — every session
/// with its actions — is on each session's own menu, wherever the session is listed.
public enum MainTab: String, CaseIterable {
    case workspaces
    case graph
    case stats

    public var label: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .graph: return "Graph"
        case .stats: return "Stats"
        }
    }
}

/// Single observable source of truth for the app. Owns the config (loaded via
/// ConfigStore), per-project scan snapshots, selection, and every user action.
/// Action methods never throw into views: failures land in `actionError`.
@MainActor
public final class AppState: ObservableObject {
    @Published public var config: GroveConfig
    @Published public var configIssue: String?
    @Published public var snapshots: [UUID: ProjectSnapshot] = [:]
    /// Per-account statusline captures (model, context %, effort, cost per session),
    /// filled by refreshUsage on the scan tick. Empty until the first refresh.
    @Published public var snapshotsByAccount: [String: [UsageSnapshot]] = [:]
    /// Per-account identity (email/org/tier), resolved OFF the main actor in
    /// refreshUsage: what `reconcileAccountNames` names accounts by. Empty until the
    /// first refresh.
    var identityByAccount: [String: AccountIdentity] = [:]
    /// Per-project recent Claude sessions (item 4): the Projects tab's previews.
    /// Filled by refreshSessionIndex (cheap, off-main — no git scan).
    @Published public var recentSessionsByProject: [UUID: [ProjectSessionRow]] = [:]
    /// Disk-wide recent sessions (Phase 2 / Task 2) attributed to a configured
    /// project by cwd prefix match. Keyed by ProjectConfig.id, newest-first.
    /// Populated by refreshSessionIndex alongside recentSessionsByProject.
    @Published public var externalSessionsByProject: [UUID: [ClaudeSession]] = [:]
    /// Disk-wide recent sessions whose cwd matches NO configured project.
    /// Newest-first. Populated by refreshSessionIndex.
    @Published public var otherSessions: [ClaudeSession] = []
    /// When non-nil, the launch sheet is presented to configure a Resume/New launch
    /// (open-target, account, model, effort) before it runs.
    @Published public var launchRequest: LaunchRequest?
    @Published public var selectedProjectID: UUID?
    @Published public var selectedTab: MainTab = .workspaces
    /// The panel's current full-screen state. Mutate via open()/goBack() so
    /// the transition direction and per-route side effects stay consistent.
    @Published public var route: Route = .projects
    /// Pending prefill for the createWorkspace route; producers set it right
    /// before open(.createWorkspace(id)), goBack() consumes it.
    @Published public var createPrefill: CreatePrefill?
    /// Direction of the LAST route change (push = forward, pop = backward),
    /// derived from route depth. Drives RootView's transition edges. Not
    /// @Published: it always changes together with `route`.
    public private(set) var routeIsForward = true
    /// The scan spawned by the last open(.project(id)); tests await it.
    internal var refreshTask: Task<Void, Never>?
    @Published public var searchQuery: String = ""
    /// True only while the screens are actually looked at: Brow's Projects section, in
    /// view for a quarter of a second. RootView's 15s refresh loop is keyed on it so the
    /// loop never runs while they are not (or in a headless render/test) — which would
    /// otherwise spin forever parsing real transcripts (the notch keeps its sections in
    /// the tree while it is closed, so their .task is not cancelled by the close).
    @Published public var isPanelOpen: Bool = false
    @Published public var isScanning: Bool = false
    @Published public var actionError: String?
    @Published public var graphRepoPath: String?
    @Published public var graphNodes: [CommitNode] = []
    /// True when the last graph page came back full — drives the "Load more" row.
    @Published public var graphCanLoadMore: Bool = false
    /// The commit whose file changes are expanded inline, and the lazily-loaded
    /// list (nil while loading). Tapping the same commit collapses it.
    @Published public var expandedCommit: String?
    @Published public var expandedCommitFiles: [CommitFileChange]?
    /// Local branch names per repo (key = repo.path), filled by loadBranches.
    /// Branch pickers fall back to the resolved default while a repo is absent.
    @Published public var branchesByRepo: [String: [String]] = [:]
    /// Stats-tab per-repo branch override (key = repo.path → chosen branch). Repo paths
    /// are unique across projects, so a flat dict is fine. Empty ⇒ each repo uses its
    /// auto-detected default. Fed into GitStatsService.scan as `branchOverrides`; an
    /// override that no longer names a real branch is silently ignored by the engine.
    @Published public var selectedStatsBranchByRepo: [String: String] = [:]

    /// Per-project code-stats snapshot (Stage 4), filled lazily by refreshCodeStats
    /// from the stats screen's .task (NOT the global refresh). Empty until scanned.
    @Published public var codeStats: [UUID: CodeStats] = [:]
    /// Per-project code-stats history (the "lines over time" series). Now GIT-derived:
    /// `refreshCodeStats` OVERWRITES it each scan with the per-day cumulative net-lines
    /// series summed across the project's repos (no longer an append-only snapshot log).
    @Published public var codeStatsHistory: [UUID: [CodeStatsPoint]] = [:]
    /// Per-project per-repo breakdown (current LOC + history + delta per repo), produced
    /// alongside the aggregate by GitStatsService. Published for a LATER per-repo UI pass;
    /// the current screen reads only `codeStats`/`codeStatsHistory`.
    @Published public var repoStats: [UUID: [RepoStats]] = [:]
    /// Per-project per-file list (project-root-relative path + classified line total +
    /// language), produced by the same scan that fills `codeStats`. Feeds the stats
    /// settings page's directory+file tree; honors the folder/.ignorestats exclusions.
    @Published public var statsFiles: [UUID: [StatFileEntry]] = [:]
    /// True only while a code-stats scan is in flight (drives the screen's spinner).
    @Published public var isStatsScanning: Bool = false

    /// How long Claude Code keeps each account's transcripts (`ClaudeRetention`), by
    /// account name — the strictest of the account's folders. The safety net never keeps
    /// or restores anything older; Settings shows it. Filled by `reconcileTranscripts`.
    @Published public var transcriptRetention: [String: ClaudeRetention.Resolution] = [:]
    /// Transcripts gone from Claude Code's folders that the safety net could put back:
    /// inside every retention that applies to them. Nothing comes back by itself — a
    /// period passed to `claude` with `--settings` can't be seen from here — so Settings
    /// lists them, newest first, each with Restore. Filled by `reconcileTranscripts`;
    /// empty while the safety net is off.
    @Published public var restorableTranscripts: [RestorableTranscript] = []

    private let configStore: ConfigStore

    /// Persistent service instance. Its mtime parse-cache MUST survive across
    /// scans/refreshes — a fresh `ClaudeService()` per tick re-parsed every transcript
    /// from scratch on the 15s loop (item 2 perf bug).
    private let claude = ClaudeService()

    /// Git-as-source-of-truth code-stats service (per-repo, honors .gitignore via git's
    /// own engine, excludes worktrees). Stateless value type; the per-project/per-repo
    /// file cache below survives across refreshes so steady-state scans only re-read
    /// changed files. Replaces the old filesystem-walk scanner for the stats numbers.
    private let gitStats = GitStatsService()
    /// Retained ONLY for `statsDirectoryTree` (the folder-exclusion picker still walks
    /// the directory skeleton via this; its `scan` is no longer used for the numbers).
    private let statsScanner = CodeStatsScanner()
    /// Per-project git-stats file cache, keyed by project UUID then repo path. Mutated
    /// only on the main actor (the detached scan takes a COPY of the relevant project's
    /// cache and returns the updated one — same pattern as refreshUsage's off-main work).
    private var gitStatsCacheByProject: [UUID: [String: RepoFileCache]] = [:]
    /// Per-project scan serialization. Two scans of the SAME project must never run
    /// concurrently: both would start from the same cache snapshot and the slower one
    /// would overwrite the faster's cache on completion, silently dropping mtime
    /// entries (so the next scan needlessly re-reads those files). A project in
    /// `statsScanInFlight` has a scan running; a refresh requested meanwhile records
    /// `statsRescanPending` and is honored once the in-flight scan settles.
    private var statsScanInFlight: Set<UUID> = []
    private var statsRescanPending: Set<UUID> = []
    /// In-flight debounce task for `setStatsBranch` — cancelled and rescheduled on each
    /// rapid branch pick so N quick switches coalesce to one rescan.
    private var statsBranchDebounce: Task<Void, Never>?

    /// Debounce interval (seconds) for branch-switch rescans. Default 0.25s in production;
    /// tests set this to 0 so the debounce fires synchronously and the coalesce assertion
    /// is deterministic without artificial sleeps.
    internal var statsBranchDebounceInterval: TimeInterval = 0.25

    /// Test seam: when set, every cmux interaction uses this service instead of
    /// a real `CmuxService()` (which would resolve and invoke the real cmux
    /// binary). Internal so GroveAppKitTests can inject via @testable import.
    internal var cmuxOverride: CmuxService?
    /// Test seam for CmuxService.claudeSessionWorkspaceMap(hookFile:); nil
    /// means the real ~/.cmuxterm/claude-hook-sessions.json.
    internal var cmuxHookFile: String?
    /// Graph page size (spec §6.2: 300). Internal so tests can page through a
    /// tiny fixture repo instead of building 300+ commits.
    internal var graphPageSize = 300

    /// Every folder the engine reads or writes outside a project: Grove's config, the
    /// status-line wrappers, the code statistics, the accounts root, the canonical
    /// (default) account and the home folder that holds its `.claude.json`. Injected
    /// at construction. A config file that is not the real one gets folders BESIDE it
    /// (`WorkspacesFolders.beside`), so a test or an offscreen render can never write
    /// into the user's own `~/.claude` or `~/Library/Application Support/Grove`.
    /// Tests may change single fields afterwards.
    public internal(set) var folders: WorkspacesFolders

    /// Test seam: the pid-liveness predicate used by the concurrency guard. nil
    /// means the real check (the pid runs and started when its record says). Tests
    /// set { _ in true } so a fixture sessions/<pid>.json counts as live.
    internal var liveProcessValidatorOverride: ((Int32) -> Bool)?

    /// Test seam: injects a fixed live-process list into the guards of Share and Resume
    /// as… (`adoptSession`, `sessionLiveUnderOtherAccount`), bypassing the records and
    /// the host's processes. nil means the real `allLiveProcesses` call.
    internal var allLiveProcessesOverride: [LiveProcess]?

    /// Whether the engine installs the status-line wrapper into an account's
    /// `settings.json` without being asked: at launch for every account not yet
    /// monitored, and as a side effect of adding, linking or migrating into an account.
    /// Grove.app did. Off unless a host turns it on, and Brow never does: capture is
    /// turned on per account in Settings, or kept where Grove already had it on — so a
    /// user's Claude Code files are edited only when they asked for it, whichever app
    /// hosts the engine.
    public var capturesByDefault = false

    /// Asked before the engine writes Grove's `config.json` or the transcript safety net;
    /// false refuses the write. A host that knows of another engine writing the same
    /// files — Grove.app, still running — says no until that has stopped.
    public var mayWrite: (() -> Bool)?

    /// Opens the host's Settings window where the panel cannot hold the settings:
    /// Workspaces' own, or an account's.
    public var openSettings: ((WorkspacesSettingsLink) -> Void)?

    /// Each account's 5-hour and weekly use, from the host (Brow's limits store), for
    /// the account pickers. nil: no numbers, just names.
    public weak var limitsProvider: AccountLimitsProviding?

    /// The host's accounts — Brow's, in Brow's order, with Brow's names, plans and colours,
    /// hidden ones left out — which every account picker lists (`accounts`). nil without a
    /// host: Grove's own config.
    @Published public var hostAccounts: [HostAccount]?
    /// The environment a launch as the account in `configDir` (expanded) starts with: the
    /// host's own, so a session launched here runs as the account it says (Brow: `env -u
    /// CLAUDE_CONFIG_DIR` for `~/.claude`, `CLAUDE_CONFIG_DIR=…` for the others, and its
    /// browser router). nil: GroveCore's.
    public var launchEnvironment: ((String) -> String)?
    /// Told when an action hands the user to something else — a terminal, cmux, Finder — so
    /// a host that shows these screens in a panel can close it.
    public var onHandOff: (() -> Void)?
    /// When the last full `refresh()` finished; nil before the first.
    @Published public internal(set) var lastRefreshAt: Date?
    /// The screen the launch form was opened from, and goes back to.
    public internal(set) var launchOrigin: Route?
    /// The session the keyboard is on in the Projects list (its row id); nil until ↑ or ↓
    /// is pressed: the focus ring shows only once the keyboard drives.
    @Published public var keyboardFocus: String?
    /// Runs the host's folder picker for "Add a folder…"; nil: an open panel of its own.
    public var addFolder: (() -> Void)?
    /// The screen in front cannot be left now: a workspace is being created, and leaving would
    /// lose its log. Esc and ‹ wait (`goBackForKey`).
    @Published public var blocksBack = false
    /// The session whose row asks "Delete this transcript?" in place of its buttons; nil for
    /// none. One at a time, and Esc answers Cancel.
    @Published public var confirmingDelete: String?

    /// What the host last read for `account`, by its config folders.
    public func limits(for account: AccountConfig) -> AccountLimits? {
        limitsProvider?.limits(forConfigDirs: account.allConfigDirs.map(expandTilde))
    }

    /// What the account is called wherever Workspaces shows it — pickers, session rows,
    /// the Accounts screen: the host's name for it, the one the notch shows, else the name
    /// in Grove's config (its email, as the engine names accounts). The config name stays
    /// the account's key; only what is shown follows the host. A second account the host
    /// names the same keeps its config name (`AccountLimitsProviding.displayName`).
    public func displayName(for account: AccountConfig) -> String {
        limitsProvider?.displayName(for: account, among: config.accounts) ?? account.name
    }

    /// The same for a session's or a row's account, which they carry by its config name.
    public func displayName(forAccountNamed name: String) -> String {
        config.accounts.first { $0.name == name }.map(displayName(for:)) ?? name
    }

    /// The account's plan as the host shows it ("Max 20x"); nil when it does not know.
    public func plan(for account: AccountConfig) -> String? {
        limitsProvider?.label(forConfigDirs: account.allConfigDirs.map(expandTilde))?.plan
    }

    /// An account as the pickers list it: "Resume as Work — 5h 42% · week 61%". The
    /// numbers are what Brow says about room; the menu is where the work moves.
    public func menuTitle(_ verb: String, _ account: AccountConfig) -> String {
        let name = displayName(for: account)
        let base = verb.isEmpty ? name : "\(verb) \(name)"
        guard let label = limits(for: account)?.label else { return base }
        return "\(base) — \(label)"
    }

    /// Test observability: incremented each time `runCodeStatsScan` begins a scan. nil
    /// in production (never read); tests set it to 0 before calling `setStatsBranch`
    /// and assert it equals 1 after the debounce fires to verify coalescing.
    internal var statsRescanStartedCount: Int?

    /// `folders` defaults to folders beside the config file — see `folders`.
    public init(configStore: ConfigStore, folders: WorkspacesFolders? = nil) {
        self.configStore = configStore
        self.folders = folders ?? .beside(configFile: configStore.url)
        let loaded = configStore.load()
        self.config = loaded.config
        self.configIssue = loaded.issue
        self.selectedProjectID = loaded.config.projects.first?.id
    }

    /// The real folders: ~/Library/Application Support/Grove/config.json and Claude
    /// Code's folders in the user's home.
    public convenience init(folders: WorkspacesFolders = .live()) {
        self.init(configStore: ConfigStore(url: folders.configFile), folders: folders)
    }

    // MARK: - Navigation (panel state machine)

    /// Navigates the panel. Pushes vs pops are classified by route depth
    /// (deeper-or-equal = forward). Opening a project selects it and kicks
    /// off a scan so the workspace tree is fresh by the time it settles.
    public func open(_ target: Route) {
        routeIsForward = target.depth >= route.depth
        if case .project(let id) = target {
            if id != selectedProjectID { resetGraph() }
            selectedProjectID = id
            refreshTask = Task { await self.refresh() }
        }
        // INSTANT route change — no withAnimation. Animating the route swap made
        // Apple's Liquid Glass framework (DesignLibrary / MaterialProviderBox) recurse
        // to a stack-overflow SIGSEGV while it re-resolved the glass layers of the
        // animated SwiftUI content INSIDE the window's NSGlassEffectView (introduced by
        // the one-window merge). A non-animated swap renders once and never re-enters
        // that resolution mid-interpolation. Brow's notch has no glass: there RootView
        // slides the screens itself (`groveHost`).
        route = target
    }

    /// Pops along Route.backRoute. Leaving createWorkspace consumes the
    /// pending prefill so a later visit never reuses stale form state.
    public func goBack() {
        if case .createWorkspace = route { createPrefill = nil }
        if route == .launch {
            cancelLaunch()
            return
        }
        open(route.backRoute)
    }

    // MARK: - Selection

    public var selectedProject: ProjectConfig? {
        config.projects.first { $0.id == selectedProjectID }
    }

    public var selectedSnapshot: ProjectSnapshot? {
        selectedProjectID.flatMap { snapshots[$0] }
    }

    /// Account a single-click "New session" launches on (spec §6.1): the selected
    /// project's defaultAccount when it is one the pickers offer, else the first of them
    /// (`accounts`: the host's, in its order).
    public var defaultLaunchAccount: AccountConfig? {
        let offered = accounts.map(\.config)
        if let name = selectedProject?.defaultAccount,
           let account = offered.first(where: { $0.name == name }) {
            return account
        }
        return offered.first ?? config.accounts.first
    }

    /// Runs one of the actions below for a window of the host's own — Brow's Settings —
    /// and returns what went wrong, if anything. The failure is shown next to the control
    /// that caused it, where the user is looking; the panel's banner, which they are not,
    /// is left as it was.
    @discardableResult
    public func attempt(_ action: () -> Void) -> String? {
        let shown = actionError
        actionError = nil
        action()
        let failure = actionError
        actionError = shown
        return failure
    }

    // MARK: - Persistence

    func persist() {
        guard mayPersist() else { return }
        do {
            try configStore.save(config)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Whether the config may be saved now (`mayWrite`); when not, says why in
    /// `actionError` (`reporting`). Asked first by an action that edits another file
    /// before it saves the config — an account's settings.json, its session folders — so
    /// a save refused at the end never leaves half the change made.
    private func mayPersist(reporting: Bool = true) -> Bool {
        guard let mayWrite, !mayWrite() else { return true }
        if reporting {
            actionError = "Not saved: Grove.app is running and writes the same settings. Quit Grove, then make the change again."
        }
        return false
    }

    // MARK: - Config CRUD

    /// Adds a project named after the path's leaf directory, saves and selects it.
    public func addProject(at path: String) {
        let expanded = expandTilde(path)
        let name = (expanded as NSString).lastPathComponent
        let project = ProjectConfig(name: name, path: expanded)
        config.projects.append(project)
        selectedProjectID = project.id
        persist()
    }

    public func removeProject(id: UUID) {
        config.projects.removeAll { $0.id == id }
        snapshots.removeValue(forKey: id)
        // Drop all per-project code-stats state and delete its history file so a
        // re-added project at the same path starts clean (the UUID differs anyway).
        // Clear any stats-branch overrides for this project's repos before dropping
        // repoStats (the only place that maps the project → its repo paths).
        for repo in repoStats[id] ?? [] {
            selectedStatsBranchByRepo.removeValue(forKey: repo.repoPath)
        }
        codeStats.removeValue(forKey: id)
        codeStatsHistory.removeValue(forKey: id)
        repoStats.removeValue(forKey: id)
        gitStatsCacheByProject.removeValue(forKey: id)
        statsStore.delete(projectID: id)
        if selectedProjectID == id {
            selectedProjectID = config.projects.first?.id
            resetGraph()
        }
        persist()
    }

    /// Replaces the project with the same id; unknown ids are ignored.
    public func updateProject(_ p: ProjectConfig) {
        guard let index = config.projects.firstIndex(where: { $0.id == p.id }) else { return }
        config.projects[index] = p
        persist()
    }

    /// Global settings edit (GlobalSettingsScreen); persists like every other config mutation.
    public func setWorkspacesRootTemplate(_ template: String) {
        config.workspacesRootTemplate = template
        persist()
    }

    /// Transcript safety-net settings edit (GlobalSettingsScreen); persists immediately.
    public func setTranscriptMirror(_ settings: TranscriptMirrorSettings) {
        config.transcriptMirror = settings
        persist()
    }

    /// New account convention (spec §6.3): configDir = ~/.claude-accounts/<name>
    /// (`folders.accountsRoot`). Phase 5A: also creates the
    /// dir and auto-installs the grove statusline there so the account captures usage
    /// from its first session (best-effort — account creation still succeeds if the
    /// install fails).
    public func addAccount(name: String) {
        guard !config.accounts.contains(where: { $0.name == name }) else {
            actionError = "account '\(name)' already exists"
            return
        }
        let account = AccountConfig(name: name, configDir: folders.storedAccountDir(name))
        config.accounts.append(account)
        persist()
        if capturesByDefault { enableMonitoring(account, reportErrors: false) }
    }

    /// Names every account by the login Claude Code knows it by — the email in its
    /// `.claude.json` — once identities have been read (`refreshUsage`). Runs at
    /// launch; a rename moves the project default-account references with it.
    /// Returns whether anything changed, so the caller can re-read captures under
    /// the new keys.
    @discardableResult
    public func reconcileAccountNames() -> Bool {
        let emails = identityByAccount.compactMapValues(\.email)
        // Same login in two folders is one account: the folder Claude Code used most
        // recently launches it, the other is read for its sessions.
        var activity: [String: Date] = [:]
        for account in config.accounts {
            activity[account.name] = (try? FileManager.default.attributesOfItem(atPath: claudeJSONPath(for: account)))?[.modificationDate] as? Date
        }
        let merge = AccountNaming.merged(accounts: config.accounts, emailByName: emails, activityByName: activity)
        var next = config
        next.accounts = merge.accounts
        next = next.renamingAccounts(merge.renames)
        let renames = AccountNaming.renames(accounts: next.accounts, emailByName: emails)
        next = next.renamingAccounts(renames)
        guard next != config else { return false }
        config = next
        persist()
        for (old, new) in merge.renames.merging(renames, uniquingKeysWith: { $1 }).sorted(by: { $0.key < $1.key }) {
            GroveLog.perf.info("account \(old, privacy: .public) → \(new, privacy: .public)")
        }
        return true
    }

    /// Adds every folder under the accounts root (`~/.claude-accounts`) that is
    /// signed in and unknown to Grove — the folders Brow's one-click sign-in
    /// creates — named by its email. Returns whether anything was added.
    @discardableResult
    public func discoverAccountDirs() -> Bool {
        let root = folders.accountsRoot
        let fm = FileManager.default
        let known = Set(config.accounts.flatMap(\.allConfigDirs).map(expandTilde))
        // A folder signed in to a login Grove already lists joins that account as an alias.
        var emailOfAccount: [String: String] = [:]
        for account in config.accounts {
            if let email = ClaudeService.identity(claudeJSONPath: claudeJSONPath(for: account))?.email {
                emailOfAccount[account.name] = email
            }
        }
        var added = false
        for folder in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !folder.hasPrefix(".") {
            let path = root + "/" + folder
            var isDir: ObjCBool = false
            guard !known.contains(path), fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  let email = ClaudeService.identity(claudeJSONPath: path + "/.claude.json")?.email
            else { continue }
            let stored = folders.storedAccountDir(folder)
            if let i = config.accounts.firstIndex(where: { emailOfAccount[$0.name] == email }) {
                config.accounts[i].aliasDirs.append(stored)
            } else {
                let name = AccountNaming.uniqueName(email: email, folder: folder, taken: Set(config.accounts.map(\.name)))
                config.accounts.append(AccountConfig(name: name, configDir: stored))
                emailOfAccount[name] = email
            }
            added = true
        }
        if added { persist() }
        return added
    }

    /// Brow's per-account browser router: `claude auth login` from a session the engine
    /// launched then opens that account's own browser profile. The host sets the one in
    /// its own bundle; without a host, the installed Brow.app's. nil = no router.
    public var browserRouter: String? = AppState.locateBrowserRouter()

    /// The `claude` sessions launch with: the host's Path to claude (Settings › General,
    /// or what it detected). nil, or a closure answering nil, leaves it to the engine's
    /// own guesses (`ClaudeService.claudeExecutable()`).
    public var claudePath: (() -> String?)?

    /// The host's look at the Claude Code processes that run, from the kernel (Brow's
    /// `ProcessTable`): the sessions that keep no record of their own, and the folders
    /// offered as projects. nil — a window of its own, a test — leaves the sessions' own
    /// records to say what runs, and suggests nothing. The engine never reads another
    /// process itself.
    public var runningClaude: (@Sendable () -> [RunningClaude])? {
        didSet { claude.runningProcesses = runningClaude }
    }

    static func locateBrowserRouter() -> String? {
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.artemefimov.brow")?.path,
                          "/Applications/Brow.app"].compactMap { $0 }
        for app in candidates {
            let router = app + "/Contents/Resources/brow-browser"
            if FileManager.default.isExecutableFile(atPath: router) { return router }
        }
        return nil
    }

    /// Removes the account from Workspaces' config only — the directory is untouched —
    /// and from the projects that launched on it by default, which fall back to the first
    /// account. What Settings offers for an account whose folder is gone.
    public func removeAccount(name: String) {
        config.accounts.removeAll { $0.name == name }
        for i in config.projects.indices where config.projects[i].defaultAccount == name {
            config.projects[i].defaultAccount = nil
        }
        persist()
    }
}

// MARK: - Services & scanning

extension AppState {
    private func cmux() -> CmuxService {
        cmuxOverride ?? CmuxService()
    }

    /// Built fresh from the CURRENT config so edits (accounts, overrides, hooks)
    /// take effect on the next scan/creation without restarting. Reuses the
    /// persistent `claude` so its transcript parse-cache survives across scans.
    public var workspaceService: WorkspaceService {
        WorkspaceService(git: GitService(), claude: claude, cmux: cmux(), config: config)
    }

    /// Scans the selected project; no-op when nothing is selected. scan() itself
    /// never throws (per-repo/cmux failures degrade into snapshot.errors).
    ///
    /// Usage refresh (account-wide, independent of selection) runs CONCURRENTLY
    /// with the scan via `async let`, and its heavy file I/O happens off the main
    /// actor (see refreshUsage), so neither freezes the panel (item 2). Both are
    /// awaited before returning so tests and the 15s loop stay deterministic.
    /// Local only: captures, sessions and worktrees. Nothing here touches the
    /// network — per-account limits are Brow's.
    public func refresh() async {
        let started = Date()
        async let usage: Void = refreshUsage(now: started)
        async let sessions: Void = refreshSessionIndex()
        // Scan the selected project every tick (its detail view needs fresh data);
        // scan the OTHERS once, when they have no snapshot yet, so EVERY project card
        // shows its "N repos · M ws" count — not only the one that's been opened.
        if !config.projects.isEmpty {
            isScanning = true
            for project in config.projects
            where project.id == selectedProjectID || snapshots[project.id] == nil {
                snapshots[project.id] = await workspaceService.scan(project: project)
            }
            isScanning = false
            GroveLog.perf.info("scan \(self.config.projects.count, privacy: .public) projects: \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        await usage
        await sessions
        await reconcileTranscripts()
        lastRefreshAt = Date()
    }

    /// Cheap per-project recent-session previews for the Projects tab (item 4).
    /// Independent of the heavy git scan: it only reads recent transcripts + live
    /// processes + the cmux hook map, all OFF the main actor. This is what makes
    /// the primary flow (open → pick a session → go to its terminal) instant.
    ///
    /// Also populates `externalSessionsByProject` and `otherSessions` (Phase 2 /
    /// Task 2): a disk-wide scan of ALL recent sessions attributed to projects by
    /// cwd prefix. The recency cap reuses `config.transcriptMirror.maxDays` (90 by
    /// default). allRecentSessions + attribution both run inside the detached task;
    /// the finished dictionaries are assigned back on the main actor.
    public func refreshSessionIndex() async {
        let accounts = config.accounts
        let claude = self.claude
        let cmuxMap = cmux().claudeSessionWorkspaceMap(hookFile: cmuxHookFile)
        let jobs: [(id: UUID, roots: [String])] = config.projects.map { p in
            let wsRoot = expandTilde(p.workspacesRoot
                ?? config.workspacesRootTemplate.replacingOccurrences(of: "{project}", with: p.name))
            return (id: p.id, roots: [expandTilde(p.path), wsRoot].filter { !$0.isEmpty })
        }
        let sinceDays = config.transcriptMirror.maxDays
        let now = Date()

        // Precompute canonical roots for every project ONCE on the main actor
        // (reads config.projects; each root is a single resolvingSymlinksInPath syscall).
        // The per-session attribution loop below needs these but runs off-main — we
        // pass a value snapshot so the closure never touches main-actor state. (I1 fix)
        let projectRoots: [(id: UUID, roots: [String])] = config.projects.map { p in
            let roots = [expandTilde(p.path), expandTilde(p.workspacesRoot ?? "")]
                .filter { !$0.isEmpty }
                .map { canonicalPath($0) }
            return (id: p.id, roots: roots)
        }

        let (sessionRows, byProject, unmatched) = await Task.detached(priority: .utility) {
            () -> ([UUID: [ProjectSessionRow]], [UUID: [ClaudeSession]], [ClaudeSession]) in
            // Single source of truth (file records ∪ process table) — same data the
            // project scan / Claude tab use, so no tab can disagree on liveness.
            let live = claude.allLiveProcesses(accounts: accounts)
            var out: [UUID: [ProjectSessionRow]] = [:]
            for job in jobs {
                let sessions = claude.recentSessions(underRoots: job.roots, accounts: accounts,
                                                     limit: AppState.sessionsPerProject)
                out[job.id] = buildProjectSessionRows(sessions: sessions, live: live, cmuxMap: cmuxMap)
            }
            // Disk-wide scan for attribution indices (Phase 2 / Task 2).
            // 500 is a GLOBAL budget across all projects (newest-first over the
            // ~90d transcriptMirror.maxDays window), so on a very active machine a
            // rarely-used project's recent sessions can fall below the cut.
            let all = claude.allRecentSessions(accounts: accounts, limit: 500,
                                               sinceDays: sinceDays, now: now)

            // Attribute sessions to projects off the main actor using the precomputed
            // canonical roots snapshot — avoids resolvingSymlinksInPath syscalls (up to
            // 500 sessions × N projects) on the main thread. (I1 fix)
            var sessionsByProject: [UUID: [ClaudeSession]] = [:]
            var otherSessions: [ClaudeSession] = []
            for session in all {
                let sessionCanon = canonicalPath(session.cwd)
                if let match = projectRoots.first(where: { proj in
                    proj.roots.contains { sessionCanon == $0 || sessionCanon.hasPrefix($0 + "/") }
                }) {
                    sessionsByProject[match.id, default: []].append(session)
                } else {
                    otherSessions.append(session)
                }
            }
            return (out, sessionsByProject, otherSessions)
        }.value
        recentSessionsByProject = sessionRows
        externalSessionsByProject = byProject
        otherSessions = unmatched
    }

    /// Refreshes branchesByRepo for `repos`, concurrently (one git call per
    /// repo). Existing entries for these repos are REPLACED — a deleted branch
    /// disappears from the pickers on the next load — while entries for other
    /// repos are left alone. localBranches never throws ([] on failure), so
    /// non-repos degrade to an empty list and the pickers fall back to the
    /// resolved default.
    public func loadBranches(for repos: [RepoInfo]) async {
        let fresh = await withTaskGroup(of: (String, [String]).self) { group in
            for repo in repos {
                group.addTask { [path = repo.path] in
                    (path, await GitService().localBranches(repoPath: path))
                }
            }
            var collected: [String: [String]] = [:]
            for await (path, branches) in group {
                collected[path] = branches
            }
            return collected
        }
        branchesByRepo.merge(fresh) { _, new in new }
    }
}

// MARK: - Graph

extension AppState {
    /// Drops the loaded graph page. Called whenever the selected project
    /// changes (open(.project) with a different id, removeProject of the
    /// selected one): graphNodes/graphRepoPath belong to ONE project, and
    /// keeping them across a switch rendered project A's commits under
    /// project B's repo strip (v1.2.1 fix 1). GraphScreen auto-selects the
    /// new project's first repo via graphAutoSelectRepo on its next .task.
    private func resetGraph() {
        graphNodes = []
        graphRepoPath = nil
        graphCanLoadMore = false
        expandedCommit = nil
        expandedCommitFiles = nil
    }

    /// Toggles the inline file-change list for commit `sha`. Loads the files lazily
    /// (`git show --numstat`) on first expand; a second tap collapses it.
    public func expandCommit(_ sha: String) async {
        if expandedCommit == sha { expandedCommit = nil; expandedCommitFiles = nil; return }
        guard let repoPath = graphRepoPath else { return }
        expandedCommit = sha
        expandedCommitFiles = nil   // spinner until loaded
        let files = try? await GitService().fileChanges(repoPath: repoPath, sha: sha)
        // Ignore a stale result if the user expanded a different commit meanwhile.
        if expandedCommit == sha { expandedCommitFiles = files ?? [] }
    }

    public func loadGraph(repoPath: String) async {
        graphRepoPath = repoPath
        do {
            graphNodes = try await GitService().commitGraph(repoPath: repoPath, limit: graphPageSize)
            graphCanLoadMore = graphNodes.count == graphPageSize
        } catch {
            graphNodes = []
            graphCanLoadMore = false
            actionError = String(describing: error)
        }
    }

    /// Appends the next `git log --all` page (spec §6.2 lazy paging). No-op
    /// when the previous page was short. Commits created between page loads
    /// shift skip-based ordering, so a page can repeat already-loaded hashes —
    /// those are dropped (graphNodes hashes must stay unique: they are ForEach
    /// identities and GraphLanesCanvas row keys). KNOWN v1 LIMITATION:
    /// commitGraph lays lanes out per page, so lane numbers (and colors)
    /// restart at each page boundary; links inside a page stay correct.
    public func loadMoreGraph() async {
        guard let repoPath = graphRepoPath, graphCanLoadMore else { return }
        do {
            let more = try await GitService().commitGraph(repoPath: repoPath,
                                                          limit: graphPageSize,
                                                          skip: graphNodes.count)
            let seen = Set(graphNodes.map(\.hash))
            graphNodes += more.filter { !seen.contains($0.hash) }
            graphCanLoadMore = more.count == graphPageSize
        } catch {
            actionError = String(describing: error)
        }
    }
}

// MARK: - Claude / cmux actions

extension AppState {
    /// Launches Claude (optionally resuming a session) in a NEW cmux workspace
    /// at `cwd`, focused. cmux is started first when not running.
    public func launchClaude(cwd: String, title: String, account: AccountConfig,
                             resume sessionId: String?,
                             model: String? = nil, effort: String? = nil,
                             skipPermissions: Bool? = nil) async {
        handOff()
        let service = cmux()
        // --dangerously-skip-permissions: an explicit per-launch choice (from the
        // config sheet) wins; otherwise resolve the project default by `cwd`, here in
        // the single launch chokepoint so EVERY caller honors the setting.
        ClaudeService.ensureOnboarded(configDir: account.configDir, home: folders.home)
        let command = ClaudeService.launchCommand(account: account, resume: sessionId,
                                                  model: model, effort: effort,
                                                  skipPermissions: skipPermissions ?? effectiveSkipPermissions(cwd: cwd),
                                                  browser: browserRouter, claude: claudePath?(),
                                                  environment: launchEnvironment?(expandTilde(account.configDir)))
        do {
            try await service.ensureRunning()
            try await service.newWorkspace(name: title, cwd: cwd, command: command, focus: true)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// An account's default model and effort (Settings › Accounts); a project's own
    /// default wins over them at launch.
    public func setAccountModel(name: String, model: String?) {
        guard let i = config.accounts.firstIndex(where: { $0.name == name }) else { return }
        config.accounts[i].defaultModel = (model?.isEmpty == true) ? nil : model
        persist()
    }
    public func setAccountEffort(name: String, effort: String?) {
        guard let i = config.accounts.firstIndex(where: { $0.name == name }) else { return }
        config.accounts[i].defaultEffort = (effort?.isEmpty == true) ? nil : effort
        persist()
    }

    public func setProjectModel(projectID: UUID, model: String?) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].defaultModel = (model?.isEmpty == true) ? nil : model
        persist()
    }
    public func setProjectEffort(projectID: UUID, effort: String?) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].defaultEffort = (effort?.isEmpty == true) ? nil : effort
        persist()
    }
    public func setProjectSkipPermissions(projectID: UUID, _ on: Bool) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].dangerouslySkipPermissions = on
        persist()
    }

    /// Relaunches a session under `account` with an EXPLICIT model/effort (a session
    /// card's "Relaunch with model X"). Cross-account still link-on-demands via
    /// resumeSession's path; here we go straight to launch with the override.
    public func relaunchSession(_ session: ClaudeSession, as account: AccountConfig,
                                model: String?, effort: String?) async {
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account,
                           resume: session.id, model: model, effort: effort)
    }

    /// The project that owns `cwd` (its path or workspacesRoot is a prefix), if any.
    /// Used so a session's launch picks up the right project defaults.
    private func project(forCwd cwd: String) -> ProjectConfig? {
        let canon = canonicalPath(cwd)
        return config.projects.first { p in
            let roots = [expandTilde(p.path), expandTilde(p.workspacesRoot ?? "")]
                .filter { !$0.isEmpty }.map(canonicalPath)
            return roots.contains { canon == $0 || canon.hasPrefix($0 + "/") }
        }
    }

    /// Public resolver for the session cards: the project owning a session's cwd,
    /// so the model/effort pickers write that project's default (`setProjectModel`).
    public func owningProject(forCwd cwd: String) -> ProjectConfig? {
        project(forCwd: cwd)
    }

    /// Effective default model for a launch: project.defaultModel beats
    /// account.defaultModel beats nil (spec §C.6). cwd resolves the project.
    func effectiveModel(cwd: String, account: AccountConfig) -> String? {
        project(forCwd: cwd)?.defaultModel ?? account.defaultModel
    }

    func effectiveEffort(cwd: String, account: AccountConfig) -> String? {
        project(forCwd: cwd)?.defaultEffort ?? account.defaultEffort
    }

    /// Whether to launch with `--dangerously-skip-permissions` for `cwd`: the owning
    /// project's per-project toggle (false when no project owns the cwd, e.g. a login
    /// shell at $HOME). Project-scoped only — there is no account/global form.
    func effectiveSkipPermissions(cwd: String) -> Bool {
        project(forCwd: cwd)?.dangerouslySkipPermissions ?? false
    }

    /// Degraded-mode affordance (spec §7): the error banner's "Launch cmux"
    /// button. ensureRunning performs `open -b com.cmuxterm.app` and waits for
    /// a ping answer; success clears the banner, failure replaces it.
    public func launchCmuxApp() async {
        do {
            try await cmux().ensureRunning()
            actionError = nil
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Projects-tab session block tap (item 4): Go to the live cmux workspace
    /// hosting the session if known, else Resume it under its account in a fresh
    /// workspace. The fast routing path — no snapshot lookup needed.
    public func openSession(_ row: ProjectSessionRow) async {
        // CLOSED → open the launch sheet (target / account / model / effort) so the
        // user confirms HOW to resume before a new process is spawned.
        guard row.state != .closed else {
            beginResume(row)
            return
        }
        // LIVE → redirect to the running process; NEVER spawn a duplicate. Try each
        // gate in turn and only fall through on FAILURE — a stale/closed workspace
        // from one path must not dead-end before the others are tried.
        handOff()
        let service = cmux()
        // 1) cmux by workspace id (row, or re-resolved from the hook registry).
        if let target = row.cmuxWorkspaceId
            ?? service.claudeSessionWorkspaceMap(hookFile: cmuxHookFile)[row.sessionId],
           (try? await service.selectWorkspace(target)) != nil {
            return
        }
        // 2) cmux by the session's directory (the registry only tracks the ACTIVE
        //    session per workspace, so most sessions aren't in it).
        if let ws = await service.workspaceForCwd(row.cwd),
           (try? await service.selectWorkspace(ws.id)) != nil {
            return
        }
        // 3) Apple's Terminal.app, by matching the process's controlling tty.
        let claude = self.claude
        let sessionId = row.sessionId
        let accounts = config.accounts
        let focused = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let tty = claude.ttyForSession(sessionId, accounts: accounts) else { return false }
            return TerminalFocus.focusTerminalApp(tty: tty)
        }.value
        if !focused {
            actionError = "“\(row.location)” is running, but in a terminal Brow can't focus "
                + "(not cmux or Terminal.app). Switch to it in your terminal."
        }
    }

    /// Seeds the launch/config sheet for `cwd`/`sessionId` with the owning project's
    /// defaults (model / effort / skip-permissions), letting the user override any
    /// of them — plus the account and target — before the launch runs. `account` is
    /// recorded as BOTH the chosen and the origin account, so a later account change
    /// in the sheet is detected as a cross-account resume.
    private func seedLaunch(sessionId: String?, cwd: String, title: String, account: String) {
        let owner = project(forCwd: cwd)
        let acct = config.accounts.first { $0.name == account }
        launchRequest = LaunchRequest(
            sessionId: sessionId, cwd: cwd, title: title,
            account: account, originAccount: account,
            model: owner?.defaultModel ?? acct?.defaultModel,
            effort: owner?.defaultEffort ?? acct?.defaultEffort,
            skipPermissions: effectiveSkipPermissions(cwd: cwd),
            target: .cmux)
        // The form is a screen of its own, pushed over the one it was asked from.
        if route != .launch {
            launchOrigin = route
            open(.launch)
        }
    }

    /// The launch form's Cancel, Esc and back: nothing launches, and the screen it was
    /// opened from comes back.
    public func cancelLaunch() {
        launchRequest = nil
        let origin = launchOrigin ?? .projects
        launchOrigin = nil
        if route == .launch { open(origin) }
    }

    /// Presents the launch sheet pre-filled to RESUME `row`'s session.
    public func beginResume(_ row: ProjectSessionRow) {
        seedLaunch(sessionId: row.sessionId, cwd: row.cwd, title: row.location, account: row.accountName)
    }

    /// Presents the launch sheet for a fresh ("New Claude") session in `cwd`.
    public func beginNew(cwd: String, title: String, account: AccountConfig) {
        seedLaunch(sessionId: nil, cwd: cwd, title: title, account: account.name)
    }

    /// Opens the per-session config/relaunch sheet for a Workspaces-tab session.
    public func beginConfigure(session: ClaudeSession) {
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        seedLaunch(sessionId: session.id, cwd: session.cwd, title: title, account: session.accountName)
    }

    /// Runs the configured launch (Resume or New) at the chosen target. Closes the
    /// sheet first so it can't be double-submitted.
    public func confirmLaunch(_ request: LaunchRequest) async {
        launchRequest = nil
        if route == .launch {
            let origin = launchOrigin ?? .projects
            launchOrigin = nil
            open(origin)
        }
        handOff()
        let account = config.accounts.first { $0.name == request.account }
            ?? config.accounts.first ?? AccountConfig(name: "default", configDir: "~/.claude")
        // Resuming under a DIFFERENT account than the session belongs to needs the
        // canonical-store linking first (so the new account's claude sees the
        // transcript); abort the launch if that move is blocked.
        if let sessionId = request.sessionId, !sessionId.isEmpty {
            guard prepareResumeAccount(sessionId: sessionId, cwd: request.cwd,
                                       fromAccount: request.originAccount, to: account) else { return }
        }
        switch request.target {
        case .cmux:
            await launchClaude(cwd: request.cwd, title: request.title, account: account,
                               resume: request.sessionId, model: request.model, effort: request.effort,
                               skipPermissions: request.skipPermissions)
        case .terminal:
            ClaudeService.ensureOnboarded(configDir: account.configDir, home: folders.home)
            let command = ClaudeService.launchCommand(account: account, resume: request.sessionId,
                                                      model: request.model, effort: request.effort,
                                                      skipPermissions: request.skipPermissions,
                                                      browser: browserRouter, claude: claudePath?(),
                                                      environment: launchEnvironment?(expandTilde(account.configDir)))
            let cwd = request.cwd
            let ok = await Task.detached(priority: .userInitiated) {
                TerminalFocus.launchInTerminal(command: command, cwd: cwd)
            }.value
            if !ok { actionError = "Couldn't open Terminal.app for the session." }
        }
    }

    public func goToCmux(_ ws: CmuxWorkspace) async {
        handOff()
        do {
            try await cmux().selectWorkspace(ws.id)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Jumps to the cmux workspace hosting the session. The Sessions table
    /// resolves the target workspace id when it builds the row (`cmuxWorkspaceId`
    /// — from the hook registry OR a cmux workspace already sitting in the
    /// session's cwd, which the spec's "Go" requires) and passes it as
    /// `workspaceId`. When nil, we re-resolve through the hook registry; only on
    /// a genuine miss do we relaunch Claude with --resume in a fresh workspace.
    public func goToSession(_ s: ClaudeSession, fallbackCwd: String, fallbackTitle: String,
                            account: AccountConfig, workspaceId: String? = nil) async {
        handOff()
        let service = cmux()
        if let id = workspaceId ?? service.claudeSessionWorkspaceMap(hookFile: cmuxHookFile)[s.id] {
            do {
                try await service.selectWorkspace(id)
            } catch {
                actionError = String(describing: error)
            }
            return
        }
        await launchClaude(cwd: fallbackCwd, title: fallbackTitle, account: account, resume: s.id)
    }

    /// The canonical store directory: the default account's `~/.claude`
    /// (`folders.canonicalDir`). Linking roots here; it is never symlinked. Internal so
    /// views in the same module (a session's menu) can evaluate canShareAcrossAccounts
    /// without recomputing the path.
    var canonicalDir: String { folders.canonicalDir }

    /// The account whose expanded configDir IS the canonical dir, if configured.
    /// Sharing is impossible without it (nothing to root the symlinks at).
    private var canonicalAccount: AccountConfig? {
        config.accounts.first { expandTilde($0.configDir) == canonicalDir }
    }

    // MARK: - Shared store

    /// Links `account` into the canonical store (wholesale dirs only; per-workspace
    /// projects symlinks are created lazily on resume). Marks it sharedStore=true and
    /// persists. No-op for the canonical account. Failures land in actionError.
    public func linkAccount(_ account: AccountConfig) {
        guard canonicalAccount != nil else {
            actionError = "Can't link without a canonical account: add an account whose "
                + "config dir is ~/.claude (the default account)."
            return
        }
        guard expandTilde(account.configDir) != canonicalDir else { return }  // canonical: nothing to link
        // Nothing linked that the config could not then record (`mayPersist`).
        guard mayPersist() else { return }
        for dir in account.allConfigDirs.map(expandTilde) where dir != canonicalDir {
            // The account's CLAUDE_CONFIG_DIR must exist before its wholesale dirs can
            // be symlinked into canonical (createSymbolicLink needs a real parent).
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            do {
                _ = try SharedSessionStore().ensureLinked(accountDir: dir, canonicalDir: canonicalDir)
            } catch {
                actionError = "Couldn't link “\(displayName(for: account))”: \(error.localizedDescription)"
                return
            }
        }
        if let index = config.accounts.firstIndex(where: { $0.name == account.name }),
           !config.accounts[index].sharedStore {
            config.accounts[index].sharedStore = true
            persist()
        }
        // Phase 5A: capture usage by default for every linked account (when the engine
        // captures by default at all).
        if capturesByDefault { enableMonitoring(account, reportErrors: false) }
    }

    // MARK: - Transcript mirror

    /// Hardlink-mirrors every account's transcripts, off the main actor, and lists the
    /// vanished ones it could put back (`restorableTranscripts`) — it puts none back by
    /// itself. No-ops when the feature is disabled or when no canonical account is
    /// configured. Snapshot-render safety comes from the caller not invoking this
    /// during `ImageRenderer` passes — the same structural guarantee `verifySharedStore`
    /// relies on.
    ///
    /// Every account's folder carries Claude Code's own retention for it into the
    /// reconcile (grove#6): the mirror keeps nothing older and offers nothing back that
    /// Claude Code's sweep may have removed. The periods are read even with the safety net
    /// off, for Settings.
    public func reconcileTranscripts() async {
        await reconcileTranscripts(restore: .none)
    }

    /// Puts back the transcripts the user chose in Settings, if they still qualify (gone,
    /// and inside every retention that applies); the rest of the pass is an ordinary
    /// reconcile. Returns how many came back.
    @discardableResult
    public func restoreTranscripts(_ chosen: [RestorableTranscript]) async -> Int {
        guard !chosen.isEmpty else { return 0 }
        let report = await reconcileTranscripts(restore: .only(Set(chosen.map(\.entry.mirrorPath))))
        let restored = report?.restored.count ?? 0
        if restored > 0 { await refreshSessionIndex() }
        return restored
    }

    @discardableResult
    private func reconcileTranscripts(restore: RestoreMode) async -> ReconcileReport? {
        if let mayWrite, !mayWrite() { return nil }
        let retention = folders.claudeRetention
        let dirsByAccount = accountDirs()
        let enabled = config.transcriptMirror.enabled && canonicalAccount != nil
        let canonical = canonicalDir
        let settings = config.transcriptMirror
        let names = Dictionary(dirsByAccount.flatMap { account in account.dirs.map { (accountKey($0), account.name) } },
                               uniquingKeysWith: { first, _ in first })
        let result = await Task.detached(priority: .utility) {
            () -> (byAccount: [String: ClaudeRetention.Resolution], report: ReconcileReport?,
                   restorable: [RestorableTranscript]) in
            let (byAccount, mirrorAccounts) = Self.resolveRetention(dirsByAccount, retention, canonicalDir: canonical)
            guard enabled else { return (byAccount, nil, []) }
            // An entry whose account left the config has no period of its own that can be
            // read, so the shortest that could apply: the managed one, Claude Code's
            // default, or any configured account's (it may have shared the workspace).
            let orphan = ([retention.resolveManaged().days, ClaudeRetention.defaultDays]
                          + byAccount.values.map(\.days)).min() ?? ClaudeRetention.defaultDays
            let policy = RetentionPolicy(maxDays: settings.maxDays,
                                         maxBytes: Int64(settings.maxMB) * 1_000_000,
                                         orphanRetentionDays: orphan)
            let report = TranscriptMirror().reconcile(accounts: mirrorAccounts, canonicalDir: canonical,
                                                      policy: policy, restore: restore)
            let restorable = report.restorable.map {
                RestorableTranscript(entry: $0, accountName: names[$0.accountKey],
                                     cwd: TranscriptCwds.cwd(ofTranscriptAt: $0.mirrorPath))
            }
            return (byAccount, report, restorable)
        }.value
        if transcriptRetention != result.byAccount { transcriptRetention = result.byAccount }
        if restorableTranscripts != result.restorable { restorableTranscripts = result.restorable }
        if let first = result.report?.issues.first { actionError = "Transcript mirror: \(first)" }
        return result.report
    }

    /// Reads every account's retention for Settings, touching nothing else.
    public func refreshTranscriptRetention() async {
        let retention = folders.claudeRetention
        let dirsByAccount = accountDirs()
        let canonical = canonicalDir
        let byAccount = await Task.detached(priority: .utility) {
            Self.resolveRetention(dirsByAccount, retention, canonicalDir: canonical).byAccount
        }.value
        if transcriptRetention != byAccount { transcriptRetention = byAccount }
    }

    private func accountDirs() -> [(name: String, dirs: [String])] {
        config.accounts.map { (name: $0.name, dirs: $0.allConfigDirs.map(expandTilde)) }
    }

    /// File reads only; called off the main actor.
    nonisolated private static func resolveRetention(_ dirsByAccount: [(name: String, dirs: [String])],
                                                     _ retention: ClaudeRetention, canonicalDir: String)
        -> (byAccount: [String: ClaudeRetention.Resolution], mirrorAccounts: [MirrorAccount]) {
        var byAccount: [String: ClaudeRetention.Resolution] = [:]
        var mirrorAccounts: [MirrorAccount] = []
        for (name, dirs) in dirsByAccount {
            let resolved = dirs.map { (dir: $0, retention: resolveFolder($0, retention, canonicalDir: canonicalDir)) }
            byAccount[name] = ClaudeRetention.strictest(resolved.map(\.retention))
            mirrorAccounts += resolved.map { MirrorAccount(configDir: $0.dir, retention: $0.retention) }
        }
        return (byAccount, mirrorAccounts)
    }

    /// One config folder's period, the project settings of every folder its sessions ran
    /// in included — those its transcripts record, and those of the transcripts only the
    /// safety net still holds. File reads only; called off the main actor.
    nonisolated static func resolveFolder(_ dir: String, _ retention: ClaudeRetention,
                                          canonicalDir: String) -> ClaudeRetention.Resolution {
        let mirrored = TranscriptMirror.mirrorRoot(canonicalDir: canonicalDir) + "/" + accountKey(dir)
        return retention.resolve(configDir: dir, projectCwds: TranscriptCwds.all(configDir: dir, extraFolders: [mirrored]))
    }

    // MARK: - Session migration (Phase 4A4)

    /// Full cross-account session migration: copies the session's transcript,
    /// aux files, tasks, settings keys, and plugins into the target account's
    /// configDir — non-destructively (never overwrites). No-op when source and
    /// target share the same account name. Works while the target account is in use.
    public func migrateSession(cwd: String, sessionId: String,
                               from sourceAccount: AccountConfig,
                               to targetAccount: AccountConfig) async {
        guard sourceAccount.name != targetAccount.name else { return }

        let fromConfigDir = expandTilde(sourceAccount.configDir)
        let toConfigDir   = expandTilde(targetAccount.configDir)

        // HOT migration: sessions running under the TARGET account are fine. The
        // target's hot config files (.claude.json, settings.json, plugin registries)
        // are merged through HotJSONFile — Claude's own `<file>.lock`, a
        // compare-before-swap, and no write at all when nothing changes — so a
        // concurrent claude process neither loses an update nor causes one.
        let fromHomeJSON  = claudeJSONPath(for: sourceAccount)
        let toHomeJSON    = claudeJSONPath(for: targetAccount)
        let mirrorRoot    = TranscriptMirror.mirrorRoot(canonicalDir: canonicalDir)
        let fromKey       = accountKey(fromConfigDir)

        // Ensure the target's standard directories exist (like linkAccount does).
        let fm = FileManager.default
        try? fm.createDirectory(atPath: toConfigDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: toConfigDir + "/projects", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: toConfigDir + "/plugins", withIntermediateDirectories: true)

        let retention = folders.claudeRetention
        let canonical = canonicalDir
        let allDirs = config.accounts.flatMap(\.allConfigDirs).map(expandTilde)
        let report = await Task.detached(priority: .utility) { () -> MigrateReport in
            // The safety net's copy stands in for a vanished transcript only inside the
            // window the safety net itself would offer it back in (grove#6): the shortest
            // period of every account that reaches the session's workspace folder — a
            // shared one is swept by each of them — project settings included.
            let reaching = TranscriptMirror.foldersSharing(encodedCwd: ClaudeService.mangle(cwd),
                                                           with: fromConfigDir, among: allDirs)
            let period = ClaudeRetention.strictest(reaching.map { Self.resolveFolder($0, retention, canonicalDir: canonical) })
            let maxAge = (Double(period.days) - TranscriptMirror.restoreMarginDays) * 86_400
            return SessionMigration.migrateSession(
                sessionId: sessionId, cwd: cwd,
                fromConfigDir: fromConfigDir, toConfigDir: toConfigDir,
                fromHomeJSON: fromHomeJSON, toHomeJSON: toHomeJSON,
                mirrorRoot: period.isCertain ? mirrorRoot : nil, fromAccountKey: fromKey,
                mirrorMaxAge: maxAge)
        }.value

        if let first = report.issues.first { actionError = "Migrate: \(first)" }
        // Phase 5A: capture usage by default for the target account now that it holds
        // a real session. Use the persisted entry so the gate reflects prior state.
        if capturesByDefault, let target = config.accounts.first(where: { $0.name == targetAccount.name }),
           !target.monitoring {
            enableMonitoring(target, reportErrors: false)
        }
        await refreshSessionIndex()
    }

    /// Permanent delete of a session's transcript (mirror + live sides), then
    /// refreshes the session index. Failures land in actionError.
    public func purgeTranscript(id: String) {
        guard canonicalAccount != nil else { return }
        let accts = config.accounts.flatMap(\.allConfigDirs).map {
            MirrorAccount(key: accountKey($0), configDir: expandTilde($0))
        }
        do {
            try TranscriptMirror().purge(sessionId: id, accounts: accts, canonicalDir: canonicalDir)
        } catch {
            actionError = "Couldn't purge transcript: \(error.localizedDescription)"
        }
        Task { await refreshSessionIndex() }
    }

    /// Runs SharedSessionStore.verify across accounts MARKED sharedStore and
    /// surfaces the first issue through actionError (the existing banner). No
    /// issues → clears nothing (so it never stomps an unrelated error). Snapshot
    /// renders skip it (no real ~/.claude access).
    public func verifySharedStore() {
        let marked = config.accounts.filter(\.sharedStore).flatMap(\.allConfigDirs).map(expandTilde).filter { $0 != canonicalDir }
        guard !marked.isEmpty, canonicalAccount != nil else { return }
        let issues = SharedSessionStore().verify(accountDirs: marked, canonicalDir: canonicalDir)
        if let first = issues.first {
            actionError = "Shared store: \(first)"
        }
    }

    /// Links `account` into the canonical store unless it IS the canonical account
    /// (never linked to itself). Marks it sharedStore=true and persists. Returns
    /// nil on success, or an error message describing the failure (caller aborts).
    private func ensureLinkedForResume(_ account: AccountConfig, mangledCwd: String) -> String? {
        guard expandTilde(account.configDir) != canonicalDir else { return nil }  // canonical: skip
        let store = SharedSessionStore()
        let dir = expandTilde(account.configDir)
        // The account's CLAUDE_CONFIG_DIR must exist before its wholesale dirs can
        // be symlinked into canonical (createSymbolicLink needs a real parent).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            _ = try store.ensureLinked(accountDir: dir, canonicalDir: canonicalDir)
            _ = try store.ensureWorkspaceLinked(accountDir: dir, canonicalDir: canonicalDir,
                                                mangledCwd: mangledCwd)
        } catch {
            return "Couldn't link “\(displayName(for: account))” to the shared store: \(error.localizedDescription)"
        }
        if let index = config.accounts.firstIndex(where: { $0.name == account.name }),
           !config.accounts[index].sharedStore {
            config.accounts[index].sharedStore = true
            persist()
        }
        return nil
    }

    // MARK: - Session adoption (Phase 2 / Task 4)

    /// Predicate: true when `account` is NOT the canonical/default account, meaning
    /// its sessions are not yet shared and can benefit from adoption. Pure, static,
    /// unit-testable. `canonicalDir` is the expanded canonical store path.
    public static func canShareAcrossAccounts(account: AccountConfig, canonicalDir: String) -> Bool {
        expandTilde(account.configDir) != canonicalDir
    }

    /// Brings a session discovered under `account` into the canonical shared store so
    /// its transcript is reachable from every linked account.
    ///
    /// Safety contract:
    /// - No-op when `account` IS the canonical account (already shared).
    /// - Aborts with `actionError` when the session is currently live under ANY account
    ///   (ensureWorkspaceLinked moves the transcript file; moving an open file causes
    ///   data loss for the running process).
    /// - On success, refreshes the session index so the UI reflects the new state.
    ///
    /// `sessionId` is required to catch sessions that are live via
    /// `claude --resume <id>` / `--session-id <id>` — these appear in the process
    /// table with `cwd == ""`, so cwd-only matching misses them (C1 fix).
    public func adoptSession(cwd: String, sessionId: String, account: AccountConfig) async {
        // No-op for the canonical/default account — already the root of sharing.
        guard Self.canShareAcrossAccounts(account: account, canonicalDir: canonicalDir) else { return }

        // SAFETY: refuse if the session is live anywhere. ensureWorkspaceLinked moves
        // the transcript file; an open file descriptor on the moved file means future
        // writes from the live claude process go to an unlinked inode (data loss).
        // ClaudeService.isSessionLive checks BOTH sessionId (table-only --resume path,
        // cwd=="") AND cwd (fresh sessions) so neither liveness signal is missed.
        let live = allLiveProcessesOverride ?? liveService.allLiveProcesses(accounts: config.accounts)
        let mangled = ClaudeService.mangle(cwd)
        if ClaudeService.isSessionLive(among: live, sessionId: sessionId) {
            actionError = "This session is running — close it, then Share."
            return
        }

        if let error = ensureLinkedForResume(account, mangledCwd: mangled) {
            actionError = error
            return
        }

        await refreshSessionIndex()
    }

    /// The name of an account (other than `launchAccount`) under which the session
    /// `sessionId` runs now, or nil. Used to BLOCK a cross-account launch that would have
    /// two processes writing one transcript (the one real corruption case). Every live
    /// process is joined to the one session it runs (`ClaudeService.allLiveProcesses`), so
    /// a plain `claude` in the same folder running another session is no conflict.
    private func sessionLiveUnderOtherAccount(_ sessionId: String, cwd: String,
                                              launchAccount: AccountConfig) -> String? {
        let live = allLiveProcessesOverride ?? liveService.allLiveProcesses(accounts: config.accounts)
        guard let running = live.first(where: { !sessionId.isEmpty && $0.sessionId == sessionId }),
              running.accountName != launchAccount.name else { return nil }
        guard let owner = config.accounts.first(where: { $0.name == running.accountName }) else {
            return "a running session"
        }
        return displayName(for: owner)
    }

    /// The engine's reader of live sessions, or a copy whose liveness check a test chose.
    private var liveService: ClaudeService {
        liveProcessValidatorOverride.map { claude.withProcessValidator($0) } ?? claude
    }

    /// Resumes `session` under `account`. Same-account: links nothing, just
    /// launches `--resume` in the session's cwd. Cross-account (D7, no copy): links
    /// BOTH the owning and the target account into the canonical store, so the
    /// transcript physically lives in canonical and is visible to the target, then
    /// launches `CLAUDE_CONFIG_DIR=<target> claude --resume <id>`. Aborts with an
    /// actionError (and launches nothing) when: there is no canonical/default
    /// account to root the share, the owning account is gone from config, linking
    /// fails, or the same session is live under a DIFFERENT account (concurrency
    /// guard, added in Task 4).
    public func resumeSession(_ session: ClaudeSession, as account: AccountConfig) async {
        guard prepareResumeAccount(sessionId: session.id, cwd: session.cwd,
                                   fromAccount: session.accountName, to: account) else { return }
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account, resume: session.id,
                           model: effectiveModel(cwd: session.cwd, account: account),
                           effort: effectiveEffort(cwd: session.cwd, account: account))
    }

    /// Prepares a resume that may target a DIFFERENT account than the session
    /// belongs to: when `account` differs from `fromAccount`, both are linked into
    /// the canonical store so the transcript is visible under the new account.
    /// Returns false (and sets `actionError`) when the move is blocked; true when
    /// same-account (a no-op) or successfully linked. Shared by `resumeSession` and
    /// the config-sheet `confirmLaunch` path.
    private func prepareResumeAccount(sessionId: String, cwd: String,
                                      fromAccount: String, to account: AccountConfig) -> Bool {
        guard account.name != fromAccount else { return true }
        if let other = sessionLiveUnderOtherAccount(sessionId, cwd: cwd, launchAccount: account) {
            actionError = "This session is live under “\(other)” — close it first, "
                + "then resume as \(displayName(for: account))."
            return false
        }
        guard canonicalAccount != nil else {
            actionError = "Can't share sessions without a canonical account: add an "
                + "account whose config dir is ~/.claude (the default account)."
            return false
        }
        guard let owner = config.accounts.first(where: { $0.name == fromAccount }) else {
            actionError = "Can't resume as \(displayName(for: account)): the owning account "
                + "“\(fromAccount)” is no longer configured."
            return false
        }
        let mangled = ClaudeService.mangle(cwd)
        // Link the owner first (so the transcript migrates into canonical),
        // then the target (so the symlinked store makes it visible).
        if let error = ensureLinkedForResume(owner, mangledCwd: mangled) {
            actionError = error
            return false
        }
        if let error = ensureLinkedForResume(account, mangledCwd: mangled) {
            actionError = error
            return false
        }
        return true
    }
}

// MARK: - Workspace creation

extension AppState {
    /// nil = no project selected. A report with a non-nil failure also sets
    /// actionError; the create screen additionally shows report.logLines.
    /// startPointOverrides (keyed by repo dirName) beat both the resolved base
    /// branch and any fork-from parent branch — see WorkspaceService.
    public func createWorkspace(name: String, branch: String, repos: [RepoInfo],
                                forkFrom: FeatureWorkspace?,
                                startPointOverrides: [String: String] = [:]) async -> CreationReport? {
        guard let project = selectedProject else { return nil }
        let report = await workspaceService.createWorkspace(project: project, name: name,
                                                            branch: branch, repos: repos,
                                                            forkFrom: forkFrom,
                                                            startPointOverrides: startPointOverrides)
        if let failure = report.failure {
            actionError = failure
        }
        return report
    }

    /// Removes ONLY the artifacts of a failed creation run (spec §5.4).
    public func rollback(_ artifacts: [CreatedArtifact]) async -> [String] {
        await workspaceService.rollback(artifacts)
    }
}

// MARK: - cmux shell fallback (spec §6.1)

extension AppState {
    /// Creates a NEW shell-only cmux workspace at `cwd` and focuses it — the
    /// cmux-button fallback when a workspace has no cmux workspace yet.
    /// `command: nil` means cmux starts its default shell.
    public func openCmuxShell(cwd: String, title: String) async {
        handOff()
        let service = cmux()
        do {
            try await service.ensureRunning()
            try await service.newWorkspace(name: title, cwd: cwd, command: nil, focus: true)
        } catch {
            actionError = String(describing: error)
        }
    }
}

// MARK: - Usage monitoring

extension AppState {
    private var statuslineScriptDir: String { folders.bin }

    /// Reads every account's statusline captures and identity (called on the scan
    /// tick). `now` injected; defaults to Date() ONLY at the production call site.
    ///
    /// The file reads + JSON parsing run OFF the main actor (`Task.detached`) so a
    /// cold read never freezes the panel on open. Results are assigned back on the
    /// main actor. Per-account limits used to be fetched here too; that is Brow's now.
    public func refreshUsage(now: Date) async {
        let jobs: [(name: String, dir: String, claudeJSON: String)] = config.accounts.map {
            (name: $0.name, dir: expandTilde($0.configDir), claudeJSON: claudeJSONPath(for: $0))
        }
        let started = Date()
        let result = await Task.detached(priority: .utility) {
            () -> (snaps: [String: [UsageSnapshot]], ids: [String: AccountIdentity]) in
            let reader = UsageReader()
            var snaps: [String: [UsageSnapshot]] = [:]
            var ids: [String: AccountIdentity] = [:]
            for job in jobs {
                snaps[job.name] = reader.read(configDir: job.dir, accountName: job.name)
                // .claude.json read off-main here: what reconcileAccountNames names
                // accounts by.
                if let id = ClaudeService.identity(claudeJSONPath: job.claudeJSON) {
                    ids[job.name] = id
                }
            }
            return (snaps, ids)
        }.value
        snapshotsByAccount = result.snaps
        identityByAccount = result.ids
        GroveLog.perf.info("capture refresh (\(jobs.count) accts): \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    private func claudeJSONPath(for account: AccountConfig) -> String {
        folders.claudeJSONPath(configDir: account.configDir)
    }

    /// Opens the account's config dir in Finder (`open <configDir>`). Snapshot-safe
    /// callers gate this off; production reveals the real dir.
    public func openConfigDir(_ account: AccountConfig) {
        NSWorkspace.shared.open(URL(fileURLWithPath: expandTilde(account.configDir)))
    }

    /// Installs the grove statusline wrapper for `account`, saving its prior
    /// command into AccountConfig.savedStatusline and marking monitoring=true.
    /// Failures land in actionError; nothing is mutated on failure. This is the
    /// user-facing toggle; the auto-install sites (addAccount/linkAccount/
    /// migrateSession) share the same core via `enableMonitoring(_:)`.
    public func installMonitoring(_ account: AccountConfig) {
        enableMonitoring(account, reportErrors: true)
    }

    /// Shared statusline auto-install: ensures the account's configDir exists, ships
    /// the (idempotent, original-preserving) grove wrapper, repoints its settings.json,
    /// and records monitoring=true + savedStatusline. Best-effort — the whole point of
    /// auto-installing at account-setup time (Phase 5A) is capture-by-default, so a
    /// failure must never abort the surrounding action (addAccount/linkAccount/
    /// migrateSession). `reportErrors` surfaces failures in `actionError` only for the
    /// explicit user toggle; the auto sites stay silent.
    ///
    /// Re-runs are safe: `StatuslineInstaller.install` recovers the true original from
    /// the previously-baked wrapper, so calling this on an already-monitored account
    /// preserves — never clobbers — the saved original.
    private func enableMonitoring(_ account: AccountConfig, reportErrors: Bool) {
        // No wrapper installed that the config could not then record.
        guard mayPersist(reporting: reportErrors) else { return }
        let dir = expandTilde(account.configDir)
        // The wrapper writes <configDir>/settings.json; the dir must exist first
        // (addAccount's ~/.claude-accounts/<name> is brand-new and empty).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let saved: String?
        do { saved = try installer.install(configDir: dir) }
        catch {
            if reportErrors {
                actionError = "Couldn't enable monitoring for “\(displayName(for: account))”: \(error.localizedDescription)"
            }
            return
        }
        // Every folder of the login captures: an alias dir's sessions are the
        // account's sessions too (best-effort; nothing to save for an alias).
        for alias in account.aliasDirs.map(expandTilde) {
            _ = try? installer.install(configDir: alias)
        }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = true
        config.accounts[i].monitoringDisabledByUser = false
        config.accounts[i].savedStatusline = saved
        persist()
    }

    /// Restores the saved original statusline command and clears monitoring.
    /// Sets `monitoringDisabledByUser=true` so reconcileMonitoring knows not to
    /// silently re-enable this account on the next launch. Every other folder of the
    /// login gets back the command its own wrapper recorded (best-effort: a folder that is
    /// gone, or no longer runs the wrapper, is left alone).
    public func disableMonitoring(_ account: AccountConfig) {
        // No command put back while the config, which could not then be saved, still
        // says the account is captured.
        guard mayPersist() else { return }
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let dir = expandTilde(account.configDir)
        do { try installer.uninstall(configDir: dir, savedStatusline: account.savedStatusline) }
        catch { actionError = "Couldn't disable monitoring for “\(displayName(for: account))”: \(error.localizedDescription)"; return }
        for alias in account.aliasDirs.map(expandTilde) {
            _ = try? installer.restoreBakedOriginal(configDir: alias)
        }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = false
        config.accounts[i].monitoringDisabledByUser = true
        config.accounts[i].savedStatusline = nil
        persist()
    }

    /// Launch reconcile (Phase 5A): auto-installs the grove statusline wrapper for
    /// every configured account not yet monitored AND not explicitly disabled by the
    /// user — so accounts created before 5A (or an account whose monitoring was never
    /// enabled, e.g. icloud) start capturing usage. Accounts where the user explicitly
    /// ran `disableMonitoring` are skipped (monitoringDisabledByUser=true), so the
    /// user's intent is respected across launches. Best-effort per account: an account
    /// whose install fails (a settings.json that doesn't parse, a lock that isn't
    /// released) is logged and stays unmonitored, so the next launch tries again. An
    /// account whose folder no longer exists is skipped, never re-created.
    /// File I/O runs off-main to keep launch responsive.
    public func reconcileMonitoring() {
        // Only an engine that captures by default installs anything unasked.
        guard capturesByDefault else { return }
        // Gather accounts needing install on the main actor, then do file I/O off-main.
        let toInstall = config.accounts.filter { !$0.monitoring && !$0.monitoringDisabledByUser }
        guard !toInstall.isEmpty else { return }
        let scriptDir = statuslineScriptDir
        Task.detached(priority: .utility) { [weak self] in
            // Run install file I/O per account off the main thread.
            var installed: [(name: String, savedStatusline: String?)] = []
            for account in toInstall {
                let dir = expandTilde(account.configDir)
                // A folder that is gone stays gone (grove#12): creating it here left a lone
                // settings.json that both apps' folder discovery then adopted as an account.
                // The next launch tries again, should the folder come back.
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                    GroveLog.workspaces.info("statusline not installed for \(account.name, privacy: .public): its folder is gone")
                    continue
                }
                let installer = StatuslineInstaller(scriptDir: scriptDir)
                // `install` returns the ORIGINAL statusline command, nil when the
                // account had none — `if let saved = try? …` read that nil as a failed
                // install, so a fresh account got its wrapper on every launch and its
                // `monitoring` flag never turned true.
                do {
                    let saved = try installer.install(configDir: dir)
                    installed.append((name: account.name, savedStatusline: saved))
                } catch {
                    GroveLog.workspaces.error("statusline not installed for \(account.name, privacy: .public), retrying next launch: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Hop back to main actor to persist config changes. A `let` copy: the
            // closure runs on another executor and must not capture the `var`.
            let finished = installed
            await MainActor.run { [weak self] in
                guard let self else { return }
                for result in finished {
                    guard let i = self.config.accounts.firstIndex(where: { $0.name == result.name }) else { continue }
                    self.config.accounts[i].monitoring = true
                    self.config.accounts[i].savedStatusline = result.savedStatusline
                }
                if !finished.isEmpty { self.persist() }
            }
        }
    }
}

// MARK: - Code stats

extension AppState {
    /// The directory holding per-project code-stats history files: `folders.stats`
    /// (~/Library/Application Support/Grove/stats in the app).
    private var statsStoreDir: URL { URL(fileURLWithPath: folders.stats) }

    /// Built fresh from the resolved dir (a value type that just holds the URL). The
    /// scanner + cache that must persist across ticks live on `self`, not here.
    private var statsStore: CodeStatsStore { CodeStatsStore(dir: statsStoreDir) }

    /// Scans the project's code per-GIT-REPO (GitStatsService), updates the aggregate
    /// `codeStats`, the per-repo `repoStats` breakdown, and overwrites
    /// `codeStatsHistory` with the git-derived per-day series. Built like refreshUsage:
    /// the project's path, scan depth, excluded repos, and that project's git-stats
    /// cache are captured OFF the main actor in a `.utility` Task.detached; the git
    /// subprocesses + file reads happen there so they never freeze the panel. Results
    /// (and the updated cache) are assigned back on the main actor.
    /// No-op for an unknown id. `isStatsScanning` brackets the whole operation.
    public func refreshCodeStats(projectID: UUID, now: Date = Date()) async {
        // Serialize per project: if a scan for this project is already running, record
        // that another is wanted and return — the in-flight scan re-runs once when it
        // finishes (see the tail below). This prevents two scans racing on the shared
        // mtime cache, while still honoring a refresh requested mid-scan (e.g. after a
        // folder-exclusion toggle clears the cache).
        guard !statsScanInFlight.contains(projectID) else {
            statsRescanPending.insert(projectID)
            return
        }
        await runCodeStatsScan(projectID: projectID, now: now)
    }

    private func runCodeStatsScan(projectID: UUID, now: Date) async {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return }
        let path = project.path
        let depth = project.scanDepth
        let excluded = Set(project.excludedRepos)
        let excludedFolders = Set(project.statsIgnoredFolders)
        let cache = gitStatsCacheByProject[projectID] ?? [:]
        let service = gitStats
        let branchOverrides = selectedStatsBranchByRepo

        if statsRescanStartedCount != nil { statsRescanStartedCount! += 1 }
        statsScanInFlight.insert(projectID)
        statsRescanPending.remove(projectID)
        isStatsScanning = true
        let result = await Task.detached(priority: .utility) {
            () -> (stats: ProjectGitStats, cache: [String: RepoFileCache]) in
            var local = cache
            let stats = await service.scan(projectPath: path, scanDepth: depth,
                                           excludedRepos: excluded, excludedFolders: excludedFolders,
                                           branchOverrides: branchOverrides,
                                           now: now, cache: &local)
            return (stats, local)
        }.value
        statsScanInFlight.remove(projectID)
        isStatsScanning = !statsScanInFlight.isEmpty
        // A concurrent removeProject (or another refresh) may have run while detached;
        // only commit if the project still exists.
        guard config.projects.contains(where: { $0.id == projectID }) else {
            statsRescanPending.remove(projectID)
            return
        }
        // Aggregate feeds the existing screen; the per-repo breakdown is new.
        codeStats[projectID] = result.stats.aggregate
        repoStats[projectID] = result.stats.repos
        statsFiles[projectID] = result.stats.files
        gitStatsCacheByProject[projectID] = result.cache

        // History now comes from GIT and is authoritative — OVERWRITE the stored series
        // each scan (not append/coalesce). The store stays as the cross-launch cache;
        // the screen reads `codeStatsHistory[id]` unchanged.
        let history = CodeStatsHistory(points: result.stats.aggregateHistory)
        try? statsStore.save(projectID: projectID, history: history)
        codeStatsHistory[projectID] = result.stats.aggregateHistory

        // Populate the branch-switcher menus: the scan already discovered every repo,
        // so reuse its [RepoStats] to load each repo's local branches into
        // branchesByRepo (the same source the Graph's branch pickers use).
        let reposForBranches = result.stats.repos.map {
            RepoInfo(path: $0.repoPath, dirName: $0.repoName)
        }
        await loadBranches(for: reposForBranches)

        // Honor a refresh that arrived while this scan was running (its cache may now
        // be stale — e.g. a repo-exclusion toggle), serialized strictly after us.
        if statsRescanPending.remove(projectID) != nil {
            await runCodeStatsScan(projectID: projectID, now: Date())
        }
    }

    /// Stats-tab branch switcher: record the chosen branch for `repoPath` and rescan
    /// the project so its history/delta reflect the new branch (current LOC is taken
    /// from the working tree and is branch-independent, so it stays put). The dict
    /// write is OPTIMISTIC (immediate) so the chip label updates at once; the rescan
    /// is DEBOUNCED — rapid picks cancel the pending task and schedule a new one so
    /// N consecutive switches coalesce to one scan. Honors the per-project scan
    /// serialization via refreshCodeStats.
    public func setStatsBranch(projectID: UUID, repoPath: String, branch: String) {
        // Optimistic: the chip shows the new label immediately (no wait for rescan).
        selectedStatsBranchByRepo[repoPath] = branch
        // Debounce: cancel any pending rescan and schedule a fresh one after the interval.
        statsBranchDebounce?.cancel()
        let interval = statsBranchDebounceInterval
        statsBranchDebounce = Task {
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await refreshCodeStats(projectID: projectID)
        }
    }

    /// Excludes (or re-includes) a project-root-relative folder from code-stats
    /// scans: mutates `ProjectConfig.statsIgnoredFolders`, persists, and clears that
    /// project's stats cache so the next refresh re-tallies without the stale
    /// contributions of a folder whose exclusion just changed. No-op for an unknown
    /// id, or when the requested state already holds.
    public func setStatsFolderExcluded(projectID: UUID, relativePath: String, excluded: Bool) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var folders = config.projects[i].statsIgnoredFolders
        let alreadyExcluded = folders.contains(relativePath)
        if excluded {
            guard !alreadyExcluded else { return }
            folders.append(relativePath)
        } else {
            guard alreadyExcluded else { return }
            folders.removeAll { $0 == relativePath }
        }
        config.projects[i].statsIgnoredFolders = folders
        gitStatsCacheByProject[projectID] = [:]
        persist()
        // Trigger an immediate rescan so the toggle actually changes the numbers + the
        // file tree. `refreshCodeStats` serializes per project (queues a clean rescan if
        // one is already in flight), so rapid toggling never races on the shared cache.
        Task { await refreshCodeStats(projectID: projectID) }
    }

    /// I/O-light directory skeleton for the exclusion picker (off the main actor —
    /// it walks dirs but reads no files).
    public func statsDirectoryTree(projectID: UUID) async -> DirNode? {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return nil }
        let path = project.path
        let scanner = statsScanner
        return await Task.detached(priority: .utility) { scanner.directoryTree(projectPath: path) }.value
    }
}

/// A transcript the safety net can put back, as Settings lists it.
public struct RestorableTranscript: Identifiable, Equatable, Sendable {
    public let entry: VanishedTranscript
    /// The Workspaces account it belongs to; nil when its folder is no account's.
    public let accountName: String?
    /// The folder the session ran in, from the transcript; nil when it records none.
    public let cwd: String?

    public init(entry: VanishedTranscript, accountName: String?, cwd: String?) {
        self.entry = entry
        self.accountName = accountName
        self.cwd = cwd
    }

    public var id: String { entry.id }
}
