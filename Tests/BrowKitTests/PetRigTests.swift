// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// The pose function: the same timeline at the same instant gives the same frame bit for bit, whatever was
/// posed before; and what it poses keeps its timings, its extremes and its tone.
final class PetRigTests: XCTestCase {
    private let reel = PetReels.tour

    // MARK: - Determinism

    /// The same timeline at t = 12.345 directly, after 30 fps frames, and after 120 fps frames: one frame.
    func testTheSameInstantWhateverWasPosedBefore() {
        let t = 12.345
        let direct = reel.pet(PetRig(), at: t)
        let at30 = PetRig()
        for n in 0..<Int(t * 30) { _ = reel.pet(at30, at: Double(n) / 30) }
        let at120 = PetRig()
        for n in 0..<Int(t * 120) { _ = reel.pet(at120, at: Double(n) / 120) }
        XCTAssertEqual(reel.pet(at30, at: t), direct)
        XCTAssertEqual(reel.pet(at120, at: t), direct)
    }

    /// Every frame of the 16 s tour at 60 fps, played forward, in a shuffled order and backward from fresh
    /// rigs: bit-equal frame for frame. Then a rewind on the rig that has seen it all.
    func testRandomAccessAndRewindAreExact() {
        let times = (0..<960).map { Double($0) / 60 }
        let forward = PetRig()
        let sequential = times.map { reel.pet(forward, at: $0) }
        var order = Array(times.indices)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in order.indices.reversed() {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            order.swapAt(i, Int(state >> 33) % (i + 1))
        }
        let shuffled = PetRig()
        for i in order { XCTAssertEqual(reel.pet(shuffled, at: times[i]), sequential[i], "shuffled, t = \(times[i])") }
        let backward = PetRig()
        for i in times.indices.reversed() { XCTAssertEqual(reel.pet(backward, at: times[i]), sequential[i], "backward, t = \(times[i])") }
        for i in times.indices.reversed() { XCTAssertEqual(reel.pet(forward, at: times[i]), sequential[i], "rewound, t = \(times[i])") }
    }

    /// The memo only saves work. Posed forward, as the app poses, it lets go of every follow-through that
    /// has come to rest, instead of keeping the last 48 whatever they are: the tests above hold it to
    /// giving the same frames whether a track was kept, dropped or never there.
    func testTheMemoLetsGoOfWhatHasComeToRest() {
        let script = PetPerformanceTests.tenMinutes
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let rig = PetRig()
        var most = 0
        for n in 0..<(600 * 5) {
            _ = script.pose(rig, at: Double(n) / 5, zones: zones)
            most = max(most, rig.memo.held)
        }
        // Ten minutes in which every behaviour plays start dozens of sources (each action, eager's bounces,
        // the hops); a handful are ever held at once.
        XCTAssertLessThanOrEqual(most, 10, "only what is still ringing, and what came to rest moments ago")
    }

    /// Rendered frames are byte-identical across two runs: every fourth frame of the tour, posed by two
    /// fresh rigs and drawn by CoreGraphics (`PetStage.bitmap`). Not through `ImageRenderer.cgImage`: early
    /// in a process its rasterizer switches how it draws gradients and edges, a level apart here and there,
    /// at a moment that varies from run to run, so two renders of one frame could differ whatever the
    /// warm-up.
    @MainActor
    func testRenderedFramesAreByteIdentical() throws {
        func image(_ rig: PetRig, _ t: Double) throws -> CGImage {
            try PetStage.bitmap(reel.scene(rig, at: t, crop: PetReels.zoomCrop), scale: 2)
        }
        let a = PetRig(), b = PetRig()
        for n in stride(from: 0, to: 960, by: 4) {
            let t = Double(n) / 60
            let ia = try image(a, t), ib = try image(b, t)
            if try PetStage.bytes(ia) != PetStage.bytes(ib) { XCTFail("t = \(t): \(Self.difference(ia, ib))") }
        }
    }

