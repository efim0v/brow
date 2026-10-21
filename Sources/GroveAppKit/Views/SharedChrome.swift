// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// A card's label in the screen's accent: Stats, Stats settings.
struct CardLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.groveAccent) private var accent
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(accent)
            Text(title).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
    }
}

/// `claude-opus-4-8` → `opus-4-8`, for the session meta line.
func shortModelName(_ id: String) -> String {
    id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
}

/// A section's caption: PROJECT FOLDER, WORKSPACES, LOOSE WORKTREES. 10 pt semibold
/// capitals, a little tracking, in the quietest white.
struct SectionCaption: View {
    let title: String
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity((renderContrast ?? systemContrast) == .increased ? 0.6 : 0.36))
            .accessibilityAddTraits(.isHeader)
    }
}
