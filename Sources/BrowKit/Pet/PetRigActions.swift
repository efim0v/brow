// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// The room an action has in its zone: what its movement depends on besides time.
struct PetRigRoom: Hashable {
    var scale: Double
    /// -1 the food is to the left, 1 to the right.
    var foodSide: Double
    /// How far the lunge can carry the body toward the food before its box meets the zone's edge.
    var reach: Double
    /// Beside, from the anchor to the notch's edge (the den is to the right); below, from the feet up to
    /// the notch's bottom (the den is overhead). 0 where there is no den.
    var denX: Double
    var denY: Double

    init(scale: Double, foodSide: Double, reach: Double, denX: Double, denY: Double) {
        self.scale = scale
        self.foodSide = foodSide
        self.reach = reach
        self.denX = denX
        self.denY = denY
    }

    init(zone: PetZone) {
        let s = Double(zone.scale)
        let anchor = zone.anchor
        let side: Double = Double(zone.foodSource.x) < Double(anchor.x) ? -1 : 1
        let edge = side < 0 ? Double(zone.bounds.minX) : Double(zone.bounds.maxX)
        // The body's half box at rest (arms included) and the lunge's speed stretch.
        let half = 13.8 * s + 1.5 * s
        let reach = max(0, abs(edge - Double(anchor.x)) - half)
        var denX = 0.0, denY = 0.0
        switch zone.den {
        case .side(let edgeX): denX = Double(edgeX - anchor.x)
        case .overhead(let notch): denY = Double(anchor.y - notch.maxY)
        case .none: break
        }
        self.init(scale: s, foodSide: side, reach: reach, denX: denX, denY: denY)
    }

    var hasSideDen: Bool { denX > 0 }
    var hasOverheadDen: Bool { denY > 0 }

    /// Beside: where the body sits hibernating, three quarters of it past the edge, so that at least 70 %
    /// of it is out of sight in the den.
    var hibernatingX: Double { denX + 0.4 * 13.8 * scale }
    /// Beside: out of sight in the den, between peeks.
    var hiddenX: Double { denX + 16 * scale }
    /// Beside: out just far enough for one eye.
    var peekX: Double { denX + 3.5 * scale }
    /// Below: lifted all the way into the notch.
    var hiddenLift: Double { denY + 23 * scale }
    /// Below: hanging just low enough for the eyes to show under the notch's edge, the rest of the body
    /// still up inside it.
    var peekLift: Double { max(0, denY - 10 * scale - 2) }
}

/// What each behaviour does: its posture, its movement and its acting, keyed by the time since its
/// segment started. The movement (`root`) is also what drives its secondary motion, so the follow-through
/// always matches what is seen.
enum PetRigActions {
    /// No action is longer than `leaveDen` (3.7 s) or a feast's satisfied (4.0 s).
    static let longestAction: Double = 4.2

    typealias M = PetTuning.Meal
    typealias B = PetTuning.Behaviour

    // MARK: - Postures

    /// - Parameter start: when the segment started, for the behaviours whose look depends on the meal
    ///   before them or the mood they rest in (a lick, a boop, the satisfactions); nil: the plain look.
    static func posture(_ b: PetBehaviour, elapsed e: Double, scene: PetRigPoser, start: Double? = nil) -> PetPosture {
        let room = PetRigRoom(zone: scene.zone)
        switch b {
        case .intro: return keyed(e, [(0, .curious, 0.2), (1.9, .content, 0.6), (2.8, .happy, 0.3), (3.3, .content, 0.4)])
        // Looking at a grey dot, stuffed keeps its eyes open, so the look shows.
        case .unsureIdle(.stuffed): return .stuffedOpen
        case .idle(let m), .settled(let m), .unsureIdle(let m): return .mood(m)
        case .perk, .eager: return .eager
        case .eat(let meal):
            let snap = meal.reduceMotion ? PetTuning.Reduced.mealFade : timing(meal).snap
            return keyed(e, [(0, relish(meal.mood), 0.1), (snap, .munch, 0.12)])
        case .satisfied(.meal): return .satisfied
        case .satisfied(.brim): return .stuffed
        case .satisfied(.grateful):
            // Eyes shut and hugging itself, then from 1.75 s the face of the mood the meal left it in: the eyes
            // open, shining, on the number.
            let after = start.flatMap { meal(before: $0, scene: scene) }.map { moodAfter($0.meal, start: $0.start, scene: scene) }
            return keyed(e, [(0, .grateful, 0.25), (1.75, .mood(after ?? .hungry), 0.45)])
        case .satisfied(.feast):
            if let start, stuffedAfter(start, scene: scene) { return .stuffed }
            return keyed(e, [(0, .feasted, 0.3), (2.6, .satisfied, 1.0)])
        case .satisfied(.lick):
            // After a nibble on a full belly it keeps the stuffed face; elsewhere content's, as ever.
            if let start, let m = meal(before: start, scene: scene), moodAfter(m.meal, start: m.start, scene: scene) == .stuffed {
                return .stuffed
            }
            return .content
        case .boop:
            if let start, let m = restingMood(before: start, scene: scene), m == .stuffed || m == .famished { return .mood(m) }
            return .content
        case .celebrate, .freshWindow: return .happy
        case .fallAsleep: return keyed(e, [(0, .heavy, 0.25), (B.fallAsleepYawn, .drowsy, 0.5),
                                           (B.fallAsleepYawn + B.fallAsleepDroop, .asleep, B.fallAsleepCurl)])
        case .asleep, .rollOver: return .asleep
        case .drowsy: return .drowsy
        case .wake: return keyed(e, [(0, .drowsy, 0.1), (0.35, .content, 0.5), (B.wakeStir + B.wakeStretch, .happy, 0.3)])
        case .enterDen(let retreat):
            if retreat { return .content }
            return keyed(e, [(0, .curious, 0.3), (0.5, .drowsy, 0.8), (B.retreat, curled(room), 1.2)])
        case .hibernating: return curled(room)
        case .stirring: return stirring(room)
        case .leaveDen(let stretch):
            if !stretch { return keyed(e, [(0, .curious, 0.2), (0.8, .content, 0.4)]) }
            return keyed(e, [(0, curled(room), 0.1), (0.05, .drowsy, 0.5), (0.8, .content, 0.4),
                             (B.leaveDenPeek + B.leaveDenOut + B.leaveDenStretch, .happy, 0.3)])
        case .denWait: return room.hasSideDen || room.hasOverheadDen ? .content : dim(.content)
        case .peek: return room.hasSideDen || room.hasOverheadDen ? .curious : dim(.curious)
        case .dozeIn: return keyed(e, [(0, .content, 0.1), (0.2, .dozing, 1.7)])
        case .doze: return .dozing
        case .welcomeBack: return keyed(e, [(0, .dozing, 0.1), (0.25, .content, 0.5)])
        case .off: return .content
        }
    }

    /// Hibernating on the pill or in the panel, where there is no den: curled into a ball, the glow at
    /// 30 %. A rounder, smaller ball than the 5-hour sleep's low loaf, with its own light turned down and
    /// no Zzz, so the weekly limit and the 5-hour one never look the same at a glance.
    static func curled(_ room: PetRigRoom) -> PetPosture {
        guard !room.hasSideDen, !room.hasOverheadDen else { return .hibernating }
        var p = PetPosture.hibernating
        p.body.glow = PetTuning.Den.pillGlow
        p.body.curl = 0.55
        p.body.squash = 0.95
        p.body.girth = 0.9
        p.light = 0.75
        return p
    }

    /// The weekly reset passed and the pet stirs in the den: still curled where it hibernated, the light
    /// brightening, one eye barely open at the edge. All of it is posture, which cross-fades, and none of
    /// it is movement or acting, which an open behaviour would drop in one frame when `leaveDen` cuts it:
    /// so `leaveDen` starts exactly where this leaves off. Beside, the face turns toward the notch's edge
    /// so that the one eye clears it; below, the pet is up inside the notch and only the light under the
    /// door shows it; on the pill, the ball's near eye opens.
    static func stirring(_ room: PetRigRoom) -> PetPosture {
        var p = curled(room)
        p.body.glow = room.hasSideDen || room.hasOverheadDen ? 0.55 : 0.5
        p.light = 1
        p.body.curl -= 0.1
        p.body.lidL = 0.2
        p.body.browLiftL = -0.15
        p.body.smile = 0.28
        if room.hasSideDen {
            p.body.turn = -0.6
            p.body.lookX = -0.5
        } else {
            p.body.lookX = 0.4 * room.foodSide
        }
        return p
    }

    /// Waiting with no account on the pill: sitting curled and dim.
    static func dim(_ base: PetPosture) -> PetPosture {
        var p = PetPosture.mixed(base, .hibernating, 0.7)
        p.body.lidL = 0.7
        p.body.lidR = 0.7
        p.body.glow = PetTuning.Den.pillGlow
        p.lookAtFood = 0
        return p
    }

    static func keyed(_ e: Double, _ keys: [(Double, PetPosture, Double)]) -> PetPosture {
        var p = keys[0].1
        for k in keys.dropFirst() where e > k.0 {
            p = PetPosture.blended(p, k.1, elapsed: e - k.0, over: k.2)
        }
        return p
    }

    /// The wind-up of a meal: eager's, but a stuffed pet stays round and low, its eyes popping open in
    /// delight, and a famished one's eyes shine.
    static func relish(_ mood: PetMood) -> PetPosture {
        switch mood {
        case .stuffed: return relishStuffed
        case .famished: return relishFamished
        default: return .eager
        }
    }

