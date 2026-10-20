// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// Where the pet looks. Priorities: the hop's destination, then the pointer, then the behaviour's own
/// glances; a behaviour that needs its eyes (the snap, the yawn) keeps them. Every response is in closed
/// form, a sum of the springs' step responses to each change of target, so a gaze at any instant needs no
/// history beyond the track it is given.
enum PetRigGaze {
    /// A gaze: the eyes inside the face, and the head's turn and nod.
    struct Look {
        var x = 0.0, y = 0.0, turn = 0.0, nod = 0.0

        static func + (a: Look, b: Look) -> Look { Look(x: a.x + b.x, y: a.y + b.y, turn: a.turn + b.turn, nod: a.nod + b.nod) }
        static func - (a: Look, b: Look) -> Look { Look(x: a.x - b.x, y: a.y - b.y, turn: a.turn - b.turn, nod: a.nod - b.nod) }
        static func * (a: Look, k: Double) -> Look { Look(x: a.x * k, y: a.y * k, turn: a.turn * k, nod: a.nod * k) }
    }

    /// Glances: the eyes dart, the head follows 60 ms later with a little overshoot.
    static let eyeDart = PetSpring(omega: 40, zeta: 0.85)
    static let headGlance = PetSpring(omega: 12, zeta: 0.7)
    /// Watching the pointer: the eyes critically damped at ω 18, the head at ω 9, ζ 0.9.
    static let eyeWatch = PetSpring(omega: PetTuning.Pointer.eyeOmega, zeta: 1)
    static let headWatch = PetSpring(omega: PetTuning.Pointer.headOmega, zeta: PetTuning.Pointer.headZeta)

    /// The eyes, in window coordinates: the controller measures the pointer's distance from the same
    /// point.
    static func eyes(_ body: PetBody) -> CGPoint {
        CGPoint(x: body.x, y: body.floorY - body.lift - PetTuning.Pointer.eyeHeight * 0.77 * body.size)
    }

    /// The gaze that looks at `target`: the eyes turn first; past 25° off straight ahead the head turns
    /// too. "Straight ahead" is out of the screen, toward the viewer, `depth` points away.
    static func toward(_ target: CGPoint, from e: CGPoint, scale s: Double) -> Look {
        let dx = Double(target.x - e.x), dy = Double(target.y - e.y)
        let distance = max(hypot(dx, dy), 0.001)
        let depth = 60 * s
        let angle = atan(distance / depth)
        let reach = PetCurve.clamp(distance / (6 * s), 0, 1)
        let ux = dx / distance, uy = dy / distance
        let follow = PetTuning.Pointer.headFollowDegrees * .pi / 180
        let head = PetCurve.clamp((angle - follow) / (.pi / 2 - follow), 0, 1)
        return Look(x: ux * reach, y: -uy * reach, turn: ux * 0.75 * head, nod: -uy * 0.5 * head)
    }

    static func lookToward(_ p: inout PetBody, _ target: CGPoint, weight w: Double, scene: PetRigPoser) {
        guard w > 0.001 else { return }
        let l = toward(target, from: eyes(p), scale: p.size)
        p.lookX = PetCurve.mix(p.lookX, l.x, w)
        p.lookY = PetCurve.mix(p.lookY, l.y, w)
        p.turn = PetCurve.mix(p.turn, l.turn, w)
        p.nod = PetCurve.mix(p.nod, l.nod, w)
    }

    /// Behaviours whose own acting needs the eyes for their whole length.
    static func ownsEyes(_ b: PetBehaviour) -> Bool {
        switch b {
        case .eat, .fallAsleep, .wake, .rollOver, .asleep, .hibernating, .stirring, .enterDen, .leaveDen, .intro, .peek,
             .celebrate, .boop, .dozeIn, .doze, .denWait, .off:
            return true
        default:
            return false
        }
    }

