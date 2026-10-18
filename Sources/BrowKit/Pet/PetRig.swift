// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// The pose function: a timeline and an instant in, one `PetFrame` out. Pure: the same arguments always
/// give the same frame, bit for bit, whatever was posed before, so any frame of any script can be rendered
/// on its own and in any order. It is a class only so that it can keep a memo of work already done, such as
/// an action's integrated follow-through; a memo may make a pose cheaper, never different.
///
/// A pose is built in layers, in this order:
/// 1. the base: the behaviour's posture, cross-faded from the one before it, and its action keyed by
///    time since its segment started (`PetRigActions`);
/// 2. idle life: breath, sway, drift, blinks, glances and rare idles, from `PetNoise` (`PetRigIdle`);
/// 3. secondary motion: closed-form steady state for the idle cycles, plus each action's transient,
///    integrated from its start (`PetRigSecondary`);
/// 4. gaze: the pointer, the glances, the hop's destination (`PetRigGaze`);
/// 5. the dock: the hop, glide or crossfade between the strip and the panel (`PetLayout`);
/// 6. constraints: area kept, the zone clamp, the notch mask (drawn by `PetCanvas`);
/// 7. particles and the food's light (`PetRigParticles`).
public final class PetRig {
    let memo = PetRigMemo()

    public init() {}

    /// - Parameters:
    ///   - t: on the timeline's clock, `PetTime.mono` in the app.
    ///   - seed: the pet's, `PetBrain.seed`.
    public func pose(_ timeline: PetTimeline, at t: TimeInterval, pointer: PetPointerTrack, dock: PetDockTrack,
                     zones: PetZones, seed: UInt64, motion: PetMotion) -> PetFrame {
        let placement = PetRigDock.placement(at: t, timeline: timeline, dock: dock, zones: zones, motion: motion)
        guard let zone = placement.zone else {
            var empty = PetFrame(pet: PetBody())
            empty.pet.opacity = 0
            empty.notch = zones.notch
            empty.motion = motion
            return empty
        }
        let poser = PetRigPoser(timeline: timeline, t: t, pointer: pointer, zone: zone, seed: seed, motion: motion,
                                memo: memo, flight: placement.flight, flightSource: placement.source,
                                lookAt: placement.lookAt)
        var frame = poser.frame()
        frame.pet.opacity *= placement.opacity
        if let echo = placement.echo {
            // Reduce Motion's crossfade: the pet in the zone it is leaving, fading out.
            let other = PetRigPoser(timeline: timeline, t: t, pointer: pointer, zone: echo.zone, seed: seed,
                                    motion: motion, memo: memo, flight: nil, flightSource: nil, lookAt: nil)
            var pet = other.frame().pet
            pet.opacity *= echo.opacity
            frame.echo = pet
            if pet.opacity > 0.001 {
                frame.canvas = frame.canvas.union(PetRigPoser.canvas(for: pet, extras: []))
            }
        }
        frame.notch = zones.notch
        return frame
    }
}

/// Noise channels of the rig, 0x200 to 0x2FF. One per use, so a new use never shifts an old one.
/// `PetDrift` takes a channel's second octave from the same channel with bit 0x80 set, so the drift
/// channels stay below 0x280.
enum PetRigChannel {
    static let breathPhase = PetNoise.Channel(0x200)
    static let swayPhase = PetNoise.Channel(0x201)
    static let shiftPhase = PetNoise.Channel(0x202)
    static let blinkRate = PetNoise.Channel(0x203)
    static let blinkAt = PetNoise.Channel(0x204)
    static let blinkDouble = PetNoise.Channel(0x205)
    static let glanceAt = PetNoise.Channel(0x207)
    static let glanceTarget = PetNoise.Channel(0x208)
    static let glanceHold = PetNoise.Channel(0x209)
    static let rareAt = PetNoise.Channel(0x20A)
    static let rareKind = PetNoise.Channel(0x20B)
    static let smallAt = PetNoise.Channel(0x20C)
    static let smallKind = PetNoise.Channel(0x20D)
    static let rumbleAt = PetNoise.Channel(0x20E)
    static let bounceAt = PetNoise.Channel(0x20F)
    static let particle = PetNoise.Channel(0x210)
    static let tiltAt = PetNoise.Channel(0x211)
    static let drowsyBlink = PetNoise.Channel(0x212)
    static let side = PetNoise.Channel(0x213)
    // Drift, first octaves (0x240 to 0x27F); their second octaves are 0x2C0 to 0x2FF.
    static let driftTurn = PetNoise.Channel(0x240)
    static let driftNod = PetNoise.Channel(0x241)
    static let driftLookX = PetNoise.Channel(0x242)
    static let driftLookY = PetNoise.Channel(0x243)
    static let driftBrowL = PetNoise.Channel(0x244)
    static let driftBrowR = PetNoise.Channel(0x245)
    static let driftArmL = PetNoise.Channel(0x246)
    static let driftArmR = PetNoise.Channel(0x247)
    static let driftLean = PetNoise.Channel(0x248)
    static let driftBreath = PetNoise.Channel(0x249)
    static let driftMote = PetNoise.Channel(0x24A)
}

