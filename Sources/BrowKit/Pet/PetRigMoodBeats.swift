// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// The two ends of the meter at rest: stuffed and famished. Their postures say the mood at a glance
/// (`PetPosture.stuffed` and `.famished`, and the round belly the meter gives, `PetRigMeter.belly`); these
/// beats make it unmistakable, each rare enough to stay a treat.
///
/// Stuffed: eyes shut in bliss that open now and then; a pat-pat on the round belly; a contented sigh with
/// a puff of breath; a peek at the number and a lick, because there is always room for more; a hiccup and
/// a sheepish grin; and every few minutes the "I'm great": a thumbs-up with a wink and a sparkle.
///
/// Famished: up on its toes toward the number, the near nub reaching for it; a lick; a tummy that grumbles
/// and gets a comforting pat before the eyes go back to the number, hopeful; a reach on tiptoe with grabby
/// little circles; and every few minutes shining eyes turned to the viewer, the nubs at its cheeks:
/// please?
///
/// The beats ride the idle's own schedules (`PetRigIdle.smalls` and `.rares`), standing in for the habits
/// that do not suit the mood (a yawn would read as sleepy, a sigh as sad, a pounce is too much for a round
/// belly), so they come no more often than the habits do; the famished tummy has a schedule of its own,
/// every 25 to 43 s. One gesture plays at a time. Everything keeps to the idle's half a point a frame at
/// 30 fps but the thumbs-up's rise and the hiccup's hop, which the layer draws in the fast class, as it
/// draws the pounce (`PetRigIdle.fastWindow`).
enum PetRigMoodBeats {
    enum Beat: Hashable, CaseIterable {
        /// Stuffed.
        case pat, sigh, roomForMore, okay, hiccup
        /// Famished.
        case reach, please, grumble
    }

    typealias Root = (dx: Double, lift: Double, squash: Double)

    /// The end of the meter an open behaviour is at, if it is at one.
    static func extreme(_ b: PetBehaviour) -> PetMood? {
        switch b {
        case .idle(let m), .settled(let m):
            return m == .stuffed || m == .famished ? m : nil
        default:
            return nil
        }
    }

    /// What a small habit becomes at an end of the meter; nil keeps the habit itself.
    static func small(_ kind: PetRigIdle.Small, mood: PetMood) -> Beat? {
        switch (mood, kind) {
        case (.stuffed, .lick): return .roomForMore
        case (.stuffed, .sigh): return .sigh
        case (.stuffed, .shuffle): return .pat
        case (.famished, .browFlick), (.famished, .squish): return .reach
        default: return nil
        }
    }

    /// What a rare idle becomes at an end of the meter; nil keeps the rare idle itself. Stuffed never
    /// yawns, which would read as sleepy, nor pounces, too round for it: it gives a thumbs-up, or hiccups.
    /// Famished never yawns either, and rather than scratching (its nubs are up and ready) it reaches.
    static func rare(_ kind: PetRigIdle.Rare, mood: PetMood?) -> Beat? {
        switch (mood, kind) {
        case (.stuffed?, .lookAround), (.stuffed?, .yawn): return .okay
        case (.stuffed?, .pounce): return .hiccup
        case (.famished?, .lookAround), (.famished?, .yawn): return .please
        case (.famished?, .scratch): return .reach
        default: return nil
        }
    }

    static func length(_ b: Beat) -> Double {
        switch b {
        case .pat: return 1.5
        case .sigh: return 2.2
        case .roomForMore: return 1.9
        case .okay: return 3.1
        case .hiccup: return 1.3
        case .reach: return 2.5
        case .please: return 3.8
        case .grumble: return 2.5
        }
    }

    /// The longest gesture: how far back a pose looks for the ones still playing.
    static let longest = 3.8

