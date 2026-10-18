// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// A resting expression and a way of moving: the stiffness and damping of the body's jelly, the breath,
/// how much the idle drifts. Glim's personality lives in these numbers: the same landing reads springy
/// when eager and heavy when stuffed.
struct PetPosture: Sendable {
    /// The posture's channels; everything else in it is ignored.
    var body = PetBody()
    var jellyHz: Double = 3.4
    var jellyZeta: Double = 0.30
    /// The breath: weights over `PetRigIdle.breathBank`, oscillators of fixed periods. A posture breathes
    /// on one of them; a blend between two postures cross-fades their oscillators instead of bending one
    /// period into another, which would wrap the phase at a large uptime.
    var breath: [Double] = PetRigIdle.bankWeights(PetTuning.Idle.breathPeriod)
    var breathAmp: Double = PetTuning.Idle.breathAmplitude
    /// How far the idle layers wander: 1 at rest, 0 asleep.
    var drift: Double = 1
    /// How much the eyes rest on the food source (eager, hungry, unsure).
    var lookAtFood: Double = 0
    /// How bright the whole pet is drawn, 1 as its light has it: hibernating on the pill, where there is
    /// no den, it turns itself down. A posture's, so it cross-fades with the rest of it.
    var light: Double = 1

    /// The channels a posture sets. `turn` and `lookX` are 0 in every posture but the den's stirring,
    /// whose face turns toward the notch's edge.
    static let channels: [WritableKeyPath<PetBody, Double>] = [
        \.squash, \.girth, \.curl, \.lean, \.tilt, \.nod, \.turn, \.lookX, \.lidL, \.lidR, \.lidSlant, \.happy,
        \.eyeSize, \.browLiftL, \.browLiftR, \.browTiltL, \.browTiltR, \.smile, \.mouthOpen, \.mouthWide, \.blush,
        \.armL, \.armR, \.glow,
    ]

    static func mixed(_ a: PetPosture, _ b: PetPosture, _ t: Double) -> PetPosture {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var m = a
        for k in channels { m.body[keyPath: k] = PetCurve.mix(a.body[keyPath: k], b.body[keyPath: k], t) }
        m.jellyHz = PetCurve.mix(a.jellyHz, b.jellyHz, t)
        m.jellyZeta = PetCurve.mix(a.jellyZeta, b.jellyZeta, t)
        m.breathAmp = PetCurve.mix(a.breathAmp, b.breathAmp, t)
        m.drift = PetCurve.mix(a.drift, b.drift, t)
        m.lookAtFood = PetCurve.mix(a.lookAtFood, b.lookAtFood, t)
        m.light = PetCurve.mix(a.light, b.light, t)
        for i in m.breath.indices { m.breath[i] = PetCurve.mix(a.breath[i], b.breath[i], t) }
        return m
    }

    static func make(hz: Double, zeta: Double, breath: Double, amp: Double, drift: Double, food: Double = 0,
                     _ f: (inout PetBody) -> Void) -> PetPosture {
        var p = PetBody()
        p.smile = 0.42
        p.blush = 0.45
        p.lidL = 0.94
        p.lidR = 0.94
        f(&p)
        return PetPosture(body: p, jellyHz: hz, jellyZeta: zeta, breath: PetRigIdle.bankWeights(breath), breathAmp: amp,
                          drift: drift, lookAtFood: food)
    }
}

extension PetPosture {
    /// At home, nothing needed: a soft smile, relaxed lids, a medium jelly.
    static let content = make(hz: 3.4, zeta: 0.30, breath: PetTuning.Idle.breathPeriod,
                              amp: PetTuning.Idle.breathAmplitude, drift: 1) { _ in }

    /// Fed past the brim: rounder, breathing slower, pleased. The lower lids smile up under open eyes
    /// (happy stays below the cross-fade to closed arcs), and the brows sit easy and level: a mood people
    /// live with for hours, so never the heavy upper lids and lowered brows that read smug at real size.
    /// Heavy lids are for stuffed only.
    static let full = make(hz: 3.0, zeta: 0.32, breath: PetTuning.Idle.fullBreathPeriod, amp: 0.018, drift: 0.8) { p in
        p.girth = 1.04; p.lidL = 1; p.lidR = 1; p.happy = 0.4; p.smile = 0.62; p.blush = 0.62
        p.browLiftL = 0.15; p.browLiftR = 0.2; p.browTiltL = 0; p.browTiltR = 0; p.glow = 1.08
    }