/// One pose, in one zone: everything `PetRig.pose` needs while it builds the frame.
struct PetRigPoser {
    let timeline: PetTimeline
    let t: Double
    let pointer: PetPointerTrack
    let zone: PetZone
    let seed: UInt64
    let motion: PetMotion
    let memo: PetRigMemo
    /// The hop or glide in progress, overlaying position, scale and squash.
    let flight: PetLayout.Flight?
    let flightSource: PetRigSource?
    /// Where the eyes go during a flight: its destination.
    let lookAt: CGPoint?

    var s: Double { Double(zone.scale) }

    /// -1 when the food is to the left (beside, the pill), 1 to the right (below, the panel).
    var foodSide: Double { Double(zone.foodSource.x) < Double(zone.anchor.x) ? -1 : 1 }

    /// The index of the segment playing at the instant; nil before the first one.
    var segmentIndex: Int? { PetRigTimeline.index(timeline.segments, at: t) }

    func frame() -> PetFrame {
        let segments = timeline.segments
        let index = segmentIndex
        let beat = PetRigBeat(segments: segments, index: index, t: t)
        var posture = PetRigTimeline.posture(segments, index: index, at: t, scene: self)
        if motion.reduceMotion { posture.breathAmp *= PetTuning.Reduced.breath }

        // 1. The base: the posture, then the behaviour's action.
        var body = posture.body
        body.x = Double(zone.anchor.x)
        body.floorY = Double(zone.anchor.y)
        body.size = s
        body.fullness = PetRigMeter.fullness(timeline.meter, segments: segments, at: t, reduceMotion: motion.reduceMotion)
        body.flash = PetRigMeter.flare(timeline.meter, segments: segments, at: t, reduceMotion: motion.reduceMotion)
        body.wavePhase = t * 2 * .pi * 1.3
        PetRigActions.place(&body, beat: beat, scene: self)
        PetRigActions.apply(&body, beat: beat, scene: self)
        PetRigActions.fadeCut(&body, beat: beat, scene: self)
        PetRigActions.feastBelly(&body, segments: segments, t: t)
        if !motion.reduceMotion { PetRigActions.smear(&body, beat: beat, scene: self) }

        // 2. Idle life.
        PetRigIdle.apply(&body, posture: posture, beat: beat, scene: self)

        // 3. Secondary motion.
        if !motion.reduceMotion {
            PetRigSecondary.apply(&body, posture: posture, beat: beat, scene: self)
        }

        // 4. Gaze.
        PetRigGaze.apply(&body, posture: posture, beat: beat, scene: self)

        // 5. The dock's flight.
        if let flight {
            body.x += flight.feet.x - Double(zone.anchor.x)
            body.floorY = flight.feet.y
            body.size = flight.scale
            body.squash *= flight.squash
            body.smear = flight.smear
            body.smearAngle = flight.smearAngle
            body.armL += 0.8 * flight.airborne
            body.armR += 0.9 * flight.airborne
            body.footL -= 0.8 * flight.airborne
            body.footR -= 0.6 * flight.airborne
        }

        // 6. Constraints.
        if motion.reduceMotion { PetRigConstraints.reduce(&body) }
        let hiding = PetRigGaze.hideStart(scene: self, beat: beat).map { t - $0 < PetRigGaze.hideLength } ?? false
        let den = PetRigActions.denPose(beat) || hiding
        PetRigConstraints.clamp(&body, zone: zone, allowDen: den, flying: flight != nil && !(flight?.landed ?? true))
        if beat.behaviour.isOff { body.opacity = PetRigActions.offOpacity(beat) }
        body.opacity *= PetRigActions.fadeInAfterOff(beat)
        // Over the black of the strip and the panel, drawing the pet fainter is drawing it dimmer.
        body.opacity *= posture.light

        // 7. Particles and the food.
        let extras = PetRigParticles.make(body: body, beat: beat, scene: self)

        var frame = PetFrame(pet: body)
        frame.particles = extras.particles
        frame.bead = extras.bead
        frame.glint = extras.glint
        frame.doorLight = extras.door
        let geometry = PetBodyGeometry(body)
        frame.bodyBox = body.opacity > 0.001 ? geometry.box() : .null
        frame.canvas = Self.canvas(for: body, extras: extras.points)
        if case .side(let edge) = zone.den { frame.denEdge = edge }
        let guards = PetLayout.guards(zone)
        frame.guardMinX = guards.min
        frame.guardMaxX = guards.max
        frame.foodSource = zone.foodSource
        frame.foodDot = zone.foodDot
        frame.motion = motion
        return frame
    }

