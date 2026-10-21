// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// A project (route .project(id)): "‹ name", its three views — Workspaces, Graph, Stats —
/// as plain words with the accent under the one shown, and its settings; under them what
/// the project holds and "+ Workspace"; then the view itself, at the full width.
///
/// In a window of its own a search row sits under the header (⌘F); in the notch the
/// search is the panel's, beside the section switch.
struct ProjectScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.groveHost) private var host
    @Environment(\.groveAccent) private var accent
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            subheader
            if !host.isNotch { searchRow }
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            BackButton { state.goBack() }
            Text(state.selectedProject?.name ?? "Project")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            tabStrip
            Button {
                if let id = state.selectedProjectID { state.open(.projectSettings(id)) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Project settings")
            .accessibilityLabel("Project settings")
        }
        .padding(.bottom, 4)
    }

    /// Workspaces · Graph · Stats as plain words; the one shown is white, semibold, with a
    /// 2 pt line in the accent under it.
    private var tabStrip: some View {
        HStack(spacing: 12) {
            ForEach(MainTab.allCases, id: \.rawValue) { tab in
                let on = state.selectedTab == tab
                Button { state.selectedTab = tab } label: {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.58))
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) {
                            if on { Capsule().fill(accent).frame(height: 2).offset(y: 3) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    /// "5 repos · 5 workspaces · 2 running", and "+ Workspace" on the Workspaces view.
    private var subheader: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.selectedTab == .workspaces, let id = state.selectedProjectID {
                Button {
                    state.createPrefill = CreatePrefill()
                    state.open(.createWorkspace(id))
                } label: {
                    Label("Workspace", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("New workspace")
            }
        }
        .padding(.leading, 6)
        .padding(.bottom, 8)
    }

    private var summary: String {
        guard let snapshot = state.selectedSnapshot else {
            return state.isScanning ? "Scanning…" : "Not scanned yet"
        }
        var parts = ["\(snapshot.repos.count) repos", "\(snapshot.workspaces.count) workspaces"]
        let running = Set(snapshot.workspaces.flatMap(\.liveProcesses).map(\.pid))
            .union(snapshot.loose.flatMap(\.liveProcesses).map(\.pid)).count
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Search (a window of its own)

    /// Filters the workspaces (spec §6). A static lookalike offscreen, where a TextField
    /// draws as a placeholder.
    private var searchRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            if isSnapshotRender {
                Text(state.searchQuery.isEmpty ? "Search" : state.searchQuery)
                    .font(.callout)
                    .foregroundStyle(state.searchQuery.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .modifier(SearchFieldChrome())
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        )
        .padding(.bottom, 8)
    }

    // MARK: - The view

    @ViewBuilder
    private var content: some View {
        switch state.selectedTab {
        case .workspaces: WorkspacesScreen(state: state)
        case .graph: GraphScreen(state: state)
        case .stats: CodeStatsScreen(state: state)
        }
    }
}
