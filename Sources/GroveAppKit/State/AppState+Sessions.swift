// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// What the session index gathers off the main actor, in one go.
struct SessionIndex: Sendable {
    var rows: [UUID: [ProjectSessionRow]]
    var counts: [UUID: Int]
    var byProject: [UUID: [ClaudeSession]]
    var other: [ClaudeSession]
    var otherFolders: [OtherFolder]
    var live: [LiveProcess]
}

extension AppState {
    // MARK: - The session index

    /// How many sessions the index reads for each project: the cards a project shows, the
    /// sessions a search finds among its recent ones, its newest prompt. A live session
    /// older than these is read as well.
    nonisolated public static let sessionsPerProjectIndex = 12

    /// The sessions of every project and outside them, with their previews and states.
    /// Cheap and independent of the git scan: it lists transcripts and reads each one's
    /// head (once) and end (when it changed), the live sessions' records and the host's
    /// processes, and the cmux hook map — all off the main actor.
    ///
    /// Also fills `externalSessionsByProject` and `otherSessions` from a disk-wide pass
    /// over the recent transcripts (the safety net's window, 90 days by default), and
    /// `otherFolders` from the latter.
    public func refreshSessionIndex() async {
        let accounts = config.accounts
        let claude = self.claude
        let liveReader = liveService
        let cmuxMap = cmux().claudeSessionWorkspaceMap(hookFile: cmuxHookFile)
        let jobs: [(id: UUID, path: String, root: String)] = config.projects.map { p in
            (p.id, expandTilde(p.path), workspacesRoot(of: p))
        }
        let sinceDays = config.transcriptMirror.maxDays
        let now = Date()
        let home = ProjectSuggestions.canonical(folders.home)
        let limit = Self.sessionsPerProjectIndex
        // Canonical roots for attributing the disk-wide pass (one syscall each).
        let projectRoots: [(id: UUID, roots: [String])] = jobs.map { job in
            (job.id, [job.path, job.root].filter { !$0.isEmpty }.map { canonicalPath($0) })
        }
        let read = beginLiveRead()
        let index = await Task.detached(priority: .utility) { () -> SessionIndex in
            let live = liveReader.allLiveProcesses(accounts: accounts)
            let owner = Self.sessionOwner(projectRoots: projectRoots)
            var rows: [UUID: [ProjectSessionRow]] = [:]
            var counts: [UUID: Int] = [:]
            for job in jobs {
                let roots = [job.path, job.root].filter { !$0.isEmpty }
                let listing = claude.sessionListing(underRoots: roots, accounts: accounts, limit: limit)
                var sessions = listing.sessions
                // A session running now is listed however old its last word.
                let canonRoots = roots.map { canonicalPath($0) }
                func under(_ cwd: String) -> Bool {
                    let canon = canonicalPath(cwd)
                    return canonRoots.contains { canon == $0 || canon.hasPrefix($0 + "/") }
                }
                for process in live where !process.sessionId.isEmpty && under(process.cwd)
                    && !sessions.contains(where: { $0.id == process.sessionId }) {
                    if let session = claude.session(id: process.sessionId, cwd: process.cwd, accounts: accounts),
                       under(session.cwd) {
                        sessions.append(session)
                    }
                }
                // One project per session: where two projects' folders overlap (one inside the
                // other, or two of one name sharing a workspaces folder) both listed it.
                let own = sessions.filter { owner($0.cwd) == job.id }
                rows[job.id] = buildProjectSessionRows(sessions: own, live: live, cmuxMap: cmuxMap,
                                                       projectPath: job.path, workspacesRoot: job.root)
                counts[job.id] = max(listing.total - (sessions.count - own.count), own.count)
            }
            // The disk-wide pass: what a project's own folder holds, and what is no
            // project's. 500 is a GLOBAL budget, newest first.
            let all = claude.allRecentSessions(accounts: accounts, limit: 500, sinceDays: sinceDays, now: now)
            var byProject: [UUID: [ClaudeSession]] = [:]
            var other: [ClaudeSession] = []
            for session in all {
                if let id = owner(session.cwd) {
                    byProject[id, default: []].append(session)
                } else {
                    other.append(session)
                }
            }
            let folders = OtherFolder.group(other) { cwd in
                ProjectSuggestions.folder(for: cwd, home: home)
            }
            return SessionIndex(rows: rows, counts: counts, byProject: byProject, other: other,
                                otherFolders: folders, live: live)
        }.value
        apply(index, liveRead: read)
    }

