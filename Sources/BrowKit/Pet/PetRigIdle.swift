// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// One blink's shape: shut fast, a short hold, open slower (close 0.05 s, hold 0.02 s, open 0.07 s),
/// stretched to `length`. 1 open, 0 shut.
enum IdleBlink {
    static func shape(_ tau: Double, length: Double = PetTuning.Idle.blink) -> Double {
        typealias I = PetTuning.Idle
        guard tau > 0, tau < length else { return 1 }
        let k = length / I.blink
        let close = I.blinkClose * k, hold = I.blinkHold * k
        if tau < close { return 1 - PetEase.inQuad(tau / close) }
        if tau < close + hold { return 0 }
        return PetEase.outQuad((tau - close - hold) / (length - close - hold))
    }
}

/// A schedule of moments with random access: moment k falls somewhere in [k·period, (k + 1)·period −
/// minimumGap], placed by `PetNoise`, so consecutive moments are `minimumGap` to `2·period − minimumGap`
/// apart. Blinks every 2.4 to 6.5 s, glances every 4 to 11 s and rare idles every 45 to 120 s are all this,
/// and finding the ones near any instant costs two hashes, whatever the uptime.
struct PetRigSchedule {
    var period: Double
    var minimumGap: Double
    var channel: PetNoise.Channel

    func time(_ k: Int, seed: UInt64) -> Double {
        Double(k) * period + (period - minimumGap) * PetNoise.hash(seed, channel, k)
    }

    /// The moments that started in the last `lookBack` seconds, newest last.
    func recent(at t: Double, lookBack: Double, seed: UInt64) -> [(k: Int, at: Double)] {
        let last = Int(floor(t / period))
        let first = Int(floor((t - lookBack) / period)) - 1
        var out: [(Int, Double)] = []
        for k in first...last {
            let at = time(k, seed: seed)
            if at <= t && at > t - lookBack { out.append((k, at)) }
        }
        return out
    }
}

/// Idle life: breath, sway and weight shift on periods that never line up, drift on value noise, blinks,
/// glances, small and rare idles. All of it from `PetNoise`, so it is the same on every run and never
/// loops: the schedules are aperiodic and the noise is not a cycle.
enum PetRigIdle {
    // MARK: Breath

    /// The breath's oscillators. A posture breathes on the one nearest its period.
    static let breathBank: [Double] = [1.6, 2.0, 2.8, 3.7, 4.2, 4.6, 6.0]

    static func bankWeights(_ period: Double) -> [Double] {
        var w = [Double](repeating: 0, count: breathBank.count)
        let i = breathBank.indices.min { abs(breathBank[$0] - period) < abs(breathBank[$1] - period) } ?? 3
        w[i] = 1
        return w
    }

    /// The idle cycles a pose is driven by, for the closed-form steady state of the springs.
    struct Cycles {
        var breathW: Double
        var breathPhase: Double
        var breathAmp: Double
        var shiftW: Double
        var shiftAmp: Double
        var shiftPhase: Double
    }

    static func cycles(posture: PetPosture, scene: PetRigPoser) -> Cycles {
        // The strongest oscillator stands for the breath; the weaker one of a cross-fade is a fraction of
        // a percent of squash and is left out of the springs' drive.
        let i = posture.breath.indices.max { posture.breath[$0] < posture.breath[$1] } ?? 3
        let amplitude = profile(scene).breath * posture.breathAmp * posture.breath[i]
        return Cycles(breathW: 2 * .pi / breathBank[i], breathPhase: breathPhase(i, seed: scene.seed),
                      breathAmp: amplitude, shiftW: 2 * .pi / PetTuning.Idle.shiftPeriod,
                      shiftAmp: profile(scene).amplitude * PetTuning.Idle.shiftAmplitude * scene.s,
                      shiftPhase: 2 * .pi * PetNoise.hash(scene.seed, PetRigChannel.shiftPhase, 0))
    }

