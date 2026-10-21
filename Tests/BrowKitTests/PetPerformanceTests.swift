// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import BrowKit

/// What the pet costs. Skipped unless `PET_PERF` is set; run in release:
///
///     PET_PERF=1 swift test -c release --filter PetPerformanceTests
///
/// `testPoseEvaluationCost` poses 100 000 instants of a scripted 10-minute timeline that visits every
/// behaviour, and reports the mean and the 99th percentile; `PET_PERF_STRICT=1` asserts the budget
/// (0.05 ms mean, 0.15 ms p99). `testCanvasCost` renders 600 of the pet's own canvases at scale 2 under
/// `XCTCPUMetric` and `XCTClockMetric`; reported, not asserted, since it includes rasterising.
final class PetPerformanceTests: XCTestCase {
    static let enabled = ProcessInfo.processInfo.environment["PET_PERF"] != nil
    static let strict = ProcessInfo.processInfo.environment["PET_PERF_STRICT"] != nil

    /// Ten minutes in which every behaviour plays at least once, with the pointer passing, the panel
    /// opening and closing, meals, sleep, hibernation and the den.
    static var tenMinutes: PetReelScript {
        let full = PetReelScript.meal(.full, chews: 3)
        let nibble = PetReelScript.meal(.nibble, chews: 2)
        let feast = PetReelScript.meal(.full, chews: 3, feast: true, points: 9)
        let last = PetReelScript.meal(.nibble, chews: 1)
        typealias B = PetTuning.Behaviour
        var plan: [(Double, PetBehaviour)] = []
        var t = 0.0
        func play(_ b: PetBehaviour, _ length: Double? = nil) {
            plan.append((t, b))
            t += length ?? b.duration ?? 10
        }
        play(.intro(noAccounts: false))
        play(.idle(.content), 25)
        play(.perk(.prompt)); play(.eager, 20)
        play(.eat(full)); play(.satisfied(.meal)); play(.idle(.content), 20)
        play(.eat(nibble)); play(.satisfied(.lick)); play(.idle(.peckish), 25); play(.idle(.hungry), 30)
        play(.eat(feast)); play(.satisfied(.feast)); play(.idle(.full), 20)
        play(.boop(giggle: false)); play(.idle(.full), 5); play(.boop(giggle: true)); play(.idle(.full), 10)
        // The two ends of the meter, with their beats, at the meter they live at (keyed below).
        let ends = t
        play(.idle(.stuffed), 30); play(.idle(.famished), 30)
        play(.celebrate(.streak(days: 7))); play(.idle(.content), 10); play(.celebrate(.goodWeek)); play(.idle(.content), 10)
        play(.freshWindow); play(.settled(.content), 30); play(.dozeIn); play(.doze, 20); play(.welcomeBack)
        play(.idle(.content), 10); play(.unsureIdle(.content), 30); play(.perk(.freshData)); play(.idle(.content), 10)
        play(.eat(last)); play(.fallAsleep); play(.asleep, 60); play(.drowsy, 20); play(.rollOver); play(.asleep, 20)
        play(.drowsy, 10); play(.wake); play(.idle(.content), 10)
        play(.enterDen(retreat: false)); play(.hibernating, 60); play(.leaveDen(stretch: true)); play(.idle(.content), 10)
        play(.enterDen(retreat: true)); play(.denWait, 30); play(.peek); play(.denWait, 30); play(.leaveDen(stretch: false))
        play(.idle(.content), 20); play(.off); play(.idle(.content), 600 - t)
        var script = PetReelScript(plan, hunger: 30)
        for (start, b) in plan { if case .eat(let meal) = b { script.meter(start + meal.swallowStart, 10) } }
        script.meter(80, 10, rate: 0.6)
        script.meter(140, 0, rate: 0.005)
        script.meter(ends, -46)
        script.meter(ends + 30, 96)
        // The panel opened at each end: a thumbs-up, then please.
        script.cue(ends + 4, .greet)
        script.cue(ends + 34, .greet)
        script.meter(ends + 60, 0.5, rate: 0.005)
        // The pointer passes the strip twice, and hovers the panel once.
        script.pointerPath([(9.5, -40, 140), (10.5, 60, 60), (12.5, 110, 50), (14, 300, 160)])
        script.cue(10.4, .notice)
        script.cue(13.9, .release)
        script.pointerPath([(149.5, 300, 160), (150, 200, 20), (160, 120, 120), (170, 250, 200), (171, 300, 300)])
        script.dock = [PetDockChange(t: 150, kind: .expand), PetDockChange(t: 171.5, kind: .collapse)]
        script.cue(320, .twitch)
        script.cue(470, .glowPulse)
        return script
    }

