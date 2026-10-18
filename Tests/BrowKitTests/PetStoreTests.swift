// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// `pet.json`, and the pet it brings back after a relaunch. Every test works in its own temporary
/// directory.
final class PetStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)       // 2026-10-15 12:00:00 UTC

    private func store(_ label: String) throws -> (PetStore, String) {
        let dir = try Fixture.tempDir("pet-\(label)").path
        return (PetStore(directory: dir), dir + "/pet.json")
    }

    private func sample() -> PetSave {
        var save = PetSave(seed: 1_311_768_467_294_899_695, bornAt: now.addingTimeInterval(-86_400))
        save.introDone = true
        save.hunger = 22.5
        save.savedAt = now
        save.lastMealAt = now.addingTimeInterval(-271)
        save.lastMealPoints = 3.2
        save.trackers = ["org-1234": PetPeriods(fiveHour: PetPeriod(resetAt: now.addingTimeInterval(7200), high: 41),
                                                sevenDay: PetPeriod(resetAt: now.addingTimeInterval(3 * 86_400), high: 63))]
        save.days = ["2026-10-14": 31.2, "2026-10-15": 12.8]
        save.streak = PetStreak(count: 6, lastFedDay: "2026-10-15", celebrated: [3])
        save.goodWeeks = ["org-1234@1760925600"]
        save.lastGoodWeekCelebratedAt = now.addingTimeInterval(-5 * 86_400)
        save.goodWeekLines = [PetGoodWeekLine(account: "org-1234", used: 82, at: now.addingTimeInterval(-3600))]
        return save
    }

    func testARoundTripIsEqual() throws {
        let (store, path) = try store("round-trip")
        XCTAssertTrue(try store.save(sample()))
        let loaded = store.load(now: now)
        XCTAssertEqual(loaded.origin, .found)
        XCTAssertEqual(loaded.save, sample())
        // The seed is above 2^53: it must come back to the bit, not by way of a Double.
        XCTAssertEqual(loaded.save.seed, 1_311_768_467_294_899_695)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"seed\" : 1311768467294899695"), text)
        XCTAssertTrue(text.contains("\"savedAt\" : \"2026-10-15T12:00:00Z\""), "ISO 8601 dates")
    }

    func testNoFileIsANewPet() throws {
        let (store, path) = try store("new")
        let loaded = store.load(now: now, newSeed: { 42 })
        XCTAssertEqual(loaded.origin, .new)
        XCTAssertEqual(loaded.save.seed, 42)
        XCTAssertEqual(loaded.save.hunger, 30)
        XCTAssertFalse(loaded.save.introDone)
        XCTAssertTrue(loaded.save.trackers.isEmpty, "the first readings are baselines")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "loading writes nothing")
    }

    /// A corrupt file must never keep the app from starting: it is a new pet with a new seed.
    func testACorruptFileIsANewPet() throws {
        let (store, path) = try store("corrupt")
        for junk in ["not json", "[1, 2]", "\"text\"", ""] {
            try junk.write(toFile: path, atomically: true, encoding: .utf8)
            let loaded = store.load(now: now, newSeed: { 7 })
            XCTAssertEqual(loaded.origin, .unreadable, junk)
            XCTAssertEqual(loaded.save.seed, 7, junk)
        }
        XCTAssertTrue(try store.save(PetSave(seed: 7, bornAt: now)), "and it is replaced")
        XCTAssertEqual(store.load(now: now).origin, .found)
    }

    /// Every field has a default and a bad one costs only itself; a field this build does not know is
    /// ignored.
    func testMissingBadAndUnknownFields() throws {
        let (store, path) = try store("lenient")
        try #"""
        {"v": 1, "seed": 99, "hunger": "lots", "introDone": true, "wings": 2,
         "trackers": {"a": {"fiveHour": {"resetAt": "2026-10-15T14:00:00Z", "high": 41}},
                      "b": {"fiveHour": {"high": 3}}, "c": 5},
         "days": {"2026-10-14": 12, "2026-10-15": "x"},
         "streak": {"count": 4},
         "goodWeeks": ["a@1", 7]}
        """#.write(toFile: path, atomically: true, encoding: .utf8)
        let save = store.load(now: now).save
        XCTAssertEqual(save.seed, 99)
        XCTAssertEqual(save.hunger, 30, "an unreadable H is a new pet's")
        XCTAssertTrue(save.introDone)
        XCTAssertEqual(save.trackers["a"]?.fiveHour, PetPeriod(resetAt: now.addingTimeInterval(7200), high: 41))
        XCTAssertEqual(save.trackers["b"], PetPeriods(), "a period with no reset instant is dropped")
        XCTAssertNil(save.trackers["c"])
        XCTAssertEqual(save.days, ["2026-10-14": 12])
        XCTAssertEqual(save.streak, PetStreak(count: 4))
        XCTAssertEqual(save.goodWeeks, ["a@1"])
        XCTAssertEqual(save.bornAt, now, "no birth date: born now")

        try #"{"v": 1}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let bare = store.load(now: now, newSeed: { 5 }).save
        XCTAssertEqual(bare.seed, 5, "no seed: one is drawn")
        XCTAssertEqual(bare.hunger, 30)
    }

    /// The clock went back after a save: no instant after now, so no negative gap anywhere.
    func testInstantsInTheFutureAreTakenAsNow() throws {
        let (store, _) = try store("future")
        var save = sample()
        save.savedAt = now.addingTimeInterval(3600)
        save.lastMealAt = now.addingTimeInterval(1800)
        try store.save(save)
        let loaded = store.load(now: now).save
        XCTAssertEqual(loaded.savedAt, now)
        XCTAssertEqual(loaded.lastMealAt, now)
    }

    func testOldDaysAndGoodWeeksAreTrimmed() throws {
        let (store, _) = try store("trim")
        var save = sample()
        save.days = Dictionary(uniqueKeysWithValues: (0..<70).map {
            (PetMoments.day(now.addingTimeInterval(-Double($0) * 86_400), in: TimeZone(identifier: "UTC")!), 1.0)
        })
        save.goodWeeks = (0..<20).map { "org@\(1_760_000_000 + $0 * 604_800)" }.shuffled()
        try store.save(save)
        let loaded = store.load(now: now).save
        XCTAssertEqual(loaded.days.count, 60)
        XCTAssertEqual(loaded.days.keys.sorted().last, "2026-10-15")
        XCTAssertEqual(loaded.days.keys.sorted().first, "2026-08-17")
        XCTAssertEqual(loaded.goodWeeks.count, 16)
        XCTAssertEqual(loaded.goodWeeks.first, "org@\(1_760_000_000 + 4 * 604_800)")
    }

    /// A newer Brow's file is read for what this build knows, and never written over.
    func testANewerFileIsReadAndLeftAlone() throws {
        let (store, path) = try store("newer")
        let newer = #"{"v": 2, "seed": 11, "hunger": 40, "introDone": true, "mood": "new in v2"}"#
        try newer.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = store.load(now: now)
        XCTAssertEqual(loaded.origin, .newer(version: 2))
        XCTAssertEqual(loaded.save.seed, 11)
        XCTAssertEqual(loaded.save.hunger, 40)
        XCTAssertFalse(try store.save(loaded.save))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), newer)
    }

    /// The file stays under 8 KB with everything it keeps full: ten accounts, 60 days, 16 good weeks.
    func testAFullFileStaysUnderEightKilobytes() throws {
        let (store, path) = try store("size")
        var save = sample()
        for n in 0..<10 {
            save.trackers["01234567-89ab-cdef-0123-456789abcd\(n)\(n)"] = PetPeriods(
                fiveHour: PetPeriod(resetAt: now, high: 41.25, closed: true), sevenDay: PetPeriod(resetAt: now, high: 63.5))
        }
        save.days = Dictionary(uniqueKeysWithValues: (0..<60).map {
            (PetMoments.day(now.addingTimeInterval(-Double($0) * 86_400), in: TimeZone(identifier: "UTC")!), 31.234567)
        })
        save.goodWeeks = (0..<16).map { "01234567-89ab-cdef-0123-456789abcdef@\(1_760_000_000 + $0 * 604_800)" }
        save.streak = PetStreak(count: 100, lastFedDay: "2026-10-15", celebrated: [3, 7, 14, 30, 60, 100])
        try store.save(save)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        XCTAssertLessThan(size, PetTuning.Store.maximumBytes)
    }

    // MARK: - The schedule

    func testItIsWrittenAtConditionChangesAfterMealsAndEveryTenMinutes() {
        var brain = PetBrain(seed: 1)
        var schedule = PetSaveSchedule()
        XCTAssertTrue(schedule.isDue(at: 0, brain: brain), "never saved")
        schedule.saved(at: 0, brain: brain)
        XCTAssertFalse(schedule.isDue(at: 599, brain: brain))
        XCTAssertTrue(schedule.isDue(at: 600, brain: brain))
        XCTAssertEqual(schedule.nextCheck(brain: brain), 600)
        brain.meals += 1
        XCTAssertFalse(schedule.isDue(at: 30, brain: brain), "at most once a minute after a meal")
        XCTAssertTrue(schedule.isDue(at: 60, brain: brain))
        XCTAssertEqual(schedule.nextCheck(brain: brain), 60)
        schedule.saved(at: 60, brain: brain)
        brain.setCondition(.asleep)
        XCTAssertTrue(schedule.isDue(at: 61, brain: brain), "a condition change, at once")
    }

    // MARK: - The pet across a relaunch

    func testABrainComesBackAsItWasSaved() throws {
        let (store, _) = try store("brain")
        var pet = PetHarness(hunger: 44)
        pet.accounts = [.init(id: "a", five: 10, week: 30)]
        pet.start()
        pet.accounts[0].five = 13
        pet.refresh(at: 30)
        pet.run(to: 100)
        try store.save(pet.brain.save(at: pet.time(100)))

        let restored = PetBrain(restoring: store.load(now: pet.time(100).wall).save)
        XCTAssertEqual(restored.seed, pet.brain.seed)
        XCTAssertEqual(restored.hunger.value, pet.brain.hunger.value, accuracy: 1e-9)
        XCTAssertEqual(restored.food, pet.brain.food)
        XCTAssertEqual(restored.moments.days, pet.brain.moments.days)
        XCTAssertEqual(restored.lastMealPoints ?? 0, 3, accuracy: 1e-9)
        XCTAssertTrue(restored.introDone)
    }

    /// What grew while Brow was not running is a catch-up meal at the next launch.
    func testGrowthWhileQuitIsACatchUpMeal() throws {
        let (store, _) = try store("catch-up")
        var before = PetHarness()
        before.accounts = [.init(id: "a", five: 20)]
        before.start()
        try store.save(before.brain.save(at: before.time(10)))

        var after = PetHarness()
        after.brain = PetBrain(restoring: store.load(now: after.time(3600).wall).save)
        after.accounts = [.init(id: "a", five: 35)]
        after.start(at: 3600)
        after.run(to: 3610)
        guard case .eat(let meal)? = after.behaviour(at: 3600) else { return XCTFail("no catch-up meal") }
        XCTAssertEqual(meal.points, 15, accuracy: 1e-9)
    }

    /// A good week celebrated before a relaunch is not celebrated again after it.
    func testAGoodWeekIsNotCelebratedAgainAfterARelaunch() throws {
        let (store, _) = try store("good-week")
        var first = PetHarness()
        first.accounts = [.init(id: "a", five: 10, week: 80, weekReset: 100)]
        first.start()
        first.run(to: 120)
        XCTAssertTrue(first.played(0...120).contains { $0.behaviour == .celebrate(.goodWeek) })
        try store.save(first.brain.save(at: first.time(120)))

        // Relaunched with the old trackers gone missing from the file's point of view: the same week
        // closes again from a stale tracker, and `goodWeeks` stops it being a second celebration.
        var save = store.load(now: first.time(130).wall).save
        save.trackers["a"]?.sevenDay = PetPeriod(resetAt: first.t0.addingTimeInterval(100), high: 80)
        save.lastGoodWeekCelebratedAt = nil             // so only `goodWeeks` can stop it
        XCTAssertEqual(save.goodWeeks, ["a@\(Int(first.t0.timeIntervalSince1970) + 100)"])
        var second = PetHarness()
        second.brain = PetBrain(restoring: save)
        second.accounts = first.accounts
        second.start(at: 130)
        second.run(to: 160)
        XCTAssertFalse(second.played(130...160).contains { $0.behaviour == .celebrate(.goodWeek) })
    }
}