    /// The part of a beat the layer draws in the fast class, times into it: the thumbs-up's arm going up,
    /// the hiccup's hop.
    static func fast(_ b: Beat) -> Range<Double>? {
        switch b {
        case .okay: return 0.28..<1.15
        case .hiccup: return 0.26..<0.72
        default: return nil
        }
    }

    /// The famished tummy's own schedule: a grumble every 25 to 43 s.
    static let grumbles = PetRigSchedule(period: 34, minimumGap: 25, channel: PetRigChannel.grumbleAt)

    /// Coming up from hungry, the tummy says so this long in, or `entranceAfterRumble` after a rumble it has
    /// just had; that is the first grumble, and the schedule's own come no sooner than `entranceClear` after it.
    static let entrance = 0.9
    static let entranceAfterRumble = 8.0
    static let entranceClear = 20.0

    /// The famished tummy's grumbles in `segment`, of those started in (`from`, `to`].
    static func grumbleTimes(in segment: PetSegment, previous: PetSegment?, from: Double, to: Double, seed: UInt64) -> [Double] {
        guard case .idle(.famished) = segment.behaviour else { return [] }
        var first: Double?
        if let previous, case .idle(.hungry) = previous.behaviour {
            let rumbled = PetRigIdle.rumbles.recent(at: segment.start + entrance, lookBack: entranceAfterRumble, seed: seed)
                .filter { $0.at > previous.start + 1.5 }.map(\.at).max()
            first = max(segment.start + entrance, (rumbled ?? -.infinity) + entranceAfterRumble)
        }
        var out: [Double] = []
        if let first, first > from, first <= to { out.append(first) }
        for (_, at) in grumbles.recent(at: to, lookBack: to - from, seed: seed)
        where at > segment.start + 1.5 && !(first.map { at < $0 + entranceClear } ?? false) {
            out.append(at)
        }
        return out.sorted()
    }

    // MARK: - One gesture at a time

    /// One gesture at an end of the meter: a beat, or one of the idle's own habits it keeps.
    struct Gesture: Equatable {
        enum Item: Equatable {
            case beat(Beat)
            /// A small habit kept as it is (a brow flick, a squish), by its index in `PetRigIdle.smalls`.
            case small(Int)
            /// A rare idle kept as it is (a scratch, a mote), by its index in `PetRigIdle.rares`.
            case rare(Int)
        }

        var item: Item
        var at: Double
        var length: Double
        var end: Double { at + length }
    }

    /// The gestures that play at an end of the meter in the open behaviour `segment`, of those started in
    /// the `lookBack` seconds up to `t`, in start order. One at a time: a gesture that would start while
    /// another was due to play is left out whole. The rule looks only at the gestures due just before each
    /// one, so the choice is the same whichever instant asks.
    static func gestures(in segment: PetSegment, previous: PetSegment?, at t: Double, lookBack: Double = longest,
                         seed: UInt64, reduceMotion: Bool) -> [Gesture] {
        guard let mood = extreme(segment.behaviour), !reduceMotion else { return [] }
        let profile = PetRigIdle.profile(segment.behaviour, reduceMotion: reduceMotion)
        // Everything that could still overlap the first of them.
        let from = t - lookBack - longest
        var due: [Gesture] = []
        if profile.small {
            for (k, at) in PetRigIdle.smalls.recent(at: t, lookBack: t - from, seed: seed) where at > segment.start + 1 {
                let kind = PetRigIdle.smallKind(k, seed: seed, behaviour: segment.behaviour)
                if let b = small(kind, mood: mood) {
                    due.append(Gesture(item: .beat(b), at: at, length: length(b)))
                } else {
                    due.append(Gesture(item: .small(k), at: at, length: PetRigIdle.smallLength(kind)))
                }
            }
        }
        if profile.rare {
            for (k, at) in PetRigIdle.rares.recent(at: t, lookBack: t - from, seed: seed) where at > segment.start + 2 {
                let kind = PetRigIdle.rareKind(k, seed: seed)
                if let b = rare(kind, mood: mood) {
                    due.append(Gesture(item: .beat(b), at: at, length: length(b)))
                } else {
                    due.append(Gesture(item: .rare(k), at: at, length: PetRigIdle.length(kind)))
                }
            }
        }
        for at in grumbleTimes(in: segment, previous: previous, from: from, to: t, seed: seed) {
            due.append(Gesture(item: .beat(.grumble), at: at, length: length(.grumble)))
        }
        due.sort { $0.at < $1.at }
        var kept: [Gesture] = []
        for (i, g) in due.enumerated() where g.at > t - lookBack {
            if due[..<i].contains(where: { $0.end > g.at }) { continue }
            kept.append(g)
        }
        return kept
    }

