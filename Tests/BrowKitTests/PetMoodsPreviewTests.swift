// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// Previews of the two ends of the meter, through Brow's real window offscreen: the strip, `EarsView`, the
/// outline, `PanelView` and the pet's own layer, on the flat cream desktop of Brow's pictures. Every number
/// in them is made up. Skipped unless `PET_MOODS_DIR` names an output folder outside the repository:
///
///     PET_MOODS_DIR=/path/to/out swift test -c release --filter PetMoodsPreviewTests/testRenderTheStills
///
/// One test per kind of output, each best run in a process of its own: the sheets (`testRenderTheStills`),
/// the films of the strip (`testRenderTheFilms`, `PET_MOODS_FILMS` names some), the panel's header and its
/// greetings (`testRenderThePanel`), the sleep at the 5-hour limit (`testRenderTheSleep`) and a day through
/// the brain (`testRenderTheDay`). A film is a `frames-<name>` folder of PNG frames at 60 fps: the 4x zoom
/// (`z0000.png`) over the strip at real size (`r0000.png`), or the panel (`p0000.png`); ffmpeg makes them
/// into films.
@MainActor
final class PetMoodsPreviewTests: XCTestCase {
    static func outDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["PET_MOODS_DIR"], !dir.isEmpty else {
            throw XCTSkip("set PET_MOODS_DIR to render the mood previews")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testRenderTheStills() throws {
        let out = try Self.outDir()
        try ladder(out)
        try sheet(out, name: "stuffed", title: "Stuffed", poses: Self.stuffedPoses)
        try sheet(out, name: "famished", title: "Famished", poses: Self.famishedPoses)
        try layouts(out)
    }

    func testRenderTheFilms() throws {
        let out = try Self.outDir()
        let only = ProcessInfo.processInfo.environment["PET_MOODS_FILMS"].map { Set($0.split(separator: ",").map(String.init)) }
        for reel in Self.films where only?.contains(reel.name) ?? true {
            try film(reel, to: out.appendingPathComponent("frames-\(reel.name)"))
        }
    }

    func testRenderThePanel() async throws {
        let out = try Self.outDir()
        try await panel(out)
        for mood in [PetMood.stuffed, .famished] {
            try await panelGreeting(mood, to: out.appendingPathComponent("frames-panel-greeting-\(mood)"))
        }
    }

    func testRenderTheSleep() throws {
        let out = try Self.outDir()
        let asleep = Self.asleepReel
        for (scale, suffix) in [(CGFloat(4), "4x"), (CGFloat(2), "real-size")] {
            let image = try Self.image(Pose(label: "", script: asleep.script, t: 9.6, left: 100), scale: scale)
            try Self.writePNG(image, pointsPerPixel: scale == 2 ? 0.5 : 1, to: out.appendingPathComponent("asleep-\(suffix).png"))
        }
        try film(asleep, to: out.appendingPathComponent("frames-asleep"))
    }

    func testRenderTheDay() throws {
        try dayFilm(try Self.outDir().appendingPathComponent("frames-day"))
    }

    // MARK: The window on a cream desktop

    /// Brow's window at one instant, cropped, on the flat cream desktop of Brow's pictures, with the pointer
    /// while it is on the desktop and a caption on the desktop under the strip.
    struct Shot: View {
        let model: NotchPanelModel
        let crop: CGRect
        var progress: CGFloat?
        var pointer: CGPoint?
        var caption: String?

        var body: some View {
            ZStack(alignment: .topLeading) {
                Desktop().frame(width: crop.width, height: crop.height)
                NotchRootView(model: model, outlineProgress: progress)
                    .offset(x: -crop.minX, y: -crop.minY)
                if let pointer { PetStage.Pointer().offset(x: pointer.x - crop.minX, y: pointer.y - crop.minY) }
                if let caption {
                    Text(caption)
                        .font(.system(size: 5.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.32, green: 0.27, blue: 0.2))
                        .padding(.leading, 3)
                        .frame(width: crop.width, height: crop.height - 33, alignment: .leading)
                        .offset(y: 33)
                }
            }
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .dark)
        }
    }

    /// The desktop of Brow's pictures: plain cream (#F3E8D2) under a lighter menu-bar band, both flat.
    struct Desktop: View {
        var body: some View {
            ZStack(alignment: .top) {
                Color(red: 0xF3 / 255, green: 0xE8 / 255, blue: 0xD2 / 255)
                Rectangle().fill(Color(red: 0xFA / 255, green: 0xF4 / 255, blue: 0xE7 / 255)).frame(height: 33)
            }
        }
    }

