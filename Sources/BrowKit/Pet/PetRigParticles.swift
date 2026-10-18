// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// The bits of light around the pet: each a pure function of its spawn time on the timeline and its
/// hashed parameters, so a particle is where it is whatever was drawn before. At most
/// `PetTuning.Particles.maximumAlive` at once. Under Reduce Motion, Zzz and sparkles fade in place.
enum PetRigParticles {
    struct Extras {
        var particles: [PetParticle] = []
        var bead: PetBead?
        var glint: PetGlint?
        var door: PetDoorLight?
        /// The boxes the canvas must hold besides the body.
        var points: [CGRect] = []
    }

    static func make(body: PetBody, beat: PetRigBeat, scene: PetRigPoser) -> Extras {
        var out = Extras()
        let segments = scene.timeline.segments
        guard let index = beat.index else { return out }
        // The segment playing, however long ago it started (a sleep's Zzz and the light under the den's
        // door go on for hours), and, since particles outlive their segment by a little, those that ended
        // in the last few seconds.
        let oldest = scene.t - 7
        var i = index
        while i >= 0 {
            let seg = segments[i]
            let end = i + 1 < segments.count ? segments[i + 1].start : nil
            if i < index, let end, end < oldest { break }
            spawn(seg, end: end, current: i == index, body: body, scene: scene, into: &out)
            i -= 1
        }
        if let start = PetRigIdle.rumbleStart(beat: beat, scene: scene) { rumble(at: start, body: body, scene: scene, into: &out) }
        if let r = PetRigIdle.rare(beat: beat, scene: scene), r.kind == .mote || r.kind == .pounce {
            let tau = scene.t - r.at
            let m = r.kind == .mote ? PetRigIdle.mote(at: tau, seed: scene.seed, k: r.k, scene: scene)
                                    : pounceMote(tau: tau, scene: scene)
            let o = PetCurve.envelope(tau, 0, 0.3, PetRigIdle.length(r.kind) - 0.5, PetRigIdle.length(r.kind))
            out.particles.append(PetParticle(kind: .mote, position: m, size: 0.55 * scene.s, opacity: 0.8 * o, tint: .sparkle))
        }
        // Nothing but the food itself crosses into the readouts' gap: a rumble line or a sparkle that would
        // is left out rather than drawn over a number.
        let guards = PetLayout.guards(scene.zone)
        let bounds = scene.zone.bounds
        out.particles = out.particles.filter { p in
            if case .dot = p.tint { return true }
            let r = p.size * 1.2 + 0.5
            if guards.min != nil, Double(p.position.x) - r < Double(bounds.minX) { return false }
            if guards.max != nil, scene.zone.kind != .panel, Double(p.position.x) + r > Double(bounds.maxX) { return false }
            return true
        }
        // Keep the brightest few.
        let limit = PetTuning.Particles.maximumAlive
        if out.particles.count > limit {
            out.particles = Array(out.particles.sorted { $0.opacity > $1.opacity }.prefix(limit))
        }
        for p in out.particles where p.opacity > 0.003 {
            let r = p.size * 2 + 2
            out.points.append(CGRect(x: p.position.x - r, y: p.position.y - r, width: 2 * r, height: 2 * r))
        }
        if let b = out.bead {
            let r = b.radius * 4
            out.points.append(CGRect(x: b.position.x - r, y: b.position.y - r, width: 2 * r, height: 2 * r))
            for q in b.trail { out.points.append(CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)) }
        }
        if let g = out.glint {
            let r = g.size * 1.5
            out.points.append(CGRect(x: g.position.x - r, y: g.position.y - r, width: 2 * r, height: 2 * r))
        }
        if let d = out.door {
            out.points.append(CGRect(x: d.minX, y: d.y, width: d.maxX - d.minX, height: 4))
        }
        return out
    }

    static func segments(_ scene: PetRigPoser) -> [PetSegment] { scene.timeline.segments }

    static func hash(_ seed: UInt64, _ start: Double, _ k: Int) -> Double {
        PetNoise.hash(seed, PetRigChannel.particle, Int(truncatingIfNeeded: Int64((start * 240).rounded())) &* 31 &+ k)
    }

    /// The particles one segment leaves.
    static func spawn(_ seg: PetSegment, end: Double?, current: Bool, body: PetBody, scene: PetRigPoser, into out: inout Extras) {
        let t = scene.t, s = scene.s, seed = scene.seed
        let tau = t - seg.start
        let anchor = scene.zone.anchor
        let crown = CGPoint(x: Double(anchor.x), y: Double(anchor.y) - 21 * s)
        switch seg.behaviour {
        case .eat(let meal):
            guard current || tau < PetRigActions.timing(meal).end + 0.6 else { return }
            food(meal, start: seg.start, body: body, current: current, scene: scene, into: &out)
        case .satisfied(.meal), .satisfied(.brim), .satisfied(.grateful):
            for (k, at) in [0.12, 0.38, 0.62].enumerated() where (end ?? .infinity) > seg.start + at {
                sparkle(at: seg.start + at, origin: CGPoint(x: crown.x + [-6, 5, -1][k] * s, y: crown.y + 2 * s),
                        seed: seed, k: k, size: 2.0 * s, scene: scene, into: &out)
            }
        case .satisfied(.feast):
            for (k, at) in [0.2, 0.5, 0.8].enumerated() where (end ?? .infinity) > seg.start + at {
                sparkle(at: seg.start + at, origin: CGPoint(x: crown.x + [6, -5, 2][k] * s, y: crown.y + 1 * s),
                        seed: seed, k: k, size: 1.5 * s, scene: scene, into: &out)
            }
            bubble(at: seg.start + 1.4, body: body, scene: scene, into: &out)
        case .celebrate(let kind):
            let times: [Double] = kind == .goodWeek ? [0.5, 0.8, 1.1, 1.6, 1.8] : [0.5, 0.62, 0.75, 1.3, 1.45, 1.6]
            for (k, at) in times.enumerated() {
                let a = 2 * Double.pi * hash(seed, seg.start, 40 + k)
                let origin = CGPoint(x: crown.x + cos(a) * 9 * s, y: crown.y + (2 - 4 * hash(seed, seg.start, 50 + k)) * s)
                let size = (PetTuning.Particles.sparkleSizeMinimum
                            + (PetTuning.Particles.sparkleSizeMaximum - PetTuning.Particles.sparkleSizeMinimum)
                            * hash(seed, seg.start, 60 + k)) * s
                sparkle(at: seg.start + at, origin: origin, seed: seed, k: k, size: size, scene: scene, into: &out)
            }
        case .freshWindow:
            for (k, at) in [0.5, 0.65].enumerated() {
                sparkle(at: seg.start + at, origin: CGPoint(x: crown.x + [-5, 6][k] * s, y: crown.y - 2 * s),
                        seed: seed, k: k, size: 1.8 * s, scene: scene, into: &out)
            }
        case .boop(let giggle):
            if giggle {
                for (k, at) in [0.3, 0.7].enumerated() {
                    sparkle(at: seg.start + at, origin: CGPoint(x: crown.x + [-6, 6][k] * s, y: crown.y + 2 * s),
                            seed: seed, k: k, size: 1.6 * s, scene: scene, into: &out)
                }
            }
        case .wake:
            let at = PetTuning.Behaviour.wakeStir + PetTuning.Behaviour.wakeStretch + 0.35
            // The Zzz still rising when it wakes pop as it starts: the sleep's own segment draws them, with
            // its end, however long the sleep was.
            for k in 0..<2 {
                sparkle(at: seg.start + at + 0.1 * Double(k), origin: CGPoint(x: crown.x + [-7, 6][k] * s, y: crown.y),
                        seed: seed, k: k, size: 1.7 * s, scene: scene, into: &out)
            }
        case .fallAsleep:
            // The first Zzz rises from the curl, and pops if the pet is woken before the next segment.
            let at = seg.start + PetTuning.Behaviour.fallAsleep - 0.35
            if at < (end ?? .infinity) {
                let next = end.flatMap { e in segments(scene).first { $0.start == e } }
                let woken = next.map { if case .asleep = $0.behaviour { return false } else { return true } } ?? false
                zzz(at: at, k: 0, seg: seg, scene: scene, into: &out, until: woken ? end : nil)
            }
        case .asleep:
            // Zzz rising 10 pt over 2.6 s, three alive at most; brisk for a minute, then slower.
            let life = PetTuning.Particles.zzzLife
            for k in max(0, asleepZzzIndex(at: tau - life))...max(0, asleepZzzIndex(at: tau)) {
                zzz(at: seg.start + asleepZzz(k), k: k, seg: seg, scene: scene, into: &out, until: end)
            }
        case .hibernating:
            // Curled into a ball where there is no den, it sleeps too deep for Zzz: that is what tells it
            // from the 5-hour sleep on the pill at a glance.
            if case .none = scene.zone.den { break }
            let every = PetTuning.Den.zzzEvery
            let life = PetTuning.Particles.zzzLife
            let first = Int(floor((t - seg.start - 1.5 - life) / every))
            for k in max(0, first)...max(0, Int(floor((t - seg.start - 1.5) / every))) {
                zzz(at: seg.start + 1.5 + Double(k) * every, k: k, seg: seg, scene: scene, into: &out, until: end, den: true)
            }
            door(seg, end: end, scene: scene, into: &out)
        case .enterDen, .stirring, .denWait, .peek, .leaveDen:
            door(seg, end: end, scene: scene, into: &out)
        default:
            break
        }
    }

    // MARK: The food

    /// The bead of light and its crumbs: popped out of the number, inhaled along an arc, landing on the
    /// snap; a glint on the ripe digit while the pet winds up; the pulse of light where the bite lands in
    /// the belly.
    static func food(_ meal: PetMeal, start: Double, body: PetBody, current: Bool, scene: PetRigPoser, into out: inout Extras) {
        let tau = scene.t - start
        let s = scene.s
        let source = beadOrigin(scene.zone)
        let dot = scene.zone.foodDot
        if meal.reduceMotion {
            // No flight under Reduce Motion: the light fades in at the mouth.
            guard current else { return }
            let mouth = PetBodyGeometry(body).facePoint(dTheta: 0, dv: -0.36).p
            let o = PetCurve.envelope(tau, 0, 0.1, 0.12, PetTuning.Reduced.mealFade)
            if o > 0.003 {
                out.bead = PetBead(position: mouth, radius: 1.4 * s, stretch: 1, angle: 0, opacity: o, trail: [], dot: dot)
            }
            return
        }
        let m = PetRigActions.timing(meal)
        // The glint, before the bite.
        if let digit = ripeDigit(scene.zone), tau < m.snap {
            let o = PetCurve.envelope(tau, 0, m.anticipation * 0.35, m.anticipation * 0.7, m.snap)
            if o > 0.003 {
                out.glint = PetGlint(position: digit, size: (1.6 + 1.0 * PetCurve.bump(tau, 0, m.snap)) * min(s, 1.2),
                                     opacity: 0.9 * o, angle: 0.5 * tau)
            }
        }
        // The bead's flight: 0.35 s to the snap, or as much of it as a nibble has.
        let flight = min(PetTuning.Meal.crumbFlight, m.snap - 0.02)
        let launch = m.snap - flight
        if current, tau >= launch, tau <= m.snap + 0.03 {
            let mouth = PetBodyGeometry(body).facePoint(dTheta: 0, dv: -0.36).p
            // In the panel the "5h" figure is on the Overall line under the header, and an arc over the
            // header's words would cross them, or the notch above them: there the bead runs along the gap
            // between the header row and the Overall line and rises into the mouth from below.
            let c = scene.zone.kind == .panel
                ? CGPoint(x: Double(mouth.x) + 2 * s, y: Double(scene.zone.bounds.maxY) + 6 * s)
                : CGPoint(x: PetCurve.mix(Double(source.x), Double(mouth.x), 0.45), y: min(Double(source.y), Double(mouth.y)) - 7 * s)
            func position(_ u: Double) -> CGPoint {
                let k = PetEase.inQuad(u)
                let a = Double(source.x), b = Double(mouth.x)
                let x = (1 - k) * (1 - k) * a + 2 * (1 - k) * k * Double(c.x) + k * k * b
                let y = (1 - k) * (1 - k) * Double(source.y) + 2 * (1 - k) * k * Double(c.y) + k * k * Double(mouth.y)
                return CGPoint(x: x, y: y)
            }
            let u = PetCurve.clamp((tau - launch) / flight, 0, 1)
            let p = position(u)
            let q = position(max(0, u - 1 / (240 * flight)))
            let speed = hypot(Double(p.x - q.x), Double(p.y - q.y)) * 240
            var trail: [CGPoint] = []
            for k in 1...6 { trail.append(position(max(0, u - Double(k) / (200 * flight)))) }
            let grow = PetEase.outBack(min(1, (tau - launch) / 0.08))
            let swallow = 1 - 0.6 * PetCurve.ramp(tau, m.snap - 0.03, m.snap + 0.03)
            let o = 1 - PetCurve.ramp(tau, m.snap, m.snap + 0.03)
            out.bead = PetBead(position: p, radius: 1.5 * s * (m.full ? 1 : 0.8) * grow * swallow,
                               stretch: min(1.9, 1 + speed / 380), angle: atan2(Double(p.y - q.y), Double(p.x - q.x)),
                               opacity: o, trail: trail, dot: dot)
            // Crumbs riding along on their own arcs, a hair behind.
            let count = PetTuning.Meal.crumbsMinimum
                + Int(hash(scene.seed, start, 1) * Double(PetTuning.Meal.crumbsMaximum - PetTuning.Meal.crumbsMinimum + 1))
            for k in 0..<count {
                // Each crumb rides its own arc a little behind the bead, spread across its path.
                let lag = 0.035 + 0.045 * Double(k) + 0.02 * hash(scene.seed, start, 10 + k)
                let uk = PetCurve.clamp((tau - launch - lag) / flight, 0, 1)
                guard uk > 0.02, uk < 1 else { continue }
                var pk = position(uk)
                // Below the bead's path rather than across the face, and gone before they reach it.
                pk.y += (1.2 + 2.2 * hash(scene.seed, start, 20 + k)) * s * sin(.pi * uk)
                let size = (PetTuning.Meal.crumbSizeMinimum
                            + (PetTuning.Meal.crumbSizeMaximum - PetTuning.Meal.crumbSizeMinimum) * hash(scene.seed, start, 30 + k)) * 0.5 * s
                out.particles.append(PetParticle(kind: .crumb, position: pk, size: size,
                                                 opacity: PetTuning.Meal.crumbOpacity * (1 - PetCurve.ramp(uk, 0.5, 0.78)),
                                                 tint: .dot(dot)))
            }
        }
        // A crumb or two flicked out by the second chew.
        if m.chews >= 2 {
            let at = m.chewStart + m.chew * 1.4
            crumbs(at: start + at, origin: mouthGuess(scene), count: 2, side: -scene.foodSide * 0.6, seed: scene.seed,
                   key: start, scene: scene, into: &out)
        }
        // The pulse of light at the splash: a soft ring that swells within the halo and fades, never out
        // across the strip toward the numbers. It is a band of light right on the body's edge, on top of
        // the flare, so it comes up over 0.2 s and stays faint: brighter or quicker, and the two together
        // flash in the corner of the eye at every meal.
        let ringTau = tau - m.splash
        if ringTau >= 0, ringTau < 0.45 {
            let u = ringTau / 0.45
            let anchor = scene.zone.anchor
            out.particles.append(PetParticle(kind: .ring, position: CGPoint(x: Double(anchor.x), y: Double(anchor.y) - 9 * s),
                                             size: 11.5 * s * PetCurve.mix(0.85, 1.2, PetEase.outCubic(u)),
                                             opacity: (m.feast ? 0.14 : 0.08) * (1 - u) * PetCurve.ramp(ringTau, 0, 0.2),
                                             tint: .ring))
        }
    }

    /// Where the bead pops out: the end of the readout nearest the pet, so it leaves the digits as light
    /// and never crosses them. Below, the dot comes first, so the bead pops out of the gap left of the
    /// dot rather than between the dot and the digits, where it would fly back through the dot.
    static func beadOrigin(_ zone: PetZone) -> CGPoint {
        let source = zone.foodSource
        switch zone.kind {
        case .beside, .pill:
            return CGPoint(x: zone.bounds.minX - PetTuning.Readout.gap + 1, y: source.y + 0.5)
        case .below:
            return CGPoint(x: zone.bounds.maxX + PetTuning.Readout.gap - 2, y: source.y + 0.5)
        case .panel:
            return CGPoint(x: source.x - 8, y: source.y)
        }
    }

    static func mouthGuess(_ scene: PetRigPoser) -> CGPoint {
        CGPoint(x: Double(scene.zone.anchor.x) + scene.foodSide * 2 * scene.s, y: Double(scene.zone.anchor.y) - 7.7 * scene.s)
    }

    /// Where the glint sits on the ripe digit, the readout's last one, which the food is about to come out
    /// of: on its top-right shoulder, where a star catches the eye without filling the counter of a 0, 4,
    /// 6, 8 or 9 and changing what the number reads. nil when there is no number (the `—`).
    static func ripeDigit(_ zone: PetZone) -> CGPoint? {
        typealias R = PetTuning.Readout
        let digit = R.twoDigitWidth - R.oneDigitWidth
        let percent = R.oneDigitWidth - digit
        let source = zone.foodSource
        let textEnd: CGFloat
        switch zone.kind {
        case .beside, .pill:
            textEnd = zone.bounds.minX - R.gap
        case .below:
            // The left readout ends at the strip's middle; its text is centred on the food source.
            let width = 2 * (source.x - zone.bounds.maxX - R.gap - EarsMetrics.dotSize - EarsMetrics.dotSpacing)
            textEnd = source.x + width / 2
        case .panel:
            return CGPoint(x: source.x + 3, y: source.y - 1)
        }
        let width = 2 * (textEnd - source.x)
        guard width > R.dashWidth + 1 else { return nil }
        return CGPoint(x: textEnd - percent - digit * 0.12, y: source.y - 4.6)
    }

    /// A few crumbs thrown from `origin`: they fly, fall, bounce once on the floor and fade.
    static func crumbs(at t0: Double, origin: CGPoint, count: Int, side: Double, seed: UInt64, key: Double,
                       scene: PetRigPoser, into out: inout Extras) {
        let t = scene.t
        guard t >= t0, t < t0 + 1.1 else { return }
        let s = scene.s
        let g = 190.0 * s, floor = Double(scene.zone.anchor.y) + 0.9 * s
        for i in 0..<count {
            let r = { (k: Int) in hash(seed, key, 100 + i * 7 + k) }
            let life = 0.5 + 0.35 * r(0)
            let tau = t - t0 - 0.015 * Double(i % 3)
            guard tau >= 0, tau < life else { continue }
            let angle = -.pi / 2 + (r(1) - 0.5) * .pi * 0.5 + side * 0.75
            let v = 26 * s * (0.45 + 0.55 * r(2))
            var vx = cos(angle) * v, vy = sin(angle) * v
            var x = Double(origin.x) + (r(4) - 0.5) * 1.5, y = Double(origin.y)
            var tt = tau
            let disc = vy * vy + 2 * g * (floor - y)
            let hit = (-vy + max(disc, 0).squareRoot()) / g
            if tt > hit && floor > y {
                x += vx * hit; y = floor; tt -= hit
                vy = -0.32 * (vy + g * hit); vx *= 0.5
            }
            x += vx * tt
            y += vy * tt + 0.5 * g * tt * tt
            if y > floor { y = floor }
            let o = 1 - PetCurve.ramp(tau, life * 0.6, life)
            out.particles.append(PetParticle(kind: .crumb, position: CGPoint(x: x, y: y), size: (0.45 + 0.3 * r(6)) * s,
                                             opacity: o, streak: CGVector(dx: -vx / 110, dy: -(vy + g * tt) / 110),
                                             tint: r(3) > 0.5 ? .crumbLight : .crumbWarm))
        }
    }

    // MARK: Sparkles, Zzz, bubbles

    /// A four-point star that twinkles for about 0.6 s, rising a little; in place under Reduce Motion.
    static func sparkle(at t0: Double, origin: CGPoint, seed: UInt64, k: Int, size: Double, scene: PetRigPoser,
                        into out: inout Extras) {
        let life = PetTuning.Particles.sparkleTwinkle + 0.12 * hash(seed, t0, 70 + k)
        let tau = scene.t - t0
        guard tau >= 0, tau < life else { return }
        let u = tau / life
        let still = scene.motion.reduceMotion
        var p = CGPoint(x: Double(origin.x) + (still ? 0 : (hash(seed, t0, 80 + k) - 0.5) * 6 * scene.s * u),
                        y: Double(origin.y) - (still ? 0 : (2 + 7 * PetEase.outCubic(u)) * scene.s))
        // Never cut in half by the strip's top edge: like the Zzz, a star stays below the zone's top, and
        // it slows to a stop there rather than meeting it.
        p.y = belowCeiling(Double(p.y), Double(scene.zone.bounds.minY) + 1 + size)
        let twinkle = pow(sin(.pi * u), 0.7)
        out.particles.append(PetParticle(kind: .sparkle, position: p, size: size * (still ? 1 : twinkle),
                                         opacity: 0.95 * (still ? twinkle : 1), angle: 0.4 * u + hash(seed, t0, 90 + k),
                                         tint: .sparkle))
    }

    /// `y` held under `ceiling` (in window coordinates, so above it is less), easing to a stop on it over
    /// its last `soft` points instead of hitting it: the same value below that, and never above it.
    static func belowCeiling(_ y: Double, _ ceiling: Double, soft: Double = 1.5) -> Double {
        let knee = ceiling + soft
        guard y < knee else { return y }
        return ceiling + soft * exp((y - knee) / soft)
    }

    /// Asleep, the k-th Zzz rises this long after the segment starts: one every `zzzEvery` for the first
    /// minute, then one every `Den.zzzEvery`, as in the den. A sleep lasts hours beside the camera while
    /// the person keeps working, and a particle rising every two seconds all that time would keep pulling
    /// at the eye.
    static func asleepZzz(_ k: Int) -> Double {
        let brisk = asleepBriskZzz
        if k < brisk { return asleepZzzFirst + Double(k) * PetTuning.Particles.zzzEvery }
        return asleepZzz(brisk - 1) + Double(k - brisk + 1) * PetTuning.Den.zzzEvery
    }

    /// The last Zzz to have started by `tau` into the sleep; -1 before the first. A Zzz's own start counts
    /// as started, whatever the last bit of the division says.
    static func asleepZzzIndex(at tau: Double) -> Int {
        guard tau >= asleepZzzFirst else { return -1 }
        let lastBrisk = asleepZzz(asleepBriskZzz - 1)
        if tau < lastBrisk + PetTuning.Den.zzzEvery {
            return min(asleepBriskZzz - 1, Int(floor((tau - asleepZzzFirst) / PetTuning.Particles.zzzEvery + 1e-9)))
        }
        return asleepBriskZzz - 1 + Int(floor((tau - lastBrisk) / PetTuning.Den.zzzEvery + 1e-9))
    }

    static let asleepZzzFirst: Double = 0.3
    /// How many of them come at the brisk rate: those of the first minute.
    static let asleepBriskZzz = Int((60 - asleepZzzFirst) / PetTuning.Particles.zzzEvery) + 1

    /// One Zzz: drawn strokes, rising 10 pt over 2.6 s with ±2 pt of drift; popped if the pet wakes.
    static func zzz(at t0: Double, k: Int, seg: PetSegment, scene: PetRigPoser, into out: inout Extras, until: Double?,
                    den: Bool = false) {
        let life = PetTuning.Particles.zzzLife
        let tau = scene.t - t0
        guard tau >= 0, tau < life, t0 >= seg.start else { return }
        if let until, t0 >= until { return }
        let s = scene.s
        let u = tau / life
        var o = PetCurve.ramp(tau, 0, 0.25) * (1 - PetCurve.ramp(tau, life * 0.6, life))
        var size = (2.4 + 2.0 * PetEase.outCubic(u)) * s
        if let until, scene.t > until {
            // Woken: the letters pop.
            let pop = PetCurve.ramp(scene.t, until, until + 0.14)
            o *= 1 - pop
            size *= 1 + 0.5 * pop
        }
        let anchor = scene.zone.anchor
        var origin = CGPoint(x: Double(anchor.x) + 4 * s, y: Double(anchor.y) - 12 * s)
        if den, case .side(let edge) = scene.zone.den { origin = CGPoint(x: Double(edge) - 4 * s, y: Double(anchor.y) - 12 * s) }
        if den, case .overhead = scene.zone.den { return }
        let still = scene.motion.reduceMotion
        let drift = PetTuning.Particles.zzzDrift * s * sin(2 * .pi * 0.7 * tau + 3 * hash(scene.seed, t0, 1))
        let rise = PetTuning.Particles.zzzRise * s * PetEase.outQuad(u)
        var p = CGPoint(x: Double(origin.x) + (still ? 0 : drift + (den ? -2 * s * u : 1.5 * s * u)),
                        y: Double(origin.y) - (still ? 0 : rise))
        // Never into the black above the zone's top, nor into the notch.
        p.y = max(p.y, Double(scene.zone.bounds.minY) + size / 2 + 0.5)
        out.particles.append(PetParticle(kind: .zzz, position: p, size: size, opacity: 0.9 * o,
                                         angle: -0.18 + 0.12 * sin(2 * .pi * 0.5 * tau), tint: .zzz))
    }

    /// The feast's hiccup: a bubble slips out of the corner of the mouth, floats off past the body, and pops.
    static func bubble(at t0: Double, body: PetBody, scene: PetRigPoser, into out: inout Extras) {
        let tau = scene.t - t0
        guard tau >= 0, tau < 0.5 else { return }
        let s = scene.s
        let m = mouthGuess(scene)
        // Away from the readout, so it never drifts toward a number.
        let side = -scene.foodSide
        let popAt = 0.34
        func path(_ u: Double) -> CGPoint {
            CGPoint(x: Double(m.x) + side * (2.5 + 30 * PetEase.outQuad(u / popAt) * popAt) * s,
                    y: Double(m.y) - (1 + 16 * u) * s)
        }
        if tau < popAt {
            out.particles.append(PetParticle(kind: .bubble, position: path(tau),
                                             size: (0.5 + 1.8 * PetEase.outCubic(tau / popAt)) * s, opacity: 0.85, tint: .bubble))
        } else {
            let c = path(popAt)
            let u = min(1, (tau - popAt) / 0.15)
            for i in 0..<3 {
                let a = 2 * Double.pi * (Double(i) / 3 + 0.2)
                let d = (1.2 + 4 * PetEase.outCubic(u)) * s
                out.particles.append(PetParticle(kind: .crumb, position: CGPoint(x: Double(c.x) + cos(a) * d, y: Double(c.y) + sin(a) * d),
                                                 size: 0.45 * s, opacity: 1 - u, tint: .burst))
            }
        }
    }

    /// The hungry tummy's rumble lines, either side of the belly, for a third of a second.
    static func rumble(at t0: Double, body: PetBody, scene: PetRigPoser, into out: inout Extras) {
        let tau = scene.t - t0
        guard tau >= 0, tau < 0.32 else { return }
        let g = PetBodyGeometry(body)
        let u = tau / 0.32
        for side in [-1.0, 1.0] {
            for k in 0..<2 {
                let base = g.point(u: side * 1.0, v: -0.45)
                let off = ((1.6 + Double(k) * 1.5) * side + 0.35 * sin(2 * .pi * 18 * scene.t + Double(k))) * body.size
                out.particles.append(PetParticle(kind: .rumble, position: CGPoint(x: Double(base.x) + off, y: Double(base.y)),
                                                 size: (1.3 - 0.3 * Double(k)) * body.size,
                                                 opacity: 0.75 * PetCurve.envelope(u, 0, 0.15, 0.6, 1),
                                                 angle: side > 0 ? 0 : .pi, tint: .rumble))
            }
        }
    }

    /// The mote the pounce goes for, floating up just out of reach.
    static func pounceMote(tau: Double, scene: PetRigPoser) -> CGPoint {
        let s = scene.s, side = PetRigIdle.pounceSide(scene)
        let anchor = scene.zone.anchor
        let rise = 6 * s * PetEase.outCubic((tau - 1.0) / 0.8)
        return CGPoint(x: Double(anchor.x) + side * (7 - 2 * tau) * s,
                       y: Double(anchor.y) - 25 * s + 1.5 * s * sin(2.4 * tau) - rise)
    }

    // MARK: The den's door

    /// Below, the den is the notch overhead: once the pet is up inside it, a line of its light shows under
    /// the door.
    static func door(_ seg: PetSegment, end: Double?, scene: PetRigPoser, into out: inout Extras) {
        guard case .overhead(let notch) = scene.zone.den else { return }
        let t = scene.t, tau = t - seg.start
        if let end, t >= end + 0.5 { return }
        var o: Double
        switch seg.behaviour {
        case .enterDen(let retreat):
            o = PetCurve.ramp(tau, retreat ? 0.5 : 1.7, retreat ? 0.9 : 2.1)
        case .hibernating:
            let breath = sin(2 * .pi * tau / PetTuning.Den.glowCycle)
            o = 1 + 0.25 * breath
        case .stirring:
            // The reset passed: the light under the door brightens as the pet stirs behind it, well past
            // the hibernating breath's brightest, so that it reads as waking and not as breathing.
            o = PetCurve.mix(1, 2.2, PetEase.inOutSine(tau / 2.0))
        case .denWait:
            o = 0.6
        case .peek:
            o = 1 - PetCurve.envelope(tau, 0, 0.45, 1.7, 2.15)
        case .leaveDen:
            o = 1 - PetCurve.ramp(tau, 0.1, 0.5)
        default:
            return
        }
        if let end, t > end { o *= 1 - PetCurve.ramp(t, end, end + 0.5) }
        let x = Double(scene.zone.anchor.x)
        let half = 9 * scene.s
        let level = PetTuning.Den.glowMaximum * 1.6
        let light = PetDoorLight(minX: x - half, maxX: x + half, y: Double(notch.maxY), opacity: level * max(0, o))
        // Segments are visited newest first, and the one that just ended fades out over half a second
        // while the next one's light comes up: the brighter of the two is what shows, so the line never
        // drops to dark and jumps back at a change of behaviour.
        if let shown = out.door, shown.opacity >= light.opacity { return }
        out.door = light
    }
}
