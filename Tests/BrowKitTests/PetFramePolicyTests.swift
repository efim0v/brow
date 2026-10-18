// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// Frame scheduling: how fast each behaviour is drawn on power and on battery, under the display options
/// and with the pointer near, and the gates that pause the layer.
final class PetFramePolicyTests: XCTestCase {
    private let meal = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false)

    private func rate(_ behaviour: PetBehaviour, elapsed: TimeInterval = 0, gates: PetFrameGates = PetFrameGates(),
                      _ change: (inout PetFrameConditions) -> Void = { _ in }) -> PetFrameRate {
        var conditions = PetFrameConditions()
        change(&conditions)
        let timeline = PetTimeline(segments: [PetSegment(start: 100, behaviour: behaviour)])
        return PetFramePolicy.rate(timeline, at: 100 + elapsed, gates: gates, conditions: conditions)
    }

    func testIdleIsThirtyFramesASecond() {
        XCTAssertEqual(rate(.idle(.content)), .fps(30))
        XCTAssertEqual(rate(.idle(.content)).minimumInterval ?? 0, 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(rate(.eager), .fps(30))
        XCTAssertEqual(rate(.unsureIdle(.full)), .fps(30))
    }

    func testAsleepIsFifteenAndHibernatingTen() {
        XCTAssertEqual(rate(.asleep), .fps(15))
        XCTAssertEqual(rate(.drowsy), .fps(15))
        XCTAssertEqual(rate(.stirring), .fps(15))
        XCTAssertEqual(rate(.hibernating), .fps(10))
        XCTAssertEqual(rate(.settled(.content)), .fps(10))
    }

    func testAMealIsNativeOnPowerSixtyOnBatteryThirtyInLowPowerMode() {
        XCTAssertEqual(rate(.eat(meal)), .native)
        XCTAssertNil(rate(.eat(meal)).minimumInterval)
        XCTAssertEqual(rate(.eat(meal)) { $0.onAC = false }, .fps(60))
        XCTAssertEqual(rate(.eat(meal)) { $0.lowPower = true }, .fps(30))
        XCTAssertEqual(rate(.eat(meal)) { $0.onAC = false; $0.lowPower = true }, .fps(30))
    }

    func testThePointerNearbyIsSixty() {
        var track = PetPointerTrack()
        track.samples = [PetPointerSample(t: 99.8, location: CGPoint(x: 150, y: 20))]
        let eyes = CGPoint(x: 123.5, y: 13.5)
        XCTAssertTrue(PetFramePolicy.pointerIsNear(track, eyes: eyes, at: 100))
        XCTAssertFalse(PetFramePolicy.pointerIsNear(track, eyes: eyes, at: 100.31), "0.5 s after it last moved")
        XCTAssertFalse(PetFramePolicy.pointerIsNear(track, eyes: CGPoint(x: 400, y: 20), at: 100), "farther than 160 pt")
        XCTAssertEqual(rate(.idle(.hungry)) { $0.pointerNear = true }, .fps(60))
        XCTAssertEqual(rate(.settled(.content)) { $0.pointerNear = true }, .fps(60))
        XCTAssertEqual(rate(.asleep) { $0.pointerNear = true }, .fps(15), "asleep, its eyes do not follow")
    }

    func testReduceMotionIsTenIdleAndThirtyInAction() {
        XCTAssertEqual(rate(.idle(.content)) { $0.reduceMotion = true }, .fps(10))
        XCTAssertEqual(rate(.eat(meal)) { $0.reduceMotion = true }, .fps(30))
        XCTAssertEqual(rate(.celebrate(.goodWeek)) { $0.reduceMotion = true }, .fps(30))
        XCTAssertEqual(rate(.asleep) { $0.reduceMotion = true }, .fps(15))
    }

    func testLowPowerModeIsFifteenIdleAndTenAsleep() {
        XCTAssertEqual(rate(.idle(.content)) { $0.lowPower = true }, .fps(15))
        XCTAssertEqual(rate(.asleep) { $0.lowPower = true }, .fps(10))
        XCTAssertEqual(rate(.hibernating) { $0.lowPower = true }, .fps(10))
    }

    func testTwoToTenMinutesWithoutInputIsTenAtMost() {
        XCTAssertEqual(rate(.idle(.content)) { $0.inputIdle = 300 }, .fps(10))
        XCTAssertEqual(rate(.eat(meal)) { $0.inputIdle = 300 }, .fps(10))
        XCTAssertEqual(rate(.idle(.content)) { $0.inputIdle = 119 }, .fps(30))
    }

    func testEveryClosedGatePausesIt() {
        let closers: [(String, (inout PetFrameGates) -> Void)] = [
            ("display asleep", { $0.displayAsleep() }), ("locked", { $0.unlocked = false }),
            ("session inactive", { $0.sessionActive = false }), ("going to sleep", { $0.systemAwake = false }),
            ("occluded", { $0.windowVisible = false }), ("collapsed with readouts off", { $0.showsPet = false }),
            ("pet off", { $0.petOn = false }), ("away", { $0.present = false }),
        ]
        for (name, close) in closers {
            var gates = PetFrameGates()
            close(&gates)
            XCTAssertEqual(rate(.eat(meal), gates: gates), .paused, name)
            XCTAssertTrue(rate(.eat(meal), gates: gates).paused, name)
        }
        XCTAssertEqual(rate(.doze), .paused, "dozing after the doze-in")
        XCTAssertEqual(rate(.dozeIn), .fps(30))
    }

    func testTheDenIsPausedBetweenPeeksAndSixtyDuringOne() {
        XCTAssertEqual(rate(.denWait), .paused)
        XCTAssertEqual(rate(.peek), .fps(60))
    }

    /// The rate changes at segment starts and inside two behaviours: the wake's shake and the fade out.
    func testTheRateIsReadAgainWhereTheClassChanges() {
        let timeline = PetTimeline(segments: [
            PetSegment(start: 10, behaviour: .wake), PetSegment(start: 12.7, behaviour: .idle(.content)),
            PetSegment(start: 50, behaviour: .off),
        ])
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 10), 12.2)
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 12.2), 12.7)
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 13), 50)
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 50), 50.2)
        XCTAssertNil(PetFramePolicy.nextChange(timeline, after: 50.2))
        let conditions = PetFrameConditions(), gates = PetFrameGates()
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 11, gates: gates, conditions: conditions), .fps(60))
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 12.3, gates: gates, conditions: conditions), .native)
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 50.1, gates: gates, conditions: conditions), .fps(60))
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 50.3, gates: gates, conditions: conditions), .paused)
        XCTAssertEqual(PetFramePolicy.rate(PetTimeline(), at: 0, gates: gates, conditions: conditions), .paused,
                       "nothing planned yet")
    }

    /// A streak milestone's twirl is the fast part of its celebration; the rate is read again where it
    /// starts and where it ends.
    func testAStreaksTwirlIsDrawnFast() {
        let twirl = PetTuning.Behaviour.streakTwirl
        let timeline = PetTimeline(segments: [
            PetSegment(start: 10, behaviour: .celebrate(.streak(days: 3))),
            PetSegment(start: 10 + PetTuning.Behaviour.celebrateStreak, behaviour: .idle(.content)),
        ])
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 10), 10 + twirl.lowerBound)
        XCTAssertEqual(PetFramePolicy.nextChange(timeline, after: 10 + twirl.lowerBound), 10 + twirl.upperBound)
        let conditions = PetFrameConditions(), gates = PetFrameGates()
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 10.5, gates: gates, conditions: conditions), .fps(60))
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 11.3, gates: gates, conditions: conditions), .native)
        XCTAssertEqual(PetFramePolicy.rate(timeline, at: 11.8, gates: gates, conditions: conditions), .fps(60))
    }
}

private extension PetFrameGates {
    mutating func displayAsleep() { displayAwake = false }
}
