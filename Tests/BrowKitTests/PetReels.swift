// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import BrowKit

/// One showreel: a segment script, the strip it plays in, and what Brow's readouts say meanwhile.
struct PetReel {
    var script: PetReelScript
    var duration: Double
    var frames: NotchFrames
    var seed: UInt64 = 7
    var motion = PetMotion()
    var palette: PetPalette = .standard
    /// What the strip's readouts say at `t`.
    var readouts: (Double) -> LimitsAggregate
    /// The time-lapse's dimming of the desktop, 0 ... 1.
    var dim: (Double) -> Double = { _ in 0 }
    var showEars = true

    func zones(at t: Double) -> PetZones {
        PetStage.zones(frames, readouts(t), showEars: showEars)
    }

    func pet(_ rig: PetRig, at t: Double) -> PetFrame {
        script.pose(rig, at: t, zones: zones(at: t), seed: seed, motion: motion)
    }

    /// The pointer's tip, while it is on the desktop.
    func pointer(at t: Double) -> CGPoint? {
        guard let last = script.pointer.last(where: { $0.t <= t }), t - last.t < 1.0 / 60 + 1e-9 else { return nil }
        return last.location
    }

    @MainActor
    func scene(_ rig: PetRig, at t: Double, crop: CGRect) -> PetStage.StripScene {
        PetStage.StripScene(frames: frames, aggregate: readouts(t), pet: pet(rig, at: t), crop: crop, palette: palette,
                            dim: dim(t), pointer: pointer(at: t))
    }
}

/// The reels.
enum PetReels {
    /// The tour's 600 × 90 pt crop centred on the notch, in window coordinates (the notch's centre is at
    /// x 236 of the 472 pt window).
    static let mainCrop = CGRect(x: 236 - 300, y: 0, width: 600, height: 90)
    /// The pet's wing, for the 4x zoom.
    static let zoomCrop = CGRect(x: 52, y: 0, width: 116, height: 44)

    /// The 16 s tour: content idle; the pointer comes and is watched; Claude Code starts and it perks up;
    /// 41 → 44 %: anticipation, bite, three chews, swallow, satisfied; a time-lapse of quiet hours, hungry;
    /// 97 → 100 %: the meal that fills the window, a yawn, asleep with Zzz; the reset: the wake and its
    /// stretch; idle again. The reel compresses hours into seconds, so it cuts `satisfied` and `fallAsleep`
    /// short where the brain would not; the meal itself keeps its full 1.98 s.
    static var tour: PetReel {
        let full = PetReelScript.meal(.full, chews: 3)
        let last = PetReelScript.meal(.nibble, chews: 1, points: 3)
        var s = PetReelScript([
            (0.00, .idle(.content)),
            (4.00, .perk(.prompt)),
            (4.50, .eager),
            (5.00, .eat(full)),
            (5.00 + full.duration, .satisfied(.meal)),
            (8.10, .idle(.content)),
            (8.55, .idle(.peckish)),
            (9.05, .idle(.hungry)),
            (9.80, .eat(last)),
            (9.80 + last.duration, .fallAsleep),
            (12.30, .asleep),
            (12.80, .wake),
            (12.80 + PetTuning.Behaviour.wake, .idle(.peckish)),
        ], hunger: 30)
        // The meter: the first meal lands at its swallow; quiet hours fill it; the last bite lands too.
        s.meter(5.00 + full.swallowStart, 30 - 6 * 3)
        s.meter(8.10, 12, rate: (72 - 12) / 1.3)
        s.meter(9.40, 72, rate: 0)
        s.meter(9.80 + last.swallowStart, 72 - 6 * 3)
        // The pointer comes up from the desktop, hovers under the strip, and goes.
        s.pointerPath([(2.85, -30, 120), (3.15, 40, 78), (3.45, 92, 52), (3.75, 104, 46), (3.95, 110, 47),
                       (4.15, 160, 70), (4.45, 290, 140)])
        s.cue(3.06, .notice)
        s.cue(4.32, .release)
        return PetReel(script: s, duration: 16, frames: PetStage.frames(.beside), readouts: { t in
            let left: Double
            // The time-lapse's jump to 97 % lands as the last bite starts, so a hungry pet is never seen
            // beside a limit that is all but used up.
            switch t {
            case ..<5.0: left = 41
            case ..<9.78: left = 44
            case ..<9.8: left = 97
            case ..<12.8: left = 100
            default: left = 0
            }
            return PetStage.aggregate(left: left)
        }, dim: { t in PetCurve.envelope(t, 7.95, 8.25, 9.25, 9.6) })
    }

