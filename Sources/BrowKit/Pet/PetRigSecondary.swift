// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// Secondary motion: the jelly of the body, the top lagging behind, the light sloshing, the brows and arms
/// flopping, the belly. Linear damped springs, so their response is a sum: the closed-form steady state of
/// the idle cycles that drive them, plus one transient per action, integrated with semi-implicit Euler at
/// a fixed 1/240 s step from that action's own start, from rest, until 2 s after it ends. Nothing depends
/// on which frames were drawn before: a transient at any instant is the same integration from the same
/// start, which the memo only saves redoing.
enum PetRigSecondary {
    static let step = PetTuning.Secondary.step
    static let tail = PetTuning.Secondary.tail

    /// The springs, in the order the memo stores them.
    enum Spring: Int, CaseIterable {
        case jiggle, leanLag, slosh, wave, brows, armsUp, armsSide, belly
    }

    /// Brows are stiffer than the arms (ω 44 against the arms' 22, about 3.5 Hz): they are part of a
    /// face, and at 3.5 Hz they would read as antennae. The arms and the belly take the springs of
    /// `PetTuning.Secondary`.
    static func springs(_ source: PetRigSource) -> [PetSpring] {
        let jelly = 2 * Double.pi * source.jellyHz
        return [
            PetSpring(omega: jelly, zeta: source.jellyZeta),
            PetSpring(omega: jelly * 0.8, zeta: source.jellyZeta + 0.05),
            PetSpring(omega: 2 * .pi * 2.3, zeta: 0.16),
            PetSpring(omega: 2 * .pi * 4.2, zeta: 0.14),
            PetSpring(omega: 44, zeta: 0.42),
            PetSpring(omega: PetTuning.Secondary.appendageOmega, zeta: PetTuning.Secondary.appendageZeta),
            PetSpring(omega: PetTuning.Secondary.appendageOmega * 0.9, zeta: PetTuning.Secondary.appendageZeta),
            PetSpring(omega: PetTuning.Secondary.bellyOmega, zeta: PetTuning.Secondary.bellyZeta),
        ]
    }

    static func apply(_ body: inout PetBody, posture: PetPosture, beat: PetRigBeat, scene: PetRigPoser) {
        var x = [Double](repeating: 0, count: Spring.allCases.count)
        steadyState(&x, posture: posture, scene: scene)
        for source in sources(beat: beat, scene: scene) {
            let tau = scene.t - source.start
            guard tau > 0 else { continue }
            let state = scene.memo.state(source, at: tau)
            for i in x.indices { x[i] += state[i] }
        }
        body.squash *= 1 + x[Spring.jiggle.rawValue]
        body.lean += x[Spring.leanLag.rawValue]
        body.slosh += x[Spring.slosh.rawValue]
        body.wave += x[Spring.wave.rawValue]
        body.browLiftL += x[Spring.brows.rawValue]
        body.browLiftR += x[Spring.brows.rawValue] * 0.92
        body.armL += x[Spring.armsUp.rawValue] - x[Spring.armsSide.rawValue]
        body.armR += x[Spring.armsUp.rawValue] + x[Spring.armsSide.rawValue]
        body.girth *= 1 + x[Spring.belly.rawValue]
    }