    static func breathPhase(_ i: Int, seed: UInt64) -> Double {
        2 * .pi * PetNoise.hash(seed, PetRigChannel.breathPhase, i)
    }

    /// The breath at `t`: in a little quicker than out, its phase wandering slowly so no two minutes match.
    static func breath(_ posture: PetPosture, t: Double, seed: UInt64) -> Double {
        let wander = 0.6 * PetDrift.drift(t, period: 23, seed: seed, channel: PetRigChannel.driftBreath)
        var b = 0.0
        for (i, w) in posture.breath.enumerated() where w > 0.0001 {
            let ph = 2 * .pi * t / breathBank[i] + breathPhase(i, seed: seed) + wander
            b += w * (sin(ph) + 0.22 * sin(2 * ph - 0.6))
        }
        return b
    }

    // MARK: What each behaviour allows

    struct Profile {
        /// How far the idle layers wander: 1 at rest, 0.5 settled.
        var amplitude: Double
        /// How much of the posture's breath shows.
        var breath: Double
        var blinks: Bool
        var glances: Bool
        var small: Bool
        var rare: Bool
    }

    /// Blinks and glances are kept out of acting: an action owns the face.
    static func profile(_ scene: PetRigPoser) -> Profile {
        let beat = PetRigBeat(segments: scene.timeline.segments, index: scene.segmentIndex, t: scene.t)
        return profile(beat.behaviour, reduceMotion: scene.motion.reduceMotion)
    }

    static func profile(_ b: PetBehaviour, reduceMotion: Bool) -> Profile {
        var p: Profile
        switch b {
        case .idle: p = Profile(amplitude: 1, breath: 1, blinks: true, glances: true, small: true, rare: true)
        case .settled: p = Profile(amplitude: PetTuning.Presence.settledAmplitude, breath: 1, blinks: true, glances: true,
                                   small: false, rare: false)
        case .eager: p = Profile(amplitude: 0.6, breath: 1, blinks: true, glances: false, small: true, rare: false)
        case .unsureIdle: p = Profile(amplitude: 0.7, breath: 1, blinks: true, glances: false, small: false, rare: false)
        case .satisfied(.meal), .satisfied(.feast), .satisfied(.brim), .satisfied(.grateful):
            p = Profile(amplitude: 0.4, breath: 1, blinks: false, glances: false, small: false, rare: false)
        case .asleep, .hibernating, .stirring, .rollOver: p = Profile(amplitude: 0, breath: 1, blinks: false, glances: false,
                                                           small: false, rare: false)
        case .drowsy: p = Profile(amplitude: 0.15, breath: 1, blinks: false, glances: false, small: false, rare: false)
        case .denWait: p = Profile(amplitude: 0.5, breath: 1, blinks: true, glances: false, small: false, rare: false)
        case .doze, .off: p = Profile(amplitude: 0, breath: 0, blinks: false, glances: false, small: false, rare: false)
        default: p = Profile(amplitude: 0.25, breath: 1, blinks: false, glances: false, small: false, rare: false)
        }
        if reduceMotion {
            // Reduce Motion: idle is breathing at half amplitude, and blinks.
            p.amplitude = 0
            p.small = false
            p.rare = false
            p.glances = false
        }
        return p
    }

    // MARK: Schedules

