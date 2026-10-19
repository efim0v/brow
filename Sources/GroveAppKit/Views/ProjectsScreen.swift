// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import AppKit
import GroveCore

/// The Projects list: one section per project — its name and counts, a header that opens
/// it, and its newest sessions — then the sessions outside every project. With no project
/// yet, what a project is and the way to add one.
struct ProjectsTab: View {
    @ObservedObject var state: AppState
    @Environment(\.groveAccent) private var accent

    var body: some View {
        if state.config.projects.isEmpty {
            ProjectsEmptyState(state: state)
        } else {
            FadingScrollView {
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            let projects = state.listedProjects
            if projects.isEmpty {
                Text("Nothing matches “\(state.searchQuery)”.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            ForEach(projects) { project in
                projectSection(project)
            }
            if !state.otherSessions.isEmpty, state.searchNeedle.isEmpty {
                otherSessionsRow
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func projectSection(_ project: ProjectConfig) -> some View {
        let rows = state.listedSessions(of: project)
        let all = state.recentSessionsByProject[project.id] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Button { state.open(.project(project.id)) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let snapshot = state.snapshots[project.id] {
                        Text("\(snapshot.repos.count) repos · \(snapshot.workspaces.count) ws")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    let running = all.filter { $0.state == .working }.count
                    if running > 0 {
                        Text("\(running) running").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.path)
            .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(state.searchNeedle.isEmpty ? "No recent Claude sessions" : "No session matches")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            ForEach(rows) { row in
                SessionLineRow(state: state, ref: SessionRef(row: row), status: row.state,
                               place: row.location, focused: state.keyboardFocus == row.id)
            }
        }
    }

    /// The sessions whose folder is no project's.
    private var otherSessionsRow: some View {
        Button { state.open(.otherSessions) } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Other sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(state.otherSessions.count) outside your projects")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// No project yet: what a project is, and the way to add one.
struct ProjectsEmptyState: View {
    @ObservedObject var state: AppState
    @Environment(\.groveAccent) private var accent

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent)
            Text("No projects yet").font(.system(size: 15, weight: .semibold))
            Text("A project is a folder of repositories you work in with Claude Code. Its sessions show up here, with what was said last.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Button { addFolder() } label: {
                Text("Add a folder…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255))
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func addFolder() {
        if let addFolder = state.addFolder { addFolder(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            state.addProject(at: url.path)
        }
    }
}

/// One session in a list: what state it is in, its title, where it runs and as whom, and
/// Go or Resume with the rest of its menu. Delete asks in the row itself.
struct SessionLineRow: View {
    @ObservedObject var state: AppState
    let ref: SessionRef
    let status: SessionState
    /// The workspace, worktree or folder the session runs in.
    let place: String
    var focused = false
    @Environment(\.groveAccent) private var accent

    private var askingDelete: Bool { state.confirmingDelete == ref.sessionId }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SessionStatusGlyph(status: status)
            VStack(alignment: .leading, spacing: 3) {
                Text(ref.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                // Asked, the question takes the meta's line, the row's whole width: the title
                // stays readable above it.
                if askingDelete {
                    DeleteTranscriptConfirm(onDelete: {
                        state.confirmingDelete = nil
                        SessionMenu.delete(ref, state: state)
                    }, onCancel: { state.confirmingDelete = nil })
                } else {
                    meta
                }
            }
            if !askingDelete {
                Spacer(minLength: 8)
                Text(relativeAge(ref.lastActivity, now: Date()))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                Button { SessionMenu.primary(ref, state: state) } label: {
                    Text(ref.isLive ? "Go" : "Resume")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(ref.isLive ? Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255) : .white)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(ref.isLive ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.10))))
                }
                .buttonStyle(.plain)
                .help(ref.isLive ? "Go to this running session" : "Resume: a new Claude process with --resume")
                SessionActionsMenu(state: state, ref: ref, onAskDelete: askDelete)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SessionCardBackground(focused: focused))
        .opacity(status == .closed ? 0.85 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            SessionMenuContent(items: SessionMenu.items(for: ref, state: state, onAskDelete: askDelete))
        }
        .help(ref.cwd)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusWord). \(ref.title). \(place), \(state.displayName(forAccountNamed: ref.accountName))")
    }

    private func askDelete() { state.confirmingDelete = ref.sessionId }

    private var meta: some View {
        HStack(spacing: 5) {
            Text(statusWord).foregroundStyle(status == .working ? accent : status.needsYou ? SessionColors.needsYou : Color.white.opacity(0.62))
            Text("·").foregroundStyle(.tertiary)
            Text(place).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("·").foregroundStyle(.tertiary)
            AccountTag(state: state, accountName: ref.accountName)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var statusWord: String { status.word.lowercased() }
}

/// A session row's surface: white 5.5 % with a 7 % edge, continuous corners; the keyboard's
/// focus a 2 pt ring in the accent.
struct SessionCardBackground: View {
    var focused = false
    @Environment(\.groveAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(.white.opacity(contrast == .increased ? 0.09 : 0.055))
            .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.25 : 0.07), lineWidth: 1))
            .overlay { if focused { shape.strokeBorder(accent, lineWidth: 2) } }
    }
}

/// An account where a row names it: its host colour as a dot, then its name.
struct AccountTag: View {
    @ObservedObject var state: AppState
    let accountName: String

    var body: some View {
        HStack(spacing: 4) {
            if let dot = state.dot(forAccountNamed: accountName) {
                Circle().fill(dot).frame(width: 5, height: 5)
            }
            Text(state.displayName(forAccountNamed: accountName)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The state of a session at a glance, by shape before colour: a working arc in the
/// accent (still under Reduce Motion, turning once every 1.6 s otherwise), a yellow disc
/// with "!" for a permission to give or "?" for a question, a white ring with a dot when
/// the turn is the user's, a grey dashed ring when it is closed. The row says the word too.
struct SessionStatusGlyph: View {
    let status: SessionState
    var size: CGFloat = 12
    @Environment(\.groveAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        ZStack {
            switch status {
            case .working:
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.6)
                if reduceMotion || isSnapshotRender {
                    arc
                } else {
                    TimelineView(.animation) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        arc.rotationEffect(.degrees(turn * 360))
                    }
                }
            case .needsPermission, .asksYou:
                Circle().fill(SessionColors.needsYou)
                Image(systemName: status == .needsPermission ? "exclamationmark" : "questionmark")
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(SessionColors.ink)
            case .yourTurn:
                Circle().strokeBorder(Color.white.opacity(0.86), lineWidth: 1.5)
                Circle().fill(Color.white.opacity(0.86)).frame(width: size * 0.32, height: size * 0.32)
            case .closed:
                Circle().strokeBorder(Color.white.opacity(0.36), style: StrokeStyle(lineWidth: 1.3, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Three quarters of a circle, from the top.
    private var arc: some View {
        Circle().trim(from: 0, to: 0.75)
            .stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// The two colours a session's state is drawn in besides the accent: yellow, which means
/// one thing only — the session needs the user — and the ink drawn on it.
enum SessionColors {
    /// #FFD05C
    static let needsYou = Color(.sRGB, red: 0xFF / 255, green: 0xD0 / 255, blue: 0x5C / 255)
    /// #2A2218
    static let ink = Color(.sRGB, red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255)
}
