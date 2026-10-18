// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// Moments: fed days, the streak and good weeks are tested on `PetMoments`; when a moment plays,
/// through the brain.
final class PetMomentsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2023-11-14 12:00 UTC: the middle of a day, so whole days can be added without crossing a date
    /// by accident.
    private let noon = Date(timeIntervalSince1970: 1_699_963_200)

    private func day(_ n: Int) -> Date { noon.addingTimeInterval(Double(n) * 86_400) }

    func testTenPointsMakeAFedDay() {
        var moments = PetMoments()
        _ = moments.credit(9.9, at: day(0), timeZone: utc)
        XCTAssertNil(moments.streak.lastFedDay, "9.9 points is not a fed day")
        _ = moments.credit(0.1, at: day(0), timeZone: utc)
        XCTAssertEqual(moments.streak, PetStreak(count: 1, lastFedDay: "2023-11-14", celebrated: []))
        XCTAssertEqual(moments.days["2023-11-14"] ?? 0, 10, accuracy: 1e-9)
    }

    /// Two unfed days in a row are rest days; the streak goes on and reaches its first milestone,
    /// celebrated once.
    func testTheStreakSurvivesTwoRestDays() {
        var moments = PetMoments()
        var reached: [Int] = []
        for (n, fed) in [true, true, false, false, true].enumerated() where fed {
            if let milestone = moments.credit(12, at: day(n), timeZone: utc) { reached.append(milestone) }
        }
        XCTAssertEqual(moments.streak.count, 3)
        XCTAssertEqual(reached, [3])
        XCTAssertNil(moments.credit(12, at: day(4).addingTimeInterval(3600), timeZone: utc), "the same day again")
        XCTAssertEqual(moments.lines(at: day(4), timeZone: utc), [.streak(days: 3)])
        XCTAssertEqual(moments.lines(at: day(5), timeZone: utc), [], "the line lasts the rest of that day")
    }

    /// The third unfed day in a row ends the streak, silently: it starts again at 1, nothing is
    /// celebrated, and no line mentions what was lost.
    func testThreeUnfedDaysEndItSilently() {
        var moments = PetMoments()
        var reached: [Int] = []
        for (n, fed) in [true, false, false, false, true].enumerated() where fed {
            if let milestone = moments.credit(12, at: day(n), timeZone: utc) { reached.append(milestone) }
        }
        XCTAssertEqual(moments.streak.count, 1)
        XCTAssertEqual(reached, [])
        XCTAssertEqual(moments.lines(at: day(4), timeZone: utc), [])
    }

    func testEveryMilestoneOncePerStreak() {
        var moments = PetMoments()
        var reached: [Int] = []
        for n in 0..<100 {
            if let milestone = moments.credit(10, at: day(n), timeZone: utc) { reached.append(milestone) }
        }
        XCTAssertEqual(reached, [3, 7, 14, 30, 60, 100])
        XCTAssertEqual(moments.days.count, PetTuning.Store.keptDays, "the last 60 dates are kept")
        XCTAssertEqual(moments.days.keys.sorted().first, PetMoments.day(day(40), in: utc))
    }

    /// Food is dated when it arrives, in the zone of that moment. Moving five hours west at 23:30
    /// puts the clock back to 18:30 of the same date: that date goes on collecting food, and its fed
    /// day is counted once, though the Mac lives through its evening twice.
    func testATimeZoneChangeNeverCountsADateTwice() {
        let west = TimeZone(secondsFromGMT: -5 * 3600)!
        let lateEvening = noon.addingTimeInterval(11.5 * 3600)            // 23:30 UTC on the 14th
        var moments = PetMoments()
        _ = moments.credit(6, at: lateEvening, timeZone: utc)
        _ = moments.credit(6, at: lateEvening.addingTimeInterval(900), timeZone: west)   // 18:45 there
        XCTAssertEqual(moments.streak, PetStreak(count: 1, lastFedDay: "2023-11-14", celebrated: []))
        _ = moments.credit(5, at: lateEvening.addingTimeInterval(3600), timeZone: west)  // 00:30 UTC
        XCTAssertEqual(moments.days, ["2023-11-14": 17])
        XCTAssertEqual(moments.streak.count, 1)
        // Its midnight comes five hours later; the next date is a new day.
        _ = moments.credit(12, at: lateEvening.addingTimeInterval(6 * 3600), timeZone: west)
        XCTAssertEqual(moments.streak, PetStreak(count: 2, lastFedDay: "2023-11-15", celebrated: []))
    }

    func testAWeekClosingAtSeventyPercentOrMoreIsAGoodWeek() {
        var moments = PetMoments()
        let reset = noon
        XCTAssertTrue(moments.weekClosed(account: "org", resetAt: reset, used: 72))
        XCTAssertFalse(moments.weekClosed(account: "org2", resetAt: reset, used: 69))
        XCTAssertEqual(moments.goodWeeks, ["org@1699963200"])
        XCTAssertEqual(moments.lines(at: reset.addingTimeInterval(3600), timeZone: utc),
                       [.goodWeek(account: "org", used: 72)])
        XCTAssertEqual(moments.lines(at: reset.addingTimeInterval(86_400), timeZone: utc), [], "for a day")
        XCTAssertFalse(moments.weekClosed(account: "org", resetAt: reset, used: 72), "once per account and period")
    }

    func testOnlyTheLastSixteenGoodWeeksAreKept() {
        var moments = PetMoments()
        for week in 0..<20 {
            _ = moments.weekClosed(account: "org", resetAt: day(7 * week), used: 80)
        }
        XCTAssertEqual(moments.goodWeeks.count, PetTuning.Store.keptGoodWeeks)
        XCTAssertEqual(moments.goodWeeks.first, "org@\(Int(day(28).timeIntervalSince1970))")
        XCTAssertEqual(moments.goodWeekLines.count, 1, "only the last day's line is live")
    }

    // MARK: - When moments play (through the brain)

    private func played(_ pet: PetHarness, _ range: ClosedRange<TimeInterval>) -> [String] {
        pet.played(range).map { segment in
            let name: String
            switch segment.behaviour {
            case .celebrate(.streak(let days)): name = "celebrate(streak \(days))"
            case .celebrate(.goodWeek): name = "celebrate(goodWeek)"
            case .eat: name = "eat"
            case .satisfied: name = "satisfied"
            case .idle: name = "idle"
            case .leaveDen(let stretch): name = stretch ? "leaveDen" : "leaveDen(short)"
            default: name = "\(segment.behaviour)"
            }
            return "\(name)@\(String(format: "%.2f", segment.start))"
        }
    }

    /// A pet two fed days into its streak; `t0` is 22:13 UTC, so its day ends 6400 s later.
    private func twoDaysIn() -> PetHarness {
        var pet = PetHarness()
        pet.brain.moments.streak = PetStreak(count: 2, lastFedDay: "2023-11-13", celebrated: [])
        pet.accounts = [.init(id: "a", five: 10)]
        return pet
    }

    /// The meal that makes the day fed is where its milestone is celebrated: `satisfied` gives way to
    /// it after its 1.5 s.
    func testAMilestoneIsCelebratedAtTheMealThatReachesIt() {
        var pet = twoDaysIn()
        pet.start()
        pet.accounts[0].five = 22
        pet.refresh(at: 20)
        pet.run(to: 40)
        // Twelve points is a feast: a 2.38 s meal, and the celebration cuts its 4 s of satisfaction.
        XCTAssertEqual(played(pet, 1...40), ["eat@20.00", "satisfied@22.38", "celebrate(streak 3)@23.88", "idle@26.28"])
        XCTAssertEqual(pet.brain.moments.lines(at: pet.time(40).wall, timeZone: utc), [.streak(days: 3)])
    }

    /// Reached unseen, it is celebrated at the first moment the pet is seen that day; seen only the
    /// next day, it is skipped without a word.
    func testAMilestoneReachedUnseenWaitsForTheDayOnly() {
        var later = twoDaysIn()
        later.start(visible: false)
        later.accounts[0].five = 22
        later.refresh(at: 20)
        later.send(.visible(true), at: 3000)
        later.run(to: 3020)
        XCTAssertTrue(played(later, 2990...3020).contains("celebrate(streak 3)@3003.88"), "\(played(later, 2990...3020))")

        var tomorrow = twoDaysIn()
        tomorrow.start(visible: false)
        tomorrow.accounts[0].five = 22
        tomorrow.refresh(at: 20)
        tomorrow.send(.visible(true), at: 7000)
        tomorrow.run(to: 7020)
        XCTAssertEqual(played(tomorrow, 6990...7020), ["eat@7000.00", "satisfied@7002.38", "idle@7006.38"])
        XCTAssertEqual(tomorrow.brain.moments.streak.celebrated, [3], "skipped, never to come back")
    }

    /// A week used to 100 % closes while the pet hibernates: out of the den first, then the good week.
    func testAGoodWeekAfterHibernationIsCelebratedOnceOutOfTheDen() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 20, week: 100, weekReset: 300)]
        pet.start()
        pet.accounts[0].week = 0
        pet.accounts[0].weekReset = 300 + 7 * 86_400
        pet.refresh(at: 301)
        pet.run(to: 320)
        XCTAssertEqual(played(pet, 0...320), ["hibernating@0.00", "stirring@300.00", "leaveDen@301.00",
                                              "celebrate(goodWeek)@304.70", "idle@307.50"])
    }

    /// Two good weeks three hours apart: one celebration a day, but each gets its line.
    func testTwoGoodWeeksInADayAreOneCelebrationAndTwoLines() {
        var pet = PetHarness()
        pet.accounts = [.init(id: "a", five: 10, week: 80, weekReset: 1000),
                        .init(id: "b", five: 10, week: 75, weekReset: 1000 + 3 * 3600)]
        pet.start()
        pet.run(to: 1000 + 3 * 3600 + 60)
        let celebrations = pet.played(0...20_000).filter { $0.behaviour == .celebrate(.goodWeek) }
        XCTAssertEqual(celebrations.map(\.start), [1000])
        XCTAssertEqual(pet.brain.moments.lines(at: pet.time(1000 + 3 * 3600 + 60).wall, timeZone: utc),
                       [.goodWeek(account: "b", used: 75), .goodWeek(account: "a", used: 80)])
    }

    /// A 5-hour reset that frees 25 points of the aggregate is a fresh window; one that frees 10,
    /// twenty minutes later, is not (and would be too soon anyway).
    func testAFreshWindowNeedsTwentyPointsFreed() {
        var pet = PetHarness()
        pet.accounts = [.init(id: "a", five: 50, fiveReset: 1000), .init(id: "b", five: 20, fiveReset: 2200)]
        pet.start()
        pet.run(to: 2300)
        XCTAssertEqual(pet.played(0...2300).filter { $0.behaviour == .freshWindow }.map(\.start), [1000])
    }

    func testAtMostOneGoodWeekCelebrationADay() {
        var moments = PetMoments()
        XCTAssertTrue(moments.mayCelebrateGoodWeek(at: noon))
        moments.lastGoodWeekCelebratedAt = noon
        XCTAssertFalse(moments.mayCelebrateGoodWeek(at: noon.addingTimeInterval(3 * 3600)))
        XCTAssertTrue(moments.mayCelebrateGoodWeek(at: noon.addingTimeInterval(86_400)))
    }
}
