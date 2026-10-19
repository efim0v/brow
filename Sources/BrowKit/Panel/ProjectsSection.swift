// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Combine
import GroveAppKit
import GroveCore
import SwiftUI

/// The Projects section: Workspaces' screens inside the notch — the projects and their
/// sessions, a project with its workspaces, graph and stats, the forms — or, while Grove.app
/// runs, why it is paused. Registered by `WorkspacesHost` while Workspaces is wanted.
@MainActor
final class ProjectsSection: NotchSection {
    let host: WorkspacesHost
    let search = ProjectsSearch()
    /// Sets `isPanelOpen` once the section has been in view for `openDelay`: a pointer that
    /// only passes over the notch starts no scan.
    private var opening: DispatchWorkItem?
    static let openDelay: TimeInterval = 0.25

    init(host: WorkspacesHost) {
        self.host = host
    }

    func content(layout: NotchShellLayout) -> AnyView {
        AnyView(ProjectsSectionView(host: host, width: layout.contentWidth))
    }

    func switchAccessory() -> AnyView {
        AnyView(ProjectsAccessory(host: host, search: search))
    }

    func footerStatus() -> AnyView { AnyView(ProjectsFooterStatus(host: host)) }

    func refreshButton() -> AnyView { AnyView(ProjectsRefreshButton(host: host)) }

    func refresh() {
        guard let state = host.state, host.activation == .on else { return }
        Task { await state.refresh() }
    }

    func escape() -> Bool {
        guard let state = host.state else { return false }
        if search.isOpen || !state.searchQuery.isEmpty {
            search.close()
            state.searchQuery = ""
            return true
        }
        return state.goBackForKey()
    }

    func handleKey(_ key: NotchKey) -> Bool {
        guard let state = host.state, host.activation == .on else { return false }
        switch key {
        case .find:
            search.open()
            return true
        case .up, .down:
            guard state.route == .projects else { return false }
            state.moveKeyboardFocus(by: key == .up ? -1 : 1)
            return true
        case .open:
            // The launch form's own ↩ (its default button) when it is in front.
            guard state.route == .projects, let row = state.focusedSessionRow else { return false }
            SessionMenu.primary(SessionRef(row: row), state: state)
            return true
        case .openWithOptions:
            guard state.route == .projects, let row = state.focusedSessionRow, row.state == .closed else { return false }
            state.beginResume(row)
            return true
        case .delete, .tab:
            return false
        }
    }

    func visibilityChanged(_ visible: Bool) {
        opening?.cancel()
        opening = nil
        guard let state = host.state else { return }
        if visible {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let state = self.host.state, self.host.activation == .on else { return }
                    state.isPanelOpen = true
                }
            }
            opening = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: work)
        } else {
            state.isPanelOpen = false
            state.keyboardFocus = nil
        }
    }
}

/// Whether the search field in the switch row is open.
@MainActor
final class ProjectsSearch: ObservableObject {
    @Published private(set) var isOpen = false
    /// Bumped when ⌘F asks for the field's focus again.
    @Published private(set) var focusRequest = 0

    func open() {
        isOpen = true
        focusRequest += 1
    }

    func close() { isOpen = false }
}

/// What the section shows: Workspaces' screens, or why they wait.
struct ProjectsSectionView: View {
    @ObservedObject var host: WorkspacesHost
    let width: CGFloat

    var body: some View {
        Group {
            if host.activation == .paused {
                WorkspacesNoticeView(notice: host.pausedNotice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let state = host.state {
                RootView(state: state)
            } else {
                Color.clear
            }
        }
        .environment(\.groveHost, .notch(width: width))
    }
}

/// The switch row's trailing side on Projects: search (⌘F), and + for a folder.
struct ProjectsAccessory: View {
    @ObservedObject var host: WorkspacesHost
    @ObservedObject var search: ProjectsSearch
    @FocusState private var focused: Bool
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        HStack(spacing: 2) {
            if let state = host.state, host.activation == .on {
                SearchControl(state: state, search: search, focused: $focused, isSnapshotRender: isSnapshotRender)
                Button { host.addFolder() } label: { NotchIconLabel(symbol: "plus") }
                    .buttonStyle(.plain)
                    .help("Add a folder as a project")
                    .accessibilityLabel("Add a folder as a project")
            }
        }
        .onChange(of: search.focusRequest) { _, _ in focused = true }
    }
}

/// The search: a magnifier, or the 168 pt field it opens into.
private struct SearchControl: View {
    @ObservedObject var state: AppState
    @ObservedObject var search: ProjectsSearch
    var focused: FocusState<Bool>.Binding
    let isSnapshotRender: Bool

    var body: some View {
        if search.isOpen || !state.searchQuery.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                if isSnapshotRender {
                    Text(state.searchQuery.isEmpty ? "Search" : state.searchQuery)
                        .font(.system(size: 12))
                        .foregroundStyle(state.searchQuery.isEmpty ? Color.secondary : Color.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search", text: $state.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused(focused)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 168, height: 24)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        } else {
            Button { search.open() } label: { NotchIconLabel(symbol: "magnifyingglass") }
                .buttonStyle(.plain)
                .help("Search (⌘F)")
                .accessibilityLabel("Search")
        }
    }
}

/// The footer's line on Projects: what runs, and how fresh the list is; in a form, its keys.
struct ProjectsFooterStatus: View {
    @ObservedObject var host: WorkspacesHost

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(line(now: context.date))
                .font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
                .foregroundStyle(NotchTheme.secondary())
        }
    }

    private func line(now: Date) -> String {
        if host.activation == .paused { return "Paused while Grove runs" }
        guard let state = host.state else { return "" }
        switch state.route {
        case .launch: return "↩ start · esc back"
        case .createWorkspace: return "tab next · ↩ create · esc back"
        case .projectSettings, .statsSettings: return "esc back"
        default: break
        }
        if !state.searchQuery.isEmpty {
            let found = state.listedSessionOrder.count
            return "\(found) \(found == 1 ? "match" : "matches") for “\(state.searchQuery)”"
        }
        var parts: [String] = []
        let running = state.recentSessionsByProject.values.flatMap { $0 }.filter { $0.state == .working }.count
        if running > 0 { parts.append("\(running) working") }
        if state.isScanning {
            parts.append("scanning…")
        } else if let scanned = state.lastRefreshAt {
            parts.append("scanned \(Self.age(scanned, now: now))")
        }
        return parts.isEmpty ? "\(state.config.projects.count) projects" : parts.joined(separator: " · ")
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        return Formatting.age(date, now: now)
    }
}

/// ⟳ on Projects: rescans the projects and re-reads the sessions.
struct ProjectsRefreshButton: View {
    @ObservedObject var host: WorkspacesHost

    var body: some View {
        if let state = host.state, host.activation == .on {
            ProjectsRefreshControl(state: state)
        } else {
            NotchIconLabel(symbol: "arrow.clockwise", color: Color.white.opacity(0.3))
        }
    }
}

private struct ProjectsRefreshControl: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button { Task { await state.refresh() } } label: {
            ZStack {
                NotchIconLabel(symbol: "arrow.clockwise").opacity(state.isScanning ? 0 : 1)
                if state.isScanning { ProgressView().controlSize(.mini) }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(state.isScanning)
        .help("Rescan the projects (⌘R)")
        .accessibilityLabel("Rescan the projects")
    }
}