    static let blinks = PetRigSchedule(period: (PetTuning.Idle.blinkBase + PetTuning.Idle.blinkSpread / 2),
                                       minimumGap: PetTuning.Idle.blinkBase, channel: PetRigChannel.blinkAt)
    static let glances = PetRigSchedule(period: PetTuning.Idle.glanceBase + PetTuning.Idle.glanceSpread / 2,
                                        minimumGap: PetTuning.Idle.glanceBase, channel: PetRigChannel.glanceAt)
    static let rares = PetRigSchedule(period: PetTuning.Idle.rareBase + PetTuning.Idle.rareSpread / 2,
                                      minimumGap: PetTuning.Idle.rareBase, channel: PetRigChannel.rareAt)
    /// The glutton's small habits between the rare idles: a lick at the number, a brow flick, a squish.
    static let smalls = PetRigSchedule(period: 20, minimumGap: 9, channel: PetRigChannel.smallAt)
    static let rumbles = PetRigSchedule(period: (PetTuning.Idle.rumbleMinimum + PetTuning.Idle.rumbleMaximum) / 2,
                                        minimumGap: PetTuning.Idle.rumbleMinimum, channel: PetRigChannel.rumbleAt)
    static let bounces = PetRigSchedule(period: (PetTuning.Eager.bounceMinimum + PetTuning.Eager.bounceMaximum) / 2,
                                        minimumGap: PetTuning.Eager.bounceMinimum, channel: PetRigChannel.bounceAt)
    static let drowsyBlinks = PetRigSchedule(period: (PetTuning.Limits.drowsyBlinkMinimum + PetTuning.Limits.drowsyBlinkMaximum) / 2,
                                             minimumGap: PetTuning.Limits.drowsyBlinkMinimum, channel: PetRigChannel.drowsyBlink)

    /// A pet's own blink rate, within ±15 %, from its seed: every interval of its schedule is scaled by it.
    static func blinkRate(seed: UInt64) -> Double {
        1 + PetTuning.Idle.blinkRateSpread * (2 * PetNoise.hash(seed, PetRigChannel.blinkRate, 0) - 1)
    }

    /// How open the eyes are under the blink schedule at `t`. 12 % of blinks are double.
    static func blinkOpen(at t: Double, seed: UInt64) -> Double {
        let rate = blinkRate(seed: seed)
        let local = t / rate
        var open = 1.0
        for (k, at) in blinks.recent(at: local, lookBack: 0.6 / rate, seed: seed) {
            let start = at * rate
            open = min(open, IdleBlink.shape(t - start))
            if PetNoise.hash(seed, PetRigChannel.blinkDouble, k) < PetTuning.Idle.doubleBlinkShare {
                open = min(open, IdleBlink.shape(t - start - 0.24))
            }
        }
        return open
    }

    /// The blinks' start times in [from, to], for the tests and the showreel's last frame.
    static func blinkStarts(from: Double, to: Double, seed: UInt64) -> [Double] {
        let rate = blinkRate(seed: seed)
        var out: [Double] = []
        let first = Int(floor(from / rate / blinks.period)) - 1, last = Int(floor(to / rate / blinks.period))
        for k in first...last {
            let at = blinks.time(k, seed: seed) * rate
            if at >= from && at <= to { out.append(at) }
        }
        return out
    }

    // MARK: - The layer