    static func apply(_ p: inout PetBody, posture: PetPosture, beat: PetRigBeat, scene: PetRigPoser) {
        // The eyes rest on the food source in the moods that want it: eager, hungry, famished, unsure; a beat
        // at an end of the meter may take them to the viewer or down to the tummy for a moment.
        var foodWeight = posture.lookAtFood
        if case .unsureIdle = beat.behaviour { foodWeight = max(foodWeight, 0.8) }
        let beats = PetRigMoodBeats.gaze(beat: beat, scene: scene)
        foodWeight *= 1 - max(beats.viewer, beats.away)
        if foodWeight > 0.001 {
            let base = Look(x: p.lookX, y: p.lookY, turn: p.turn, nod: p.nod)
            var food = toward(scene.zone.foodSource, from: eyes(p), scale: p.size)
            // Leaning in, the head takes over part of the eyes' travel and the face turns as one.
            food.turn += 0.12 * food.x * posture.foodFace
            food.x *= 1 - 0.4 * posture.foodFace
            let l = base + (food - Look(x: 0, y: 0, turn: 0, nod: 0)) * foodWeight
            p.lookX = l.x; p.lookY = l.y; p.turn = l.turn; p.nod = l.nod
        }
        glances(&p, beat: beat, scene: scene)
        cues(&p, beat: beat, scene: scene)
        // Under Reduce Motion too: following the pointer turns the eyes and the head, and moves nothing
        // across the screen.
        watch(&p, beat: beat, scene: scene)
        hideAndPeek(&p, beat: beat, scene: scene)
        // A thumbs-up and please look straight out of the screen at whoever is there, wherever the pointer is.
        let viewer = beats.viewer
        if viewer > 0.001 {
            p.lookX = PetCurve.mix(p.lookX, 0, viewer)
            p.lookY = PetCurve.mix(p.lookY, 0.1, viewer)
            p.turn = PetCurve.mix(p.turn, 0, viewer)
            p.nod = PetCurve.mix(p.nod, p.nod + 0.06, viewer)
        }
        // Eyes shut in bliss do not roll under their lids: a glance turns the head, and the arcs stay where
        // they are, over the smile, rather than sliding down onto it.
        if posture.bliss > 0.001 {
            let band = PetCanvas.happyBand
            let shut = PetCurve.ramp(p.happy, band.lowerBound, band.upperBound) * posture.bliss
            p.lookX *= 1 - shut
            p.lookY *= 1 - shut
        }
        if let target = scene.lookAt {
            lookToward(&p, target, weight: 1, scene: scene)
        }
    }

    // MARK: Glances

    enum GlanceTarget: CaseIterable { case food, den, viewer, down }

    /// Glances every 4 to 11 s, to the food source, the den, the viewer or down; hungry glances at the food
    /// three times as often. Each holds 1 to 2.5 s.
    static func glances(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        let allowed = PetRigIdle.profile(beat.behaviour, reduceMotion: scene.motion.reduceMotion).glances
        let previous = beat.previous.map { PetRigIdle.profile($0.behaviour, reduceMotion: scene.motion.reduceMotion).glances } ?? false
        let w = allowed ? PetCurve.ramp(beat.elapsed, 0, 0.3) : (previous ? 1 - PetCurve.ramp(beat.elapsed, 0, 0.3) : 0)
        guard w > 0.001 else { return }
        let t = scene.t, seed = scene.seed
        let hungry: Bool
        switch beat.behaviour {
        case .idle(let m), .settled(let m): hungry = m == .hungry || m == .peckish || m == .famished
        default: hungry = false
        }
        var eye = Look(), head = Look()
        let e = eyes(p)
        for (k, at) in PetRigIdle.glances.recent(at: t, lookBack: 4.5, seed: seed) {
            let hold = 1.0 + 1.5 * PetNoise.hash(seed, PetRigChannel.glanceHold, k)
            let target = glanceTarget(k, hungry: hungry, from: e, scene: scene, size: p.size)
            for (start, sign) in [(at, 1.0), (at + hold, -1.0)] where start <= t {
                eye = eye + target * (sign * (1 - eyeDart.stepRemainder(t - start)))
                head = head + target * (sign * (1 - headGlance.stepRemainder(t - start - PetTuning.Idle.eyeLead)))
            }
        }
        p.lookX += w * eye.x
        p.lookY += w * eye.y
        p.turn += w * head.turn
        p.nod += w * head.nod
    }

    static func glanceTarget(_ k: Int, hungry: Bool, from e: CGPoint, scene: PetRigPoser, size: Double) -> Look {
        let r = PetNoise.hash(scene.seed, PetRigChannel.glanceTarget, k)
        // Food, den, viewer, down; hungry triples the food's share.
        let weights: [Double] = hungry ? [3, 1, 1, 1] : [1, 1, 1, 1]
        let total = weights.reduce(0, +)
        var acc = 0.0, pick = GlanceTarget.viewer
        for (i, w) in weights.enumerated() {
            acc += w / total
            if r < acc { pick = GlanceTarget.allCases[i]; break }
        }
        switch pick {
        case .food:
            return toward(scene.zone.foodSource, from: e, scale: size)
        case .den:
            if case .side(let edge) = scene.zone.den { return toward(CGPoint(x: edge + 12, y: e.y - 4), from: e, scale: size) }
            if case .overhead(let notch) = scene.zone.den { return toward(CGPoint(x: e.x + 4, y: notch.midY), from: e, scale: size) }
            return Look(x: -scene.foodSide * 0.8, y: 0.2, turn: -scene.foodSide * 0.3, nod: 0.05)
        case .viewer:
            return Look(x: 0, y: 0.05, turn: 0, nod: 0.08)
        case .down:
            return Look(x: 0.15, y: -0.7, turn: 0.05, nod: -0.22)
        }
    }

