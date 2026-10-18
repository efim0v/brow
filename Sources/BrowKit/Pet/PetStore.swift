// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// Everything `pet.json` holds: the pet's seed, its hunger, what it has seen of each account's periods,
/// its fed days and good weeks. Not the plate, the behaviour or the pointer: a relaunch starts in the
/// condition the data says, in idle, with H as saved, and the time Brow was not running is away time.
///
/// Every field has a default and is read on its own, the way `BrowSettings` reads `config.json`: a
/// field this build cannot read costs that field, not the pet, and a field it does not know is
/// ignored. Nothing in it leaves the Mac; it holds organisation ids (already in `limits.json`),
/// dates and numbers.
public struct PetSave: Codable, Sendable, Equatable {
    /// The file's format. A newer one is read for what this build knows and never written over
    /// (`PetStore.save`), so going back to an older Brow and forward again loses nothing.
    public var v: Int
    public var seed: UInt64
    public var bornAt: Date
    public var introDone: Bool
    public var hunger: Double
    public var savedAt: Date
    /// When the last meal started.
    public var lastMealAt: Date?
    /// What it held, for the panel's `Ate 3 % · 2 min ago` after a relaunch.
    public var lastMealPoints: Double?
    public var trackers: [String: PetPeriods]
    public var days: [String: Double]
    public var streak: PetStreak
    public var goodWeeks: [String]
    public var lastGoodWeekCelebratedAt: Date?
    /// The good weeks of the last day, for their panel lines after a relaunch.
    public var goodWeekLines: [PetGoodWeekLine]

    /// A pet that has just been born: H 30, every tracker empty, so its first readings are baselines.
    public init(seed: UInt64, bornAt: Date) {
        v = PetTuning.Store.version
        self.seed = seed
        self.bornAt = bornAt
        introDone = false
        hunger = PetTuning.Hunger.newPet
        savedAt = bornAt
        lastMealAt = nil
        lastMealPoints = nil
        trackers = [:]
        days = [:]
        streak = PetStreak()
        goodWeeks = []
        lastGoodWeekCelebratedAt = nil
        goodWeekLines = []
    }

    private enum CodingKeys: String, CodingKey {
        case v, seed, bornAt, introDone, hunger, savedAt, lastMealAt, lastMealPoints, trackers, days, streak,
             goodWeeks, lastGoodWeekCelebratedAt, goodWeekLines
    }

    /// One unreadable entry of a list or a map is dropped on its own.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }

