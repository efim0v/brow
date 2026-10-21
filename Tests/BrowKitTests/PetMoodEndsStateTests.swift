// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The two ends of the meter through the state machine: the brain's mood and the rig's reading of it agree
/// across meals, boops, rest, absence and the panel, and random days keep the rules of both ends. The days
/// are a few by default; `PET_SWEEP=1` plays 120 of them.
final class PetMoodEndsStateTests: XCTestCase {
    let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))

    private func greetings(_ pet: PetHarness) -> [Double] {
        pet.brain.timeline.cues.filter { $0.kind == .greet }.map(\.t)
    }

    // MARK: - Boops after a meal

    /// A pet fed `points` from `hunger`, booped a second into the satisfaction that follows: the brain's
    /// timeline, and the boop's segment.
    private func boopedAfterAMeal(from hunger: Double, points: Double) throws -> (pet: PetHarness, boop: PetSegment) {
        var pet = PetHarness(hunger: hunger)
        pet.accounts[0].five = 10
        pet.start()
        pet.accounts[0].five = 10 + points
        pet.refresh(at: 20)
        pet.run(to: 23)
        let satisfied = try XCTUnwrap(pet.played(20...23).first { if case .satisfied = $0.behaviour { return true }; return false })
        pet.send(.boop, at: satisfied.start + 1)
        pet.run(to: satisfied.start + 1.3)
        let boop = try XCTUnwrap(pet.played(20...30).first { if case .boop = $0.behaviour { return true }; return false })
        return (pet, boop)
    }

    private func boopPosture(_ pet: PetHarness, _ boop: PetSegment) -> PetPosture {
        var script = PetReelScript()
        script.timeline = pet.brain.timeline
        let scene = PetMoodEndsTests.scene(script, at: boop.start + 0.3, zones: zones)
        return PetRigActions.posture(boop.behaviour, elapsed: 0.3, scene: scene, start: boop.start)
    }

    /// Booped during the brim, a pet the meal has just made stuffed is booped as a stuffed pet, not in the
    /// face of the Full pet it was before the meal.
    func testABoopAfterTheMealThatMadeItStuffedIsAStuffedPets() throws {
        let (pet, boop) = try boopedAfterAMeal(from: -10, points: 6)
        XCTAssertEqual(pet.brain.mood, .stuffed)
        XCTAssertTrue(pet.played(20...30).contains { $0.behaviour == .satisfied(.brim) })
        let posture = boopPosture(pet, boop)
        XCTAssertEqual(posture.body.glow, PetPosture.stuffed.body.glow, accuracy: 1e-9)
        XCTAssertEqual(posture.body.armL, PetPosture.stuffed.body.armL, accuracy: 1e-9, "the nubs on the belly")
    }

    /// Booped during the grateful beat, a famished pet the meal has fed out of it is no longer famished: no
    /// shining eyes on tiptoe after the food.
    func testABoopAfterAFamishedPetsMealIsNoLongerFamished() throws {
        let (pet, boop) = try boopedAfterAMeal(from: 96, points: 3)
        XCTAssertEqual(pet.brain.mood, .hungry)
        XCTAssertTrue(pet.played(20...30).contains { $0.behaviour == .satisfied(.grateful) })
        let posture = boopPosture(pet, boop)
        XCTAssertEqual(posture.body.shine, 0, accuracy: 1e-9)
        XCTAssertEqual(posture.foodLean, 0, accuracy: 1e-9)
        XCTAssertEqual(posture.body.glow, PetPosture.content.body.glow, accuracy: 1e-9, "a boop's own face, as at any mood between the ends")
    }

    /// At rest the boop keeps the mood it rests in, as before.
    func testABoopAtRestKeepsTheEnd() throws {
        for (hunger, mood) in [(-46.0, PetMood.stuffed), (96, .famished)] {
            var pet = PetHarness(hunger: hunger)
            pet.start()
            pet.send(.boop, at: 30)
            pet.run(to: 31)
            let boop = try XCTUnwrap(pet.played(0...31).first { if case .boop = $0.behaviour { return true }; return false })
            XCTAssertEqual(boopPosture(pet, boop).body.glow, PetPosture.mood(mood).body.glow, accuracy: 1e-9, "\(mood)")
        }
    }

    // MARK: - Rest, absence and the panel

    /// A first reading at 100 % is not food: famished, the pet falls asleep at the 5-hour limit like any pet,
    /// and with the hunger clock stopped it wakes famished after the reset.
    func testFamishedSleepsAtTheLimitAndWakesFamished() {
        var pet = PetHarness(hunger: 96)
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 100, fiveReset: 600)]
        pet.start()
        XCTAssertEqual(pet.behaviour(at: 0), .asleep)
        pet.accounts[0].five = 0
        pet.accounts[0].fiveReset = 600 + 5 * 3600
        pet.refresh(at: 600)
        pet.run(to: 620)
        XCTAssertEqual(pet.played(0...620).map(\.behaviour), [.asleep, .wake, .idle(.famished)])
    }

    /// Stuffed at the weekly limit: into the den and, the clock stopped all along, out of it stuffed.
    func testStuffedHibernatesAndLeavesTheDenStuffed() {
        var pet = PetHarness(hunger: -46)
        pet.refreshEvery = nil
        pet.accounts = [.init(id: "a", five: 10, week: 100, weekReset: 900)]
        pet.start()
        XCTAssertEqual(pet.behaviour(at: 0), .hibernating)
        pet.accounts[0].week = 0
        pet.accounts[0].weekReset = 900 + 7 * 86_400
        pet.refresh(at: 905)
        pet.run(to: 930)
        XCTAssertEqual(pet.played(0...930).last?.behaviour, .idle(.stuffed))
        XCTAssertEqual(pet.meter(at: 900), -46, accuracy: 1e-9, "no hunger in the den")
    }

    /// Stale numbers and an absence stop the hunger clock but change nothing else: famished before, famished
    /// after, through `unsureIdle`, the doze and the welcome back.
    func testFamishedHoldsThroughStaleNumbersAndAnAbsence() {
        var pet = PetHarness(hunger: 96)
        pet.refreshEvery = nil
        pet.start()
        pet.run(to: 700)
        XCTAssertEqual(pet.behaviour(at: 700), .unsureIdle(.famished))
        pet.refresh(at: 700)
        pet.idleSince = 710
        pet.run(to: 1400)
        pet.idleSince = nil
        pet.refresh(at: 1400)
        pet.run(to: 1420)
        let played = pet.played(0...1420).map(\.behaviour)
        XCTAssertTrue(played.contains(.doze), "\(played)")
        XCTAssertTrue(played.contains(.welcomeBack), "\(played)")
        XCTAssertEqual(played.last, .idle(.famished))
    }

    /// Settled at an end, the hand that comes back to open the panel is someone at the Mac: the presence
    /// check its pointer asks for makes the pet idle again, and the greeting comes 0.6 s after the opening.
    func testAHandBackFromSettledIsGreeted() {
        var pet = PetHarness(hunger: -46)
        pet.idleSince = 0
        pet.start()
        pet.run(to: 300)
        XCTAssertEqual(pet.behaviour(at: 300), .settled(.stuffed))
        pet.idleSince = nil
        pet.send(.presence(pet.presence(at: 300)), at: 300)
        pet.send(.panel(open: true), at: 300)
        pet.run(to: 302)
        XCTAssertEqual(greetings(pet), [300.6])
    }

    /// A feast big enough to take a famished pet all the way past the brim is still the grateful meal it was
    /// planned as; then it rests stuffed.
    func testAFamishedFeastThatLeavesItStuffedIsGrateful() {
        var pet = PetHarness(hunger: 95)
        pet.accounts[0].five = 10
        pet.start()
        pet.accounts[0].five = 33
        pet.refresh(at: 20)
        pet.run(to: 40)
        let played = pet.played(0...40).map(\.behaviour)
        XCTAssertTrue(played.contains(.satisfied(.grateful)), "\(played)")
        XCTAssertEqual(played.last, .idle(.stuffed))
    }

    /// Turned off with the panel open, and on again later: the opening's greeting went with the pet.
    func testTurnedOffAndOnAgainNoGreetingIsLeftOver() {
        var pet = PetHarness(hunger: 96)
        pet.start()
        pet.send(.panel(open: true), at: 10)
        pet.send(.showPet(false), at: 10.2)
        pet.send(.showPet(true), at: 30)
        pet.run(to: 40)
        XCTAssertTrue(greetings(pet).isEmpty)
        XCTAssertEqual(pet.played(0...40).last?.behaviour, .idle(.famished))
    }

    // MARK: - Random days

    /// Random days at the ends of the meter: use small and large, resets, the panel opening for a look,
    /// prompts, boops, absences, the pet unseen, the weekly limit, the pet turned off, stale numbers, Reduce
    /// Motion, the Mac asleep, no accounts. After every step, and over each whole day:
    /// - a greeting is cued only 0.6 s after an opening, the panel still open, Reduce Motion off, in an idle
    ///   at an end, and at most one every 3 minutes;
    /// - the open behaviour playing wears the brain's mood;
    /// - by time alone the meter only rises: the pet never becomes stuffed and never stops being famished
    ///   without food (a meal, or at rest and off, where the plate is cleared into the meter);
    /// - a full meal or a feast planned famished is followed by the grateful beat, and only such a meal; the
    ///   brim leaves it stuffed;
    /// - no mood comes back within a second of leaving it;
    /// - the same day played twice gives the same timeline.
    func testRandomDaysKeepTheRulesOfBothEnds() {
        let sweep = PetZoneSweepTests.full
        let seeds: ClosedRange<UInt64> = sweep ? 1...120 : 1...6
        let hours = sweep ? 8.0 : 5
        var moods = Set<PetMood>()
        for seed in seeds {
            let hunger = [-46.0, -20, 30, 80, 96][Int(seed % 5)]
            let day = RandomDay(seed: seed, hours: hours, hunger: hunger)
            for segment in day.pet.played(0...(hours * 3600 + 60)) {
                if let mood = RandomDay.mood(of: segment.behaviour) { moods.insert(mood) }
            }
            let problems = day.problems + day.wholeDayProblems()
            XCTAssertTrue(problems.isEmpty, "seed \(seed): \(problems.prefix(5))")
            let again = RandomDay(seed: seed, hours: hours, hunger: hunger)
            XCTAssertEqual(again.pet.brain.timeline, day.pet.brain.timeline, "seed \(seed): the same events, the same timeline")
        }
        XCTAssertTrue(moods.isSuperset(of: [.stuffed, .famished]), "the days reach both ends: \(moods)")
    }
}