    /// The project a session in `cwd` belongs to: the one whose folder or workspaces folder
    /// holds it most closely, the first in the list when two hold it alike. `projectRoots`:
    /// each project's canonical folders, in the list's order.
    nonisolated static func sessionOwner(projectRoots: [(id: UUID, roots: [String])]) -> @Sendable (String) -> UUID? {
        let roots = projectRoots
        return { cwd in
            let canon = canonicalPath(cwd)
            var best: (id: UUID, length: Int)?
            for project in roots {
                for root in project.roots where canon == root || canon.hasPrefix(root + "/") {
                    if root.count > (best?.length ?? -1) { best = (project.id, root.count) }
                }
            }
            return best?.id
        }
    }

    /// Numbers a read of what runs as it starts.
    func beginLiveRead() -> Int {
        liveReadsStarted += 1
        return liveReadsStarted
    }

    /// The index's findings, published only where they changed: SwiftUI redraws what
    /// reads a published value on every assignment. `liveRead`: the number of the index's
    /// read of what runs. When a newer read has been shown since — a record written while
    /// the index listed transcripts — the index's own read is older news: its rows take
    /// their states from the newer one, which stays.
    func apply(_ index: SessionIndex, liveRead: Int? = nil) {
        let isNewest = liveRead.map { $0 > liveReadShown } ?? true
        let live = isNewest ? index.live : liveSessions
        let rows = isNewest ? index.rows : Self.restated(index.rows, live: live)
        if recentSessionsByProject != rows { recentSessionsByProject = rows }
        if sessionCountByProject != index.counts { sessionCountByProject = index.counts }
        if externalSessionsByProject != index.byProject { externalSessionsByProject = index.byProject }
        if otherSessions != index.other { otherSessions = index.other }
        if otherFolders != index.otherFolders { otherFolders = index.otherFolders }
        guard isNewest else { return }
        if let liveRead { liveReadShown = liveRead }
        if liveSessions != live { liveSessions = live }
        sessionWatch.liveChanged(live)
    }

    /// `rows` with each one's state read again from `live`.
    static func restated(_ rows: [UUID: [ProjectSessionRow]], live: [LiveProcess]) -> [UUID: [ProjectSessionRow]] {
        rows.mapValues { list in
            list.map { row in
                let state = SessionState.of(live.liveProcess(forSessionId: row.sessionId, cwd: row.cwd), turn: row.preview?.turn)
                return state == row.state ? row : row.with(state: state, preview: row.preview, lastActivity: row.lastActivity)
            }
        }
    }

    /// The expanded workspaces folder of `project`.
    func workspacesRoot(of project: ProjectConfig) -> String {
        expandTilde(project.workspacesRoot
            ?? config.workspacesRootTemplate.replacingOccurrences(of: "{project}", with: project.name))
    }

    // MARK: - The live layer

    /// What runs now, read again (the records, the host's processes): every row's state in
    /// place, the "needs you" count and the chips. A session that started running and is
    /// not listed yet asks the index again. Cheap: a few small files and the kernel.
    public func refreshLive() async {
        let accounts = config.accounts
        let reader = liveService
        let read = beginLiveRead()
        let live = await Task.detached(priority: .userInitiated) { reader.allLiveProcesses(accounts: accounts) }.value
        applyLive(live, read: read)
    }

    /// `read`: the read's number (`beginLiveRead`); one older than what is shown — two reads
    /// at once, the older finishing last — changes nothing.
    func applyLive(_ live: [LiveProcess], read: Int? = nil) {
        if let read {
            guard read > liveReadShown else { return }
            liveReadShown = read
        }
        if liveSessions != live { liveSessions = live }
        sessionWatch.liveChanged(live)
        let next = Self.restated(recentSessionsByProject, live: live)
        if next != recentSessionsByProject { recentSessionsByProject = next }
        let listed = Set(next.values.flatMap { $0.map(\.sessionId) } + otherSessions.map(\.id))
        if live.contains(where: { !$0.sessionId.isEmpty && !listed.contains($0.sessionId) && !$0.isAutomated }) {
            sessionWatch.indexSoon()
        }
    }