    /// The idle cycles' share, in closed form: the breath drives the jelly and the belly, the weight
    /// shift drives the top's lag and the light's slosh. Each sinusoid's response is the spring's gain
    /// and lag at that frequency (`PetSpring.steadyState`).
    static func steadyState(_ x: inout [Double], posture: PetPosture, scene: PetRigPoser) {
        let idle = PetRigIdle.cycles(posture: posture, scene: scene)
        let probe = PetRigSource(kind: .idle, start: 0, scale: scene.s, foodSide: 0, jellyHz: posture.jellyHz,
                                 jellyZeta: posture.jellyZeta)
        let sp = springs(probe)
        // The breath scales y by A·b(t), b = sin(wt + φ) + 0.22 sin(2wt + 2φ − 0.6); its second derivative
        // is the force on the jelly, as an authored squash's is in a transient.
        for (k, amplitude, phase) in [(1.0, 1.0, 0.0), (2.0, 0.22, -0.6)] {
            let w = k * idle.breathW
            let force = 0.30 * idle.breathAmp * amplitude * w * w
            x[Spring.jiggle.rawValue] += sp[0].steadyState(amplitude: force, w: w, phase: k * idle.breathPhase + phase, at: scene.t)
            x[Spring.belly.rawValue] += sp[7].steadyState(amplitude: 0.35 * force, w: w, phase: k * idle.breathPhase + phase,
                                                          at: scene.t)
        }
        // The weight shift moves the root by ±0.4 pt; its acceleration leans the top back and tilts the light.
        let w = idle.shiftW
        let accel = idle.shiftAmp * w * w
        let h = PetBodyGeometry.restHeight
        x[Spring.leanLag.rawValue] += sp[1].steadyState(amplitude: 0.30 * accel / h, w: w, phase: idle.shiftPhase, at: scene.t)
        x[Spring.slosh.rawValue] += sp[2].steadyState(amplitude: 0.034 * accel, w: w, phase: idle.shiftPhase, at: scene.t)
    }

    /// Every source whose transient is still alive at the pose's instant.
    static func sources(beat: PetRigBeat, scene: PetRigPoser) -> [PetRigSource] {
        var out: [PetRigSource] = []
        let segments = scene.timeline.segments
        if let index = beat.index {
            // Segments whose action, plus its tail, still reaches the instant. No action lasts long
            // enough for one that started more than this long ago to matter.
            let oldest = scene.t - PetRigActions.longestAction - tail
            var i = index
            while i >= 0, segments[i].start >= oldest {
                let seg = segments[i]
                let end = i + 1 < segments.count ? segments[i + 1].start : nil
                let length = min(seg.behaviour.duration ?? .infinity, (end ?? .infinity) - seg.start)
                if seg.start + length + tail > scene.t,
                   let source = PetRigActions.source(seg, length: length, scene: scene) {
                    out.append(source)
                }
                i -= 1
            }
        }
        out += PetRigIdle.motionSources(beat: beat, scene: scene)
        if let dock = scene.flightSource { out.append(dock) }
        return out
    }
}

/// One source of transient motion: an action's own movement, a bounce, a hop between the strip and the
/// panel. Everything its integration depends on is in it, so it is also the memo's key.
struct PetRigSource: Hashable {
    enum Kind: Hashable {
        /// A segment's action, cut at `length` seconds.
        case segment(PetBehaviour, length: Double)
        /// One of eager's small bounces, or an idle hop.
        case bounce(height: Double, air: Double)
        /// The rare idle pounce that falls short.
        case pounce
        /// A beat at an end of the meter: a pat on the belly, a hiccup (`PetRigMoodBeats`).
        case beat(PetRigMoodBeats.Beat)
        /// The hop between the strip and the panel.
        case dock(expand: Bool, ax: Double, ay: Double, bx: Double, by: Double, sa: Double, sb: Double, stepsOff: Bool)
        /// The idle cycles' probe: never integrated.
        case idle
    }

    var kind: Kind
    var start: Double
    var scale: Double
    var foodSide: Double
    var jellyHz: Double
    var jellyZeta: Double
    /// Where the action can go, in points: the lunge's reach toward the food, and the den's offset from
    /// the anchor.
    var reach: Double = 0
    var denX: Double = 0
    var denY: Double = 0

    /// How long it pushes: after this, only its tail rings out.
    var length: Double {
        switch kind {
        case .segment(_, let length): return length
        case .bounce(_, let air): return air + 0.4
        case .pounce: return PetRigIdle.pounceLength
        case .beat(let b): return PetRigMoodBeats.length(b)
        case .dock(let expand, let ax, let ay, let bx, let by, _, _, _):
            return PetRigDock.hopDuration(expand: expand, a: CGPoint(x: ax, y: ay), b: CGPoint(x: bx, y: by))
        case .idle: return 0
        }
    }