    static func apply(_ body: inout PetBody, posture: PetPosture, beat: PetRigBeat, scene: PetRigPoser) {
        let profile = profile(beat.behaviour, reduceMotion: scene.motion.reduceMotion)
        let t = scene.t, seed = scene.seed, s = scene.s
        let a = profile.amplitude * posture.drift

        // Breath: squash and girth, the light rising and falling with it.
        let b = breath(posture, t: t, seed: seed) * profile.breath
        body.squash += posture.breathAmp * b
        body.girth += 0.35 * posture.breathAmp * b
        body.fullness += 0.012 * b
        body.glow += 0.05 * b

        // Sway, weight shift and appendage drift: three cycles of 7.3, 11.9 and 5.3 s, which never line up.
        typealias I = PetTuning.Idle
        let sway = sin(2 * .pi * t / I.swayPeriod + 2 * .pi * PetNoise.hash(seed, PetRigChannel.swayPhase, 0))
        body.lean += a * tan(I.swayDegrees * .pi / 180) * sway
        let shift = sin(2 * .pi * t / I.shiftPeriod + 2 * .pi * PetNoise.hash(seed, PetRigChannel.shiftPhase, 0))
        body.x += a * I.shiftAmplitude * s * shift
        let limbs = sin(2 * .pi * t / I.appendagePeriod + 2 * .pi * PetNoise.hash(seed, PetRigChannel.shiftPhase, 1))
        body.armL += a * 0.08 * limbs
        body.armR -= a * 0.08 * limbs

        // Drift: the head, the eyes and the brows each wander on their own noise.
        body.tilt += a * 0.02 * PetDrift.drift(t, period: 5.3, seed: seed, channel: PetRigChannel.driftLean)
        body.turn += a * 0.07 * PetDrift.drift(t, period: 2.9, seed: seed, channel: PetRigChannel.driftTurn)
        body.nod += a * 0.06 * PetDrift.drift(t, period: 3.4, seed: seed, channel: PetRigChannel.driftNod)
        body.lookX += a * 0.10 * PetDrift.drift(t, period: 1.9, seed: seed, channel: PetRigChannel.driftLookX)
        body.lookY += a * 0.08 * PetDrift.drift(t, period: 2.3, seed: seed, channel: PetRigChannel.driftLookY)
        body.browLiftL += a * 0.14 * PetDrift.drift(t, period: 2.2, seed: seed, channel: PetRigChannel.driftBrowL)
        body.browLiftR += a * 0.14 * PetDrift.drift(t, period: 2.5, seed: seed, channel: PetRigChannel.driftBrowR)
        body.armL += a * 0.12 * PetDrift.drift(t, period: 2.6, seed: seed, channel: PetRigChannel.driftArmL)
        body.armR += a * 0.12 * PetDrift.drift(t, period: 2.8, seed: seed, channel: PetRigChannel.driftArmR)

        // Blinks.
        if profile.blinks {
            let open = blinkOpen(at: t, seed: seed)
            body.lidL *= open
            body.lidR *= open
        }
        if case .drowsy = beat.behaviour {
            // Drowsy: slow, heavy blinks every 3 to 5 s, and a yawn at once and every 40 s.
            for (_, at) in drowsyBlinks.recent(at: t, lookBack: 0.8, seed: seed) where at > beat.start + 1.2 {
                let open = IdleBlink.shape(t - at, length: 0.6)
                body.lidL *= open
                body.lidR *= open
            }
            let every = PetTuning.Limits.drowsyYawnEvery
            let k = floor((t - beat.start) / every)
            if k >= 1 { PetRigActions.yawn(&body, e: t - beat.start - k * every, at: 0) }
        }
        if case .stirring = beat.behaviour {
            // Stirring in the den: the one open eye blinks as slowly as a drowsy pet's, with no yawn.
            for (_, at) in drowsyBlinks.recent(at: t, lookBack: 0.8, seed: seed) where at > beat.start + 2.0 {
                body.lidL *= IdleBlink.shape(t - at, length: 0.6)
            }
        }

        // The glutton's small habits, the rare idles, the hungry tummy.
        if profile.small { smallIdle(&body, beat: beat, scene: scene) }
        if profile.rare { rareIdle(&body, beat: beat, scene: scene) }
        if case .idle(let mood) = beat.behaviour, mood == .peckish || mood == .hungry || mood == .famished {
            rumble(&body, beat: beat, scene: scene)
        }
        if case .settled(let mood) = beat.behaviour, mood == .hungry || mood == .famished {
            rumble(&body, beat: beat, scene: scene)
        }

        // Eager's bounces on its toes.
        if case .eager = beat.behaviour, !scene.motion.reduceMotion {
            for bounce in eagerBounces(beat: beat, scene: scene) {
                let r = bounceRoot(t - bounce.start, height: bounce.height, air: bounce.air, scale: s)
                body.lift += r.lift
                body.squash += r.squash
                let up = PetCurve.envelope(t - bounce.start, 0.1, 0.25, bounce.air, bounce.air + 0.2)
                body.armL += 0.1 * up
                body.armR += 0.12 * up
            }
        }
    }

    // MARK: Small and rare idles