    /// The pet's own canvas: 64 × 44 pt at scale 1, 128 × 112 at scale 2, centred on the body and grown
    /// to hold the whole halo and whatever particle or bead is out beyond it, so no soft edge is ever cut
    /// by the canvas's own.
    static func canvas(for body: PetBody, extras: [CGRect]) -> CGRect {
        typealias C = PetTuning.Canvas
        let s = body.size
        let k = PetCurve.clamp(s - 1, 0, 1)
        let width = s < 1 ? C.width * s : PetCurve.mix(C.width, C.panelWidth, k)
        let height = s < 1 ? C.height * s : PetCurve.mix(C.height, C.panelHeight, k)
        let bottom = body.floorY + 6 * s
        var rect = CGRect(x: body.x - width / 2, y: bottom - height, width: width, height: height)
        rect = rect.union(PetCanvas.lightBox(PetBodyGeometry(body)))
        for r in extras { rect = rect.union(r) }
        return rect.integral
    }
}

/// The segment playing at an instant, its neighbours and the time into it.
struct PetRigBeat {
    let behaviour: PetBehaviour
    /// When it started; `-infinity` before the first segment.
    let start: Double
    /// When the next segment starts, if one is planned.
    let end: Double?
    let elapsed: Double
    let previous: PetSegment?
    let index: Int?

    init(segments: [PetSegment], index: Int?, t: Double) {
        self.index = index
        if let i = index {
            behaviour = segments[i].behaviour
            start = segments[i].start
            end = i + 1 < segments.count ? segments[i + 1].start : nil
            previous = i > 0 ? segments[i - 1] : nil
        } else {
            // Before anything is planned the pet simply idles, content.
            behaviour = .idle(.content)
            start = -.infinity
            end = segments.first?.start
            previous = nil
        }
        elapsed = start.isFinite ? t - start : .infinity
    }

    /// How long this segment lasts: its planned duration, cut short by the next segment.
    var length: Double? {
        let own = behaviour.duration
        if let end, start.isFinite { return min(own ?? .infinity, end - start) }
        return own
    }
}

extension PetBehaviour {
    var isOff: Bool { if case .off = self { return true }; return false }
}

