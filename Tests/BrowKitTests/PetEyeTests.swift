// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import XCTest
@testable import BrowKit

/// The eyes frame by frame at the idle's 30 fps. Between the bean eye and the closed happy arc the drawing
/// cross-fades (`PetCanvas.happyBand`), and so does the lid between open and shut: held there for more than
/// two frames, an eye shows two drawings at once, a ghost. And a blink must not side-eye: in its middle frames
/// a slanted lid half shut reads as a smirk.
///
/// The suite scans five minutes of every idle mood, settled, eager and the ten-minute script for the reels'
/// pet; `PET_SWEEP=1` scans half an hour of each for both pets.
final class PetEyeTests: XCTestCase {
    struct Scan {
        var name: String
        var script: PetReelScript
        var length: Double
    }

    static var scans: [Scan] {
        let length: Double = PetZoneSweepTests.full ? 1800 : 300
        var out: [Scan] = []
        let hungers: [PetMood: Double] = [.stuffed: -46, .full: -20, .content: 22, .peckish: 50, .hungry: 80, .famished: 96]
        for mood in PetMood.allCases {
            let h = hungers[mood] ?? 30
            out.append(Scan(name: "idle(\(mood))", script: PetReelScript([(0, .idle(mood))], hunger: h), length: length))
            out.append(Scan(name: "settled(\(mood))", script: PetReelScript([(0, .settled(mood))], hunger: h), length: length))
        }
        out.append(Scan(name: "eager", script: PetReelScript([(0, .idle(.content)), (4.5, .perk(.prompt)), (5, .eager)]),
                        length: length))
        out.append(Scan(name: "ten minutes", script: PetPerformanceTests.tenMinutes, length: 600))
        return out
    }

    static var seeds: [UInt64] { PetZoneSweepTests.full ? [7, 1_311_768_467_294_899_695] : [7] }

    /// No run of three frames or more with an eye in the happy arc's cross-fade, or, in the open behaviours,
    /// a lid in the shut line's cross-fade outside a blink; and the middle of every blink level.
    func testTheEyesNeverShowTwoDrawingsAndABlinkNeverSideEyes() {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let band = PetCanvas.happyBand
        var failures: [String] = []
        for seed in Self.seeds {
            for scan in Self.scans {
                let rig = PetRig()
                var happyRun = 0, lidRun = 0
                var worst = (happy: (0, 0.0), lid: (0, 0.0), slant: (0.0, 0.0))
                for n in 0..<Int(scan.length * 30) {
                    let t = 5 + Double(n) / 30
                    let p = scan.script.pose(rig, at: t, zones: zones, seed: seed).pet
                    // Each eye as drawn: a wink takes one eye to the arc alone.
                    let eyes = [max(p.happy, p.winkL), max(p.happy, p.winkR)]
                    let ghost = eyes.contains { $0 > band.lowerBound + 1e-6 && $0 < band.upperBound - 1e-6 }
                    happyRun = ghost ? happyRun + 1 : 0
                    if happyRun > worst.happy.0 { worst.happy = (happyRun, t) }
                    let behaviour = scan.script.timeline.segments.last { $0.start <= t }?.behaviour
                    let blink = PetRigIdle.blinkOpen(at: t, seed: seed)
                    if Self.isOpenAndAwake(behaviour) {
                        let lid = min(p.lidL, p.lidR)
                        lidRun = lid > 0.1 && lid < 0.24 && blink > 0.999 ? lidRun + 1 : 0
                        if lidRun > worst.lid.0 { worst.lid = (lidRun, t) }
                        if blink < 0.5, min(p.lidL, p.lidR) < 0.5, abs(p.lidSlant) > worst.slant.0 {
                            worst.slant = (abs(p.lidSlant), t)
                        }
                    } else {
                        lidRun = 0
                    }
                }
                let line = String(format: "seed %llu, %@: happy run %d (at %.2f s), lid run %d (at %.2f s), mid-blink slant %.3f (at %.2f s)",
                                  seed, scan.name, worst.happy.0, worst.happy.1, worst.lid.0, worst.lid.1, worst.slant.0,
                                  worst.slant.1)
                print("eye scan: \(line)")
                if worst.happy.0 > 2 || worst.lid.0 > 2 || worst.slant.0 > 0.05 { failures.append(line) }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Stuffed, eyes that open out of their bliss just as a gesture opens them on its own (the thumbs-up,
    /// room for more, the hiccup, a mote) stay open for it: shutting and opening again at once, they would
    /// stop half way, in two drawings at once. Every such meeting in an hour of either pet, frame by frame.
    func testBlissEyesStayOpenForAGestureThatOpensThem() {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let band = PetCanvas.happyBand
        let k = PetPosture.eyeClock
        let segment = PetSegment(start: 0, behaviour: .idle(.stuffed))
        let script = PetReelScript([(0, .idle(.stuffed))], hunger: -46)
        var meetings = 0
        for seed in [7, 1_311_768_467_294_899_695] as [UInt64] {
            let gestures = PetRigMoodBeats.gestures(in: segment, previous: nil, at: 3600, lookBack: 3600, seed: seed,
                                                    reduceMotion: false)
            let opens = gestures.compactMap { g in PetRigMoodBeats.opensTheEyes(g.item, seed: seed).map { g.at + $0 } }
            let rig = PetRig()
            for (n, at) in PetRigMoodBeats.blissOpens.recent(at: 3590, lookBack: 3580, seed: seed) {
                let shut = at + PetRigMoodBeats.blissHold(n, seed: seed)
                guard opens.contains(where: { $0 > shut - 1e-9 && $0 <= shut + k }) else { continue }
                meetings += 1
                var run = 0
                for f in 0..<36 {
                    let t = 5 + (floor((shut - 5) * 30) - 9 + Double(f)) / 30
                    let happy = script.pose(rig, at: t, zones: zones, seed: seed).pet.happy
                    run = happy > band.lowerBound + 1e-6 && happy < band.upperBound - 1e-6 ? run + 1 : 0
                    XCTAssertLessThanOrEqual(run, 2, "seed \(seed), the eyes shutting at \(shut): held half way at \(t)")
                }
            }
        }
        XCTAssertGreaterThan(meetings, 0, "an opening runs into a gesture within the hour")
    }

    /// The open behaviours, where nothing but a blink moves the lids.
    static func isOpenAndAwake(_ b: PetBehaviour?) -> Bool {
        switch b {
        case .idle?, .settled?, .eager?, .unsureIdle?: return true
        default: return false
        }
    }

    /// Hungry and famished lift the outer corners of their lids; a blink takes the slant down with the lid,
    /// so the frame in the middle of it is level and never a side-eye.
    func testABlinkTakesTheSlantDownWithTheLid() throws {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let rig = PetRig()
        for (mood, hunger) in [(PetMood.hungry, 80.0), (.famished, 96)] {
            let script = PetReelScript([(0, .idle(mood))], hunger: hunger)
            let starts = PetRigIdle.blinkStarts(from: 20, to: 200, seed: 7)
            var checked = 0
            for start in starts {
                let mid = start + PetTuning.Idle.blinkClose + PetTuning.Idle.blinkHold / 2
                let p = script.pose(rig, at: mid, zones: zones).pet
                guard max(p.lidL, p.lidR) < 0.2 else { continue }        // a blink a beat held off
                XCTAssertLessThanOrEqual(abs(p.lidSlant), 0.05, "\(mood) at \(mid)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 10, "\(mood)")
        }
    }
}
