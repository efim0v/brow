// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The numbers that put the pet to rest and pace its hunger. Pure: the visible accounts and `now` in,
/// numbers out.
public enum PetLimits {

    /// One account's effective used % of a window: a window whose reset instant has passed counts as
    /// reset, whatever the last reading said, so a three-day-old 100 % does not keep the pet asleep. Two
    /// refinements of that rule, for a clock that jumps:
    ///
    /// - `closed`: a period the pet has already seen end stays reset when the clock goes back, so a
    ///   backward jump never puts it to sleep without a fresh reading.
    /// - A reading fetched more than a minute after its own reset instant that still reports that
    ///   window means the server still has it open and the Mac's clock is ahead (a forward jump past
    ///   the reset): its number counts, so the fresh reading that still says 100 % puts the pet back
    ///   to sleep. Within the minute it is the endpoint lagging at the boundary, and the window has
    ///   reset.
    static func effective(_ window: PetWindow?, fetchedAt: Date, now: Date, closed: Bool) -> Double {
        guard let window else { return 0 }                  // not started: 0 % used
        guard let reset = window.resetAt else { return window.used }
        if fetchedAt.timeIntervalSince(reset) > PetTuning.Food.closedReadingSlack { return window.used }
        return reset <= now || closed ? 0 : window.used
    }

    /// `E(window, now)`: the tier-weighted average of the effective used % over the visible accounts
    /// that have a reading, the set the readouts average over; nil when there is none.
    public static func aggregate(_ accounts: [PetAccount], _ window: PetWindowKind, now: Date,
                                 food: PetFood? = nil) -> Double? {
        aggregate(accounts, window, now: now, food: food, zeroed: [])
    }

    private static func aggregate(_ accounts: [PetAccount], _ window: PetWindowKind, now: Date, food: PetFood?,
                                  zeroed: Set<String>) -> Double? {
        var used = 0.0
        var weights = 0.0
        for account in accounts {
            guard let reading = account.reading else { continue }
            weights += account.weight
            guard !zeroed.contains(account.id) else { continue }
            let closed = reading[window]?.resetAt.map {
                food?.isClosed(account: account.id, window: window, resetAt: $0) ?? false
            } ?? false
            used += account.weight * effective(reading[window], fetchedAt: reading.fetchedAt, now: now, closed: closed)
        }
        return weights > 0 ? used / weights : nil
    }

    /// The earliest future reset at which `E(window)` drops below the stay line, found by resetting the
    /// accounts one by one in the order their windows reset; nil when no known reset gets it there (it
    /// "wakes when the limit resets").
    public static func wakeInstant(_ accounts: [PetAccount], _ window: PetWindowKind, now: Date,
                                   food: PetFood? = nil) -> Date? {
        guard let current = aggregate(accounts, window, now: now, food: food), current >= PetTuning.Limits.stay
        else { return nil }
        let resets = accounts.compactMap { account -> (id: String, at: Date)? in
            guard let reset = account.reading?[window]?.resetAt, reset > now else { return nil }
            return (account.id, reset)
        }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        var zeroed: Set<String> = []
        for reset in resets {
            zeroed.insert(reset.id)
            if let left = aggregate(accounts, window, now: now, food: food, zeroed: zeroed),
               left < PetTuning.Limits.stay {
                return reset.at
            }
        }
        return nil
    }

    /// `e7`, an even week's pace in percent: each account's share of the week gone since its weekly
    /// window started, weighted like the aggregate; 0 for an account whose weekly window has not started.
    public static func evenPace(_ accounts: [PetAccount], now: Date) -> Double {
        var elapsed = 0.0
        var weights = 0.0
        for account in accounts {
            guard let reading = account.reading else { continue }
            weights += account.weight
            guard let reset = reading.sevenDay?.resetAt else { continue }
            let start = reset.addingTimeInterval(-PetTuning.Hunger.week)
            elapsed += account.weight * min(max(now.timeIntervalSince(start) / PetTuning.Hunger.week, 0), 1)
        }
        return weights > 0 ? elapsed / weights * 100 : 0
    }

    /// Pace damping `f`: 1 on or behind an even pace, falling to 0 thirty points ahead of it, so the pet
    /// never asks for food the week cannot afford and never pushes into the weekly wall. Never above 1: a
    /// light week does not make it hungrier than the base rate.
    public static func pace(_ accounts: [PetAccount], now: Date, food: PetFood? = nil) -> Double {
        let used = aggregate(accounts, .sevenDay, now: now, food: food) ?? 0
        let ahead = used - evenPace(accounts, now: now)
        return min(max(1 - ahead / PetTuning.Hunger.paceStop, 0), 1)
    }
}

