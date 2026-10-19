// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// A resting expression and a way of moving: the stiffness and damping of the body's jelly, the breath,
/// how much the idle drifts. Glim's personality lives in these numbers: the same landing reads springy
/// when eager and soft when stuffed.
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
    /// A lean toward the food source (a shear, as `PetBody.lean`), whichever side it is on: famished leans
    /// in at the number, stuffed back from it, belly out. Below and in the panel the food is to the right,
    /// so the lean is the posture's and not the body's.
    var foodLean: Double = 0
    /// How far the body stands toward the food source, in points at scale 1.
    var foodStep: Double = 0
    /// How much higher the arm on the food's side is held than the other: famished reaches for it.
    var foodArm: Double = 0
    /// How much of its look at the food the head takes over from the eyes. Leaning in, famished turns its
    /// whole face to the number: its big eyes sliding across the face on their own would end up on its smile.
    var foodFace: Double = 0
    /// Eyes shut in bliss that open now and then, and no blinks while they are shut: stuffed
    /// (`PetRigMoodBeats.bliss`).
    var bliss: Double = 0

    /// The channels a posture sets. `turn` and `lookX` are 0 in every posture but the den's stirring,
    /// whose face turns toward the notch's edge.
    static let channels: [WritableKeyPath<PetBody, Double>] = [
        \.squash, \.girth, \.curl, \.lean, \.tilt, \.nod, \.turn, \.lookX, \.lidL, \.lidR, \.lidSlant, \.happy,
        \.eyeSize, \.browLiftL, \.browLiftR, \.browTiltL, \.browTiltR, \.smile, \.mouthOpen, \.mouthWide, \.blush,
        \.armL, \.armR, \.glow, \.shine,
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
        m.foodLean = PetCurve.mix(a.foodLean, b.foodLean, t)
        m.foodStep = PetCurve.mix(a.foodStep, b.foodStep, t)
        m.foodArm = PetCurve.mix(a.foodArm, b.foodArm, t)
        m.foodFace = PetCurve.mix(a.foodFace, b.foodFace, t)
        m.bliss = PetCurve.mix(a.bliss, b.bliss, t)
        for i in m.breath.indices { m.breath[i] = PetCurve.mix(a.breath[i], b.breath[i], t) }
        return m
    }

    /// A blend `elapsed` into `length` from `a` to `b`. Between bean eyes and the closed arcs of bliss or
    /// a squint the eye's drawing cross-fades (`PetCanvas.happyBand`), and a cross-fade held for more than
    /// a couple of frames shows two drawings at once: a blend that takes `happy` across it does so on a
    /// quick clock of its own, `eyeClock`, while everything else moves at the blend's pace.
    static func blended(_ a: PetPosture, _ b: PetPosture, elapsed: Double, over length: Double) -> PetPosture {
        var m = mixed(a, b, PetEase.smoother(elapsed / length))
        if length > eyeClock, crossesTheEyeBand(a.body.happy, b.body.happy) {
            m.body.happy = PetCurve.mix(a.body.happy, b.body.happy, PetEase.smoother(elapsed / eyeClock))
        }
        return m
    }

    /// How long eyes take to open out of bliss or shut into it.
    static let eyeClock = 0.2

    static func crossesTheEyeBand(_ x: Double, _ y: Double) -> Bool {
        let band = PetCanvas.happyBand
        return min(x, y) < band.upperBound && max(x, y) > band.lowerBound && abs(x - y) > 0.05
    }

    static func make(hz: Double, zeta: Double, breath: Double, amp: Double, drift: Double, food: Double = 0,
                     foodLean: Double = 0, foodStep: Double = 0, foodArm: Double = 0, foodFace: Double = 0,
                     _ f: (inout PetBody) -> Void) -> PetPosture {
        var p = PetBody()
        p.smile = 0.42
        p.blush = 0.45
        p.lidL = 0.94
        p.lidR = 0.94
        f(&p)
        return PetPosture(body: p, jellyHz: hz, jellyZeta: zeta, breath: PetRigIdle.bankWeights(breath), breathAmp: amp,
                          drift: drift, lookAtFood: food, foodLean: foodLean, foodStep: foodStep, foodArm: foodArm,
                          foodFace: foodFace)
    }
}

extension PetPosture {
    /// At home, nothing needed: a soft smile, relaxed lids, a medium jelly.
    static let content = make(hz: 3.4, zeta: 0.30, breath: PetTuning.Idle.breathPeriod,
                              amp: PetTuning.Idle.breathAmplitude, drift: 1) { _ in }

    /// Fed to the brim: rounder, breathing slower, pleased. The lower lids smile up under open eyes
    /// (happy stays below the cross-fade to closed arcs), and the brows sit easy and level: a mood people
    /// live with for hours, so never the heavy upper lids and lowered brows that read smug at real size.
    /// Heavy lids are for the yawn before a nap only (`heavy`).
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