    enum Small: CaseIterable { case lick, browFlick, squish, sigh, shuffle }

    /// Which small habit the k-th one is. Eager only licks its lips, and hungry and famished never sigh:
    /// they lick.
    static func smallKind(_ k: Int, seed: UInt64, behaviour: PetBehaviour) -> Small {
        if case .eager = behaviour { return .lick }
        let kind = Small.allCases[Int(PetNoise.hash(seed, PetRigChannel.smallKind, k) * Double(Small.allCases.count))]
        if case .idle(let mood) = behaviour, mood == .hungry || mood == .famished, kind == .sigh { return .lick }
        return kind
    }

    /// The small habits are drawn at the idle's 30 fps, where ambient motion keeps to half a point a frame:
    /// each one is timed to move no faster, or it ticks instead of moving, every 20 s all day.
    static func smallIdle(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        let t = scene.t, seed = scene.seed
        let dir = scene.foodSide
        for (k, at) in smalls.recent(at: t, lookBack: 1.4, seed: seed) where at > beat.start + 1 {
            let tau = t - at
            switch smallKind(k, seed: seed, behaviour: beat.behaviour) {
            case .lick:
                // The nibble's lick at half its pace, the head turning less.
                PetRigActions.lick(&p, e: tau / 2, dir: dir, turn: 0.16)
            case .browFlick:
                p.browLiftL += 0.9 * PetCurve.envelope(tau, 0, 0.1, 0.12, 0.26)
                p.browLiftR += 0.85 * PetCurve.envelope(tau, 0.01, 0.11, 0.13, 0.27)
            case .squish:
                p.squash -= 0.04 * PetCurve.envelope(tau, 0, 0.16, 0.2, 0.44)
                p.happy = max(p.happy, 0.7 * PetCurve.envelope(tau, 0.04, 0.16, 0.5, 0.7))
                p.smile += 0.3 * PetCurve.envelope(tau, 0.04, 0.16, 0.5, 0.7)
            case .sigh:
                p.squash += 0.03 * PetCurve.envelope(tau, 0, 0.35, 0.36, 1.0, up: PetEase.inOutSine, down: PetEase.inOutSine)
                p.nod += 0.12 * PetCurve.envelope(tau, 0, 0.35, 0.36, 1.0)
            case .shuffle:
                let side = PetNoise.hash(seed, PetRigChannel.side, k) < 0.5 ? -1.0 : 1.0
                p.footL += 0.8 * PetCurve.envelope(tau, 0, 0.12, 0.16, 0.3) * (side < 0 ? 1 : 0.4)
                p.footR += 0.8 * PetCurve.envelope(tau, 0.24, 0.36, 0.4, 0.54) * (side > 0 ? 1 : 0.4)
                p.lean += 0.04 * side * PetCurve.envelope(tau, 0, 0.3, 0.5, 1.2)
            }
        }
    }

    enum Rare: CaseIterable { case lookAround, yawn, scratch, mote, pounce }

    /// Which rare idle the k-th one is. The pounce is the joke, and a joke told every few minutes stops
    /// being one: about one rare idle in twelve, the others sharing the rest.
    static func rareKind(_ k: Int, seed: UInt64) -> Rare {
        let h = PetNoise.hash(seed, PetRigChannel.rareKind, k)
        guard h < 1 - pounceShare else { return .pounce }
        let others: [Rare] = [.lookAround, .yawn, .scratch, .mote]
        return others[min(others.count - 1, Int(h / (1 - pounceShare) * Double(others.count)))]
    }

    static let pounceShare = 1.0 / 12

    /// The rare idle that started last, if it is still playing.
    static func rare(beat: PetRigBeat, scene: PetRigPoser) -> (kind: Rare, at: Double, k: Int)? {
        guard profile(beat.behaviour, reduceMotion: scene.motion.reduceMotion).rare else { return nil }
        for (k, at) in rares.recent(at: scene.t, lookBack: 4, seed: scene.seed).reversed() where at > beat.start + 2 {
            let kind = rareKind(k, seed: scene.seed)
            if scene.t - at < length(kind) { return (kind, at, k) }
        }
        return nil
    }