    /// Thinking of food: eyes a little wider and more often on the number.
    static let peckish = make(hz: 3.2, zeta: 0.32, breath: 3.9, amp: 0.016, drift: 0.9, food: 0.35) { p in
        p.eyeSize = 1.06; p.lidL = 1; p.lidR = 1; p.browLiftL = 0.35; p.browLiftR = 0.45; p.browTiltL = 0.06
        p.browTiltR = 0.06; p.smile = 0.28; p.blush = 0.4
    }

    /// Hungry, and hopeful, never sad: a nudge, not a reproach. Big round eyes fixed on the number, brows
    /// up with the inner ends lifted just enough to plead, the outer lids lifted rather than drooping, a
    /// small open mouth, leaning 3° toward the food, a little lower. The dimming light is the meter.
    static let hungry = make(hz: 2.6, zeta: 0.42, breath: 4.4, amp: 0.02, drift: 0.55, food: 0.9) { p in
        p.squash = 0.96; p.eyeSize = 1.2; p.lidL = 1; p.lidR = 1; p.lidSlant = -0.12
        p.browLiftL = 0.6; p.browLiftR = 0.75; p.browTiltL = 0.04; p.browTiltR = 0.07
        p.smile = 0.42; p.mouthOpen = 0.1; p.mouthWide = 0.62; p.blush = 0.45; p.armL = 0.12; p.armR = 0.12
        p.glow = 0.95
    }

    /// Claude Code is working: food is coming. Taller (1.04), stiff and springy, everything up.
    static let eager = make(hz: 4.6, zeta: 0.24, breath: 2.1, amp: 0.018, drift: 0.5, food: 0.85) { p in
        p.squash = PetTuning.Idle.eagerHeight; p.eyeSize = 1.14; p.lidL = 1; p.lidR = 1; p.browLiftL = 1.0
        p.browLiftR = 1.1; p.smile = 0.75; p.mouthOpen = 0.1; p.mouthWide = 0.8; p.blush = 0.7; p.armL = 0.5; p.armR = 0.55
        p.glow = PetTuning.Light.glowEager
    }

    /// The pointer came close: wide eyes, one brow up, a little "o".
    static let curious = make(hz: 4.0, zeta: 0.34, breath: 2.6, amp: 0.012, drift: 0.4) { p in
        p.squash = 1.03; p.eyeSize = 1.1; p.lidL = 1; p.lidR = 1; p.browLiftL = 1.2; p.browLiftR = 0.5
        p.browTiltL = -0.05; p.browTiltR = 0.12; p.smile = -0.05; p.mouthOpen = 0.18; p.mouthWide = 0.42
        p.armL = 0.2; p.armR = 0.3; p.blush = 0.55
    }

    /// Mid-meal: eyes shut in delight, cheeks full.
    static let munch = make(hz: 3.8, zeta: 0.30, breath: 2.0, amp: 0.01, drift: 0.2) { p in
        p.happy = 1; p.browLiftL = 0.5; p.browLiftR = 0.4; p.browTiltL = 0.08; p.browTiltR = 0.08
        p.smile = 0.5; p.blush = 0.9; p.armL = 0.2; p.armR = 0.15; p.glow = 1.1
    }

    /// Fed and pleased: slow deep breaths, eyes closed in bliss.
    static let satisfied = make(hz: 3.0, zeta: 0.34, breath: 2.8, amp: 0.022, drift: 0.6) { p in
        p.girth = 1.03; p.happy = 0.85; p.browLiftL = 0.35; p.browLiftR = 0.35; p.browTiltL = 0.12; p.browTiltR = 0.12
        p.smile = 0.85; p.blush = 0.9; p.armL = 0.05; p.armR = 0.05; p.glow = 1.15
    }