/// One random day of a pet, played through `PetHarness` with the rules checked after every step.
private struct RandomDay {
    var pet: PetHarness
    var problems: [String] = []
    private var opens: [Double] = []
    private var closes: [Double] = []
    private var reduceMotion: [(t: Double, on: Bool)] = []

    /// SplitMix-like, so a seed is a day.
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func mood(of behaviour: PetBehaviour) -> PetMood? {
        switch behaviour {
        case .idle(let m), .settled(let m), .unsureIdle(let m): return m
        default: return nil
        }
    }

    init(seed: UInt64, hours: Double, hunger: Double) {
        var random = Random(state: seed)
        pet = PetHarness(seed: seed, hunger: hunger)
        pet.accounts = [.init(id: "a", five: 5, fiveReset: 5 * 3600, week: 20, weekReset: 3 * 86_400)]
        pet.start()
        var t = 0.0, five = 5.0, fiveReset = 5.0 * 3600
        var visible = true, idle = false, reduce = false
        while t < hours * 3600 {
            t += 1 + random.next() * 240
            let r = random.next()
            switch r {
            case ..<0.25:
                // Use: a little, now and then a lot.
                five = min(100, five + (random.next() < 0.15 ? 5 + random.next() * 20 : random.next() * 3))
                pet.accounts[0].five = five
                pet.refresh(at: t)
            case ..<0.30 where t > fiveReset:
                fiveReset = t + 5 * 3600
                five = random.next() * 5
                pet.accounts[0].five = five
                pet.accounts[0].fiveReset = fiveReset
                pet.refresh(at: t)
            case ..<0.42:
                // The panel opened for a look of up to 6 s.
                pet.send(.panel(open: true), at: t)
                opens.append(t)
                t += random.next() * 6
                pet.run(to: t)
                pet.send(.panel(open: false), at: t)
                closes.append(t)
            case ..<0.50:
                pet.send(.prompt, at: t)
            case ..<0.55:
                pet.send(.boop, at: t)
            case ..<0.62:
                idle.toggle()
                pet.idleSince = idle ? t : nil
                pet.run(to: t)
            case ..<0.64:
                visible.toggle()
                pet.send(.visible(visible), at: t)
            case ..<0.642:
                pet.accounts[0].week = random.next() < 0.5 ? 100 : 30
                pet.refresh(at: t)
            case ..<0.644:
                pet.send(.showPet(false), at: t)
                t += random.next() * 600
                pet.send(.showPet(true), at: t)
            case ..<0.646:
                pet.refreshEvery = pet.refreshEvery == nil ? 60 : nil
                pet.run(to: t)
            case ..<0.647:
                reduce.toggle()
                reduceMotion.append((t, reduce))
                pet.send(.motion(PetMotion(reduceMotion: reduce, reduceTransparency: false, increaseContrast: false)), at: t)
            case ..<0.649:
                // The Mac asleep for up to two hours: the wall clock moves on, the monotonic one does not.
                pet.send(.systemSleep, at: t)
                pet.send(.visible(false), at: t)
                pet.wallShift += random.next() * 7200
                pet.send(.systemWake, at: t + 1)
                t += 1
                pet.refresh(at: t)
                pet.send(.presence(pet.presence(at: t)), at: t)
                pet.send(.visible(visible), at: t)
            case ..<0.650:
                let accounts = pet.accounts
                pet.accounts = []
                pet.refresh(at: t)
                t += random.next() * 300
                pet.accounts = accounts
                pet.refresh(at: t)
            default:
                pet.run(to: t)
            }
            check(at: t)
        }
    }

