// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import BrowKit

/// What counts as food. Times are seconds after `t0`; one account of weight 1 unless a case says
/// otherwise.
final class PetFoodTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// One visible account's reading. The 5-hour window resets an hour after `t0` and the weekly one
    /// five days after, unless a case moves them.
    private func account(_ id: String = "a", weight: Double = 1, five: Double? = nil,
                         fiveReset: TimeInterval? = 3600, week: Double? = nil,
                         weekReset: TimeInterval? = 5 * 86_400, fetched: TimeInterval = 0) -> PetAccount {
        PetAccount(id: id, weight: weight, reading: PetReading(
            fetchedAt: at(fetched),
            fiveHour: five.map { PetWindow(used: $0, resetAt: fiveReset.map(at)) },
            sevenDay: week.map { PetWindow(used: $0, resetAt: weekReset.map(at)) }))
    }

    func testTheFirstReadingIsASilentBaseline() {
        var food = PetFood()
        XCTAssertEqual(food.take([account(five: 41)]).points, 0)
        XCTAssertEqual(food.trackers["a"]?.fiveHour, PetPeriod(resetAt: at(3600), high: 41))
    }

    func testGrowthInTheSamePeriodIsFood() {
        var food = PetFood()
        _ = food.take([account(five: 41)])
        XCTAssertEqual(food.take([account(five: 44, fetched: 30)]).points, 3, accuracy: 1e-9)
    }

    /// A statusline 43 beside the endpoint's 44 is jitter: nothing is un-eaten, and the high-water mark
    /// holds until a reading passes it.
    func testJitterIsIgnoredAndTheHighWaterMarkHolds() {
        var food = PetFood()
        _ = food.take([account(five: 44)])
        XCTAssertEqual(food.take([account(five: 43, fetched: 10)]).points, 0)
        XCTAssertEqual(food.trackers["a"]?.fiveHour?.high, 44)
        XCTAssertEqual(food.take([account(five: 45, fetched: 20)]).points, 1, accuracy: 1e-9)
        XCTAssertEqual(food.trackers["a"]?.fiveHour?.high, 45)
    }

    /// Everything used since a reset is new, and the period before it is over.
    func testANewPeriodEatsItsWholeReadingAndClosesTheOldOne() {
        var food = PetFood()
        _ = food.take([account(five: 80)])
        let intake = food.take([account(five: 3, fiveReset: 3600 + 5 * 3600, fetched: 3700)])
        XCTAssertEqual(intake.points, 3, accuracy: 1e-9)
        XCTAssertEqual(intake.closes, [PetPeriodClose(account: "a", window: .fiveHour, resetAt: at(3600), high: 80)])
        XCTAssertEqual(food.trackers["a"]?.fiveHour, PetPeriod(resetAt: at(3600 + 5 * 3600), high: 3))
    }

    /// The endpoint dates a reset a fraction of a second before the boundary it means; through the
    /// panel's rounding and the 600 s rule, both spellings are one period.
    func testAResetAFractionOfASecondEarlyIsTheSamePeriod() throws {
        func row(_ used: Double, _ resetsAt: String, fetched: TimeInterval) -> AccountRow {
            let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: nil, configDir: "/tmp/brow-tests/a",
                                            aliasDirs: [], tokenExpiresAt: nil)
            let snapshot = LimitSnapshot(organizationUuid: "org", fetchedAt: at(fetched),
                                         fiveHour: CapturedWindow(usedPercentage: used, resetsAt: resetsAt),
                                         sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
            return AccountRow(account: account, name: "a", snapshot: snapshot, status: .ok, tokenStatus: "valid")
        }
        var food = PetFood()
        _ = food.take([PetAccount(row: row(20, "2023-11-15T00:59:59.641069+00:00", fetched: 0))])
        let intake = food.take([PetAccount(row: row(23, "2023-11-15T01:00:00Z", fetched: 60))])
        XCTAssertEqual(intake.points, 3, accuracy: 1e-9)
        XCTAssertEqual(intake.closes, [])
        // And without the rounding, the two instants are still well inside one period.
        var raw = PetFood()
        _ = raw.take([account(five: 20, fiveReset: 3599.64)])
        XCTAssertEqual(raw.take([account(five: 23, fiveReset: 3600, fetched: 60)]).points, 3, accuracy: 1e-9)
    }

    /// A point of food is a point of the left readout: with a Max 20x and a Pro (W = 21), the Pro's
    /// +5 % is 5/21 of a point and the Max's +1 % is 20/21.
    func testFoodIsWeightedIntoTheAggregatesUnits() {
        var food = PetFood()
        let start = [account("max", weight: 20, five: 10), account("pro", weight: 1, five: 10)]
        _ = food.take(start)
        let proGrew = food.take([account("max", weight: 20, five: 10, fetched: 30), account("pro", weight: 1, five: 15, fetched: 30)])
        XCTAssertEqual(proGrew.points, 0.238, accuracy: 0.0005)
        let maxGrew = food.take([account("max", weight: 20, five: 11, fetched: 60), account("pro", weight: 1, five: 15, fetched: 60)])
        XCTAssertEqual(maxGrew.points, 0.952, accuracy: 0.0005)
    }

    /// The aggregate jumps when an account gets its first reading; that is not food.
    func testASecondAccountsFirstReadingIsNotFood() {
        var food = PetFood()
        _ = food.take([account("a", five: 10), account("b", reading: nil)])
        XCTAssertEqual(food.take([account("a", five: 10, fetched: 30), account("b", five: 80, fetched: 30)]).points, 0)
    }

    /// Hidden, its trackers go; shown again, its first reading is a new baseline, so what it used
    /// while hidden is not food.
    func testAnAccountHiddenAndShownAgainStartsFromABaseline() {
        var food = PetFood()
        _ = food.take([account("a", five: 10), account("b", five: 30)])
        XCTAssertEqual(food.take([account("a", five: 10, fetched: 30)]).points, 0, "b hidden")
        XCTAssertNil(food.trackers["b"])
        XCTAssertEqual(food.take([account("a", five: 10, fetched: 60), account("b", five: 50, fetched: 60)]).points, 0)
        XCTAssertEqual(food.trackers["b"]?.fiveHour?.high, 50)
    }

    func testAWindowThatHasNotStartedIsNoFoodAndLeavesTheTrackerAlone() {
        var food = PetFood()
        _ = food.take([account(five: 41)])
        let before = food.trackers
        XCTAssertEqual(food.take([account(five: nil, fetched: 30)]).points, 0)
        XCTAssertEqual(food.trackers, before)
        // An undated window counts toward the aggregate and never as food.
        XCTAssertEqual(food.take([account(five: 60, fiveReset: nil, fetched: 60)]).points, 0)
        XCTAssertEqual(food.trackers, before)
    }

    /// A reading whose reset instant lies more than a minute before its own fetch describes a window
    /// that had already closed when it was fetched.
    func testAReadingOfAnAlreadyClosedWindowIsIgnored() {
        var food = PetFood()
        _ = food.take([account(five: 41)])
        let late = food.take([account(five: 90, fiveReset: 3600, fetched: 3600 + 61)])
        XCTAssertEqual(late, PetFood.Intake(points: 0, closes: []))
        XCTAssertEqual(food.trackers["a"]?.fiveHour?.high, 41)
        // Within the minute it is still the same period's reading.
        XCTAssertEqual(food.take([account(five: 44, fiveReset: 3600, fetched: 3600 + 59)]).points, 3, accuracy: 1e-9)
    }

    /// What was used while Brow was not running is a catch-up meal.
    func testAPersistedTrackerTurnsGrowthWhileQuitIntoACatchUpMeal() {
        var samePeriod = PetFood(trackers: ["a": PetPeriods(fiveHour: PetPeriod(resetAt: at(3600), high: 20))])
        XCTAssertEqual(samePeriod.take([account(five: 35)]).points, 15, accuracy: 1e-9)

        var newPeriod = PetFood(trackers: ["a": PetPeriods(fiveHour: PetPeriod(resetAt: at(-3600), high: 70))])
        let intake = newPeriod.take([account(five: 12)])
        XCTAssertEqual(intake.points, 12, accuracy: 1e-9)
        XCTAssertEqual(intake.closes.map(\.resetAt), [at(-3600)])
    }

    /// One prompt moves both numbers; only the 5-hour one feeds, or it would count twice.
    func testOnlyTheFiveHourWindowFeeds() {
        var food = PetFood()
        _ = food.take([account(five: 10, week: 40)])
        XCTAssertEqual(food.take([account(five: 10, week: 50, fetched: 30)]).points, 0)
        XCTAssertEqual(food.trackers["a"]?.sevenDay?.high, 50, "the weekly tracker still follows, for the good week")
    }

    /// Other models still work when the model weekly window is used up, so it is neither food nor
    /// sleep: the pet's reading does not even carry it.
    func testTheModelWeeklyWindowIsNeitherFoodNorSleep() {
        let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: "default_claude_max_20x",
                                        configDir: "/tmp/brow-tests/a", aliasDirs: [], tokenExpiresAt: nil)
        func row(scoped: Double, fetched: TimeInterval) -> AccountRow {
            let snapshot = LimitSnapshot(organizationUuid: "org", fetchedAt: at(fetched),
                                         fiveHour: CapturedWindow(usedPercentage: 30, resetsAt: "2023-11-15T01:00:00Z"),
                                         sevenDay: CapturedWindow(usedPercentage: 60, resetsAt: "2023-11-19T02:00:00Z"),
                                         weeklyScoped: CapturedWindow(usedPercentage: scoped, resetsAt: "2023-11-19T02:00:00Z"),
                                         weeklyScopedModel: "Fable")
            return AccountRow(account: account, name: "a", snapshot: snapshot, status: .ok, tokenStatus: "valid")
        }
        var food = PetFood()
        _ = food.take([PetAccount(row: row(scoped: 40, fetched: 0))])
        let full = PetAccount(row: row(scoped: 100, fetched: 30))
        XCTAssertEqual(food.take([full]).points, 0)
        XCTAssertEqual(full.weight, 20)
        XCTAssertEqual(PetLimits.aggregate([full], .fiveHour, now: at(30)), 30)
        XCTAssertEqual(PetLimits.aggregate([full], .sevenDay, now: at(30)), 60)
    }

    /// Periods end by the clock at their reset instant when no newer reading has come, in the order
    /// they ended, and a late reading of a closed period is ignored.
    func testThePeriodsCloseByTheClockInOrder() {
        var food = PetFood()
        _ = food.take([account("a", five: 50, fiveReset: 7200, week: 75, weekReset: 3600),
                       account("b", five: 20, fiveReset: 3600)])
        XCTAssertEqual(food.nextClose(after: at(0)), at(3600))
        XCTAssertEqual(food.closeElapsed(now: at(3599)), [])
        let closes = food.closeElapsed(now: at(7200))
        XCTAssertEqual(closes.map { "\($0.account).\($0.window.rawValue)@\(Int($0.resetAt.timeIntervalSince(t0)))" },
                       ["b.fiveHour@3600", "a.sevenDay@3600", "a.fiveHour@7200"])
        XCTAssertEqual(food.closeElapsed(now: at(9000)), [], "each period closes once")
        XCTAssertTrue(food.isClosed(account: "a", window: .fiveHour, resetAt: at(7200)))
        // A stale reading of the closed period changes nothing.
        let stale = food.take([account("a", five: 60, fiveReset: 7200, week: 75, weekReset: 3600, fetched: 7100),
                               account("b", five: 20, fiveReset: 3600)])
        XCTAssertEqual(stale, PetFood.Intake(points: 0, closes: []))
    }

    func testTheRowHelperReadsTheTierAndRoundsTheResets() {
        let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: "default_claude_pro",
                                        configDir: "/tmp/brow-tests/a", aliasDirs: [], tokenExpiresAt: nil)
        let none = AccountRow(account: account, name: "a", snapshot: nil, status: .stale, tokenStatus: "valid")
        XCTAssertEqual(PetAccount(row: none), PetAccount(id: "org", weight: 1, reading: nil))
        let unknown = DiscoveredAccount(organizationUuid: "o2", email: nil, tier: "default_claude_team",
                                        configDir: "/tmp/brow-tests/b", aliasDirs: [], tokenExpiresAt: nil)
        XCTAssertEqual(PetAccount(row: AccountRow(account: unknown, name: "b", snapshot: nil, status: .stale,
                                                  tokenStatus: "valid")).weight, 1, "an unknown tier weighs 1")
    }
}

private extension PetFoodTests {
    func account(_ id: String, reading: PetReading?) -> PetAccount {
        PetAccount(id: id, weight: 1, reading: reading)
    }
}