    // MARK: Cues

    static func cues(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        let t = scene.t
        for cue in scene.timeline.cues.reversed() {
            if cue.t > t { continue }
            let tau = t - cue.t
            if tau > 3 { break }
            switch cue.kind {
            case .notice:
                // Noticed (0.25 s): the eyes widen, the brows pop, a little flinch.
                guard !ownsEyes(beat.behaviour) else { continue }
                let pop = PetCurve.envelope(tau, 0, 0.05, 0.12, PetTuning.Behaviour.notice + 0.1)
                p.browLiftL += 0.8 * pop
                p.browLiftR += 0.6 * pop
                p.eyeSize += 0.12 * PetCurve.envelope(tau, 0, 0.06, 0.8, 1.2)
                p.squash -= 0.04 * PetCurve.envelope(tau, 0, 0.04, 0.06, 0.18)
                p.mouthOpen = max(p.mouthOpen, 0.16 * PetCurve.envelope(tau, 0.02, 0.08, 0.5, 0.8))
                p.mouthWide = PetCurve.mix(p.mouthWide, 0.45, PetCurve.envelope(tau, 0.02, 0.08, 0.5, 0.8))
            case .release:
                continue
            case .twitch:
                // Glim has no ears: a brow twitches in its sleep.
                let k = PetCurve.bump(tau, 0, 0.12) + 0.7 * PetCurve.bump(tau, 0.14, 0.26)
                p.browLiftR += 0.7 * k
                p.tremor += 0.15 * PetCurve.bump(tau, 0, 0.2)
            case .sleepyEye:
                // Booped asleep: one eye opens halfway, looks, and closes (0.9 s).
                let open = PetCurve.envelope(tau, 0.1, 0.28, 0.6, PetTuning.Boop.sleepyEye)
                p.lidR = max(p.lidR, 0.5 * open)
                p.browLiftR += 0.6 * open
            case .glowPulse:
                // Booped hibernating: the glow pulses once (0.6 s).
                p.glow += 0.35 * PetCurve.bump(tau, 0, PetTuning.Boop.glowPulse)
            case .greet:
                // A gesture of its own (`PetRigMoodBeats`).
                continue
            }
        }
    }

    // MARK: The pointer

    /// How much the pointer holds the gaze: from a `notice` until 0.6 s after the `release`; in the panel,
    /// whenever the pointer has moved in the last moments.
    static func watchWeight(beat: PetRigBeat, scene: PetRigPoser) -> Double {
        let t = scene.t
        if scene.zone.kind == .panel {
            guard let last = scene.pointer.samples.last(where: { $0.t <= t }) else { return 0 }
            return 1 - PetCurve.ramp(t - last.t, 1.5, 2.0)
        }
        let cues = scene.timeline.cues
        guard let notice = cues.last(where: { $0.kind == .notice && $0.t <= t }) else { return 0 }
        var w = PetCurve.ramp(t - notice.t, 0, 0.12)
        if let release = cues.last(where: { $0.kind == .release && $0.t <= t }), release.t > notice.t {
            w *= 1 - PetCurve.ramp(t - release.t - PetTuning.Pointer.releaseHold, 0, 0.35)
        }
        return w
    }

    static func watch(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        var w = watchWeight(beat: beat, scene: scene)
        if ownsEyes(beat.behaviour) { w *= 1 - PetCurve.ramp(beat.elapsed, 0, 0.15) }
        if let prev = beat.previous, ownsEyes(prev.behaviour), !ownsEyes(beat.behaviour) {
            w *= PetCurve.ramp(beat.elapsed, 0, 0.3)
        }
        guard w > 0.001 else { return }
        let samples = scene.pointer.samples
        guard let lastIndex = samples.lastIndex(where: { $0.t <= scene.t }) else { return }
        let e = eyes(p)
        let s = p.size
        let eye = respond(samples, through: lastIndex, at: scene.t, window: 0.8, spring: eyeWatch) {
            toward($0, from: e, scale: s)
        }
        let head = respond(samples, through: lastIndex, at: scene.t, window: 1.6, spring: headWatch) {
            toward($0, from: e, scale: s)
        }
        p.lookX = PetCurve.mix(p.lookX, eye.x, w)
        p.lookY = PetCurve.mix(p.lookY, eye.y, w)
        p.turn = PetCurve.mix(p.turn, head.turn, w)
        p.nod = PetCurve.mix(p.nod, head.nod, w)
        // Watching, one brow stays up: curious, not alarmed.
        p.browLiftL += 0.35 * w
    }

