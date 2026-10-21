// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// Other folders (route .otherSessions): the folders Claude Code runs in that no project
/// shows, then the sessions outside every project by the folder they ran in — the
/// repository around it when there is one — each folder with "Add as project", each
/// session a preview with Resume and its own menu.
struct OtherSessionsScreen: View {
    @ObservedObject var state: AppState

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        let folders = state.listedOtherFolders()
        let suggestions = state.searchNeedle.isEmpty ? state.listedSuggestions : []
        VStack(alignment: .leading, spacing: 0) {
            ScopeHeader(title: "Other folders", subtitle: subtitle(folders), onBack: { state.goBack() })
            if folders.isEmpty && suggestions.isEmpty {
                emptyState
            } else {
                FadingScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionCaption(title: "CLAUDE IS RUNNING IN").padding(.horizontal, 2)
                                ForEach(suggestions) { SuggestionRow(state: state, suggestion: $0) }
                            }
                        }
                        ForEach(folders) { folder in
                            VStack(alignment: .leading, spacing: 6) {
                                OtherFolderHeader(state: state, folder: folder)
                                ForEach(folder.sessions, id: \.id) { session in
                                    SessionPreviewCard(state: state, session: session, place: nil,
                                                       highlight: state.searchNeedle)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func subtitle(_ folders: [OtherFolder]) -> String {
        let sessions = folders.reduce(0) { $0 + $1.sessions.count }
        return "\(sessions) session\(sessions == 1 ? "" : "s") in \(folders.count) folder\(folders.count == 1 ? "" : "s") outside your projects"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No other folders")
                .font(.system(size: 14, weight: .semibold))
            Text("Sessions in a project's folders are listed under the project.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