    /// Too full: round, heavy, a slow low wobble, heavy-lidded bliss.
    static let stuffed = make(hz: 1.9, zeta: 0.26, breath: 1.6, amp: 0.02, drift: 0.2) { p in
        p.squash = 0.96; p.girth = 1.1; p.lidL = 0.52; p.lidR = 0.52; p.lidSlant = 0.2; p.happy = 0.3
        p.browLiftL = 0.1; p.browLiftR = 0.1; p.browTiltL = 0.14; p.browTiltR = 0.14; p.smile = 0.55
        p.blush = 0.85; p.armL = 0.3; p.armR = 0.3; p.glow = 1.2
    }

    /// Up, not awake: sitting up out of the loaf, but only half way, heavy, eyes at 0.35. Half way, so
    /// rolling back over into the loaf fits its one second at 15 fps.
    static let drowsy = make(hz: 1.8, zeta: 0.55, breath: 3.0, amp: 0.02, drift: 0.15) { p in
        p.curl = 0.45; p.squash = 0.97; p.girth = 1.03; p.lidL = PetTuning.Limits.drowsyEyes; p.lidR = PetTuning.Limits.drowsyEyes
        p.lidSlant = 0.15; p.browLiftL = -0.25; p.browLiftR = -0.15; p.browTiltL = 0.08; p.browTiltR = 0.08
        p.smile = 0.3; p.blush = 0.65; p.armL = -0.15; p.armR = -0.15; p.glow = 0.9
    }

    /// Asleep at the 5-hour limit: curled into a low loaf at the anchor, eyes shut, the light breathing
    /// slowly like a sleeping Mac's, the glow at 0.6.
    static let asleep = make(hz: 1.5, zeta: 0.8, breath: 4.6, amp: 0.03, drift: 0) { p in
        p.curl = 1; p.girth = 1.0; p.tilt = 0.04; p.nod = -0.2; p.lidL = 0; p.lidR = 0; p.browLiftL = -0.45
        p.browLiftR = -0.45; p.browTiltL = 0.05; p.browTiltR = 0.05; p.smile = 0.25; p.mouthOpen = 0.07
        p.mouthWide = 0.45; p.blush = 0.55; p.armL = -0.3; p.armR = -0.3; p.glow = PetTuning.Light.glowAsleep
    }

    /// In the den at the weekly limit: curled, the glow down to 0.3, a slower breath still.
    static let hibernating = make(hz: 1.4, zeta: 0.85, breath: PetTuning.Den.glowCycle, amp: 0.025, drift: 0) { p in
        p.curl = 1; p.tilt = 0.03; p.nod = -0.25; p.lidL = 0; p.lidR = 0; p.browLiftL = -0.5; p.browLiftR = -0.5
        p.smile = 0.2; p.mouthOpen = 0.05; p.mouthWide = 0.4; p.blush = 0.4; p.armL = -0.3; p.armR = -0.3
        p.glow = PetTuning.Light.glowHibernating
    }

    /// After the reset, or a celebration: bright and bouncy.
    static let happy = make(hz: 4.2, zeta: 0.28, breath: 2.0, amp: 0.018, drift: 0.7) { p in
        p.squash = 1.03; p.lidL = 1; p.lidR = 1; p.happy = 0.35; p.eyeSize = 1.05; p.browLiftL = 0.7
        p.browLiftR = 0.7; p.smile = 0.95; p.mouthOpen = 0.16; p.blush = 0.75; p.armL = 0.35; p.armR = 0.35; p.glow = 1.15
    }

    /// Dozing while you are away: eyes shut, head down, settled into itself, still.
    static let dozing = make(hz: 1.6, zeta: 0.7, breath: 4.4, amp: 0.012, drift: 0) { p in
        p.squash = 0.94; p.girth = 1.04; p.nod = -0.3; p.lidL = 0; p.lidR = 0; p.browLiftL = -0.35; p.browLiftR = -0.35
        p.smile = 0.3; p.blush = 0.5; p.armL = -0.2; p.armR = -0.2; p.glow = 0.85
    }

    /// The posture of a mood, the open behaviours' base. The two ends of the meter look like their
    /// neighbours for now: stuffed like full, famished like hungry.
    static func mood(_ m: PetMood) -> PetPosture {
        switch m {
        case .stuffed, .full: return .full
        case .content: return .content
        case .peckish: return .peckish
        case .hungry, .famished: return .hungry
        }
    }
}