    /// A spring's response at `t` to the pointer's path as a series of steps: it starts settled on the
    /// last sample before `window`, then each later sample is a step of the target. At most the 120 most
    /// recent samples count; older ones have long settled.
    static func respond(_ samples: [PetPointerSample], through last: Int, at t: Double, window: Double,
                        spring: PetSpring, look: (CGPoint) -> Look) -> Look {
        var first = last
        while first > 0, samples[first].t > t - window, last - first < 120 { first -= 1 }
        var value = look(samples[first].location)
        var previous = value
        if first < last {
            for j in (first + 1)...last {
                let target = look(samples[j].location)
                value = value + (target - previous) * (1 - spring.stepRemainder(t - samples[j].t))
                previous = target
            }
        }
        return value
    }

    // MARK: The rare hide-and-peek

    /// After a long calm, a pointer that comes at the pet fast sends it behind the camera for a moment:
    /// it ducks into the den, peeks out with one eye, and comes back (a rare reaction, not the default).
    /// Derived from the pointer track alone, never from chance: nothing that reacts to the person is
    /// random. Beside only, where there is a den to duck into.
    static let calm: Double = 15
    static let hideLength: Double = 1.6

    static func hideStart(scene: PetRigPoser, beat: PetRigBeat) -> Double? {
        guard scene.zone.kind == .beside, !scene.motion.reduceMotion else { return nil }
        switch beat.behaviour {
        case .idle, .settled, .unsureIdle: break
        default: return nil
        }
        let samples = scene.pointer.samples
        let t = scene.t
        let anchor = scene.zone.anchor
        let eye = CGPoint(x: anchor.x, y: anchor.y - PetTuning.Pointer.eyeHeight * scene.zone.scale)
        func distance(_ q: CGPoint) -> Double { Double(hypot(q.x - eye.x, q.y - eye.y)) }
        for j in samples.indices.reversed() where j > 0 {
            let sj = samples[j]
            if sj.t > t { continue }
            if sj.t < t - hideLength - 0.3 { break }
            guard sj.t - samples[j - 1].t >= calm else { continue }
            // The approach: the next quarter second, closing fast to within the notice distance. A new idle
            // segment (a mood change) does not cancel the reaction; anything else is not idle, above.
            let trigger = sj.t + 0.25
            guard trigger <= t else { continue }
            guard let end = samples.last(where: { $0.t <= trigger }) else { continue }
            let closed = distance(sj.location) - distance(end.location)
            if closed >= 100, distance(end.location) <= PetTuning.Pointer.notice { return trigger }
        }
        return nil
    }

    static func hideAndPeek(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        guard let start = hideStart(scene: scene, beat: beat) else { return }
        let tau = scene.t - start
        guard tau < hideLength else { return }
        let room = PetRigRoom(zone: scene.zone)
        let s = scene.s
        // Flinch, duck behind the camera (all but one eye), peek, come back out.
        let flinch = PetCurve.envelope(tau, 0, 0.04, 0.06, 0.14)
        p.squash -= 0.1 * flinch
        p.eyeSize += 0.15 * PetCurve.envelope(tau, 0, 0.05, 0.3, 0.45)
        p.browLiftL += 0.9 * flinch; p.browLiftR += 0.8 * flinch
        let duck = PetCurve.envelope(tau, 0.06, 0.32, 1.05, 1.5, up: PetEase.outCubic, down: PetEase.inOutCubic)
        p.x += room.peekX * duck
        p.lift += 2.0 * s * PetCurve.bump(tau, 0.06, 0.32)
        p.lean -= 0.18 * PetCurve.envelope(tau, 0.4, 0.55, 0.95, 1.1)
        p.tilt -= 0.06 * PetCurve.envelope(tau, 0.4, 0.55, 0.95, 1.1)
        p.mouthOpen = max(p.mouthOpen, 0.15 * PetCurve.envelope(tau, 0.45, 0.55, 0.9, 1.0))
        p.mouthWide = PetCurve.mix(p.mouthWide, 0.42, PetCurve.envelope(tau, 0.45, 0.55, 0.9, 1.0))
    }
}
