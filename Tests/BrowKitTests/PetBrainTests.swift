// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The state machine, through `PetHarness`, which sends what the app would. Times are seconds after
/// `t0`; one account of weight 1; H starts at 30. "Within one step" is the rig's 1/240 s.
final class PetBrainTests: XCTestCase {
    private let step = PetTuning.Secondary.step

    private func starts(_ harness: PetHarness, _ range: ClosedRange<TimeInterval>) -> [String] {
        harness.played(range).map { "\(name($0.behaviour))@\(String(format: "%.2f", $0.start))" }
    }

    private func name(_ behaviour: PetBehaviour) -> String {
        switch behaviour {
        case .idle(let mood): return "idle(\(mood))"
        case .settled(let mood): return "settled(\(mood))"
        case .unsureIdle(let mood): return "unsureIdle(\(mood))"
        case .eat(let meal):
            return "eat(\(meal.feast ? "feast" : meal.size == .full ? "full" : "nibble"),\(meal.chews))"
        case .satisfied(let kind): return "satisfied(\(kind))"
        case .perk(let perk): return "perk(\(perk))"
        case .boop(let giggle): return giggle ? "giggle" : "boop"
        case .celebrate(.streak(let days)): return "celebrate(streak \(days))"
        case .celebrate(.goodWeek): return "celebrate(goodWeek)"
        case .enterDen(let retreat): return retreat ? "retreat" : "enterDen"
        case .leaveDen(let stretch): return stretch ? "leaveDen" : "leaveDen(short)"
        case .intro(let none): return none ? "intro(noAccounts)" : "intro"
        default: return "\(behaviour)"
        }
    }

    // MARK: - The tour at real pace