    /// One pose: a segment script seen at `t`.
    struct Pose {
        var label: String
        var script: PetReelScript
        var t: Double
        var left: Double = 41
    }

    static func image(_ pose: Pose, scale: CGFloat, frames: NotchFrames = PetStage.frames(.beside), crop: CGRect? = nil,
                      seed: UInt64 = 7) throws -> CGImage {
        let aggregate = PetStage.aggregate(left: pose.left)
        let crop = try crop ?? (frames.notch == nil ? PetReels.crop(frames) : stillCrop(frames))
        let layer = PetLayer()
        layer.timeline = pose.script.timeline
        layer.seed = seed
        layer.zones = PetStage.zones(frames, aggregate)
        layer.now = { pose.t }
        let model = PetFinalRenderTests.strip(frames, aggregate, layer: layer)
        return try PetStage.image(Shot(model: model, crop: crop), scale: scale)
    }

    /// The strip from the left readout to the notch, beside; its middle, below.
    static func stillCrop(_ frames: NotchFrames) throws -> CGRect {
        let notch = PetLayout.window(try XCTUnwrap(frames.notch), in: frames)
        if frames.placement == .below { return CGRect(x: notch.minX - 4, y: 18, width: 136, height: 40) }
        return CGRect(x: notch.minX - 116, y: 0, width: 136, height: 40)
    }

