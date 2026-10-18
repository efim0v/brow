// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// The pet's layer in `NotchRootView`: a `TimelineView` at the rate `PetFramePolicy` asks for, posing
/// the pet afresh at every tick and drawing it on its own small canvas, which moves with it. The layer
/// covers the window, in the window's coordinates, inside the outline's clip: the shape that grows on
/// hover cuts the pet exactly as it cuts the panel, and the canvas masks the camera itself. It takes no
/// click; the boop is the panel controller's hit test against the posed body.
struct PetLayerView: View {
    @ObservedObject var layer: PetLayer
    /// `frames.expanded.size`.
    let size: CGSize
    let expanded: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: layer.rate.minimumInterval, paused: layer.rate.paused)) { _ in
                PetLayerFrame(frame: posed(), palette: layer.palette, measure: measure)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            stripElement
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // The rig owns every move the pet makes: no SwiftUI animation may tween between two of its
        // frames, not even the outline's spring, inside whose transaction the layer is rebuilt on hover.
        .transaction { $0.animation = nil }
    }

    /// The pose for this tick. Reading `redraws` here is what makes a bump of it draw a paused frame
    /// again.
    private func posed() -> PetFrame? {
        _ = layer.redraws
        guard let perf = layer.perf else { return layer.frame() }
        let start = ContinuousClock.now
        let frame = layer.frame()
        perf.frame(layer.frameClass(at: layer.now()), body: ContinuousClock.now - start)
        return frame
    }

    private var measure: ((Duration) -> Void)? {
        layer.perf.map { perf in { perf.draw($0) } }
    }

    /// One VoiceOver element for the pet in the strip: over its zone, never announcing itself. In the
    /// panel the header row is the pet's element instead.
    @ViewBuilder
    private var stripElement: some View {
        if layer.isOn, !expanded, let zone = layer.zones?.strip {
            // The element first, then placed by padding rather than an offset, so that its accessibility
            // frame is the zone and nothing more.
            Color.clear
                .frame(width: zone.bounds.width, height: zone.bounds.height)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PetText.label)
                .accessibilityValue(layer.accessibilityValue)
                .accessibilityAddTraits(.updatesFrequently)
                .padding(.leading, zone.bounds.minX)
                .padding(.top, zone.bounds.minY)
                .allowsHitTesting(false)
        }
    }
}

/// One drawn frame: the pet's canvas at `frame.canvas`, in a layer the size of the window.
private struct PetLayerFrame: View {
    let frame: PetFrame?
    let palette: PetPalette
    let measure: ((Duration) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let frame {
                PetCanvas(frame: frame, palette: palette, measure: measure)
                    .offset(x: frame.canvas.minX, y: frame.canvas.minY)
            }
        }
    }
}
