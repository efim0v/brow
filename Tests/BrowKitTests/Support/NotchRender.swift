// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import GroveAppKit
@testable import BrowKit

/// The notch panel as the app builds and clips it, for offscreen renders: the real
/// `NotchPanelController` — its model, shell and outline at the frames it computes, Glim in
/// it — opened on a section. The window is never ordered in and the pointer never read
/// (`drivesWindow` off), and the pet is posed from a script at a fixed instant, so a render
/// is the same on every run.
@MainActor
struct NotchRender {
    let controller: NotchPanelController
    let pet: PetController

    /// Open on `tab`; `host` registers Projects, as Workspaces does while it is on.
    static func open(store: LimitsStore, clock: PanelClock, tab: NotchTab = .limits, screen: ScreenMetrics,
                     host: WorkspacesHost? = nil, pinned: Bool = false, keys: Bool = false) throws -> NotchRender {
        let petDir = try Fixture.tempDir("notch-render-pet")
        let pet = PetController(store: store, petStore: PetStore(directory: petDir.path), senses: false,
                                defaults: UserDefaults(suiteName: "brow-notch-render-\(UUID().uuidString)")!)
        let controller = NotchPanelController(store: store, clock: clock, pet: pet,
                                              onExpandedChange: { _ in }, onSettings: {})
        controller.drivesWindow = false
        controller.screen = { screen }
        controller.now = { clock.now }
        host?.notch = controller
        controller.show()
        controller.openPinned(on: tab)
        if !pinned { controller.unpin() }
        controller.model.showsKeys = keys
        let render = NotchRender(controller: controller, pet: pet)
        render.pose(expanded: controller.model.tab == .limits)
        return render
    }

    /// Glim content and at rest, its eyes open: in the header (`expanded`) or on its ledge.
    /// `progress`, how far the open spring has run: the hop takes about half a second from the
    /// instant the outline starts to open, and before that the pet is on its ledge. Set after
    /// opening: opening publishes the words of a pet that has not started.
    func pose(expanded: Bool, at progress: CGFloat = 1) {
        pet.panel.header = PetText.Header(word: "Content", detail: "Ate 3 % · 2 min ago", moment: nil)
        pet.panel.meter = 22
        let layer = pet.layer
        layer.timeline.segments = [PetSegment(start: 0, behaviour: .idle(.content))]
        layer.timeline.meter = [PetMeterKey(t: 0, value: 22, rate: 0)]
        layer.seed = 7
        var t = 9.0
        while PetRigIdle.blinkOpen(at: t, seed: layer.seed) < 0.999 || PetRigIdle.blinkOpen(at: t - 0.2, seed: layer.seed) < 0.999 {
            t += 0.05
        }
        layer.dock.changes = expanded && progress > 0 ? [PetDockChange(t: t - 0.55 * Double(progress), kind: .expand)] : []
        let instant = t
        layer.now = { instant }
    }

    /// The outline and everything in it; `outlineProgress` catches it part-way open.
    func view(outlineProgress: CGFloat? = nil) -> some View {
        NotchRootView(model: controller.model, outlineProgress: outlineProgress)
            .snapshotRender()
            .environment(\.colorScheme, .dark)
    }
}