    /// The source's own movement at `tau` seconds in, in points: the root's offset across, its lift, and
    /// its squash beyond 1.
    func root(_ tau: Double) -> (dx: Double, lift: Double, squash: Double) {
        switch kind {
        case .segment(let behaviour, let length):
            let room = PetRigRoom(scale: scale, foodSide: foodSide, reach: reach, denX: denX, denY: denY)
            return PetRigActions.root(behaviour, elapsed: min(tau, length), room: room)
        case .bounce(let height, let air):
            return PetRigIdle.bounceRoot(tau, height: height, air: air, scale: scale)
        case .pounce:
            return PetRigIdle.pounceRoot(tau, scale: scale, side: foodSide)
        case .beat(let b):
            return PetRigMoodBeats.root(b, min(tau, PetRigMoodBeats.length(b)), scale: scale, foodSide: foodSide)
        case .dock(let expand, let ax, let ay, let bx, let by, let sa, let sb, let stepsOff):
            let a = CGPoint(x: ax, y: ay), b = CGPoint(x: bx, y: by)
            let f = expand ? PetLayout.expand(a: a, b: b, scaleA: sa, scaleB: sb, stepsOff: stepsOff, tau: tau)
                           : PetLayout.collapse(a: a, b: b, scaleA: sa, scaleB: sb, beside: !stepsOff, tau: tau)
            let end = expand ? b : a
            return (Double(f.feet.x - end.x), Double(end.y - f.feet.y), f.squash - 1)
        case .idle:
            return (0, 0, 0)
        }
    }

    /// Kicks at given instants: a chomp, a landing, a gulp. (τ, spring, velocity).
    var impulses: [(Double, PetRigSecondary.Spring, Double)] {
        switch kind {
        case .segment(let behaviour, let length):
            return PetRigActions.impulses(behaviour).filter { $0.0 <= length }
        case .bounce(let height, let air):
            return [(0.12 + air, .jiggle, -0.02 * 4 * height / air)]
        case .pounce:
            return PetRigIdle.pounceImpulses
        case .beat(let b):
            return PetRigMoodBeats.impulses(b)
        case .dock(let expand, let ax, let ay, let bx, let by, _, _, _):
            let a = CGPoint(x: ax, y: ay), b = CGPoint(x: bx, y: by)
            let land = expand ? PetTuning.Hop.crouch + PetLayout.flightTime(from: a, to: b) : PetTuning.Hop.collapseY
            return [(land, .jiggle, -1.6), (land, .brows, -6)]
        case .idle:
            return []
        }
    }
}

/// Transients already integrated, by source. A pose reads the stored step at or before its instant and
/// the one after it, so the result is the same whether the steps were stored a moment ago, an hour ago,
/// or just now: a memo that makes a pose cheaper, never different.
final class PetRigMemo {
    private struct Track {
        /// Spring positions and velocities, `count` per step.
        var states: [Double]
        /// The root's last two samples, to continue the backward differences.
        var roots: [(dx: Double, lift: Double, squash: Double)]
        var steps: Int
        var springs: [PetSpring]
        var impulses: [(Double, PetRigSecondary.Spring, Double)]
    }

    private var tracks: [PetRigSource: Track] = [:]
    private var recent: [PetRigSource] = []
    private static let keep = 48
    private static let count = PetRigSecondary.Spring.allCases.count
    /// A track whose tail ended this long before the instant being posed is let go when a new one
    /// starts: the app's poses only move forward, so it would only hold memory. A pose that does go
    /// back to it integrates it again, to the same bits.
    private static let forgetAfter: Double = 5