    func testPoseEvaluationCost() throws {
        guard Self.enabled else { throw XCTSkip("set PET_PERF=1 (and run with -c release) to measure the pose") }
        let script = Self.tenMinutes
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let count = PetTuning.Budget.poseSamples
        let length = PetTuning.Budget.scriptLength
        // The tracks the controller would hand in, worked out before the clock starts.
        let times = (0..<count).map { Double($0) * length / Double(count) }
        var pointerTracks: [PetPointerTrack] = []
        var dockTracks: [PetDockTrack] = []
        pointerTracks.reserveCapacity(count)
        dockTracks.reserveCapacity(count)
        for t in times {
            pointerTracks.append(script.pointerTrack(at: t))
            dockTracks.append(script.dockTrack(at: t))
        }
        func run(_ order: [Int]) -> (mean: Double, p99: Double, max: Double) {
            let rig = PetRig()
            var samples = [Double](repeating: 0, count: order.count)
            var sink = 0.0
            for (n, i) in order.enumerated() {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let frame = rig.pose(script.timeline, at: times[i], pointer: pointerTracks[i], dock: dockTracks[i],
                                     zones: zones, seed: 7, motion: PetMotion())
                let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                sink += frame.pet.squash
                samples[n] = Double(end - start) * 1e-9
            }
            XCTAssertTrue(sink.isFinite)
            let sorted = samples.sorted()
            return (samples.reduce(0, +) / Double(samples.count), sorted[Int(Double(sorted.count) * 0.99)], sorted.last!)
        }
        // In order, as the layer plays it (100 000 poses over 10 minutes, about 167 a second) ...
        let played = run(Array(0..<count))
        // ... and in a shuffled order, every pose on its own.
        var order = Array(0..<count)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in order.indices.reversed() {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            order.swapAt(i, Int(state >> 33) % (i + 1))
        }
        let shuffled = run(order)
        print(String(format: "pet pose, in order: mean %.4f ms, p99 %.4f ms, max %.3f ms", played.mean * 1e3, played.p99 * 1e3, played.max * 1e3))
        print(String(format: "pet pose, shuffled: mean %.4f ms, p99 %.4f ms, max %.3f ms", shuffled.mean * 1e3, shuffled.p99 * 1e3, shuffled.max * 1e3))
        if Self.strict {
            XCTAssertLessThanOrEqual(played.mean, PetTuning.Budget.poseMean)
            XCTAssertLessThanOrEqual(played.p99, PetTuning.Budget.poseP99)
            XCTAssertLessThanOrEqual(shuffled.mean, PetTuning.Budget.poseMean)
            XCTAssertLessThanOrEqual(shuffled.p99, PetTuning.Budget.poseP99)
        }
    }

    @MainActor
    func testCanvasCost() throws {
        guard Self.enabled else { throw XCTSkip("set PET_PERF=1 (and run with -c release) to measure the canvas") }
        let reel = PetReels.tour
        let rig = PetRig()
        let frames = (0..<PetTuning.Budget.canvasFrames).map { reel.pet(rig, at: Double($0) / 60 * 1.6) }
        for f in frames.prefix(20) { _ = ImageRenderer(content: PetCanvas(frame: f)).cgImage }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(), XCTClockMetric()], options: options) {
            for f in frames {
                let renderer = ImageRenderer(content: PetCanvas(frame: f))
                renderer.scale = PetTuning.Budget.renderScale
                _ = renderer.cgImage
            }
        }
        var timer = [Double]()
        for f in frames {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let renderer = ImageRenderer(content: PetCanvas(frame: f))
            renderer.scale = PetTuning.Budget.renderScale
            _ = renderer.cgImage
            timer.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) * 1e-9)
        }
        let sorted = timer.sorted()
        print(String(format: "pet canvas through ImageRenderer at 2x: mean %.3f ms, p95 %.3f ms per frame",
                     timer.reduce(0, +) / Double(timer.count) * 1e3, sorted[Int(Double(sorted.count) * 0.95)] * 1e3))
    }
}