    /// The pounce's wind-up wiggle and its leap, to the landing squash, as times into it: faster than
    /// ambient motion may move at 30 fps, so the layer draws them in the fast class.
    static let pounceFast = 0.3..<1.6

    /// The fast window of the pounce playing in `segment` at `t`, or of the next one to come in it: the
    /// controller raises the frame rate for exactly this long. nil where no rare idle plays, or none is a
    /// pounce in the next hour and a half.
    static func fastWindow(after t: Double, segment: PetSegment, seed: UInt64, reduceMotion: Bool) -> Range<Double>? {
        guard profile(segment.behaviour, reduceMotion: reduceMotion).rare else { return nil }
        let first = Int(floor((max(t, segment.start) - pounceFast.upperBound) / rares.period)) - 1
        for k in first...(first + 64) {
            let at = rares.time(k, seed: seed)
            guard at > segment.start + 2, rareKind(k, seed: seed) == .pounce else { continue }
            let window = (at + pounceFast.lowerBound)..<(at + pounceFast.upperBound)
            if window.upperBound > t { return window }
        }
        return nil
    }

    static func length(_ r: Rare) -> Double {
        switch r {
        case .lookAround: return 2.4
        case .yawn: return 1.3
        case .scratch: return 1.85
        case .mote: return 3.2
        case .pounce: return pounceLength
        }
    }

    static func rareIdle(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        guard let r = rare(beat: beat, scene: scene) else { return }
        let tau = scene.t - r.at
        switch r.kind {
        case .lookAround:
            let env = PetCurve.envelope(tau, 0, 0.3, 2.0, 2.4)
            p.turn += 0.45 * sin(2 * .pi * tau / 2.4) * env
            p.lookX += 0.7 * sin(2 * .pi * tau / 2.4 + 0.3) * env
        case .yawn:
            PetRigActions.yawn(&p, e: tau, at: 0, scale: 0.55)
        case .scratch:
            // A scratch behind the side: one arm up, a few slow rubs, and down again. Slow enough for the
            // 30 fps the idle is drawn at, where a quick rub only shivers and a quick arm only ticks.
            let up = PetCurve.envelope(tau, 0, 0.65, 1.15, 1.8)
            p.armR += 1.5 * up + 0.12 * sin(2 * .pi * 3.5 * tau) * PetCurve.envelope(tau, 0.55, 0.7, 1.05, 1.2)
            p.tilt += 0.05 * up
            p.happy = max(p.happy, 0.8 * up)
            p.smile += 0.2 * up
        case .mote:
            // A dust mote drifts past: the eyes follow it (the particle is `PetRigParticles.mote`).
            let m = mote(at: tau, seed: scene.seed, k: r.k, scene: scene)
            PetRigGaze.lookToward(&p, m, weight: PetCurve.envelope(tau, 0.2, 0.5, 2.6, 3.0), scene: scene)
            p.browLiftL += 0.4 * PetCurve.envelope(tau, 0.3, 0.5, 1.5, 1.8)
        case .pounce:
            pounce(&p, tau: tau, scene: scene)
        }
    }

    /// Where the drifting mote is, `tau` into its rare idle: across the pet's view, above it, slowly.
    static func mote(at tau: Double, seed: UInt64, k: Int, scene: PetRigPoser) -> CGPoint {
        let s = scene.s
        let side = PetNoise.hash(seed, PetRigChannel.side, k + 7) < 0.5 ? -1.0 : 1.0
        let x = Double(scene.zone.anchor.x) + side * (16 - 10 * tau) * s
        let y = Double(scene.zone.anchor.y) - (24 + 3 * sin(tau * 2.1)) * s
            + 2 * s * PetDrift.noise(tau * 1.3, seed: seed, channel: PetRigChannel.driftMote)
        return CGPoint(x: x, y: y)
    }

