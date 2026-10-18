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
}
