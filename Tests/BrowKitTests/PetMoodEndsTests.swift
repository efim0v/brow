// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import XCTest
@testable import BrowKit

/// The two ends of the hunger meter, Stuffed and Famished: where they sit on it, how the brain gets there
/// and back, and what follows a meal in each.
final class PetMoodEndsTests: XCTestCase {

    // MARK: - The meter

    /// Each end is entered at its threshold and left 5 points past it, like every other mood.
    func testTheEndsHaveFivePointsOfHysteresis() {
        XCTAssertEqual(PetHunger.mood(-34.9, from: .full), .full)
        XCTAssertEqual(PetHunger.mood(-35.0, from: .full), .stuffed)
        XCTAssertEqual(PetHunger.mood(-30.0, from: .stuffed), .stuffed)
        XCTAssertEqual(PetHunger.mood(-29.9, from: .stuffed), .full)
        XCTAssertEqual(PetHunger.mood(89.9, from: .hungry), .hungry)
        XCTAssertEqual(PetHunger.mood(90.0, from: .hungry), .famished)
        XCTAssertEqual(PetHunger.mood(85.0, from: .famished), .famished)
        XCTAssertEqual(PetHunger.mood(84.9, from: .famished), .hungry)
        // Content and Peckish are where they were.
        XCTAssertEqual(PetHunger.mood(-4.9, from: .content), .content)
        XCTAssertEqual(PetHunger.mood(-5.0, from: .content), .full)
        XCTAssertEqual(PetHunger.mood(60, from: .hungry), .hungry)
        XCTAssertEqual(PetHunger.mood(59.9, from: .hungry), .peckish)
    }