    /// The rare comic failure: it eyes a mote, wiggles, pounces, and falls short; a sheepish look after.
    /// Its wind-up and leap are drawn in the fast class (`pounceFast`).
    static let pounceLength = 2.6

    static func pounceRoot(_ tau: Double, scale s: Double, side: Double) -> (dx: Double, lift: Double, squash: Double) {
        let wiggle = 0.03 * sin(2 * .pi * 6 * tau) * PetCurve.envelope(tau, 0.3, 0.45, 0.8, 0.9)
        let crouch = -0.12 * PetCurve.envelope(tau, 0.3, 0.5, 0.85, 0.92, up: PetEase.outQuad, down: PetEase.inQuad)
        var dx = 0.0, lift = 0.0, squash = wiggle + crouch
        if tau > 0.92 && tau < 1.32 {
            let u = (tau - 0.92) / 0.4
            lift = 4 * 3.5 * s * u * (1 - u)
            squash += 0.14 * abs(1 - 2 * u) * PetCurve.envelope(u, 0, 0.1, 0.85, 1)
            dx = side * 3 * s * u
        } else if tau >= 1.32 {
            dx = side * 3 * s * (1 - PetEase.inOutSine((tau - 1.9) / 0.6))
            squash -= 0.12 * PetCurve.envelope(tau, 1.32, 1.36, 1.38, 1.6, up: PetEase.outQuad)
        }
        return (dx, lift, squash)
    }

    static let pounceImpulses: [(Double, PetRigSecondary.Spring, Double)] = [(1.32, .jiggle, -2.0), (1.32, .brows, -8)]

    static func pounce(_ p: inout PetBody, tau: Double, scene: PetRigPoser) {
        let side = pounceSide(scene)
        let r = pounceRoot(tau, scale: scene.s, side: side)
        p.x += r.dx
        p.lift += r.lift
        p.squash += r.squash
        let up = PetCurve.envelope(tau, 0.95, 1.05, 1.2, 1.32)
        p.armL += 1.2 * up
        p.armR += 1.3 * up
        p.eyeSize += 0.15 * PetCurve.envelope(tau, 0.2, 0.35, 1.2, 1.4)
        p.lookY += 0.8 * PetCurve.envelope(tau, 0.1, 0.3, 1.3, 1.5)
        p.lookX += side * 0.5 * PetCurve.envelope(tau, 0.1, 0.3, 1.3, 1.5)
        // Missed: brows up and worried, a sheepish smile, a blush.
        let sheepish = PetCurve.envelope(tau, 1.4, 1.55, 2.2, 2.6)
        p.browTiltL += 0.25 * sheepish; p.browTiltR += 0.25 * sheepish
        p.browLiftL += 0.5 * sheepish; p.browLiftR += 0.6 * sheepish
        p.smile += 0.2 * sheepish
        p.blush += 0.4 * sheepish
        p.lookX -= side * 0.6 * sheepish
    }

    /// The pounce goes where there is room: away from the den and the readout's edge, toward the middle.
    static func pounceSide(_ scene: PetRigPoser) -> Double {
        let room = PetRigRoom(zone: scene.zone)
        return room.reach > 6 * scene.s ? room.foodSide : -room.foodSide
    }

    /// Peckish and hungry, a tummy rumble every 40 to 70 s: a shiver of the outline, a look down at the
    /// belly, and back to the number, hopeful.
    static func rumble(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        for (_, at) in rumbles.recent(at: scene.t, lookBack: 1.2, seed: scene.seed) where at > beat.start + 1.5 {
            let tau = scene.t - at
            // The shiver is the outline's own ripple; the clench under it is slow enough for 30 fps.
            p.tremor += 0.8 * PetCurve.ring(tau, 0, frequency: 15, decay: 0.09)
            p.squash -= 0.02 * PetCurve.envelope(tau, 0, 0.06, 0.1, 0.22)
            p.lookY -= 0.7 * PetCurve.envelope(tau, 0.05, 0.15, 0.45, 0.65)
            p.nod -= 0.15 * PetCurve.envelope(tau, 0.05, 0.15, 0.45, 0.65)
            p.browLiftL += 0.3 * PetCurve.envelope(tau, 0.05, 0.12, 0.4, 0.6)
            p.mouthWide = PetCurve.mix(p.mouthWide, 0.45, PetCurve.envelope(tau, 0.05, 0.12, 0.4, 0.6))
        }
    }