    /// Lenient field by field. A missing seed is the caller's to fill (`PetStore.load` draws one),
    /// so it decodes as 0 and `hasSeed` says so.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        v = field(Int.self, .v) ?? PetTuning.Store.version
        seed = field(UInt64.self, .seed) ?? 0
        hasSeed = field(UInt64.self, .seed) != nil
        bornAt = field(Date.self, .bornAt) ?? .distantPast
        introDone = field(Bool.self, .introDone) ?? false
        hunger = min(max(field(Double.self, .hunger) ?? PetTuning.Hunger.newPet, PetTuning.Hunger.minimum),
                     PetTuning.Hunger.maximum)
        savedAt = field(Date.self, .savedAt) ?? .distantPast
        lastMealAt = field(Date.self, .lastMealAt)
        lastMealPoints = field(Double.self, .lastMealPoints)
        trackers = (field([String: Lenient<PetPeriods>].self, .trackers) ?? [:]).compactMapValues(\.value)
        days = (field([String: Lenient<Double>].self, .days) ?? [:]).compactMapValues(\.value)
        streak = field(PetStreak.self, .streak) ?? PetStreak()
        goodWeeks = (field([Lenient<String>].self, .goodWeeks) ?? []).compactMap(\.value)
        lastGoodWeekCelebratedAt = field(Date.self, .lastGoodWeekCelebratedAt)
        goodWeekLines = (field([Lenient<PetGoodWeekLine>].self, .goodWeekLines) ?? []).compactMap(\.value)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(seed, forKey: .seed)
        try c.encode(bornAt, forKey: .bornAt)
        try c.encode(introDone, forKey: .introDone)
        try c.encode(hunger, forKey: .hunger)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encodeIfPresent(lastMealAt, forKey: .lastMealAt)
        try c.encodeIfPresent(lastMealPoints, forKey: .lastMealPoints)
        try c.encode(trackers, forKey: .trackers)
        try c.encode(days, forKey: .days)
        try c.encode(streak, forKey: .streak)
        try c.encode(goodWeeks, forKey: .goodWeeks)
        try c.encodeIfPresent(lastGoodWeekCelebratedAt, forKey: .lastGoodWeekCelebratedAt)
        try c.encode(goodWeekLines, forKey: .goodWeekLines)
    }

    /// False for a file that had no seed: not encoded, and not compared.
    var hasSeed = true

    public static func == (a: PetSave, b: PetSave) -> Bool {
        a.v == b.v && a.seed == b.seed && a.bornAt == b.bornAt && a.introDone == b.introDone && a.hunger == b.hunger
            && a.savedAt == b.savedAt && a.lastMealAt == b.lastMealAt && a.lastMealPoints == b.lastMealPoints
            && a.trackers == b.trackers && a.days == b.days && a.streak == b.streak && a.goodWeeks == b.goodWeeks
            && a.lastGoodWeekCelebratedAt == b.lastGoodWeekCelebratedAt && a.goodWeekLines == b.goodWeekLines
    }

    /// Keeps the file in shape whatever the clock did: no instant after `now`, so a clock that went back
    /// after a save never makes a negative gap; the last 60 dates and 16 good weeks; the good-week lines
    /// of the last day.
    func tidied(now: Date) -> PetSave {
        var save = self
        save.bornAt = min(save.bornAt, now)
        save.savedAt = min(save.savedAt, now)
        save.lastMealAt = save.lastMealAt.map { min($0, now) }
        save.lastGoodWeekCelebratedAt = save.lastGoodWeekCelebratedAt.map { min($0, now) }
        if save.days.count > PetTuning.Store.keptDays {
            for day in save.days.keys.sorted().prefix(save.days.count - PetTuning.Store.keptDays) { save.days[day] = nil }
        }
        if save.goodWeeks.count > PetTuning.Store.keptGoodWeeks {
            // By the reset each one names, so the newest are kept even from a file that was reordered.
            let epoch = { (key: String) in Int(key.split(separator: "@").last ?? "") ?? 0 }
            save.goodWeeks = Array(save.goodWeeks.sorted { epoch($0) < epoch($1) }.suffix(PetTuning.Store.keptGoodWeeks))
        }
        save.goodWeekLines = save.goodWeekLines.filter { now.timeIntervalSince($0.at) < PetTuning.Moments.goodWeekLine }
        return save
    }
}

/// `<directory>/pet.json`, beside `config.json` and `limits.json`, so the README's uninstall already
/// removes it. Atomic writes, like `LimitSnapshotStore`; an unreadable file is logged and replaced by a
/// new pet, and the app starts either way.
public struct PetStore: Sendable {
    public static let defaultDirectory = BrowSettingsStore.defaultDirectory

    private let directory: String
    private var file: String { directory + "/" + PetTuning.Store.fileName }

    public init(directory: String = PetStore.defaultDirectory) {
        self.directory = directory
    }

    /// What was on disk.
    public enum Origin: Sendable, Equatable {
        /// No file: a first launch for the pet.
        case new
        case found
        /// Not JSON, or not an object: logged at `.error`, and a new pet with a new seed.
        case unreadable
        /// Written by a newer Brow: read for what this build knows, and left as it is.
        case newer(version: Int)
    }

    /// The pet to start with. `newSeed` is called only for a new pet; the app's draws from
    /// `SystemRandomNumberGenerator`, the only randomness the pet ever has.
    public func load(now: Date, newSeed: () -> UInt64 = PetStore.randomSeed) -> (save: PetSave, origin: Origin) {
        let path = file
        guard let data = FileManager.default.contents(atPath: path) else {
            return (PetSave(seed: newSeed(), bornAt: now), .new)
        }
        var save: PetSave
        do {
            save = try Self.decoder.decode(PetSave.self, from: data)
        } catch {
            BrowLog.pet.error("pet.json unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public); a new pet")
            return (PetSave(seed: newSeed(), bornAt: now), .unreadable)
        }
        if !save.hasSeed {
            save.seed = newSeed()
            save.hasSeed = true
        }
        if save.bornAt == .distantPast { save.bornAt = now }
        if save.savedAt == .distantPast { save.savedAt = now }
        let origin: Origin = save.v > PetTuning.Store.version ? .newer(version: save.v) : .found
        if case .newer(let version) = origin {
            BrowLog.pet.error("pet.json is version \(version, privacy: .public), newer than this build's; read, not written")
        }
        return (save.tidied(now: now), origin)
    }

