// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

// Pure presentation for the sessions the Projects list and a project show: joins the
// session index with the live sessions (by id: one process runs one session) and the cmux
// hook map, for a state (`SessionState`, the one mapping), a preview of how the
// conversation ends, a place and a Go target.

/// One session as a list shows it.
public struct ProjectSessionRow: Sendable, Equatable, Identifiable {
    public var id: String { cwd + "\u{0}" + sessionId }
    public let sessionId: String
    /// Claude Code's name for it: the one given with `/rename`, else the generated one,
    /// else the newest prompt; the id's first characters when there is none.
    public let title: String
    public let cwd: String
    /// Where it runs, as the row writes it: the workspace, the loose worktree's folder, or
    /// the git branch for a session in the project's own folder.
    public let location: String
    public let accountName: String
    public let lastActivity: Date
    public let state: SessionState
    /// cmux workspace hosting the session, if any — present -> "Go", nil -> "Resume".
    public let cmuxWorkspaceId: String?
    /// How its transcript ends: the newest prompt, Claude's newest line, what it waits on.
    public let preview: SessionPreview?
    public let gitBranch: String?

    public var canGo: Bool { cmuxWorkspaceId != nil }
    public var isLive: Bool { state.isLive }

    public init(sessionId: String, title: String, cwd: String, location: String,
                accountName: String, lastActivity: Date, state: SessionState,
                cmuxWorkspaceId: String?, preview: SessionPreview? = nil, gitBranch: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.location = location
        self.accountName = accountName
        self.lastActivity = lastActivity
        self.state = state
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.preview = preview
        self.gitBranch = gitBranch
    }

    /// The same row in another state: the live layer updates rows in place.
    public func with(state: SessionState, preview: SessionPreview?, lastActivity: Date) -> ProjectSessionRow {
        ProjectSessionRow(sessionId: sessionId, title: title, cwd: cwd, location: location, accountName: accountName,
                          lastActivity: lastActivity, state: state, cmuxWorkspaceId: cmuxWorkspaceId,
                          preview: preview, gitBranch: gitBranch)
    }
}

/// Joins `sessions` with the `live` sessions (by id) and the cmux hook `cmuxMap`, for a
/// state, a place and a Go target. A session no process runs is closed. `projectPath`
/// and `workspacesRoot` (expanded) name the places: a workspace by its folder under the
/// root, the project's own folder by its branch.
public func buildProjectSessionRows(sessions: [ClaudeSession], live: [LiveProcess],
                                    cmuxMap: [String: String], projectPath: String? = nil,
                                    workspacesRoot: String? = nil) -> [ProjectSessionRow] {
    let root = workspacesRoot.map(canonicalPath)
    let project = projectPath.map(canonicalPath)
    return sessions.map { s in
        let process = live.liveProcess(forSessionId: s.id, cwd: s.cwd)
        let title = s.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? s.preview?.title ?? s.preview?.prompt ?? String(s.id.prefix(8))
        let branch = s.gitBranch
        return ProjectSessionRow(
            sessionId: s.id,
            title: title,
            cwd: s.cwd,
            location: sessionPlace(cwd: s.cwd, branch: branch, projectPath: project, workspacesRoot: root),
            accountName: process?.accountName.isEmpty == false ? process!.accountName : s.accountName,
            lastActivity: s.lastActivity,
            state: SessionState.of(process, turn: s.preview?.turn),
            cmuxWorkspaceId: cmuxMap[s.id],
            preview: s.preview,
            gitBranch: branch)
    }
}

/// Where a session runs, in a word: its workspace (the folder under the workspaces root),
/// the git branch when it runs in the project's own folder, else its folder's name.
/// `projectPath` and `workspacesRoot` are canonical.
public func sessionPlace(cwd: String, branch: String?, projectPath: String?, workspacesRoot: String?) -> String {
    let path = canonicalPath(cwd)
    if let root = workspacesRoot, path.hasPrefix(root + "/") {
        if let workspace = path.dropFirst(root.count + 1).split(separator: "/").first { return String(workspace) }
    }
    if let projectPath, path == projectPath, let branch, !branch.isEmpty { return branch }
    return (cwd as NSString).lastPathComponent
}