    /// Where two images of one size differ: how many pixels, the box round them, and the largest step in
    /// any channel.
    static func difference(_ a: CGImage, _ b: CGImage) -> String {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count,
              a.bitsPerPixel == 32 else { return "images of different layouts" }
        let pa = [UInt8](da), pb = [UInt8](db)
        var count = 0, largest = 0
        var box = CGRect.null
        for i in stride(from: 0, to: pa.count, by: 4) {
            let step = (0..<4).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max() ?? 0
            guard step > 0 else { continue }
            count += 1
            largest = max(largest, step)
            let pixel = i / 4
            box = box.union(CGRect(x: pixel % (a.bytesPerRow / 4), y: pixel / (a.bytesPerRow / 4), width: 1, height: 1))
        }
        return "\(count) pixels differ, by at most \(largest), in \(box) (2x pixels of the zoom crop)"
    }

    /// Two pets blink at different times; each blinks the same on every run.
    func testSeedsShapeTheBlinks() {
        let one = PetRigIdle.blinkStarts(from: 0, to: 120, seed: 1)
        let two = PetRigIdle.blinkStarts(from: 0, to: 120, seed: 2)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one, PetRigIdle.blinkStarts(from: 0, to: 120, seed: 1))
        // Intervals of 2.4 to 6.5 s, scaled by the pet's own rate (±15 %).
        for seed: UInt64 in [1, 2, 3, 99] {
            let rate = PetRigIdle.blinkRate(seed: seed)
            let starts = PetRigIdle.blinkStarts(from: 0, to: 600, seed: seed)
            for (a, b) in zip(starts, starts.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, 2.4 * rate - 1e-9)
                XCTAssertLessThanOrEqual(b - a, 6.5 * rate + 1e-9)
            }
            XCTAssertTrue(abs(rate - 1) <= 0.15)
        }
    }

    /// The schedules are aperiodic and reach far uptimes with the same cost: a week in, blinks still come.
    func testIdleNeverLoopsAndWorksAtAnyUptime() {
        let rig = PetRig()
        let script = PetReelScript([(0, .idle(.content))])
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        func minute(_ start: Double) -> [Double] {
            stride(from: start, to: start + 60, by: 0.25).map { t in
                let p = script.pose(rig, at: t, zones: zones).pet
                return p.lookX * 3 + p.squash * 10 + p.turn + p.lidL
            }
        }
        let a = minute(100), b = minute(160), c = minute(604_800)
        XCTAssertGreaterThan(zip(a, b).map { abs($0 - $1) }.reduce(0, +), 1)
        XCTAssertGreaterThan(zip(a, c).map { abs($0 - $1) }.reduce(0, +), 1)
        XCTAssertFalse(PetRigIdle.blinkStarts(from: 604_800, to: 604_860, seed: 7).isEmpty)
    }

    // MARK: - The meal

    /// A full meal's timing, to the frame: anticipation, the snap at 0.42 s, three 0.32 s chews, the
    /// swallow at 1.62 s, the end at 1.98 s; the flare eases in over at least six frames at 60 fps.
    func testTheMealHitsItsBeats() {
        let meal = PetReelScript.meal(.full, chews: 3)
        let m = PetRigActions.timing(meal)
        XCTAssertEqual(m.snap, 0.42, accuracy: 1e-9)
        XCTAssertEqual(m.chewStart, 0.66, accuracy: 1e-9)
        XCTAssertEqual(m.swallowStart, meal.swallowStart, accuracy: 1e-9)
        XCTAssertEqual(m.end, meal.duration, accuracy: 1e-9)
        var script = PetReelScript([(0, .idle(.content)), (10, .eat(meal)), (10 + meal.duration, .satisfied(.meal))])
        // The brain keys the meter's drop at the swallow.
        script.meter(10 + meal.swallowStart, 30 - 6 * 3)
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 44))
        let rig = PetRig()
        func pose(_ e: Double) -> PetBody { script.pose(rig, at: 10 + e, zones: zones).pet }
        // The mouth is wide open just before the snap and shut just after it.
        XCTAssertGreaterThan(pose(m.snap - 1.0 / 60).mouthOpen, 0.7)
        XCTAssertLessThan(pose(m.snap + 2.0 / 60).mouthOpen, 0.1)
        // The lunge reaches toward the readout, and the body is back home for the chews.
        XCTAssertLessThan(pose(m.snap).x, Double(zones.strip!.anchor.x) - 6)
        XCTAssertEqual(pose(m.chewStart + 0.1).x, Double(zones.strip!.anchor.x), accuracy: 1.2)
        // Each chew is a whole-body beat: the body is lower mid-chew than between chews.
        for i in 0..<3 {
            let mid = pose(m.chewStart + (Double(i) + 0.5) * m.chew), edge = pose(m.chewStart + Double(i) * m.chew + 0.01)
            XCTAssertLessThan(mid.squash, edge.squash - 0.02, "chew \(i)")
        }
        // The swallowed light is on its way down during the swallow.
        XCTAssertGreaterThanOrEqual(pose(m.swallowStart + 0.15).lump, 0)
        // The flare: from its first light to its peak takes at least six frames, and its peak is soft.
        var flashes: [Double] = []
        for n in 0...Int(1.0 * 60) { flashes.append(pose(m.swallowStart + Double(n) / 60).flash) }
        let peak = flashes.indices.max { flashes[$0] < flashes[$1] }!
        let first = flashes.firstIndex { $0 > 0.01 }!
        XCTAssertGreaterThanOrEqual(peak - first, 6)
        XCTAssertLessThanOrEqual(flashes[peak], 0.45)
    }

    // MARK: - Tone and gaze

    /// Hungry is hopeful, never sad: eyes big and open, the outer lids never drooping, no frown, the eyes
    /// on the number; over a minute it licks its lips and its tummy rumbles.
    func testHungryLooksHopeful() {
        let script = PetReelScript([(0, .idle(.hungry))], hunger: 85)
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let rig = PetRig()
        var licks = 0, rumbles = 0
        for n in 0..<(120 * 30) {
            let t = 5 + Double(n) / 30
            let p = script.pose(rig, at: t, zones: zones).pet
            XCTAssertLessThanOrEqual(p.lidSlant, 0.001, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.smile, -0.05, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.eyeSize, 1.1, "t = \(t)")
            if p.tongue > 0.5 { licks += 1 }
            if abs(p.tremor) > 0.2 { rumbles += 1 }
        }
        XCTAssertGreaterThan(licks, 0)
        XCTAssertGreaterThan(rumbles, 0)
        // Eyes on the number: the food is to the left.
        let p = script.pose(rig, at: 7.0, zones: zones).pet
        XCTAssertLessThan(p.lookX, -0.3)
    }

    /// The pointer is watched, not fled: after a notice the eyes follow it and the body stays where it is.
    func testThePointerIsWatchedNotFled() {
        var script = PetReelScript([(0, .idle(.content))])
        script.pointerPath([(4.0, 40, 90), (4.5, 60, 60), (5.5, 200, 60), (6.5, 60, 60)])
        script.cue(4.1, .notice)
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let rig = PetRig()
        let anchor = Double(zones.strip!.anchor.x)
        let left = script.pose(rig, at: 4.6, zones: zones).pet
        let right = script.pose(rig, at: 5.6, zones: zones).pet
        XCTAssertLessThan(left.lookX, -0.3, "looks left at the pointer")
        XCTAssertGreaterThan(right.lookX, 0.3, "and follows it to the right")
        XCTAssertLessThan(left.lookY, 0, "it is below the strip")
        for n in 0..<120 {
            let p = script.pose(rig, at: 4 + Double(n) / 60, zones: zones).pet
            XCTAssertEqual(p.x, anchor, accuracy: 1.5, "it does not hide")
        }
    }

    /// The rare hide-and-peek: only after a long calm and a fast approach, derived from the track alone.
    func testHideAndPeekNeedsACalmAndAFastApproach() {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let anchor = Double(zones.strip!.anchor.x)
        func maxShift(calm: Double, fast: Bool) -> Double {
            var script = PetReelScript([(0, .idle(.content))])
            script.pointer = [PetPointerSample(t: 30 - calm, location: CGPoint(x: 400, y: 400))]
            let dt = fast ? 0.2 : 1.5
            let keys = [(30.0, 400.0, 300.0), (30 + dt, 140.0, 70.0), (30 + dt + 2.5, 140.0, 72.0)]
            var path = PetReelScript()
            path.pointerPath(keys)
            script.pointer += path.pointer
            let rig = PetRig()
            var shift = 0.0
            for n in 0..<240 { shift = max(shift, script.pose(rig, at: 30 + Double(n) / 60, zones: zones).pet.x - anchor) }
            return shift
        }
        XCTAssertGreaterThan(maxShift(calm: 40, fast: true), 10, "a fast approach after a long calm: it ducks")
        XCTAssertLessThan(maxShift(calm: 40, fast: false), 1.5, "a slow approach: it watches")
        XCTAssertLessThan(maxShift(calm: 3, fast: true), 1.5, "no calm before it: it watches")
    }

    // MARK: - Moments, sleep and the food

    /// A streak milestone's second hop is a twirl: mid-air the face is round the back, and it lands a
    /// whole turn later, facing out again. Under Reduce Motion there is no twirl.
    func testAStreakTwirlsAndLandsFacingOut() {
        let script = PetReelScript([(0, .idle(.content)), (5, .celebrate(.streak(days: 7)))])
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let rig = PetRig()
        let twirl = PetRigActions.twirl
        let mid = script.pose(rig, at: 5 + twirl.takeoff + twirl.air / 2, zones: zones).pet
        XCTAssertGreaterThan(mid.lift, 1, "in the air")
        XCTAssertLessThan(PetBodyGeometry(mid).faceVisibility, 0.05, "the face round the back")
        let landed = script.pose(rig, at: 5 + twirl.land + 0.1, zones: zones).pet
        XCTAssertEqual(landed.spin, 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(PetBodyGeometry(landed).faceVisibility, 1, accuracy: 1e-9)
        let still = script.pose(rig, at: 5 + twirl.takeoff + twirl.air / 2, zones: zones,
                                motion: PetMotion(reduceMotion: true)).pet
        XCTAssertEqual(still.spin, 0)
    }

    /// Asleep, a Zzz every 1.8 s for the first minute and then every 6 s, as in the den, so a sleep of
    /// hours does not keep pulling at the eye: three alive at most, and the schedule and its inverse agree.
    func testAsleepTheZzzSlowDownAfterAMinute() {
        typealias P = PetRigParticles
        XCTAssertEqual(P.asleepZzz(0), 0.3, accuracy: 1e-9)
        XCTAssertEqual(P.asleepZzz(1) - P.asleepZzz(0), PetTuning.Particles.zzzEvery, accuracy: 1e-9)
        let last = P.asleepBriskZzz - 1
        XCTAssertLessThan(P.asleepZzz(last), 60.3)
        XCTAssertGreaterThanOrEqual(P.asleepZzz(last + 1), 60.3)
        XCTAssertEqual(P.asleepZzz(last + 2) - P.asleepZzz(last + 1), PetTuning.Den.zzzEvery, accuracy: 1e-9)
        for k in 0..<60 {
            XCTAssertEqual(P.asleepZzzIndex(at: P.asleepZzz(k)), k)
            XCTAssertEqual(P.asleepZzzIndex(at: P.asleepZzz(k + 1) - 1e-6), k)
        }
        let script = PetReelScript([(0, .asleep)], hunger: 0)
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 100))
        let rig = PetRig()
        var alive: [Int] = []
        for n in 0..<(180 * 15) {
            let frame = script.pose(rig, at: Double(n) / 15, zones: zones)
            alive.append(frame.particles.filter { $0.kind == .zzz && $0.opacity > 0.01 }.count)
        }
        XCTAssertLessThanOrEqual(alive.max() ?? 0, PetTuning.Particles.zzzAlive)
        XCTAssertGreaterThan(alive[(30 * 15)..<(40 * 15)].reduce(0, +), alive[(130 * 15)..<(140 * 15)].reduce(0, +) * 2,
                             "fewer after the first minute")
    }

    /// On the pill there is no den: hibernating is a rounder ball than the 5-hour sleep's loaf, its light
    /// turned down, and no Zzz, so the two never look the same at a glance.
    func testOnThePillHibernatingIsNotTheFiveHourSleep() {
        let zones = PetStage.zones(PetStage.frames(.beside, notch: false), PetStage.aggregate(left: 41, right: 100))
        let rig = PetRig()
        let asleep = PetReelScript([(0, .asleep)], hunger: 0)
        let hibernating = PetReelScript([(0, .hibernating)], hunger: 0)
        var zzz = 0
        for n in 0..<(30 * 15) {
            zzz += hibernating.pose(rig, at: Double(n) / 15, zones: zones).particles.filter { $0.kind == .zzz }.count
        }
        XCTAssertEqual(zzz, 0, "no Zzz curled up in the ball")
        let ball = hibernating.pose(rig, at: 20, zones: zones).pet, loaf = asleep.pose(rig, at: 20, zones: zones).pet
        XCTAssertLessThan(ball.opacity, loaf.opacity - 0.2, "its light turned down")
        let b = PetBodyGeometry(ball), l = PetBodyGeometry(loaf)
        XCTAssertGreaterThan(b.height / b.halfWidth, l.height / l.halfWidth + 0.1, "rounder")
        XCTAssertLessThan(b.halfWidth, l.halfWidth, "smaller")
    }

    /// Sparkles stay under the strip's top edge: a celebration's stars slow to a stop below it rather than
    /// being cut in half by it, on the pill above all, where the strip is lowest.
    func testSparklesStayUnderTheTopEdge() {
        for (frames, left) in [(PetStage.frames(.beside, notch: false), 41.0), (PetStage.frames(.beside), 41)] {
            let zones = PetStage.zones(frames, PetStage.aggregate(left: left))
            let zone = zones.strip!
            for behaviour in [PetBehaviour.celebrate(.streak(days: 7)), .celebrate(.goodWeek), .satisfied(.meal)] {
                let script = PetReelScript([(0, .idle(.content)), (5, behaviour)])
                let rig = PetRig()
                for n in 0..<(3 * 60) {
                    for p in script.pose(rig, at: 5 + Double(n) / 60, zones: zones).particles where p.kind == .sparkle {
                        XCTAssertGreaterThanOrEqual(Double(p.position.y) - p.size, Double(zone.bounds.minY) + 1 - 1e-9,
                                                    "\(zone.kind) \(behaviour) at \(Double(n) / 60)")
                    }
                }
            }
        }
    }

    /// Below, the dot comes before the digits: the bead pops out of the gap left of the dot and never
    /// flies back through it.
    func testBelowTheBeadNeverCrossesTheDot() {
        let zones = PetStage.zones(PetStage.frames(.below), PetStage.aggregate(left: 44))
        let zone = zones.strip!
        let dot = Double(zone.bounds.maxX) + PetTuning.Readout.gap
        let full = PetReelScript.meal(.full, chews: 3)
        let script = PetReelScript([(0, .idle(.content)), (5, .eat(full))])
        let rig = PetRig()
        var seen = 0
        for n in 0..<Int(full.duration * 240) {
            guard let bead = script.pose(rig, at: 5 + Double(n) / 240, zones: zones).bead else { continue }
            seen += 1
            XCTAssertLessThan(Double(bead.position.x) + bead.radius, dot, "at \(Double(n) / 240)")
        }
        XCTAssertGreaterThan(seen, 0)
    }

    // MARK: - Motion quality

    /// Points the eye follows: the crown, the eyes, both arm tips, both brows' inner ends.
    static func keyPoints(_ p: PetBody) -> [CGPoint] {
        let g = PetBodyGeometry(p)
        var out = [g.point(u: 0, v: 1)]
        for side in [-1.0, 1.0] {
            out.append(g.facePoint(dTheta: side * 0.37, dv: 0).p)
            let a = g.arm(side)
            out.append(CGPoint(x: a.centre.x + cos(a.angle) * a.length / 2, y: a.centre.y + sin(a.angle) * a.length / 2))
            out.append(CGPoint(x: g.facePoint(dTheta: side * 0.4, dv: 0.4).p.x, y: g.facePoint(dTheta: side * 0.4, dv: 0.4).p.y - (side < 0 ? p.browLiftL : p.browLiftR) * p.size))
        }
        return out
    }

    /// The per-frame speed of the head, the eyes, the arm tips and the brows at 60 fps, with single-frame
    /// jumps flagged: a frame that leaps away from both its neighbours while they agree.
    func testMotionDiagnosticFindsNoSingleFrameJumps() {
        let rig = PetRig()
        let frames = (0..<960).map { reel.pet(rig, at: Double($0) / 60).pet }
        let points = frames.map(Self.keyPoints)
        var jumps: [String] = []
        for n in 1..<(frames.count - 1) where frames[n].opacity > 0.5 {
            for k in points[n].indices {
                let a = points[n - 1][k], b = points[n][k], c = points[n + 1][k]
                let out = hypot(b.x - a.x, b.y - a.y), back = hypot(c.x - b.x, c.y - b.y), across = hypot(c.x - a.x, c.y - a.y)
                if out > 1.5 && back > 1.5 && across < 0.35 * min(out, back) {
                    jumps.append(String(format: "f%d point %d: %.2f out, %.2f back", n, k, out, back))
                }
            }
        }
        XCTAssertTrue(jumps.isEmpty, jumps.joined(separator: "\n"))
    }

    /// A jitter scan over every channel in idle at 30 fps. Jitter is motion that keeps reversing: a channel
    /// may turn back once or twice a second as its drift wanders, and an eye dart may overshoot once, but a
    /// channel that reverses frame after frame shivers. Blinks are exempt: a blink is meant to be quick.
    func testJitterScanOverEveryChannelInIdle() {
        let rig = PetRig()
        let script = PetReelScript([(0, .idle(.content))])
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let frames = (0..<(40 * 30)).map { script.pose(rig, at: 20 + Double($0) / 30, zones: zones).pet }
        let channels: [(String, KeyPath<PetBody, Double>)] = [
            ("x", \.x), ("squash", \.squash), ("girth", \.girth), ("lean", \.lean), ("tilt", \.tilt), ("turn", \.turn),
            ("nod", \.nod), ("lookX", \.lookX), ("lookY", \.lookY), ("browLiftL", \.browLiftL), ("browLiftR", \.browLiftR),
            ("armL", \.armL), ("armR", \.armR), ("fullness", \.fullness), ("glow", \.glow), ("slosh", \.slosh),
        ]
        for (name, key) in channels {
            let v = frames.map { $0[keyPath: key] }
            let steps = zip(v.dropFirst(), v).map { $0 - $1 }
            let floor = (steps.map { abs($0) }.max() ?? 0) * 0.02
            var reversals = 0, run = 0, longest = 0
            for (a, b) in zip(steps, steps.dropFirst()) {
                if abs(a) > floor, abs(b) > floor, (a > 0) != (b > 0) {
                    reversals += 1
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
            let perSecond = Double(reversals) / 40
            XCTAssertLessThan(perSecond, 2.5, "\(name) reverses \(perSecond) times a second")
            XCTAssertLessThan(longest, 3, "\(name) shivers: \(longest) reversals in a row")
        }
    }

    /// The reel neither starts nor ends mid-blink: a film cut there opens or closes on a half-shut eye.
    func testTheReelNeverEndsMidBlink() {
        let rig = PetRig()
        for t in [0.0, 15.0 + 59.0 / 60] {
            let p = reel.pet(rig, at: t).pet
            XCTAssertFalse(PetRigIdle.blinkOpen(at: t, seed: reel.seed) < 0.999 && p.lidL < 0.9, "mid-blink at \(t)")
        }
    }

    /// The weekly reset in the den: `stirring` stays where the pet hibernated, its light comes up and,
    /// beside, one eye clears the notch's edge; and in every layout neither its start nor `leaveDen` cutting
    /// it moves anything by more than a frame's worth.
    func testTheDensStirringStaysInTheDenAndHandsOverWithoutAJump() throws {
        let script = PetReelScript([(0, .idle(.content)), (1, .enterDen(retreat: false)),
                                    (1 + PetTuning.Behaviour.enterDen, .hibernating), (20, .stirring),
                                    (40, .leaveDen(stretch: true)), (40 + PetTuning.Behaviour.leaveDen, .idle(.content))])
        for (placement, notch) in [(EarsPlacement.beside, true), (.below, true), (.beside, false)] {
            let frames = PetStage.frames(placement, notch: notch)
            let zones = PetStage.zones(frames, PetStage.aggregate(left: 23, right: 100))
            let name = notch ? "\(placement)" : "pill"
            let rig = PetRig()
            // A 60 fps frame on each side of each boundary: no more than an action's 1 pt a frame, and the
            // light, the face and the eye no more than they move in any one frame of the blend.
            for boundary in [20.0, 40.0] {
                var previous = script.pose(rig, at: boundary - 2.0 / 60, zones: zones).pet
                for n in -1...2 {
                    let t = boundary + Double(n) / 60
                    let p = script.pose(rig, at: t, zones: zones).pet
                    XCTAssertLessThan(abs(p.x - previous.x), 1, "\(name): x at \(t)")
                    XCTAssertLessThan(abs(p.lift - previous.lift), 1, "\(name): lift at \(t)")
                    XCTAssertLessThan(abs(p.glow - previous.glow), 0.03, "\(name): glow at \(t)")
                    XCTAssertLessThan(abs(p.turn - previous.turn), 0.05, "\(name): turn at \(t)")
                    XCTAssertLessThan(abs(p.lidL - previous.lidL), 0.12, "\(name): the eye at \(t)")
                    previous = p
                }
            }
            let hibernating = script.pose(rig, at: 19, zones: zones).pet
            let stirring = script.pose(rig, at: 30, zones: zones).pet
            XCTAssertEqual(stirring.x, hibernating.x, accuracy: 0.6, "\(name): it stirs where it lies")
            XCTAssertGreaterThan(stirring.glow, hibernating.glow + 0.15, "\(name): the light comes up")
            if placement == .beside, notch {
                let edge: Double = Double(try XCTUnwrap(zones.strip?.den.sideEdge))
                let g = PetBodyGeometry(stirring)
                let dTheta: Double = -0.37 + stirring.lookX * 0.05
                let eye = g.facePoint(dTheta: dTheta, dv: stirring.lookY * 0.04)
                let eyeX: Double = Double(eye.p.x) + stirring.lookX * 0.5 * g.s
                XCTAssertLessThan(eyeX, edge - 0.5, "beside: one eye at the edge")
                XCTAssertGreaterThan(stirring.lidL, 0.15, "beside: the eye is open a little")
            }
        }
    }
}

private extension PetDen {
    var sideEdge: CGFloat? {
        if case .side(let edge) = self { return edge }
        return nil
    }
}

/// The speed rules the frame classes rest on: at its class's rate, ambient motion moves at most 0.5 pt a
/// frame and an action at most 1 pt, so motion looks smooth at the rate it is drawn at; the fast class is
/// free. Measured on the crown, the eyes, the arm tips and the brows, beside at scale 1. Blinks are
/// exempt (a lid moves no point here).
final class PetSpeedTests: XCTestCase {
    func testPeakSpeedsKeepToTheirFrameClass() {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        var failures: [String] = []
        for behaviour in PetZoneSweepTests.behaviours {
            let script = PetZoneSweepTests.script(for: behaviour)
            let rig = PetRig()
            let length = behaviour.duration ?? 12
            var worst: [PetFrameClass: (Double, Double)] = [:]
            var t = 5.0
            while t < 5 + length {
                let frameClass = behaviour.frameClass(elapsed: t - 5)
                let rate: Double
                switch frameClass {
                case .off, .fast: rate = 0
                case .still: rate = PetTuning.Frames.still
                case .sleep: rate = PetTuning.Frames.sleep
                case .idle: rate = PetTuning.Frames.idle
                case .action: rate = PetTuning.Frames.action
                }
                // An open behaviour's first half second is still its blend in from the one before; a pair of
                // frames that crosses into another class runs at the faster of the two.
                guard rate > 0, t - 5 > 0.5 || behaviour.duration != nil,
                      behaviour.frameClass(elapsed: t - 5 + 1 / rate) == frameClass else { t += 1.0 / 240; continue }
                let a = PetRigTests.keyPoints(script.pose(rig, at: t, zones: zones).pet)
                let b = PetRigTests.keyPoints(script.pose(rig, at: t + 1 / rate, zones: zones).pet)
                let step = zip(a, b).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }.max() ?? 0
                if step > (worst[frameClass]?.0 ?? 0) { worst[frameClass] = (step, t - 5) }
                t += 1.0 / 240
            }
            for (frameClass, (step, at)) in worst {
                let limit = frameClass == .action ? PetTuning.Speed.actionPerFrame : PetTuning.Speed.ambientPerFrame
                if step > limit {
                    failures.append(String(format: "%@ (%@): %.2f pt a frame at %.3f s", "\(behaviour)", "\(frameClass)", step, at))
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The all-day behaviours frame by frame at the 30 fps the layer draws them at: half a point a frame at
    /// most, everywhere but in the pounce's leap, which the layer draws in the fast class
    /// (`PetRigIdle.fastWindow`). Rare idles come every 45 to 120 s and the small habits every 20 s, so the
    /// 12 s sample above never sees them. For the reels' pet (seed 7) and one seeded `0x1234567890ABCDEF`,
    /// every kind of both comes within the first ten minutes, which is what the suite scans; `PET_SWEEP=1`
    /// scans half an hour of every mood and of eager for both.
    func testTheAllDayIdleKeepsToHalfAPointAFrame() {
        let full = PetZoneSweepTests.full
        let length: Double = full ? 1800 : 600
        let seeds: [UInt64] = [7, 1_311_768_467_294_899_695]
        let moods: [(PetBehaviour, Double)] = [(.idle(.full), -20), (.idle(.content), 22), (.idle(.peckish), 50),
                                               (.idle(.hungry), 85), (.eager, 30)]
        // Full, content and peckish keep the same schedule of habits; hungry and eager have their own.
        let distinct: [PetBehaviour] = [.idle(.content), .idle(.hungry), .eager]
        var cases: [(UInt64, PetBehaviour, Double)] = []
        for seed in seeds {
            for (behaviour, hunger) in moods where full || behaviour == .idle(.content) || seed == 7 && distinct.contains(behaviour) {
                cases.append((seed, behaviour, hunger))
            }
        }
        for seed in seeds {
            let rares = (0...Int(length / PetRigIdle.rares.period) + 1).filter {
                let at = PetRigIdle.rares.time($0, seed: seed)
                return at > 12 && at + 3 < 10 + length
            }
            let kinds = Set(rares.map { PetRigIdle.rareKind($0, seed: seed) })
            XCTAssertEqual(kinds.count, PetRigIdle.Rare.allCases.count, "seed \(seed): every rare idle within the scan")
        }
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let step = 1 / PetTuning.Frames.idle
        var failures: [String] = []
        for (seed, behaviour, hunger) in cases {
            let script = behaviour == .eager
                ? PetReelScript([(0, .idle(.content)), (4.5, .perk(.prompt)), (5, .eager)], hunger: hunger)
                : PetReelScript([(0, behaviour)], hunger: hunger)
            let segment = script.timeline.segments[script.timeline.segments.count - 1]
            var leaps: [Range<Double>] = []
            var from = 10.0
            while let leap = PetRigIdle.fastWindow(after: from, segment: segment, seed: seed, reduceMotion: false),
                  leap.lowerBound < 10 + length {
                leaps.append(leap)
                from = leap.upperBound
            }
            let rig = PetRig()
            func points(_ t: Double) -> [CGPoint] {
                PetRigTests.keyPoints(script.pose(rig, at: t, zones: zones, seed: seed).pet)
            }
            var previous = points(10)
            var worst = (step: 0.0, at: 0.0)
            for n in 1...Int(length / step) {
                let t = 10 + Double(n) * step
                let now = points(t)
                defer { previous = now }
                if leaps.contains(where: { $0.contains(t) || $0.contains(t - step) }) { continue }
                let moved = zip(previous, now).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }.max() ?? 0
                if moved > worst.step { worst = (moved, t) }
            }
            let line = String(format: "seed %llu, %@, %.0f s: at most %.2f pt a frame, at %.3f s", seed, "\(behaviour)",
                              length, worst.step, worst.at)
            print("all-day speed: \(line)")
            if worst.step > PetTuning.Speed.ambientPerFrame { failures.append(line) }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
