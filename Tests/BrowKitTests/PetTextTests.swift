// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// What the panel's header row says in each situation, word for word, with `now`, the time zone and the
/// calendar injected; and the pet's VoiceOver value.
final class PetTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)       // 2026-10-15 12:00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let calendar = Calendar(identifier: .gregorian)

    private func header(_ situation: PetStatus.Situation, lastMeal: TimeInterval? = nil, points: Double? = nil,
                        pace: Double = 1, moments: [PetMomentLine] = [], names: [String: String] = [:]) -> PetText.Header {
        let status = PetStatus(situation: situation, meter: 20, lastMeal: lastMeal.map { now.addingTimeInterval(-$0) },
                               lastMealPoints: points, pace: pace, moments: moments)
        return PetText.header(status, now: now, timeZone: utc, calendar: calendar, names: names)
    }

    private func words(_ header: PetText.Header) -> String { "\(header.word) | \(header.detail)" }

    func testAMealInTheLastTenMinutes() {
        XCTAssertEqual(words(header(.awake(mood: .content), lastMeal: 120, points: 3.2)), "Content | Ate 3 % · 2 min ago")
        XCTAssertEqual(words(header(.awake(mood: .full), lastMeal: 30, points: 0.4)), "Full | Ate <1 % · just now")
        XCTAssertEqual(words(header(.awake(mood: .content), lastMeal: 599, points: 2.5)), "Content | Ate 3 % · 9 min ago")
    }

    func testOtherwiseAwake() {
        XCTAssertEqual(words(header(.awake(mood: .peckish), lastMeal: 3 * 3600 + 100, points: 3)), "Peckish | Last meal 3 h ago")
        XCTAssertEqual(words(header(.awake(mood: .content))), "Content | No meal yet")
        XCTAssertEqual(words(header(.awake(mood: .full), lastMeal: 1200, points: 3, pace: 0.5)),
                       "Full | Last meal 20 min ago · well fed this week")
        XCTAssertEqual(words(header(.awake(mood: .hungry), lastMeal: 2 * 86_400, points: 3, pace: 0.51)),
                       "Hungry | Last meal 2 d ago")
    }

    /// The two ends of the meter have words of their own, and the same detail lines as every mood.
    func testTheEndsOfTheMeter() {
        XCTAssertEqual(words(header(.awake(mood: .stuffed), lastMeal: 120, points: 9.2)), "Stuffed | Ate 9 % · 2 min ago")
        XCTAssertEqual(words(header(.awake(mood: .stuffed), lastMeal: 1800, points: 9.2, pace: 0.4)),
                       "Stuffed | Last meal 30 min ago · well fed this week")
        XCTAssertEqual(words(header(.awake(mood: .famished), lastMeal: 5 * 3600 + 60, points: 3)), "Famished | Last meal 5 h ago")
        XCTAssertEqual(words(header(.unsure(mood: .famished, newest: now.addingTimeInterval(-14 * 60)))),
                       "Famished | No fresh numbers for 14 min")
        // Eating, eager and asleep say what they always say, at either end.
        XCTAssertEqual(words(header(.eating(points: 3))), "Eating | 3 % of the 5-hour limit")
        XCTAssertEqual(words(header(.eager)), "Waiting for food | Claude Code is working")
    }

    func testEagerAndEating() {
        XCTAssertEqual(words(header(.eager)), "Waiting for food | Claude Code is working")
        XCTAssertEqual(words(header(.eating(points: 3))), "Eating | 3 % of the 5-hour limit")
        XCTAssertEqual(words(header(.eating(points: 0.3))), "Eating | <1 % of the 5-hour limit")
    }

    func testAsleepSaysWhenItWakes() {
        XCTAssertEqual(words(header(.asleep(wakesAt: now.addingTimeInterval(6 * 3600 + 40 * 60)))),
                       "Asleep | 5-hour limit used up · wakes at 18:40")
        XCTAssertEqual(words(header(.asleep(wakesAt: Date(timeIntervalSince1970: 1_792_634_400)))),
                       "Asleep | 5-hour limit used up · wakes 22 Oct 02:00")
        XCTAssertEqual(words(header(.asleep(wakesAt: nil))), "Asleep | 5-hour limit used up · wakes when it resets")
        // The day is the injected zone's: 18:40 UTC is the next morning in Tokyo.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let status = PetStatus(situation: .asleep(wakesAt: now.addingTimeInterval(6 * 3600 + 40 * 60)), meter: 0)
        XCTAssertEqual(PetText.header(status, now: now, timeZone: tokyo, calendar: calendar).detail,
                       "5-hour limit used up · wakes 16 Oct 03:40")
    }

    func testWakingUpAndHibernating() {
        XCTAssertEqual(words(header(.drowsy)), "Waking up | The 5-hour limit has reset")
        XCTAssertEqual(words(header(.hibernating(wakesAt: Date(timeIntervalSince1970: 1_792_634_400)))),
                       "Hibernating | Weekly limit used up · wakes 22 Oct 02:00")
        XCTAssertEqual(words(header(.stirring)), "Waking up | The weekly limit has reset")
    }

    func testUnsureKeepsItsMoodAndSaysHowLongItHasHadNoNumbers() {
        XCTAssertEqual(words(header(.unsure(mood: .peckish, newest: now.addingTimeInterval(-14 * 60)))),
                       "Peckish | No fresh numbers for 14 min")
        XCTAssertEqual(words(header(.unsure(mood: .content, newest: now.addingTimeInterval(-3 * 3600)))),
                       "Content | No fresh numbers for 3 h")
        XCTAssertEqual(words(header(.unsure(mood: .content, newest: nil))), "Content | No numbers yet")
    }

    func testNoAccounts() {
        XCTAssertEqual(words(header(.noAccounts)), "Waiting | No Claude account to eat from yet")
    }

    func testTheMomentLine() {
        XCTAssertNil(header(.awake(mood: .content)).moment)
        XCTAssertEqual(header(.awake(mood: .content), moments: [.streak(days: 7)]).moment, "Streak: 7 fed days")
        XCTAssertEqual(header(.awake(mood: .content), moments: [.goodWeek(account: "o1", used: 82.4)],
                              names: ["o1": "Work"]).moment,
                       "Good week: 82 % of the weekly limit used")
        XCTAssertEqual(header(.awake(mood: .content), moments: [.goodWeek(account: "o1", used: 82.4), .streak(days: 3)],
                              names: ["o1": "Work", "o2": "Home"]).moment,
                       "Good week: 82 % used · Work", "the newest, with its account among several, named last")
    }

    func testTheVoiceOverValueSpellsTheUnitsOut() {
        let status = PetStatus(situation: .awake(mood: .content), meter: 20, lastMeal: now.addingTimeInterval(-12 * 60),
                               lastMealPoints: 3)
        XCTAssertEqual(PetText.voiceOverValue(status, now: now, timeZone: utc, calendar: calendar),
                       "Content. Last meal 12 minutes ago. Hunger 20 percent.")
        let ate = PetStatus(situation: .awake(mood: .full), meter: 0.4, lastMeal: now.addingTimeInterval(-61), lastMealPoints: 0.2)
        XCTAssertEqual(PetText.voiceOverValue(ate, now: now, timeZone: utc, calendar: calendar),
                       "Full. Ate less than 1 percent, 1 minute ago. Hunger 0 percent.")
        let asleep = PetStatus(situation: .asleep(wakesAt: now.addingTimeInterval(3600)), meter: 100)
        XCTAssertEqual(PetText.voiceOverValue(asleep, now: now, timeZone: utc, calendar: calendar),
                       "Asleep. 5-hour limit used up, wakes at 13:00. Hunger 100 percent.")
        let stuffed = PetStatus(situation: .awake(mood: .stuffed), meter: 0, lastMeal: now.addingTimeInterval(-120),
                                lastMealPoints: 9.2)
        XCTAssertEqual(PetText.voiceOverValue(stuffed, now: now, timeZone: utc, calendar: calendar),
                       "Stuffed. Ate 9 percent, 2 minutes ago. Hunger 0 percent.")
        let famished = PetStatus(situation: .awake(mood: .famished), meter: 96, lastMeal: now.addingTimeInterval(-5 * 3600 - 60),
                                 lastMealPoints: 3)
        XCTAssertEqual(PetText.voiceOverValue(famished, now: now, timeZone: utc, calendar: calendar),
                       "Famished. Last meal 5 hours ago. Hunger 96 percent.")
        XCTAssertEqual(PetText.label, "Pet")
        XCTAssertEqual(PetText.actionName, "Pet")
    }

    /// No text says "you" or judges use, in any situation, mood or moment: hunger is a mood, never a
    /// reproach.
    func testNothingItSaysAddressesOrJudgesThePerson() {
        let soon = now.addingTimeInterval(3600), later = now.addingTimeInterval(3 * 86_400)
        var situations: [PetStatus.Situation] = [.noAccounts, .stirring, .drowsy, .eager, .eating(points: 3),
                                                 .eating(points: 0.2), .asleep(wakesAt: soon), .asleep(wakesAt: nil),
                                                 .hibernating(wakesAt: later), .unsure(mood: .hungry, newest: nil)]
        for mood in PetMood.allCases {
            situations += [.awake(mood: mood), .unsure(mood: mood, newest: now.addingTimeInterval(-900))]
        }
        var said: [String] = []
        for situation in situations {
            for (lastMeal, pace) in [(nil, 1.0), (120.0, 1.0), (7200.0, 0.3)] {
                let header = self.header(situation, lastMeal: lastMeal, points: 3, pace: pace,
                                         moments: [.goodWeek(account: "o1", used: 75), .streak(days: 14)],
                                         names: ["o1": "Work", "o2": "Home"])
                let status = PetStatus(situation: situation, meter: 70, lastMeal: lastMeal.map { now.addingTimeInterval(-$0) },
                                       lastMealPoints: 3, pace: pace)
                said += [header.word, header.detail, header.moment ?? "",
                         PetText.voiceOverValue(status, now: now, timeZone: utc, calendar: calendar)]
            }
        }
        said += [PetText.moment(.streak(days: 3), names: [:]), PetText.moment(.goodWeek(account: "o1", used: 70), names: [:])]
        for line in said {
            let words = Set(line.lowercased().split { !$0.isLetter }.map(String.init))
            for banned in ["you", "your", "lazy", "wasted", "waste", "bad", "should", "lost", "starving", "sad"] {
                XCTAssertFalse(words.contains(banned), "\(line)")
            }
        }
    }

    // MARK: - The brain's status

    func testTheBrainReportsWhatIsPlaying() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 10, fiveReset: 3600)]
        pet.start()
        XCTAssertEqual(pet.brain.status(at: pet.time(1)).situation, .awake(mood: .content))
        pet.accounts[0].five = 13
        pet.refresh(at: 10)
        XCTAssertEqual(pet.brain.status(at: pet.time(11)).situation, .eating(points: 3))
        let after = pet.brain.status(at: pet.time(20))
        XCTAssertEqual(after.situation, .awake(mood: .content))
        XCTAssertEqual(after.lastMeal, pet.time(10).wall)
        XCTAssertEqual(after.lastMealPoints ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(after.meter, 30 + 20 * 20 / 3600 - 18, accuracy: 1e-6)
        pet.send(.prompt, at: 30)
        XCTAssertEqual(pet.brain.status(at: pet.time(31)).situation, .eager)
        pet.accounts[0].five = 100
        pet.refresh(at: 200)
        pet.run(to: 300)
        XCTAssertEqual(pet.brain.status(at: pet.time(300)).situation, .asleep(wakesAt: pet.t0.addingTimeInterval(3600)))
    }
}