    /// The springs' positions `tau` seconds after `source` started, interpolated between the two
    /// integration steps around it. After the source's length plus its tail it is at rest.
    func state(_ source: PetRigSource, at tau: Double) -> [Double] {
        let dt = PetRigSecondary.step
        let horizon = source.length + PetRigSecondary.tail
        guard tau < horizon else { return [Double](repeating: 0, count: Self.count) }
        let k = Int((tau / dt).rounded(.down))
        if tracks[source] == nil { forget(before: source.start + tau - Self.forgetAfter) }
        var track = tracks[source] ?? Self.begin(source)
        extend(&track, source: source, through: k + 1)
        tracks[source] = track
        touch(source)
        let frac = tau / dt - Double(k)
        var out = [Double](repeating: 0, count: Self.count)
        let base = k * 2 * Self.count, next = (k + 1) * 2 * Self.count
        for i in 0..<Self.count {
            let a = track.states[base + 2 * i], b = track.states[next + 2 * i]
            out[i] = a + (b - a) * frac
        }
        // Fade the last half second of the tail to exactly zero, so dropping it never pops.
        let fade = 1 - PetEase.smooth((tau - (horizon - 0.5)) / 0.5)
        if fade < 1 { for i in out.indices { out[i] *= fade } }
        return out
    }

    private static func begin(_ source: PetRigSource) -> Track {
        let r = source.root(0)
        return Track(states: [Double](repeating: 0, count: 2 * count), roots: [r, r], steps: 0,
                     springs: PetRigSecondary.springs(source), impulses: source.impulses.sorted { $0.0 < $1.0 })
    }

    /// Integrates from the last stored step to step `k`.
    private func extend(_ track: inout Track, source: PetRigSource, through k: Int) {
        guard track.steps < k else { return }
        let dt = PetRigSecondary.step
        let n = Self.count
        let s = max(source.scale, 0.1)
        let h = PetBodyGeometry.restHeight * s
        track.states.reserveCapacity((k + 1) * 2 * n)
        var x = [Double](repeating: 0, count: n), v = [Double](repeating: 0, count: n)
        let last = track.steps * 2 * n
        for i in 0..<n { x[i] = track.states[last + 2 * i]; v[i] = track.states[last + 2 * i + 1] }
        while track.steps < k {
            let step = track.steps + 1
            let tau = Double(step) * dt
            let r = source.root(tau)
            let r1 = track.roots[1], r0 = track.roots[0]
            // Backward differences of the source's own movement: the accelerations the body feels.
            let ax = (r.dx - 2 * r1.dx + r0.dx) / (dt * dt) / s
            let ay = (r.lift - 2 * r1.lift + r0.lift) / (dt * dt) / s
            let asq = (r.squash - 2 * r1.squash + r0.squash) / (dt * dt)
            track.roots = [r1, r]
            var force = [Double](repeating: 0, count: n)
            force[PetRigSecondary.Spring.jiggle.rawValue] = -0.30 * asq
            force[PetRigSecondary.Spring.leanLag.rawValue] = -0.30 * ax / (h / s)
            force[PetRigSecondary.Spring.slosh.rawValue] = -0.034 * ax
            force[PetRigSecondary.Spring.wave.rawValue] = -0.012 * ay
            force[PetRigSecondary.Spring.brows.rawValue] = -0.45 * ay / (h / s) * 20
            force[PetRigSecondary.Spring.armsUp.rawValue] = -0.07 * ay / (h / s) * 20
            force[PetRigSecondary.Spring.armsSide.rawValue] = -0.005 * ax
            // Kicks that land in this step.
            let from = tau - dt
            for (at, spring, amount) in track.impulses where at > from && at <= tau {
                v[spring.rawValue] += amount
            }
            for i in 0..<n { track.springs[i].step(&x[i], &v[i], force: force[i], dt: dt) }
            for i in 0..<n {
                track.states.append(x[i])
                track.states.append(v[i])
            }
            track.steps = step
        }
    }

    private func touch(_ source: PetRigSource) {
        if let i = recent.firstIndex(of: source) { recent.remove(at: i) }
        recent.append(source)
        if recent.count > Self.keep {
            let old = recent.removeFirst()
            tracks[old] = nil
        }
    }

    /// Lets go of every track whose source had come to rest by `instant`.
    private func forget(before instant: Double) {
        let done = Set(recent.filter { $0.start + $0.length + PetRigSecondary.tail < instant })
        guard !done.isEmpty else { return }
        for source in done { tracks[source] = nil }
        recent.removeAll { done.contains($0) }
    }

    /// How many sources are held, for the tests.
    var held: Int { tracks.count }
}