/// Finding segments and blending their postures.
enum PetRigTimeline {
    /// The last segment that has started by `t`.
    static func index(_ segments: [PetSegment], at t: Double) -> Int? {
        guard let first = segments.first, first.start <= t else { return nil }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The posture at `t`: the segment's own, cross-faded in from wherever the one before it had got to
    /// when it started. A short segment's predecessor may still have been blending, so this looks back
    /// a few segments; past that, a posture has long arrived.
    static func posture(_ segments: [PetSegment], index: Int?, at t: Double, scene: PetRigPoser, depth: Int = 0) -> PetPosture {
        guard let i = index else { return PetRigActions.posture(.idle(.content), elapsed: .infinity, scene: scene) }
        let segment = segments[i]
        let own = PetRigActions.posture(segment.behaviour, elapsed: t - segment.start, scene: scene)
        guard i > 0, depth < 4 else { return own }
        let blend = PetRigActions.blendIn(segment.behaviour, after: segments[i - 1].behaviour)
        let u = (t - segment.start) / blend
        guard u < 1 else { return own }
        let from = posture(segments, index: i - 1, at: segment.start, scene: scene, depth: depth + 1)
        return PetPosture.mixed(from, own, PetEase.smoother(u))
    }
}

/// The hunger meter as the pet's light.
enum PetRigMeter {
    /// What the meter shows at `t`: H + pendingDrop, before the clamp. No key at all reads as a new pet.
    static func value(_ keys: [PetMeterKey], at t: Double) -> Double {
        guard let first = keys.first else { return PetTuning.Hunger.newPet }
        guard first.t <= t else { return first.value }
        var lo = 0, hi = keys.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if keys[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let k = keys[lo]
        return k.value + k.rate * (t - k.t)
    }

    /// How much light the pet holds: 1 fed to the crown at H = 0, a little overfull below it, a low glow
    /// at H = 100. A meal's drop (keyed at its swallow) is eased in as the swallowed light splashes into
    /// the belly, rather than cut; any other jump eases over 0.6 s; Reduce Motion takes it at once.
    static func fullness(_ keys: [PetMeterKey], segments: [PetSegment], at t: Double, reduceMotion: Bool) -> Double {
        var h = value(keys, at: t)
        if !reduceMotion, let jump = lastJump(keys, at: t) {
            let food = jump.delta < 0
            let delay = food ? splash(at: jump.t, segments: segments) : 0
            let duration = food ? 0.3 : 0.6
            let u = (t - jump.t - delay) / duration
            if u < 1 { h -= jump.delta * (1 - (food ? PetEase.outCubic(u) : PetEase.smooth(u))) }
        }
        return light(h)
    }

    /// From a meal's swallow to the moment its light lands in the belly. The meal is the `eat` whose
    /// swallow the key marks; any other drop lands a quarter second in.
    static func splash(at keyTime: Double, segments: [PetSegment]) -> Double {
        for seg in segments.reversed() where seg.start <= keyTime {
            if case .eat(let meal) = seg.behaviour, !meal.reduceMotion,
               abs(seg.start + meal.swallowStart - keyTime) < 1e-6 {
                let m = PetRigActions.timing(meal)
                return m.splash - m.swallowStart
            }
            if keyTime - seg.start > PetRigActions.longestAction { break }
        }
        return 0.25
    }

    /// The satisfied flare as the light lands: it eases in over a quarter of a second, 15
    /// frames at 60 fps, to a soft peak and dies away over half a second, so the pet's light swells rather
    /// than flashes; with the fuller light it keeps and the splash's ring, the region round it brightens
    /// by about a tenth, never more than a couple of percent in one frame. It follows the meter's drop, so
    /// it carries on across the end of the `eat` into whatever follows it.
    static func flare(_ keys: [PetMeterKey], segments: [PetSegment], at t: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, let jump = lastJump(keys, at: t), jump.delta < 0 else { return 0 }
        let start = jump.t + splash(at: jump.t, segments: segments)
        let size = PetCurve.clamp(-jump.delta / 30, 0, 1)
        return (0.05 + 0.05 * size) * PetCurve.envelope(t, start, start + 0.25, start + 0.3, start + 0.8,
                                                       up: PetEase.inOutSine, down: PetEase.inOutSine)
    }

    static func light(_ h: Double) -> Double {
        let hunger = PetCurve.clamp(h, PetTuning.Hunger.minimum, PetTuning.Hunger.maximum)
        return hunger >= 0 ? PetCurve.mix(1.0, 0.12, hunger / 100) : PetCurve.mix(1.0, 1.12, -hunger / 50)
    }

    /// The most recent key within the last 1.4 s whose value is not where the piece before it had got to:
    /// a step, and how big.
    static func lastJump(_ keys: [PetMeterKey], at t: Double) -> (t: Double, delta: Double)? {
        guard keys.count > 1 else { return nil }
        var i = keys.count - 1
        while i > 0 && keys[i].t > t { i -= 1 }
        while i > 0 && t - keys[i].t < 1.4 {
            let before = keys[i - 1]
            let reached = before.value + before.rate * (keys[i].t - before.t)
            let delta = keys[i].value - reached
            if abs(delta) > 1e-9 { return (keys[i].t, delta) }
            i -= 1
        }
        return nil
    }
}

/// The pose's extremes (lean, squash and stretch), the zone it stays inside, and Reduce Motion's limits.
enum PetRigConstraints {
    /// Lean is a shear and tilt a rotation; together they lean the body at most this far.
    static let maxLean = PetTuning.Zone.maxLeanDegrees * .pi / 180