    static func gestures(beat: PetRigBeat, scene: PetRigPoser, lookBack: Double = longest) -> [Gesture] {
        guard let i = beat.index else { return [] }
        let segments = scene.timeline.segments
        return gestures(in: segments[i], previous: i > 0 ? segments[i - 1] : nil, at: scene.t, lookBack: lookBack,
                        seed: scene.seed, reduceMotion: scene.motion.reduceMotion)
    }

    /// The gestures playing at the instant.
    static func playing(beat: PetRigBeat, scene: PetRigPoser) -> [Gesture] {
        gestures(beat: beat, scene: scene).filter { scene.t < $0.end }
    }

    /// The beats playing at the instant, each with its start.
    static func beats(beat: PetRigBeat, scene: PetRigPoser) -> [(beat: Beat, at: Double)] {
        playing(beat: beat, scene: scene).compactMap { g in
            if case .beat(let b) = g.item { return (b, g.at) }
            return nil
        }
    }

    /// Whether the idle's own habit `item` plays: away from the ends of the meter always, at an end only when
    /// no other gesture was due as it started.
    static func keeps(_ item: Gesture.Item, at start: Double, beat: PetRigBeat, scene: PetRigPoser) -> Bool {
        guard extreme(beat.behaviour) != nil, !scene.motion.reduceMotion else { return true }
        return gestures(beat: beat, scene: scene, lookBack: scene.t - start + 0.01).contains { $0.item == item && $0.at == start }
    }

    // MARK: - The eyes

    /// A beat's eyes: open from `open` and shut again from `close`, each on the eyes' own quick clock.
    static func eyes(_ tau: Double, open: Double, close: Double) -> Double {
        let k = PetPosture.eyeClock
        return PetCurve.envelope(tau, open, open + k, close, close + k, up: PetEase.smoother, down: PetEase.smoother)
    }

    /// Open out of bliss, the eyes smile as Full's do.
    static let blissOpenHappy = 0.42

    /// Stuffed, the eyes open from their bliss every 6 to 18 s, for 1.6 to 2.8 s: about a fifth of the time.
    static let blissOpens = PetRigSchedule(period: 12, minimumGap: 6, channel: PetRigChannel.blissAt)

    static func blissHold(_ k: Int, seed: UInt64) -> Double {
        1.6 + 1.2 * PetNoise.hash(seed, PetRigChannel.blissHold, k)
    }

