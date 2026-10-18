// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// The pet through Brow's real views, offscreen: every frame is `NotchRootView` itself, with
/// the real outline, `EarsView`, `PanelView` and its header row, and the pet's own layer, on a stand-in
/// desktop. Only the outline's spring is replayed by hand (`outlineProgress`), because `ImageRenderer`
/// cannot run one. Skipped unless `PET_FINAL_DIR` names an output folder outside the repository:
///
///     PET_FINAL_DIR=/path/to/out swift test -c release --filter PetFinalRenderTests
///
/// `PET_FINAL_ONLY` (comma-separated: tour, brain, panel, panelmeal, below, pill, den, stirring, moments,
/// moods) renders some of them. Films go to sub-folders as PNG frames; ffmpeg makes them into films.
@MainActor
final class PetFinalRenderTests: XCTestCase {
    func testRenderThroughTheRealViews() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PET_FINAL_DIR"], !dir.isEmpty else {
            throw XCTSkip("set PET_FINAL_DIR to render the pet through Brow's real views")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = Set((ProcessInfo.processInfo.environment["PET_FINAL_ONLY"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        func wants(_ name: String) -> Bool { only.isEmpty || only.contains(name) }
        if wants("tour") { try film(PetReels.tour, crop: PetReels.mainCrop, scale: 2, to: out.appendingPathComponent("tour")) }
        if wants("brain") { try brainFilm(out.appendingPathComponent("brain")) }
        if wants("panel") { try await panelFilm(out.appendingPathComponent("panel")) }
        if wants("panelmeal") { try await panelMealFilm(out.appendingPathComponent("panelmeal")) }
        if wants("moments") {
            let reel = Self.moments
            try film(reel, crop: PetReels.crop(reel.frames), scale: 2, to: out.appendingPathComponent("moments"))
        }
        if wants("below") { try film(PetReels.below, crop: PetReels.crop(PetReels.below.frames), scale: 2, to: out.appendingPathComponent("below")) }
        if wants("pill") { try film(PetReels.pill, crop: PetReels.crop(PetReels.pill.frames), scale: 2, to: out.appendingPathComponent("pill")) }
        if wants("den") {
            for placement in [EarsPlacement.beside, .below] {
                let reel = PetReels.den(placement)
                try film(reel, crop: PetReels.crop(reel.frames), scale: 2, to: out.appendingPathComponent("den-\(placement)"))
            }
        }
        if wants("stirring") {
            for (name, placement, notch) in [("beside", EarsPlacement.beside, true), ("below", .below, true), ("pill", .beside, false)] {
                let reel = Self.stirring(placement, notch: notch)
                try film(reel, crop: PetReels.crop(reel.frames), scale: 2, to: out.appendingPathComponent("stirring-\(name)"))
            }
        }
        if wants("moods") { try moods(out) }
    }

    // MARK: The window

    /// Brow's window at one instant, cropped, on the stand-in desktop.
    struct Shot: View {
        let model: NotchPanelModel
        var progress: CGFloat?
        let crop: CGRect
        var pointer: CGPoint?
        var dim: Double = 0

        var body: some View {
            ZStack(alignment: .topLeading) {
                PetStage.Desktop(dim: dim).frame(width: crop.width, height: crop.height)
                NotchRootView(model: model, outlineProgress: progress)
                    .offset(x: -crop.minX, y: -crop.minY)
                if let pointer { PetStage.Pointer().offset(x: pointer.x - crop.minX, y: pointer.y - crop.minY) }
            }
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .dark)
        }
    }

    /// The collapsed window of `frames` with the readouts of `aggregate` and the pet layer `layer`.
    static func strip(_ frames: NotchFrames, _ aggregate: LimitsAggregate, layer: PetLayer, showEars: Bool = true) -> NotchPanelModel {
        let model = NotchPanelModel(frames: frames, pet: layer)
        model.showEars = showEars
        model.ears = AnyView(EarsView(aggregate: aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        return model
    }

    static func write(_ view: some View, scale: CGFloat, to url: URL) throws {
        try PetStage.writePNG(try PetStage.image(view, scale: scale), to: url)
    }

    static func fresh(_ dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Segment scripts

    /// A segment-script reel at 60 fps, every frame through the real window. One layer for the whole film,
    /// so the rig keeps its memo, as it does in the app.
    func film(_ reel: PetReel, crop: CGRect, scale: CGFloat, to dir: URL) throws {
        try Self.fresh(dir)
        let layer = PetLayer()
        layer.timeline = reel.script.timeline
        layer.seed = reel.seed
        layer.motion = reel.motion
        layer.palette = reel.palette
        layer.rate = .fps(60)
        for n in 0..<Int((reel.duration * 60).rounded()) {
            let t = Double(n) / 60
            layer.pointer = reel.script.pointerTrack(at: t)
            layer.dock = reel.script.dockTrack(at: t)
            layer.zones = reel.zones(at: t)
            layer.now = { t }
            let model = Self.strip(reel.frames, reel.readouts(t), layer: layer, showEars: reel.showEars)
            try Self.write(Shot(model: model, crop: crop, pointer: reel.pointer(at: t), dim: reel.dim(t)), scale: scale,
                           to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
    }

    /// The weekly reset in the den with the new `stirring` between hibernating and leaving: the light comes
    /// up and, beside, one eye shows at the edge, then out (the brain waits up to 180 s for fresh numbers;
    /// the reel gives it 4).
    static func stirring(_ placement: EarsPlacement, notch: Bool) -> PetReel {
        var s = PetReelScript([
            (0.0, .idle(.content)),
            (0.8, .enterDen(retreat: false)),
            (0.8 + PetTuning.Behaviour.enterDen, .hibernating),
            (6.5, .stirring),
            (10.5, .leaveDen(stretch: true)),
            (10.5 + PetTuning.Behaviour.leaveDen, .idle(.content)),
        ])
        s.cue(8.6, .glowPulse)
        return PetReel(script: s, duration: 16, frames: PetStage.frames(placement, notch: notch), readouts: { t in
            PetStage.aggregate(left: 23, right: t < 0.7 ? 99 : (t < 6.5 ? 100 : (t < 10.5 ? 100 : 0)))
        })
    }

    /// The two celebrations, beside: a streak milestone, a happy hop and then the twirl, the face going
    /// round the back; a good week, the drum roll on the belly and a hop.
    static var moments: PetReel {
        typealias B = PetTuning.Behaviour
        let s = PetReelScript([
            (0.0, .idle(.content)),
            (0.6, .celebrate(.streak(days: 7))),
            (0.6 + B.celebrateStreak, .idle(.content)),
            (4.0, .celebrate(.goodWeek)),
            (4.0 + B.celebrateGoodWeek, .idle(.content)),
        ], hunger: 10)
        return PetReel(script: s, duration: 8, frames: PetStage.frames(.beside), readouts: { _ in PetStage.aggregate(left: 23) })
    }

    // MARK: The brain at the speed of life

    /// The tour's events played by the real brain at real pace (baseline 41 % at 0, the pointer at 3, a
    /// prompt at 4, 44 % at 5, hungry at 10, 100 % at 60, the reset at 200), drawn in three windows: the
    /// first 16 s, the feast and the yawn, the wake.
    func brainFilm(_ dir: URL) throws {
        var pet = PetHarness(seed: 7)
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 41, fiveReset: 200)]
        pet.start()
        pet.send(.pointer(distance: 120), at: 3)
        pet.send(.prompt, at: 4)
        // The path drawn below leaves at 4.6 s, as the app would tell the brain: the notice is released
        // and the eyes go back to the number.
        pet.send(.pointer(distance: 260), at: 4.6)
        pet.accounts[0].five = 44
        pet.refresh(at: 5)
        pet.send(.debugHunger(70), at: 10)
        pet.accounts[0].five = 100
        pet.refresh(at: 60)
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 200 + 5 * 3600
        pet.refresh(at: 200)
        pet.run(to: 210)
        var timeline = pet.brain.timeline
        timeline.segments = pet.played(0...210)
        let frames = PetStage.frames(.beside)
        let layer = PetLayer()
        layer.timeline = timeline
        layer.seed = 7
        layer.rate = .fps(60)
        // The pointer comes up under the strip at 3 s, 120 pt from the eyes, and goes.
        var path = PetReelScript()
        path.pointerPath([(2.6, 330, 150), (3.0, 205, 75), (3.6, 190, 70), (4.2, 300, 150), (4.6, 420, 260)])
        func readout(_ t: Double) -> Double { t < 5 ? 41 : (t < 60 ? 44 : (t < 200 ? 100 : 0)) }
        try Self.fresh(dir)
        var n = 0
        for window in [(0.0, 16.0), (58.5, 67.0), (198.5, 206.0)] {
            var t = window.0
            while t < window.1 - 1e-9 {
                layer.pointer = path.pointerTrack(at: t)
                layer.zones = PetStage.zones(frames, PetStage.aggregate(left: readout(t)))
                layer.now = { t }
                let model = Self.strip(frames, PetStage.aggregate(left: readout(t)), layer: layer)
                let pointer = path.pointer.last(where: { $0.t <= t && t - $0.t < 1.0 / 60 })?.location
                try Self.write(Shot(model: model, crop: PetReels.mainCrop, pointer: pointer), scale: 2,
                               to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
                n += 1
                t += 1.0 / 60
            }
        }
    }

    // MARK: The panel, with the real controller

    /// The pointer comes up to the strip, the outline springs open on Brow's spring and the pet hops into
    /// the header; the pointer goes over the rows and the eyes follow; it leaves, the outline closes, and
    /// the pet hops home a beat ahead of the black. Everything but the spring is the app's own: the
    /// fixture's store, `PetController` on a moved clock, the brain, the rig, `PanelView` and its header.
    func panelFilm(_ dir: URL) async throws {
        let wall0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, root) = try await PetAppFixture.store([.init()], now: wall0)
        let petStore = PetStore(directory: root.appendingPathComponent("pet").path)
        var save = PetSave(seed: 7, bornAt: wall0.addingTimeInterval(-3 * 86_400))
        save.introDone = true
        save.hunger = 22
        save.lastMealAt = wall0.addingTimeInterval(-130)
        save.lastMealPoints = 3
        save.savedAt = wall0.addingTimeInterval(-60)
        try petStore.save(save)
        let mono0: TimeInterval = 50_000
        let clock = PetTestClock(PetTime(wall: wall0, mono: mono0))
        let pet = PetController(store: store, petStore: petStore, clock: { clock.now }, senses: false,
                                defaults: UserDefaults(suiteName: "brow-pet-render-\(UUID().uuidString)")!)
        let panelClock = PanelClock(now: { wall0 })
        // The window is as tall as the panel laid out with its header row.
        let probe = NSHostingView(rootView: PanelView(store: store, clock: panelClock, topInset: 40, flare: 6,
                                                      drawsBackground: false, pet: pet.panel, onSettings: {}, onRefresh: {})
            .frame(width: 472))
        let height = max(NotchPanelController.estimatedExpandedHeight(barCounts: [2], topInset: 40, pet: true),
                         probe.fittingSize.height)
        let frames = NotchGeometry.frames(for: PetStage.notched, expandedHeight: height, placement: .beside)
        let model = NotchPanelModel(frames: frames, pet: pet.layer)
        model.ears = AnyView(EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        model.panel = AnyView(PanelView(store: store, clock: panelClock, topInset: frames.contentTopInset, flare: frames.flare,
                                        drawsBackground: false, pet: pet.panel, onSettings: {}, onRefresh: {})
            .frame(width: frames.expanded.width))
        pet.layout(frames: frames, aggregate: store.aggregate, showEars: true)
        // One render of the open window at its origin: `PanelView` reports where its "5h" figure is.
        model.expanded = true
        _ = try PetStage.image(NotchRootView(model: model), scale: 1)
        model.expanded = false
        pet.start()

        let open = 1.0, close = 3.9
        var path = PetReelScript()
        path.pointerPath([(0.2, 330, 150), (0.6, 250, 70), (0.95, 205, 22), (1.6, 190, 120), (2.3, 120, 150),
                          (2.9, 300, 170), (3.4, 340, 300)])
        func progress(_ t: Double) -> CGFloat {
            typealias H = PetTuning.Hop
            if t < open { return 0 }
            let opened = PetLayout.springProgress(t - open, response: H.openResponse, damping: H.openDamping)
            if t < close { return CGFloat(opened) }
            let at = PetLayout.springProgress(close - open, response: H.openResponse, damping: H.openDamping)
            return CGFloat(at * (1 - PetLayout.springProgress(t - close, response: H.closeResponse, damping: H.closeDamping)))
        }
        try Self.fresh(dir)
        let crop = CGRect(x: 236 - 300, y: 0, width: 600, height: 200)
        var fed = 0
        for n in 0..<Int(5.0 * 60) {
            let t = Double(n) / 60
            // The pointer's samples up to this instant, each at its own time, as the monitors deliver them.
            while fed < path.pointer.count, path.pointer[fed].t <= t {
                let sample = path.pointer[fed]
                clock.now = PetTime(wall: wall0.addingTimeInterval(sample.t), mono: mono0 + sample.t)
                pet.pointerMoved(to: sample.location)
                fed += 1
            }
            clock.now = PetTime(wall: wall0.addingTimeInterval(t), mono: mono0 + t)
            if t >= open, !pet.expanded, t < close { pet.dockChanged(expanded: true) }
            if t >= close, pet.expanded { pet.dockChanged(expanded: false) }
            pet.timerFired()
            model.expanded = pet.expanded
            pet.layer.now = { mono0 + t }
            let pointer = path.pointer.last(where: { $0.t <= t && t - $0.t < 0.02 })?.location
            try Self.write(Shot(model: model, progress: progress(t), crop: crop, pointer: pointer), scale: 2,
                           to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
        pet.flush()
    }

    /// A meal in the open panel: the bead pops out of the Overall line's "5h" figure, rises over the
    /// header's words and drops into the pet's mouth on the stage. The window is the app's, with the panel
    /// open throughout; the pet is a segment script on its own layer, and the header's words are set by
    /// hand.
    func panelMealFilm(_ dir: URL) async throws {
        let wall0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, _) = try await PetAppFixture.store([.init()], now: wall0)
        let panelClock = PanelClock(now: { wall0 })
        let words = PetPanelModel()
        words.header = PetText.Header(word: "Content", detail: "Ate 3 % · 2 min ago", moment: nil)
        words.meter = 22
        var fiveHour: CGRect?
        words.fiveHourFrameChanged = { fiveHour = $0 }
        func panel(_ frames: NotchFrames) -> some View {
            PanelView(store: store, clock: panelClock, topInset: frames.contentTopInset, flare: frames.flare,
                      drawsBackground: false, pet: words, onSettings: {}, onRefresh: {})
                .frame(width: frames.expanded.width)
        }
        let probe = NSHostingView(rootView: PanelView(store: store, clock: panelClock, topInset: 40, flare: 6,
                                                      drawsBackground: false, pet: words, onSettings: {}, onRefresh: {})
            .frame(width: 472))
        let height = max(NotchPanelController.estimatedExpandedHeight(barCounts: [2], topInset: 40, pet: true),
                         probe.fittingSize.height)
        let frames = NotchGeometry.frames(for: PetStage.notched, expandedHeight: height, placement: .beside)
        let layer = PetLayer()
        let model = NotchPanelModel(frames: frames, pet: layer)
        model.ears = AnyView(EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        model.panel = AnyView(panel(frames))
        model.expanded = true
        // One render of the open window: `PanelView` reports where its "5h" figure is.
        _ = try PetStage.image(NotchRootView(model: model), scale: 1)
        let full = PetReelScript.meal(.full, chews: 3)
        var script = PetReelScript([(0, .idle(.content)), (0.6, .eat(full)), (0.6 + full.duration, .satisfied(.meal)),
                                    (0.6 + full.duration + 3, .idle(.content))], hunger: 22)
        script.meter(0.6 + full.swallowStart, 22 - 6 * 3)
        script.dock = [PetDockChange(t: -10, kind: .expand)]
        layer.timeline = script.timeline
        layer.seed = 7
        layer.rate = .fps(60)
        layer.dock = script.dockTrack(at: 0)
        layer.zones = PetLayout.zones(frames: frames, aggregate: store.aggregate, showEars: true, fiveHour: fiveHour)
        XCTAssertNotNil(fiveHour, "the panel reported its 5h figure")
        try Self.fresh(dir)
        let crop = CGRect(x: 236 - 300, y: 0, width: 600, height: 200)
        for n in 0..<Int(4.0 * 60) {
            let t = Double(n) / 60
            layer.now = { t }
            try Self.write(Shot(model: model, crop: crop), scale: 2, to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
    }

    // MARK: The moods, at the size of the strip

    /// Each mood resting beside its readout: at real size (2x pixels) and at 4x.
    func moods(_ out: URL) throws {
        let frames = PetStage.frames(.beside)
        let aggregate = PetStage.aggregate(left: 41)
        let notch = PetLayout.window(try XCTUnwrap(frames.notch), in: frames)
        let crop = CGRect(x: notch.minX - 116, y: 0, width: 136, height: 40)
        let cases: [(String, PetMood, Double)] = [("full", .full, -20), ("content", .content, 22), ("peckish", .peckish, 50),
                                                  ("hungry", .hungry, 85)]
        for scale in [CGFloat(2), 4] {
            var cells: [(image: CGImage, label: String)] = []
            for (name, mood, hunger) in cases {
                let layer = PetLayer()
                layer.timeline = PetReelScript([(0, .idle(mood))], hunger: hunger).timeline
                layer.seed = 7
                layer.zones = PetStage.zones(frames, aggregate)
                var t = 8.0
                while PetRigIdle.blinkOpen(at: t, seed: 7) < 0.999 || PetRigIdle.blinkOpen(at: t - 0.2, seed: 7) < 0.999 { t += 0.05 }
                layer.now = { t }
                let shot = Shot(model: Self.strip(frames, aggregate, layer: layer), crop: crop)
                cells.append((try PetStage.image(shot, scale: scale), name))
            }
            let sheet = PetStage.Sheet(title: scale == 2 ? "The moods at real size (2x pixels), on the real strip"
                                                         : "The moods at 4x, on the real strip",
                                       cells: cells, columns: 4, labelSize: scale == 2 ? 13 : 18)
            try Self.write(sheet, scale: 1, to: out.appendingPathComponent(scale == 2 ? "moods-real-size.png" : "moods-4x.png"))
        }
    }
}
