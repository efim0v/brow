// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The hunger meter. The arithmetic is tested on `PetHunger` and `PetLimits.pace` directly; when the
/// clock runs, and what the meter shows before a swallow, through the brain.
final class PetHungerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3600

    func testAnHourOfHungerTimeAtAnEvenPaceAddsTwenty() {
        var hunger = PetHunger()
        XCTAssertEqual(hunger.value, 30, "a new pet")
        hunger.pass(hour, pace: 1)
        XCTAssertEqual(hunger.value, 50, accuracy: 1e-9)
    }

    func testFromZeroItIsHungryAfterThreeHoursAndAQuarter() {
        var hunger = PetHunger(value: 0)
        hunger.pass(3.25 * hour, pace: 1)
        XCTAssertEqual(hunger.value, 65, accuracy: 1e-9)
        XCTAssertEqual(PetHunger.mood(hunger.value, from: .peckish), .hungry)
    }

    func testItNeverGoesPastAHundred() {
        var hunger = PetHunger()
        hunger.pass(10 * hour, pace: 1)
        XCTAssertEqual(hunger.value, 100)
    }

    func testFoodTakesSixAPointDownToTheFloor() {
        var hunger = PetHunger(value: 50)
        XCTAssertEqual(hunger.eat(3), 18, accuracy: 1e-9, "the drop the meter holds back")
        XCTAssertEqual(hunger.value, 32, accuracy: 1e-9)
        var empty = PetHunger(value: 0)
        XCTAssertEqual(empty.eat(20), 50, accuracy: 1e-9, "the drop after the floor")
        XCTAssertEqual(empty.value, -50)
    }

    // MARK: - Pace

    /// One account whose weekly window is half gone (it resets in three and a half days), so an even
    /// pace is 50 %.
    private func halfwayThroughTheWeek(used: Double?) -> [PetAccount] {
        [PetAccount(id: "a", weight: 1, reading: PetReading(
            fetchedAt: t0, fiveHour: nil,
            sevenDay: used.map { PetWindow(used: $0, resetAt: t0.addingTimeInterval(3.5 * 86_400)) }))]
    }

    private func anHour(at pace: Double) -> Double {
        var hunger = PetHunger(value: 0)
        hunger.pass(hour, pace: pace)
        return hunger.value
    }

    func testFifteenPointsAheadOfPaceHalvesTheHunger() {
        let accounts = halfwayThroughTheWeek(used: 65)
        XCTAssertEqual(PetLimits.evenPace(accounts, now: t0), 50, accuracy: 1e-9)
        XCTAssertEqual(PetLimits.pace(accounts, now: t0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(anHour(at: PetLimits.pace(accounts, now: t0)), 10, accuracy: 1e-9)
    }

    func testThirtyPointsAheadOrMoreStopsIt() {
        XCTAssertEqual(anHour(at: PetLimits.pace(halfwayThroughTheWeek(used: 80), now: t0)), 0, accuracy: 1e-9)
        XCTAssertEqual(anHour(at: PetLimits.pace(halfwayThroughTheWeek(used: 99), now: t0)), 0, accuracy: 1e-9)
    }

    /// Behind pace near a reset is the nudge to use what resets; it never goes above the base rate.
    func testBehindPaceItGetsHungryAtTheBaseRate() {
        XCTAssertEqual(PetLimits.pace(halfwayThroughTheWeek(used: 30), now: t0), 1)
        XCTAssertEqual(anHour(at: PetLimits.pace(halfwayThroughTheWeek(used: 30), now: t0)), 20, accuracy: 1e-9)
    }

    func testAWeekThatHasNotStartedIsAnEvenPace() {
        XCTAssertEqual(PetLimits.pace(halfwayThroughTheWeek(used: nil), now: t0), 1)
        XCTAssertEqual(PetLimits.pace([], now: t0), 1)
    }

    // MARK: - Moods

    func testMoodsHaveFivePointsOfHysteresis() {
        // Rising into Hungry and falling back out of it.
        var mood = PetHunger.mood(64.9, from: .peckish)
        XCTAssertEqual(mood, .peckish)
        mood = PetHunger.mood(65.0, from: mood)
        XCTAssertEqual(mood, .hungry)
        mood = PetHunger.mood(61.0, from: mood)
        XCTAssertEqual(mood, .hungry)
        mood = PetHunger.mood(59.9, from: mood)
        XCTAssertEqual(mood, .peckish)
        // Rising from −10.
        XCTAssertEqual(PetHunger.mood(0.0, from: .full), .full)
        XCTAssertEqual(PetHunger.mood(0.1, from: .full), .content)
        // Falling from 20.
        XCTAssertEqual(PetHunger.mood(-4.9, from: .content), .content)
        XCTAssertEqual(PetHunger.mood(-5.0, from: .content), .full)
    }

    func testABigMealOrADebugValueCrossesSeveralMoodsAtOnce() {
        XCTAssertEqual(PetHunger.mood(-50, from: .hungry), .full)
        XCTAssertEqual(PetHunger.mood(70, from: .content), .hungry)
    }

    // MARK: - When the clock runs (through the brain)

    func testHungerCountsOnlyTheHoursSomeoneIsAtTheMac() {
        var pet = PetHarness()
        pet.start()
        pet.run(to: hour)
        pet.screenLocked = true
        pet.send(.visible(false), at: hour)
        pet.run(to: 9 * hour)
        pet.screenLocked = false
        pet.send(.visible(true), at: 9 * hour)
        pet.run(to: 10 * hour)
        XCTAssertEqual(pet.brain.hunger.value, 70, accuracy: 0.01, "1 h + 1 h of hunger, not the 8 h between")
    }

    /// Asleep, hibernating, unsure, with no account or with the pet off: the clock stands still.
    func testTheClockStandsStillAtRestAndWithoutFreshNumbers() {
        func anHour(_ setUp: (inout PetHarness) -> Void) -> Double {
            var pet = PetHarness()
            setUp(&pet)
            pet.start()
            pet.run(to: 60)
            let start = pet.brain.hunger.value
            pet.run(to: 60 + hour)
            return pet.brain.hunger.value - start
        }
        XCTAssertEqual(anHour { $0.accounts = [.init(id: "a", five: 100, fiveReset: 9 * 3600)] }, 0, "asleep")
        XCTAssertEqual(anHour { $0.accounts = [.init(id: "a", week: 100)] }, 0, "hibernating")
        XCTAssertEqual(anHour { $0.refreshEvery = nil; $0.accounts = [.init(id: "a", fetchedAt: -600)] }, 0, "unsure")
        XCTAssertEqual(anHour { $0.accounts = [] }, 0, "no accounts")
        var off = PetHarness()
        off.start()
        off.send(.showPet(false), at: 60)
        let before = off.brain.hunger.value
        off.run(to: 60 + hour)
        off.send(.showPet(true), at: 60 + hour)
        XCTAssertEqual(off.brain.hunger.value, before, "the pet off")
    }

    /// Hunger runs on the monotonic clock: a wall clock three hours ahead adds ten seconds of it.
    func testAWallClockJumpAddsOnlyTheMonotonicTime() {
        var pet = PetHarness()
        pet.presenceEvery = nil
        pet.refreshEvery = nil
        pet.start()
        pet.send(.presence(pet.presence(at: 100)), at: 100)
        let before = pet.brain.hunger.value
        pet.wallShift = 3 * hour
        pet.send(.clockChanged, at: 110)
        XCTAssertEqual(pet.brain.hunger.value - before, 0.06, accuracy: 0.005)
    }

    /// The meter waits for the swallow; unseen, it waits for the meal.
    func testTheMeterFallsAtTheSwallowNotAtTheReading() {
        var pet = PetHarness(hunger: 50)
        pet.presenceEvery = nil
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 10)]
        pet.start()
        pet.accounts[0].five = 13
        pet.refresh(at: 0)
        XCTAssertEqual(pet.meter(at: 1.0), 50, accuracy: 0.01)
        XCTAssertEqual(pet.meter(at: 1.61), 50, accuracy: 0.01, "just before the swallow")
        XCTAssertEqual(pet.meter(at: 1.63), 32, accuracy: 0.01, "just after")
        XCTAssertEqual(pet.brain.hunger.value, 32, accuracy: 0.01, "H had it at once")

        var unseen = PetHarness(hunger: 50)
        unseen.accounts = [.init(id: "a", five: 10)]
        unseen.start(visible: false)
        unseen.accounts[0].five = 13
        unseen.refresh(at: 0)
        unseen.run(to: 300)
        XCTAssertEqual(unseen.meter(at: 300), 50 + 300 * 20 / hour, accuracy: 0.01)
    }

    /// A new pet is Content; a restored one takes the mood its H gives on the way up.
    func testWithoutHistoryTheMoodIsTheOneOnTheWayUp() {
        XCTAssertEqual(PetHunger.moodOnTheWayUp(PetTuning.Hunger.newPet), .content)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(0), .full)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(34.9), .content)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(35), .peckish)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(64), .peckish)
        XCTAssertEqual(PetHunger.moodOnTheWayUp(65), .hungry)
    }
}
