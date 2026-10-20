// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import AppKit
import GroveCore

/// The Projects list, top to bottom:
///
/// - SUGGESTED: folders Claude Code runs in that no project shows, at most two, each with
///   Add and "not now";
/// - the projects with something running: the name, what it holds, how many sessions need
///   the user or work, and up to three sessions as previews — what needs the user first,
///   then what works, then what waits for the next prompt — then "N more sessions";
/// - NOTHING RUNNING: the rest, one line each with the newest prompt;
/// - Other folders: the sessions outside every project.
///
/// With no project yet: what a project is, Add a folder, and every folder Claude Code runs
/// in. A search (⌘F) narrows the list to the sessions it finds, closed ones included.
/// Rows never move while the list is in view (`AppState.frozenOrder`).
struct ProjectsTab: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
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

    private var searching: Bool { !state.searchNeedle.isEmpty }

    private var list: some View {
        let lists = state.projectsList
        let others = state.listedOtherFolders()
        return VStack(alignment: .leading, spacing: 16) {
            if searching {
                if lists.live.isEmpty && others.isEmpty {
                    Text("Nothing matches “\(state.searchQuery)”.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            } else if !state.listedSuggestions.isEmpty {
                SuggestedSection(state: state, suggestions: state.listedSuggestions)
            }
            ForEach(lists.live) { entry in
                projectSection(entry)
            }
            if !searching, !lists.quiet.isEmpty {
                QuietProjectsSection(state: state, entries: lists.quiet)
            }
            if searching {
                ForEach(others) { folder in
                    VStack(alignment: .leading, spacing: 6) {
                        OtherFolderHeader(state: state, folder: folder)
                        ForEach(folder.sessions, id: \.id) { session in
                            SessionPreviewCard(state: state, session: session, place: nil, highlight: state.searchNeedle)
                        }
                    }
                }
            } else if !others.isEmpty {
                OtherFoldersRow(state: state, folders: others)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func projectSection(_ entry: ProjectsListEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectHeader(state: state, entry: entry)
            ForEach(entry.shown) { row in
                SessionPreviewCard(state: state, row: row, focused: state.keyboardFocus == row.id,
                                   highlight: state.searchNeedle)
            }
            if entry.more > 0 && !searching {
                Button { state.open(.project(entry.project.id)) } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("\(entry.more) more session\(entry.more == 1 ? "" : "s")")
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PanelWhite.secondary(increased))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(entry.project.name)")
            }
        }
    }
}

/// A live project's header: its name, what it holds, how many sessions need the user and
/// work; the way into it.
struct ProjectHeader: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let entry: ProjectsListEntry
    @Environment(\.groveAccent) private var accent

    var body: some View {
        Button { state.open(.project(entry.project.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.project.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if let counts {
                    Text(counts).font(.system(size: 10.5)).foregroundStyle(PanelWhite.tertiary(increased))
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 6)
                if entry.needsYou > 0 {
                    Text("\(entry.needsYou) need\(entry.needsYou == 1 ? "s" : "") you")
                        .foregroundStyle(SessionColors.needsYou)
                }
                if entry.working > 0 {
                    Text("\(entry.working) working").foregroundStyle(accent.opacity(0.9))
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelWhite.tertiary(increased))
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.project.path)
    }

    /// "5 repos · 5 ws", once the project has been scanned.
    private var counts: String? {
        guard let snapshot = state.snapshots[entry.project.id] else { return nil }
        var parts = ["\(snapshot.repos.count) repo\(snapshot.repos.count == 1 ? "" : "s")"]
        if !snapshot.workspaces.isEmpty { parts.append("\(snapshot.workspaces.count) ws") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Suggestions

/// SUGGESTED: at most two folders, then the way to the rest.
struct SuggestedSection: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let suggestions: [ProjectSuggestion]
    static let shown = SuggestedSectionLimit.shown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionCaption(title: "SUGGESTED")
                Spacer()
                Text(suggestions.count == 1 ? "Claude is running in a folder you haven't added"
                     : "Claude is running in \(suggestions.count) folders you haven't added")
                    .font(.system(size: 10)).foregroundStyle(PanelWhite.tertiary(increased)).lineLimit(1)
            }
            .padding(.horizontal, 2)
            ForEach(suggestions.prefix(Self.shown)) { suggestion in
                SuggestionRow(state: state, suggestion: suggestion,
                              focused: state.keyboardFocus == "suggestion:" + suggestion.path)
            }
            if suggestions.count > Self.shown {
                Button { state.open(.otherSessions) } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("+\(suggestions.count - Self.shown) more folder\(suggestions.count - Self.shown == 1 ? "" : "s")")
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PanelWhite.secondary(increased))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A folder Claude Code runs in that no project shows: a dashed outline (not a project
/// yet), the folder and as whom it runs there, where it is and how many sessions run there,
/// Add, and "not now", which is remembered. The path gives way first: a long one keeps its
/// two ends.
struct SuggestionRow: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let suggestion: ProjectSuggestion
    var focused = false
    @Environment(\.groveAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                Circle().fill(accent).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(suggestion.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    accounts
                        .font(.system(size: 10.5)).lineLimit(1)
                        .layoutPriority(-1)
                }
                place
            }
            Spacer(minLength: 6)
            Button { state.addSuggestion(suggestion) } label: {
                Text("Add")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(SessionColors.ink)
                    .padding(.horizontal, 12).frame(height: 22)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .help("Add \(suggestion.path) as a project")
            Button { state.dismissSuggestion(suggestion) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PanelWhite.tertiary(increased))
                    .frame(width: 18, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not now: don't suggest this folder again")
            .accessibilityLabel("Don't suggest \(suggestion.name) again")
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent, lineWidth: 2) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested project \(suggestion.name): Claude is running there")
    }

    /// "● Work", the accounts its sessions run as.
    private var accounts: Text {
        let quiet = PanelWhite.tertiary(increased)
        var parts: [Text] = []
        for dir in suggestion.configDirs.prefix(2) {
            if let account = state.account(ofConfigDir: dir) {
                if !parts.isEmpty { parts.append(Text("  ")) }
                if let dot = account.dot { parts.append(Text("● ").foregroundStyle(dot).font(.system(size: 7))) }
                parts.append(Text(account.name).foregroundStyle(quiet))
            }
        }
        return Text.joined(parts)
    }

    /// "~/Code/harbor-api · 2 claude sessions": the path in the middle cut short when it is
    /// long, the count whole.
    private var place: some View {
        let quiet = PanelWhite.tertiary(increased)
        let count = suggestion.pids.count
        return HStack(spacing: 0) {
            Text(state.displayPath(suggestion.path))
                .lineLimit(1).truncationMode(.middle)
            Text(" · " + (count == 1 ? "claude running" : "\(count) claude sessions"))
                .lineLimit(1).fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(quiet)
    }
}

// MARK: - Nothing running

/// NOTHING RUNNING: one grouped card, a line per project: its name, its newest prompt —
/// still the way the user knows it — and how long ago.
struct QuietProjectsSection: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let entries: [ProjectsListEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionCaption(title: "NOTHING RUNNING")
                Spacer()
                Text("\(entries.count) project\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(PanelWhite.tertiary(increased))
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry)
                    if index < entries.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.leading, 10)
                    }
                }
            }
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    private func row(_ entry: ProjectsListEntry) -> some View {
        Button { state.open(.project(entry.project.id)) } label: {
            HStack(spacing: 8) {
                Text(entry.project.name)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                    .fixedSize(horizontal: entry.project.name.count < 24, vertical: false)
                if let newest = entry.newest {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                        Text(state.showsMessagePreviews ? (newest.preview?.prompt ?? newest.title) : newest.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                    Text(relativeAge(newest.lastActivity, now: Date()))
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(PanelWhite.tertiary(increased)).fixedSize()
                } else {
                    Text("no sessions yet").font(.system(size: 11)).foregroundStyle(PanelWhite.tertiary(increased))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelWhite.tertiary(increased))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.project.path)
        .accessibilityLabel("\(entry.project.name), nothing running")
    }
}

// MARK: - Other folders

/// The way to the sessions outside every project.
struct OtherFoldersRow: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let folders: [OtherFolder]

    var body: some View {
        let sessions = folders.reduce(0) { $0 + $1.sessions.count }
        Button { state.open(.otherSessions) } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.45))
                Text("Other folders").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                Text("\(sessions) session\(sessions == 1 ? "" : "s") in \(folders.count) folder\(folders.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(PanelWhite.tertiary(increased)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelWhite.tertiary(increased))
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An other folder's header: its name and place, and the way to make it a project.
struct OtherFolderHeader: View {
    @ObservedObject var state: AppState
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }
    let folder: OtherFolder
    @Environment(\.groveAccent) private var accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder").font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.55))
            Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(state.displayPath(folder.path)).font(.system(size: 10.5)).foregroundStyle(PanelWhite.tertiary(increased))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button { state.addFolderAsProject(folder) } label: {
                Text("Add as project").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .help("Add \(folder.path) as a project")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - No projects yet

/// No project yet: what a project is, the way to add one, and the folders Claude Code
/// already runs in, one click each.
struct ProjectsEmptyState: View {
    @ObservedObject var state: AppState
    @Environment(\.groveAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(accent)
                Text("No projects yet").font(.system(size: 15, weight: .semibold))
                Text("A project is a folder of repositories you work in with Claude Code. Its sessions show up here, with what was said last.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330)
                Button { addFolder() } label: {
                    Text("Add a folder…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SessionColors.ink)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.top, 26)
            .padding(.bottom, 24)
            if !state.listedSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionCaption(title: "CLAUDE IS RUNNING IN").padding(.horizontal, 2)
                    ForEach(state.listedSuggestions) { SuggestionRow(state: state, suggestion: $0) }
                }
            }
        }
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

// MARK: - Shared

/// A session card's surface: white 5.5 % with a 7 % edge, continuous corners, a little
/// brighter under the pointer; the keyboard's focus a 2 pt ring in the accent.
struct SessionCardBackground: View {
    var focused = false
    var hovered = false
    @Environment(\.groveAccent) private var accent
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var contrast: ColorSchemeContrast { renderContrast ?? systemContrast }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let increased = contrast == .increased
        shape.fill(.white.opacity(hovered ? 0.085 : increased ? 0.09 : 0.055))
            .overlay(shape.strokeBorder(.white.opacity(increased ? 0.25 : 0.07), lineWidth: 1))
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

/// The panel's quieter whites, stronger under Increase Contrast.
enum PanelWhite {
    static func secondary(_ increased: Bool) -> Color { .white.opacity(increased ? 0.8 : 0.58) }
    static func tertiary(_ increased: Bool) -> Color { .white.opacity(increased ? 0.6 : 0.36) }
}
