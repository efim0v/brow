// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The fed-day streak as `pet.json` keeps it.
public struct PetStreak: Codable, Sendable, Equatable {
    /// Fed days in the streak. It survives two unfed days in a row; the third ends it, silently, and
    /// that is judged when the next fed day comes.
    public var count: Int
    /// `yyyy-MM-dd`, the local date of the streak's last fed day.
    public var lastFedDay: String?
    /// Milestones of this streak already reached, each once, whether it was celebrated or skipped.
    public var celebrated: [Int]

    public init(count: Int = 0, lastFedDay: String? = nil, celebrated: [Int] = []) {
        self.count = count
        self.lastFedDay = lastFedDay
        self.celebrated = celebrated
    }

    private enum CodingKeys: String, CodingKey { case count, lastFedDay, celebrated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        lastFedDay = (try? c.decodeIfPresent(String.self, forKey: .lastFedDay)) ?? nil
        celebrated = (try? c.decodeIfPresent([Int].self, forKey: .celebrated)) ?? []
    }
}

/// A good week the panel mentions for a day: `Good week: 82 % of the weekly limit used`. Kept in
/// `pet.json` so a relaunch inside the day does not lose the line.
public struct PetGoodWeekLine: Codable, Sendable, Equatable {
    /// The organisation; `PetText` gives it the account's panel name when there are several.
    public var account: String
    /// The period's high-water mark.
    public var used: Double
    /// When the week closed: its reset instant.
    public var at: Date
}

/// A line the panel header's third row can show while it is live.
public enum PetMomentLine: Sendable, Equatable {
    /// `Streak: 7 fed days`, for the rest of the day the milestone was reached.
    case streak(days: Int)
    /// `Good week: 82 % of the weekly limit used`, for 24 hours.
    case goodWeek(account: String, used: Double)
}

/// Days, the streak and good weeks. Nothing random and nothing lost: no moment depends on chance, and a
/// broken streak or a light week ends without a word.
public struct PetMoments: Sendable, Equatable {
    /// Points eaten per local date (`yyyy-MM-dd`), the last `PetTuning.Store.keptDays` dates.
    public var days: [String: Double] = [:]
    public var streak = PetStreak()
    /// `org@epochOfReset` of every good week seen, the last `PetTuning.Store.keptGoodWeeks`: each
    /// account's period is a good week once, across relaunches.
    public var goodWeeks: [String] = []
    /// At most one good-week celebration per `PetTuning.Moments.celebrationEvery`.
    public var lastGoodWeekCelebratedAt: Date?
    public var goodWeekLines: [PetGoodWeekLine] = []

    public init() {}

    /// The local date `date` falls on in `timeZone`, as `pet.json` stores it. Food is dated when it
    /// arrives, and a time zone change never rewrites a date already stored.
    public static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The first instant of the local day after the one `date` falls on: when a milestone that could
    /// not be shown that day is skipped.
    public static func endOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    /// Whole days from one stored date to another, by the calendar (time zone free: the dates are
    /// already local).
    static func days(from earlier: String, to later: String) -> Int? {
        let utc = TimeZone(identifier: "UTC")!
        func parse(_ day: String) -> Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let a = parse(earlier), let b = parse(later) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// Credits `points` of food to the local date at `date`. When this makes the day fed, the streak
    /// grows (or starts again after three unfed days), and a milestone it reaches for the first time
    /// in this streak is returned: the caller celebrates it at the meal, or at the first moment the
    /// pet is seen that day.
    public mutating func credit(_ points: Double, at date: Date, timeZone: TimeZone) -> Int? {
        guard points > 0 else { return nil }
        let today = Self.day(date, in: timeZone)
        let before = days[today] ?? 0
        days[today] = before + points
        trimDays()
        guard before < PetTuning.Moments.fedDay, before + points >= PetTuning.Moments.fedDay else { return nil }
        // Fed today. A date already counted (seen twice after a time zone change) is never counted
        // again, and a date before the last fed one (the zone moved west) adds nothing.
        if let last = streak.lastFedDay {
            guard let gap = Self.days(from: last, to: today), gap > 0 else { return nil }
            if gap - 1 > PetTuning.Moments.restDays {
                streak = PetStreak(count: 1, lastFedDay: today, celebrated: [])
            } else {
                streak.count += 1
                streak.lastFedDay = today
            }
        } else {
            streak = PetStreak(count: 1, lastFedDay: today, celebrated: [])
        }
        guard PetTuning.Moments.milestones.contains(streak.count), !streak.celebrated.contains(streak.count)
        else { return nil }
        streak.celebrated.append(streak.count)
        return streak.count
    }

    /// An account's weekly period closed with its high-water mark at `used`. A good week (70 % or more)
    /// is recorded once per account and period, gets its line for a day, and is returned as true when it
    /// may be celebrated: at most one celebration a day, the others get only the line.
    public mutating func weekClosed(account: String, resetAt: Date, used: Double) -> Bool {
        guard used >= PetTuning.Moments.goodWeek else { return false }
        let key = "\(account)@\(Int(resetAt.timeIntervalSince1970))"
        guard !goodWeeks.contains(key) else { return false }
        goodWeeks.append(key)
        if goodWeeks.count > PetTuning.Store.keptGoodWeeks {
            goodWeeks.removeFirst(goodWeeks.count - PetTuning.Store.keptGoodWeeks)
        }
        goodWeekLines.append(PetGoodWeekLine(account: account, used: used, at: resetAt))
        goodWeekLines = goodWeekLines.filter { resetAt.timeIntervalSince($0.at) < PetTuning.Moments.goodWeekLine }
        return true
    }

    /// Whether a good-week celebration may play at `now`, with none in the last day.
    public func mayCelebrateGoodWeek(at now: Date) -> Bool {
        guard let last = lastGoodWeekCelebratedAt else { return true }
        return abs(now.timeIntervalSince(last)) >= PetTuning.Moments.celebrationEvery
    }

    /// The lines live at `now`, newest first: the streak's on the day its milestone was reached, and
    /// each good week's for a day after it closed.
    public func lines(at now: Date, timeZone: TimeZone) -> [PetMomentLine] {
        var lines: [PetMomentLine] = []
        if PetTuning.Moments.milestones.contains(streak.count), streak.celebrated.contains(streak.count),
           streak.lastFedDay == Self.day(now, in: timeZone) {
            lines.append(.streak(days: streak.count))
        }
        for line in goodWeekLines.sorted(by: { $0.at > $1.at }) {
            let age = now.timeIntervalSince(line.at)
            if age >= 0 && age < PetTuning.Moments.goodWeekLine {
                lines.append(.goodWeek(account: line.account, used: line.used))
            }
        }
        return lines
    }

    /// Keeps the newest `PetTuning.Store.keptDays` dates. `yyyy-MM-dd` sorts by date.
    mutating func trimDays() {
        guard days.count > PetTuning.Store.keptDays else { return }
        for day in days.keys.sorted().prefix(days.count - PetTuning.Store.keptDays) { days[day] = nil }
    }
}