    /// Hibernation: the weekly limit runs out, the pet goes into the den, sleeps there with its light
    /// breathing (booped once: the glow pulses), and comes out at the weekly reset. Beside it squeezes past
    /// the notch's edge; below it goes up into the notch and leaves light under the door.
    static func den(_ placement: EarsPlacement) -> PetReel {
        var s = PetReelScript([
            (0.0, .idle(.content)),
            (1.2, .enterDen(retreat: false)),
            (1.2 + PetTuning.Behaviour.enterDen, .hibernating),
            (10.4, .leaveDen(stretch: true)),
            (10.4 + PetTuning.Behaviour.leaveDen, .idle(.content)),
        ])
        s.cue(7.4, .glowPulse)
        return PetReel(script: s, duration: 16, frames: PetStage.frames(placement), readouts: { t in
            PetStage.aggregate(left: 23, right: t < 1.1 ? 99 : (t < 10.4 ? 100 : 0))
        })
    }

    /// The below layout at scale 0.80: idle, a meal, the 5-hour limit, asleep, the reset and the wake, all
    /// in the 22 pt strip under the notch, the bite going right toward the readout.
    static var below: PetReel {
        let full = PetReelScript.meal(.full, chews: 3)
        var s = PetReelScript([
            (0.0, .idle(.content)),
            (1.2, .perk(.prompt)),
            (1.7, .eager),
            (3.0, .eat(full)),
            (3.0 + full.duration, .satisfied(.meal)),
            (7.98, .idle(.content)),
            (8.4, .fallAsleep),
            (8.4 + PetTuning.Behaviour.fallAsleep, .asleep),
            (12.9, .wake),
            (12.9 + PetTuning.Behaviour.wake, .idle(.content)),
        ])
        s.meter(3.0 + full.swallowStart, 12)
        return PetReel(script: s, duration: 16, frames: PetStage.frames(.below), readouts: { t in
            PetStage.aggregate(left: t < 3 ? 41 : (t < 8.4 ? 44 : (t < 12.9 ? 100 : 0)))
        })
    }

    /// The pill of a display with no notch at scale 0.82: a meal, then the weekly limit with no den to go
    /// into: it curls into a ball with its glow at 30 %, then gets up at the reset.
    static var pill: PetReel {
        let full = PetReelScript.meal(.full, chews: 2)
        var s = PetReelScript([
            (0.0, .idle(.content)),
            (1.5, .eat(full)),
            (1.5 + full.duration, .satisfied(.meal)),
            (6.2, .idle(.content)),
            (6.8, .enterDen(retreat: false)),
            (6.8 + PetTuning.Behaviour.enterDen, .hibernating),
            (11.6, .leaveDen(stretch: true)),
            (11.6 + PetTuning.Behaviour.leaveDen, .idle(.content)),
        ])
        s.meter(1.5 + full.swallowStart, 18)
        return PetReel(script: s, duration: 16, frames: PetStage.frames(.beside, notch: false), readouts: { t in
            PetStage.aggregate(left: t < 1.5 ? 41 : 43, right: t < 6.7 ? 98 : (t < 11.6 ? 100 : 0))
        })
    }

    /// The crop a layout reel is seen through, window coordinates: the pet's part of the strip with its
    /// readout and, beside, the notch's edge.
    static func crop(_ frames: NotchFrames) -> CGRect {
        let strip = PetLayout.window(frames.collapsed, in: frames)
        guard frames.hasNotch else { return CGRect(x: strip.minX - 20, y: 0, width: strip.width + 40, height: 40) }
        let notch = PetLayout.window(frames.notch!, in: frames)
        if frames.placement == .below { return CGRect(x: notch.minX - 14, y: 0, width: 200, height: 64) }
        return CGRect(x: notch.minX - 114, y: 0, width: 150, height: 44)
    }
}
