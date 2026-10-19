// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// What a session's menu needs to know about the session, whichever row draws it: the
/// Projects list, a project's folder, a workspace, a loose worktree, the other folders.
public struct SessionRef: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    /// The account the session belongs to, by its name in Grove's config.
    public let accountName: String
    public let title: String
    public let isLive: Bool
    /// The cmux workspace showing it, when known.
    public let cmuxWorkspaceId: String?
    public let lastActivity: Date

    public init(sessionId: String, cwd: String, accountName: String, title: String, isLive: Bool,
                cmuxWorkspaceId: String? = nil, lastActivity: Date) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.accountName = accountName
        self.title = title
        self.isLive = isLive
        self.cmuxWorkspaceId = cmuxWorkspaceId
        self.lastActivity = lastActivity
    }

    public init(row: ProjectSessionRow) {
        self.init(sessionId: row.sessionId, cwd: row.cwd, accountName: row.accountName, title: row.title,
                  isLive: row.isLive, cmuxWorkspaceId: row.cmuxWorkspaceId, lastActivity: row.lastActivity)
    }

    public init(session: ClaudeSession, isLive: Bool, cmuxWorkspaceId: String? = nil) {
        self.init(sessionId: session.id, cwd: session.cwd, accountName: session.accountName,
                  title: session.title ?? String(session.id.prefix(8)), isLive: isLive,
                  cmuxWorkspaceId: cmuxWorkspaceId, lastActivity: session.lastActivity)
    }

    /// The session as the engine's resume and go actions take it.
    var session: ClaudeSession {
        ClaudeSession(id: sessionId, cwd: cwd, title: title, lastActivity: lastActivity,
                      accountName: accountName, gitBranch: nil)
    }
}

/// One item of a session's menu, as data: the live menu and an offscreen render of it draw
/// the same list.
public struct SessionMenuItem: Identifiable {
    public enum Kind {
        case action
        case submenu([SessionMenuItem])
        case separator
    }

    public let id: String
    public let title: String
    /// "↩", "⌘↩".
    public let shortcut: String?
    /// An account's limits, "5h 41% · week 93%".
    public let detail: String?
    /// An account's colour.
    public let dot: Color?
    public let destructive: Bool
    public let enabled: Bool
    public let kind: Kind
    let perform: @MainActor () -> Void

    init(id: String, title: String, shortcut: String? = nil, detail: String? = nil, dot: Color? = nil,
         destructive: Bool = false, enabled: Bool = true, kind: Kind = .action,
         perform: @escaping @MainActor () -> Void = {}) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.detail = detail
        self.dot = dot
        self.destructive = destructive
        self.enabled = enabled
        self.kind = kind
        self.perform = perform
    }

    static func separator(_ id: String) -> SessionMenuItem { SessionMenuItem(id: id, title: "", kind: .separator) }
}

/// Everything the project's Claude tab could do to a session, on the session itself.
@MainActor
public enum SessionMenu {
    public static func items(for ref: SessionRef, state: AppState,
                             onAskDelete: @escaping @MainActor () -> Void) -> [SessionMenuItem] {
        let owner = state.config.accounts.first { $0.name == ref.accountName }
        let others = state.accounts.filter { $0.config.name != ref.accountName }
        var items: [SessionMenuItem] = []
        items.append(SessionMenuItem(id: "primary", title: ref.isLive ? "Go" : "Resume", shortcut: "↩") {
            primary(ref, state: state)
        })
        items.append(SessionMenuItem(id: "options", title: "Resume with options…", shortcut: "⌘↩",
                                     enabled: !ref.isLive) {
            state.beginConfigure(session: ref.session)
        })
        if !ref.isLive, !others.isEmpty {
            items.append(SessionMenuItem(id: "resume-as", title: "Resume as", kind: .submenu(others.map { account in
                SessionMenuItem(id: "resume-as-" + account.id, title: account.name,
                                detail: state.limits(for: account.config)?.label, dot: account.dot) {
                    Task { await state.resumeSession(ref.session, as: account.config) }
                }
            })))
        }
        if let owner, AppState.canShareAcrossAccounts(account: owner, canonicalDir: state.canonicalDir) {
            items.append(SessionMenuItem(id: "share", title: "Share with all accounts") {
                Task { await state.adoptSession(cwd: ref.cwd, sessionId: ref.sessionId, account: owner) }
            })
        }
        if let owner, !others.isEmpty {
            items.append(SessionMenuItem(id: "copy-to", title: "Copy to account", kind: .submenu(others.map { account in
                SessionMenuItem(id: "copy-to-" + account.id, title: account.name,
                                detail: state.limits(for: account.config)?.label, dot: account.dot) {
                    Task { await state.migrateSession(cwd: ref.cwd, sessionId: ref.sessionId, from: owner, to: account.config) }
                }
            })))
        }
        items.append(SessionMenuItem(id: "copy-id", title: "Copy session ID") { state.copySessionID(ref.sessionId) })
        items.append(SessionMenuItem(id: "reveal", title: "Show transcript in Finder") {
            state.revealTranscript(sessionId: ref.sessionId, cwd: ref.cwd, accountName: ref.accountName)
        })
        items.append(.separator("before-delete"))
        // Not under a running session: its process still writes the file.
        items.append(SessionMenuItem(id: "delete", title: "Delete transcript…", destructive: true,
                                     enabled: !ref.isLive) { onAskDelete() })
        return items
    }

