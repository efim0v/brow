// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
@testable import BrowKit

/// `PetController` in miniature, for the brain's tests: it sends each scripted event at its time and,
/// in between, what the app would send on its own: the ticks the brain asks for, a presence check
/// every 5 s, and the accounts' readings again every minute as Brow's polls refresh them. Time is
/// seconds after `t0` on both clocks, which only part where a test moves one of them on its own.
struct PetHarness {
    /// One visible account as the store would show it.
    struct Account {
        var id: String
        var weight: Double = 1
        var hasReading = true
        var five: Double? = 0
        /// Seconds after `t0`; nil: undated.
        var fiveReset: TimeInterval? = 4 * 3600
        var week: Double? = 10
        var weekReset: TimeInterval? = 5 * 86_400
        /// nil: fetched at each refresh, so always fresh; a number pins the fetch time.
        var fetchedAt: TimeInterval?
    }

    var brain: PetBrain
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// Added to the wall clock only: a clock jump, or a Mac that slept.
    var wallShift: TimeInterval = 0
    private(set) var now: TimeInterval = 0
    var accounts: [Account] = [Account(id: "a")]
    /// Input stopped at this instant; nil while the person keeps using the Mac.
    var idleSince: TimeInterval?
    var screenLocked = false
    var presenceEvery: TimeInterval? = PetTuning.Presence.checkEvery
    var refreshEvery: TimeInterval? = 60
    private var lastPresence: TimeInterval = 0
    private var lastRefresh: TimeInterval = 0
    /// Every segment ever planned, by start, so a test can look past the brain's 20 minutes.
    private(set) var log: [PetSegment] = []

    init(seed: UInt64 = 1, introDone: Bool = true, hunger: Double = PetTuning.Hunger.newPet) {
        brain = PetBrain(seed: seed)
        brain.introDone = introDone
        brain.hunger = PetHunger(value: hunger)
        brain.mood = PetHunger.moodOnTheWayUp(hunger)
    }

    func time(_ seconds: TimeInterval) -> PetTime {
        PetTime(wall: t0.addingTimeInterval(seconds + wallShift), mono: seconds)
    }

    func petAccounts(at seconds: TimeInterval) -> [PetAccount] {
        accounts.map { account in
            PetAccount(id: account.id, weight: account.weight, reading: account.hasReading ? PetReading(
                fetchedAt: t0.addingTimeInterval((account.fetchedAt ?? seconds) + wallShift),
                fiveHour: account.five.map { PetWindow(used: $0, resetAt: account.fiveReset.map { t0.addingTimeInterval($0) }) },
                sevenDay: account.week.map { PetWindow(used: $0, resetAt: account.weekReset.map { t0.addingTimeInterval($0) }) })
                : nil)
        }
    }

    func presence(at seconds: TimeInterval) -> PetPresence {
        PetPresence(displayAsleep: false, screenLocked: screenLocked, sessionInactive: false,
                    inputIdle: idleSince.map { max(0, seconds - $0) } ?? 0)
    }

    /// What the controller sends once at start.
    mutating func start(visible: Bool = true, at seconds: TimeInterval = 0) {
        now = seconds
        for event in [PetEvent.showPet(true), .motion(PetMotion()), .timeZone(TimeZone(identifier: "UTC")!),
                      .presence(presence(at: seconds)), .visible(visible), .readings(petAccounts(at: seconds))] {
            deliver(event, at: seconds)
        }
        lastPresence = seconds
        lastRefresh = seconds
    }

    /// Plays everything due up to `seconds`, then `event` at `seconds`.
    mutating func send(_ event: PetEvent, at seconds: TimeInterval) {
        run(to: seconds)
        deliver(event, at: seconds)
    }

    /// The accounts' current readings, now.
    mutating func refresh(at seconds: TimeInterval) {
        run(to: seconds)
        deliver(.readings(petAccounts(at: seconds)), at: seconds)
        lastRefresh = seconds
    }

    /// What the app would do on its own until `seconds`.
    mutating func run(to seconds: TimeInterval) {
        for _ in 0..<1_000_000 {
            var next: (at: TimeInterval, event: PetEvent)?
            // Each source is judged by its own last delivery, so two of them due at the same instant
            // are both delivered: the app's presence check and the brain's tick do coincide.
            func consider(_ at: TimeInterval?, after last: TimeInterval, _ event: @autoclosure () -> PetEvent) {
                guard let at, at <= seconds, at > last, at >= now else { return }
                if next.map({ at < $0.at }) ?? true { next = (at, event()) }
            }
            if let every = presenceEvery {
                consider(lastPresence + every, after: lastPresence, .presence(presence(at: lastPresence + every)))
            }
            if let every = refreshEvery {
                consider(lastRefresh + every, after: lastRefresh, .readings(petAccounts(at: lastRefresh + every)))
            }
            consider(brain.nextDeadline(after: time(now))?.mono, after: now, .tick)
            guard let due = next else { break }
            if case .presence = due.event { lastPresence = due.at }
            if case .readings = due.event { lastRefresh = due.at }
            deliver(due.event, at: due.at)
        }
        now = max(now, seconds)
    }

    mutating func deliver(_ event: PetEvent, at seconds: TimeInterval) {
        _ = brain.handle(event, at: time(seconds))
        now = max(now, seconds)
        // What the brain still holds, after what it has forgotten.
        let segments = brain.timeline.segments
        log = log.filter { $0.start < (segments.first?.start ?? .infinity) } + segments
    }

    /// The segments that really started in `range`, with their starts relative to `t0`.
    func played(_ range: ClosedRange<TimeInterval>) -> [PetSegment] {
        log.filter { range.contains($0.start) && $0.start <= now }
    }

    /// What was playing at `seconds`.
    func behaviour(at seconds: TimeInterval) -> PetBehaviour? {
        log.last { $0.start <= seconds }?.behaviour
    }

    /// The meter at `seconds`, from the timeline's keys, as the rig reads it.
    func meter(at seconds: TimeInterval) -> Double {
        let keys = brain.timeline.meter
        guard let first = keys.first else { return PetTuning.Hunger.newPet }
        guard let key = keys.last(where: { $0.t <= seconds }) else { return first.value }
        return key.value + key.rate * (seconds - key.t)
    }
}