    /// The rules that hold at every step.
    private mutating func check(at t: Double) {
        let brain = pet.brain
        let greetings = brain.timeline.cues.filter { $0.kind == .greet }.map(\.t)
        for g in greetings {
            switch pet.behaviour(at: g) {
            case .idle(.stuffed)?, .idle(.famished)?: break
            case let other: problems.append("a greeting at \(g) during \(String(describing: other))")
            }
            guard let open = opens.last(where: { $0 <= g + 1e-9 }) else {
                problems.append("a greeting at \(g) with no opening")
                continue
            }
            if abs(g - open - PetTuning.Greet.after) > 1e-6 { problems.append("a greeting at \(g) for the opening at \(open)") }
            if closes.contains(where: { $0 > open && $0 < g }) { problems.append("a greeting at \(g) after the panel closed") }
            if reduceMotion.last(where: { $0.t <= g })?.on ?? false { problems.append("a greeting at \(g) under Reduce Motion") }
        }
        for (a, b) in zip(greetings, greetings.dropFirst()) where b - a < PetTuning.Greet.every - 1e-6 {
            problems.append("greetings at \(a) and \(b)")
        }
        if case .awake(let mood) = brain.condition, let playing = brain.timeline.segments.last(where: { $0.start <= t }),
           case .idle(let m) = playing.behaviour, m != mood {
            problems.append("at \(t) \(playing.behaviour) while the brain's mood is \(mood)")
        }
    }

