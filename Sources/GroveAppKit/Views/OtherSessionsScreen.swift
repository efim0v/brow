// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// The sessions whose folder is no project's (route .otherSessions), newest first, each
/// with Resume and its own menu: resume as another account, share, copy, delete.
struct OtherSessionsScreen: View {
    @ObservedObject var state: AppState

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScopeHeader(title: "Other sessions", subtitle: "\(state.otherSessions.count) outside your projects",
                        onBack: { state.goBack() })
            let sessions = listed
            if sessions.isEmpty {
                emptyState
            } else {
                FadingScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions, id: \.id) { session in
                            SessionLineRow(state: state, ref: SessionRef(session: session, isLive: false),
                                           status: .closed, place: (session.cwd as NSString).lastPathComponent)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// The sessions, the search applied.
    private var listed: [ClaudeSession] {
        let needle = state.searchNeedle
        guard !needle.isEmpty else { return state.otherSessions }
        return state.otherSessions.filter {
            ($0.title ?? "").lowercased().contains(needle) || $0.cwd.lowercased().contains(needle)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No other sessions")
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
