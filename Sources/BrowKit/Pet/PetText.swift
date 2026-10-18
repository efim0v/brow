// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// What the words are about at one instant, from the brain (`PetBrain.status(at:)`): the panel header
/// and VoiceOver say it, the rig never reads it.
public struct PetStatus: Sendable, Equatable {
    public enum Situation: Sendable, Equatable {
        case off
        case noAccounts
        case hibernating(wakesAt: Date?)
        /// The weekly reset passed and it stirs in the den, waiting for fresh numbers.
        case stirring
        case asleep(wakesAt: Date?)
        case drowsy
        /// No fresh numbers: the mood it had, and when the newest reading was fetched (nil: none yet).
        case unsure(mood: PetMood, newest: Date?)
        case eating(points: Double)
        case eager
        case awake(mood: PetMood)
    }

    public var situation: Situation
    /// What the meter shows, 0 to 100.
    public var meter: Double
    /// When the last meal started, and what it held.
    public var lastMeal: Date?
    public var lastMealPoints: Double?
    /// Pace damping `f` (`PetLimits.pace`): at 0.5 or less the detail adds that the week is well fed.
    public var pace: Double
    /// The header's third line, newest first; the header shows the first.
    public var moments: [PetMomentLine]

    public init(situation: Situation, meter: Double, lastMeal: Date? = nil, lastMealPoints: Double? = nil,
                pace: Double = 1, moments: [PetMomentLine] = []) {
        self.situation = situation
        self.meter = meter
        self.lastMeal = lastMeal
        self.lastMealPoints = lastMealPoints
        self.pace = pace
        self.moments = moments
    }
}

/// Every word the pet says, in one pure place like `PanelText`: `now`, the time zone and the calendar
/// are injected. No line says "you" or judges use: hunger is a mood, a limit used up is a nap, and
/// nothing is ever lost.
public enum PetText {
    /// The panel header's words.
    public struct Header: Sendable, Equatable {
        /// 13 pt semibold: `Content`, `Eating`, `Asleep`.
        public var word: String
        /// 10 pt, one line: `Last meal 3 h ago`.
        public var detail: String
        /// 10 pt, only while a moment is live: `Streak: 7 fed days`.
        public var moment: String?
    }

    /// The accessibility label of the pet in the strip and in the header, and the name of the header's
    /// action, which boops it.
    public static let label = "Pet"
    public static let actionName = "Pet"

    /// - Parameter names: the visible accounts' panel names by organisation. A good week names its
    ///   account when there are several.
    public static func header(_ status: PetStatus, now: Date, timeZone: TimeZone, calendar: Calendar,
                              names: [String: String] = [:]) -> Header {
        let (word, parts) = words(status, now: now, timeZone: timeZone, calendar: calendar)
        return Header(word: word, detail: parts.map(\.shown).joined(separator: " · "),
                      moment: status.moments.first.map { moment($0, names: names) })
    }

    /// The VoiceOver value: the state word, the detail with its units spelled out, the meter.
    /// `Content. Last meal 12 minutes ago. Hunger 20 percent.`
    public static func voiceOverValue(_ status: PetStatus, now: Date, timeZone: TimeZone, calendar: Calendar) -> String {
        let (word, parts) = words(status, now: now, timeZone: timeZone, calendar: calendar)
        let detail = parts.map(\.spoken).joined(separator: ", ")
        let hunger = "Hunger \(Int(min(max(status.meter, 0), 100).rounded())) percent"
        return [word, detail, hunger].filter { !$0.isEmpty }.map { $0 + "." }.joined(separator: " ")
    }

    // MARK: - The words

    /// One piece of a detail line, as the header shows it and as VoiceOver says it.
    struct Part: Equatable {
        var shown: String
        var spoken: String

        init(_ shown: String, spoken: String? = nil) {
            self.shown = shown
            self.spoken = spoken ?? shown
        }
    }

    static func words(_ status: PetStatus, now: Date, timeZone: TimeZone, calendar: Calendar) -> (String, [Part]) {
        switch status.situation {
        case .off:
            return ("", [])
        case .noAccounts:
            return ("Waiting", [Part("No Claude account to eat from yet")])
        case .hibernating(let wakesAt):
            return ("Hibernating", [Part("Weekly limit used up"), wakes(wakesAt, now: now, timeZone: timeZone, calendar: calendar)])
        case .stirring:
            return ("Waking up", [Part("The weekly limit has reset")])
        case .asleep(let wakesAt):
            return ("Asleep", [Part("5-hour limit used up"), wakes(wakesAt, now: now, timeZone: timeZone, calendar: calendar)])
        case .drowsy:
            return ("Waking up", [Part("The 5-hour limit has reset")])
        case .unsure(let mood, let newest):
            guard let newest else { return (word(mood), [Part("No numbers yet")]) }
            let age = duration(now.timeIntervalSince(newest))
            return (word(mood), [Part("No fresh numbers for \(age.shown)", spoken: "No fresh numbers for \(age.spoken)")])
        case .eating(let points):
            let amount = percent(points)
            return ("Eating", [Part("\(amount.shown) of the 5-hour limit", spoken: "\(amount.spoken) of the 5-hour limit")])
        case .eager:
            return ("Waiting for food", [Part("Claude Code is working")])
        case .awake(let mood):
            if let meal = status.lastMeal, now.timeIntervalSince(meal) < PetTuning.Words.recentMeal {
                let amount = percent(status.lastMealPoints ?? 0)
                let ago = age(meal, now: now)
                return (word(mood), [Part("Ate \(amount.shown)", spoken: "Ate \(amount.spoken)"), ago])
            }
            var parts: [Part]
            if let meal = status.lastMeal {
                let ago = age(meal, now: now)
                parts = [Part("Last meal \(ago.shown)", spoken: "Last meal \(ago.spoken)")]
            } else {
                parts = [Part("No meal yet")]
            }
            if status.pace <= PetTuning.Words.wellFedPace { parts.append(Part("well fed this week")) }
            return (word(mood), parts)
        }
    }