    /// The rules over the whole day's log.
    func wholeDayProblems() -> [String] {
        var problems: [String] = []
        let log = pet.played(0...Double.greatestFiniteMagnitude)
        var last: PetMood?
        var fed = false
        var meal: PetMeal?
        for (i, segment) in log.enumerated() {
            switch segment.behaviour {
            case .eat(let m):
                fed = true
                meal = m
            case .fallAsleep, .asleep, .enterDen, .hibernating, .denWait, .off:
                // At rest and off the plate is cleared into the meter, without a meal.
                fed = true
            case .satisfied(let kind):
                guard let meal else { break }
                let next = log.dropFirst(i + 1).lazy.compactMap { Self.mood(of: $0.behaviour) }.first
                if meal.mood == .famished, meal.size == .full || meal.feast, kind != .grateful {
                    problems.append("\(segment.start): \(kind) after a meal planned famished")
                }
                if kind == .grateful, meal.mood != .famished { problems.append("\(segment.start): grateful after a \(meal.mood) meal") }
                if kind == .brim, next != .stuffed { problems.append("\(segment.start): the brim, then \(String(describing: next))") }
            default:
                break
            }
            guard let mood = Self.mood(of: segment.behaviour) else { continue }
            if let before = last, before != mood, !fed {
                let order = PetMood.allCases
                if order.firstIndex(of: mood)! < order.firstIndex(of: before)! {
                    problems.append("\(segment.start): \(before) to \(mood) without food")
                }
            }
            last = mood
            fed = false
        }
        var changes: [(t: Double, mood: PetMood)] = []
        for segment in log {
            guard let mood = Self.mood(of: segment.behaviour), changes.last?.mood != mood else { continue }
            changes.append((segment.start, mood))
        }
        for k in changes.indices.dropFirst(2) where changes[k].mood == changes[k - 2].mood && changes[k].t - changes[k - 1].t < 1 {
            problems.append("\(changes[k - 1].t): \(changes[k - 2].mood), \(changes[k - 1].mood), \(changes[k].mood) within a second")
        }
        return problems
    }
}