    static let relishFamished: PetPosture = {
        var p = PetPosture.mixed(.eager, .famished, 0.5)
        // The lunge leans, reaches and turns to the food on its own.
        p.foodLean = 0
        p.foodStep = 0
        p.foodArm = 0
        p.foodFace = 0
        p.body.shine = 1
        p.body.eyeSize = 1.3
        return p
    }()

    static let relishStuffed: PetPosture = {
        var p = PetPosture.mixed(.eager, .stuffed, 0.45)
        p.body.happy = 0
        p.bliss = 0
        return p
    }()

    /// The meal a satisfaction follows: the last `eat` that started before `start`.
    static func meal(before start: Double, scene: PetRigPoser) -> (meal: PetMeal, start: Double)? {
        for seg in scene.timeline.segments.reversed() where seg.start < start - 1e-9 {
            if case .eat(let meal) = seg.behaviour { return (meal, seg.start) }
            if start - seg.start > 8 { break }
        }
        return nil
    }

    /// The mood a meal leaves the pet in: the meter once its drop has landed, judged from the mood it was
    /// eaten in, as the brain judges it.
    static func moodAfter(_ meal: PetMeal, start: Double, scene: PetRigPoser) -> PetMood {
        PetHunger.mood(PetRigMeter.value(scene.timeline.meter, at: start + meal.duration + 1e-6), from: meal.mood)
    }

    /// Whether the meal before a satisfaction starting at `start` left the pet stuffed.
    static func stuffedAfter(_ start: Double, scene: PetRigPoser) -> Bool {
        guard let m = meal(before: start, scene: scene) else { return false }
        return moodAfter(m.meal, start: m.start, scene: scene) == .stuffed
    }

    /// The mood it rests in around `start`: that of the last open behaviour before it, or, when a meal came
    /// after that one, the mood the meal left it in. A boop during the satisfaction after a meal that made it
    /// stuffed is a stuffed pet's, and one after a famished pet's meal no longer a famished one's.
    static func restingMood(before start: Double, scene: PetRigPoser) -> PetMood? {
        for seg in scene.timeline.segments.reversed() where seg.start < start - 1e-9 {
            switch seg.behaviour {
            case .idle(let m), .settled(let m), .unsureIdle(let m): return m
            case .eat(let meal): return moodAfter(meal, start: seg.start, scene: scene)
            default: if start - seg.start > 30 { return nil }
            }
        }
        return nil
    }

    /// How long a behaviour takes to settle into its posture from the one before it.
    static func blendIn(_ b: PetBehaviour, after previous: PetBehaviour) -> Double {
        switch b {
        case .off: return 1e9               // turned off, it holds whatever it was doing and fades
        case .idle(let m), .settled(let m), .unsureIdle(let m):
            // Out of stuffed the rest gives way slowly, as the belly it rests on goes down; the eyes open
            // on their own quick clock (`PetPosture.blended`).
            switch previous {
            case .idle(.stuffed), .settled(.stuffed): return m == .stuffed ? 0.6 : 2.0
            default: return 0.6
            }
        case .perk: return 0.12
        case .eager: return 0.25
        case .eat: return 0.12
        case .satisfied(.lick): return 0.2
        case .satisfied: return 0.25
        case .boop: return 0.08
        case .celebrate, .freshWindow: return 0.2
        case .fallAsleep: return 0.3
        case .asleep: return 0.6
        case .drowsy: return 1.8
        case .wake: return 0.5
        case .welcomeBack: return 0.12
        case .rollOver: return 1.0
        case .enterDen, .leaveDen: return 0.3
        case .hibernating: return 0.8
        case .stirring: return 2.0
        case .denWait: return 0.4
        case .peek: return 0.2
        case .dozeIn: return 0.3
        case .doze: return 0.5
        case .intro: return 0.2
        }
    }

    /// A streak's twirl, times into the celebration: its crouch starts off the first hop's landing, and
    /// all of it, crouch to landing squash, lies inside `PetTuning.Behaviour.streakTwirl`, the part drawn
    /// in the fast class.
    struct Twirl {
        let crouch = 1.0
        let takeoff = 1.14
        let air = 0.34
        var land: Double { takeoff + air }
    }

    static let twirl = Twirl()

    // MARK: - The meal's clock

    /// The meal's beats, from `PetTuning.Meal`: the rig hits them to the frame.
    struct MealTiming {
        var anticipation: Double, lunge: Double, hold: Double, recoil: Double, chew: Double, swallow: Double
        var chews: Int
        var full: Bool
        var feast: Bool
        /// The mood it was planned in: stuffed eats lazily.
        var mood: PetMood = .content
        var snap: Double { anticipation + lunge }
        var recoilStart: Double { snap + hold }
        var chewStart: Double { recoilStart + recoil }
        var swallowStart: Double { chewStart + Double(chews) * chew }
        var end: Double { swallowStart + swallow }
        /// The swallowed light lands in the belly this far into the swallow.
        var splash: Double { swallowStart + (feast ? 0.5 : swallow * 0.72) }
    }

    static func timing(_ meal: PetMeal) -> MealTiming {
        if meal.size == .full {
            return MealTiming(anticipation: M.fullAnticipation, lunge: M.fullLunge, hold: M.fullHold, recoil: M.fullRecoil,
                              chew: M.fullChew, swallow: M.fullSwallow + (meal.feast ? M.feastSwallowExtra : 0),
                              chews: meal.chews, full: true, feast: meal.feast, mood: meal.mood)
        }
        return MealTiming(anticipation: M.nibbleAnticipation, lunge: M.nibbleLunge, hold: M.nibbleHold,
                          recoil: M.nibbleRecoil, chew: M.nibbleChew, swallow: M.nibbleSwallow, chews: meal.chews,
                          full: false, feast: false, mood: meal.mood)
    }

    // MARK: - Movement

