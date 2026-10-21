// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// v1.2.1 fix 4: the back affordance in scope headers is a REAL button — a
/// 28x28pt hit target (was a bare ~13pt glyph) with a hover highlight — and
/// it exists exactly ONCE: every scoped screen renders this component
/// (directly or via ScopeHeader) instead of keeping five chevron copies.
///
/// Keyboard: Esc triggers it. Esc over Cmd+[ because the panel is a state
/// machine of full-screen scopes and Esc is the native "leave this scope"
/// key for panels/popovers; Cmd+[ is a browser/editor convention that also
/// collides with text-indent shortcuts while a field is focused.
///
/// The hover highlight is live-only by nature (snapshots never hover), so no
/// isSnapshotRender gate is needed: the idle state draws opacity 0.
struct BackButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.white.opacity(hovered ? 0.08 : 0), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut(.escape, modifiers: [])
        .help("Back (esc)")
        .accessibilityLabel("Back")
    }
}

/// Shared header for scoped screens: "‹ title", the subtitle under it (what the screen is
/// about: a project, a place), the screen's own actions on the right.
struct ScopeHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    /// CreateWorkspaceScreen disables back (and with it Esc) while a creation
    /// run is in flight — leaving mid-run would orphan the progress log.
    var backDisabled = false
    let onBack: () -> Void
    @ViewBuilder var actions: () -> Actions
    @Environment(\.groveHost) private var host

    var body: some View {
        HStack(spacing: 6) {
            BackButton(action: onBack)
                .disabled(backDisabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, host.isNotch ? 0 : 12)
        .padding(.bottom, 8)
        .padding(.top, host.isNotch ? 0 : 8)
    }
}

extension ScopeHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, backDisabled: Bool = false, onBack: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, backDisabled: backDisabled, onBack: onBack, actions: { EmptyView() })
    }
}