/// One window's rest: asleep at the 5-hour limit, hibernating at the weekly one, by the same rules.
/// Pure and mutating; the brain feeds it the effective aggregate at each update.
public struct PetRest: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case awake
        /// At rest since `since` (`PetTime.mono`).
        case resting(since: TimeInterval)
        /// The reset at `reset` passed while someone could see the pet: drowsy (in the den, stirring)
        /// since `since`, waiting up to `PetTuning.Limits.confirmationWait` for fresh numbers.
        case waiting(since: TimeInterval, reset: Date)
    }

    /// What an update changed.
    public enum Change: Sendable, Equatable {
        /// Full: asleep, or into the den.
        case rest
        /// The reset passed: drowsy.
        case wait
        /// Up again; `reset` says whether a reset did it, or something else (an account added or
        /// shown with room), which needs the minimum stay.
        case wake(reset: Bool)
        /// A fresh reading in the drowsy wait still says full: back to rest.
        case rollOver
    }

    public private(set) var phase: Phase = .awake
    /// When it last woke (`PetTime.mono`); the 5-hour rest does not start again sooner than
    /// `afterWake` after it.
    public private(set) var lastWake: TimeInterval?
    /// While at rest: when a reset will take the aggregate below the stay line, if one will.
    public private(set) var wakesAt: Date?
    /// 30 s for the 5-hour window, none for the weekly one.
    public let afterWake: TimeInterval

    public init(afterWake: TimeInterval) {
        self.afterWake = afterWake
    }

    public var isResting: Bool {
        if case .awake = phase { return false }
        return true
    }

    public var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    /// Re-evaluates the rest at `t`.
    /// - Parameters:
    ///   - effective: the window's effective aggregate now; nil without a single reading.
    ///   - wakeInstant: `PetLimits.wakeInstant` now.
    ///   - newestFetch: the newest `fetchedAt` among the visible readings: a reading fetched at or after
    ///     the reset confirms it.
    ///   - seen: whether anyone can see the pet. Nobody watching, a reset wakes it at once, with no
    ///     drowsy wait: the stretch plays when it is next seen.
    public mutating func update(effective: Double?, wakeInstant: Date?, newestFetch: Date?, seen: Bool,
                                at t: PetTime) -> Change? {
        typealias L = PetTuning.Limits
        let used = effective ?? 0
        switch phase {
        case .awake:
            guard used >= L.enter else { return nil }
            if let lastWake, t.mono - lastWake < afterWake { return nil }
            phase = .resting(since: t.mono)
            wakesAt = wakeInstant
            return .rest
        case .resting(let since):
            if used >= L.stay {
                wakesAt = wakeInstant
                return nil
            }
            // Below the stay line: either the reset it was waiting for came, which wakes it however
            // soon, or something else did it, which must wait out the minimum stay.
            if let reset = wakesAt, t.wall >= reset {
                if seen {
                    phase = .waiting(since: t.mono, reset: reset)
                    return .wait
                }
                wake(at: t)
                return .wake(reset: true)
            }
            guard t.mono - since >= L.minimumStay else { return nil }
            wake(at: t)
            return .wake(reset: false)
        case .waiting(let since, let reset):
            let confirmed = newestFetch.map { $0 >= reset } ?? false
            guard confirmed || !seen || t.mono - since >= L.confirmationWait else { return nil }
            if used >= L.enter {
                phase = .resting(since: t.mono)
                wakesAt = wakeInstant
                return .rollOver
            }
            wake(at: t)
            return .wake(reset: true)
        }
    }

    /// The next instant at which `update` could change something with the readings it has, so the
    /// brain asks for a tick then: the end of the wait after a wake, the minimum stay of an exit
    /// that is not a reset, the drowsy limit. Wake instants are wall-clock and the brain adds them.
    public func deadline(effective: Double?) -> TimeInterval? {
        typealias L = PetTuning.Limits
        let used = effective ?? 0
        switch phase {
        case .awake:
            guard used >= L.enter, let lastWake else { return nil }
            return lastWake + afterWake
        case .resting(let since):
            return used < L.stay ? since + L.minimumStay : nil
        case .waiting(let since, _):
            return since + L.confirmationWait
        }
    }

    /// Back to the start: no account is visible any more, or the pet was turned off. The next
    /// update judges the numbers afresh.
    public mutating func forget() {
        phase = .awake
        wakesAt = nil
    }

    private mutating func wake(at t: PetTime) {
        phase = .awake
        lastWake = t.mono
        wakesAt = nil
    }
}