    /// Fed far past the brim and loving it: round and low on its feet, leaning back from the number belly
    /// out, the nubs resting on the belly, eyes shut in bliss over a wide smile and rosy cheeks, the chin
    /// up, the brows high and easy, its light over the brim. The belly itself is the meter's
    /// (`PetRigMeter.belly`), so it stays round whatever the pet does. Bliss, never sleep: never heavy lids,
    /// lowered or pinched brows, a yawn or lying down, and its eyes open now and then to look about.
    static let stuffed: PetPosture = {
        var posture = make(hz: 2.3, zeta: 0.24, breath: 4.6, amp: 0.026, drift: 0.6, foodLean: -0.04) { p in
            p.squash = 0.95; p.girth = 1.05; p.nod = 0.1; p.lidL = 1; p.lidR = 1; p.happy = 0.92; p.eyeSize = 1
            p.browLiftL = 0.45; p.browLiftR = 0.5; p.browTiltL = 0.1; p.browTiltR = 0.1
            p.smile = 0.95; p.mouthWide = 1.12; p.blush = 1.0; p.armL = -0.45; p.armR = -0.45; p.glow = 1.12
        }
        posture.bliss = 1
        return posture
    }()

    /// The meter near the top, and every bit of it hope: up on its toes, leaning in at the number and a
    /// step closer to it, the near nub reaching, shining eyes on it, the brows high and level, an eager open
    /// smile, rosy cheeks. Its light is low (that is the meter), so the face carries the mood: never a
    /// raised inner brow, a down-turned mouth, a lower or thinner body, a tear or a tongue resting out.
    static let famished = make(hz: 3.2, zeta: 0.34, breath: 3.7, amp: 0.02, drift: 0.6, food: 1.0, foodLean: 0.09,
                               foodStep: 1.2, foodArm: 0.4, foodFace: 1) { p in
        p.squash = 1.03; p.eyeSize = 1.3; p.lidL = 1; p.lidR = 1; p.lidSlant = -0.18; p.shine = 1
        p.browLiftL = 0.95; p.browLiftR = 1.05; p.browTiltL = 0; p.browTiltR = 0.02
        p.smile = 0.6; p.mouthOpen = 0.2; p.mouthWide = 0.7; p.blush = 0.9; p.armL = 0.45; p.armR = 0.45
        p.glow = 1.08
    }

    /// Fed when it was famished: eyes shut, brows up and touched, the widest smile, pink to the ears, its
    /// light up.
    static let grateful = make(hz: 3.0, zeta: 0.3, breath: 2.8, amp: 0.02, drift: 0.3) { p in
        p.squash = 0.98; p.girth = 1.02; p.happy = 1; p.lidL = 1; p.lidR = 1; p.browLiftL = 0.7; p.browLiftR = 0.75
        p.browTiltL = 0.14; p.browTiltR = 0.14; p.smile = 1.0; p.blush = 1.1; p.armL = -0.15; p.armR = -0.15; p.glow = 1.25
    }

    /// Stuffed with its eyes open, as Full's are: looking at a grey dot when the numbers are stale.
    static let stuffedOpen: PetPosture = {
        var posture = stuffed
        posture.body.happy = PetRigMoodBeats.blissOpenHappy
        posture.bliss = 0
        return posture
    }()

    /// Too full to keep its eyes open: round, a slow low wobble, heavy-lidded. Only the start of the yawn
    /// at the 5-hour limit; awake and stuffed, it is `stuffed`.
    static let heavy = make(hz: 1.9, zeta: 0.26, breath: 1.6, amp: 0.02, drift: 0.2) { p in
        p.squash = 0.96; p.girth = 1.1; p.lidL = 0.52; p.lidR = 0.52; p.lidSlant = 0.2; p.happy = 0.3
        p.browLiftL = 0.1; p.browLiftR = 0.1; p.browTiltL = 0.14; p.browTiltR = 0.14; p.smile = 0.55
        p.blush = 0.85; p.armL = 0.3; p.armR = 0.3; p.glow = 1.2
    }

    /// After a feast that leaves it short of stuffed: round and blissful, eyes shut, before it settles
    /// into `satisfied`.
    static let feasted = make(hz: 2.4, zeta: 0.28, breath: 2.8, amp: 0.024, drift: 0.4) { p in
        p.squash = 0.97; p.girth = 1.07; p.lidL = 1; p.lidR = 1; p.happy = 0.92; p.browLiftL = 0.4; p.browLiftR = 0.42
        p.browTiltL = 0.1; p.browTiltR = 0.1; p.smile = 0.9; p.blush = 0.95; p.armL = -0.2; p.armR = -0.2; p.glow = 1.18
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

    /// The posture of a mood, the open behaviours' base.
    static func mood(_ m: PetMood) -> PetPosture {
        switch m {
        case .stuffed: return .stuffed
        case .full: return .full
        case .content: return .content
        case .peckish: return .peckish
        case .hungry: return .hungry
        case .famished: return .famished
        }
    }
}
