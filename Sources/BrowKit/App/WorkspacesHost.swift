// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Combine
import GroveAppKit
import GroveCore

/// Brow's side of Workspaces: whether the engine runs (`WorkspacesActivation`), the
/// Grove-running guard, the lock that keeps the engine to one copy of Brow
/// (`WorkspacesEngineLock`), the Projects section of the notch panel and the menu-bar
/// item that opens it. GroveAppKit never imports BrowKit; this is where the two meet.
///
/// Nothing of the engine runs until Workspaces is wanted: no account adoption, no
/// status-line reconcile, no timer, and the notch has no Projects section. While it is
/// off, Grove's config is still read for a status line Workspaces captured, which Claude
/// Code keeps running through the wrapper (`dormantAccounts`), and changed only to give
/// one back or to take out such an account whose folder is gone (`withoutEngine`).
@MainActor
public final class WorkspacesHost: ObservableObject {
    @Published public private(set) var activation: WorkspacesActivation = .off
    /// What Workspaces waits for while it is paused; nil otherwise.
    @Published public private(set) var pause: WorkspacesPause?
    /// The engine's state while Workspaces is wanted; nil while it is off.
    @Published public private(set) var state: AppState?
    /// Grove's accounts as its config has them, read without the engine while Workspaces
    /// is not on: an account whose status line it captured keeps running the wrapper
    /// under Claude Code whatever Workspaces does, so Settings keeps the switch that gives
    /// it back. Empty while Workspaces is on — the engine's state has them then.
    @Published public private(set) var dormantAccounts: [AccountConfig] = []
    /// What went wrong changing Grove's config while Workspaces is not on — giving a
    /// status line back, taking out an account whose folder is gone — by the name in
    /// Grove's config of the account it concerns: Settings shows it under that account.
    @Published public private(set) var changeErrors: [String: String] = [:]
    /// Whether Grove.app runs, as last looked. While Workspaces is wanted that pauses it;
    /// while it is off it decides nothing, but Grove.app still writes the files a change
    /// from Settings would (`dormantChangeBlock`).
    @Published public private(set) var groveRunning = false
    /// Folders picked as projects while Workspaces could not take them — paused, with
    /// Grove.app or another copy of Brow writing the same config — added once it runs.
    /// Not kept past a quit of Brow.
    @Published public private(set) var pendingProjects: [String] = []
    /// Opens Brow's Settings window where the screens ask for it: a project's gear goes
    /// to Workspaces, an account's link to Accounts.
    public var openSettings: ((WorkspacesSettingsLink) -> Void)?
    /// The notch panel: where the Projects section lives, and what closes on a hand-off.
    public weak var notch: NotchPresenting? {
        didSet { syncSection() }
    }

    public let folders: WorkspacesFolders
    private let store: LimitsStore
    private let groveGuard: GroveAppGuard
    private let groveConfigExists: () -> Bool
    private let watchRunningApps: RunningAppsWatch
    /// The look at the Claude Code processes that run (`ProcessTable.claudeCodeFolders`): what
    /// finds sessions that keep no record and the folders to suggest. nil reads none — what
    /// every test and offscreen render gets, so none of them looks at the Mac's processes.
    private let runningClaude: (@Sendable () -> [RunningClaude])?
    /// Held while this copy of Brow runs the engine; another copy that runs it first
    /// keeps this one paused.
    private let engineLock: WorkspacesEngineLock
    private var engine: WorkspacesEngine?
    private lazy var section = ProjectsSection(host: self)
    /// Who talks to whom among the agents of Brow's accounts: the Agents section's reader,
    /// watching only while the panel is open (and half a minute after).
    public let agents: AgentsObserver
    private lazy var agentsSection = AgentsSection(host: self)
    /// Keeps the Agents switch's dot on what the reader saw, and its accounts on the notch's.
    private var agentsWatch: Set<AnyCancellable> = []
    private lazy var statusItem = WorkspacesStatusItem { [weak self] in self?.statusItemClicked() }
    /// Keeps the running-apps watch alive while started.
    private var runningAppsWatch: AnyObject?
    /// Grove.app instances `quitGrove()` asked to quit, watched until they have.
    private var quitting: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// Keeps the notch's scan in step with the folders Workspaces knows.
    private var accountsWatch: AnyCancellable?
    /// Keeps the pickers on the notch's accounts.
    private var storeWatch: AnyCancellable?
    /// Keeps the switch's "needs you" count and the "N live" chips on what runs.
    private var liveWatch: AnyCancellable?
    /// Keeps the rows' previews on or off as Settings has them.
    private var previewsWatch: AnyCancellable?
    /// Brings the panel back for an error that follows a hand-off.
    private var errorWatch: AnyCancellable?
    /// When the panel last handed the user off: an error the engine reports right after
    /// brings the panel back to show it.
    private var lastHandOff: Date?
    private var started = false