    /// How far the eyes are open out of their bliss at `t`, and the gentler part of it the brows and the
    /// smile follow. A gesture owns the eyes: an opening that would start while one plays is left out, and
    /// one that a gesture shutting the eyes starts during shuts there. A gesture that opens them (the
    /// thumbs-up, room for more, the hiccup, a mote) takes them as they are.
    static func blissOpen(beat: PetRigBeat, scene: PetRigPoser) -> (eyes: Double, face: Double) {
        guard let i = beat.index, case .stuffed? = extreme(beat.behaviour) else { return (0, 0) }
        let segments = scene.timeline.segments
        let segment = segments[i], previous = i > 0 ? segments[i - 1] : nil
        let seed = scene.seed, k = PetPosture.eyeClock
        var eyes = 0.0, face = 0.0
        for (n, at) in blissOpens.recent(at: scene.t, lookBack: 2.8 + 2 * k + 0.5, seed: seed) where at > segment.start + 1.5 {
            let hold = blissHold(n, seed: seed)
            // The gestures due from the opening to its end, decided as they come.
            let due = gestures(in: segment, previous: previous, at: at + hold, lookBack: hold + longest, seed: seed,
                               reduceMotion: scene.motion.reduceMotion)
            if due.contains(where: { $0.at <= at && $0.end > at }) { continue }
            let cut = due.first {
                $0.at > at && $0.at < at + hold && shutsTheEyes($0.item, behaviour: segment.behaviour, seed: seed)
            }?.at
            let close = cut.map { $0 - at } ?? hold
            let tau = scene.t - at
            eyes = max(eyes, self.eyes(tau, open: 0, close: close))
            face = max(face, PetCurve.envelope(tau, 0, 0.35, close, close + 0.45))
        }
        return (eyes, face)
    }

    /// The gestures that shut eyes opened out of bliss: the pat, the sigh, a squish, a scratch.
    static func shutsTheEyes(_ item: Gesture.Item, behaviour: PetBehaviour, seed: UInt64) -> Bool {
        switch item {
        case .beat(let b): return b == .pat || b == .sigh
        case .small(let k): return PetRigIdle.smallKind(k, seed: seed, behaviour: behaviour) == .squish
        case .rare(let k): return PetRigIdle.rareKind(k, seed: seed) == .scratch
        }
    }

    /// Stuffed at rest: eyes shut in bliss that open now and then to look about, the brows lifting a touch.
    static func bliss(_ p: inout PetBody, posture: PetPosture, beat: PetRigBeat, scene: PetRigPoser) {
        guard posture.bliss > 0.001 else { return }
        let open = blissOpen(beat: beat, scene: scene)
        p.happy = PetCurve.mix(p.happy, blissOpenHappy, open.eyes * posture.bliss)
        p.browLiftL += 0.12 * open.face * posture.bliss
        p.browLiftR += 0.12 * open.face * posture.bliss
        p.smile -= 0.08 * open.face * posture.bliss
    }

    // MARK: - The beats

    /// Plays the beats on the body: their movement, then their acting.
    static func apply(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        let dir = scene.foodSide
        for (b, at) in beats(beat: beat, scene: scene) {
            let tau = scene.t - at
            let r = root(b, tau, scale: scene.s, foodSide: dir)
            p.x += r.dx
            p.lift += r.lift
            p.squash += r.squash
            act(b, &p, tau: tau, dir: dir, scene: scene)
        }
    }