    /// The 16 s tour's events played at the speed of life: the pointer, a prompt, a meal, hunger, the
    /// meal that fills the window, sleep and the reset.
    func testTheTourAtRealPace() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 41, fiveReset: 200)]
        pet.start()
        pet.send(.pointer(distance: 120), at: 3)
        pet.send(.prompt, at: 4)
        pet.accounts[0].five = 44
        pet.refresh(at: 5)
        pet.send(.debugHunger(70), at: 10)
        pet.accounts[0].five = 100
        pet.refresh(at: 60)
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 200 + 5 * 3600
        pet.refresh(at: 200)
        pet.run(to: 300)

        XCTAssertEqual(starts(pet, 0...300), [
            "idle(content)@0.00", "perk(prompt)@4.00", "eager@4.50",
            "eat(full,3)@5.00", "satisfied(meal)@6.98", "idle(content)@9.98", "idle(hungry)@10.00",
            "eat(feast,3)@60.00", "fallAsleep@62.38", "asleep@64.98",
            // It slept the window's feast off with its hunger clock stopped: it wakes stuffed, and happy.
            "wake@200.00", "idle(stuffed)@202.70",
        ])
        XCTAssertEqual(pet.brain.timeline.cues.first, PetCue(t: 3, kind: .notice))
        // The meter: 30, the 3 points (18) land at the swallow, the feast's drop at its swallow.
        XCTAssertEqual(pet.meter(at: 6.5), 30 + 6.5 * 20 / 3600, accuracy: 1e-6)
        XCTAssertEqual(pet.meter(at: 6.7), 30 + 6.7 * 20 / 3600 - 18, accuracy: 1e-6)
        XCTAssertEqual(pet.meter(at: 61.5), 70 + 50 * 20 / 3600, accuracy: 1e-6, "hungry until the swallow")
        XCTAssertEqual(pet.meter(at: 61.7), -50, accuracy: 1e-6, "the floor")
        XCTAssertEqual(pet.meter(at: 150), -50, accuracy: 1e-6, "no hunger while asleep")
    }

    private func tourScenario(tickEvery: TimeInterval? = nil) -> PetHarness {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 41, fiveReset: 200)]
        pet.start()
        var script: [(TimeInterval, (inout PetHarness) -> Void)] = [
            (3, { $0.send(.pointer(distance: 120), at: 3) }),
            (4, { $0.send(.prompt, at: 4) }),
            (5, { $0.accounts[0].five = 44; $0.refresh(at: 5) }),
            (10, { $0.send(.debugHunger(70), at: 10) }),
            (60, { $0.accounts[0].five = 100; $0.refresh(at: 60) }),
            (200, { $0.accounts[0].five = 0; $0.accounts[0].fiveReset = 200 + 5 * 3600; $0.refresh(at: 200) }),
        ]
        if let every = tickEvery {
            script += stride(from: every, to: 300, by: every).map { at in (at, { $0.send(.tick, at: at) }) }
            script.sort { $0.0 < $1.0 }
        }
        for (_, action) in script { action(&pet) }
        pet.run(to: 300)
        return pet
    }

    /// The same events at the same times give the same timeline, and a tick that finds nothing to do
    /// changes nothing: a controller that wakes the brain more often than asked gets the same pet.
    func testTheTimelineIsAFunctionOfTheEventsAlone() {
        let once = tourScenario(), again = tourScenario()
        XCTAssertEqual(once.brain.timeline, again.brain.timeline)
        let ticked = tourScenario(tickEvery: 0.7)
        XCTAssertEqual(ticked.brain.timeline.segments, once.brain.timeline.segments)
        XCTAssertEqual(ticked.brain.timeline.cues, once.brain.timeline.cues)
        XCTAssertEqual(ticked.brain.timeline.meter, once.brain.timeline.meter)
    }

    /// After an action there is always a next segment at its end at the latest, planned
    /// when the action was, so the rig never has to guess what follows.
    func testEveryActionIsFollowedByAPlannedSegment() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 41, fiveReset: 200)]
        pet.start()
        let checks: [(TimeInterval, PetEvent?)] = [(4, .prompt), (5, nil), (60, nil)]
        for (at, event) in checks {
            if let event { pet.send(event, at: at) } else {
                pet.accounts[0].five = at == 5 ? 44 : 100
                pet.refresh(at: at)
            }
            let segments = pet.brain.timeline.segments
            for (index, segment) in segments.enumerated() {
                guard let duration = segment.behaviour.duration else { continue }
                XCTAssertTrue(index + 1 < segments.count, "nothing planned after \(segment)")
                if index + 1 < segments.count {
                    XCTAssertLessThanOrEqual(segments[index + 1].start, segment.start + duration + 1e-9)
                }
            }
        }
    }

    func testHandleReturnsWhatItPlanned() {
        var brain = PetBrain(seed: 1)
        brain.introDone = true
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ s: TimeInterval) -> PetTime { PetTime(wall: t0.addingTimeInterval(s), mono: s) }
        let account = PetAccount(id: "a", weight: 1, reading: PetReading(
            fetchedAt: t0, fiveHour: PetWindow(used: 10, resetAt: t0.addingTimeInterval(3600)), sevenDay: nil))
        XCTAssertEqual(brain.handle(.visible(true), at: at(0)), [], "nothing before the accounts are known")
        XCTAssertEqual(brain.handle(.readings([account]), at: at(0)), [PetSegment(start: 0, behaviour: .idle(.content))])
        XCTAssertEqual(brain.handle(.tick, at: at(1)), [], "the plan stayed as it was")
        let planned = brain.handle(.prompt, at: at(2))
        XCTAssertEqual(planned, [PetSegment(start: 2, behaviour: .perk(.prompt)), PetSegment(start: 2.5, behaviour: .eager)])
    }

    /// Between events the timeline holds the plan. A pointer event that comes during a planned
    /// celebration, with no tick in between (a timer that fired late), must commit what started
    /// before it, not skip it: the milestone plays once.
    func testAnEventBetweenTicksCommitsWhatThePlanStarted() {
        var brain = PetBrain(seed: 3)
        brain.introDone = true
        brain.moments.streak = PetStreak(count: 2, lastFedDay: "2023-11-13", celebrated: [])
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ s: TimeInterval) -> PetTime { PetTime(wall: t0.addingTimeInterval(s), mono: s) }
        func reading(_ five: Double, _ s: TimeInterval) -> PetEvent {
            .readings([PetAccount(id: "a", weight: 1, reading: PetReading(
                fetchedAt: t0.addingTimeInterval(s), fiveHour: PetWindow(used: five, resetAt: t0.addingTimeInterval(4 * 3600)),
                sevenDay: nil))])
        }
        for event in [PetEvent.visible(true), .presence(PetPresence()), reading(10, 0)] { _ = brain.handle(event, at: at(0)) }
        _ = brain.handle(reading(22, 20), at: at(20))
        _ = brain.handle(.tick, at: at(21.62))           // the swallow; the next tick is late
        _ = brain.handle(.pointer(distance: 300), at: at(24))
        _ = brain.handle(.tick, at: at(60))
        let celebrations = brain.timeline.segments.filter { $0.behaviour == .celebrate(.streak(days: 3)) }
        XCTAssertEqual(celebrations.map(\.start), [23.88])
        XCTAssertTrue(brain.pendingCelebrations.isEmpty)
        XCTAssertEqual(brain.timeline.segments.last?.behaviour, .idle(.stuffed), "twelve points: a feast, 30 → −42")
    }

    // MARK: - Meals

    /// A started pet with one account at 10 %, everything else as the app sends it.
    private func started(five: Double = 10) -> PetHarness {
        var pet = PetHarness()
        pet.accounts = [.init(id: "a", five: five)]
        pet.start()
        return pet
    }

    private func grow(_ pet: inout PetHarness, to five: Double, at seconds: TimeInterval) {
        pet.accounts[0].five = five
        pet.refresh(at: seconds)
    }

    func testFoodDuringEagerIsAFullMealThenSatisfied() {
        var pet = started()
        pet.send(.prompt, at: 10)
        grow(&pet, to: 13, at: 20)
        pet.run(to: 40)
        XCTAssertEqual(starts(pet, 10...40), ["perk(prompt)@10.00", "eager@10.50", "eat(full,3)@20.00",
                                              "satisfied(meal)@21.98", "idle(content)@24.98"])
    }

    /// A prompt during a meal waits for it and for `satisfied`, and is still within its 90 s then.
    func testAPromptDuringAMealWaitsForSatisfiedToEnd() {
        var pet = started()
        grow(&pet, to: 13, at: 20)
        pet.send(.prompt, at: 21)
        pet.run(to: 200)
        XCTAssertEqual(starts(pet, 20...200), ["eat(full,3)@20.00", "satisfied(meal)@21.98", "perk(prompt)@24.98",
                                               "eager@25.48", "idle(content)@111.00"])
    }

    func testTwoSmallFoodsMakeOneMealAtTheSecond() {
        var pet = started()
        grow(&pet, to: 10.3, at: 20)
        grow(&pet, to: 10.6, at: 40)
        pet.run(to: 60)
        XCTAssertEqual(starts(pet, 1...60), ["eat(full,1)@40.00", "satisfied(meal)@41.34", "idle(content)@44.34"])
        guard case .eat(let meal)? = pet.behaviour(at: 40) else { return XCTFail("no meal") }
        XCTAssertEqual(meal.points, 0.6, accuracy: 1e-9)
    }

    func testASmallPlateIsFlushedAsANibbleAfterTwoMinutes() {
        var pet = started()
        grow(&pet, to: 10.3, at: 20)
        pet.run(to: 200)
        XCTAssertEqual(starts(pet, 1...200), ["eat(nibble,1)@140.00", "satisfied(lick)@140.86", "idle(content)@141.46"])
    }

    func testCrumbsAreDroppedWithoutAMeal() {
        var pet = started()
        grow(&pet, to: 10.05, at: 20)
        pet.run(to: 300)
        XCTAssertEqual(starts(pet, 1...300), [])
        XCTAssertEqual(pet.brain.pendingDrop, 0)
        let clock = pet.brain.clock ?? 0
        XCTAssertEqual(pet.meter(at: clock), pet.brain.hunger.value, accuracy: 1e-9, "the meter shows what H has")
        XCTAssertEqual(pet.meter(at: 139), pet.meter(at: 141) + 0.05 * 6 - 2 * 20 / 3600, accuracy: 1e-9,
                       "the crumbs' drop leaves the meter when they are dropped")
    }

    /// 40 s from the start of one meal to the start of the next; within 600 s of the last one, the
    /// second is a nibble.
    func testMealsAreFortySecondsApart() {
        var pet = started()
        grow(&pet, to: 13, at: 5)
        grow(&pet, to: 14, at: 15)
        pet.run(to: 60)
        XCTAssertEqual(starts(pet, 1...60), ["eat(full,3)@5.00", "satisfied(meal)@6.98", "idle(content)@9.98",
                                             "eat(nibble,1)@45.00", "satisfied(lick)@45.86", "idle(content)@46.46"])
    }

    /// Unseen, the plate waits; seen again, one catch-up meal eats all of it.
    func testFoodUnseenIsOneCatchUpMealWhenSeen() {
        var pet = PetHarness()
        pet.accounts = [.init(id: "a", five: 10)]
        pet.start(visible: false)
        grow(&pet, to: 13, at: 20)
        grow(&pet, to: 15, at: 1800)
        pet.send(.visible(true), at: 3600)
        pet.run(to: 3700)
        let meals = pet.played(0...3700).filter { if case .eat = $0.behaviour { return true }; return false }
        XCTAssertEqual(meals.map(\.start), [3600])
        guard case .eat(let meal)? = meals.first?.behaviour else { return XCTFail("no meal") }
        XCTAssertEqual(meal.points, 5, accuracy: 1e-9)
        XCTAssertEqual(meal.size, .full)
    }

    /// The meal that fills the window goes straight into the yawn; food after it is cleared, and H
    /// still has it.
    func testFoodWhileFallingAsleepIsNotAMeal() {
        var pet = started(five: 50)
        grow(&pet, to: 99.6, at: 20)
        let h = pet.brain.hunger.value
        grow(&pet, to: 100, at: 23)
        pet.run(to: 200)
        XCTAssertEqual(starts(pet, 1...200), ["eat(feast,3)@20.00", "fallAsleep@22.38", "asleep@24.98"])
        XCTAssertEqual(pet.brain.hunger.value, max(-50, h - 0.4 * 6), accuracy: 1e-9)
        XCTAssertEqual(pet.brain.pendingDrop, 0)
    }

    // MARK: - Boops

    func testABoopDuringAMealIsIgnored() {
        var pet = started()
        grow(&pet, to: 13, at: 20)
        pet.send(.boop, at: 21)
        pet.run(to: 30)
        XCTAssertEqual(starts(pet, 20...30), ["eat(full,3)@20.00", "satisfied(meal)@21.98", "idle(content)@24.98"])
    }

    /// Five boops within 6 s are a giggle, and then it ignores boops for 10 s.
    func testFiveBoopsAreAGiggleThenTenQuietSeconds() {
        var pet = started()
        for at in [10.0, 11, 12, 13, 14, 16, 20, 25] { pet.send(.boop, at: at) }
        pet.run(to: 30)
        XCTAssertEqual(starts(pet, 10...30), [
            "boop@10.00", "idle(content)@10.60", "boop@11.00", "idle(content)@11.60", "boop@12.00", "idle(content)@12.60",
            "boop@13.00", "idle(content)@13.60", "giggle@14.00", "idle(content)@15.20", "boop@25.00", "idle(content)@25.60",
        ])
    }

    func testABoopAtRestIsAReactionNotAWake() {
        var pet = started(five: 100)
        pet.run(to: 100)
        pet.send(.boop, at: 100)
        pet.send(.boop, at: 100.5)
        XCTAssertEqual(pet.brain.timeline.cues.map(\.kind), [.sleepyEye], "one reaction; the second is too soon")
        XCTAssertEqual(pet.behaviour(at: 101), .asleep)
    }

    // MARK: - Conditions

    /// A condition change waits for an action, but `enterDen` cuts `satisfied` at once.
    func testTheWeeklyLimitDuringSatisfiedGoesIntoTheDenAtOnce() {
        var pet = started()
        grow(&pet, to: 13, at: 20)
        pet.accounts[0].week = 100
        pet.refresh(at: 23)
        pet.run(to: 40)
        XCTAssertEqual(starts(pet, 20...40), ["eat(full,3)@20.00", "satisfied(meal)@21.98", "enterDen@23.00",
                                              "hibernating@26.20"])
    }

    func testNoVisibleAccountRetreatsIntoTheDenAndPeeks() {
        var pet = started()
        pet.accounts = []
        pet.refresh(at: 20)
        pet.run(to: 1000)
        let played = pet.played(20...1000)
        XCTAssertEqual(played.prefix(2).map { name($0.behaviour) }, ["retreat", "denWait"])
        XCTAssertEqual(played[1].start, 21.6, accuracy: 1e-9)
        let peeks = played.filter { $0.behaviour == .peek }
        XCTAssertGreaterThanOrEqual(peeks.count, 6)
        for peek in peeks {
            let wait = played.last { $0.behaviour == .denWait && $0.start < peek.start }!
            XCTAssertTrue((60...120).contains(peek.start - wait.start), "peek \(peek.start - wait.start) s after the wait")
            XCTAssertEqual(played.first { $0.start > peek.start }?.start ?? 0, peek.start + 2.2, accuracy: 1e-9)
        }
        // An account coming back: out of the den without the stretch.
        pet.accounts = [.init(id: "a", five: 10)]
        pet.refresh(at: 1001)
        pet.run(to: 1010)
        XCTAssertEqual(pet.played(1001...1010).map { name($0.behaviour) }.prefix(2), ["leaveDen(short)", "idle(content)"])
    }

    /// Settled at 120 s without input, a doze at 600 s; back at 900 s, a welcome back.
    func testAwayItDozesAndIsWelcomedBack() {
        var pet = started()
        pet.idleSince = 0
        pet.run(to: 899)
        pet.idleSince = nil
        pet.run(to: 920)
        XCTAssertEqual(starts(pet, 1...920), ["settled(content)@120.00", "dozeIn@600.00", "doze@602.00",
                                              "welcomeBack@900.00", "idle(content)@901.80"])
    }

    /// Locked for two minutes is not 600 s away: no welcome back.
    func testAShortAbsenceIsNoWelcomeBack() {
        var pet = started()
        pet.run(to: 29)
        pet.screenLocked = true
        pet.send(.visible(false), at: 30)
        pet.run(to: 150)
        pet.screenLocked = false
        pet.send(.visible(true), at: 150)
        pet.run(to: 170)
        // The lock is away at once; the presence check that sees it unlocked brings it back, with no
        // welcome after 125 s.
        XCTAssertEqual(starts(pet, 1...170), ["dozeIn@30.00", "doze@32.00", "idle(content)@155.00"])
    }

    /// The Mac asleep six hours across the 5-hour reset, while the pet slept full: the first frame
    /// anyone sees is the stretch they missed, then the day goes on.
    func testAMorningAfterAResetIsTheFullStretch() {
        var pet = started(five: 100)
        pet.run(to: 100)
        XCTAssertEqual(pet.behaviour(at: 100), .asleep)
        pet.presenceEvery = nil
        pet.refreshEvery = nil
        pet.send(.systemSleep, at: 100)
        pet.send(.visible(false), at: 100)
        pet.wallShift = 6 * 3600                       // the night: wall moved, mono did not
        pet.send(.systemWake, at: 101)
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 9 * 3600
        pet.refresh(at: 102)
        pet.send(.presence(pet.presence(at: 102)), at: 102)
        pet.send(.visible(true), at: 103)
        pet.run(to: 120)
        XCTAssertEqual(starts(pet, 100...120), ["wake@103.00", "idle(content)@105.70"])
    }

    func testAMorningWithNothingChangedIsAWelcomeBack() {
        var pet = started()
        pet.presenceEvery = nil
        pet.refreshEvery = nil
        pet.send(.systemSleep, at: 100)
        pet.send(.visible(false), at: 100)
        pet.wallShift = 6 * 3600
        pet.send(.systemWake, at: 101)
        pet.refresh(at: 102)
        pet.send(.presence(pet.presence(at: 102)), at: 102)
        pet.send(.visible(true), at: 103)
        pet.run(to: 120)
        // Back at the Mac before the strip shows the pet again: awake but unseen, and welcomed when
        // seen.
        XCTAssertEqual(starts(pet, 100...120), ["doze@100.00", "idle(content)@102.00", "welcomeBack@103.00",
                                                "idle(content)@104.80"])
    }

    // MARK: - Claude Code

    /// Eager lasts 90 s after the latest prompt, each prompt extending it; a perk at most once a
    /// minute.
    func testEagerLastsNinetySecondsAfterTheLatestPrompt() {
        var pet = started()
        pet.send(.prompt, at: 10)
        pet.send(.prompt, at: 40)                       // inside the minute: no second perk
        pet.send(.prompt, at: 75)                       // a minute after the perk: a perk
        pet.run(to: 200)
        XCTAssertEqual(starts(pet, 1...200), ["perk(prompt)@10.00", "eager@10.50", "perk(prompt)@75.00",
                                              "eager@75.50", "idle(content)@165.00"])
    }

    /// At most 600 s from the first perk; then idle until a minute passes with no prompt.
    func testEagerStopsAfterTenMinutesUntilAMinuteWithoutPrompts() {
        var pet = started()
        for at in stride(from: 10.0, through: 640, by: 30) { pet.send(.prompt, at: at) }
        pet.send(.prompt, at: 720)                      // 80 s after the last: eager again
        pet.run(to: 730)
        let played = starts(pet, 1...730)
        XCTAssertEqual(played.first, "perk(prompt)@10.00")
        XCTAssertTrue(played.contains("idle(content)@610.00"), "\(played)")
        XCTAssertFalse(played.contains { $0.hasPrefix("perk") && $0.hasSuffix("@640.00") }, "within the cooldown")
        XCTAssertEqual(played.suffix(2), ["perk(prompt)@720.00", "eager@720.50"])
    }

    /// Asleep, a prompt or the pointer close by is a twitch, each at most so often; hibernating,
    /// nothing at all.
    func testAtRestPromptsAndThePointerOnlyTwitch() {
        var pet = started(five: 100)
        pet.run(to: 100)
        let events: [(TimeInterval, PetEvent)] = [
            (100, .prompt), (101, .pointer(distance: 30)), (110, .pointer(distance: 30)), (125, .pointer(distance: 30)),
            (130, .prompt), (150, .pointer(distance: 60)), (170, .prompt),
        ]
        for (at, event) in events { pet.send(event, at: at) }
        // The prompt's minute, the pointer's 20 s, and never two twitches within 20 s.
        XCTAssertEqual(pet.brain.timeline.cues.map { "\($0.kind)@\(Int($0.t))" },
                       ["twitch@100", "twitch@125", "twitch@170"])
        XCTAssertEqual(pet.behaviour(at: 170), .asleep)

        var den = started()
        den.accounts[0].week = 100
        den.refresh(at: 10)
        den.run(to: 60)
        den.send(.prompt, at: 60)
        den.send(.pointer(distance: 10), at: 61)
        XCTAssertEqual(den.brain.timeline.cues, [])
    }

    // MARK: - The pointer

    func testThePointerIsNoticedWithin160AndReleasedBeyond200() {
        var pet = started()
        for (at, distance) in [(10.0, 300.0), (11, 170), (12, 150), (13, 190), (14, 210), (15, 100)] {
            pet.send(.pointer(distance: distance), at: at)
        }
        XCTAssertEqual(pet.brain.timeline.cues.map { "\($0.kind)@\(Int($0.t))" },
                       ["notice@12", "release@14", "notice@15"])
        // Falling asleep ends the watch, so the rig's gaze is the pet's own again.
        pet.accounts[0].five = 100
        pet.refresh(at: 20)
        pet.run(to: 30)
        XCTAssertEqual(pet.brain.timeline.cues.last?.kind, .release)
    }

    // MARK: - A new pet

    func testANewPetIntroducesItselfWhenFirstSeenWithData() {
        var pet = PetHarness(introDone: false)
        pet.accounts = [.init(id: "a", hasReading: false)]
        pet.start()
        pet.run(to: 10)
        XCTAssertEqual(starts(pet, 0...10), ["denWait@0.00"], "no numbers yet: it waits in the den")
        pet.accounts[0].hasReading = true
        pet.accounts[0].five = 20
        pet.refresh(at: 10)
        pet.run(to: 400)
        XCTAssertEqual(starts(pet, 0...400), ["denWait@0.00", "intro@10.00", "idle(content)@13.60"],
                       "no peeks before the intro")
        XCTAssertTrue(pet.brain.introDone)
    }

    func testANewPetWithNoAccountsPeeksAndGoesBackIn() {
        var pet = PetHarness(introDone: false)
        pet.accounts = []
        pet.start()
        pet.run(to: 5)
        XCTAssertEqual(starts(pet, 0...5), ["intro(noAccounts)@0.00", "denWait@2.20"])
    }

    func testANewPetFirstSeenAsleepHasNoIntro() {
        var pet = PetHarness(introDone: false)
        pet.accounts = [.init(id: "a", five: 100)]
        pet.start(visible: false)
        pet.send(.visible(true), at: 30)
        pet.run(to: 60)
        XCTAssertEqual(starts(pet, 0...60), ["asleep@0.00"])
        XCTAssertTrue(pet.brain.introDone, "saved either way")
    }

    // MARK: - Off and on

    func testTurnedOffItFadesOutAndComesBackAtTheDatasCondition() {
        var pet = started()
        pet.send(.showPet(false), at: 10)
        XCTAssertNil(pet.brain.nextDeadline(after: pet.time(10)), "off: no timers")
        pet.accounts[0].five = 14
        pet.refresh(at: 100)                            // used while it was off
        pet.send(.showPet(true), at: 200)
        pet.run(to: 210)
        XCTAssertEqual(starts(pet, 1...210), ["off@10.00", "eat(full,3)@200.00", "satisfied(meal)@201.98",
                                              "idle(content)@204.98"], "the time it was off is a catch-up meal")
        XCTAssertEqual(pet.meter(at: 150), pet.meter(at: 11), accuracy: 1e-9, "no hunger while off")
    }

    // MARK: - No fresh numbers

    func testStaleNumbersAreUnsureAndFreshOnesAPerk() {
        var pet = started()
        pet.refreshEvery = nil
        pet.run(to: 700)
        XCTAssertEqual(starts(pet, 1...700), ["unsureIdle(content)@600.00"])
        let meter = pet.meter(at: 650)
        XCTAssertEqual(pet.meter(at: 700), meter, accuracy: 1e-9, "the hunger clock stops")
        pet.refresh(at: 700)
        pet.run(to: 710)
        XCTAssertEqual(starts(pet, 600...710), ["unsureIdle(content)@600.00", "perk(freshData)@700.00",
                                                "idle(content)@700.80"])
    }

    // MARK: - -petForceState

    func testAForcedStateHoldsUntilLetGo() {
        var pet = started()
        pet.send(.forceState(.asleep), at: 10)
        pet.send(.forceState(.hibernating), at: 100)
        pet.send(.forceState(nil), at: 200)
        pet.run(to: 220)
        XCTAssertEqual(starts(pet, 1...220), ["fallAsleep@10.00", "asleep@12.60", "enterDen@100.00",
                                              "hibernating@103.20", "leaveDen@200.00", "idle(content)@203.70"])
    }

    /// A backward jump brings a passed reset back into the future, but a period the pet saw end stays
    /// ended: no sleep without a fresh reading.
    func testAClockJumpingBackNeverPutsItToSleep() {
        var pet = PetHarness()
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: -10, fetchedAt: -100)]
        pet.start()
        XCTAssertEqual(pet.behaviour(at: 0), .idle(.content), "its reset has passed")
        pet.wallShift = -3600
        pet.send(.clockChanged, at: 100)
        pet.refresh(at: 101)
        pet.run(to: 400)
        XCTAssertFalse(pet.played(0...400).contains { $0.behaviour == .fallAsleep || $0.behaviour == .asleep })
    }
}
