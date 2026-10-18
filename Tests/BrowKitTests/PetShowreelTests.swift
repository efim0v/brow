// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// The pet's showreels, rendered offscreen from segment scripts on Brow's real views. Skipped unless
/// `PET_SHOWREEL_DIR` names an output folder outside the repository:
///
///     PET_SHOWREEL_DIR=/path/to/out swift test --filter PetShowreelTests
///
/// `PET_SHOWREEL_ONLY` (a comma-separated list: stills, reel, zoom, poses, meal, below, pill, den, panel)
/// renders only some of them. Frames go to sub-folders as PNGs; the films are made from them with ffmpeg.
@MainActor
final class PetShowreelTests: XCTestCase {
    func testRenderShowreels() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PET_SHOWREEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("set PET_SHOWREEL_DIR to render the pet's showreels")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = Set((ProcessInfo.processInfo.environment["PET_SHOWREEL_ONLY"] ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        func wants(_ name: String) -> Bool { only.isEmpty || only.contains(name) }
        if wants("stills") { try stills(out) }
        if wants("reel") { try film(PetReels.tour, crop: PetReels.mainCrop, scale: 2, to: out.appendingPathComponent("reel-frames")) }
        if wants("zoom") { try film(PetReels.tour, crop: PetReels.zoomCrop, scale: 4, to: out.appendingPathComponent("zoom-frames")) }
        if wants("panel") { try await panel(out.appendingPathComponent("panel-frames")) }
        if wants("poses") { try poses(out.appendingPathComponent("poses.png")) }
        if wants("meal") { try mealStrip(out.appendingPathComponent("filmstrip-eat.png")) }
        if wants("variants") { try variants(out.appendingPathComponent("variants.png")) }
        if wants("below") { try film(PetReels.below, crop: PetReels.crop(PetReels.below.frames), scale: 2, to: out.appendingPathComponent("below-frames")) }
        if wants("pill") { try film(PetReels.pill, crop: PetReels.crop(PetReels.pill.frames), scale: 2, to: out.appendingPathComponent("pill-frames")) }
        if wants("den") {
            try film(PetReels.den(.beside), crop: PetReels.crop(PetReels.den(.beside).frames), scale: 2,
                     to: out.appendingPathComponent("den-beside-frames"))
            try film(PetReels.den(.below), crop: PetReels.crop(PetReels.den(.below).frames), scale: 2,
                     to: out.appendingPathComponent("den-below-frames"))
        }
        if wants("idle") { try idle(out.appendingPathComponent("idle-frames")) }
    }

    // MARK: Sheets

    /// One pose: `behaviour` played after what the brain plays before it, `elapsed` into it, at 4x.
    func cell(_ behaviour: PetBehaviour, _ elapsed: Double, _ label: String, placement: EarsPlacement = .beside,
              notch: Bool = true, left: Double = 41, right: Double = 63, motion: PetMotion = PetMotion(),
              palette: PetPalette = .standard, edit: (inout PetReelScript) -> Void = { _ in },
              scale: CGFloat = 4) throws -> (CGImage, String) {
        var script = PetZoneSweepTests.script(for: behaviour)
        edit(&script)
        let frames = PetStage.frames(placement, notch: notch)
        let aggregate = PetStage.aggregate(left: left, right: right)
        let zones = PetStage.zones(frames, aggregate)
        let pet = script.pose(PetRig(), at: 5 + elapsed, zones: zones, motion: motion)
        let anchor = zones.strip!.anchor
        let height = frames.placement == .below ? 60.0 : (notch ? 40.0 : 32.0)
        let crop = CGRect(x: Double(anchor.x) - 58, y: 0, width: 92, height: height)
        let pointer = script.pointer.last(where: { $0.t <= 5 + elapsed && 5 + elapsed - $0.t < 0.05 })?.location
        let scene = PetStage.StripScene(frames: frames, aggregate: aggregate, pet: pet, crop: crop, palette: palette,
                                        pointer: pointer)
        return (try PetStage.image(scene, scale: scale), label)
    }

    /// Every behaviour the pet has, at a moment that shows it, on the real strip at 4x.
    func poses(_ url: URL) throws {
        let full = PetReelScript.meal(.full, chews: 3)
        let m = PetRigActions.timing(full)
        let feast = PetReelScript.meal(.full, chews: 3, feast: true, points: 9)
        let nibble = PetReelScript.meal(.nibble, chews: 2)
        let reduced = PetReelScript.meal(.full, chews: 2, reduceMotion: true)
        typealias B = PetTuning.Behaviour
        var cells: [(CGImage, String)] = []
        cells.append(try cell(.intro(noAccounts: false), 1.0, "intro: a peek out of the den"))
        cells.append(try cell(.intro(noAccounts: false), 1.75, "intro: notices the readout"))
        cells.append(try cell(.intro(noAccounts: false), 2.5, "intro: steps out"))
        cells.append(try cell(.idle(.content), 6, "idle, content"))
        cells.append(try cell(.idle(.full), 6, "idle, full", edit: { $0.meter(0, -20) }))
        cells.append(try cell(.idle(.peckish), 6, "idle, peckish", edit: { $0.meter(0, 50) }))
        cells.append(try cell(.idle(.hungry), 6, "idle, hungry: hopeful", edit: { $0.meter(0, 85) }))
        cells.append(try cell(.settled(.content), 6, "settled (half amplitude)"))
        cells.append(try cell(.unsureIdle(.content), 6.3, "unsure: at the grey dot", left: 41))
        cells.append(try cell(.perk(.prompt), 0.2, "perk: the brow flick"))
        cells.append(try cell(.eager, 3.0, "eager: eyes on the number"))
        cells.append(try cell(.eat(full), 0.18, "eat: anticipation, the glint"))
        cells.append(try cell(.eat(full), m.snap - 0.04, "eat: the lunge, the bead"))
        cells.append(try cell(.eat(full), m.snap + 0.02, "eat: the snap"))
        cells.append(try cell(.eat(full), m.chewStart + 0.16, "eat: a chew's beat"))
        cells.append(try cell(.eat(full), m.swallowStart + 0.16, "eat: the swallow, eyes follow"))
        cells.append(try cell(.eat(full), m.splash + 0.14, "eat: the light lands"))
        cells.append(try cell(.eat(feast), PetRigActions.timing(feast).swallowStart + 0.3, "eat: a feast's swallow"))
        cells.append(try cell(.eat(nibble), 0.3, "eat: a nibble"))
        cells.append(try cell(.eat(reduced), 0.6, "eat, Reduce Motion: chewing in place", motion: PetMotion(reduceMotion: true)))
        cells.append(try cell(.satisfied(.meal), 1.2, "satisfied: a pat"))
        cells.append(try cell(.satisfied(.feast), 1.48, "satisfied, feast: hic"))
        cells.append(try cell(.satisfied(.lick), 0.25, "after a nibble: a lick"))
        cells.append(try cell(.boop(giggle: false), 0.1, "boop"))
        cells.append(try cell(.boop(giggle: true), 0.6, "boop: the giggle"))
        cells.append(try cell(.celebrate(.streak(days: 7)), 0.75, "celebrate: a streak"))
        cells.append(try cell(.celebrate(.goodWeek), 0.6, "celebrate: a good week's drum"))
        cells.append(try cell(.freshWindow, 0.6, "fresh window: a hop"))
        cells.append(try cell(.fallAsleep, 0.5, "fall asleep: the yawn", left: 100))
        cells.append(try cell(.fallAsleep, 1.45, "fall asleep: the head lolls", left: 100))
        cells.append(try cell(.fallAsleep, 2.5, "fall asleep: the curl", left: 100))
        cells.append(try cell(.asleep, 3.0, "asleep: under 14 pt, Zzz", left: 100))
        cells.append(try cell(.drowsy, 1.6, "drowsy: the slow yawn", left: 100))
        cells.append(try cell(.rollOver, 0.6, "roll over, back to sleep", left: 100))
        cells.append(try cell(.wake, 0.25, "wake: one eye", left: 0))
        cells.append(try cell(.wake, B.wakeStir + 0.8, "wake: the stretch", left: 0))
        cells.append(try cell(.wake, B.wakeStir + B.wakeStretch + 0.08, "wake: the shake", left: 0))
        cells.append(try cell(.enterDen(retreat: false), 1.0, "into the den: steps", right: 100))
        cells.append(try cell(.enterDen(retreat: false), 2.8, "into the den: squeezing in", right: 100))
        cells.append(try cell(.hibernating, 3.0, "hibernating: three quarters hidden", right: 100))
        cells.append(try cell(.leaveDen(stretch: true), 0.6, "out of the den: an eye", right: 0))
        cells.append(try cell(.leaveDen(stretch: true), 1.3, "out of the den: steps out", right: 0))
        cells.append(try cell(.peek, 1.0, "no account: a peek", left: 41))
        cells.append(try cell(.dozeIn, 1.2, "doze in"))
        cells.append(try cell(.doze, 1.0, "dozing (no frames)"))
        cells.append(try cell(.welcomeBack, 0.8, "welcome back: a stretch"))
        cells.append(try cell(.off, 0.1, "off: fading"))
        cells.append(try cell(.idle(.content), 1.0, "the pointer: watched", edit: { s in
            s.pointerPath([(4.0, 60, 70), (6.5, 70, 60)]); s.cue(4.2, .notice)
        }))
        cells.append(try cell(.idle(.content), 0.45, "a fast approach after a calm: hides", edit: { s in
            s.pointer = [PetPointerSample(t: -30, location: CGPoint(x: 400, y: 400))]
            var path = PetReelScript()
            path.pointerPath([(4.6, 400, 300), (4.8, 150, 70), (7, 150, 72)])
            s.pointer += path.pointer
        }))
        cells.append(try pounceCell())
        cells.append(try cell(.idle(.content), 6, "below, scale 0.80", placement: .below))
        cells.append(try cell(.asleep, 3, "below, asleep", placement: .below, left: 100))
        cells.append(try cell(.idle(.content), 6, "the pill, scale 0.82", notch: false))
        cells.append(try cell(.hibernating, 3, "the pill: curled, glow 30 %", notch: false, right: 100))
        let sheet = PetStage.Sheet(title: "Glim in Brow: every behaviour, 4x, on the real strip (cream)", cells: cells, columns: 6,
                                   labelSize: 17)
        try PetStage.writePNG(try PetStage.image(sheet, scale: 1), to: url)
    }

    /// The rare comic failure, found in the idle schedule: the first pounce of seed 7.
    func pounceCell() throws -> (CGImage, String) {
        let script = PetReelScript([(0, .idle(.content))])
        let frames = PetStage.frames(.beside)
        let aggregate = PetStage.aggregate(left: 41)
        let zones = PetStage.zones(frames, aggregate)
        var k = 0
        var at = 0.0
        while true {
            let time = PetRigIdle.rares.time(k, seed: 7)
            if PetRigIdle.rareKind(k, seed: 7) == .pounce, time > 3 { at = time; break }
            k += 1
        }
        let pet = script.pose(PetRig(), at: at + 1.15, zones: zones)
        let anchor = zones.strip!.anchor
        let crop = CGRect(x: Double(anchor.x) - 58, y: 0, width: 92, height: 40)
        let scene = PetStage.StripScene(frames: frames, aggregate: aggregate, pet: pet, crop: crop)
        return (try PetStage.image(scene, scale: 4), "idle: the pounce that falls short")
    }

    /// Every second frame of the meal at 60 fps, 4x (41 → 44 %, a full meal of three chews).
    func mealStrip(_ url: URL) throws {
        let reel = PetReels.tour
        let rig = PetRig()
        var cells: [(CGImage, String)] = []
        let crop = CGRect(x: 66, y: 0, width: 82, height: 36)
        var n = Int(5.0 * 60)
        while Double(n) / 60 <= 5.0 + 1.98 + 0.5 {
            let t = Double(n) / 60
            cells.append((try PetStage.image(reel.scene(rig, at: t, crop: crop), scale: 4),
                          String(format: "f%d  %.3f s  (+%.3f)", n, t, t - 5)))
            n += 2
        }
        let sheet = PetStage.Sheet(title: "The meal, every second frame at 60 fps, 4x: anticipation 0.30, lunge 0.12, hold 0.06, recoil 0.18, three chews of 0.32, swallow 0.36 = 1.98 s",
                                   cells: cells, columns: 8, labelSize: 14)
        try PetStage.writePNG(try PetStage.image(sheet, scale: 1), to: url)
    }

    /// The display options the pet follows (Reduce Transparency, Increase Contrast, Reduce Motion) and the
    /// looks, side by side: the same frame, only the drawing changes.
    func variants(_ url: URL) throws {
        let full = PetReelScript.meal(.full, chews: 3)
        var cells: [(CGImage, String)] = []
        for (motion, name) in [(PetMotion(), "standard"), (PetMotion(reduceTransparency: true), "Reduce Transparency: no glow"),
                               (PetMotion(increaseContrast: true), "Increase Contrast: rim 60 %, outline")] {
            cells.append(try cell(.idle(.content), 6, name, motion: motion))
            cells.append(try cell(.eat(full), PetRigActions.timing(full).splash + 0.14, name + ", the light lands", motion: motion))
        }
        cells.append(try cell(.idle(.content), 6, "Reduce Motion: breathing, blinks", motion: PetMotion(reduceMotion: true)))
        cells.append(try cell(.eat(PetReelScript.meal(.full, chews: 2, reduceMotion: true)), 0.5, "Reduce Motion: the meal in place",
                              motion: PetMotion(reduceMotion: true)))
        for palette in PetPalette.allCases {
            cells.append(try cell(.idle(.content), 6, "look: \(palette)", palette: palette))
            cells.append(try cell(.idle(.hungry), 6, "look: \(palette), hungry", palette: palette, edit: { $0.meter(0, 85) }))
        }
        for palette in [PetPalette.cream, .original] {
            cells.append(try cell(.idle(.content), 6, "real size, \(palette)", palette: palette, scale: 2))
            cells.append(try cell(.asleep, 3, "real size, \(palette), asleep", left: 100, palette: palette, scale: 2))
        }
        let sheet = PetStage.Sheet(title: "Display options and looks: the pose is the same, only the drawing changes", cells: cells,
                                   columns: 4, labelSize: 16)
        try PetStage.writePNG(try PetStage.image(sheet, scale: 1), to: url)
    }

    /// 24 s of content idle at 30 fps, at 4x: the idle never loops.
    func idle(_ dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reel = PetReel(script: PetReelScript([(0, .idle(.content))]), duration: 24, frames: PetStage.frames(.beside),
                           readouts: { _ in PetStage.aggregate(left: 41) })
        let rig = PetRig()
        for n in 0..<(24 * 30) {
            let t = 100 + Double(n) / 30
            try PetStage.writePNG(try PetStage.image(reel.scene(rig, at: t, crop: PetReels.zoomCrop), scale: 4),
                                  to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
    }

    // MARK: The panel

    /// The pointer comes up to the strip; Brow's outline springs open and the pet hops into the header's
    /// stage; the pointer goes over the rows and the eyes follow it; it leaves, the outline closes, and the
    /// pet hops home a beat ahead of the black.
    func panel(_ dir: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, cleanup) = try await PetPanelStage.store(now: now)
        defer { cleanup() }
        let clock = PanelClock(now: { now })
        let height = NotchPanelController.estimatedExpandedHeight(barCounts: [2], topInset: 40, pet: true)
        let frames = NotchGeometry.frames(for: PetStage.notched, expandedHeight: height, placement: .beside)
        let open = 1.0, close = 3.9
        var script = PetReelScript([(0, .idle(.content))], hunger: 22)
        script.pointerPath([(0.2, 330, 150), (0.6, 250, 70), (0.95, 205, 22), (1.6, 190, 120), (2.3, 120, 150),
                            (2.9, 300, 170), (3.4, 340, 300)])
        script.cue(0.55, .notice)
        script.cue(4.2, .release)
        script.dock = [PetDockChange(t: open, kind: .expand), PetDockChange(t: close, kind: .collapse)]
        // Where the Overall line's "5h" figure is, as `PanelView` lays it out below the header.
        let fiveHour = CGRect(x: 318, y: 40 + PetTuning.Panel.addedHeight, width: 40, height: 15)
        let zones = PetLayout.zones(frames: frames, aggregate: store.aggregate, showEars: true, fiveHour: fiveHour)
        func progress(_ t: Double) -> Double {
            typealias H = PetTuning.Hop
            if t < open { return 0 }
            let opened = PetLayout.springProgress(t - open, response: H.openResponse, damping: H.openDamping)
            if t < close { return opened }
            let at = PetLayout.springProgress(close - open, response: H.openResponse, damping: H.openDamping)
            return at * (1 - PetLayout.springProgress(t - close, response: H.closeResponse, damping: H.closeDamping))
        }
        if ProcessInfo.processInfo.environment["PET_SHOWREEL_RANGE"] == nil { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = PetRig()
        let words = PetPanelStage.words()
        let crop = CGRect(x: 236 - 300, y: 0, width: 600, height: 200)
        for n in 0..<Int(5.0 * 60) {
            let t = Double(n) / 60
            let pet = script.pose(rig, at: t, zones: zones)
            let pointer = script.pointer.last(where: { $0.t <= t && t - $0.t < 0.02 })?.location
            let scene = PetPanelStage.Scene(frames: frames, store: store, clock: clock, pet: pet, words: words,
                                            progress: progress(t), crop: crop, pointer: pointer)
            try PetStage.writePNG(try PetStage.image(scene, scale: 2), to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
    }

    // MARK: Films

    /// Every frame of a reel at 60 fps, as PNGs.
    func film(_ reel: PetReel, crop: CGRect, scale: CGFloat, to dir: URL, fps: Double = 60) throws {
        if ProcessInfo.processInfo.environment["PET_SHOWREEL_RANGE"] == nil { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rig = PetRig()
        let count = Int((reel.duration * fps).rounded())
        // PET_SHOWREEL_RANGE="5.0,7.6" renders only those seconds, for a quick look while tuning.
        var range = 0..<count
        if let seconds = ProcessInfo.processInfo.environment["PET_SHOWREEL_RANGE"] {
            let v = seconds.split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { range = max(0, Int(v[0] * fps))..<min(count, Int(v[1] * fps)) }
        }
        for n in range {
            let t = Double(n) / fps
            let image = try PetStage.image(reel.scene(rig, at: t, crop: crop), scale: scale)
            try PetStage.writePNG(image, to: dir.appendingPathComponent(String(format: "f%04d.png", n)))
        }
    }

    // MARK: Stills

    /// A quick look at single poses: each cell is its own script at one instant, at 4x.
    func stills(_ out: URL) throws {
        let frames = PetStage.frames(.beside)
        let full = PetReelScript.meal(.full, chews: 3)
        let cases: [(String, PetReelScript, Double, Double)] = [
            ("content", PetReelScript([(0, .idle(.content))]), 5.0, 41),
            ("full", PetReelScript([(0, .idle(.full))], hunger: -20), 5.0, 41),
            ("peckish", PetReelScript([(0, .idle(.peckish))], hunger: 50), 5.0, 41),
            ("hungry", PetReelScript([(0, .idle(.hungry))], hunger: 85), 5.0, 41),
            ("eager", PetReelScript([(0, .eager)]), 3.0, 41),
            ("anticipation", PetReelScript([(0, .idle(.content)), (5, .eat(full))]), 5.25, 44),
            ("snap", PetReelScript([(0, .idle(.content)), (5, .eat(full))]), 5.42, 44),
            ("chew", PetReelScript([(0, .idle(.content)), (5, .eat(full))]), 5.83, 44),
            ("swallow", PetReelScript([(0, .idle(.content)), (5, .eat(full))]), 5.80 + 0.96 + 0.2, 44),
            ("satisfied", PetReelScript([(0, .idle(.content)), (5, .satisfied(.meal))]), 5.5, 44),
            ("asleep", PetReelScript([(0, .asleep)], hunger: 0), 5.0, 100),
            ("drowsy", PetReelScript([(0, .drowsy)]), 3.0, 100),
        ]
        var cells: [(CGImage, String)] = []
        let rig = PetRig()
        for (name, script, t, left) in cases {
            let aggregate = PetStage.aggregate(left: left)
            let zones = PetStage.zones(frames, aggregate)
            let pet = script.pose(rig, at: t, zones: zones)
            let crop = CGRect(x: 60, y: 0, width: 92, height: 40)
            let scene = PetStage.StripScene(frames: frames, aggregate: aggregate, pet: pet, crop: crop)
            cells.append((try PetStage.image(scene, scale: 4), name))
        }
        let sheet = PetStage.Sheet(title: "stills, 4x", cells: cells, columns: 4)
        try PetStage.writePNG(try PetStage.image(sheet, scale: 1), to: out.appendingPathComponent("stills.png"))
    }
}
