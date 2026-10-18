// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// Asleep at the 5-hour limit, hibernating at the weekly one. The aggregate, the wake instants and the
/// rest's own rules are tested here on `PetLimits` and `PetRest`; what the pet plays for each of them,
/// through the brain.
final class PetLimitsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_065_600)     // 2026-10-15 12:00:00 UTC
    private var resetAt1840: Date { t0.addingTimeInterval(6 * 3600 + 40 * 60) }

    private func time(_ seconds: TimeInterval) -> PetTime { PetTime(wall: t0.addingTimeInterval(seconds), mono: seconds) }

    private func account(_ id: String = "a", weight: Double = 1, five: Double?, fiveReset: Date? = nil,
                         week: Double? = nil, weekReset: Date? = nil, fetched: TimeInterval = 0) -> PetAccount {
        PetAccount(id: id, weight: weight, reading: PetReading(
            fetchedAt: t0.addingTimeInterval(fetched),
            fiveHour: five.map { PetWindow(used: $0, resetAt: fiveReset ?? resetAt1840) },
            sevenDay: week.map { PetWindow(used: $0, resetAt: weekReset ?? t0.addingTimeInterval(5 * 86_400)) }))
    }

    /// The 5-hour rest, fed as the brain feeds it.
    private struct Nap {
        var rest = PetRest(afterWake: PetTuning.Limits.sleepAfterWake)
        var accounts: [PetAccount]
        let window: PetWindowKind

        init(_ accounts: [PetAccount], window: PetWindowKind = .fiveHour) {
            self.accounts = accounts
            self.window = window
            if window == .sevenDay { rest = PetRest(afterWake: 0) }
        }

        mutating func update(at time: PetTime, seen: Bool = true) -> PetRest.Change? {
            rest.update(effective: PetLimits.aggregate(accounts, window, now: time.wall),
                        wakeInstant: PetLimits.wakeInstant(accounts, window, now: time.wall),
                        newestFetch: accounts.compactMap { $0.reading?.fetchedAt }.max(), seen: seen, at: time)
        }
    }

    func testOneFullAccountSleepsUntilItsReset() {
        var nap = Nap([account(five: 100)])
        XCTAssertEqual(nap.update(at: time(0)), .rest)
        XCTAssertEqual(nap.rest.wakesAt, resetAt1840)
    }

    /// A Max 20x at 100 % and a Pro at 90 % is 99.52 %: the readout says `100%`, so it sleeps, and it
    /// is the 20x's reset that wakes it.
    func testSeveralAccountsSleepOnlyWhenTheAggregateIsFull() {
        let twentyReset = t0.addingTimeInterval(2 * 3600), proReset = t0.addingTimeInterval(3 * 3600)
        let accounts = [account("max", weight: 20, five: 100, fiveReset: twentyReset),
                        account("pro", weight: 1, five: 90, fiveReset: proReset)]
        XCTAssertEqual(PetLimits.aggregate(accounts, .fiveHour, now: t0) ?? 0, 99.52, accuracy: 0.005)
        var nap = Nap(accounts)
        XCTAssertEqual(nap.update(at: time(0)), .rest)
        XCTAssertEqual(nap.rest.wakesAt, twentyReset)
        // Had the Pro reset first, that alone leaves 95.2 %, under the stay line: its reset wakes it.
        let proFirst = [account("max", weight: 20, five: 100, fiveReset: proReset),
                        account("pro", weight: 1, five: 90, fiveReset: twentyReset)]
        XCTAssertEqual(PetLimits.wakeInstant(proFirst, .fiveHour, now: t0), twentyReset)
        // A Pro and two 20x accounts, all full: the Pro's reset first still leaves 97.6 %, so it is
        // the next one, the first 20x's, that wakes it.
        let first = t0.addingTimeInterval(3600)
        let three = [account("pro", weight: 1, five: 100, fiveReset: first),
                     account("m1", weight: 20, five: 100, fiveReset: twentyReset),
                     account("m2", weight: 20, five: 100, fiveReset: proReset)]
        XCTAssertEqual(PetLimits.wakeInstant(three, .fiveHour, now: t0), twentyReset)
    }

    func testOneFullAccountAmongOthersWithRoomIsNotStuffed() {
        let accounts = [account("max", weight: 20, five: 100), account("five", weight: 5, five: nil)]
        XCTAssertEqual(PetLimits.aggregate(accounts, .fiveHour, now: t0) ?? 0, 80, accuracy: 1e-9)
        var nap = Nap(accounts)
        XCTAssertNil(nap.update(at: time(0)))
        XCTAssertFalse(nap.rest.isResting)
    }

    /// An API 99 after a statusline 100 is jitter: it stays asleep while the aggregate is 97 or more.
    func testJitterDoesNotWakeIt() {
        var nap = Nap([account(five: 100)])
        _ = nap.update(at: time(0))
        nap.accounts = [account(five: 99, fetched: 30)]
        XCTAssertNil(nap.update(at: time(30)))
        nap.accounts = [account(five: 97, fetched: 60)]
        XCTAssertNil(nap.update(at: time(60)))
        XCTAssertTrue(nap.rest.isResting)
    }

    /// At the reset it is drowsy; with no fresh reading it gets up 180 s later.
    func testAResetWithNoReadingIsADrowsyWaitOfThreeMinutes() {
        var nap = Nap([account(five: 100)])
        _ = nap.update(at: time(0))
        let reset = resetAt1840.timeIntervalSince(t0)
        XCTAssertNil(nap.update(at: time(reset - 1)))
        XCTAssertEqual(nap.update(at: time(reset)), .wait)
        XCTAssertEqual(nap.rest.deadline(effective: 0), reset + 180)
        XCTAssertNil(nap.update(at: time(reset + 179)))
        XCTAssertEqual(nap.update(at: time(reset + 180)), .wake(reset: true))
    }

    func testAFreshReadingAfterTheResetEndsTheWaitAtOnce() {
        var nap = Nap([account(five: 100)])
        _ = nap.update(at: time(0))
        let reset = resetAt1840.timeIntervalSince(t0)
        XCTAssertEqual(nap.update(at: time(reset)), .wait)
        nap.accounts = [account(five: 0, fiveReset: resetAt1840.addingTimeInterval(5 * 3600), fetched: reset + 40)]
        XCTAssertEqual(nap.update(at: time(reset + 40)), .wake(reset: true))
    }

    func testAFreshReadingThatStillSaysFullRollsItOver() {
        var nap = Nap([account(five: 100)])
        _ = nap.update(at: time(0))
        let reset = resetAt1840.timeIntervalSince(t0)
        _ = nap.update(at: time(reset))
        let next = resetAt1840.addingTimeInterval(5 * 3600)
        nap.accounts = [account(five: 100, fiveReset: next, fetched: reset + 40)]
        XCTAssertEqual(nap.update(at: time(reset + 40)), .rollOver)
        XCTAssertEqual(nap.rest.wakesAt, next)
    }

    /// An account with room shown 20 s into the sleep takes the aggregate below 97 without a reset:
    /// the pet sleeps out its minute, then gets up with no drowsy wait.
    func testAnExitThatIsNotAResetWaitsOutTheMinimum() {
        var nap = Nap([account("a", five: 100)])
        _ = nap.update(at: time(0))
        nap.accounts = [account("a", five: 100, fetched: 20), account("b", five: 10, fetched: 20)]
        XCTAssertNil(nap.update(at: time(20)))
        XCTAssertEqual(nap.rest.deadline(effective: 55), 60)
        XCTAssertNil(nap.update(at: time(59)))
        XCTAssertEqual(nap.update(at: time(60)), .wake(reset: false))
    }

    /// A reset wakes it whenever it comes, even 20 s after it fell asleep.
    func testAResetHasNoMinimum() {
        let soon = t0.addingTimeInterval(20)
        var nap = Nap([account(five: 100, fiveReset: soon)])
        _ = nap.update(at: time(0))
        XCTAssertEqual(nap.update(at: time(20)), .wait)
    }

    /// It falls asleep again no sooner than 30 s after it woke.
    func testItSleepsAgainNoSoonerThanThirtySecondsAfterAWake() {
        let soon = t0.addingTimeInterval(20)
        var nap = Nap([account(five: 100, fiveReset: soon)])
        _ = nap.update(at: time(0))
        _ = nap.update(at: time(20))
        let next = soon.addingTimeInterval(5 * 3600)
        nap.accounts = [account(five: 0, fiveReset: next, fetched: 21)]
        XCTAssertEqual(nap.update(at: time(21)), .wake(reset: true))
        nap.accounts = [account(five: 100, fiveReset: next, fetched: 31)]
        XCTAssertNil(nap.update(at: time(31)), "10 s after the wake")
        XCTAssertEqual(nap.rest.deadline(effective: 100), 51)
        XCTAssertNil(nap.update(at: time(50.9)))
        XCTAssertEqual(nap.update(at: time(51)), .rest)
    }

    /// Nobody watching, a reset wakes it at once: the stretch is played when it is next seen.
    func testUnseenAResetWakesItWithoutTheWait() {
        var nap = Nap([account(five: 100)])
        _ = nap.update(at: time(0))
        XCTAssertEqual(nap.update(at: time(resetAt1840.timeIntervalSince(t0)), seen: false), .wake(reset: true))
    }

    func testTheWeeklyLimitHibernatesItUntilTheWeeklyReset() {
        let weekly = t0.addingTimeInterval(2 * 86_400)
        var den = Nap([account(five: 40, week: 100, weekReset: weekly)], window: .sevenDay)
        XCTAssertEqual(den.update(at: time(0)), .rest)
        XCTAssertEqual(den.rest.wakesAt, weekly)
        XCTAssertEqual(den.rest.afterWake, 0, "only the 5-hour rest waits after a wake")
    }

    /// A window whose reset has passed is reset, whatever its last reading said.
    func testAThreeDayOldFullReadingWhoseResetPassedIsEmpty() {
        let old = account(five: 100, fiveReset: t0.addingTimeInterval(-3 * 86_400 + 3600), fetched: -3 * 86_400)
        XCTAssertEqual(PetLimits.aggregate([old], .fiveHour, now: t0), 0)
        var nap = Nap([old])
        XCTAssertNil(nap.update(at: time(0)))
    }

    /// Offline, the last reading still stands until its reset.
    func testOfflineTheLastFullReadingKeepsItAsleepUntilItsReset() {
        let reading = account(five: 100, fiveReset: t0.addingTimeInterval(2 * 3600), fetched: -3600)
        var nap = Nap([reading])
        XCTAssertEqual(nap.update(at: time(0)), .rest)
        XCTAssertEqual(nap.rest.wakesAt, t0.addingTimeInterval(2 * 3600))
    }

    /// The two rules for a clock that jumps: a period the pet saw end stays reset when the clock goes
    /// back, and a reading fetched well after its own reset that still reports the window counts (the
    /// Mac's clock is ahead of the server's).
    func testClockJumpsCannotFakeOrHideAFullWindow() {
        let reset = t0.addingTimeInterval(3600)
        let reading = account(five: 100, fiveReset: reset, fetched: 0)
        var food = PetFood()
        _ = food.take([reading])
        _ = food.closeElapsed(now: reset)
        // The clock goes back an hour after the reset passed: the old reading is not full again.
        XCTAssertEqual(PetLimits.aggregate([reading], .fiveHour, now: t0.addingTimeInterval(1800), food: food), 0)
        XCTAssertEqual(PetLimits.aggregate([reading], .fiveHour, now: t0.addingTimeInterval(1800)), 100,
                       "without the tracker it would be")
        // Jumped three hours ahead, a fresh reading still reports the window at 100 %.
        let ahead = account(five: 100, fiveReset: reset, fetched: 3 * 3600 + 3600)
        XCTAssertEqual(PetLimits.aggregate([ahead], .fiveHour, now: t0.addingTimeInterval(4 * 3600), food: food), 100)
        // The endpoint a few seconds late at the boundary is not that.
        let lagging = account(five: 100, fiveReset: reset, fetched: 3600 + 30)
        XCTAssertEqual(PetLimits.aggregate([lagging], .fiveHour, now: t0.addingTimeInterval(3600 + 30)), 0)
    }

    // MARK: - What the pet plays (through the brain)

    private func played(_ pet: PetHarness, _ range: ClosedRange<TimeInterval>) -> [String] {
        pet.played(range).map { segment in
            let name: String
            switch segment.behaviour {
            case .idle(let mood): name = "idle(\(mood))"
            case .leaveDen(let stretch): name = stretch ? "leaveDen" : "leaveDen(short)"
            case .enterDen(let retreat): name = retreat ? "retreat" : "enterDen"
            case .eat: name = "eat"
            case .satisfied: name = "satisfied"
            default: name = "\(segment.behaviour)"
            }
            return "\(name)@\(String(format: "%.1f", segment.start))"
        }
    }

    func testAtTheResetItIsDrowsyThenStretchesThreeMinutesLater() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 200)]
        pet.start()
        pet.run(to: 500)
        XCTAssertEqual(played(pet, 0...500), ["asleep@0.0", "drowsy@200.0", "wake@380.0", "idle(content)@382.7"])
    }

    func testAFreshReadingInTheDrowsyWaitStretchesAtOnce() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 200)]
        pet.start()
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 200 + 5 * 3600
        pet.refresh(at: 240)
        pet.run(to: 300)
        XCTAssertEqual(played(pet, 0...300), ["asleep@0.0", "drowsy@200.0", "wake@240.0", "idle(content)@242.7"])
    }

    /// The weekly reset in the den: it stirs where it lies, a case of its own so the rig keeps it in the
    /// den; a boop there pulses its glow, and the words say the week has reset. With no fresh reading it
    /// comes out 180 s later, and the week it used up is a good week.
    func testAtTheWeeklyResetItStirsInTheDenThenComesOut() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 20, week: 100, weekReset: 300)]
        pet.start()
        pet.send(.boop, at: 320)
        XCTAssertEqual(pet.brain.timeline.cues.map(\.kind), [.glowPulse])
        let status = pet.brain.status(at: pet.time(330))
        XCTAssertEqual(status.situation, .stirring)
        XCTAssertEqual(PetText.header(status, now: pet.time(330).wall, timeZone: TimeZone(identifier: "UTC")!,
                                      calendar: Calendar(identifier: .gregorian)).detail, "The weekly limit has reset")
        pet.run(to: 500)
        XCTAssertEqual(played(pet, 0...500), ["hibernating@0.0", "stirring@300.0", "leaveDen@480.0",
                                              "celebrate(BrowKit.PetBehaviour.Celebration.goodWeek)@483.7",
                                              "idle(content)@486.5"])
    }

    func testAFreshReadingThatStillSaysFullRollsItOverBackToSleep() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 200)]
        pet.start()
        pet.accounts[0].fiveReset = 200 + 5 * 3600
        pet.refresh(at: 240)
        pet.run(to: 300)
        XCTAssertEqual(played(pet, 0...300), ["asleep@0.0", "drowsy@200.0", "rollOver@240.0", "asleep@241.0"])
    }

    /// 20 s into its sleep an account with room is shown: no reset, so it sleeps out its minute and
    /// gets up with no drowsy wait.
    func testAnAccountWithRoomWakesItAfterTheMinuteWithoutDrowsy() {
        var pet = PetHarness()
        pet.accounts = [.init(id: "a", five: 100)]
        pet.start()
        pet.accounts.append(.init(id: "b", five: 10))
        pet.refresh(at: 20)
        pet.run(to: 100)
        XCTAssertEqual(played(pet, 0...100), ["asleep@0.0", "wake@60.0", "idle(content)@62.7"])
    }

    func testAResetTwentySecondsIntoTheSleepIsDrowsyAtOnce() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 20)]
        pet.start()
        pet.run(to: 30)
        XCTAssertEqual(played(pet, 0...30), ["asleep@0.0", "drowsy@20.0"])
    }

    /// Woken, it does not fall asleep again for 30 s, however full the next reading.
    func testItFallsAsleepNoSoonerThanThirtySecondsAfterWaking() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 20)]
        pet.start()
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 20 + 5 * 3600
        pet.refresh(at: 21)                             // awake at 21
        pet.accounts[0].five = 100
        pet.refresh(at: 31)
        pet.run(to: 80)
        // The new period's 100 points are a meal while it is still awake; the yawn waits for 51.
        XCTAssertEqual(played(pet, 0...80), ["asleep@0.0", "drowsy@20.0", "wake@21.0", "idle(content)@23.7",
                                             "eat@31.0", "satisfied@33.4", "idle(full)@37.4",
                                             "fallAsleep@51.0", "asleep@53.6"])
    }

    /// Both limits used up: it hibernates (the weekly rest outranks the 5-hour one), and when the
    /// week resets with the 5-hour still full it comes out of the den and lies down asleep, no yawn.
    func testHibernationOutranksSleepAndLeavesTheDenAsleep() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 9 * 3600, week: 100, weekReset: 300)]
        pet.start()
        XCTAssertEqual(pet.brain.condition, .hibernating)
        XCTAssertEqual(pet.brain.den.wakesAt, pet.t0.addingTimeInterval(300))
        pet.accounts[0].week = 5
        pet.accounts[0].weekReset = 300 + 7 * 86_400
        pet.refresh(at: 330)
        pet.run(to: 400)
        XCTAssertEqual(played(pet, 0...400), ["hibernating@0.0", "stirring@300.0", "leaveDen(short)@330.0", "asleep@331.6"])
        XCTAssertEqual(pet.brain.condition, .asleep)
    }

    func testNoReadingsNoAggregateAndNoWakeInstant() {
        XCTAssertNil(PetLimits.aggregate([], .fiveHour, now: t0))
        XCTAssertNil(PetLimits.aggregate([PetAccount(id: "a", weight: 1, reading: nil)], .fiveHour, now: t0))
        XCTAssertNil(PetLimits.wakeInstant([account(five: 50)], .fiveHour, now: t0), "not full")
        XCTAssertNil(PetLimits.wakeInstant([account(five: 100, fiveReset: nil).undated], .fiveHour, now: t0),
                     "an undated full window never resets by the clock")
    }
}

private extension PetAccount {
    var undated: PetAccount {
        var copy = self
        copy.reading?.fiveHour?.resetAt = nil
        return copy
    }
}