    /// A PNG that says how many points a pixel is, so that a viewer showing it at its own size shows a 2x
    /// sheet at the size the strip has on a Retina screen.
    static func writePNG(_ image: CGImage, pointsPerPixel: CGFloat = 1, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) * pointsPerPixel, height: CGFloat(image.height) * pointsPerPixel)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    // MARK: Finding the beats

    static let hunger: [PetMood: Double] = [.stuffed: -46, .full: -20, .content: 20, .peckish: 50, .hungry: 80, .famished: 96]

    static func idle(_ mood: PetMood) -> PetReelScript {
        PetReelScript([(0, .idle(mood))], hunger: hunger[mood] ?? 30)
    }

    /// The gestures an idle of `mood` that started at 0 really plays, in the first `span` seconds.
    static func gestures(_ mood: PetMood, span: Double = 900, seed: UInt64 = 7) -> [PetRigMoodBeats.Gesture] {
        let segment = PetSegment(start: 0, behaviour: .idle(mood))
        return PetRigMoodBeats.gestures(in: segment, previous: nil, at: span, lookBack: span, seed: seed, reduceMotion: false)
    }

    /// The start of the first `beat` after `t` that really plays.
    static func start(of beat: PetRigMoodBeats.Beat, mood: PetMood, after t: Double, seed: UInt64 = 7) -> Double {
        gestures(mood, seed: seed).first { $0.item == .beat(beat) && $0.at > t }?.at ?? .infinity
    }

    /// An instant at or after `t` in an idle of `mood` when no gesture plays around it, no blink or glance is
    /// near and, stuffed, the eyes are shut in bliss: a plain moment of its rest.
    static func quiet(_ mood: PetMood, after t: Double, seed: UInt64 = 7) -> Double {
        let all = mood == .stuffed || mood == .famished ? gestures(mood, seed: seed) : []
        var t = t
        while true {
            let busy = all.contains { $0.at < t + 0.6 && $0.end > t - 0.6 }
                || !PetRigIdle.smalls.recent(at: t + 0.3, lookBack: 2.0, seed: seed).isEmpty
                || !PetRigIdle.rares.recent(at: t + 0.3, lookBack: 4.0, seed: seed).isEmpty
                || !PetRigIdle.glances.recent(at: t + 0.3, lookBack: 4.0, seed: seed).isEmpty
            let blink = PetRigIdle.blinkOpen(at: t, seed: seed) < 0.999 || PetRigIdle.blinkOpen(at: t - 0.25, seed: seed) < 0.999
            let open = mood == .stuffed && PetRigMoodBeats.blissOpens.recent(at: t + 0.4, lookBack: 4, seed: seed)
                .contains { $0.at > 1.5 && t + 0.4 - $0.at < PetRigMoodBeats.blissHold($0.k, seed: seed) + 0.6 }
            if !busy && !blink && !open { return t }
            t += 0.25
        }
    }

    /// An instant when the stuffed eyes are open out of their bliss, held, with no blink.
    static func blissOpen(after t: Double, seed: UInt64 = 7) -> Double {
        let all = gestures(.stuffed, seed: seed)
        for (k, at) in PetRigMoodBeats.blissOpens.recent(at: t + 300, lookBack: 300, seed: seed) where at > t {
            let mid = at + 0.9
            if !all.contains(where: { $0.at < at + PetRigMoodBeats.blissHold(k, seed: seed) && $0.end > at - 0.1 }),
               PetRigIdle.blinkOpen(at: mid, seed: seed) > 0.999, PetRigIdle.blinkOpen(at: mid - 0.25, seed: seed) > 0.999 {
                return mid
            }
        }
        return t
    }

    // MARK: Stills

    /// Each mood resting beside its readout, the two new ends with today's four between them.
    func ladder(_ out: URL) throws {
        let poses = PetMood.allCases.map { mood in
            Pose(label: "\(mood), H \(Int(Self.hunger[mood] ?? 0))", script: Self.idle(mood), t: Self.quiet(mood, after: 8))
        }
        for (scale, suffix, title) in [(CGFloat(4), "4x", "The moods at 4x, on the real strip"),
                                       (CGFloat(2), "real-size", "The moods at real size (2x pixels)")] {
            let cells = try poses.map { (image: try Self.image($0, scale: scale), label: $0.label) }
            let sheet = PetStage.Sheet(title: title, cells: cells, columns: 6, labelSize: scale == 2 ? 12 : 17)
            try Self.writePNG(try PetStage.image(sheet, scale: 1), pointsPerPixel: scale == 2 ? 0.5 : 1,
                              to: out.appendingPathComponent("ladder-\(suffix).png"))
        }
    }

    func sheet(_ out: URL, name: String, title: String, poses: [Pose]) throws {
        for (scale, suffix) in [(CGFloat(4), "4x"), (CGFloat(2), "real-size")] {
            let cells = try poses.map { (image: try Self.image($0, scale: scale), label: $0.label) }
            let sheet = PetStage.Sheet(title: "\(title), \(scale == 4 ? "at 4x" : "at real size (2x pixels)")",
                                       cells: cells, columns: 5, labelSize: scale == 2 ? 12 : 17)
            try Self.writePNG(try PetStage.image(sheet, scale: 1), pointsPerPixel: scale == 2 ? 0.5 : 1,
                              to: out.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    static var stuffedMeal: (script: PetReelScript, meal: PetMeal) {
        let more = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .stuffed)
        var script = PetReelScript([(0, .idle(.stuffed)), (1.5, .eat(more)), (1.5 + more.duration, .satisfied(.brim)),
                                    (4.5 + more.duration, .idle(.stuffed))], hunger: -40)
        script.meter(1.5 + more.swallowStart, -50)
        return (script, more)
    }

    static var gratefulMeal: (script: PetReelScript, meal: PetMeal) {
        let meal = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .famished)
        var script = PetReelScript([(0, .idle(.famished)), (1.5, .eat(meal)), (1.5 + meal.duration, .satisfied(.grateful)),
                                    (4.5 + meal.duration, .idle(.hungry))], hunger: 96)
        script.meter(1.5 + meal.swallowStart, 78)
        return (script, meal)
    }

    static var stuffedPoses: [Pose] {
        let stuffed = idle(.stuffed)
        let meal = stuffedMeal
        return [
            Pose(label: "full, as today", script: idle(.full), t: quiet(.full, after: 8)),
            Pose(label: "at rest: eyes shut in bliss", script: stuffed, t: quiet(.stuffed, after: 8)),
            Pose(label: "now and then the eyes open", script: stuffed, t: blissOpen(after: 8)),
            Pose(label: "all good: a thumbs-up and a wink", script: stuffed,
                 t: start(of: .okay, mood: .stuffed, after: 5) + 1.3),
            Pose(label: "pat-pat on the belly", script: stuffed, t: start(of: .pat, mood: .stuffed, after: 5) + 0.9),
            Pose(label: "a contented sigh", script: stuffed, t: start(of: .sigh, mood: .stuffed, after: 5) + 1.25),
            Pose(label: "room for more: a peek at the number", script: stuffed,
                 t: start(of: .roomForMore, mood: .stuffed, after: 5) + 0.75),
            Pose(label: "a hiccup", script: stuffed, t: start(of: .hiccup, mood: .stuffed, after: 5) + 0.45),
            Pose(label: "and still it eats more", script: meal.script, t: 1.5 + 0.95),
            Pose(label: "after it: pat-pat, thumbs-up", script: meal.script, t: 1.5 + meal.meal.duration + 1.85),
        ]
    }

    static var famishedPoses: [Pose] {
        let famished = idle(.famished)
        let meal = gratefulMeal
        let grumble = start(of: .grumble, mood: .famished, after: 5)
        return [
            Pose(label: "hungry, as today", script: idle(.hungry), t: quiet(.hungry, after: 8)),
            Pose(label: "at rest: on its toes, reaching for the number", script: famished, t: quiet(.famished, after: 8)),
            Pose(label: "the tummy grumbles", script: famished, t: grumble + 0.3),
            Pose(label: "a pat on the tummy", script: famished, t: grumble + 0.95),
            Pose(label: "reaching on tiptoe", script: famished, t: start(of: .reach, mood: .famished, after: 5) + 1.2),
            Pose(label: "please?", script: famished, t: start(of: .please, mood: .famished, after: 5) + 1.3),
            Pose(label: "a hop of joy: food!", script: meal.script, t: 1.5 + 0.17),
            Pose(label: "chewing, swaying", script: meal.script, t: 1.5 + 0.95),
            Pose(label: "the most grateful meal: a hug", script: meal.script, t: 1.5 + meal.meal.duration + 1.0),
            Pose(label: "more?", script: meal.script, t: 1.5 + meal.meal.duration + 2.45),
        ]
    }

    /// Both ends under the notch (scale 0.80, the food to the right) and on the pill of a display with no
    /// notch (scale 0.82): at rest, and the beat that says the mood.
    func layouts(_ out: URL) throws {
        let poses = [
            Pose(label: "stuffed: at rest", script: Self.idle(.stuffed), t: Self.quiet(.stuffed, after: 8)),
            Pose(label: "stuffed: thumbs-up", script: Self.idle(.stuffed), t: Self.start(of: .okay, mood: .stuffed, after: 5) + 1.3),
            Pose(label: "famished: at rest", script: Self.idle(.famished), t: Self.quiet(.famished, after: 8)),
            Pose(label: "famished: please?", script: Self.idle(.famished),
                 t: Self.start(of: .please, mood: .famished, after: 5) + 1.3),
        ]
        for (name, frames, title) in [("below", PetStage.frames(.below), "Under the notch (scale 0.80)"),
                                      ("pill", PetStage.frames(.beside, notch: false), "No notch: the pill (scale 0.82)")] {
            for (scale, suffix) in [(CGFloat(4), "4x"), (CGFloat(2), "real-size")] {
                let cells = try poses.map { (image: try Self.image($0, scale: scale, frames: frames), label: $0.label) }
                let sheet = PetStage.Sheet(title: "\(title), \(scale == 4 ? "at 4x" : "at real size (2x pixels)")",
                                           cells: cells, columns: 4, labelSize: scale == 2 ? 12 : 17)
                try Self.writePNG(try PetStage.image(sheet, scale: 1), pointsPerPixel: scale == 2 ? 0.5 : 1,
                                  to: out.appendingPathComponent("layout-\(name)-\(suffix).png"))
            }
        }
    }

    // MARK: Films of the strip

    /// One film: a segment script, what the readout says, and the stretches of it to show.
    struct Reel {
        var name: String
        var script: PetReelScript
        var from: Double
        var duration: Double
        var seed: UInt64 = 7
        var readout: (Double) -> Double = { _ in 41 }
        var caption: (Double) -> String? = { _ in nil }
    }

    /// The pet's wing at 4x, and the strip at real size (2x pixels) under it.
    static let zoomCrop = CGRect(x: 48, y: 0, width: 150, height: 44)
    static let realCrop = CGRect(x: -52, y: 0, width: 300, height: 44)

    func film(_ reel: Reel, to dir: URL) throws {
        try PetFinalRenderTests.fresh(dir)
        let frames = PetStage.frames(.beside)
        let layer = PetLayer()
        layer.timeline = reel.script.timeline
        layer.seed = reel.seed
        layer.rate = .fps(60)
        for n in 0..<Int((reel.duration * 60).rounded()) {
            let t = reel.from + Double(n) / 60
            let aggregate = PetStage.aggregate(left: reel.readout(t))
            layer.pointer = reel.script.pointerTrack(at: t)
            layer.dock = reel.script.dockTrack(at: t)
            layer.zones = PetStage.zones(frames, aggregate)
            layer.now = { t }
            let model = PetFinalRenderTests.strip(frames, aggregate, layer: layer)
            let pointer = reel.script.pointer.last(where: { $0.t <= t && t - $0.t < 1.0 / 60 + 1e-9 })?.location
            for (crop, scale, tag) in [(Self.zoomCrop, CGFloat(4), "z"), (Self.realCrop, CGFloat(2), "r")] {
                let shot = Shot(model: model, crop: crop, pointer: pointer, caption: tag == "z" ? reel.caption(t) : nil)
                try PetStage.writePNG(try PetStage.image(shot, scale: scale),
                                      to: dir.appendingPathComponent(String(format: "%@%04d.png", tag, n)))
            }
        }
    }

    /// Where in seed 7's first ten minutes of `mood` a stretch of `length` seconds holds the most beats.
    static func busiest(_ mood: PetMood, length window: Double) -> Double {
        let all = gestures(mood, span: 640).filter { if case .beat = $0.item { return true }; return false }
        var best = (from: 10.0, count: -1)
        for from in stride(from: 5.0, through: 600 - window, by: 1) {
            let inside = all.filter { $0.at > from + 0.5 && $0.end < from + window }
            let kinds = Set(inside.map { "\($0.item)" }).count
            let count = inside.count + kinds
            if count > best.count { best = (from, count) }
        }
        return best.from
    }

    static var asleepReel: Reel {
        typealias B = PetTuning.Behaviour
        let last = PetMeal(size: .full, chews: 2, feast: false, points: 3, reduceMotion: false, mood: .stuffed)
        var script = PetReelScript([(0, .idle(.stuffed)), (1.0, .eat(last)), (1.0 + last.duration, .fallAsleep),
                                    (1.0 + last.duration + B.fallAsleep, .asleep)], hunger: -46)
        script.meter(1.0 + last.swallowStart, -50)
        return Reel(name: "asleep", script: script, from: 0, duration: 12, readout: { $0 < 1.0 ? 97 : 100 })
    }

    static var films: [Reel] {
        var reels: [Reel] = []
        reels.append(Reel(name: "stuffed-at-rest-real-pace", script: idle(.stuffed), from: busiest(.stuffed, length: 40),
                          duration: 40))
        reels.append(Reel(name: "famished-at-rest-real-pace", script: idle(.famished), from: busiest(.famished, length: 40),
                          duration: 40))
        // A meal on a full belly: the eyes pop open, a lazy lunge, chews, the belly bounces; pat-pat,
        // thumbs-up, a sigh.
        reels.append(Reel(name: "stuffed-eats-more", script: stuffedMeal.script, from: 0, duration: 8.5,
                          readout: { $0 < 1.5 ? 41 : 44 }))
        // Into stuffed: a feast on a full pet, the belly rounding as the light lands, pats, a hiccup, a
        // thumbs-up, a sigh.
        let feast = PetMeal(size: .full, chews: 3, feast: true, points: 9, reduceMotion: false, mood: .full)
        var intoStuffed = PetReelScript([(0, .idle(.full)), (1.5, .eat(feast)), (1.5 + feast.duration, .satisfied(.feast)),
                                         (5.5 + feast.duration, .idle(.stuffed))], hunger: -8)
        intoStuffed.meter(1.5 + feast.swallowStart, -50)
        reels.append(Reel(name: "into-stuffed-feast", script: intoStuffed, from: 0, duration: 11, readout: { $0 < 1.5 ? 41 : 50 }))
        // Out of stuffed: the meter rises past −30 (an hour of hunger in a few seconds) and it settles into
        // full over 2 s, the eyes opening on their own quick clock.
        var settles = PetReelScript([(0, .idle(.stuffed)), (4.0, .idle(.full))], hunger: -34)
        settles.timeline.meter = [PetMeterKey(t: 0, value: -34, rate: 1), PetMeterKey(t: 4.0, value: -30, rate: 0)]
        reels.append(Reel(name: "stuffed-settles-to-full", script: settles, from: 1.0, duration: 7))
        // Into famished: the meter crosses 90 while it waits, hungry, well after its last rumble; it rises on
        // its toes and the tummy says so at once.
        var intoFamished = PetReelScript([(0, .idle(.hungry)), (12.0, .idle(.famished))], hunger: 87)
        intoFamished.timeline.meter = [PetMeterKey(t: 0, value: 87, rate: 0.25), PetMeterKey(t: 12.0, value: 90, rate: 0)]
        reels.append(Reel(name: "into-famished", script: intoFamished, from: 9.5, duration: 8))
        // The most grateful meal: famished, a hop of joy, chews swaying, hugs itself, more?
        reels.append(Reel(name: "famished-grateful-meal", script: gratefulMeal.script, from: 0, duration: 9,
                          readout: { $0 < 1.5 ? 41 : 44 }))
        return reels
    }

    // MARK: The panel

    /// Brow's window with the panel open on its header row: words, meter and stage at scale 2.
    struct PanelSetup {
        let model: NotchPanelModel
        let frames: NotchFrames
        let fiveHour: CGRect?
    }

    func panelWindow(store: LimitsStore, clock: PanelClock, words: PetPanelModel, layer: PetLayer) throws -> PanelSetup {
        var fiveHour: CGRect?
        words.fiveHourFrameChanged = { fiveHour = $0 }
        let probe = NSHostingView(rootView: PanelView(store: store, clock: clock, topInset: 40, flare: 6, drawsBackground: false,
                                                      pet: words, onSettings: {}, onRefresh: {})
            .frame(width: 472))
        let height = max(NotchPanelController.estimatedExpandedHeight(barCounts: [2], topInset: 40, pet: true),
                         probe.fittingSize.height)
        let frames = NotchGeometry.frames(for: PetStage.notched, expandedHeight: height, placement: .beside)
        let model = NotchPanelModel(frames: frames, pet: layer)
        model.ears = AnyView(EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        model.panel = AnyView(PanelView(store: store, clock: clock, topInset: frames.contentTopInset, flare: frames.flare,
                                        drawsBackground: false, pet: words, onSettings: {}, onRefresh: {})
            .frame(width: frames.expanded.width))
        model.expanded = true
        // One render of the open window: `PanelView` reports where its "5h" figure is.
        _ = try PetStage.image(NotchRootView(model: model), scale: 1)
        return PanelSetup(model: model, frames: frames, fiveHour: fiveHour)
    }

    /// The header with the new words and the meter: stuffed giving its thumbs-up, famished asking please.
    func panel(_ out: URL) async throws {
        let wall0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, _) = try await PetAppFixture.store([.init()], now: wall0)
        let clock = PanelClock(now: { wall0 })
        var cells: [(image: CGImage, label: String)] = []
        for (mood, header, meter) in [(PetMood.stuffed, PetText.Header(word: "Stuffed", detail: "Ate 9 % · 2 min ago", moment: nil), 0.0),
                                      (.famished, PetText.Header(word: "Famished", detail: "Last meal 5 h ago", moment: nil), 96)] {
            let words = PetPanelModel()
            words.header = header
            words.meter = meter
            let layer = PetLayer()
            let setup = try panelWindow(store: store, clock: clock, words: words, layer: layer)
            var script = Self.idle(mood)
            script.dock = [PetDockChange(t: -10, kind: .expand)]
            let beat: PetRigMoodBeats.Beat = mood == .stuffed ? .okay : .please
            let t = Self.start(of: beat, mood: mood, after: 5) + 1.3
            layer.timeline = script.timeline
            layer.seed = 7
            layer.dock = script.dockTrack(at: t)
            layer.zones = PetLayout.zones(frames: setup.frames, aggregate: store.aggregate, showEars: true, fiveHour: setup.fiveHour)
            layer.now = { t }
            let shot = Shot(model: setup.model, crop: CGRect(x: 0, y: 0, width: 472, height: 150))
            cells.append((try PetStage.image(shot, scale: 2), mood == .stuffed ? "Stuffed: the header, a thumbs-up"
                                                                                : "Famished: the header, please?"))
        }
        let sheet = PetStage.Sheet(title: "In the panel (2x pixels)", cells: cells, columns: 2, labelSize: 22)
        try Self.writePNG(try PetStage.image(sheet, scale: 1), pointsPerPixel: 0.5, to: out.appendingPathComponent("panel.png"))
    }

    /// The real controller on a moved clock: the pointer comes up, the panel opens on Brow's spring, the pet
    /// hops into the header, and the brain's greeting plays, a thumbs-up stuffed, please famished. Then the
    /// pointer goes over the rows. 600 × 200 pt at 2x, 60 fps.
    func panelGreeting(_ mood: PetMood, to dir: URL) async throws {
        typealias H = PetTuning.Hop
        try PetFinalRenderTests.fresh(dir)
        let wall0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, root) = try await PetAppFixture.store([.init()], now: wall0)
        let petStore = PetStore(directory: root.appendingPathComponent("pet").path)
        var save = PetSave(seed: 7, bornAt: wall0.addingTimeInterval(-3 * 86_400))
        save.introDone = true
        save.hunger = mood == .stuffed ? -46 : 96
        save.lastMealAt = wall0.addingTimeInterval(mood == .stuffed ? -120 : -5 * 3600 - 300)
        save.lastMealPoints = mood == .stuffed ? 9.2 : 3
        save.savedAt = wall0.addingTimeInterval(-60)
        try petStore.save(save)
        // A start at which the pet's own gestures leave the first seconds free, so the greeting plays as
        // the brain cues it.
        let segment = { (start: Double) in PetSegment(start: start, behaviour: .idle(mood)) }
        var mono0: TimeInterval = 50_000
        while !PetRigMoodBeats.gestures(in: segment(mono0), previous: nil, at: mono0 + 8, lookBack: 8, seed: 7,
                                        reduceMotion: false).isEmpty {
            mono0 += 7
        }
        let clock = PetTestClock(PetTime(wall: wall0, mono: mono0))
        let pet = PetController(store: store, petStore: petStore, clock: { clock.now }, senses: false,
                                defaults: UserDefaults(suiteName: "brow-pet-render-\(UUID().uuidString)")!)
        let setup = try panelWindow(store: store, clock: PanelClock(now: { wall0 }), words: pet.panel, layer: pet.layer)
        pet.layout(frames: setup.frames, aggregate: store.aggregate, showEars: true)
        setup.model.expanded = false
        pet.start()
        let open = 1.0
        var path = PetReelScript()
        path.pointerPath([(0.2, 330, 150), (0.6, 250, 70), (0.95, 205, 22), (1.6, 200, 70), (2.6, 230, 120),
                          (4.6, 300, 150), (5.4, 320, 160)])
        let crop = CGRect(x: 236 - 300, y: 0, width: 600, height: 200)
        var fed = 0
        for n in 0..<Int(5.5 * 60) {
            let t = Double(n) / 60
            while fed < path.pointer.count, path.pointer[fed].t <= t {
                let sample = path.pointer[fed]
                clock.now = PetTime(wall: wall0.addingTimeInterval(sample.t), mono: mono0 + sample.t)
                pet.pointerMoved(to: sample.location)
                fed += 1
            }
            clock.now = PetTime(wall: wall0.addingTimeInterval(t), mono: mono0 + t)
            if t >= open, !pet.expanded { pet.dockChanged(expanded: true) }
            pet.timerFired()
            setup.model.expanded = pet.expanded
            pet.layer.now = { mono0 + t }
            let progress = t < open ? 0 : CGFloat(PetLayout.springProgress(t - open, response: H.openResponse, damping: H.openDamping))
            let pointer = path.pointer.last(where: { $0.t <= t && t - $0.t < 0.02 })?.location
            try PetStage.writePNG(try PetStage.image(Shot(model: setup.model, crop: crop, progress: progress, pointer: pointer), scale: 2),
                                  to: dir.appendingPathComponent(String(format: "p%04d.png", n)))
        }
        XCTAssertTrue(pet.brain.timeline.cues.contains { $0.kind == .greet }, "the brain greeted")
        pet.flush()
    }

    // MARK: A day

    /// One day at the two ends of the meter, played by the real brain and drawn in stretches: famished in
    /// the morning, a grateful meal, a feast that stuffs it, a thumbs-up, the 5-hour limit and a sweet sleep,
    /// and in the evening back to full. The brain runs at the speed of life; the story skips hours between
    /// the stretches, with `debugHunger` standing in for what those hours did to the meter. Each stretch is
    /// drawn from the brain's timeline as it stands just after it, which holds its past.
    func dayFilm(_ dir: URL) throws {
        try PetFinalRenderTests.fresh(dir)
        var pet = PetHarness(seed: 7, hunger: 89.95)
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 8, fiveReset: 5_000, week: 22, weekReset: 4 * 86_400)]
        pet.start()
        var readouts: [(Double, Double)] = [(0, 8)]
        func read(_ five: Double, at t: Double) {
            pet.accounts[0].five = five
            pet.refresh(at: t)
            readouts.append((t, five))
        }
        func readout(_ t: Double) -> Double { readouts.last { $0.0 <= t }?.1 ?? 8 }
        let frames = PetStage.frames(.beside)
        var n = 0
        var notes: [String] = []
        func render(_ from: Double, _ to: Double, _ caption: String) throws {
            pet.run(to: to + 3)
            var timeline = pet.brain.timeline
            timeline.segments = pet.played(0...(to + 3))
            let layer = PetLayer()
            layer.timeline = timeline
            layer.seed = 7
            layer.rate = .fps(60)
            notes.append(String(format: "%@: %.2f to %.2f s, from frame %d", caption, from, to, n))
            var t = from
            while t < to - 1e-9 {
                let aggregate = PetStage.aggregate(left: readout(t))
                layer.zones = PetStage.zones(frames, aggregate)
                layer.now = { t }
                let model = PetFinalRenderTests.strip(frames, aggregate, layer: layer)
                for (crop, scale, tag) in [(Self.zoomCrop, CGFloat(4), "z"), (Self.realCrop, CGFloat(2), "r")] {
                    let shot = Shot(model: model, crop: crop, caption: tag == "z" ? caption : nil)
                    try PetStage.writePNG(try PetStage.image(shot, scale: scale),
                                          to: dir.appendingPathComponent(String(format: "%@%04d.png", tag, n)))
                }
                n += 1
                t += 1.0 / 60
            }
        }
        // 09:00: hungry, waiting; the meter crosses 90 and it rises on its toes, the tummy grumbling.
        try render(3, 13, "09:00 · hungry, and then famished")
        // 09:12: still famished, it asks.
        pet.run(to: 420)
        let askAt = Self.firstGesture(.please, in: pet, after: 30, before: 420) ?? 60
        try render(askAt - 0.8, askAt + 4.4, "09:12 · please?")
        // 09:30: Claude Code starts; the first numbers: the most grateful meal.
        let work = max(askAt + 8, 430)
        pet.send(.prompt, at: work)
        read(11, at: work + 3)
        try render(work - 0.5, work + 9.5, "09:30 · Claude Code at work: the most grateful meal")
        // 12:40: a morning's work later, a big session: a feast, and it is stuffed.
        let noon = work + 40
        pet.send(.debugHunger(6), at: noon - 10)
        read(20, at: noon)
        try render(noon - 0.5, noon + 10, "12:40 · a feast: stuffed")
        // 13:05: round and blissful; a thumbs-up, or a pat.
        pet.run(to: noon + 300)
        let beat = Self.firstGesture(.okay, in: pet, after: noon + 15, before: noon + 300)
            ?? Self.firstGesture(.pat, in: pet, after: noon + 15, before: noon + 300) ?? noon + 20
        try render(beat - 0.8, beat + 3.6, "13:05 · stuffed and blissful")
        // 15:20: the 5-hour limit: the meal that fills it, the yawn, a sweet sleep.
        let limit = noon + 310
        read(100, at: limit)
        try render(limit - 0.5, limit + 9, "15:20 · the 5-hour limit: asleep, stuffed")
        // 17:00: the window resets; it wakes as stuffed as it fell asleep.
        let reset = 5_000.0
        pet.accounts[0].fiveReset = reset + 5 * 3600
        read(0, at: reset)
        try render(reset - 0.5, reset + 5, "17:00 · the window resets: it wakes still stuffed")
        // 19:00: an evening later the meter rises past −30: full again, the belly gone down.
        pet.send(.debugHunger(-30.2), at: reset + 20)
        pet.run(to: reset + 70)
        let full = pet.played((reset + 20)...(reset + 70)).first { $0.behaviour == .idle(.full) }?.start ?? reset + 30
        try render(full - 1.5, full + 4.5, "19:00 · the belly settles: full again")
        // What played, for the notes beside the film.
        notes += pet.played(0...(reset + 70)).map { String(format: "%9.2f  %@", $0.start, "\($0.behaviour)") }
        try notes.joined(separator: "\n").write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }

    /// The start of the first gesture `beat` the rig plays in `(after, before)` of what the brain has played.
    static func firstGesture(_ beat: PetRigMoodBeats.Beat, in pet: PetHarness, after: Double, before: Double) -> Double? {
        let segments = pet.played(0...before)
        for (i, segment) in segments.enumerated() where segment.start < before {
            let end = i + 1 < segments.count ? segments[i + 1].start : before
            let gestures = PetRigMoodBeats.gestures(in: segment, previous: i > 0 ? segments[i - 1] : nil, at: min(end, before),
                                                    lookBack: min(end, before) - segment.start, seed: 7, reduceMotion: false,
                                                    cues: pet.brain.timeline.cues)
            if let g = gestures.first(where: { $0.item == .beat(beat) && $0.at > after && $0.end < min(end, before) }) {
                return g.at
            }
        }
        return nil
    }
}