    /// The behaviour's own movement at `e`: the root's offset across (points, + right), its lift, and
    /// its squash beyond 1. The pose adds exactly this, and the transients are driven by exactly this.
    static func root(_ b: PetBehaviour, elapsed e: Double, room: PetRigRoom) -> (dx: Double, lift: Double, squash: Double) {
        let s = room.scale
        switch b {
        case .eat(let meal):
            return meal.reduceMotion ? (0, 0, 0) : eatRoot(timing(meal), e, room)
        case .perk(let kind):
            let pop = PetCurve.envelope(e, 0.04, 0.2, 0.24, kind == .prompt ? 0.46 : 0.7, up: { PetEase.outBack($0) })
            return (0, 0.4 * s * PetCurve.bump(e, 0.06, 0.36), 0.05 * pop)
        case .satisfied(.meal):
            let sigh = PetCurve.envelope(e, 0.2, 0.6, 0.62, 1.05, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (0, 0, 0.05 * sigh - 0.02 * (PetCurve.bump(e, 1.1, 1.36) + PetCurve.bump(e, 1.6, 1.86)))
        case .satisfied(.grateful):
            // Hugging itself it squeezes a little; a small happy bounce in the middle of the hug.
            let hug = PetCurve.envelope(e, 0.12, 0.45, 1.45, 1.8, up: PetEase.inOutSine, down: PetEase.inOutSine)
            let bounce = PetCurve.bump(e, 0.95, 1.3)
            let land = PetCurve.envelope(e, 1.27, 1.31, 1.33, 1.5, up: PetEase.outQuad)
            return (0, 1.1 * s * bounce, -0.035 * hug - 0.03 * land)
        case .satisfied(.brim):
            // The pats dip the round belly; the contented sigh at the end lifts it.
            var dip = 0.0
            for c in [0.35, 0.75] { dip -= 0.015 * PetCurve.bump(e, c - 0.03, c + 0.17) }
            let sigh = PetCurve.envelope(e, 2.2, 2.5, 2.55, 3.0, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (0, 0, dip + 0.035 * sigh)
        case .satisfied(.feast):
            let hic = PetCurve.envelope(e, 1.4, 1.48, 1.5, 1.66, up: PetEase.outQuad, down: PetEase.inOutSine)
            let sigh = PetCurve.envelope(e, 2.6, 3.0, 3.05, 3.5, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (0, 0.9 * s * hic, 0.04 * PetCurve.bump(e, 1.4, 1.6) + 0.04 * sigh)
        case .satisfied(.lick):
            return (0, 0, -0.015 * PetCurve.bump(e, 0.32, 0.46))
        case .boop(let giggle):
            let squish = -0.14 * PetCurve.envelope(e, 0, 0.05, 0.08, 0.3, up: PetEase.outQuad, down: PetEase.inOutSine)
                + 0.05 * PetCurve.bump(e, 0.24, 0.5)
            guard giggle else { return (0, 0, squish) }
            var lift = 0.0
            for c in [0.12, 0.42, 0.72] { lift += 1.1 * s * PetCurve.bump(e, c, c + 0.2) }
            return (0, lift, squish - 0.03 * sin(2 * .pi * 7 * e) * PetCurve.envelope(e, 0.1, 0.2, 0.9, 1.1))
        case .celebrate(.streak):
            // A happy hop, then off its landing a higher one with a twirl (`twirl`), in the fast class.
            return hopRoot(e, at: 0.2, crouch: 0.26, air: 0.5, height: 3.0 * s, dx: 0, k: 0.6)
                + hopRoot(e, at: twirl.crouch, crouch: twirl.takeoff - twirl.crouch, air: twirl.air,
                          height: 3.5 * s, dx: 0, k: 0.8)
        case .celebrate(.goodWeek):
            var drum = 0.0
            for c in [0.3, 0.6, 0.9, 1.2] { drum -= 0.025 * PetCurve.bump(e, c - 0.08, c + 0.16) }
            return hopRoot(e, at: 1.5, crouch: 0.24, air: 0.48, height: 2.7 * s, dx: 0, k: 0.6) + (0, 0, drum)
        case .freshWindow:
            return hopRoot(e, at: 0.24, crouch: 0.18, air: 0.4, height: 2.1 * s, dx: 0, k: 0.6)
        case .fallAsleep:
            let inhale = PetCurve.envelope(e, 0, 0.35, 0.6, 0.85, up: PetEase.inOutSine, down: PetEase.inOutSine)
            let sink = PetCurve.ramp(e, 1.0, 1.8) * (1 - PetCurve.ramp(e, 1.8, 2.6))
            return (0, 0, 0.08 * inhale - 0.04 * sink)
        case .wake:
            return stretchRoot(e - B.wakeStir, s: s) + (0, 0, 0.02 * sin(2 * .pi * 2 * e) * PetCurve.envelope(e, 0.1, 0.2, 0.4, 0.55))
        case .rollOver:
            let roll = PetCurve.envelope(e, 0, 0.45, 0.5, 1.0, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (room.foodSide * -0.8 * s * roll, 0, -0.02 * roll)
        case .enterDen(let retreat):
            return denRoot(enter: true, retreat: retreat, e, room)
        case .leaveDen(let stretch):
            var r = denRoot(enter: false, retreat: !stretch, e, room)
            if stretch { r = r + stretchRoot(e - B.leaveDenPeek - B.leaveDenOut, s: s) }
            return r
        case .peek:
            return peekRoot(e, room)
        case .intro(let noAccounts):
            return introRoot(e, noAccounts: noAccounts, room)
        case .dozeIn:
            return (0, 0, -0.03 * PetCurve.ramp(e, 0.3, 1.8))
        case .doze:
            return (0, 0, -0.03)
        case .welcomeBack:
            let stretch = PetCurve.envelope(e, 0.35, 0.75, 0.95, 1.35, up: PetEase.outCubic, down: PetEase.inOutSine)
            return (0, 0, -0.03 * (1 - PetCurve.ramp(e, 0, 0.3)) + 0.09 * stretch - 0.03 * PetCurve.bump(e, 1.3, 1.6))
        case .drowsy:
            let yawn = PetCurve.envelope(e, 0.9, 1.55, 2.0, 2.55, up: PetEase.inOutSine, down: PetEase.inOutSine)
            return (0, 0, 0.03 * yawn)
        case .idle, .settled, .eager, .asleep, .unsureIdle, .denWait, .hibernating, .stirring, .off:
            // Where the open behaviours sit is `restOffset`'s; they have no movement of their own.
            return (0, 0, 0)
        }
    }

    /// The meal: rear back, lunge and snap at the food, hold, recoil to the seat with an overshoot, a
    /// whole-body beat per chew, and the swallow's long neck.
    static func eatRoot(_ m: MealTiming, _ e: Double, _ room: PetRigRoom) -> (dx: Double, lift: Double, squash: Double) {
        let s = room.scale, dir = room.foodSide
        // Stuffed, it leans for the food rather than leaping at it: round and happy to stay put.
        let lazy = m.mood == .stuffed
        let big = (m.full ? 1.0 : 0.6) * (lazy ? 0.7 : 1)
        let rear = -dir * 2.0 * s * big * (lazy ? 0.7 : 1)
        let reach = dir * room.reach * (m.full ? 1 : 0.6) * (lazy ? 0.55 : 1)
        let leap = lazy ? 0.55 : 1.0
        var dx = 0.0, lift = 0.0, squash = 0.0
        if e < m.anticipation {
            let u = e / m.anticipation
            dx = rear * PetEase.outQuad(u)
            squash = -0.12 * big * PetEase.outQuad(u)
            // Famished, a little hop of joy as the food pops out of the number.
            if m.mood == .famished && m.full { lift = 1.0 * s * PetCurve.bump(e, 0, m.anticipation * 0.85) }
        } else if e < m.snap {
            let u = (e - m.anticipation) / m.lunge
            dx = PetCurve.mix(rear, reach, PetEase.inQuad(u))
            lift = 2.5 * s * big * leap * sin(.pi * u * 0.8)
            squash = PetCurve.mix(-0.12 * big, 0.10 * big, PetEase.outQuad(min(1, u * 1.6)))
        } else if e < m.recoilStart {
            let u = (e - m.snap) / max(m.hold, 1e-6)
            dx = reach
            lift = 2.5 * s * big * leap * sin(.pi * 0.8) * (1 - u)
            squash = PetCurve.mix(0.10 * big, 0.02 * big, PetEase.outQuad(min(1, u * 2)))
        } else if e < m.chewStart {
            let u = (e - m.recoilStart) / m.recoil
            // Back to the seat, a touch past it, and home.
            dx = reach * (1 - PetEase.outBack(u, 1.2))
            lift = (m.hold > 0 ? 0 : 2.5 * s * big * leap * sin(.pi * 0.8)) * (1 - PetEase.outQuad(min(1, u * 1.5)))
            squash = PetCurve.mix(0.02 * big, -0.04 * big, PetEase.inOutSine(min(1, u * 1.6))) * (1 - PetEase.inOutSine((u - 0.5) * 2))
        } else if e < m.swallowStart {
            let i = Int((e - m.chewStart) / m.chew)
            let u = (e - m.chewStart) / m.chew - Double(i)
            // The bite-down squashes the whole body, the jaw coming up lets it go: a beat that reads at
            // arm's length.
            squash = -0.05 * big * sin(.pi * u) * (i == m.chews - 1 ? 1.15 : 1)
            dx = 0.25 * s * (i % 2 == 0 ? -1 : 1) * sin(.pi * u)
        } else {
            let u = (e - m.swallowStart) / m.swallow
            let k = m.feast ? 0.36 / m.swallow : 1
            squash = -0.04 * PetCurve.bump(u, 0, 0.2 * k) + 0.075 * PetCurve.envelope(u, 0.18 * k, 0.32 * k, 0.45 * k, 0.7 * k)
                + (m.feast ? 0.06 * PetCurve.envelope(u, 0.5, 0.65, 0.75, 0.95) : 0)
                // Stuffed, the bite lands on a full belly, which bounces.
                - (lazy ? 0.05 * PetCurve.envelope(u, 0.6, 0.72, 0.78, 1.0) : 0)
        }
        return (dx, lift, squash)
    }

    /// One hop in place or across: a crouch, a ballistic arc stretched at both ends and round at the
    /// apex, a squash on landing. `k` scales the squash and stretch. The transitions are long enough that
    /// a hop inside an action-class behaviour keeps to 1 pt a frame at 60 fps, the most that class's rate
    /// draws smoothly.
    static func hopRoot(_ e: Double, at t0: Double, crouch: Double, air: Double, height: Double, dx: Double,
                        k: Double = 1) -> (dx: Double, lift: Double, squash: Double) {
        let takeoff = t0 + crouch, land = takeoff + air
        guard e > t0 else { return (0, 0, 0) }
        guard e < land + 0.4 else { return (dx, 0, 0) }
        var r = (dx: 0.0, lift: 0.0, squash: 0.0)
        r.squash -= 0.09 * k * PetCurve.envelope(e, t0, t0 + crouch * 0.75, takeoff - 0.05, takeoff + 0.06,
                                                 up: PetEase.outQuad, down: PetEase.inOutSine)
        r.squash += 0.06 * k * (PetCurve.envelope(e, takeoff - 0.05, takeoff + 0.07, takeoff + air * 0.3, takeoff + air * 0.5)
                                + PetCurve.envelope(e, land - air * 0.45, land - air * 0.2, land - 0.03, land + 0.04))
        if e > takeoff && e < land {
            let u = (e - takeoff) / air
            r.lift = 4 * height * u * (1 - u)
            r.dx = dx * PetCurve.mix(u, PetEase.inOutSine(u), 0.3)
        } else if e >= land {
            r.dx = dx
        }
        r.squash -= 0.08 * k * PetCurve.envelope(e, land - 0.02, land + 0.06, land + 0.09, land + 0.36,
                                                 up: PetEase.outQuad, down: PetEase.inOutSine)
        return r
    }

    /// A step-out: the body slides `dx` over `length` on two little steps, its weight rocking.
    static func stepRoot(_ e: Double, at t0: Double, length: Double, dx: Double) -> (dx: Double, lift: Double, squash: Double) {
        guard e > t0 else { return (0, 0, 0) }
        guard e < t0 + length + 0.2 else { return (dx, 0, 0) }
        let u = PetEase.inOutSine((e - t0) / length)
        let bob = PetCurve.bump(e, t0 + 0.05 * length, t0 + 0.5 * length) + PetCurve.bump(e, t0 + 0.45 * length, t0 + 0.95 * length)
        return (dx * u, 0.5 * bob, -0.02 * bob)
    }

    /// The big stretch of the wake and of leaving the den: a crouch, up to the zone's stretch limit with
    /// a trembling hold, a release that overshoots.
    static func stretchRoot(_ e: Double, s: Double) -> (dx: Double, lift: Double, squash: Double) {
        guard e > 0 else { return (0, 0, 0) }
        let crouch = PetCurve.envelope(e, 0, 0.12, 0.13, 0.22, up: PetEase.inOutSine, down: PetEase.inOutSine)
        let up = PetCurve.envelope(e, 0.12, 0.62, 1.1, 1.4, up: PetEase.inOutSine, down: PetEase.inOutSine)
        let after = PetCurve.envelope(e, 1.3, 1.42, 1.44, 1.58, up: PetEase.inOutSine, down: PetEase.inOutSine)
        let tremble = 0.008 * sin(2 * .pi * 14 * e) * PetCurve.envelope(e, 0.62, 0.72, 1.0, 1.1)
        return (0, 0.7 * s * PetCurve.envelope(e, 0.25, 0.6, 1.05, 1.35), -0.08 * crouch + 0.20 * up - 0.05 * after + tremble)
    }

    /// Into the den (enter) or out of it. Beside, sideways past the notch's edge; below, up into the notch
    /// and down from it; on the pill and in the panel, nowhere: it curls up where it is.
    static func denRoot(enter: Bool, retreat: Bool, _ e: Double, _ room: PetRigRoom) -> (dx: Double, lift: Double, squash: Double) {
        if room.hasSideDen {
            if enter {
                // Steps toward the edge, a look back, then a slow squeeze past it; a retreat is the squeeze
                // alone.
                if retreat {
                    let u = PetEase.inOutSine(e / (B.retreat - 0.1))
                    return (room.hiddenX * u, 0, -0.04 * PetCurve.bump(e, 0.2, B.retreat))
                }
                let walk = stepRoot(e, at: 0.45, length: 0.9, dx: 0.6 * room.denX)
                let slide = PetEase.inOutSine((e - B.retreat) / (B.enterDen - B.retreat - 0.15))
                let dx = e < B.retreat ? walk.dx : PetCurve.mix(0.6 * room.denX, room.hibernatingX, slide)
                return (dx, walk.lift, walk.squash - 0.04 * PetCurve.bump(e, 1.6, 3.2))
            }
            // Out: an eye at the edge, then two steps out to the anchor; from denWait it starts hidden.
            let from = retreat ? room.hiddenX : room.hibernatingX
            let peek = PetCurve.mix(from, room.peekX, PetEase.inOutSine(e / 0.6))
            if e < B.leaveDenPeek { return (peek, 0, 0) }
            let out = stepRoot(e, at: B.leaveDenPeek, length: B.leaveDenOut - 0.05, dx: -room.peekX)
            return (room.peekX + out.dx, out.lift, out.squash)
        }
        if room.hasOverheadDen {
            if enter {
                // Below: a crouch, a look up, and up into the notch; it stays up there.
                let start = retreat ? 0.0 : 1.2
                let crouch = PetCurve.envelope(e, start, start + 0.22, start + 0.26, start + 0.36, up: PetEase.outQuad, down: PetEase.inOutSine)
                let rise = PetEase.inOutSine((e - start - 0.3) / 0.6)
                return (0, e > start + 0.3 ? room.hiddenLift * rise : 0, -0.07 * crouch + 0.05 * PetCurve.bump(e, start + 0.3, start + 0.8))
            }
            // Out: hanging down to peek, then down to the anchor, landing soft.
            if e < B.leaveDenPeek { return (0, PetCurve.mix(room.hiddenLift, room.peekLift, PetEase.inOutSine(e / 0.6)), 0) }
            let u = (e - B.leaveDenPeek) / 0.45
            let lift = room.peekLift * (1 - PetEase.inOutSine(u))
            let land = -0.06 * PetCurve.envelope(e, B.leaveDenPeek + 0.4, B.leaveDenPeek + 0.5, B.leaveDenPeek + 0.52,
                                                 B.leaveDenPeek + 0.75)
            return (0, max(0, lift), land)
        }
        // No den: settle down into a ball, or get up out of one.
        let settle = enter ? PetCurve.envelope(e, 0.4, 0.8, 1.6, 2.4) : PetCurve.bump(e, 0, 0.6)
        return (0, 0, -0.04 * settle)
    }

    /// One look out of the den, 2.2 s.
    static func peekRoot(_ e: Double, _ room: PetRigRoom) -> (dx: Double, lift: Double, squash: Double) {
        let out = PetCurve.envelope(e, 0, 0.55, 1.6, 2.15, up: PetEase.inOutSine, down: PetEase.inOutSine)
        if room.hasSideDen { return (PetCurve.mix(room.hiddenX, room.peekX, out), 0, 0) }
        if room.hasOverheadDen { return (0, PetCurve.mix(room.hiddenLift, room.peekLift, out), 0) }
        return (0, 0, 0)
    }

    /// The first time the pet is seen: it peeks out, looks around, notices the readout, steps out and
    /// sits; with no accounts it goes back in.
    static func introRoot(_ e: Double, noAccounts: Bool, _ room: PetRigRoom) -> (dx: Double, lift: Double, squash: Double) {
        if room.hasSideDen {
            let peek = PetCurve.mix(room.hiddenX, room.peekX, PetEase.inOutSine(e / 0.6))
            if noAccounts {
                let back = PetEase.inOutSine((e - 1.6) / 0.55)
                return (PetCurve.mix(peek, room.hiddenX, back), 0, 0)
            }
            if e < 2.0 { return (peek, 0, 0) }
            let out = stepRoot(e, at: 2.0, length: 0.85, dx: -room.peekX)
            return (room.peekX + out.dx, out.lift, out.squash - 0.03 * PetCurve.bump(e, 2.95, 3.45))
        }
        if room.hasOverheadDen {
            let peek = PetCurve.mix(room.hiddenLift, room.peekLift, PetEase.inOutSine(e / 0.6))
            if noAccounts { return (0, PetCurve.mix(peek, room.hiddenLift, PetEase.inOutSine((e - 1.6) / 0.55)), 0) }
            if e < 2.0 { return (0, peek, 0) }
            let u = (e - 2.0) / 0.5
            let land = -0.06 * PetCurve.envelope(e, 2.45, 2.55, 2.57, 2.8)
            return (0, max(0, room.peekLift * (1 - PetEase.inOutSine(u))), land)
        }
        // No den: it rises into being and has a look round.
        return (0, 0, -0.05 * (1 - PetEase.smooth(e / 0.5)))
    }

    /// Kicks to the secondary springs at the action's beats.
    static func impulses(_ b: PetBehaviour) -> [(Double, PetRigSecondary.Spring, Double)] {
        switch b {
        case .eat(let meal):
            guard !meal.reduceMotion else { return [] }
            let m = timing(meal)
            let big = m.full ? 1.0 : 0.6
            var out: [(Double, PetRigSecondary.Spring, Double)] = [
                (m.snap + 0.001, .jiggle, -1.2 * big), (m.snap, .brows, -8 * big), (m.chewStart, .jiggle, -0.9 * big),
                (m.swallowStart + 0.06, .jiggle, 0.9), (m.splash, .wave, 2.6),
                (m.splash, .belly, m.mood == .stuffed ? 0.9 : m.feast ? 0.3 : 0.14),
            ]
            for i in 0..<m.chews {
                out.append((m.chewStart + (Double(i) + 0.5) * m.chew, .jiggle, i == m.chews - 1 ? -0.9 : -0.7))
            }
            return out
        case .perk: return [(0.1, .jiggle, 0.8), (0.08, .brows, 4)]
        case .satisfied(.meal): return [(1.25, .jiggle, -0.4), (1.75, .jiggle, -0.4)]
        case .satisfied(.grateful): return [(1.31, .jiggle, -0.7), (0.45, .belly, 0.5)]
        case .satisfied(.brim):
            return [(brimPat.taps[0], .belly, 1.0), (brimPat.taps[1], .belly, 0.9), (1.55, .brows, 4)]
        case .satisfied(.feast): return [(1.45, .jiggle, 1.4), (0.65, .jiggle, -0.4), (1.1, .jiggle, -0.4)]
        case .boop(let giggle): return [(0.02, .jiggle, -3.0), (0.02, .brows, 9)] + (giggle ? [(0.32, .jiggle, -1.0), (0.62, .jiggle, -1.0)] : [])
        case .celebrate(.streak): return [(0.96, .jiggle, -0.7), (twirl.land, .jiggle, -0.6)]
        case .celebrate(.goodWeek): return [(2.22, .jiggle, -0.6)]
        case .freshWindow: return [(0.82, .jiggle, -0.5)]
        case .wake: return [(B.wakeStir + 1.4, .jiggle, -1.2)]
        case .leaveDen(let stretch): return stretch ? [(B.leaveDenPeek + B.leaveDenOut + 1.4, .jiggle, -1.0)] : []
        case .intro: return []
        default: return []
        }
    }

    /// The transient source of a segment, if its behaviour moves the body.
    static func source(_ segment: PetSegment, length: Double, scene: PetRigPoser) -> PetRigSource? {
        switch segment.behaviour {
        case .idle, .settled, .eager, .asleep, .hibernating, .stirring, .denWait, .doze, .unsureIdle, .off:
            return nil
        case .eat(let meal) where meal.reduceMotion:
            return nil
        default:
            break
        }
        let posture = posture(segment.behaviour, elapsed: 0.5, scene: scene)
        let room = PetRigRoom(zone: scene.zone)
        var source = PetRigSource(kind: .segment(segment.behaviour, length: length), start: segment.start,
                                  scale: room.scale, foodSide: room.foodSide, jellyHz: posture.jellyHz,
                                  jellyZeta: posture.jellyZeta)
        source.reach = room.reach
        source.denX = room.denX
        source.denY = room.denY
        return source
    }

    // MARK: - Placing the body

    /// Where a behaviour puts the body before it moves: in the den for the den behaviours.
    static func place(_ body: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        let room = PetRigRoom(zone: scene.zone)
        let rest = restOffset(beat.behaviour, room: room)
        body.x += rest.dx
        body.lift += rest.lift
    }

    /// The offset of a behaviour's resting place from the anchor: inside the den for hibernating and for
    /// waiting with no account.
    static func restOffset(_ b: PetBehaviour, room: PetRigRoom) -> (dx: Double, lift: Double) {
        switch b {
        case .hibernating, .stirring:
            if room.hasSideDen { return (room.hibernatingX, 0) }
            if room.hasOverheadDen { return (0, room.hiddenLift) }
            return (0, 0)
        case .denWait:
            if room.hasSideDen { return (room.hiddenX, 0) }
            if room.hasOverheadDen { return (0, room.hiddenLift) }
            return (0, 0)
        default:
            return (0, 0)
        }
    }

    /// Where the feet stand in a zone for a behaviour at rest: the start of a glide out of the den.
    static func restFeet(_ b: PetBehaviour, zone: PetZone) -> CGPoint {
        let r = restOffset(b, room: PetRigRoom(zone: zone))
        return CGPoint(x: Double(zone.anchor.x) + r.dx, y: Double(zone.anchor.y) - r.lift)
    }

    /// Poses that may pass the zone on the den's side.
    static func denPose(_ beat: PetRigBeat) -> Bool {
        switch beat.behaviour {
        case .enterDen, .hibernating, .stirring, .leaveDen, .denWait, .peek, .intro: return true
        default: return false
        }
    }

    // MARK: - Acting

    static func apply(_ body: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        guard beat.start.isFinite else { return }
        let room = PetRigRoom(zone: scene.zone)
        let e = beat.elapsed
        let r = root(beat.behaviour, elapsed: e, room: room)
        body.x += r.dx
        body.lift += r.lift
        body.squash += r.squash
        act(beat.behaviour, &body, e: e, room: room, scene: scene)
    }

    /// The face, the limbs and the light of each behaviour, on top of its posture and movement.
    static func act(_ b: PetBehaviour, _ p: inout PetBody, e: Double, room: PetRigRoom, scene: PetRigPoser) {
        let dir = room.foodSide
        switch b {
        case .eat(let meal):
            if meal.reduceMotion { reducedMeal(meal, &p, e: e) } else { eat(timing(meal), &p, e: e, dir: dir) }
            // A green or red glow at the mouth of a full creature reads as nausea: stuffed, or stuffed by
            // this meal, the swallowed light is the pet's own.
            if meal.mood == .stuffed || moodAfter(meal, start: scene.t - e, scene: scene) == .stuffed { p.lumpTint = 0 }
        case .perk(let kind):
            // The signature: a cheeky double flick of the brows, then everything up, eyes on the food.
            for (i, c) in [0.0, 0.13].enumerated() {
                let k = PetCurve.envelope(e, c, c + 0.05, c + 0.06, c + 0.12, up: PetEase.outQuad, down: PetEase.inOutSine)
                p.browLiftL += (i == 0 ? 0.9 : 0.8) * k
                p.browLiftR += (i == 0 ? 0.75 : 0.9) * k
            }
            p.eyeSize += 0.1 * PetCurve.envelope(e, 0.02, 0.08, 0.3, kind == .prompt ? 0.5 : 0.8)
            p.smile += 0.25 * PetCurve.envelope(e, 0.02, 0.08, 0.2, 0.3)
        case .satisfied(.grateful):
            grateful(&p, e: e, dir: dir)
        case .satisfied(.meal):
            p.nod += 0.2 * PetCurve.envelope(e, 0.2, 0.6, 0.62, 1.05)
            pats(&p, e: e, at: [1.2, 1.7])
            p.happy = max(p.happy, 0.85 * (1 - PetCurve.ramp(e, 2.6, 3.0)))
        case .satisfied(.feast):
            pats(&p, e: e, at: [0.6, 1.05])
            let hic = PetCurve.envelope(e, 1.4, 1.43, 1.48, 1.6)
            p.lidL = PetCurve.mix(p.lidL, 1, 0.7 * hic); p.lidR = PetCurve.mix(p.lidR, 1, 0.7 * hic)
            p.happy *= 1 - hic
            p.browLiftL += 0.7 * hic; p.browLiftR += 0.7 * hic
            p.mouthOpen = max(p.mouthOpen, 0.22 * PetCurve.bump(e, 1.4, 1.5))
            p.mouthWide *= 1 - 0.4 * hic
            if stuffedAfter(scene.t - e, scene: scene) {
                // Stuffed by it, and still great: the eyes open on the viewer for a thumbs-up, then a sigh.
                p.happy = PetCurve.mix(p.happy, 0, PetRigMoodBeats.eyes(e, open: 1.9, close: 3.25))
                PetRigMoodBeats.thumbsUp(&p, e - 2.0, rise: 0.4, hold: 0.75, lower: 0.45, side: PetRigMoodBeats.thumbSide(scene))
                PetRigMoodBeats.sighOut(&p, e - 3.3)
            }
        case .satisfied(.brim):
            brim(&p, e: e, dir: dir, side: PetRigMoodBeats.thumbSide(scene))
        case .satisfied(.lick):
            lick(&p, e: e, dir: dir)
            if let m = meal(before: scene.t - e, scene: scene) {
                if m.meal.mood == .famished {
                    // Grateful even for a nibble: a quick happy squint, pink cheeks.
                    p.happy = max(p.happy, PetCurve.envelope(e, 0.36, 0.42, 0.5, 0.6))
                    p.blush += 0.25 * PetCurve.envelope(e, 0.3, 0.4, 0.5, 0.6)
                } else if moodAfter(m.meal, start: m.start, scene: scene) == .stuffed {
                    // A nibble on a full belly: one pat with the near nub.
                    let hit = PetCurve.envelope(e, 0.22, 0.38, 0.4, 0.58, up: PetEase.inOutSine, down: PetEase.inOutSine)
                    if dir < 0 { p.armL -= 0.6 * hit } else { p.armR -= 0.6 * hit }
                }
            }
        case .boop(let giggle):
            p.squeeze = max(p.squeeze, PetCurve.envelope(e, 0, 0.03, 0.16, 0.3))
            p.blush += 0.4 * PetCurve.envelope(e, 0, 0.1, 0.4, 0.6)
            p.smile += 0.4 * PetCurve.envelope(e, 0.1, 0.2, 0.4, 0.6)
            p.mouthOpen = max(p.mouthOpen, 0.25 * PetCurve.envelope(e, 0.12, 0.2, 0.35, 0.5))
            if giggle {
                p.happy = max(p.happy, PetCurve.envelope(e, 0.15, 0.25, 0.95, 1.15))
                p.tremor += 0.35 * sin(2 * .pi * 9 * e) * PetCurve.envelope(e, 0.15, 0.25, 0.9, 1.1)
                p.mouthOpen = max(p.mouthOpen, 0.35 * PetCurve.envelope(e, 0.2, 0.3, 0.9, 1.1))
                p.armL += 0.6 * PetCurve.envelope(e, 0.2, 0.3, 0.9, 1.1)
                p.armR += 0.6 * PetCurve.envelope(e, 0.2, 0.3, 0.9, 1.1)
            }
        case .celebrate(.streak):
            // A happy hop, arms up, then the twirl: a whole turn in the air, the face going round the back
            // and coming in from the other side. A whole turn looks like none, so the spin keeps its 2π
            // after landing and never jumps back. Eyes squeezed with joy throughout.
            let up = PetCurve.envelope(e, 0.3, 0.6, 0.85, 1.1)
                + PetCurve.envelope(e, twirl.takeoff - 0.08, twirl.takeoff + 0.06, twirl.land - 0.04, twirl.land + 0.24)
            p.armL += 0.9 * up; p.armR += 1.0 * up
            p.spin += 2 * .pi * PetEase.inOutSine((e - twirl.takeoff) / twirl.air)
            p.happy = max(p.happy, 0.9 * PetRigMoodBeats.eyes(e, open: 0.5, close: 2.1))
            p.smile += 0.3 * PetCurve.envelope(e, 0.3, 0.5, 2.0, 2.3)
            p.footL -= 0.6 * min(1, up); p.footR -= 0.6 * min(1, up)
        case .celebrate(.goodWeek):
            // A drum roll on the belly, a hop, arms up.
            for (i, c) in [0.3, 0.6, 0.9, 1.2].enumerated() {
                let hit = PetCurve.envelope(e, c - 0.14, c, c + 0.02, c + 0.16, up: PetEase.inOutSine, down: PetEase.inOutSine)
                if i % 2 == 0 { p.armL -= 1.3 * hit } else { p.armR -= 1.3 * hit }
            }
            p.happy = max(p.happy, 0.8 * PetRigMoodBeats.eyes(e, open: 0.15, close: 1.35))
            let up = PetCurve.envelope(e, 1.6, 1.9, 2.15, 2.45)
            p.armL += 0.9 * up; p.armR += 0.9 * up
            p.happy = max(p.happy, 0.9 * PetRigMoodBeats.eyes(e, open: 2.1, close: 2.55))
        case .freshWindow:
            p.turn += 0.4 * dir * PetCurve.envelope(e, 0, 0.12, 0.3, 0.5)
            p.lookX += 0.8 * dir * PetCurve.envelope(e, 0, 0.08, 0.3, 0.45)
            p.browLiftL += 0.8 * PetCurve.envelope(e, 0.05, 0.12, 0.25, 0.4)
            p.browLiftR += 0.8 * PetCurve.envelope(e, 0.05, 0.12, 0.25, 0.4)
            let up = PetCurve.envelope(e, 0.35, 0.55, 0.65, 0.85)
            p.armL += 0.7 * up; p.armR += 0.7 * up
        case .fallAsleep:
            fallAsleep(&p, e: e)
        case .drowsy:
            yawn(&p, e: e, at: 0.9, scale: 0.6, slow: 1.8)
        case .wake:
            wake(&p, e: e, stir: true)
        case .rollOver:
            let roll = PetCurve.envelope(e, 0, 0.45, 0.5, 1.0, up: PetEase.inOutSine, down: PetEase.inOutSine)
            p.tilt += -dir * 0.07 * roll
            p.smile += 0.15 * roll
        case .enterDen(let retreat):
            if !retreat {
                p.turn += 0.55 * PetCurve.envelope(e, 0.05, 0.35, 1.3, 1.6) * (room.hasSideDen ? 1 : 0)
                p.nod += 0.5 * PetCurve.envelope(e, 0.1, 0.4, 1.1, 1.4) * (room.hasOverheadDen ? 1 : 0)
                yawn(&p, e: e, at: 1.55, scale: 0.7)
            } else {
                p.turn += 0.5 * PetCurve.envelope(e, 0, 0.2, 1.2, 1.5) * (room.hasSideDen ? 1 : 0)
            }
        case .leaveDen(let stretch):
            // An eye at the edge, a look, out.
            p.lidL = min(p.lidL, PetCurve.mix(0.2, 1, PetCurve.ramp(e, 0.2, 0.5)))
            p.turn -= 0.45 * PetCurve.envelope(e, 0.2, 0.45, 0.7, 0.95) * (room.hasSideDen ? 1 : 0)
            if stretch {
                stretchFace(&p, e: e - B.leaveDenPeek - B.leaveDenOut)
                shake(&p, e: e - B.leaveDenPeek - B.leaveDenOut - B.leaveDenStretch, strength: 0.4)
            }
        case .peek:
            let look = PetCurve.envelope(e, 0.5, 0.7, 1.5, 1.7)
            p.turn += (-0.6 + 0.9 * PetEase.inOutSine((e - 0.7) / 0.7)) * look * (room.hasSideDen ? 1 : 0.6)
            p.lookX += (-0.8 + 1.2 * PetEase.inOutSine((e - 0.65) / 0.7)) * look
            p.browLiftL += 0.5 * look
        case .intro(let noAccounts):
            let look = PetCurve.envelope(e, 0.6, 0.8, 1.5, 1.7)
            p.turn += (-0.5 + 0.8 * PetEase.inOutSine((e - 0.7) / 0.8)) * look
            p.lookX += (-0.8 + 1.4 * PetEase.inOutSine((e - 0.65) / 0.8)) * look
            let notice = PetCurve.envelope(e, 1.6, 1.68, 1.85, 2.0)
            p.browLiftL += 1.1 * notice; p.browLiftR += 0.9 * notice
            p.eyeSize += 0.12 * notice
            p.lookX += dir * 0.9 * PetCurve.envelope(e, 1.6, 1.7, noAccounts ? 1.65 : 2.3, noAccounts ? 1.75 : 2.5)
        case .dozeIn:
            p.nod -= 0.1 * PetCurve.ramp(e, 0.4, 1.8)
            let heavy = IdleBlink.shape(e - 0.5, length: 0.4) * (1 - PetCurve.ramp(e, 0.9, 1.0))
            p.lidL *= heavy; p.lidR *= heavy
        case .welcomeBack:
            let blink = IdleBlink.shape(e - 0.15, length: 0.18)
            p.lidL *= blink; p.lidR *= blink
            let stretch = PetCurve.envelope(e, 0.35, 0.75, 0.95, 1.35, up: PetEase.outCubic, down: PetEase.inOutSine)
            p.armL += 1.0 * stretch; p.armR += 0.85 * stretch
            p.squeeze = max(p.squeeze, 0.8 * PetCurve.envelope(e, 0.45, 0.6, 0.9, 1.1))
            p.mouthOpen = max(p.mouthOpen, 0.35 * PetCurve.envelope(e, 0.5, 0.65, 0.9, 1.1))
            p.mouthWide = PetCurve.mix(p.mouthWide, 0.6, PetCurve.envelope(e, 0.5, 0.65, 0.9, 1.1))
            p.smile += 0.3 * PetCurve.ramp(e, 1.2, 1.6)
        case .asleep, .hibernating:
            p.glow += (b == .asleep ? 0.18 : 0.1) * sin(2 * .pi * e / (b == .asleep ? 4.6 : PetTuning.Den.glowCycle) - 0.3)
        case .unsureIdle:
            // A puzzled head tilt every 20 to 40 s.
            let period = PetTuning.Stale.tiltMinimum + PetTuning.Stale.tiltMaximum
            let k = Int(floor(e / (period / 2)))
            let at = Double(k) * period / 2 + 4 + 8 * PetNoise.hash(scene.seed, PetRigChannel.tiltAt, k)
            let tilt = PetCurve.envelope(e, at, at + 0.35, at + 1.3, at + 1.8)
            let side = PetNoise.hash(scene.seed, PetRigChannel.side, k) < 0.5 ? -1.0 : 1.0
            p.tilt += side * 0.13 * tilt
            p.browLiftL += (side < 0 ? 0.6 : -0.1) * tilt
            p.browLiftR += (side > 0 ? 0.6 : -0.1) * tilt
            p.mouthWide = PetCurve.mix(p.mouthWide, 0.5, 0.6 * tilt)
        case .idle, .settled, .eager, .stirring, .denWait, .doze, .off:
            break
        }
    }

    // MARK: The meal

    static func eat(_ m: MealTiming, _ p: inout PetBody, e: Double, dir: Double) {
        let big = (m.full ? 1.0 : 0.65) * (m.mood == .stuffed ? 0.7 : 1)
        if m.mood == .famished {
            // Shining eyes on the food, and through the chews a blissful sway, the cheeks pink.
            p.eyeSize += 0.08 * PetCurve.envelope(e, 0, m.anticipation * 0.5, m.snap, m.snap + 0.05)
            let savour = PetCurve.envelope(e, m.chewStart, m.chewStart + 0.1, m.swallowStart, m.swallowStart + 0.2)
            p.turn += 0.1 * sin(2 * .pi * (e - m.chewStart) / (2 * m.chew)) * savour
            p.blush += 0.3 * savour
        }
        // Anticipation: lean back, eyes wide on the food, the mouth opening wide.
        let rear = PetCurve.envelope(e, 0, m.anticipation * 0.8, m.anticipation, m.snap, up: PetEase.outQuad, down: PetEase.inQuad)
        p.lean -= dir * 0.10 * big * rear
        p.eyeSize += 0.14 * PetCurve.envelope(e, 0, m.anticipation * 0.5, m.snap - 0.02, m.snap + 0.02)
        p.browLiftL += 0.9 * PetCurve.envelope(e, 0, m.anticipation * 0.4, m.snap - 0.05, m.snap)
        p.browLiftR += 0.9 * PetCurve.envelope(e, 0, m.anticipation * 0.4, m.snap - 0.05, m.snap)
        let open = PetCurve.envelope(e, m.anticipation * 0.15, m.anticipation, m.snap - 0.012, m.snap + 0.012,
                                     up: PetEase.outCubic, down: PetEase.inQuad)
        p.mouthOpen = max(p.mouthOpen, (m.full ? 1.0 : 0.7) * open)
        p.mouthWide *= 1 + 0.12 * open
        p.smile -= 0.3 * open
        p.armL += -0.45 * rear
        p.armR += -0.45 * rear
        // The lunge: stretched toward the food, face up, arms out.
        let strike = PetCurve.envelope(e, m.anticipation - 0.01, m.anticipation + m.lunge * 0.5, m.snap, m.recoilStart + m.recoil * 0.5)
        p.lean += dir * 0.24 * big * strike
        p.nod += 0.45 * PetCurve.envelope(e, m.anticipation, m.snap - 0.04, m.snap, m.recoilStart + 0.1)
        p.browTiltL -= 0.25 * strike; p.browTiltR -= 0.25 * strike
        if dir < 0 { p.armL += 0.8 * strike; p.armR += 0.5 * strike } else { p.armR += 0.8 * strike; p.armL += 0.5 * strike }
        p.turn += dir * 0.35 * PetCurve.envelope(e, 0, m.anticipation * 0.5, m.recoilStart, m.chewStart)
        // The snap: eyes squeezed for a few frames, the cheeks full.
        p.squeeze = max(p.squeeze, PetCurve.envelope(e, m.snap - 0.008, m.snap + 0.006, m.snap + 0.04, m.snap + 0.08))
        p.cheekPuff = max(p.cheekPuff, PetCurve.ramp(e, m.snap, m.snap + 0.05) * (1 - PetCurve.ramp(e, m.swallowStart, m.swallowStart + 0.1)))
        // The chews: the jaw down and up, the cheeks working side to side, brows on the off-beat.
        if e >= m.chewStart && e < m.swallowStart {
            let i = Int((e - m.chewStart) / m.chew)
            let u = (e - m.chewStart) / m.chew - Double(i)
            let jaw = sin(.pi * u)
            p.chew = PetCurve.envelope(e, m.chewStart - 0.03, m.chewStart + 0.03, m.swallowStart - 0.04, m.swallowStart + 0.02)
            p.chewPhase = 2 * .pi * u + Double(i) * 0.9
            p.cheekBias = (i % 2 == 0 ? -1 : 1) * jaw
            p.nod -= 0.16 * jaw
            p.browLiftL += 0.4 * sin(2 * .pi * u - 0.8)
            p.browLiftR += 0.4 * sin(2 * .pi * u - 1.1)
            p.cheekPuff = max(p.cheekPuff, 1.0)
            p.lean += 0.02 * (i % 2 == 0 ? -1 : 1) * jaw
        }
        // The swallow: the bite moves from the cheeks to the throat, a long neck and chin up, then the
        // light drops through the body and splashes in; the eyes follow it down.
        if e >= m.swallowStart - 0.05 {
            let u = e - m.swallowStart
            let gulp = PetCurve.envelope(u, 0.04, 0.1, 0.16, 0.26)
            p.nod += 0.3 * gulp
            p.smile -= 0.35 * gulp
            p.happy -= 0.6 * PetCurve.envelope(u, 0, 0.06, 0.2, 0.3)
            let drop = m.splash - m.swallowStart - 0.08
            if u >= 0.08 && u <= 0.08 + drop { p.lump = (u - 0.08) / drop }
            p.lookY -= 0.9 * PetCurve.envelope(u, 0.08, 0.12, drop + 0.08, drop + 0.3)
            p.lookX -= dir * 0.2 * PetCurve.envelope(u, 0.08, 0.12, drop + 0.08, drop + 0.3)
        }
        // From the snap to the end the mouth stays shut on its bite, whatever the posture's mouth was.
        if e > m.snap - 0.012 {
            p.mouthOpen *= 1 - PetCurve.ramp(e, m.snap - 0.012, m.snap + 0.012)
        }
    }

    /// The brim's pat-pat, drawn at the satisfactions' 60 fps: the nubs come across the belly from the meal at
    /// once, pat it twice and are back at rest by 1.1 s, before the thumbs-up.
    static let brimPat = PetRigMoodBeats.BellyPat(arrive: 0, settle: 0.3, taps: [0.5, 0.74], leave: 0.8, tapTime: 0.1)

    /// A full meal that leaves it stuffed: both nubs across the round belly for a pat-pat, eyes shut; then
    /// the eyes open on the viewer for a thumbs-up with a wink, and a contented sigh.
    static func brim(_ p: inout PetBody, e: Double, dir: Double, side: Double) {
        let near = brimPat.offset(e), far = brimPat.offset(e, lag: PetRigMoodBeats.patLag)
        p.armL += dir < 0 ? near : far
        p.armR += dir < 0 ? far : near
        p.nod += 0.08 * PetCurve.envelope(e, 0.2, 0.45, 0.85, 1.1)
        p.happy = PetCurve.mix(p.happy, 0, PetRigMoodBeats.eyes(e, open: 1.0, close: 2.35))
        PetRigMoodBeats.thumbsUp(&p, e - 1.15, rise: 0.4, hold: 0.75, lower: 0.5, side: side)
        PetRigMoodBeats.sighOut(&p, e - 2.45)
    }

    /// A meal eaten famished, the most grateful of all: it hugs itself with both nubs, eyes shut, cheeks
    /// pink, swaying a little, a small happy bounce in the middle; then the eyes open, shining, on the
    /// number, and a lick: more?
    static func grateful(_ p: inout PetBody, e: Double, dir: Double) {
        let hug = PetCurve.envelope(e, 0.12, 0.45, 1.45, 1.8, up: PetEase.inOutSine, down: PetEase.inOutSine)
        p.armL -= 2.05 * hug
        p.armR -= 2.05 * hug
        let sway = sin(2 * .pi * (e - 0.45) / 0.9) * PetCurve.envelope(e, 0.4, 0.6, 1.3, 1.5)
        p.tilt += -dir * 0.07 * hug + 0.04 * sway
        p.blush += 0.3 * hug
        p.smile += 0.1 * hug
        p.shine = max(p.shine, PetCurve.ramp(e, 1.7, 2.0))
        lick(&p, e: (e - 2.15) / 1.1, dir: dir, turn: 0.2)
    }

    /// Reduce Motion's meal: a crossfade to a chewing pose, one chew per point up to three, a crossfade
    /// back. No lunge, no squash beyond ±2 %.
    static func reducedMeal(_ meal: PetMeal, _ p: inout PetBody, e: Double) {
        let fade = PetTuning.Reduced.mealFade
        let chew = PetTuning.Reduced.chew
        let end = fade + Double(meal.chews) * chew
        let on = PetCurve.ramp(e, 0, fade) * (1 - PetCurve.ramp(e, end, end + fade))
        p.cheekPuff = max(p.cheekPuff, on)
        p.chew = on
        p.happy = max(p.happy, on)
        if e > fade && e < end {
            let u = (e - fade) / chew
            p.chewPhase = 2 * .pi * u
            p.cheekBias = sin(.pi * u.truncatingRemainder(dividingBy: 1)) * (Int(u) % 2 == 0 ? -1 : 1)
        }
    }

    /// The belly pats of `satisfied`: the right arm swings across the belly and back.
    static func pats(_ p: inout PetBody, e: Double, at times: [Double]) {
        for c in times {
            p.armR -= 1.55 * PetCurve.envelope(e, c - 0.1, c + 0.1, c + 0.12, c + 0.32, up: PetEase.inOutSine, down: PetEase.inOutSine)
        }
    }

    /// The glutton's tic: an eye on the number, a lick of the lips, a little chew. `turn` is how far the
    /// head goes with the eyes.
    static func lick(_ p: inout PetBody, e: Double, dir: Double, turn: Double = 0.3) {
        p.lookX += dir * 0.6 * PetCurve.envelope(e, 0, 0.05, 0.4, 0.55)
        p.turn += dir * turn * PetCurve.envelope(e, 0.03, 0.12, 0.4, 0.58)
        p.tongue = max(p.tongue, PetCurve.envelope(e, 0.12, 0.18, 0.24, 0.33))
        p.browLiftL += 0.3 * PetCurve.envelope(e, 0.05, 0.15, 0.3, 0.45)
        p.chew = max(p.chew, 0.5 * PetCurve.envelope(e, 0.34, 0.37, 0.42, 0.48))
        p.chewPhase = 2 * .pi * (e - 0.34) / 0.12
        // A happy squint, all the way to the arcs: held part way, the eye would show two drawings.
        p.happy = max(p.happy, 0.8 * PetCurve.envelope(e, 0.3, 0.38, 0.5, 0.6))
    }

    // MARK: Sleep

    /// A yawn: an inhale with brows up, eyes shut, a tall "O", a tremble, a smack. `slow` stretches it
    /// in time: drowsy's yawn plays at 15 fps.
    static func yawn(_ p: inout PetBody, e: Double, at t0: Double, scale: Double = 1, slow: Double = 1) {
        let t = (e - t0) / slow
        guard t > 0, t < 1.25 else { return }
        let inhale = PetCurve.envelope(t, 0, 0.3, 0.55, 0.8, up: PetEase.inOutSine, down: PetEase.inOutSine)
        p.nod += 0.3 * inhale * scale
        p.browLiftL += 0.8 * inhale * scale; p.browLiftR += 0.8 * inhale * scale
        p.browTiltL += 0.28 * inhale; p.browTiltR += 0.28 * inhale
        p.armL += 0.4 * inhale * scale; p.armR += 0.4 * inhale * scale
        let shut = PetCurve.envelope(t, 0.06, 0.14, 0.62, 0.74)
        p.lidL *= 1 - shut; p.lidR *= 1 - shut
        p.happy *= 1 - shut
        let open = PetCurve.envelope(t, 0.1, 0.25, 0.55, 0.75, up: PetEase.outQuad, down: PetEase.inOutSine)
        p.mouthOpen = max(p.mouthOpen, 0.95 * open * scale)
        p.mouthWide = PetCurve.mix(p.mouthWide, 0.5, open)
        p.smile = PetCurve.mix(p.smile, 0, open)
        p.tremor += 0.4 * sin(2 * .pi * 13 * t) * PetCurve.envelope(t, 0.3, 0.34, 0.46, 0.52) * scale
        p.chew = max(p.chew, 0.55 * PetCurve.envelope(t, 0.78, 0.8, 0.84, 0.9))
        p.chewPhase = 2 * .pi * (t - 0.78) / 0.1
    }

    /// Stuffed, it yawns, droops with a head that lolls and jerks back once, and curls up (yawn 1.0 s,
    /// droop 0.8 s, curl 0.8 s).
    static func fallAsleep(_ p: inout PetBody, e: Double) {
        yawn(&p, e: e, at: 0.05)
        let droopStart = B.fallAsleepYawn, curlStart = droopStart + B.fallAsleepDroop
        // The head lolls to one side, jerks back up past upright, and gives in.
        let drop = PetCurve.envelope(e, droopStart + 0.1, droopStart + 0.38, droopStart + 0.4, droopStart + 0.46,
                                     up: PetEase.inQuad, down: PetEase.outQuad)
        p.nod -= 0.7 * drop
        p.tilt += 0.1 * drop
        let jerk = PetCurve.envelope(e, droopStart + 0.41, droopStart + 0.46, droopStart + 0.5, droopStart + 0.62)
        p.browLiftL += 0.7 * jerk; p.browLiftR += 0.7 * jerk
        p.lidL = PetCurve.mix(p.lidL, 0.55, jerk); p.lidR = PetCurve.mix(p.lidR, 0.5, jerk)
        p.tilt -= 0.04 * PetCurve.envelope(e, droopStart + 0.44, droopStart + 0.48, droopStart + 0.52, droopStart + 0.62)
        let give = PetCurve.ramp(e, droopStart + 0.55, curlStart + 0.2, PetEase.inOutSine)
        p.lidL *= 1 - give; p.lidR *= 1 - give
    }

    /// The wake (stir 0.6 s, stretch 1.6 s, shake 0.5 s): one eye cracks open and looks, then both; the
    /// big stretch; a shake that the face follows a beat late.
    static func wake(_ p: inout PetBody, e: Double, stir: Bool) {
        if stir {
            // One eye cracks open and looks; then both pop open.
            let one = PetCurve.ramp(e, 0.08, 0.2), both = PetCurve.ramp(e, 0.42, 0.5)
            p.lidL = PetCurve.mix(min(p.lidL, 0.1), 1, both)
            p.lidR = PetCurve.mix(PetCurve.mix(min(p.lidR, 0.1), 0.5, one), 1, both)
            p.lookX += -0.5 * one * (1 - both)
            p.browLiftR += 0.8 * one * (1 - both)
            p.browLiftL += 1.0 * PetCurve.envelope(e, 0.4, 0.46, 0.52, 0.62)
            p.browLiftR += 1.0 * PetCurve.envelope(e, 0.4, 0.46, 0.52, 0.62)
            p.eyeSize += 0.12 * PetCurve.envelope(e, 0.4, 0.46, 0.52, 0.62)
            p.happy *= both
        }
        stretchFace(&p, e: e - B.wakeStir)
        shake(&p, e: e - B.wakeStir - B.wakeStretch)
    }

    /// The stretch's face and arms: squeezed eyes, an open mouth, arms up (one higher), leaning to a side.
    static func stretchFace(_ p: inout PetBody, e: Double) {
        guard e > 0, e < 1.6 else { return }
        let crouch = PetCurve.envelope(e, 0, 0.12, 0.13, 0.2, up: PetEase.outQuad, down: PetEase.inQuad)
        let up = PetCurve.envelope(e, 0.12, 0.62, 1.1, 1.4, up: PetEase.inOutSine, down: PetEase.inOutSine)
        p.armL += -0.3 * crouch + 1.8 * up
        p.armR += -0.3 * crouch + 1.4 * up
        p.squeeze = max(p.squeeze, PetCurve.envelope(e, 0.1, 0.2, 1.15, 1.3))
        let o = PetCurve.envelope(e, 0.2, 0.32, 1.0, 1.2)
        p.mouthOpen = max(p.mouthOpen, 0.5 * o)
        p.mouthWide = PetCurve.mix(p.mouthWide, 0.55, o)
        p.tilt += 0.09 * PetCurve.envelope(e, 0.2, 0.5, 1.0, 1.3)
        p.lean -= 0.05 * PetCurve.envelope(e, 0.2, 0.5, 1.0, 1.3)
        p.nod += 0.3 * up
        p.tremor += 0.5 * sin(2 * .pi * 14 * e) * PetCurve.envelope(e, 0.6, 0.7, 1.05, 1.15)
    }

    /// Shaking itself off: the body sways at 8 Hz and dies away, the face lags, the arms flap. The wake's
    /// shake runs in the fast class; leaving the den, at the action rate, it is held to `strength`.
    static func shake(_ p: inout PetBody, e: Double, strength: Double = 1) {
        guard e > 0, e < 0.5 else { return }
        let d = strength * exp(-e / 0.13) * PetEase.smooth(e / (strength < 1 ? 0.08 : 0.03)) * (1 - PetCurve.ramp(e, 0.38, 0.5))
        let w = 2 * Double.pi * 8 * e
        p.lean += 0.2 * sin(w) * d
        p.tilt -= 0.04 * sin(w - 0.4) * d
        p.squash += 0.025 * sin(2 * w) * d
        p.turn += 0.32 * sin(w - 1.0) * d
        p.armL += 0.55 * sin(w - 0.5) * d
        p.armR -= 0.55 * sin(w - 0.5) * d
        p.browLiftL += 0.5 * sin(w - 1.5) * d
        p.browLiftR += 0.5 * sin(w - 1.7) * d
        p.squeeze = max(p.squeeze, 0.9 * PetCurve.envelope(e, 0, 0.04, 0.24, 0.32))
    }

    /// The speed stretch along fast travel, area kept: the leap at the number reads as a smear toward it
    /// at 60 fps. Measured from the action's own movement, so it is exactly as fast as what is seen.
    static func smear(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        guard beat.start.isFinite, case .eat(let meal) = beat.behaviour, !meal.reduceMotion else { return }
        let room = PetRigRoom(zone: scene.zone)
        let m = timing(meal)
        let e = beat.elapsed
        let h = 1.0 / 240
        let a = root(beat.behaviour, elapsed: e - h, room: room)
        let b = root(beat.behaviour, elapsed: e + h, room: room)
        let vx = (b.dx - a.dx) / (2 * h), vy = -(b.lift - a.lift) / (2 * h)
        let speed = hypot(vx, vy) / max(room.scale, 0.1)
        // Stretched along the leap toward the food, then, on the snap, squashed along the same line: the
        // body hits the bite and gives, then springs back as it lets go.
        let toward = vx * room.foodSide > 0
        let stretch = toward && speed > 20 ? min(PetTuning.Hop.speedStretchMaximum, (speed - 20) / 1100) : 0
        let contact = PetCurve.envelope(e, m.snap - 0.01, m.snap + 0.025, m.recoilStart, m.recoilStart + m.recoil * 0.6,
                                        up: PetEase.outQuad, down: PetEase.inOutSine)
        p.smear = 1 + stretch - (m.full ? 0.10 : 0.06) * contact
        p.smearAngle = stretch > 0 ? atan2(vy, vx) : (room.foodSide < 0 ? .pi : 0)
    }

    // MARK: - Cuts, fades and the belly

    /// A segment that cut the one before it short: the cut action's offsets fade out over 0.2 s rather
    /// than vanish. A segment that followed its predecessor's own end has nothing to fade. An open
    /// behaviour always ends by being cut, so what it was doing at that instant fades too: the asleep
    /// and hibernating glow's slow pulse, the unsure head tilt, the drowsy yawn.
    static func fadeCut(_ p: inout PetBody, beat: PetRigBeat, scene: PetRigPoser) {
        guard let prev = beat.previous, beat.start.isFinite, beat.elapsed < 0.2 else { return }
        let own = prev.behaviour.duration ?? .infinity
        let length = beat.start - prev.start
        guard length < own - 1e-6, length > 0 else { return }
        let room = PetRigRoom(zone: scene.zone)
        var base = p
        base.cheekPuff = 0; base.mouthOpen = 0; base.squeeze = 0; base.chew = 0; base.tongue = 0; base.flash = 0
        base.lump = -1
        var cut = base
        let r = root(prev.behaviour, elapsed: length, room: room)
        cut.x += r.dx; cut.lift += r.lift; cut.squash += r.squash
        act(prev.behaviour, &cut, e: length, room: room, scene: scene)
        // A beat at an end of the meter under way when an action cuts the idle fades with it rather than
        // vanish; between two open behaviours it plays on instead (`PetRigMoodBeats.carries`).
        if let i = beat.index, i > 0, PetRigMoodBeats.extreme(prev.behaviour) != nil,
           !PetRigMoodBeats.carries(from: prev, to: scene.timeline.segments[i]) {
            let atCut = PetRigPoser(timeline: scene.timeline, t: beat.start, pointer: scene.pointer, zone: scene.zone,
                                    seed: scene.seed, motion: scene.motion, memo: scene.memo, flight: nil, flightSource: nil,
                                    lookAt: nil)
            PetRigMoodBeats.apply(&cut, beat: PetRigBeat(segments: scene.timeline.segments, index: i - 1, t: beat.start), scene: atCut)
        }
        let k = 1 - PetEase.smooth(beat.elapsed / 0.2)
        for key in fadeChannels { p[keyPath: key] += (cut[keyPath: key] - base[keyPath: key]) * k }
    }

    static let fadeChannels: [WritableKeyPath<PetBody, Double>] = [
        \.x, \.lift, \.squash, \.lean, \.tilt, \.nod, \.turn, \.cheekPuff, \.mouthOpen, \.mouthWide, \.smile, \.squeeze,
        \.eyeSize, \.browLiftL, \.browLiftR, \.browTiltL, \.browTiltR, \.armL, \.armR, \.chew, \.tongue, \.happy, \.flash,
        \.glow, \.thumbL, \.thumbR, \.winkL, \.winkR, \.shine,
    ]

    /// A feast leaves the belly round, easing back over 20 minutes.
    static func feastBelly(_ p: inout PetBody, segments: [PetSegment], t: Double) {
        let decay = M.feastBellyDecay
        for seg in segments.reversed() {
            if seg.start < t - decay - 10 { break }
            guard seg.start <= t, case .eat(let meal) = seg.behaviour, meal.feast else { continue }
            let m = timing(meal)
            let since = t - (seg.start + m.splash)
            let k = PetCurve.ramp(since, 0, 0.5) * (1 - PetEase.smooth(since / decay))
            p.girth *= 1 + 0.07 * M.feastBelly * k
            return
        }
    }

    /// `off`: 0.2 s of fade, then nothing.
    static func offOpacity(_ beat: PetRigBeat) -> Double {
        1 - PetEase.smooth(beat.elapsed / B.fadeOut)
    }

    /// Whatever follows `off` fades in over 0.3 s.
    static func fadeInAfterOff(_ beat: PetRigBeat) -> Double {
        guard let prev = beat.previous, prev.behaviour.isOff, beat.start.isFinite else { return 1 }
        return PetEase.smooth(beat.elapsed / B.fadeIn)
    }
}

/// Adds two root movements.
fileprivate func + (a: (dx: Double, lift: Double, squash: Double), b: (dx: Double, lift: Double, squash: Double))
    -> (dx: Double, lift: Double, squash: Double) {
    (a.dx + b.dx, a.lift + b.lift, a.squash + b.squash)
}