    /// Delete transcript…, once the row has asked: the transcript is gone for good, from the
    /// account's folders and the safety net alike.
    public static func delete(_ ref: SessionRef, state: AppState) {
        state.purgeTranscript(id: ref.sessionId)
    }

    /// ↩ on a session: Go to it while it runs, Resume it as its own account when it does not.
    public static func primary(_ ref: SessionRef, state: AppState) {
        if ref.isLive {
            let row = ProjectSessionRow(sessionId: ref.sessionId, title: ref.title, cwd: ref.cwd,
                                        location: (ref.cwd as NSString).lastPathComponent,
                                        accountName: ref.accountName, lastActivity: ref.lastActivity,
                                        state: .working, cmuxWorkspaceId: ref.cmuxWorkspaceId)
            Task { await state.openSession(row) }
        } else {
            let account = state.config.accounts.first { $0.name == ref.accountName }
                ?? state.defaultLaunchAccount
                ?? AccountConfig(name: "default", configDir: "~/.claude")
            Task { await state.resumeSession(ref.session, as: account) }
        }
    }
}

/// The ••• button that opens a session's menu. Offscreen, where a `Menu` draws as a
/// placeholder, a still glyph.
struct SessionActionsMenu: View {
    @ObservedObject var state: AppState
    let ref: SessionRef
    let onAskDelete: () -> Void
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        if isSnapshotRender {
            SessionMenuGlyph()
        } else {
            Menu {
                SessionMenuContent(items: SessionMenu.items(for: ref, state: state, onAskDelete: onAskDelete))
            } label: {
                SessionMenuGlyph()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this session")
            .accessibilityLabel("More for this session")
        }
    }
}

/// "•••" in a small circle.
struct SessionMenuGlyph: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(0.08)))
            .contentShape(Circle())
    }
}

/// The items as menu content: buttons, submenus, separators. The account's limits follow
/// its name, as every picker writes them.
struct SessionMenuContent: View {
    let items: [SessionMenuItem]

    var body: some View {
        ForEach(items) { item in
            switch item.kind {
            case .separator:
                Divider()
            case .submenu(let children):
                Menu(item.title) { SessionMenuContent(items: children) }
                    .disabled(!item.enabled)
            case .action:
                Button(role: item.destructive ? .destructive : nil) { item.perform() } label: {
                    Text(item.detail.map { "\(item.title) — \($0)" } ?? item.title)
                }
                .disabled(!item.enabled)
            }
        }
    }
}

/// Delete, asked in the card itself: no dialog, nothing that covers the panel.
struct DeleteTranscriptConfirm: View {
    let onDelete: () -> Void
    let onCancel: () -> Void
    @Environment(\.groveAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Text("Delete this transcript?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onDelete) {
                Text("Delete").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.27, blue: 0.24)))
            }
            .buttonStyle(.plain)
            Button(action: onCancel) {
                Text("Cancel").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete this transcript? It cannot be undone.")
    }
}