    /// The beats' own movement, which also drives their follow-through (`PetRigSource.Kind.beat`).
    static func root(_ b: Beat, _ tau: Double, scale s: Double, foodSide dir: Double) -> Root {
        switch b {
        case .pat:
            var sq = 0.0
            for c in [0.3, 0.8] { sq -= 0.012 * PetCurve.bump(tau, c - 0.04, c + 0.2) }
            return (0, 0, sq)
        case .sigh:
            // In, up and round over 0.7 s; out slowly.
            let inhale = PetCurve.envelope(tau, 0, 0.7, 0.75, 1.8, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (0, 0, 0.035 * inhale)
        case .roomForMore:
            return (0, 0, 0.012 * PetCurve.envelope(tau, 0.1, 0.35, 0.5, 0.9))
        case .okay:
            return (0, 0, 0.02 * PetCurve.envelope(tau, 0.45, 0.75, 1.6, 2.1))
        case .hiccup:
            let hop = PetCurve.bump(tau, 0.3, 0.52)
            let land = PetCurve.envelope(tau, 0.5, 0.54, 0.56, 0.72, up: PetEase.outQuad)
            return (0, 0.9 * s * hop, 0.04 * PetCurve.bump(tau, 0.28, 0.4) - 0.04 * land)
        case .reach:
            let r = reaching(tau)
            return (0, 0.45 * s * r, 0.025 * r)
        case .please:
            return (0, 0, -0.015 * pleading(tau))
        case .grumble:
            let clench = PetCurve.envelope(tau, 0, 0.06, 0.12, 0.26) + 0.8 * PetCurve.envelope(tau, 0.38, 0.44, 0.5, 0.64)
            return (0, 0, -0.02 * clench)
        }
    }

    /// Up on its toes for a reach: up over 0.75 s, held, down by 2.5 s.
    static func reaching(_ tau: Double) -> Double {
        PetCurve.envelope(tau, 0, 0.75, 1.7, 2.5, up: PetEase.inOutSine, down: PetEase.inOutSine)
    }

    /// Please: the nubs come in over 1.1 s, slow and shy, are held, and go back over 1.25 s; the near one, up
    /// and reaching for the number, comes in over 1.25 s.
    static func pleading(_ tau: Double, near: Bool = false) -> Double {
        PetCurve.envelope(tau, 0, near ? 1.25 : 1.1, 2.5, 3.75, up: PetEase.inOutSine, down: PetEase.inOutSine)
    }

    /// A grumble's look down at the tummy: quick, but not so quick that the face, turned to the number,
    /// sweeps across the body faster than the idle's half a point a frame.
    static func lookingDown(_ tau: Double) -> Double {
        PetCurve.envelope(tau, 0.06, 0.34, 0.85, 1.15)
    }

    /// Kicks at the beats' contacts: a pat on the belly sets it wobbling, a hiccup jolts it.
    static func impulses(_ b: Beat) -> [(Double, PetRigSecondary.Spring, Double)] {
        switch b {
        case .pat: return [(0.3, .belly, 1.0), (0.8, .belly, 0.9)]
        case .hiccup: return [(0.54, .jiggle, -0.8), (0.54, .belly, 0.8), (0.3, .brows, 5)]
        case .okay: return [(0.75, .brows, 4)]
        case .grumble: return [(0.03, .belly, 1.2), (0.41, .belly, 0.9), (0.93, .belly, 0.6)]
        case .sigh, .roomForMore, .reach, .please: return []
        }
    }

    static func act(_ b: Beat, _ p: inout PetBody, tau: Double, dir: Double, scene: PetRigPoser) {
        switch b {
        case .pat:
            // The near nub, then the far one, pat the round belly; the eyes stay shut, a little nod.
            for (i, c) in [0.3, 0.8].enumerated() {
                let hit = PetCurve.envelope(tau, c - 0.3, c, c + 0.04, c + 0.4, up: PetEase.inOutSine, down: PetEase.inOutSine)
                if (i == 0) == (dir < 0) { p.armL -= 0.62 * hit } else { p.armR -= 0.62 * hit }
            }
            p.happy = max(p.happy, 0.92 * PetCurve.envelope(tau, 0, 0.15, 1.3, 1.5, up: PetEase.smoother))
            p.smile += 0.12 * PetCurve.envelope(tau, 0.1, 0.3, 1.1, 1.4)
            p.nod += 0.06 * PetCurve.envelope(tau, 0.2, 0.45, 0.9, 1.3)
        case .sigh:
            // In, up and round; out slowly through a little "o", a puff of breath (`particles`); a wider
            // smile after.
            let inhale = PetCurve.envelope(tau, 0, 0.7, 0.75, 1.8, up: PetEase.inOutSine, down: PetEase.inOutSine)
            p.nod += 0.12 * inhale
            p.browLiftL += 0.25 * inhale
            p.browLiftR += 0.25 * inhale
            p.happy = max(p.happy, 0.92 * PetCurve.envelope(tau, 0, 0.15, 2.0, 2.2, up: PetEase.smoother))
            sighOut(&p, tau - 0.78)
            p.smile += 0.18 * PetCurve.envelope(tau, 1.3, 1.6, 1.9, 2.2)
        case .roomForMore:
            // Room for more: the eyes open on the number, the brows go up, a lick, and back to bliss.
            p.happy = PetCurve.mix(p.happy, 0.05, eyes(tau, open: 0, close: 1.45))
            p.eyeSize += 0.08 * PetCurve.envelope(tau, 0.1, 0.3, 0.6, 0.9)
            p.browLiftL += 0.45 * PetCurve.envelope(tau, 0.1, 0.28, 0.55, 0.85)
            p.browLiftR += 0.4 * PetCurve.envelope(tau, 0.12, 0.3, 0.55, 0.85)
            PetRigActions.lick(&p, e: (tau - 0.5) / 2, dir: dir, turn: 0.16)
        case .okay:
            // "I'm great": the eyes open on the viewer, the nub away from the number comes up with a thumb,
            // a wink on that side, a grin and a sparkle at the thumb (`particles`), and back to bliss.
            p.happy = PetCurve.mix(p.happy, 0, eyes(tau, open: 0, close: 2.6))
            p.eyeSize += 0.05 * PetCurve.envelope(tau, 0, 0.25, 2.6, 3.05)
            // Up quick (drawn in the fast class), down slow enough for the idle's 30 fps.
            thumbsUp(&p, tau - 0.3, rise: 0.45, hold: 1.0, lower: 1.2, side: thumbSide(scene))
            p.browLiftL += 0.35 * PetCurve.envelope(tau, 0.3, 0.55, 1.7, 2.1)
            p.browLiftR += 0.35 * PetCurve.envelope(tau, 0.3, 0.55, 1.7, 2.1)
        case .hiccup:
            // A hiccup: a little hop, the eyes pop open, a bubble (`particles`), a sheepish blush, then back
            // to bliss.
            p.happy = PetCurve.mix(p.happy, 0, eyes(tau, open: 0.27, close: 0.95))
            let pop = PetCurve.envelope(tau, 0.28, 0.33, 0.55, 0.8)
            p.eyeSize += 0.14 * pop
            p.browLiftL += 0.7 * pop
            p.browLiftR += 0.7 * pop
            p.mouthOpen = max(p.mouthOpen, 0.2 * PetCurve.bump(tau, 0.28, 0.46))
            p.mouthWide = PetCurve.mix(p.mouthWide, 0.45, PetCurve.bump(tau, 0.28, 0.46))
            let sheepish = PetCurve.envelope(tau, 0.65, 0.85, 1.0, 1.3)
            p.blush += 0.35 * sheepish
            p.smile += 0.15 * sheepish
        case .reach:
            // Up on its toes, both nubs out at the number, the near one making grabby little circles: is it
            // coming?
            let r = reaching(tau)
            let grab = 0.1 * sin(2 * .pi * 2.5 * (tau - 0.75)) * PetCurve.envelope(tau, 0.75, 0.9, 1.55, 1.7)
            if dir < 0 { p.armL += 1.0 * r + grab; p.armR += 0.5 * r } else { p.armR += 1.0 * r + grab; p.armL += 0.5 * r }
            p.lean += dir * 0.03 * r
            p.eyeSize += 0.05 * r
            p.mouthOpen = max(p.mouthOpen, 0.2 * r)
        case .please:
            // Please? The shining eyes turn to the viewer (`viewer`), the head tilts away from the readout,
            // both nubs come in to the cheeks, two quick happy squints, a hopeful smile. Never a pout, never
            // a tear.
            let on = pleading(tau)
            p.tilt += -dir * 0.1 * on
            // The near nub, up and reaching, has further to come: it takes a little longer, so it never
            // hurries past the idle's half a point a frame.
            let near = pleading(tau, near: true)
            p.armL = PetCurve.mix(p.armL, -1.9, dir < 0 ? near : on)
            p.armR = PetCurve.mix(p.armR, -1.9, dir < 0 ? on : near)
            p.eyeSize += 0.1 * on
            p.shine = max(p.shine, on)
            p.smile += 0.15 * on
            p.blush += 0.2 * on
            for c in [1.45, 1.78] {
                p.happy = max(p.happy, PetCurve.envelope(tau, c, c + 0.07, c + 0.12, c + 0.24))
            }
        case .grumble:
            // The tummy grumbles twice: it looks down at it, surprised, pats it with both nubs, and goes back
            // to the number with a hopeful smile and a lick. The outline's shiver stays at the idle's half a
            // point a frame; the belly's wobble does the rest.
            p.tremor += 0.82 * PetCurve.ring(tau, 0, frequency: 15, decay: 0.1)
                + 0.7 * PetCurve.ring(tau, 0.38, frequency: 15, decay: 0.09)
            let down = lookingDown(tau)
            p.lookY -= 0.6 * down
            p.nod -= 0.3 * down
            p.eyeSize += 0.1 * PetCurve.envelope(tau, 0.05, 0.15, 0.6, 0.9)
            let o = PetCurve.envelope(tau, 0.06, 0.16, 0.6, 0.9)
            p.mouthOpen = max(p.mouthOpen, 0.24 * o)
            p.mouthWide = PetCurve.mix(p.mouthWide, 0.45, o)
            let pat = PetCurve.envelope(tau, 0.55, 0.9, 0.95, 1.3, up: PetEase.inOutSine, down: PetEase.inOutSine)
            p.armL -= 0.75 * pat
            p.armR -= 0.75 * pat
            // The idle's lick, at its half pace (`PetRigIdle.smallIdle`).
            PetRigActions.lick(&p, e: (tau - 1.25) / 2, dir: dir, turn: 0.15)
            p.smile += 0.15 * PetCurve.envelope(tau, 1.25, 1.45, 2.2, 2.5)
        }
    }

    /// A contented breath out through a little "o", `tau` from its start: 0.67 s.
    static func sighOut(_ p: inout PetBody, _ tau: Double) {
        let blow = PetCurve.envelope(tau, 0, 0.14, 0.37, 0.67)
        guard blow > 0 else { return }
        p.mouthOpen = max(p.mouthOpen, 0.13 * blow)
        p.mouthWide = PetCurve.mix(p.mouthWide, 0.4, blow)
    }

    /// The arm that gives the thumbs-up: in the strip the one away from the readout, so it never points at
    /// a number; in the panel the one toward its words.
    static func thumbSide(_ scene: PetRigPoser) -> Double {
        scene.zone.kind == .panel ? 1 : -scene.foodSide
    }

    /// A thumbs-up with the arm on `side`: up in `rise` with a little overshoot, held with a pump and a wink
    /// on that side, down in `lower`; the thumb grows in over the last of the rise and is there only while
    /// the arm is up. `tau` is from the start of the rise.
    static func thumbsUp(_ p: inout PetBody, _ tau: Double, rise: Double, hold: Double, lower: Double, side: Double) {
        guard tau > 0, tau < rise + hold + lower else { return }
        let up = PetCurve.envelope(tau, 0, rise, rise + hold, rise + hold + lower, up: { PetEase.outBack($0, 1.1) },
                                   down: PetEase.inOutSine)
        let pump = 0.14 * PetCurve.bump(tau, rise + 0.12, rise + 0.42)
        // Out to the side and a little up, level enough that the thumb on its end stands straight up.
        let raise = 1.55 * up + pump
        let thumb = PetCurve.envelope(tau, rise * 0.55, rise, rise + hold, rise + hold + 0.15)
        // The wink shuts within two frames at 30 fps and opens a little slower.
        let wink = PetCurve.envelope(tau, rise + 0.1, rise + 0.16, rise + hold - 0.15, rise + hold - 0.05,
                                     up: PetEase.smoother, down: PetEase.smoother)
        if side < 0 {
            p.armL += raise
            p.thumbL = max(p.thumbL, thumb)
            p.winkL = max(p.winkL, wink)
        } else {
            p.armR += raise
            p.thumbR = max(p.thumbR, thumb)
            p.winkR = max(p.winkR, wink)
        }
        let grin = PetCurve.envelope(tau, rise * 0.5, rise, rise + hold, rise + hold + lower * 0.8)
        p.smile += 0.25 * grin
        p.mouthOpen = max(p.mouthOpen, 0.13 * grin)
        p.blush += 0.15 * grin
        p.tilt += side * 0.05 * grin
    }

    // MARK: - Gaze, particles, follow-through

    /// How much the beats take the eyes off the number: to the viewer, straight out of the screen (the
    /// thumbs-up, please), or down at the tummy (a grumble).
    static func gaze(beat: PetRigBeat, scene: PetRigPoser) -> (viewer: Double, away: Double) {
        var viewer = 0.0, away = 0.0
        for (b, at) in beats(beat: beat, scene: scene) {
            let tau = scene.t - at
            switch b {
            case .okay: viewer = max(viewer, PetCurve.envelope(tau, 0, 0.25, 2.6, 3.05))
            case .please: viewer = max(viewer, pleading(tau))
            case .grumble: away = max(away, lookingDown(tau))
            default: break
            }
        }
        return (viewer, away)
    }

    /// Whether a beat owns the eyes at a blink starting at `start`: the thumbs-up, please and the grumble keep
    /// them wide (or winking) from a little before they start to their end, and the blink is left out whole.
    /// Decided from the gestures due by then, so a blink is kept or left out the same at every instant.
    static func holdsTheBlink(at start: Double, beat: PetRigBeat, scene: PetRigPoser) -> Bool {
        guard let i = beat.index, extreme(beat.behaviour) != nil else { return false }
        let segments = scene.timeline.segments
        let due = gestures(in: segments[i], previous: i > 0 ? segments[i - 1] : nil, at: start + 0.4, lookBack: longest + 0.8,
                           seed: scene.seed, reduceMotion: scene.motion.reduceMotion)
        return due.contains { g in
            guard case .beat(let b) = g.item, b == .okay || b == .please || b == .grumble else { return false }
            return start > g.at - 0.4 && start < g.end
        }
    }

    /// The beats' bits of light: a sparkle at the thumb, the sigh's puff, the hiccup's bubble, the grumble's
    /// lines.
    static func particles(body: PetBody, beat: PetRigBeat, scene: PetRigPoser, into out: inout PetRigParticles.Extras) {
        for (b, at) in beats(beat: beat, scene: scene) {
            switch b {
            case .okay:
                PetRigParticles.thumbSparkle(at: at + 0.92, body: body, side: thumbSide(scene), scene: scene, into: &out)
            case .sigh:
                PetRigParticles.puff(at: at + 0.9, scene: scene, into: &out)
            case .hiccup:
                PetRigParticles.bubble(at: at + 0.33, body: body, scene: scene, into: &out)
            case .grumble:
                PetRigParticles.rumble(at: at, body: body, scene: scene, into: &out, strong: true)
                PetRigParticles.rumble(at: at + 0.38, body: body, scene: scene, into: &out, strong: true)
            case .pat, .roomForMore, .reach, .please:
                break
            }
        }
    }

    /// The beats' follow-through, as sources of transient motion: each until its tail has rung out.
    static func sources(beat: PetRigBeat, scene: PetRigPoser, posture: PetPosture) -> [PetRigSource] {
        gestures(beat: beat, scene: scene, lookBack: longest + PetRigSecondary.tail).compactMap { g in
            guard case .beat(let b) = g.item else { return nil }
            return PetRigSource(kind: .beat(b), start: g.at, scale: scene.s, foodSide: scene.foodSide, jellyHz: posture.jellyHz,
                                jellyZeta: posture.jellyZeta)
        }
    }
}
