// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

// What the pet eats: the growth of each visible account's 5-hour window inside one period, weighted
// into the units of the left readout. Not the delta of the aggregate: that drops at every reset, jumps
// when an account gets its first reading or is shown again, and moves when the set of weights changes,
// and every one of those would be fake food or fake fasting.

/// The two windows that feed the pet or put it to rest. The model weekly window (Fable, Opus) is
/// neither: other models still work when it is used up.
public enum PetWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour, sevenDay
}

/// One (account, window) period as the pet last saw it. Kept in `pet.json`, so what was used while Brow
/// was not running is still food when it comes back.
public struct PetPeriod: Codable, Sendable, Equatable {
    /// The period's reset instant, as `Formatting.resetInstant` rounds it.
    public var resetAt: Date
    /// The highest reading seen in the period. A lower one is jitter (a statusline 97 beside the
    /// endpoint's 98) and changes nothing: nothing is ever un-eaten.
    public var high: Double
    /// Ended, by a reading of a newer period or by the clock at `resetAt`. A late reading of a closed
    /// period is ignored, and the clock going back cannot open it again.
    public var closed: Bool

    public init(resetAt: Date, high: Double, closed: Bool = false) {
        self.resetAt = resetAt
        self.high = high
        self.closed = closed
    }

    private enum CodingKeys: String, CodingKey { case resetAt, high, closed }

    /// Only the reset instant is required: without it the period cannot be matched to a reading and
    /// is dropped. A missing mark is a baseline of 0, a missing flag an open period.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetAt = try c.decode(Date.self, forKey: .resetAt)
        high = (try? c.decodeIfPresent(Double.self, forKey: .high)) ?? 0
        closed = (try? c.decodeIfPresent(Bool.self, forKey: .closed)) ?? false
    }
}

/// One account's two periods.
public struct PetPeriods: Codable, Sendable, Equatable {
    public var fiveHour: PetPeriod?
    public var sevenDay: PetPeriod?

    public init(fiveHour: PetPeriod? = nil, sevenDay: PetPeriod? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    private enum CodingKeys: String, CodingKey { case fiveHour, sevenDay }

    /// Each window on its own: an unreadable weekly tracker costs the good week, not the 5-hour one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = (try? c.decodeIfPresent(PetPeriod.self, forKey: .fiveHour)) ?? nil
        sevenDay = (try? c.decodeIfPresent(PetPeriod.self, forKey: .sevenDay)) ?? nil
    }

    public subscript(window: PetWindowKind) -> PetPeriod? {
        get { window == .fiveHour ? fiveHour : sevenDay }
        set { if window == .fiveHour { fiveHour = newValue } else { sevenDay = newValue } }
    }
}

/// A period that ended: the weekly close is where a good week is judged, the 5-hour close where a fresh
/// window is.
public struct PetPeriodClose: Sendable, Equatable {
    public var account: String
    public var window: PetWindowKind
    /// The period's own reset instant: closes are handled in its order and dated by it, even when
    /// several are found at once after the Mac slept through them.
    public var resetAt: Date
    public var high: Double
}

extension PetReading {
    public subscript(window: PetWindowKind) -> PetWindow? {
        window == .fiveHour ? fiveHour : sevenDay
    }
}

extension PetAccount {
    /// The pet's view of one `LimitsStore` row: the organisation, its tier's weight in the aggregate
    /// (`RateLimitModel`, the same table the readouts use) and the 5-hour and weekly windows of its
    /// snapshot, with the reset instants rounded as the panel rounds them. The model weekly window is
    /// left out: other models still work when it is used up.
    public init(row: AccountRow) {
        self.init(id: row.id, weight: RateLimitModel.weight(forTier: row.account.tier).value,
                  reading: row.snapshot.map(PetReading.init(snapshot:)))
    }
}

extension PetReading {
    public init(snapshot: LimitSnapshot) {
        func window(_ captured: CapturedWindow?) -> PetWindow? {
            captured.map { PetWindow(used: $0.usedPercentage, resetAt: Formatting.resetInstant($0.resetsAt)) }
        }
        self.init(fetchedAt: snapshot.fetchedAt, fiveHour: window(snapshot.fiveHour),
                  sevenDay: window(snapshot.sevenDay))
    }
}

/// The trackers, and the food a reading brings. Pure: readings in, points and closed periods out.
public struct PetFood: Sendable, Equatable {
    /// By organisation. A hidden account's trackers are deleted, so when it is shown again its first
    /// reading is a baseline and the time it was hidden is not food.
    public var trackers: [String: PetPeriods]

    public init(trackers: [String: PetPeriods] = [:]) {
        self.trackers = trackers
    }

