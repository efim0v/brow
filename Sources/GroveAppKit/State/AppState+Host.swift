// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Foundation
import SwiftUI
import GroveCore

/// One of the host's accounts, as the host shows it: Brow's notch and Settings › Accounts.
public struct HostAccount: Equatable, Sendable {
    /// What the user called it (else its email).
    public var name: String
    /// "Max 20x"; nil when the host does not know.
    public var plan: String?
    /// The login's email, which names the account in Grove's config.
    public var email: String?
    /// Its config folder first, then the other folders signed in to the same organisation.
    public var configDirs: [String]
    /// The colour the host draws it in: a dot before its name.
    public var dot: Color?

    public init(name: String, plan: String?, email: String?, configDirs: [String], dot: Color?) {
        self.name = name
        self.plan = plan
        self.email = email
        self.configDirs = configDirs
        self.dot = dot
    }
}

/// An account as Workspaces offers it in a picker: the host's account, joined to the entry
/// in Grove's config that shares a folder with it. Grove's entry is the key every session,
/// project default and launch carries; the name, the plan and the colour are the host's.
public struct WorkspacesAccount: Identifiable, Equatable {
    public var id: String { config.name }
    public let config: AccountConfig
    public let name: String
    public let plan: String?
    public let dot: Color?
}

extension AppState {
    // MARK: - Accounts

    /// The accounts every picker lists. With a host: the host's visible accounts in its
    /// order, each joined to its entry in Grove's config — an account only Grove knows stays
    /// in the config for its old sessions, but is never offered. Without a host: Grove's own.
    public var accounts: [WorkspacesAccount] {
        guard let hostAccounts else {
            return config.accounts.map {
                WorkspacesAccount(config: $0, name: displayName(for: $0), plan: plan(for: $0), dot: nil)
            }
        }
        var seen = Set<String>()
        return hostAccounts.compactMap { host in
            let dirs = Set(host.configDirs.map(Self.normalizedDir))
            guard let config = config.accounts.first(where: { !dirs.isDisjoint(with: $0.allConfigDirs.map(Self.normalizedDir)) }),
                  seen.insert(config.name).inserted else { return nil }
            return WorkspacesAccount(config: config, name: host.name, plan: host.plan, dot: host.dot)
        }
    }

    /// The picker's entry for an account by its name in Grove's config.
    public func workspacesAccount(named name: String) -> WorkspacesAccount? {
        accounts.first { $0.config.name == name }
    }

    /// The host's dot for an account by its name in Grove's config; nil without one.
    public func dot(forAccountNamed name: String) -> Color? {
        workspacesAccount(named: name)?.dot
    }

    /// An account as a picker lists it: "Resume as Work — 5h 42% · week 61%".
    public func menuTitle(_ verb: String, _ account: WorkspacesAccount) -> String {
        let base = verb.isEmpty ? account.name : "\(verb) \(account.name)"
        guard let label = limits(for: account.config)?.label else { return base }
        return "\(base) — \(label)"
    }

    /// Adds to Grove's config every host account it does not know yet, named by its email
    /// as the engine names accounts, so it can be picked and launched as. Returns whether
    /// anything was added. Folders of an account Grove knows by another folder join it.
    @discardableResult
    public func adoptHostAccounts() -> Bool {
        guard let hostAccounts else { return false }
        var added = false
        for host in hostAccounts {
            let dirs = host.configDirs.map(Self.normalizedDir)
            guard let first = dirs.first else { continue }
            let known = config.accounts.contains { !Set(dirs).isDisjoint(with: $0.allConfigDirs.map(Self.normalizedDir)) }
            guard !known else { continue }
            let folder = (first as NSString).lastPathComponent
            let name = AccountNaming.uniqueName(email: host.email ?? folder, folder: folder,
                                                taken: Set(config.accounts.map(\.name)))
            config.accounts.append(AccountConfig(name: name, configDir: Self.storedDir(first),
                                                 aliasDirs: dirs.dropFirst().map(Self.storedDir)))
            added = true
        }
        if added { persist() }
        return added
    }

    /// `/Users/me/.claude-accounts/work` → `~/.claude-accounts/work`, as Grove's config writes
    /// folders in the home.
    static func storedDir(_ dir: String) -> String {
        let home = NSHomeDirectory()
        return dir == home ? "~" : dir.hasPrefix(home + "/") ? "~" + dir.dropFirst(home.count) : dir
    }

