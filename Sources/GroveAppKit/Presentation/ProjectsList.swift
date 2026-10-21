// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

// The Projects list, as data: which projects have something running and which do not,
// which of their sessions show and in what order, what a search finds. Pure, so the
// order rules are tested without a view.

/// A project as the Projects list shows it.
public struct ProjectsListEntry: Identifiable, Equatable {
    public let project: ProjectConfig
    public var id: UUID { project.id }
    /// The sessions it shows as cards: its live ones (or, with a search, every one that
    /// matches), in the list's order, at most `ProjectsListModel.maxCards` without a search.
    public let shown: [ProjectSessionRow]
    /// Sessions it has besides: "N more sessions".
    public let more: Int
    /// Live sessions stopped on the user, and working.
    public let needsYou: Int
    public let working: Int
    /// Its newest session: the one line a project with nothing running shows.
    public let newest: ProjectSessionRow?

    public init(project: ProjectConfig, shown: [ProjectSessionRow], more: Int, needsYou: Int, working: Int,
                newest: ProjectSessionRow?) {
        self.project = project
        self.shown = shown
        self.more = more
        self.needsYou = needsYou
        self.working = working
        self.newest = newest
    }
}

/// The order the list showed in when it came into view: kept while it stays in view.
public struct ProjectsOrder: Equatable, Sendable {
    /// The projects, in their sections' order.
    public var projects: [UUID]
    /// Each project's sessions, by row id.
    public var sessions: [UUID: [String]]
    /// The projects the live section held.
    public var live: Set<UUID>

    public init(projects: [UUID], sessions: [UUID: [String]], live: Set<UUID>) {
        self.projects = projects
        self.sessions = sessions
        self.live = live
    }
}

/// Every project's sessions, sorted, split and searched.
public enum ProjectsListModel {
    /// Cards a project shows on the list; "N more sessions" opens the rest.
    public static let maxCards = 3

    /// Sessions in the list's order: what needs the user first, then what works, then what
    /// waits for the next prompt, then what is closed; the most recent first within each.
    public static func sorted(_ rows: [ProjectSessionRow]) -> [ProjectSessionRow] {
        rows.sorted { ($0.state.rank, $1.lastActivity, $0.id) < ($1.state.rank, $0.lastActivity, $1.id) }
    }

    /// Whether `row` has `needle` (lowercased) in what it shows: its prompt, Claude's line,
    /// its title, its folder or workspace.
    public static func matches(_ row: ProjectSessionRow, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let fields = [row.preview?.prompt, row.preview?.reply, row.preview?.question, row.preview?.pendingInput,
                      row.title, row.location, (row.cwd as NSString).lastPathComponent, row.gitBranch]
        return fields.contains { $0?.lowercased().contains(needle) ?? false }
    }

