// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

// The rig's small motion toolkit: easings, envelopes, value noise and damped springs. Everything here
// is a pure function of its arguments, which is what lets `PetRig.pose` be one too. The names carry a
// `Pet` prefix because the pet's two halves share one module.

/// Named easings only, never a linear tween, which starts and stops at full speed and reads as
/// mechanical. Each takes and clamps a fraction.
enum PetEase {
    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Cubic smoothstep: slow in, slow out.
    static func smooth(_ t: Double) -> Double { let x = clamp01(t); return x * x * (3 - 2 * x) }

    /// Quintic smootherstep, for curves no spring smooths afterwards: its acceleration is continuous
    /// too, so a channel that follows it never shows a kink at 60 fps.
    static func smoother(_ t: Double) -> Double {
        let x = clamp01(t)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    static func inOutSine(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * clamp01(t)) }
    static func inQuad(_ t: Double) -> Double { let x = clamp01(t); return x * x }
    static func outQuad(_ t: Double) -> Double { let x = 1 - clamp01(t); return 1 - x * x }
    static func inCubic(_ t: Double) -> Double { let x = clamp01(t); return x * x * x }
    static func outCubic(_ t: Double) -> Double { let x = 1 - clamp01(t); return 1 - x * x * x }

    /// Ease-in-out cubic, the easing for moves.
    static func inOutCubic(_ t: Double) -> Double {
        let x = clamp01(t)
        if x < 0.5 { return 4 * x * x * x }
        let y = -2 * x + 2
        return 1 - y * y * y / 2
    }

    /// Ease-out-back, the easing for pops: it overshoots by `PetTuning.Idle.popOvershoot`.
    static func outBack(_ t: Double, _ overshoot: Double = PetTuning.Idle.popOvershoot) -> Double {
        let x = clamp01(t) - 1
        return 1 + x * x * ((overshoot + 1) * x + overshoot)
    }
}

/// Envelopes keyed by time: the base layer of every action is made of these.
enum PetCurve {
    @inline(__always) static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    @inline(__always) static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// 0 before `a`, 1 after `b`, eased in between.
    static func ramp(_ t: Double, _ a: Double, _ b: Double, _ ease: (Double) -> Double = PetEase.smooth) -> Double {
        if t <= a { return 0 }
        if t >= b { return 1 }
        return ease((t - a) / (b - a))
    }

    /// Rises over [a, b], holds, falls over [c, d]; 0 outside [a, d].
    static func envelope(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double,
                         up: (Double) -> Double = PetEase.smooth,
                         down: (Double) -> Double = PetEase.smooth) -> Double {
        if t <= a || t >= d { return 0 }
        if t < b { return up((t - a) / (b - a)) }
        if t <= c { return 1 }
        return 1 - down((t - c) / (d - c))
    }

    /// A single smooth bump over [a, b]: up and down with no hold, its peak in the middle.
    static func bump(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard t > a, t < b else { return 0 }
        let x = (t - a) / (b - a)
        let s = sin(.pi * x)
        return s * s
    }

    /// A decaying oscillation that starts at `t0` (0 before it), faded in over `attack` so it never
    /// starts with a jump in speed: a tremble, a rumble, a shiver.
    static func ring(_ t: Double, _ t0: Double, frequency: Double, decay: Double, attack: Double = 0.025,
                     phase: Double = 0) -> Double {
        let tau = t - t0
        guard tau > 0 else { return 0 }
        let a = attack > 0 ? PetEase.smooth(tau / attack) : 1
        return a * sin(2 * .pi * frequency * tau + phase) * exp(-tau / decay)
    }
}

/// Smooth value noise from `PetNoise`: random access in O(1), never periodic, and the same for the same
/// seed on every Mac. Idle drift is made of it, so a day of idle never repeats and any instant of it
/// can be posed on its own.
enum PetDrift {
    /// Value noise in [-1, 1] at `x`, interpolated with the quintic smootherstep (C²: no kinks).
    static func noise(_ x: Double, seed: UInt64, channel: PetNoise.Channel) -> Double {
        let i = floor(x)
        let f = x - i
        let k = Int(i)
        let a = PetNoise.hash(seed, channel, k) * 2 - 1
        let b = PetNoise.hash(seed, channel, k &+ 1) * 2 - 1
        return a + (b - a) * (f * f * f * (f * (f * 6 - 15) + 10))
    }

    /// Two octaves of noise over `period` seconds: an idle wander that never loops.
    static func drift(_ t: Double, period: Double, seed: UInt64, channel: PetNoise.Channel) -> Double {
        0.7 * noise(t / period, seed: seed, channel: channel)
            + 0.3 * noise(t / (period * 0.43) + 17.3, seed: seed, channel: PetNoise.Channel(channel.raw ^ 0x80))
    }
}

/// A linear damped spring, x'' + 2ζω x' + ω² x = force, as the secondary motion uses it: in closed form
/// where the drive is known (a sinusoid's steady state, a step, an impulse), and stepped with
/// semi-implicit Euler where it is not (an action's transient).
struct PetSpring: Sendable, Hashable {
    var omega: Double
    var zeta: Double

    /// One semi-implicit Euler step: the velocity first, then the position from the new velocity.
    /// Stable for ω·dt well under 1, which the rig's 1/240 s step keeps (ω ≤ 60 rad/s).
    @inline(__always)
    func step(_ x: inout Double, _ v: inout Double, force: Double, dt: Double) {
        v += (force - omega * omega * x - 2 * zeta * omega * v) * dt
        x += v * dt
    }

    /// The steady-state response to `amplitude · sin(w·t + phase)`: the spring's transfer function
    /// gives its gain and its lag, so a periodic idle drive needs no integration at all.
    func steadyState(amplitude: Double, w: Double, phase: Double, at t: Double) -> Double {
        let re = omega * omega - w * w
        let im = 2 * zeta * omega * w
        let gain = amplitude / (re * re + im * im).squareRoot()
        let lag = atan2(im, re)
        return gain * sin(w * t + phase - lag)
    }

    /// From x = 1 at rest to the target 0, `tau` seconds after a step: what a gaze does after its target
    /// jumps. 1 before the step. Exact for every damping ratio.
    func stepRemainder(_ tau: Double) -> Double {
        guard tau > 0 else { return 1 }
        let a = zeta * omega
        if zeta < 0.999 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            return exp(-a * tau) * (cos(wd * tau) + a / wd * sin(wd * tau))
        }
        if zeta > 1.001 {
            let r = omega * (zeta * zeta - 1).squareRoot()
            let s1 = -a + r, s2 = -a - r
            return (s1 * exp(s2 * tau) - s2 * exp(s1 * tau)) / (s1 - s2)
        }
        return exp(-omega * tau) * (1 + omega * tau)
    }
}