    /// The newest previews of the sessions that run: each live row's transcript looked at
    /// (a `stat`), and read again from its end only when it changed.
    public func refreshPreviews() async {
        let claude = self.claude
        let rows = recentSessionsByProject.values.flatMap { $0 }.filter { $0.isLive && $0.transcriptPath != nil }
        guard !rows.isEmpty else { return }
        let paths = rows.compactMap(\.transcriptPath)
        let fresh = await Task.detached(priority: .utility) { () -> [String: (SessionPreview?, Date)] in
            var out: [String: (SessionPreview?, Date)] = [:]
            for path in paths {
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { continue }
                out[path] = (claude.preview(ofTranscriptAt: path), modified)
            }
            return out
        }.value
        var next = recentSessionsByProject
        for (id, list) in next {
            next[id] = list.map { row in
                guard let path = row.transcriptPath, let (preview, modified) = fresh[path],
                      preview != row.preview || modified != row.lastActivity else { return row }
                let state = SessionState.of(liveSessions.liveProcess(forSessionId: row.sessionId, cwd: row.cwd),
                                            turn: preview?.turn)
                return row.with(state: state, preview: preview, lastActivity: modified)
            }
        }
        if next != recentSessionsByProject { recentSessionsByProject = next }
    }

    /// A session's state for a screen that lists it from the disk-wide pass (the project's
    /// own folder, the other folders): the one mapping, from what runs now.
    public func state(of session: ClaudeSession) -> SessionState {
        SessionState.of(liveSessions.liveProcess(forSessionId: session.id, cwd: session.cwd), turn: session.preview?.turn)
    }

    /// Sessions stopped on the user — a permission to give, a question to answer — across
    /// every account: the yellow count on the switch. An SDK's runs and background jobs
    /// left out.
    public var needsYouCount: Int {
        liveSessions.filter { !$0.isAutomated && SessionState.of($0).needsYou }.count
    }

    /// Sessions stopped on the user in a folder no project shows yet: the suggestion's row
    /// says so, so the switch's count is never a number nothing on the list explains.
    public func needsYou(in suggestion: ProjectSuggestion) -> Int {
        let pids = Set(suggestion.pids)
        return liveSessions.filter { pids.contains($0.pid) && !$0.isAutomated && SessionState.of($0).needsYou }.count
    }

    /// Sessions stopped on the user among `folders`' (outside every project), less the ones a
    /// suggestion's row already shows: what the Other folders row says.
    public func needsYou(in folders: [OtherFolder]) -> Int {
        let suggested = Set(listedSuggestions.flatMap(\.pids))
        let ids = Set(folders.flatMap { $0.sessions.map(\.id) })
        return liveSessions.filter {
            ids.contains($0.sessionId) && !suggested.contains($0.pid) && !$0.isAutomated && SessionState.of($0).needsYou
        }.count
    }

    /// The sessions running as each account, by its name in Grove's config: the "N live"
    /// chips on Limits.
    public var liveCountByAccount: [String: Int] {
        Dictionary(liveSessions.filter { !$0.isAutomated && !$0.accountName.isEmpty }.map { ($0.accountName, 1) },
                   uniquingKeysWith: +)
    }

    // MARK: - The Projects list

    /// The list as it shows now: the account filter and the search applied, in the order it
    /// opened with while it stays in view.
    public var projectsList: (live: [ProjectsListEntry], quiet: [ProjectsListEntry]) {
        ProjectsListModel.entries(projects: config.projects, rows: recentSessionsByProject, counts: sessionCountByProject,
                                  account: accountFilter, needle: searchNeedle, order: frozenOrder)
    }

    /// Keeps the list's order while it is in view: called as it comes into view.
    public func freezeOrder() {
        frozenOrder = nil
        frozenOrder = ProjectsListModel.order(of: projectsList)
    }

    /// The list may sort again: it left the view.
    public func thawOrder() {
        if frozenOrder != nil { frozenOrder = nil }
    }

    /// The other folders' sessions the search finds (all of them without one), the account
    /// filter applied.
    public func listedOtherFolders() -> [OtherFolder] {
        otherFolders.compactMap { folder in
            let kept = folder.sessions.filter { session in
                (accountFilter == nil || session.accountName == accountFilter)
                    && (searchNeedle.isEmpty || Self.matches(session, needle: searchNeedle)
                        || folder.name.lowercased().contains(searchNeedle))
            }
            return kept.isEmpty ? nil : OtherFolder(path: folder.path, sessions: kept)
        }
    }

    /// Whether a session from the disk-wide pass shows `needle` (lowercased).
    static func matches(_ session: ClaudeSession, needle: String) -> Bool {
        let fields = [session.preview?.prompt, session.preview?.reply, session.title,
                      (session.cwd as NSString).lastPathComponent]
        return fields.contains { $0?.lowercased().contains(needle) ?? false }
    }