    /// The list: projects with something running (or, with a search, something found), then
    /// those with nothing running. `rows` are each project's sessions, newest first;
    /// `counts` how many each has in all. `account` narrows to one account's sessions,
    /// `needle` (lowercased) to what matches. With `order`, the order the list opened with
    /// is kept: no project and no row moves; a session new since sits after the others.
    public static func entries(projects: [ProjectConfig], rows: [UUID: [ProjectSessionRow]], counts: [UUID: Int],
                               account: String? = nil, needle: String = "",
                               order: ProjectsOrder? = nil) -> (live: [ProjectsListEntry], quiet: [ProjectsListEntry]) {
        var live: [ProjectsListEntry] = []
        var quiet: [ProjectsListEntry] = []
        for project in projects {
            var all = rows[project.id] ?? []
            if let account { all = all.filter { $0.accountName == account } }
            let searching = !needle.isEmpty
            if searching {
                let nameMatches = project.name.lowercased().contains(needle)
                let found = nameMatches ? all : all.filter { matches($0, needle: needle) }
                guard !found.isEmpty || nameMatches else { continue }
                live.append(ProjectsListEntry(project: project, shown: arrange(found, project: project.id, order: order),
                                              more: 0, needsYou: found.filter(\.state.needsYou).count,
                                              working: found.filter { $0.state == .working }.count, newest: all.first))
                continue
            }
            let running = all.filter(\.isLive)
            let total = account == nil ? max(counts[project.id] ?? all.count, all.count) : all.count
            let wasLive = order?.live.contains(project.id)
            // While the list stays in view a project keeps its section: its last session
            // closing leaves it where it was, as a closed card.
            let liveSection = wasLive ?? !running.isEmpty
            if liveSection {
                let kept = wasLive == true
                    ? all.filter { row in running.contains(row) || (order?.sessions[project.id]?.contains(row.id) ?? false) }
                    : running
                let shown = Array(arrange(kept, project: project.id, order: order).prefix(maxCards))
                live.append(ProjectsListEntry(project: project, shown: shown, more: max(0, total - shown.count),
                                              needsYou: running.filter(\.state.needsYou).count,
                                              working: running.filter { $0.state == .working }.count,
                                              newest: all.first))
            } else if account == nil || !all.isEmpty {
                quiet.append(ProjectsListEntry(project: project, shown: [], more: total, needsYou: 0, working: 0,
                                               newest: all.first))
            }
        }
        if let order {
            let place = Dictionary(order.projects.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            func position(_ entry: ProjectsListEntry) -> Int { place[entry.id] ?? Int.max }
            live = live.enumerated().sorted { (position($0.element), $0.offset) < (position($1.element), $1.offset) }.map(\.element)
            quiet = quiet.enumerated().sorted { (position($0.element), $0.offset) < (position($1.element), $1.offset) }.map(\.element)
        } else {
            // Projects with anything that needs the user first, then working, then the rest,
            // the most recent first.
            live.sort { lhs, rhs in
                let l = (lhs.needsYou > 0 ? 0 : lhs.working > 0 ? 1 : 2), r = (rhs.needsYou > 0 ? 0 : rhs.working > 0 ? 1 : 2)
                if l != r { return l < r }
                return (lhs.shown.first?.lastActivity ?? .distantPast) > (rhs.shown.first?.lastActivity ?? .distantPast)
            }
            quiet.sort { ($0.newest?.lastActivity ?? .distantPast) > ($1.newest?.lastActivity ?? .distantPast) }
        }
        return (live, quiet)
    }

    /// `rows` sorted, or in the order the list opened with (a row it did not have after the
    /// others, sorted).
    static func arrange(_ rows: [ProjectSessionRow], project: UUID, order: ProjectsOrder?) -> [ProjectSessionRow] {
        guard let kept = order?.sessions[project] else { return sorted(rows) }
        let place = Dictionary(kept.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let known = rows.filter { place[$0.id] != nil }.sorted { place[$0.id]! < place[$1.id]! }
        return known + sorted(rows.filter { place[$0.id] == nil })
    }

    /// The order to keep while the list is in view: the one it shows now.
    public static func order(of lists: (live: [ProjectsListEntry], quiet: [ProjectsListEntry])) -> ProjectsOrder {
        let all = lists.live + lists.quiet
        return ProjectsOrder(projects: all.map(\.id),
                             sessions: Dictionary(lists.live.map { ($0.id, $0.shown.map(\.id)) }, uniquingKeysWith: { a, _ in a }),
                             live: Set(lists.live.map(\.id)))
    }
}

/// A folder of sessions outside every project: the Other folders screen's group.
public struct OtherFolder: Identifiable, Equatable, Sendable {
    public var id: String { path }
    /// The folder they ran in: the repository around it when there is one.
    public let path: String
    public let name: String
    /// Its sessions, newest first.
    public let sessions: [ClaudeSession]

    public init(path: String, sessions: [ClaudeSession]) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.sessions = sessions
    }

    /// `sessions` by the folder each ran in — the repository around it when there is one
    /// (`folder`, which may look at the disk) — the folder with the newest session first.
    public static func group(_ sessions: [ClaudeSession], folder: (String) -> String?) -> [OtherFolder] {
        var byFolder: [String: [ClaudeSession]] = [:]
        var order: [String] = []
        var resolved: [String: String] = [:]
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let path = resolved[session.cwd] ?? (folder(session.cwd) ?? session.cwd)
            resolved[session.cwd] = path
            if byFolder[path] == nil { order.append(path) }
            byFolder[path, default: []].append(session)
        }
        return order.map { OtherFolder(path: $0, sessions: byFolder[$0]!) }
    }
}
