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
}
