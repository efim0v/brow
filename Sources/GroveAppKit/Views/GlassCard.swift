// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// True while a view is rendered offscreen (SnapshotMode, the README and design renders).
/// ImageRenderer draws no ScrollView content, and AppKit-backed controls (Menu, Picker,
/// TextField, Toggle) as placeholders, so the views that use them draw a static lookalike
/// instead while this is set.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

extension View {
    /// Draws this view for an offscreen render (see `isSnapshotRender`). For tests and
    /// render tools only; the app never sets it.
    public func snapshotRender(_ on: Bool = true) -> some View {
        environment(\.isSnapshotRender, on)
    }
}

/// Card chrome used across the app: a GRAY translucent substrate floating on the
/// window's transparent Liquid Glass. The glass is the WINDOW (set on the panel);
/// the content blocks are these neutral gray cards with a pronounced Apple-26
/// continuous radius and a hairline top-edge highlight. A plain fill (not
/// .glassEffect) keeps the card — and everything inside it — visible both live and
/// in the offscreen snapshot renderer. The card declares itself the container
/// shape so nested ConcentricRectangle elements resolve concentric radii against it.
public struct GlassCard: ViewModifier {
    @Environment(\.groveHost) private var host
    @Environment(\.colorSchemeContrast) private var contrast

    public init() {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: host.isNotch ? 10 : DesignRadius.card, style: .continuous)
    }

    public func body(content: Content) -> some View {
        if host.isNotch {
            // On the notch's black there is no glass to float on: the panel's own card, white
            // at 5.5 % with a 7 % edge (more of both under Increase Contrast).
            let increased = contrast == .increased
            content
                .background(Color.white.opacity(increased ? 0.09 : 0.055), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(increased ? 0.25 : 0.07), lineWidth: 1))
                .containerShape(shape)
        } else {
            // A few tones DARKER than before (white 0.16 → 0.10) and slightly more
            // opaque (0.70 → 0.74) so the cards read closer to black than gray, per the
            // user's "darker substrates" ask; NO light "glass" border — a clean
            // near-black surface floating on the window's Liquid Glass.
            content
                .background(Color(white: 0.10).opacity(0.74), in: shape)
                .containerShape(shape)
        }
    }
}

extension View {
    public func glassCard() -> some View {
        modifier(GlassCard())
    }
}