    /// With no history (a new pet, one restored from `pet.json`) a value takes the mood on the way up.
    func testWithoutHistoryAValueTakesTheMoodOnTheWayUp() {
        XCTAssertEqual(PetHunger.moodOnTheWayUp(-50), .stuffed)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(-30), .stuffed)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(-29.9), .full)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(0), .full)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(89.9), .hungry)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(90), .famished)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(100), .famished)
    }

    /// The brain's tick lands on the next threshold up: −30 out of Stuffed, 90 into Famished, none past it.
    func testTheNextThresholdUp() {
        XCTAssertEqual(PetHunger.nextThreshold(above: -40, mood: .stuffed), -30)
        XCTAssertEqual(PetHunger.nextThreshold(above: -20, mood: .full), 0)
        XCTAssertEqual(PetHunger.nextThreshold(above: 70, mood: .hungry), 90)
        XCTAssertEqual(PetHunger.nextThreshold(above: 91, mood: .hungry), 91, "already past it: at once")
        XCTAssertNil(PetHunger.nextThreshold(above: 95, mood: .famished))
    }

    /// From 0 at an even pace, Famished after 4 h 30 min of hunger time; at 100 it stays Famished.
    func testFamishedComesFourAndAHalfHoursAfterZeroAndStays() {
        var pet = PetHarness(hunger: 0)
        pet.accounts[0].five = 10
        pet.accounts[0].fiveReset = 9 * 3600
        pet.start()
        pet.run(to: 4.5 * 3600 - 10)
        XCTAssertEqual(pet.brain.mood, .hungry)
        pet.run(to: 4.5 * 3600 + 10)
        XCTAssertEqual(pet.brain.mood, .famished)
        pet.run(to: 6 * 3600)
        XCTAssertEqual(pet.meter(at: 6 * 3600), 100, accuracy: 1e-9)
        XCTAssertEqual(pet.brain.mood, .famished, "nothing happens at 100 but staying Famished")
        XCTAssertEqual(pet.behaviour(at: 6 * 3600), .idle(.famished))
    }

    /// The meter crosses 90 while the pet waits: the brain's tick lands the change exactly, within one step
    /// of the rig, and the words say so.
    func testTheTickLandsOnNinety() {
        var pet = PetHarness(hunger: 89)
        pet.accounts[0].five = 10
        pet.start()
        pet.run(to: 400)
        XCTAssertEqual(pet.behaviour(at: 170), .idle(.hungry))
        let famished = try? XCTUnwrap(pet.played(0...400).first { $0.behaviour == .idle(.famished) })
        // One point of hunger takes 3 minutes at the full rate.
        XCTAssertEqual(famished?.start ?? 0, 180.0, accuracy: PetTuning.Secondary.step)
        let status = pet.brain.status(at: pet.time(400))
        XCTAssertEqual(status.situation, .awake(mood: .famished))
        XCTAssertEqual(PetText.header(status, now: pet.time(400).wall, timeZone: TimeZone(identifier: "UTC")!,
                                      calendar: Calendar(identifier: .gregorian)).word, "Famished")
    }

    /// Stuffed is left by time alone, when the meter rises above −30: from the floor, an hour of hunger time.
    func testStuffedWearsOffWithinAnHourFromTheFloor() {
        var pet = PetHarness(hunger: -50)
        pet.accounts[0].five = 10
        pet.accounts[0].fiveReset = 3 * 3600
        pet.start()
        XCTAssertEqual(pet.behaviour(at: 0), .idle(.stuffed))
        pet.run(to: 3700)
        let full = try? XCTUnwrap(pet.played(0...3700).first { $0.behaviour == .idle(.full) })
        XCTAssertEqual(full?.start ?? 0, 3600, accuracy: 0.05, "20 points an hour from −50 to above −30")
    }

    // MARK: - pet.json

    /// Nothing new is saved: a restored pet takes the end its H gives, and the file is the same version.
    func testARestoredPetTakesTheEndItsHungerGives() {
        func restored(_ hunger: Double) -> PetBrain {
            var save = PetSave(seed: 1, bornAt: Date(timeIntervalSince1970: 0))
            save.hunger = hunger
            return PetBrain(restoring: save)
        }
        XCTAssertEqual(restored(-30).mood, .stuffed)
        XCTAssertEqual(restored(-29.9).mood, .full)
        XCTAssertEqual(restored(90).mood, .famished)
        XCTAssertEqual(restored(89.9).mood, .hungry)
        let save = restored(-42).save(at: PetTime(wall: Date(timeIntervalSince1970: 100), mono: 100))
        XCTAssertEqual(save.v, PetTuning.Store.version)
        XCTAssertEqual(save.hunger, -42, accuracy: 1e-9)
    }

    // MARK: - Meals

    /// What follows a meal: a nibble's lick, the grateful meal for a full meal or a feast eaten famished, a
    /// feast's own, the brim for a full meal that leaves it stuffed, and the plain one otherwise.
    func testTheSatisfactionTable() {
        func after(_ size: PetMeal.Size, feast: Bool = false, planned: PetMood, leaves: PetMood) -> PetBehaviour.Satisfaction {
            var brain = PetBrain(seed: 1)
            brain.mood = leaves
            let meal = PetMeal(size: size, chews: 3, feast: feast, points: feast ? 9 : 3, reduceMotion: false, mood: planned)
            return brain.satisfaction(after: meal)
        }
        XCTAssertEqual(after(.full, planned: .full, leaves: .stuffed), .brim)
        XCTAssertEqual(after(.full, planned: .content, leaves: .content), .meal)
        XCTAssertEqual(after(.nibble, planned: .stuffed, leaves: .stuffed), .lick)
        XCTAssertEqual(after(.nibble, planned: .famished, leaves: .hungry), .lick)
        XCTAssertEqual(after(.full, planned: .famished, leaves: .hungry), .grateful)
        XCTAssertEqual(after(.full, planned: .famished, leaves: .famished), .grateful)
        XCTAssertEqual(after(.full, feast: true, planned: .famished, leaves: .peckish), .grateful)
        XCTAssertEqual(after(.full, feast: true, planned: .content, leaves: .stuffed), .feast)
        XCTAssertEqual(after(.full, feast: true, planned: .full, leaves: .full), .feast)
    }

    /// A full meal that leaves it stuffed: the brim, then stuffed at rest. The meal was planned in the mood
    /// before the food reached the meter.
    func testAFullMealThatLeavesItStuffedIsTheBrim() throws {
        var pet = PetHarness(hunger: -10)
        pet.accounts[0].five = 10
        pet.start()
        pet.accounts[0].five = 15
        pet.refresh(at: 20)
        pet.run(to: 40)
        let played = pet.played(0...40).map(\.behaviour)
        guard case .eat(let meal)? = played.first(where: { if case .eat = $0 { return true }; return false }) else {
            return XCTFail("no meal: \(played)")
        }
        XCTAssertEqual(meal.mood, .full)
        XCTAssertTrue(played.contains(.satisfied(.brim)), "\(played)")
        XCTAssertEqual(played.last, .idle(.stuffed))
    }

    /// A meal eaten famished is the grateful one, whatever it leaves the pet in: 3 points take 96 to 78.
    func testAMealEatenFamishedIsGrateful() throws {
        var pet = PetHarness(hunger: 96)
        pet.accounts[0].five = 10
        pet.start()
        pet.accounts[0].five = 13
        pet.refresh(at: 20)
        pet.run(to: 40)
        let played = pet.played(0...40).map(\.behaviour)
        guard case .eat(let meal)? = played.first(where: { if case .eat = $0 { return true }; return false }) else {
            return XCTFail("no meal: \(played)")
        }
        XCTAssertEqual(meal.mood, .famished)
        XCTAssertTrue(played.contains(.satisfied(.grateful)), "\(played)")
        XCTAssertEqual(played.last, .idle(.hungry), "Famished is left only by food")
        XCTAssertEqual(pet.meter(at: 40), 96 + 40 * PetTuning.Hunger.perHour / 3600 - 18, accuracy: 1e-6)
    }

    /// A nibble at either end is a lick, as anywhere: the second meal within ten minutes of the first.
    func testANibbleAtEitherEndIsALick() {
        for (hunger, first, mood) in [(-45.0, 3.0, PetMood.stuffed), (100, 1, .famished)] {
            var pet = PetHarness(hunger: hunger)
            pet.accounts[0].five = 10
            pet.start()
            pet.accounts[0].five = 10 + first
            pet.refresh(at: 20)
            pet.accounts[0].five = 10 + first + 0.6
            pet.refresh(at: 80)
            pet.run(to: 100)
            let played = pet.played(60...100).map(\.behaviour)
            guard case .eat(let nibble)? = played.first(where: { if case .eat = $0 { return true }; return false }) else {
                return XCTFail("\(mood): no nibble: \(played)")
            }
            XCTAssertEqual(nibble.size, .nibble)
            XCTAssertEqual(nibble.mood, mood)
            XCTAssertTrue(played.contains(.satisfied(.lick)), "\(mood): \(played)")
            XCTAssertEqual(played.last, .idle(mood))
        }
    }

    /// The meal that fills the 5-hour window goes straight into the yawn, however full; the hunger clock
    /// stands while it sleeps, so after the reset it wakes as stuffed as it fell asleep.
    func testItWakesAsStuffedAsItFellAsleep() {
        var pet = PetHarness(hunger: -20)
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 90, fiveReset: 600)]
        pet.start()
        pet.accounts[0].five = 100
        pet.refresh(at: 20)
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 600 + 5 * 3600
        pet.refresh(at: 600)
        pet.run(to: 620)
        let played = pet.played(0...620).map(\.behaviour)
        XCTAssertTrue(played.contains(.fallAsleep), "\(played)")
        XCTAssertFalse(played.contains(.satisfied(.brim)), "the yawn, not the brim: \(played)")
        XCTAssertEqual(played.last, .idle(.stuffed), "\(played)")
    }

    // MARK: - Stuffed, the look

    let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))

    static func stuffed(_ hunger: Double = -46) -> PetReelScript { PetReelScript([(0, .idle(.stuffed))], hunger: hunger) }

    /// The gestures an idle that started at 0 plays in its first `span` seconds.
    static func gestures(_ behaviour: PetBehaviour, span: Double, seed: UInt64 = 7) -> [PetRigMoodBeats.Gesture] {
        PetRigMoodBeats.gestures(in: PetSegment(start: 0, behaviour: behaviour), previous: nil, at: span, lookBack: span,
                                 seed: seed, reduceMotion: false)
    }

    static func scene(_ script: PetReelScript, at t: Double, zones: PetZones, seed: UInt64 = 7,
                      motion: PetMotion = PetMotion()) -> PetRigPoser {
        PetRigPoser(timeline: script.timeline, t: t, pointer: PetPointerTrack(), zone: zones.strip!, seed: seed, motion: motion,
                    memo: PetRigMemo(), flight: nil, flightSource: nil, lookAt: nil)
    }

    /// At rest, between its gestures, stuffed is blissful and never sleepy: eyes shut in happy arcs but
    /// when they open out of their bliss, no blink while they are shut, the brows up and easy, a wide smile.
    func testStuffedAtRestIsBlissfulNeverSleepy() {
        let rig = PetRig()
        let script = Self.stuffed()
        let gestures = Self.gestures(.idle(.stuffed), span: 610)
        var shut = 0, open = 0
        for n in 0..<(600 * 10) {
            let t = 5 + Double(n) / 10
            guard !gestures.contains(where: { $0.at - 0.25 < t && t < $0.end + 0.25 }) else { continue }
            let p = script.pose(rig, at: t, zones: zones).pet
            XCTAssertGreaterThanOrEqual(min(p.browLiftL, p.browLiftR), 0.3, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.smile, 0.8, "t = \(t)")
            XCTAssertLessThanOrEqual(abs(p.lidSlant), 0.001, "t = \(t)")
            if p.happy >= PetCanvas.happyBand.upperBound {
                shut += 1
                XCTAssertGreaterThanOrEqual(min(p.lidL, p.lidR), 0.9, "t = \(t): no blink while the eyes are shut")
            } else {
                open += 1
                let opening = PetRigMoodBeats.blissOpen(beat: PetRigBeat(segments: script.timeline.segments, index: 0, t: t),
                                                        scene: Self.scene(script, at: t, zones: zones))
                XCTAssertGreaterThan(opening.eyes, 0, "t = \(t): open only out of bliss")
            }
        }
        let share = Double(open) / Double(shut + open)
        XCTAssertEqual(share, 0.2, accuracy: 0.07, "the eyes open about a fifth of the time")
    }

    /// Rounder and wider than Full, with a belly that bulges low and feet set wider, and its light up.
    func testStuffedIsRounderThanFull() {
        let rig = PetRig()
        let full = PetReelScript([(0, .idle(.full))], hunger: -20).pose(rig, at: 9, zones: zones).pet
        let stuffed = Self.stuffed().pose(rig, at: 9, zones: zones).pet
        func width(_ body: PetBody) -> Double {
            let xs = PetBodyGeometry(body).outlinePoints().map { Double($0.x) }
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        func feet(_ body: PetBody) -> Double {
            let g = PetBodyGeometry(body)
            return abs(Double(g.foot(1).centre.x - g.foot(-1).centre.x))
        }
        XCTAssertGreaterThan(width(stuffed), width(full) + 3, "rounder")
        XCTAssertGreaterThan(feet(stuffed), feet(full) + 1, "feet set wider")
        XCTAssertGreaterThan(stuffed.glow, full.glow)
        XCTAssertGreaterThan(stuffed.fullness, 1.08, "the light over the brim")
    }

    /// The thumbs-up with its wink comes about every three minutes, and the thumb is there only while an arm
    /// is up giving one: never at rest, never in any other beat.
    func testTheThumbIsThereOnlyInAThumbsUp() {
        let rig = PetRig()
        let script = Self.stuffed()
        let okays = Self.gestures(.idle(.stuffed), span: 1810).filter { $0.item == .beat(.okay) }
        XCTAssertGreaterThanOrEqual(okays.count, 6, "about every three minutes over half an hour: \(okays.count)")
        XCTAssertLessThanOrEqual(okays.count, 15)
        var winked = false
        for n in 0..<(1800 * 10) {
            let t = 5 + Double(n) / 10
            let p = script.pose(rig, at: t, zones: zones).pet
            let inside = okays.contains { $0.at < t && t < $0.end }
            if p.thumbL > 0 || p.thumbR > 0 { XCTAssertTrue(inside, "t = \(t): a thumb outside a thumbs-up") }
            if p.thumbR > 0.9, p.winkR > 0.9 { winked = true }
            XCTAssertEqual(p.thumbL, 0, "beside, the thumb is on the side away from the readout")
        }
        XCTAssertTrue(winked)
    }

    /// The thumbs-up grins, open-mouthed, wider than it smiles at rest. A mouth only just open is drawn as a
    /// thin flat sliver, pressed lips that read as a smirk: through the hold the mouth is open into a grin.
    func testTheThumbsUpGrins() {
        let rig = PetRig()
        let script = Self.stuffed()
        let okays = Self.gestures(.idle(.stuffed), span: 610).filter { $0.item == .beat(.okay) }
        XCTAssertFalse(okays.isEmpty)
        for okay in okays {
            // The arm is up from 0.75 s, held for a second.
            for n in 0...10 {
                let t = okay.at + 0.8 + Double(n) * 0.09
                let p = script.pose(rig, at: t, zones: zones).pet
                XCTAssertGreaterThanOrEqual(p.mouthOpen, 0.3, "t = \(t): a grin, not pressed lips")
                XCTAssertGreaterThan(p.smile, PetPosture.stuffed.body.smile, "t = \(t): wider than at rest")
            }
        }
    }

    /// The pat-pat is seen, at real size too: both nubs come in across the round belly, their tips well in
    /// from where they rest, and lift off it and land on it twice before they go back. A swing a little
    /// further in from the side of the belly barely moved the outline.
    func testThePatHoldsTheBellyAndPatsIt() throws {
        let rig = PetRig()
        let script = Self.stuffed()
        let pat = try XCTUnwrap(Self.gestures(.idle(.stuffed), span: 610).first { $0.item == .beat(.pat) })
        func tips(_ t: Double) -> [CGPoint] {
            let g = PetBodyGeometry(script.pose(rig, at: t, zones: zones).pet)
            return [-1.0, 1.0].map { side in
                let a = g.arm(side)
                return CGPoint(x: a.centre.x + cos(a.angle) * a.length / 2, y: a.centre.y + sin(a.angle) * a.length / 2)
            }
        }
        let rest = tips(pat.at - 0.05), held = tips(pat.at + 0.75)
        XCTAssertGreaterThan(held[0].x - rest[0].x, 3, "the left nub across the belly")
        XCTAssertGreaterThan(rest[1].x - held[1].x, 3, "the right nub across the belly")
        let p = PetRigMoodBeats.idlePat
        for c in p.taps {
            let up = tips(pat.at + c - p.tapTime), down = tips(pat.at + c)
            for side in 0..<2 {
                XCTAssertGreaterThan(down[side].y - up[side].y, 0.5, "a tap at \(c): off the belly and onto it")
            }
        }
        XCTAssertEqual(tips(pat.end + 0.1)[1].x, rest[1].x, accuracy: 0.6, "and back")
    }

    /// The belly is the meter's: none above −26, 0.59 where the pet becomes stuffed, full from −42, and it
    /// rounds out as the meal that makes it stuffed lands. Curled up asleep it is gone: the loaf keeps its
    /// shape.
    func testTheBellyFollowsTheMeterAndNotTheLoaf() {
        XCTAssertEqual(PetRigMeter.belly(-26), 0)
        XCTAssertEqual(PetRigMeter.belly(-30), 0.156, accuracy: 0.001)
        XCTAssertEqual(PetRigMeter.belly(-35), 0.593, accuracy: 0.001)
        XCTAssertEqual(PetRigMeter.belly(-42), 1)
        XCTAssertEqual(PetRigMeter.belly(-50), 1)
        let rig = PetRig()
        let asleep = PetReelScript([(0, .idle(.stuffed)), (1, .fallAsleep), (1 + PetTuning.Behaviour.fallAsleep, .asleep)],
                                   hunger: -50)
        XCTAssertEqual(asleep.pose(rig, at: 9, zones: zones).pet.belly, 0, "asleep at the limit, the loaf as ever")
        let meal = PetMeal(size: .full, chews: 3, feast: false, points: 6, reduceMotion: false, mood: .full)
        var script = PetReelScript([(0, .idle(.full)), (2, .eat(meal)), (2 + meal.duration, .satisfied(.brim))], hunger: -10)
        script.meter(2 + meal.swallowStart, -46)
        XCTAssertLessThan(script.pose(rig, at: 2 + meal.swallowStart, zones: zones).pet.belly, 0.01)
        XCTAssertGreaterThan(script.pose(rig, at: 2 + meal.duration + 0.5, zones: zones).pet.belly, 0.8)
    }

    /// Eating stuffed keeps the meal's beats to the frame, leans for the food rather than leaping, and the
    /// swallowed light carries no tint of the number's dot.
    func testEatingStuffedKeepsTheBeatsAndLeansLazily() {
        let rig = PetRig()
        func script(_ mood: PetMood, _ hunger: Double, after: Double) -> PetReelScript {
            let meal = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: mood)
            var s = PetReelScript([(0, .idle(mood)), (10, .eat(meal)), (10 + meal.duration, .satisfied(.meal))], hunger: hunger)
            s.meter(10 + meal.swallowStart, after)
            return s
        }
        let m = PetRigActions.timing(PetReelScript.meal(.full, chews: 3))
        let plain = script(.content, 30, after: 12), lazy = script(.stuffed, -40, after: -50)
        func pose(_ s: PetReelScript, _ e: Double) -> PetBody { s.pose(rig, at: 10 + e, zones: zones).pet }
        let anchor = Double(zones.strip!.anchor.x)
        for s in [plain, lazy] {
            XCTAssertGreaterThan(pose(s, m.snap - 1.0 / 60).mouthOpen, 0.6, "the mouth wide before the snap")
            XCTAssertLessThan(pose(s, m.snap + 2.0 / 60).mouthOpen, 0.1, "shut on the bite")
            XCTAssertEqual(pose(s, m.chewStart + 0.1).x, anchor, accuracy: 1.6, "back on its seat for the chews")
            XCTAssertGreaterThanOrEqual(pose(s, m.swallowStart + 0.15).lump, 0, "the swallow on time")
        }
        let peak = m.anticipation + m.lunge * 0.6
        XCTAssertLessThan(pose(lazy, peak).lift, pose(plain, peak).lift - 0.5, "stuffed hardly leaves the ground")
        XCTAssertGreaterThan(pose(lazy, m.snap).x, pose(plain, m.snap).x + 1.5, "and reaches less far")
        XCTAssertEqual(pose(lazy, m.swallowStart + 0.15).lumpTint, 0, "no green at a stuffed mouth")
        XCTAssertEqual(pose(plain, m.swallowStart + 0.15).lumpTint, 1)
        // The meal that makes it stuffed is untinted too.
        let into = script(.full, -20, after: -40)
        XCTAssertEqual(pose(into, m.swallowStart + 0.15).lumpTint, 0)
    }

    /// One gesture at a time: over an hour of stuffed idle no two gestures overlap, and every beat comes.
    func testStuffedGesturesNeverOverlap() {
        for seed: UInt64 in [7, 1_311_768_467_294_899_695] {
            let all = Self.gestures(.idle(.stuffed), span: 3600, seed: seed)
            for (a, b) in zip(all, all.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.at, "seed \(seed): \(a) and \(b)") }
            for beat: PetRigMoodBeats.Beat in [.pat, .sigh, .roomForMore, .okay, .hiccup] {
                XCTAssertTrue(all.contains { $0.item == .beat(beat) }, "seed \(seed): \(beat) within the hour")
            }
        }
    }

    /// Out of stuffed by time, the eyes open on their own quick clock while the rest settles over 2 s: never
    /// two eye drawings at once for more than two frames at 30 fps.
    func testStuffedSettlesIntoFullWithoutADoubleEye() {
        XCTAssertEqual(PetRigActions.blendIn(.idle(.full), after: .idle(.stuffed)), 2.0)
        let script = PetReelScript([(0, .idle(.stuffed)), (20, .idle(.full))], hunger: -30)
        let rig = PetRig()
        var run = 0, longest = 0
        for n in 0..<(4 * 30) {
            let happy = script.pose(rig, at: 19.5 + Double(n) / 30, zones: zones).pet.happy
            run = happy > PetCanvas.happyBand.lowerBound && happy < PetCanvas.happyBand.upperBound ? run + 1 : 0
            longest = max(longest, run)
        }
        XCTAssertLessThanOrEqual(longest, 2)
    }

    /// The same instant of a stuffed timeline with a meal, the brim and the beats is one frame whatever was
    /// posed before.
    func testStuffedFramesAreTheSameWhateverWasPosedBefore() {
        let more = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .stuffed)
        var script = PetReelScript([(0, .idle(.stuffed)), (300, .eat(more)), (300 + more.duration, .satisfied(.brim)),
                                    (303 + more.duration, .idle(.stuffed))], hunger: -40)
        script.meter(300 + more.swallowStart, -50)
        let times = stride(from: 280.0, to: 330.0, by: 0.37).map { $0 }
        let forward = PetRig()
        let sequential = times.map { script.pose(forward, at: $0, zones: zones) }
        let backward = PetRig()
        for (t, frame) in zip(times, sequential).reversed() {
            XCTAssertEqual(script.pose(backward, at: t, zones: zones), frame, "t = \(t)")
        }
    }

    // MARK: - Famished, the look

    static func famished(_ hunger: Double = 96) -> PetReelScript { PetReelScript([(0, .idle(.famished))], hunger: hunger) }

    /// At rest, between its gestures, famished is up and hopeful: the brows high and level, smiling, leaning
    /// toward the number, the near nub held higher than the far one, the eyes big and shining.
    func testFamishedAtRestLeansInHopefully() {
        let rig = PetRig()
        let script = Self.famished()
        let gestures = Self.gestures(.idle(.famished), span: 610)
        let anchor = Double(zones.strip!.anchor.x)
        for n in 0..<(600 * 10) {
            let t = 5 + Double(n) / 10
            guard !gestures.contains(where: { $0.at - 0.25 < t && t < $0.end + 0.25 }) else { continue }
            let p = script.pose(rig, at: t, zones: zones).pet
            XCTAssertLessThanOrEqual(max(p.browTiltL, p.browTiltR), 0.05, "t = \(t): level brows, never a pleading slope")
            XCTAssertGreaterThanOrEqual(p.smile, 0.4, "t = \(t)")
            XCTAssertLessThan(p.x, anchor - 0.6, "t = \(t): a step toward the number, on the left")
            XCTAssertLessThan(p.lean, 0, "t = \(t): leaning toward it")
            XCTAssertGreaterThan(p.armL, p.armR + 0.2, "t = \(t): the near nub reaching")
            XCTAssertGreaterThanOrEqual(p.eyeSize, 1.25, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.shine, 0.95, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.squash, 0.99, "t = \(t): up on its toes, never lower")
        }
    }

    /// Famished is never sad, through every gesture: the outer lids never droop, it always smiles, its eyes
    /// stay big, no tongue rests out; and its tummy grumbles and it licks.
    func testFamishedIsHopefulNeverSad() {
        let rig = PetRig()
        let script = Self.famished()
        var grumbles = 0, licks = 0, tongueOut = 0
        for n in 0..<(600 * 10) {
            let t = 5 + Double(n) / 10
            let frame = script.pose(rig, at: t, zones: zones)
            let p = frame.pet
            XCTAssertLessThanOrEqual(p.lidSlant, 0.001, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.smile, 0.3, "t = \(t)")
            XCTAssertGreaterThanOrEqual(p.eyeSize, 1.2, "t = \(t)")
            // A sheepish moment after a pounce that falls short lifts the inner brows a little, briefly.
            XCTAssertLessThanOrEqual(max(p.browTiltL, p.browTiltR), 0.3, "t = \(t): no sad slope")
            if frame.particles.contains(where: { $0.kind == .rumble }) { grumbles += 1 }
            if p.tongue > 0.5 { licks += 1 }
            if p.tongue > 0.05 { tongueOut += 1 }
        }
        XCTAssertGreaterThan(grumbles, 0)
        XCTAssertGreaterThan(licks, 0)
        XCTAssertLessThan(Double(tongueOut) / 6000, 0.1, "the tongue only for a lick")
    }

    /// Leaning in, famished turns its whole face to the number, so its big eyes stay over its smile rather
    /// than sliding across the face onto it: over ten minutes at rest the smile sits under the middle of its
    /// eyes at least as well as hungry's does, beside the notch and under it.
    func testFamishedTurnsItsWholeFaceToTheNumber() {
        func offset(_ mood: PetMood, hunger: Double, _ placement: EarsPlacement) -> Double {
            let zones = PetStage.zones(PetStage.frames(placement), PetStage.aggregate(left: 41))
            let rig = PetRig()
            let script = PetReelScript([(0, .idle(mood))], hunger: hunger)
            let gestures = Self.gestures(.idle(mood), span: 610)
            var sum = 0.0, count = 0
            for n in 0..<(600 * 10) {
                let t = 5 + Double(n) / 10
                guard !gestures.contains(where: { $0.at - 0.25 < t && t < $0.end + 0.25 }) else { continue }
                let p = script.pose(rig, at: t, zones: zones).pet
                let g = PetBodyGeometry(p)
                let middle = Double(g.eye(-1).centre.x + g.eye(1).centre.x) / 2
                sum += abs(Double(g.mouth.p.x) - middle) / p.size
                count += 1
            }
            return sum / Double(count)
        }
        for placement in [EarsPlacement.beside, .below] {
            XCTAssertLessThanOrEqual(offset(.famished, hunger: 96, placement), offset(.hungry, hunger: 80, placement),
                                     "\(placement)")
        }
    }

    /// The tummy grumbles every 25 to 43 s on a schedule of its own; coming up from hungry the first comes
    /// 0.9 s in, or 8 s after a rumble it has just had, and the schedule's own come no sooner than 20 s after
    /// it: never a grumble on the heels of a rumble, nor two at once.
    func testTheTummyGrumblesOnItsOwnSchedule() {
        let segment = PetSegment(start: 0, behaviour: .idle(.famished))
        let times = PetRigMoodBeats.grumbleTimes(in: segment, previous: nil, from: 0, to: 3600, seed: 7)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 25 - 1e-9)
            XCTAssertLessThanOrEqual(b - a, 43 + 1e-9)
        }
        let before = PetSegment(start: 0, behaviour: .idle(.hungry))
        var afterARumble = 0
        for seed: UInt64 in [7, 1_311_768_467_294_899_695] {
            for start in stride(from: 3.0, through: 300, by: 7) {
                let into = PetSegment(start: start, behaviour: .idle(.famished))
                let entering = PetRigMoodBeats.grumbleTimes(in: into, previous: before, from: start, to: start + 100, seed: seed)
                let rumbled = PetRigIdle.rumbles.recent(at: start + 0.9, lookBack: 8, seed: seed).map(\.at).filter { $0 > 1.5 }.max()
                if rumbled != nil { afterARumble += 1 }
                let first = max(start + 0.9, (rumbled ?? -.infinity) + 8)
                XCTAssertEqual(entering.first ?? 0, first, accuracy: 1e-9, "seed \(seed), from \(start): the entrance comes first")
                XCTAssertGreaterThanOrEqual((entering.dropFirst().first ?? .infinity) - first, 20, "seed \(seed), from \(start)")
            }
        }
        XCTAssertGreaterThan(afterARumble, 0, "some come up just after a rumble")
    }

    /// Please: the shining eyes leave the number for the viewer and both nubs come in to the cheeks, to
    /// −1.9 whatever they were; two quick happy squints, and no blink in it, or in a grumble.
    func testPleaseBringsTheNubsToTheCheeksAndHoldsTheEyesWide() {
        let rig = PetRig()
        let script = Self.famished()
        let gestures = Self.gestures(.idle(.famished), span: 900)
        let please = try? XCTUnwrap(gestures.first { $0.item == .beat(.please) })
        guard let please else { return XCTFail("no please in 15 minutes") }
        let held = script.pose(rig, at: please.at + 2.0, zones: zones).pet
        XCTAssertEqual(held.armL, -1.9, accuracy: 0.15)
        XCTAssertEqual(held.armR, -1.9, accuracy: 0.15)
        XCTAssertLessThan(abs(held.lookX), 0.2, "at the viewer")
        var squints = 0, previous = 0.0
        for n in 0..<Int(please.length * 60) {
            let t = please.at + Double(n) / 60
            let p = script.pose(rig, at: t, zones: zones).pet
            if p.happy > 0.9, previous <= 0.9 { squints += 1 }
            previous = p.happy
            XCTAssertGreaterThanOrEqual(min(p.lidL, p.lidR), 0.95, "t = \(t - please.at): no blink in please")
        }
        XCTAssertEqual(squints, 2)
        for grumble in gestures where grumble.item == .beat(.grumble) {
            for n in 0..<Int(grumble.length * 30) {
                let p = script.pose(rig, at: grumble.at + Double(n) / 30, zones: zones).pet
                XCTAssertGreaterThanOrEqual(min(p.lidL, p.lidR), 0.95, "no blink in a grumble")
            }
        }
    }

    /// One gesture at a time: over an hour of famished idle no two gestures overlap, and every beat comes.
    func testFamishedGesturesNeverOverlap() {
        for seed: UInt64 in [7, 1_311_768_467_294_899_695] {
            let all = Self.gestures(.idle(.famished), span: 3600, seed: seed)
            for (a, b) in zip(all, all.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.at, "seed \(seed): \(a) and \(b)") }
            for beat: PetRigMoodBeats.Beat in [.reach, .please, .grumble] {
                XCTAssertTrue(all.contains { $0.item == .beat(beat) }, "seed \(seed): \(beat) within the hour")
            }
        }
    }

    /// The grateful meal keeps the meal's beats, hops for joy at the wind-up, and then hugs itself, eyes
    /// shut, with four sparkles and a bounce; the eyes open shining on the number for more.
    func testTheGratefulMeal() {
        let rig = PetRig()
        let meal = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .famished)
        var script = PetReelScript([(0, .idle(.famished)), (10, .eat(meal)), (10 + meal.duration, .satisfied(.grateful)),
                                    (13 + meal.duration, .idle(.hungry))], hunger: 96)
        script.meter(10 + meal.swallowStart, 78)
        let m = PetRigActions.timing(meal)
        func pose(_ e: Double) -> PetFrame { script.pose(rig, at: 10 + e, zones: zones) }
        XCTAssertGreaterThan(pose(m.anticipation * 0.42).pet.lift, 0.8, "a hop of joy")
        XCTAssertGreaterThan(pose(m.snap - 1.0 / 60).pet.mouthOpen, 0.6)
        XCTAssertLessThan(pose(m.snap + 2.0 / 60).pet.mouthOpen, 0.1)
        XCTAssertGreaterThanOrEqual(pose(m.swallowStart + 0.15).pet.lump, 0)
        let s0 = meal.duration
        let hug = pose(s0 + 1.0).pet
        XCTAssertLessThan(hug.armL, -1.9)
        XCTAssertLessThan(hug.armR, -1.9)
        XCTAssertGreaterThanOrEqual(hug.happy, PetCanvas.happyBand.upperBound, "eyes shut")
        XCTAssertGreaterThan(pose(s0 + 1.12).pet.lift, 0.8, "a happy bounce")
        var sparkles = 0
        for n in 0..<(Int(1.6 * 60)) {
            let count = pose(s0 + Double(n) / 60).particles.filter { $0.kind == .sparkle }.count
            sparkles = max(sparkles, count)
        }
        XCTAssertGreaterThanOrEqual(sparkles, 2)
        let more = pose(s0 + 2.3).pet
        XCTAssertLessThan(more.happy, PetCanvas.happyBand.lowerBound, "the eyes open")
        XCTAssertGreaterThan(more.shine, 0.9, "shining")
        XCTAssertLessThan(more.lookX, -0.2, "on the number")
    }

    // MARK: - Asleep at the 5-hour limit

    /// Asleep at the limit it sleeps sweetly, full and cozy, never bored, sick or worse: the brows rest above
    /// the shut eyes rather than pressing on them, the mouth is a small closed smile, the cheeks warm; the
    /// loaf is the loaf, with no belly, and as low as ever.
    func testAsleepAtTheLimitSmilesInItsSleep() {
        let rig = PetRig()
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 100))
        let script = PetReelScript([(0, .idle(.stuffed)), (1, .fallAsleep), (1 + PetTuning.Behaviour.fallAsleep, .asleep)],
                                   hunger: -50)
        for n in 0..<(120 * 15) {
            let t = 8 + Double(n) / 15
            let frame = script.pose(rig, at: t, zones: zones)
            let p = frame.pet
            XCTAssertGreaterThanOrEqual(min(p.browLiftL, p.browLiftR), -0.05, "t = \(t): the brows off the eyes")
            XCTAssertGreaterThanOrEqual(p.smile, 0.5, "t = \(t)")
            XCTAssertLessThan(p.mouthOpen, 0.02, "t = \(t): a closed mouth, no dark dash")
            XCTAssertGreaterThanOrEqual(p.blush, 0.85, "t = \(t)")
            XCTAssertEqual(p.belly, 0, "t = \(t)")
            XCTAssertLessThanOrEqual(frame.bodyBox.height, PetTuning.Zone.asleepMaxHeight, "t = \(t)")
        }
    }

    // MARK: - The greeting

    /// The greetings the brain cued, by time.
    private func greetings(_ pet: PetHarness) -> [Double] {
        pet.brain.timeline.cues.filter { $0.kind == .greet }.map(\.t)
    }

    /// Opening the panel at an end of the meter cues a greeting 0.6 s later, once the hop has landed; at
    /// most one every 3 minutes, never under Reduce Motion, never when the panel closed first.
    func testThePanelOpeningCuesAGreetingAtEitherEnd() {
        for hunger in [-46.0, 96] {
            var pet = PetHarness(hunger: hunger)
            pet.start()
            pet.send(.panel(open: true), at: 30)
            pet.run(to: 32)
            XCTAssertEqual(greetings(pet), [30.6], "at \(hunger)")
            // Again within three minutes: none.
            pet.send(.panel(open: false), at: 40)
            pet.send(.panel(open: true), at: 100)
            pet.run(to: 102)
            XCTAssertEqual(greetings(pet), [30.6])
            // After three minutes: one.
            pet.send(.panel(open: false), at: 150)
            pet.send(.panel(open: true), at: 220)
            pet.run(to: 222)
            XCTAssertEqual(greetings(pet), [30.6, 220.6])
        }
    }

    /// Only an idle at an end of the meter greets: not content, not eating, not under Reduce Motion, not
    /// when the panel closed again before the hop landed.
    func testOnlyAnIdleAtAnEndGreets() {
        var content = PetHarness(hunger: 20)
        content.start()
        content.send(.panel(open: true), at: 30)
        content.run(to: 32)
        XCTAssertTrue(greetings(content).isEmpty)

        var reduced = PetHarness(hunger: -46)
        reduced.start()
        reduced.send(.motion(PetMotion(reduceMotion: true, reduceTransparency: false, increaseContrast: false)), at: 1)
        reduced.send(.panel(open: true), at: 30)
        reduced.run(to: 32)
        XCTAssertTrue(greetings(reduced).isEmpty)

        var closed = PetHarness(hunger: -46)
        closed.start()
        closed.send(.panel(open: true), at: 30)
        closed.send(.panel(open: false), at: 30.3)
        closed.run(to: 32)
        XCTAssertTrue(greetings(closed).isEmpty)

        var eating = PetHarness(hunger: 96)
        eating.accounts[0].five = 10
        eating.start()
        eating.accounts[0].five = 13
        eating.refresh(at: 30)
        eating.send(.panel(open: true), at: 30.1)
        eating.run(to: 34)
        XCTAssertTrue(greetings(eating).isEmpty, "a meal is under way at 30.7")
    }

    /// The rig plays a greeting as the mood's own gesture, waiting at most 1.5 s for one already playing
    /// to end, or letting it go; two gestures never overlap.
    func testAGreetingWaitsAtMostASecondAndAHalf() throws {
        let all = Self.gestures(.idle(.stuffed), span: 900)
        let pat = try XCTUnwrap(all.first { $0.item == .beat(.pat) && $0.at > 20 })
        let okay = try XCTUnwrap(all.first { $0.item == .beat(.okay) && $0.at > 20 })
        let segment = PetSegment(start: 0, behaviour: .idle(.stuffed))
        func played(cue: Double) -> [PetRigMoodBeats.Gesture] {
            PetRigMoodBeats.gestures(in: segment, previous: nil, at: cue + 10, lookBack: 12, seed: 7, reduceMotion: false,
                                     cues: [PetCue(t: cue, kind: .greet)])
        }
        // During a pat with a second of it left: the thumbs-up comes as it ends.
        let afterPat = played(cue: pat.end - 1.0)
        let greeted = try XCTUnwrap(afterPat.first { $0.item == .beat(.okay) && $0.at > pat.at })
        XCTAssertEqual(greeted.at, pat.end + 0.1, accuracy: 1e-9)
        // During a thumbs-up with most of it left: let go.
        let duringOkay = played(cue: okay.at + 0.2)
        XCTAssertEqual(duringOkay.filter { $0.item == .beat(.okay) }.count, 1, "only the one that was playing")
        for gestures in [afterPat, duringOkay] {
            for (a, b) in zip(gestures, gestures.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.at) }
        }
        // Famished greets with please; a mood that has changed by then, with nothing.
        let famished = PetRigMoodBeats.gestures(in: PetSegment(start: 0, behaviour: .idle(.famished)), previous: nil, at: 400,
                                                lookBack: 5, seed: 7, reduceMotion: false, cues: [PetCue(t: 396, kind: .greet)])
        XCTAssertTrue(famished.contains { $0.item == .beat(.please) && abs($0.at - 396) < 1.6 }, "\(famished)")
        let changed = PetRigMoodBeats.gestures(in: PetSegment(start: 397, behaviour: .idle(.full)),
                                               previous: PetSegment(start: 0, behaviour: .idle(.hungry)), at: 400, lookBack: 5,
                                               seed: 7, reduceMotion: false, cues: [PetCue(t: 396, kind: .greet)])
        XCTAssertTrue(changed.isEmpty)
    }

    /// A beat under way when the mood changes plays on into the next idle instead of vanishing.
    func testABeatPlaysOnAcrossAChangeOfMood() throws {
        let okay = try XCTUnwrap(Self.gestures(.idle(.stuffed), span: 900).first { $0.item == .beat(.okay) })
        let change = okay.at + 1.0
        let script = PetReelScript([(0, .idle(.stuffed)), (change, .idle(.full))], hunger: -30)
        let rig = PetRig()
        let during = script.pose(rig, at: change + 0.3, zones: zones).pet
        XCTAssertGreaterThan(during.thumbR, 0.9, "the thumbs-up goes on")
        XCTAssertGreaterThan(during.armR, 0.8)
        let after = script.pose(rig, at: okay.end + 0.2, zones: zones).pet
        XCTAssertEqual(after.thumbR, 0)
    }

    /// Settled, famished keeps its posture and rumbles at half strength on its own schedule, with none of
    /// the gestures the quiet hours' 10 fps cannot draw.
    func testSettledFamishedOnlyRumbles() {
        XCTAssertTrue(Self.gestures(.settled(.famished), span: 600).isEmpty)
        let rig = PetRig()
        let script = PetReelScript([(0, .settled(.famished))], hunger: 96)
        var tremor = 0.0
        for n in 0..<(300 * 30) {
            let p = script.pose(rig, at: 5 + Double(n) / 30, zones: zones).pet
            tremor = max(tremor, abs(p.tremor))
            XCTAssertGreaterThanOrEqual(p.shine, 0.95)
        }
        XCTAssertGreaterThan(tremor, 0.1, "it rumbles")
        XCTAssertLessThan(tremor, 0.45, "at half strength")
    }
}