    static func normalizedDir(_ path: String) -> String {
        var dir = expandTilde(path)
        if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }

    // MARK: - Handing off

    /// The user is being taken somewhere else: a host showing these screens in a panel
    /// closes it.
    func handOff() { onHandOff?() }

    /// Esc, or the host's back: the screen in front goes back one, unless it cannot be left
    /// now (`blocksBack`). False at the root, where there is nothing to go back to.
    public func goBackForKey() -> Bool {
        if confirmingDelete != nil {
            confirmingDelete = nil
            return true
        }
        if blocksBack { return true }
        guard route != .projects else { return false }
        goBack()
        return true
    }

    /// Whether opening the panel should refresh: not when the last refresh finished less than
    /// 10 s ago — the notch opens on every pass of the pointer.
    public func needsRefreshOnOpen(now: Date = Date()) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= 10
    }

    // MARK: - A session's menu

    /// Copies the session's id.
    public func copySessionID(_ sessionId: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionId, forType: .string)
    }

    /// Where the session's transcript is: under its own account's folders first, then any
    /// account's; nil when none holds it.
    public func transcriptPath(sessionId: String, cwd: String, accountName: String) -> String? {
        let own = config.accounts.first { $0.name == accountName }
        let dirs = (own?.allConfigDirs ?? []) + config.accounts.flatMap(\.allConfigDirs)
        let folder = ClaudeService.mangle(cwd)
        for dir in dirs.map(expandTilde) {
            let path = dir + "/projects/" + folder + "/" + sessionId + ".jsonl"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Shows the transcript in Finder, selected. A hand-off.
    public func revealTranscript(sessionId: String, cwd: String, accountName: String) {
        guard let path = transcriptPath(sessionId: sessionId, cwd: cwd, accountName: accountName) else {
            actionError = "The transcript of this session is not on this Mac any more."
            return
        }
        handOff()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - The Projects list, and the keyboard on it

    /// How many sessions a project shows on the Projects list, and how many the session index
    /// reads for it.
    nonisolated public static let sessionsPerProject = 3

    /// The search, as the lists compare it: trimmed, lowercased; empty when there is none.
    var searchNeedle: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The projects the list shows, in its order: every one, or those the search finds by
    /// name or by one of their sessions.
    public var listedProjects: [ProjectConfig] {
        let needle = searchNeedle
        guard !needle.isEmpty else { return config.projects }
        return config.projects.filter { project in
            project.name.lowercased().contains(needle) || !listedSessions(of: project).isEmpty
        }
    }

    /// A project's sessions as the list shows them: the newest, at most
    /// `sessionsPerProject`; with a search, the ones it finds (all of them when the project's
    /// own name matches).
    public func listedSessions(of project: ProjectConfig) -> [ProjectSessionRow] {
        let rows = recentSessionsByProject[project.id] ?? []
        let needle = searchNeedle
        let found = needle.isEmpty || project.name.lowercased().contains(needle)
            ? rows
            : rows.filter { $0.title.lowercased().contains(needle) || $0.location.lowercased().contains(needle) }
        return Array(found.prefix(Self.sessionsPerProject))
    }

    /// Every session the list shows, top to bottom: what ↑ and ↓ walk.
    public var listedSessionOrder: [ProjectSessionRow] {
        listedProjects.flatMap(listedSessions(of:))
    }

    /// The session the keyboard is on, while it is still listed.
    public var focusedSessionRow: ProjectSessionRow? {
        guard let keyboardFocus else { return nil }
        return listedSessionOrder.first { $0.id == keyboardFocus }
    }

    /// ↑ (−1) or ↓ (+1): the focus ring moves through the listed sessions; the first press
    /// puts it on the first (↓) or last (↑).
    public func moveKeyboardFocus(by delta: Int) {
        let order = listedSessionOrder
        guard !order.isEmpty else { keyboardFocus = nil; return }
        guard let current = keyboardFocus, let index = order.firstIndex(where: { $0.id == current }) else {
            keyboardFocus = (delta < 0 ? order.last : order.first)?.id
            return
        }
        keyboardFocus = order[min(max(index + delta, 0), order.count - 1)].id
    }
}