    /// What the search finds: sessions of the projects and of the other folders.
    public var searchMatchCount: Int {
        projectsList.live.reduce(0) { $0 + $1.shown.count } + listedOtherFolders().reduce(0) { $0 + $1.sessions.count }
    }

    // MARK: - Narrowing to one account

    /// Shows only `account`'s sessions (its name in Grove's config), and the folders it
    /// runs in: an account's "N live" chip.
    public func filter(account: String?) {
        if accountFilter != account { accountFilter = account }
        keyboardFocus = nil
    }

    // MARK: - Suggestions

    /// The folders the system's temporary folders are: never a project. Tests make theirs
    /// count.
    nonisolated static let defaultTemporaryRoots = ProjectSuggestions.temporaryRoots

    /// Looks at the processes again (the host's look, `runningClaude`) for folders Claude
    /// Code runs in that no project shows: not the projects' own or their workspaces', not
    /// noise, not one turned down, not an SDK's or a background job's.
    public func refreshSuggestions() async {
        guard let running = runningClaude else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let dirs = config.accounts.flatMap(\.allConfigDirs).map(expandTilde)
        let covered = config.projects.flatMap { [expandTilde($0.path), workspacesRoot(of: $0)] }
        let dismissed = Set(config.dismissedSuggestions)
        let home = folders.home
        let temporary = suggestionTemporaryRoots
        let found = await Task.detached(priority: .utility) { () -> [ProjectSuggestion] in
            let processes = running()
            let pids = Set(processes.map(\.pid))
            let automated = Set(dirs.flatMap { SessionRegistry.sessions(configDir: $0) }
                .filter { pids.contains($0.pid) && LiveProcess(record: $0, accountName: "").isAutomated }
                .map(\.pid))
            return ProjectSuggestions.suggest(running: processes, automated: automated, covered: covered,
                                              dismissed: dismissed, home: home, temporaryRoots: temporary)
        }.value
        if found != suggestions { suggestions = found }
    }

    /// The suggestions the list offers, the account filter applied.
    public var listedSuggestions: [ProjectSuggestion] {
        guard let accountFilter, let account = config.accounts.first(where: { $0.name == accountFilter }) else {
            return suggestions
        }
        let dirs = Set(account.allConfigDirs.map(Self.normalizedDir))
        return suggestions.filter { !dirs.isDisjoint(with: $0.configDirs.map(Self.normalizedDir)) }
    }

    /// The account a suggestion's sessions run as, as a picker names it; nil when it is no
    /// account Workspaces knows.
    public func account(ofConfigDir dir: String) -> WorkspacesAccount? {
        let normalized = Self.normalizedDir(dir)
        guard let config = config.accounts.first(where: { $0.allConfigDirs.map(Self.normalizedDir).contains(normalized) })
        else { return nil }
        return workspacesAccount(named: config.name)
    }

    /// A folder as a row writes it: `~/Code/harbor-api`.
    public func displayPath(_ path: String) -> String {
        for home in [folders.home, NSHomeDirectory()] where !home.isEmpty {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    /// "acme-shop › checkout-redesign": the project a folder is in and its place there (a
    /// workspace, a repository); the project alone at its own folder; nil outside every
    /// project. What the Agents tab writes under a session.
    public func placeDescription(ofCwd cwd: String) -> String? {
        guard let project = owningProject(forCwd: cwd) else { return nil }
        let path = canonicalPath(cwd)
        let projectPath = canonicalPath(expandTilde(project.path))
        if path == projectPath { return project.name }
        let place = sessionPlace(cwd: cwd, branch: nil, projectPath: projectPath,
                                 workspacesRoot: canonicalPath(workspacesRoot(of: project)))
        return project.name + " › " + place
    }

    /// Adds a suggested folder as a project: it moves into the list with its sessions.
    public func addSuggestion(_ suggestion: ProjectSuggestion) {
        addProject(at: suggestion.path)
        suggestions.removeAll { $0.path == suggestion.path }
        Task { await refreshSessionIndex() }
    }

    /// "Not now": the folder is never offered again.
    public func dismissSuggestion(_ suggestion: ProjectSuggestion) {
        if !config.dismissedSuggestions.contains(suggestion.path) {
            config.dismissedSuggestions.append(suggestion.path)
            persist()
        }
        suggestions.removeAll { $0.path == suggestion.path }
    }

    /// Adds an other folder as a project.
    public func addFolderAsProject(_ folder: OtherFolder) {
        addProject(at: folder.path)
        Task { await refreshSessionIndex() }
    }
}