    /// Writes `save` atomically. A file a newer Brow wrote is left alone, and this returns false: the
    /// pet still runs, it just does not overwrite what the newer build will want back.
    @discardableResult
    public func save(_ save: PetSave) throws -> Bool {
        if let data = FileManager.default.contents(atPath: file),
           let existing = try? Self.decoder.decode(Version.self, from: data),
           let version = existing.v, version > PetTuning.Store.version {
            if Self.newerReport.fire() {
                BrowLog.pet.error("pet.json was written by a newer Brow (version \(version, privacy: .public)); not saving over it")
            }
            return false
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var tidy = save.tidied(now: save.savedAt)
        tidy.v = PetTuning.Store.version
        try Self.encoder.encode(tidy).write(to: URL(fileURLWithPath: file), options: .atomic)
        return true
    }

    public static func randomSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }

    private struct Version: Decodable { let v: Int? }

    private static let newerReport = OneShot()

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

/// When to write `pet.json`: at every condition change, at most once a minute after a meal, and every
/// 10 minutes while running. The controller also writes on `willSleepNotification` and in
/// `applicationWillTerminate`, whatever this says. Pure, with the monotonic clock passed in.
public struct PetSaveSchedule: Sendable, Equatable {
    public private(set) var lastSave: TimeInterval?
    private var meals = 0
    private var conditionChanges = 0

    public init() {}

    public func isDue(at mono: TimeInterval, brain: PetBrain) -> Bool {
        guard let lastSave else { return true }
        if brain.conditionChanges != conditionChanges { return true }
        if brain.meals != meals && mono - lastSave >= PetTuning.Store.afterMealAtMost { return true }
        return mono - lastSave >= PetTuning.Store.every
    }

    /// When to ask `isDue` again if no event comes first.
    public func nextCheck(brain: PetBrain) -> TimeInterval? {
        guard let lastSave else { return nil }
        return lastSave + (brain.meals != meals ? PetTuning.Store.afterMealAtMost : PetTuning.Store.every)
    }

    public mutating func saved(at mono: TimeInterval, brain: PetBrain) {
        lastSave = mono
        meals = brain.meals
        conditionChanges = brain.conditionChanges
    }
}

// MARK: - The brain from and to pet.json

extension PetBrain {
    /// A pet as `pet.json` left it. A relaunch is away time: H as saved, the trackers as they were (so
    /// growth while Brow was not running is a catch-up meal), and the condition the next readings
    /// give.
    public init(restoring save: PetSave) {
        self.init(seed: save.seed)
        hunger = PetHunger(value: save.hunger)
        mood = PetHunger.moodOnTheWayUp(hunger.value)
        unsureMood = mood
        food = PetFood(trackers: save.trackers)
        moments.days = save.days
        moments.streak = save.streak
        moments.goodWeeks = save.goodWeeks
        moments.lastGoodWeekCelebratedAt = save.lastGoodWeekCelebratedAt
        moments.goodWeekLines = save.goodWeekLines
        introDone = save.introDone
        bornAt = save.bornAt
        lastMealWall = save.lastMealAt
        lastMealPoints = save.lastMealPoints
    }

    /// What to write to `pet.json` at `time`.
    public func save(at time: PetTime) -> PetSave {
        let now = brought(to: time)
        var save = PetSave(seed: seed, bornAt: bornAt ?? time.wall)
        save.introDone = introDone
        save.hunger = now.hunger.value
        save.savedAt = time.wall
        save.lastMealAt = now.lastMealWall
        save.lastMealPoints = now.lastMealPoints
        save.trackers = now.food.trackers
        save.days = now.moments.days
        save.streak = now.moments.streak
        save.goodWeeks = now.moments.goodWeeks
        save.lastGoodWeekCelebratedAt = now.moments.lastGoodWeekCelebratedAt
        save.goodWeekLines = now.moments.goodWeekLines
        return save.tidied(now: time.wall)
    }
}