    /// Starts telling `onChange` about every app that launches or quits, for as long as
    /// the returned object is kept.
    public typealias RunningAppsWatch = @MainActor (_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyObject

    /// NSWorkspace's list of running apps, observed. Not its launch and quit
    /// notifications: those leave out apps that run as agents (`LSUIElement`), which
    /// Grove.app is, as Brow is. The list is complete, and documented as observable.
    public static let watchWorkspaceApps: RunningAppsWatch = { onChange in
        NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { _, _ in
            Task { @MainActor in onChange() }
        }
    }

    public init(store: LimitsStore,
                folders: WorkspacesFolders = .live(),
                groveGuard: GroveAppGuard = GroveAppGuard(runningBundleIdentifiers: {
                    NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                }),
                groveConfigExists: (() -> Bool)? = nil,
                watchRunningApps: RunningAppsWatch? = nil,
                runningClaude: (@Sendable () -> [RunningClaude])? = nil,
                readsAgents: Bool = false) {
        self.store = store
        // Tests and renders read no agents: the app asks for it.
        self.agents = AgentsObserver(reads: readsAgents)
        self.folders = folders
        self.groveGuard = groveGuard
        self.runningClaude = runningClaude
        let configPath = folders.configFile.path
        self.groveConfigExists = groveConfigExists ?? { FileManager.default.fileExists(atPath: configPath) }
        self.watchRunningApps = watchRunningApps ?? Self.watchWorkspaceApps
        self.engineLock = WorkspacesEngineLock(folders: folders)
    }

    /// Decides once, then again whenever Grove.app launches or quits, or the settings
    /// that decide change — and at every background tick of the engine, in case a
    /// launch or a quit went unreported.
    public func start() {
        guard !started else { return }
        started = true
        runningAppsWatch = watchRunningApps { [weak self] in self?.refreshIfChanged() }
        // `@Published` fires in willSet: the new value is the argument, not the store's.
        store.$settings
            .map(\.workspaces)
            .removeDuplicates()
            .sink { [weak self] workspaces in
                Task { @MainActor in self?.apply(workspaces: workspaces) }
            }
            .store(in: &cancellables)
        refresh()
    }

    public func stop() {
        runningAppsWatch = nil
        quitting.removeAll()
        cancellables.removeAll()
        engine?.stopEngine()
        engine = nil
        storeWatch = nil
        errorWatch = nil
        liveWatch = nil
        previewsWatch = nil
        clearBadges()
        statusItem.hide()
        notch?.sections.unregister(.projects)
        notch?.sections.unregister(.agents)
        stopAgents()
        engineLock.release()
        started = false
    }

    /// Re-decides from the current settings, the Grove config and Grove.app.
    public func refresh() {
        apply(workspaces: store.settings.workspaces)
    }

    /// An app launched or quit: re-decides only if that changes the answer, since most
    /// of them are not Grove.
    func refreshIfChanged() {
        let decision = WorkspacesActivation.decide(setting: store.settings.workspaces.enabled,
                                                   groveConfigExists: groveConfigExists(),
                                                   groveRunning: lookForGrove())
        if decision != activation { refresh() }
    }

    /// Whether Grove.app runs now, kept in `groveRunning` for Settings.
    private func lookForGrove() -> Bool {
        let running = groveGuard.isGroveRunning
        if running != groveRunning { groveRunning = running }
        return running
    }

    private func apply(workspaces settings: WorkspacesSettings) {
        var next = WorkspacesActivation.decide(setting: settings.enabled,
                                               groveConfigExists: groveConfigExists(),
                                               groveRunning: lookForGrove())
        var waitsFor: WorkspacesPause? = next == .paused ? .groveRunning : nil
        // On in one copy of Brow at a time: the one holding the engine's lock.
        if next == .on, !engineLock.acquire() {
            next = .paused
            waitsFor = .anotherBrow
        }
        if next != .on { engineLock.release() }
        let previous = activation
        if next != previous || waitsFor != pause {
            BrowLog.workspaces.info("workspaces: \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)\(waitsFor.map { " (\($0))" } ?? "", privacy: .public)")
        }
        activation = next
        pause = waitsFor
        switch next {
        case .off:
            engine?.stopEngine()
            engine = nil
            state = nil
            accountsWatch = nil
            storeWatch = nil
            errorWatch = nil
            liveWatch = nil
            previewsWatch = nil
            clearBadges()
            store.runtimeExtraDirs = []
            pendingProjects = []
        case .paused:
            ensureEngine().stopEngine()
        case .on:
            recordFirstRunOnce()
            // Coming from paused or off, read Grove's config afresh: Grove.app may have
            // written it while Workspaces waited, and a state loaded before that would
            // save its old copy over it.
            if previous != .on, let stale = engine {
                stale.stopEngine()
                engine = nil
                state = nil
                accountsWatch = nil
                storeWatch = nil
                errorWatch = nil
                liveWatch = nil
                previewsWatch = nil
            }
            let engine = ensureEngine()
            engine.startEngine()
            // The projects picked while it waited, now that nothing else writes the config.
            if let state, !pendingProjects.isEmpty {
                let paths = pendingProjects
                pendingProjects = []
                for path in paths { state.addProject(at: path) }
            }
            // Accounts Workspaces knows outside ~/.claude and ~/.claude-accounts join the
            // notch's scan, so their limits show in the pickers too.
            if accountsWatch == nil, let state {
                accountsWatch = state.$config
                    .map { WorkspacesAccountJoin.extraDirs(for: $0.accounts) }
                    .removeDuplicates()
                    .sink { [weak store = self.store] dirs in store?.runtimeExtraDirs = dirs }
            }
        }
        syncSection()
        if next.isWanted && settings.showInMenuBar { statusItem.show() } else { statusItem.hide() }
        reloadDormantAccounts()
    }

    /// The notch has Projects and Agents sections exactly while Workspaces is wanted.
    private func syncSection() {
        guard let notch else { return }
        if activation.isWanted {
            notch.sections.register(.projects, section)
            notch.sections.register(.agents, agentsSection)
            notch.badges.openAccount = { [weak self] dir in self?.openAccount(configDir: dir) }
            watchAgents()
        } else {
            notch.sections.unregister(.projects)
            notch.sections.unregister(.agents)
            notch.badges.openAccount = nil
            stopAgents()
        }
    }

    // MARK: - Agents

    /// The notch's visible accounts as the Agents tab watches them: each with its alias
    /// folders, named and coloured as Limits shows it.
    func agentsAccounts() -> [AgentsAccount] {
        store.rows.enumerated().map { index, row in
            AgentsAccount(name: row.name, dot: NotchTheme.account(index),
                          configDirs: [row.account.configDir] + row.account.aliasDirs)
        }
    }

    /// Feeds the reader the notch's accounts, keeps them in step, and puts what it saw
    /// on the switch.
    private func watchAgents() {
        agents.setAccounts(agentsAccounts())
        agents.place = { [weak self] cwd in self?.state?.placeDescription(ofCwd: cwd) }
        guard agentsWatch.isEmpty else { return }
        // `@Published` fires in willSet: the new value is the argument.
        agents.$isLive
            .removeDuplicates()
            .sink { [weak self] live in
                MainActor.assumeIsolated {
                    guard let badges = self?.notch?.badges, badges.agentsActive != live else { return }
                    badges.agentsActive = live
                }
            }
            .store(in: &agentsWatch)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.agents.setAccounts(self.agentsAccounts())
                }
            }
            .store(in: &agentsWatch)
    }

    private func stopAgents() {
        agentsWatch.removeAll()
        agents.stop()
        if let badges = notch?.badges, badges.agentsActive { badges.agentsActive = false }
    }

    /// "Go to session" on the Agents tab: as Go on a session row — its cmux workspace, else
    /// a resume — as the Workspaces account whose folders it runs in.
    func goToSession(_ node: AgentNode) {
        guard let state, activation == .on, let sessionId = node.sessionId,
              let cwd = node.cwd ?? node.live?.cwd else { return }
        let dirs = Set((agents.account(key: node.account)?.configDirs ?? []).map(NotchBadges.key))
        let account = state.config.accounts.first { !dirs.isDisjoint(with: $0.allConfigDirs.map(NotchBadges.key)) }
            ?? state.defaultLaunchAccount
        guard let account else { return }
        SessionMenu.primary(SessionRef(sessionId: sessionId, cwd: cwd, accountName: account.name, title: node.name,
                                       isLive: node.live != nil, lastActivity: Date()),
                            state: state)
    }

    // MARK: - Status lines captured while Workspaces is not on

    /// The accounts whose status line runs Workspaces' wrapper while Workspaces is not on.
    public var dormantCaptures: [AccountConfig] { dormantAccounts.filter(\.monitoring) }

    /// What a change Settings makes to Grove's config without the engine — giving a status
    /// line back, taking out an account whose folder is gone — waits for: what a paused
    /// Workspaces waits for, or, while Workspaces is off, Grove.app, which writes the same
    /// files whether Workspaces is on or not. nil when nothing is in the way.
    public var dormantChangeBlock: WorkspacesPause? {
        switch activation {
        case .on: return nil
        case .paused: return pause ?? .groveRunning
        case .off: return groveRunning ? .groveRunning : nil
        }
    }

    /// What `account` is called where the notch shows it, with or without the engine: the
    /// name from Settings › Accounts, else Grove's own — as the engine names it.
    public func displayName(for account: AccountConfig) -> String {
        store.displayName(for: account, among: dormantAccounts)
    }

    /// Re-reads `dormantAccounts` from Grove's config. Reads only: no engine starts, and
    /// nothing is written.
    public func reloadDormantAccounts() {
        guard !isPreview else { return }
        let accounts = activation == .on || !FileManager.default.fileExists(atPath: folders.configFile.path)
            ? [] : ConfigStore(url: folders.configFile).load().config.accounts
        if accounts != dormantAccounts { dormantAccounts = accounts }
        // An account no longer listed takes what went wrong with it along.
        let kept = changeErrors.filter { name, _ in accounts.contains { $0.name == name } }
        if kept != changeErrors { changeErrors = kept }
    }

    /// What went wrong with the last change Settings made to `account` without the engine.
    public func changeError(for account: AccountConfig) -> String? {
        changeErrors[account.name]
    }

    /// What went wrong for any of `accounts`, in their order, each failure once: Give them
    /// back can fail the same way for all of them.
    public func changeErrors(for accounts: [AccountConfig]) -> [String] {
        var seen = Set<String>()
        return accounts.compactMap { changeErrors[$0.name] }.filter { seen.insert($0).inserted }
    }

    /// Gives `account`'s status line back while Workspaces is off: the command it had in
    /// place of the wrapper, in every folder of the login, and capture marked off in
    /// Grove's config so nothing turns it on again. Grove's config is read for just this,
    /// with no engine. Not while Grove.app runs, whether that pauses Workspaces or it is
    /// off: Grove.app writes the same files. While Workspaces is on, the engine's own
    /// switch does this.
    public func releaseStatusLine(_ account: AccountConfig) {
        let failure: String?
        switch activation {
        case .on:
            failure = state.flatMap { state in
                state.config.accounts.first { $0.name == account.name }.flatMap { current in
                    state.attempt { state.disableMonitoring(current) }
                }
            }
        case .paused:
            failure = Self.pausedChangeNote(pause)
        case .off:
            failure = withoutEngine { engine in
                if let current = engine.config.accounts.first(where: { $0.name == account.name }), current.monitoring {
                    engine.disableMonitoring(current)
                }
            }
        }
        changeErrors[account.name] = failure
    }

    /// Takes `account` out of Workspaces' config, folder untouched: what Settings offers
    /// for an account whose folder is gone, which nothing else can change any more.
    public func removeAccount(_ account: AccountConfig) {
        let failure: String?
        switch activation {
        case .on:
            failure = state.flatMap { state in state.attempt { state.removeAccount(name: account.name) } }
        case .paused:
            failure = Self.pausedChangeNote(pause)
        case .off:
            failure = withoutEngine { $0.removeAccount(name: account.name) }
        }
        changeErrors[account.name] = failure
    }

    /// Makes one change to Grove's config while Workspaces is off: a state read for just
    /// this, no engine started, and the dormant list read again after. Not while Grove.app
    /// runs, which writes the same config and settings.json whether Workspaces is on or
    /// off, nor under the feet of another copy of Brow whose engine runs on this config.
    /// Returns what went wrong.
    private func withoutEngine(_ change: (AppState) -> Void) -> String? {
        guard !lookForGrove() else { return Self.pausedChangeNote(.groveRunning) }
        guard engineLock.acquire() else { return Self.pausedChangeNote(.anotherBrow) }
        defer { engineLock.release() }
        let engine = AppState(folders: folders)
        engine.capturesByDefault = false
        engine.mayWrite = { [groveGuard] in !groveGuard.isGroveRunning }
        // What goes wrong names the account as Settings does.
        engine.limitsProvider = store
        let failure = engine.attempt { change(engine) }
        reloadDormantAccounts()
        return failure
    }

    /// Why Settings can't change Grove's config now: `pause` writes the same files.
    static func pausedChangeNote(_ pause: WorkspacesPause?) -> String {
        pause == .anotherBrow
            ? "Another copy of Brow runs Workspaces: make the change there, or quit it first."
            : "Quit Grove first: it writes the same settings."
    }

    /// Every captured status line back, as `releaseStatusLine` does one.
    public func releaseAllStatusLines() {
        for account in dormantCaptures { releaseStatusLine(account) }
    }

    private func ensureEngine() -> WorkspacesEngine {
        if let engine { return engine }
        let state = AppState(folders: folders)
        // Brow asks before it edits an account's settings.json: capture is turned on
        // per account, in Settings › Accounts, or kept where Grove had it on.
        state.capturesByDefault = false
        // Never two engines writing one config.json: a Grove.app that started since the
        // last decision stops every write until Workspaces has paused.
        state.mayWrite = { [groveGuard] in !groveGuard.isGroveRunning }
        // The pickers show each account's limits, from the notch's own readings.
        state.limitsProvider = store
        // Sessions launch with Brow's own router and Brow's Path to claude, like every
        // sign-in Brow starts, and as the account they say: `env -u CLAUDE_CONFIG_DIR` for
        // the default one, whatever the shell they run in exports.
        state.browserRouter = AddAccountFlow.browserHelperPath ?? state.browserRouter
        state.claudePath = { [weak store = self.store] in store.flatMap { $0.settings.claudePath ?? $0.claudeDetected } }
        // Outside the app bundle (a development build) the router is the installed Brow's.
        state.launchEnvironment = { [weak state] dir in
            AddAccountFlow.environmentPrefix(dir: dir, browser: state?.browserRouter)
        }
        state.openSettings = { [weak self] link in
            self?.notch?.dismiss(.settings)
            self?.openSettings?(link)
        }
        // Go, Resume, Start session, Show in Finder: the user is somewhere else now.
        state.onHandOff = { [weak self] in
            self?.lastHandOff = Date()
            self?.notch?.dismiss(.handOff)
        }
        state.addFolder = { [weak self] in self?.addFolder() }
        state.hostAccounts = hostAccounts()
        // The sessions that keep no record of their own, and the folders to suggest: Brow's
        // look at the kernel's process table, which the engine never takes itself.
        state.runningClaude = runningClaude
        state.showsMessagePreviews = store.settings.workspaces.showMessagePreviews
        self.state = state
        watchStore(state)
        watchLive(state)
        // An error right after a hand-off — cmux would not start, say — brings the panel
        // back, where the error is shown with its fix.
        errorWatch = state.$actionError
            .compactMap { $0 }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, let at = self.lastHandOff, Date().timeIntervalSince(at) < 15 else { return }
                    self.lastHandOff = nil
                    self.notch?.openPinned(on: .projects)
                }
            }
        let engine = WorkspacesEngine(state: state)
        // Every background tick re-checks for Grove.app first: a tick that finds it pauses
        // Workspaces instead of running.
        engine.tickGate = { [weak self] in
            guard let self else { return false }
            self.refreshIfChanged()
            return self.activation == .on
        }
        self.engine = engine
        return engine
    }

    // MARK: - Brow's accounts in the pickers

    /// The notch's visible accounts, in its order, with its names, plans and colours.
    func hostAccounts() -> [HostAccount] {
        store.rows.enumerated().map { index, row in
            HostAccount(name: row.name, plan: row.account.tier.map(PanelText.tierLabel), email: row.account.email,
                        configDirs: [row.account.configDir] + row.account.aliasDirs,
                        dot: NotchTheme.account(index))
        }
    }

    /// Keeps the pickers on the notch's accounts: a renamed, hidden, added or reordered
    /// account shows in them at once, and an account Grove does not know yet is adopted.
    private func watchStore(_ state: AppState) {
        storeWatch = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] _ in
                MainActor.assumeIsolated {
                    guard let self, let state else { return }
                    let accounts = self.hostAccounts()
                    guard accounts != state.hostAccounts else { return }
                    state.hostAccounts = accounts
                    if self.activation == .on { state.adoptHostAccounts() }
                }
            }
    }

    // MARK: - The switch's marks and the chips

    /// Keeps the switch's "needs you" count and each account's "N live" chip on what runs,
    /// and the rows' previews on what Settings says.
    private func watchLive(_ state: AppState) {
        liveWatch = state.$liveSessions
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] live in
                MainActor.assumeIsolated {
                    guard let self, let state else { return }
                    self.syncBadges(live: live, state: state)
                }
            }
        previewsWatch = store.$settings
            .map(\.workspaces.showMessagePreviews)
            .removeDuplicates()
            .sink { [weak state] on in
                MainActor.assumeIsolated { if state?.showsMessagePreviews != on { state?.showsMessagePreviews = on } }
            }
        notch?.badges.openAccount = { [weak self] dir in self?.openAccount(configDir: dir) }
    }

    /// The count of sessions that need the user, and each Brow account's live sessions by its
    /// config folder.
    func syncBadges(live: [LiveProcess], state: AppState) {
        guard let badges = notch?.badges else { return }
        let needsYou = live.filter { !$0.isAutomated && SessionState.of($0).needsYou }.count
        if badges.projectsNeedYou != needsYou { badges.projectsNeedYou = needsYou }
        var byAccount: [String: Int] = [:]
        for process in live where !process.isAutomated && !process.accountName.isEmpty {
            byAccount[process.accountName, default: 0] += 1
        }
        var byDir: [String: Int] = [:]
        for row in store.rows {
            let dirs = Set(([row.account.configDir] + row.account.aliasDirs).map(NotchBadges.key))
            let count = state.config.accounts
                .filter { !dirs.isDisjoint(with: $0.allConfigDirs.map(NotchBadges.key)) }
                .reduce(0) { $0 + (byAccount[$1.name] ?? 0) }
            if count > 0 { byDir[NotchBadges.key(row.account.configDir)] = count }
        }
        if badges.liveByConfigDir != byDir { badges.liveByConfigDir = byDir }
    }

    private func clearBadges() {
        guard let badges = notch?.badges else { return }
        if badges.projectsNeedYou != 0 { badges.projectsNeedYou = 0 }
        if !badges.liveByConfigDir.isEmpty { badges.liveByConfigDir = [:] }
    }

    /// An account's "N live" chip: Projects, narrowed to that account.
    func openAccount(configDir: String) {
        guard let state, activation == .on else { return }
        let key = NotchBadges.key(configDir)
        let row = store.rows.first { NotchBadges.key($0.account.configDir) == key }
        let dirs = Set(([configDir] + (row?.account.aliasDirs ?? [])).map(NotchBadges.key))
        guard let account = state.config.accounts.first(where: { !dirs.isDisjoint(with: $0.allConfigDirs.map(NotchBadges.key)) })
        else { return }
        state.filter(account: account.name)
        state.searchQuery = ""
        if state.route != .projects { state.open(.projects) }
        notch?.openPinned(on: .projects)
    }

    // MARK: - What the user can do

    /// Settings › Workspaces › Show message previews: rows show the newest prompt and
    /// Claude's newest line, or only the title.
    public var showsMessagePreviews: Bool {
        get { store.settings.workspaces.showMessagePreviews }
        set {
            objectWillChange.send()
            store.settings.workspaces.showMessagePreviews = newValue
        }
    }

    /// Turns Workspaces on or off in Brow's own settings.
    public func setEnabled(_ on: Bool) {
        store.settings.workspaces.enabled = on
        refresh()
    }

    /// Asks Grove.app to quit; Workspaces starts when it has — told by the app itself,
    /// as well as by the running-apps watch.
    public func quitGrove() {
        for app in NSWorkspace.shared.runningApplications where GroveAppGuard.isGrove(app.bundleIdentifier) {
            let id = ObjectIdentifier(app)
            if quitting[id] == nil {
                quitting[id] = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
                    guard app.isTerminated else { return }
                    Task { @MainActor in
                        self?.quitting[id] = nil
                        self?.refresh()
                    }
                }
            }
            app.terminate()
        }
    }

    /// One background tick of the engine, as its timer runs it; for tests.
    func backgroundTick() async {
        await engine?.runBackgroundTick()
    }

    /// Offscreen renders and tests: this state and activation, nothing started.
    func preview(state: AppState?, activation: WorkspacesActivation, dormant: [AccountConfig] = []) {
        self.state = state
        self.activation = activation
        self.dormantAccounts = dormant
        isPreview = true
        state?.hostAccounts = hostAccounts()
        syncSection()
    }

    /// A preview's accounts are its own: nothing is read from disk for it.
    private var isPreview = false

    /// Whether the engine's launch work and background cadence are running.
    var isEngineRunning: Bool { engine?.isEngineRunning == true }

    /// The notch panel, pinned on Projects: from the main menu, the menu-bar item and
    /// reopening Brow. While Workspaces is off there is no Projects section: Settings ›
    /// Workspaces opens instead, where it is turned on.
    public func showPanel() {
        // What it waits for may have gone without a word: another copy of Brow turning
        // Workspaces off quits no app.
        refreshIfChanged()
        guard activation.isWanted else {
            openSettings?(.workspaces)
            return
        }
        notch?.openPinned(on: .projects)
    }

    /// The menu-bar item: opens Projects, or closes the panel when it already shows them.
    func statusItemClicked() {
        if notch?.isShowing(.projects) == true {
            notch?.dismiss(.escape)
        } else {
            showPanel()
        }
    }

    /// "Add a folder…" and the + beside the search: the notch makes way for the system's
    /// folder picker, then opens on Projects again with the folder added.
    func addFolder() {
        guard let notch else { return }
        notch.runOutsideNotch(reopeningOn: .projects) { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Add Project"
            panel.message = "Pick the folder that contains your repositories."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self?.addProjectFolder(url.path)
        }
    }

    /// Turns Workspaces on with `path` as a project. Added at once only while the engine
    /// runs: paused, the config is another app's to write, so the folder waits in
    /// `pendingProjects` — the paused notice names it — and is added when Workspaces starts.
    func addProjectFolder(_ path: String) {
        setEnabled(true)
        if activation == .on, let state {
            state.addProject(at: path)
        } else if !pendingProjects.contains(path) {
            pendingProjects.append(path)
            refresh()   // the notice now names it
        }
    }

    // MARK: - Notices
    // Internal, not private: the README's screenshots render them.

    /// What the Projects section shows while Workspaces waits.
    var pausedNotice: WorkspacesNotice {
        pause == .anotherBrow ? anotherBrowNotice : groveRunningNotice
    }

    var groveRunningNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "pause.circle",
            title: "Grove is still running",
            message: "Grove is part of Brow now, and your Grove projects open here. They stay paused while Grove.app is open, so the two never edit the same files at once." + pendingNote,
            primary: .init("Quit Grove") { [weak self] in self?.quitGrove() })
    }

    var anotherBrowNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "pause.circle",
            title: "Projects are open in another Brow",
            message: "Another copy of Brow, a second install or a development build, is running Workspaces on the same projects. They open in one copy at a time, so the two never edit the same files at once; here, when that copy quits." + pendingNote,
            primary: .init("Try Again") { [weak self] in self?.refresh() })
    }

    /// " “shop” is added when Workspaces starts.", after a paused notice's message.
    private var pendingNote: String {
        guard !pendingProjects.isEmpty else { return "" }
        let names = pendingProjects.map { "“\(($0 as NSString).lastPathComponent)”" }
        // English, like the sentence it ends: not the Mac's list format.
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return " \(list) \(names.count == 1 ? "is" : "are") added when Workspaces starts."
    }

    // MARK: - The first run

    /// Whether Workspaces runs, or will run, a setup Grove made — for the words Settings
    /// uses. Recorded the first time it runs; before that, a Grove config can only be
    /// Grove's, since Brow writes one only once Workspaces runs.
    public var isGroveSetup: Bool {
        store.settings.workspaces.groveSetup ?? groveConfigExists()
    }

    /// The first time Workspaces runs in Brow, before the engine writes anything: whether
    /// the setup is Grove's.
    private func recordFirstRunOnce() {
        guard store.settings.workspaces.groveSetup == nil else { return }
        store.settings.workspaces.groveSetup = groveConfigExists()
    }
}