    /// What one set of readings brought.
    public struct Intake: Sendable, Equatable {
        /// Food points: one point is one point of the left readout.
        public var points: Double
        /// Periods a reading of a newer period ended, in the accounts' order.
        public var closes: [PetPeriodClose]
    }

    /// Each visible account's share of the aggregate, `w / W`, where `W` sums the weights of the
    /// visible accounts that have a reading: the same set `LimitsAggregate.compute` averages over.
    public static func shares(_ accounts: [PetAccount]) -> [String: Double] {
        let total = accounts.filter { $0.reading != nil }.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [:] }
        var shares: [String: Double] = [:]
        for account in accounts where account.reading != nil { shares[account.id] = account.weight / total }
        return shares
    }

    /// Takes in the visible accounts' readings. Only the 5-hour window feeds: one prompt moves both
    /// numbers, and counting both would count it twice. The weekly trackers are kept for the good
    /// week.
    public mutating func take(_ accounts: [PetAccount]) -> Intake {
        let visible = Set(accounts.map(\.id))
        trackers = trackers.filter { visible.contains($0.key) }
        let shares = Self.shares(accounts)
        var points = 0.0
        var closes: [PetPeriodClose] = []
        for account in accounts {
            guard let reading = account.reading, let share = shares[account.id] else { continue }
            var periods = trackers[account.id] ?? PetPeriods()
            for kind in PetWindowKind.allCases {
                // Not started, or a window that carries no date: it counts toward the aggregate,
                // never as food.
                guard let window = reading[kind], let reset = window.resetAt else { continue }
                // A reading of a window that had already closed when it was fetched.
                guard reset > reading.fetchedAt.addingTimeInterval(-PetTuning.Food.closedReadingSlack) else { continue }
                let used = window.used
                guard let period = periods[kind] else {
                    // The first reading ever: a silent baseline. What was used before the pet
                    // looked is not food.
                    periods[kind] = PetPeriod(resetAt: reset, high: used)
                    continue
                }
                if abs(reset.timeIntervalSince(period.resetAt)) <= PetTuning.Food.samePeriod {
                    // The same period (this absorbs the endpoint's `…:59.64` beside `:00`).
                    guard !period.closed, used > period.high else { continue }
                    if kind == .fiveHour { points += (used - period.high) * share }
                    periods[kind]?.high = used
                } else if reset > period.resetAt {
                    // A newer period: everything used since its reset is new.
                    if !period.closed {
                        closes.append(PetPeriodClose(account: account.id, window: kind,
                                                     resetAt: period.resetAt, high: period.high))
                    }
                    if kind == .fiveHour { points += used * share }
                    periods[kind] = PetPeriod(resetAt: reset, high: used)
                }
                // An older period than the one already seen says nothing new, and is not a reason
                // to close the newer one.
            }
            trackers[account.id] = periods
        }
        return Intake(points: points, closes: closes)
    }

    /// Closes, by the clock, every open period whose reset instant has come without a reading of a
    /// newer one, oldest first: after a night asleep they are judged in the order they ended.
    public mutating func closeElapsed(now: Date) -> [PetPeriodClose] {
        var closes: [PetPeriodClose] = []
        // Sorted, because a dictionary's order changes from run to run and the brain must not.
        for id in trackers.keys.sorted() {
            for kind in PetWindowKind.allCases {
                guard let period = trackers[id]?[kind], !period.closed, period.resetAt <= now else { continue }
                trackers[id]?[kind]?.closed = true
                closes.append(PetPeriodClose(account: id, window: kind, resetAt: period.resetAt, high: period.high))
            }
        }
        return closes.sorted {
            ($0.resetAt, $0.window == .fiveHour ? 0 : 1, $0.account) < ($1.resetAt, $1.window == .fiveHour ? 0 : 1, $1.account)
        }
    }

    /// The next reset instant at which an open period will close by the clock.
    public func nextClose(after now: Date) -> Date? {
        trackers.values.flatMap { [$0.fiveHour, $0.sevenDay] }
            .compactMap { $0.flatMap { !$0.closed && $0.resetAt > now ? $0.resetAt : nil } }
            .min()
    }

    /// Whether the period that resets at `resetAt` has already been closed, by a newer reading or by
    /// the clock. A closed period stays closed when the clock goes back.
    public func isClosed(account: String, window: PetWindowKind, resetAt: Date) -> Bool {
        guard let period = trackers[account]?[window] else { return false }
        if abs(resetAt.timeIntervalSince(period.resetAt)) <= PetTuning.Food.samePeriod { return period.closed }
        // A reading of an older period than the tracker's: that one is over.
        return resetAt < period.resetAt
    }
}