    static func word(_ mood: PetMood) -> String {
        switch mood {
        case .full: return "Full"
        case .content: return "Content"
        case .peckish: return "Peckish"
        case .hungry: return "Hungry"
        }
    }

    /// Aggregate points as the readout's percent, rounded: `3 %`, `<1 %` below half a point.
    static func percent(_ points: Double) -> Part {
        guard points >= PetTuning.Words.lessThanOne else { return Part("<1 %", spoken: "less than 1 percent") }
        let whole = Int(points.rounded())
        return Part("\(whole) %", spoken: "\(whole) percent")
    }

    /// `Formatting.age`, with its units spelled out for VoiceOver.
    static func age(_ date: Date, now: Date) -> Part {
        let shown = Formatting.age(date, now: now)
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= 60 else { return Part(shown) }
        return Part(shown, spoken: spelled(seconds) + " ago")
    }

    /// How long something has lasted, in `Formatting.age`'s units: `14 min`, `3 h`, `2 d`.
    static func duration(_ seconds: TimeInterval) -> Part {
        let s = max(0, seconds)
        let shown: String
        if s < 3600 { shown = "\(Int(s / 60)) min" } else if s < 86_400 { shown = "\(Int(s / 3600)) h" } else { shown = "\(Int(s / 86_400)) d" }
        return Part(shown, spoken: spelled(s))
    }

    private static func spelled(_ seconds: TimeInterval) -> String {
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if seconds < 3600 { return unit(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return unit(Int(seconds / 3600), "hour") }
        return unit(Int(seconds / 86_400), "day")
    }

    /// `wakes at 18:40` the same day, `wakes 22 Oct 02:00` another, `wakes when it resets` without a
    /// known reset: the forms `NoticeText` uses, in `en_US_POSIX`.
    static func wakes(_ date: Date?, now: Date, timeZone: TimeZone, calendar: Calendar) -> Part {
        guard let date else { return Part("wakes when it resets") }
        var calendar = calendar
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return Part("wakes at \(formatter.string(from: date))")
        }
        formatter.dateFormat = "d MMM HH:mm"
        return Part("wakes \(formatter.string(from: date))")
    }

    static func moment(_ line: PetMomentLine, names: [String: String]) -> String {
        switch line {
        case .streak(let days):
            return "Streak: \(days) fed days"
        case .goodWeek(let account, let used):
            let percent = Int(used.rounded())
            // Among several accounts the name comes last, so a long one is what the one-line header
            // cuts, never the number.
            if names.count > 1, let name = names[account] { return "Good week: \(percent) % used · \(name)" }
            return "Good week: \(percent) % of the weekly limit used"
        }
    }
}

extension PetBrain {
    /// What the panel header and VoiceOver say at `time`.
    public func status(at time: PetTime) -> PetStatus {
        let now = brought(to: time)
        let playing = now.timeline.segments.last { $0.start <= time.mono }?.behaviour
        let situation: PetStatus.Situation
        if case .eat(let meal)? = playing {
            situation = .eating(points: meal.points)
        } else {
            switch now.condition {
            case .off: situation = .off
            case .noAccounts: situation = .noAccounts
            case .hibernating: situation = now.den.isWaiting ? .stirring : .hibernating(wakesAt: now.den.wakesAt)
            case .asleep: situation = now.nap.isWaiting ? .drowsy : .asleep(wakesAt: now.nap.wakesAt)
            case .unsure:
                situation = .unsure(mood: now.unsureMood, newest: now.accounts?.compactMap { $0.reading?.fetchedAt }.max())
            case .awake(let mood):
                situation = playing == .eager || playing == .perk(.prompt) ? .eager : .awake(mood: mood)
            }
        }
        return PetStatus(situation: situation, meter: min(max(now.meterValue, 0), 100), lastMeal: now.lastMealWall,
                         lastMealPoints: now.lastMealPoints,
                         pace: now.accounts.map { PetLimits.pace($0, now: time.wall, food: now.food) } ?? 1,
                         moments: now.moments.lines(at: time.wall, timeZone: now.timeZone))
    }
}