    /// Reduce Motion: no squash or stretch beyond ±2 %, no speed stretch, a still outline.
    static func reduce(_ body: inout PetBody) {
        let r = PetTuning.Reduced.squash
        body.squash = PetCurve.clamp(body.squash, 1 - r, 1 + r)
        body.smear = 1
        body.tremor = 0
        body.lift = 0
        body.lean = PetCurve.clamp(body.lean, -0.04, 0.04)
        body.tilt = PetCurve.clamp(body.tilt, -0.05, 0.05)
        body.spin = 0
    }

    /// Keeps the pose inside the zone: the extremes first, then the box. Reach is given up first (the
    /// body slides back), then lift and stretch, then squash's width; den poses may pass the bounds on
    /// the den's side. Deterministic, at most six passes.
    static func clamp(_ body: inout PetBody, zone: PetZone, allowDen: Bool, flying: Bool) {
        let maxStretch = Double(zone.maxStretch)
        body.squash = PetCurve.clamp(body.squash, PetTuning.Zone.minimumSquash, maxStretch)
        // The speed stretch along the travel, and its squash on contact, keep the hop's limits: the
        // stretch at most 1 + `PetTuning.Hop.speedStretchMaximum`, the squash no deeper than
        // `PetTuning.Zone.minimumSquash`.
        body.smear = PetCurve.clamp(body.smear, PetTuning.Zone.minimumSquash, 1 + PetTuning.Hop.speedStretchMaximum)
        let angle = atan(body.lean) + body.tilt
        if abs(angle) > maxLean {
            let k = maxLean / abs(angle)
            body.lean = tan(atan(body.lean) * k)
            body.tilt *= k
        }
        // In flight the hop's own path keeps the pet inside the opening outline; the zone is where it
        // lands, not where it flies.
        guard !flying else { return }
        let bounds = zone.bounds
        for _ in 0..<6 {
            let box = PetBodyGeometry(body).box()
            var moved = false
            let denRight: Bool, denUp: Bool
            switch zone.den {
            case .side: denRight = allowDen; denUp = false
            case .overhead: denRight = false; denUp = allowDen
            case .none: denRight = false; denUp = false
            }
            if box.minX < bounds.minX - 0.001 {
                body.x += Double(bounds.minX - box.minX)
                moved = true
            }
            if !denRight, box.maxX > bounds.maxX + 0.001 {
                body.x -= Double(box.maxX - bounds.maxX)
                moved = true
            }
            if !denUp, box.minY < bounds.minY - 0.001 {
                let over = Double(bounds.minY - box.minY)
                // Give up lift first, then stretch, then the raised arms' reach.
                let fromLift = min(body.lift, over)
                body.lift -= fromLift
                let rest = over - fromLift
                if rest > 0 {
                    let height = Double(box.height)
                    // The speed stretch, or the bite's squash along its line, makes it taller: ease it, and
                    // give up the stretch in the same pass.
                    if abs(body.smear - 1) > 0.005 { body.smear = 1 + (body.smear - 1) * 0.5 }
                    if body.squash > 1 {
                        body.squash = max(1, body.squash * (1 - rest / max(height, 1)) - 0.002)
                    } else {
                        // Standing at full height and still too tall: it is the raised arms.
                        body.armL = min(body.armL, max(0.4, body.armL - 0.3))
                        body.armR = min(body.armR, max(0.4, body.armR - 0.3))
                    }
                }
                moved = true
            }
            if box.maxY > bounds.maxY + 0.001 {
                body.floorY -= Double(box.maxY - bounds.maxY)
                moved = true
            }
            if box.width > bounds.width && !denRight {
                // Too wide for the zone at all: give up the squash's width, then the cheeks, then the
                // belly's roundness.
                body.squash = min(1, body.squash + 0.05)
                body.cheekPuff *= 0.8
                body.girth = max(1, body.girth - 0.02)
                moved = true
            }
            if !moved { break }
        }
    }
}