    /// The last rumble's start, if one is on: the rumble lines are drawn from it.
    static func rumbleStart(beat: PetRigBeat, scene: PetRigPoser) -> Double? {
        let mood: PetMood?
        switch beat.behaviour {
        case .idle(let m), .settled(let m): mood = m
        default: mood = nil
        }
        guard let m = mood, m == .hungry || m == .famished || (m == .peckish && isIdle(beat)) else { return nil }
        return rumbles.recent(at: scene.t, lookBack: 0.4, seed: scene.seed).last { $0.at > beat.start + 1.5 }?.at
    }

    static func isIdle(_ beat: PetRigBeat) -> Bool { if case .idle = beat.behaviour { return true }; return false }

    // MARK: Bounces

    /// Eager's small bounces on its toes every 1.6 to 2.2 s, inside the eager segment.
    static func eagerBounces(beat: PetRigBeat, scene: PetRigPoser) -> [(start: Double, height: Double, air: Double)] {
        guard case .eager = beat.behaviour else { return [] }
        let air = 0.34
        let length = 0.12 + air + 0.24
        return bounces.recent(at: scene.t, lookBack: length + PetTuning.Secondary.tail, seed: scene.seed)
            .filter { $0.at > beat.start + 0.4 && ($0.at + length < (beat.end ?? .infinity)) }
            .map { (start: $0.at, height: 0.6 * scene.s, air: air) }
    }

    /// One of eager's bounces on its toes: small and soft, because eager runs at the idle rate, 30 fps,
    /// where ambient motion keeps to half a point a frame.
    static func bounceRoot(_ tau: Double, height: Double, air: Double, scale: Double) -> (dx: Double, lift: Double, squash: Double) {
        var lift = 0.0, squash = 0.0
        let takeoff = 0.12
        squash -= 0.018 * PetCurve.envelope(tau, 0, 0.08, 0.09, takeoff + 0.1, up: PetEase.inOutSine, down: PetEase.inOutSine)
        if tau > takeoff && tau < takeoff + air {
            let u = (tau - takeoff) / air
            lift = 4 * height * u * (1 - u)
        }
        squash -= 0.02 * PetCurve.envelope(tau, takeoff + air - 0.04, takeoff + air + 0.06, takeoff + air + 0.08,
                                           takeoff + air + 0.24, up: PetEase.inOutSine, down: PetEase.inOutSine)
        return (0, lift, squash)
    }

    /// The idle movements that drive transients: eager's bounces and the pounce.
    static func motionSources(beat: PetRigBeat, scene: PetRigPoser) -> [PetRigSource] {
        var out: [PetRigSource] = []
        let posture = PetRigActions.posture(beat.behaviour, elapsed: 1, scene: scene)
        for b in eagerBounces(beat: beat, scene: scene) {
            out.append(PetRigSource(kind: .bounce(height: b.height, air: b.air), start: b.start, scale: scene.s,
                                    foodSide: 0, jellyHz: posture.jellyHz, jellyZeta: posture.jellyZeta))
        }
        if let r = rare(beat: beat, scene: scene), r.kind == .pounce {
            out.append(PetRigSource(kind: .pounce, start: r.at, scale: scene.s, foodSide: pounceSide(scene),
                                    jellyHz: posture.jellyHz, jellyZeta: posture.jellyZeta))
        }
        return out
    }
}
