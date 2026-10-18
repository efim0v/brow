// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

extension PetTuning {
    /// The brain's own bookkeeping: numbers its rules imply without stating, each with the reason it is
    /// what it is.
    public enum Brain {
        /// A fresh window that could not play at once (the pet busy, or not seen) waits this long,
        /// then is let go: a hop at the readout minutes after it changed would be about nothing.
        public static let freshWindowWait: TimeInterval = 30
        /// After a return from away, a welcome back stays due this long while the morning's other
        /// beats play: about 10 s at most in all.
        public static let returnWait: TimeInterval = PetTuning.Clock.morningAtMost
        /// A deadline worked out by arithmetic (a mood threshold, a full meter) lands at least one
        /// rig step after the instant it was worked out at, so an instant floating point puts a hair
        /// early never asks for the same tick twice.
        public static let step: TimeInterval = PetTuning.Secondary.step
        /// Pace damping is held to this grid, so the meter gets a new key when the week's pace has
        /// moved, not at every presence check.
        public static let paceGrid: Double = 0.01
        /// A guard on planning: real chains of actions are two to four long.
        static let chainLimit = 24
    }
}

extension PetNoise.Channel {
    /// The gaps between peeks out of the den.
    static let denPeek = PetNoise.Channel(0x100)
}

/// The pet's mind: conditions from the data, behaviours from the conditions and the events, and the
/// timeline the rig plays. Pure and mutating, like `LimitWarnings`: the same events at the same times
/// always give the same timeline. Nothing inside reads a clock or a random number; the time comes with
/// each event, and every choice comes from `PetNoise` and `seed`.
///
/// How it works. The brain has deadlines of its own (a meal's swallow, the end of `eager`, a reset
/// instant, the next peek), and `advance(to:)` plays them in time order before each event, so a tick
/// that comes late, or not at all, changes nothing but when the work is done. After each event it
/// plans ahead: a copy of itself plays on to the end of the action in progress and of everything
/// that follows it, and what the copy commits is the timeline's future. The plan is thrown away and
/// made again at the next event, so it is never more than a forecast; what the brain commits when
/// the time really comes is the same, unless an event changed it.
public struct PetBrain: Sendable {
    /// What the rig plays: the segment on now, what is planned after it, and `PetTimeline.memory` of
    /// the past.
    public private(set) var timeline = PetTimeline()
    /// The pet's own seed from `pet.json`: it shapes the pet's quirks and never changes.
    public let seed: UInt64

    // MARK: What it has been told

    var showPet = true
    var motion = PetMotion()
    /// Fed days are dated in this zone; the controller sends the system's at start and on each change.
    var timeZone = TimeZone(identifier: "UTC")!
    var presence = PetPresence()
    /// `PetTime.mono` of the last input, from the last presence check.
    var lastInput: TimeInterval?
    var visibleFlag = false
    var systemAsleep = false
    /// nil until the first `readings`: the brain does not know yet whether there are accounts.
    var accounts: [PetAccount]?
    var forced: PetForcedState?

    // MARK: The clocks

    /// The `PetTime.mono` the state has been brought to.
    var clock: TimeInterval?
    /// `wall − mono` in seconds at the latest event, for turning wall-clock deadlines into ticks.
    var offset: TimeInterval = 0

    // MARK: Hunger and food

    var hunger = PetHunger()
    /// H between its jumps: a straight line from the last time food, a debug value or a change of
    /// rate moved it. Read from the line, not added up step by step, H at an instant is the same
    /// bits however many updates came in between, and so is every meter key.
    var hungerLine: HungerLine?
    /// Whether the hunger clock runs, and at which pace: set at each update, held until the next.
    var running = false
    var pace: Double = 1
    var food = PetFood()
    var plate = Plate()
    /// Meals started whose drop has not reached the meter yet.
    var swallows: [Swallow] = []
    var mood: PetMood = .content
    var lastMealMono: TimeInterval?
    var lastMealWall: Date?
    var lastMealPoints: Double?
    /// Meals eaten since launch, for the save schedule.
    public internal(set) var meals = 0

    // MARK: Rest

    var nap = PetRest(afterWake: PetTuning.Limits.sleepAfterWake)
    var den = PetRest(afterWake: 0)
    /// What the data says, re-evaluated at every update.
    public private(set) var condition: PetCondition = .unsure
    /// Bumped at every change of `condition`, for the save schedule.
    public private(set) var conditionChanges = 0
    /// Unsure keeps the mood it had when the numbers went stale.
    var unsureMood: PetMood = .content

    // MARK: Moments

    var moments = PetMoments()
    var introDone = false
    var bornAt: Date?
    var pendingCelebrations: [PendingCelebration] = []
    /// `PetTime.mono` at which a fresh window became due.
    var pendingFreshWindow: TimeInterval?
    var lastFreshWindow: TimeInterval?
    /// `PetTime.mono` at which someone came back after 600 s or more away.
    var returnPending: TimeInterval?

    // MARK: Claude Code

    /// The first perk of the eager stretch in progress, and when it ends.
    var eagerSince: TimeInterval?
    var eagerUntil: TimeInterval?
    var lastPrompt: TimeInterval?
    var lastPerk: TimeInterval?
    /// Eager ran its 600 s; no perk until a minute passes with no prompt.
    var capped = false
    /// A prompt waiting for an action or `satisfied` to end, by its time.
    var queuedPrompt: TimeInterval?

    // MARK: Away, the pointer, boops, the den

    var away = false
    /// When the last input before going away was.
    var awaySince: Date?
    var noticed = false
    /// The last twitch in its sleep, of either kind, and the last one a prompt caused: a prompt twitches
    /// it at most once a minute, the pointer at most once per 20 s, and never two within 20 s.
    var lastTwitch: TimeInterval?
    var lastPromptTwitch: TimeInterval?
    /// Boops of the last six seconds, for the giggle.
    var boops: [TimeInterval] = []
    var lastBoop: TimeInterval?
    var quietUntil: TimeInterval?
    /// A boop waiting for a short action to end; true when it is the giggle.
    var queuedBoop: Bool?
    /// Peeks so far, the index of the next peek's gap.
    var peeks = 0

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// Takes in one event. Returns the segments it planned, in start order (a plan it replaced is
    /// replaced by these), or nothing when the plan stayed as it was; `timeline` holds the result.
    public mutating func handle(_ event: PetEvent, at time: PetTime) -> [PetSegment] {
        let before = timeline.segments
        // Time never runs backwards inside the brain, whatever a script or a clock does.
        let now = clock.map { PetTime(wall: time.wall, mono: max(time.mono, $0)) } ?? time
        // The pointer moves up to 120 times a second. With nothing of the brain's own due before it,
        // all it can do is add a cue at its instant: the plan and every deadline stay as they are.
        if case .pointer(let distance) = event, clock != nil, nextWakeup().map({ $0 > now.mono }) ?? true {
            pointer(at: distance, time: now)
            // Nothing was due, so nothing planned lies between the last update and now: the clock can
            // move up without playing anything, and the cue counts as committed. H is read from its
            // line, so it needs no step either.
            clock = now.mono
            offset = now.wall.timeIntervalSince1970 - now.mono
            return []
        }
        if let clock { timeline.dropPlans(after: clock) }
        advance(to: now)
        // The event lands on the state as it is at its own instant: food is taken off H as it stands
        // then, not as it stood at the last update.
        integrate(to: now)
        clock = max(clock ?? now.mono, now.mono)
        apply(event, at: now)
        step(at: now)
        plan(from: now)
        prune(at: now)
        let old = Set(before)
        guard let first = timeline.segments.firstIndex(where: { !old.contains($0) }) else { return [] }
        return Array(timeline.segments[first...])
    }

    /// When the brain next needs a `.tick` if nothing else happens: a meal flush, the end of `eager`,
    /// the drowsy limit, a wake instant, a minimum stay, the next peek. nil: no such moment.
    public func nextDeadline(after time: PetTime) -> PetTime? {
        guard showPet, clock != nil else { return nil }
        guard let due = brought(to: time).nextWakeup() else { return nil }
        return time.adding(due - time.mono)
    }

    /// A copy of the brain as it will be at `time` if no event comes first: the plan is let go and
    /// what really happens up to `time` is played, so the copy's segment, hunger and state are those
    /// of that instant. For questions about it (`nextDeadline`, `status`, `save`).
    func brought(to time: PetTime) -> PetBrain {
        var copy = self
        if let clock { copy.timeline.dropPlans(after: clock) }
        copy.advance(to: time)
        copy.integrate(to: time)
        copy.clock = max(copy.clock ?? time.mono, time.mono)
        return copy
    }
}

// MARK: - The parts of the state

extension PetBrain {
    /// Food the pet has not been seen eating yet: the hunger model already has it.
    struct Plate: Sendable, Equatable {
        var points: Double = 0
        /// The part of H's drop that belongs to this food: the meter shows it until the swallow.
        var drop: Double = 0
        /// `PetTime.mono` of the last food, for the flush.
        var lastFood: TimeInterval = 0
    }

    /// H rising at `rate` from `value` at `t`, up to 100, and standing still from `stoppingAt` on:
    /// 600 s after the last input, the hunger clock stops.
    struct HungerLine: Sendable, Equatable {
        var t: TimeInterval
        var value: Double
        var rate: Double

        func value(at time: TimeInterval, stoppingAt stop: TimeInterval?) -> Double {
            let end = max(t, min(time, stop ?? time))
            return min(PetTuning.Hunger.maximum, value + rate * (end - t))
        }
    }

    /// A meal's drop on its way to the meter, landing at the swallow.
    struct Swallow: Sendable, Equatable {
        var at: TimeInterval
        var drop: Double
    }

    struct PendingCelebration: Sendable, Equatable {
        var celebration: PetBehaviour.Celebration
        /// A milestone is skipped when its day ends unseen; a good week after its line's 24 hours.
        var until: Date
    }

    /// Where a behaviour leaves the pet, which decides what a change of condition plays.
    enum Place: Sendable, Equatable {
        /// Out in its zone, awake.
        case open
        /// Asleep in the open at the 5-hour limit.
        case nap
        /// Hibernating in the den at the weekly limit.
        case den
        /// In the den with no account to eat from, or before its intro.
        case burrow
        case doze
        case off
    }

    var pendingDrop: Double { plate.drop + swallows.reduce(0) { $0 + $1.drop } }

    /// H + pendingDrop: what the meter shows before the clamp, and what moods are judged on.
    var meterValue: Double { hunger.value + pendingDrop }

    var isVisible: Bool { showPet && visibleFlag && !systemAsleep }

    /// Someone can see the pet and is there to see it: meals, moments and transitions wait for this.
    var audience: Bool { isVisible && !away }

    var isAwake: Bool {
        if case .awake = condition { return true }
        return false
    }

    var current: PetSegment? { timeline.segments.last }

    var currentPlace: Place { current.map { place(after: $0.behaviour) } ?? .open }

    func place(after behaviour: PetBehaviour) -> Place {
        switch behaviour {
        case .fallAsleep, .asleep, .drowsy, .rollOver: return .nap
        case .enterDen(let retreat): return retreat ? .burrow : .den
        case .hibernating, .stirring: return .den
        case .denWait, .peek, .intro(noAccounts: true): return .burrow
        case .dozeIn, .doze: return .doze
        case .off: return .off
        default: return .open
        }
    }

    /// The place the condition calls for.
    var targetPlace: Place {
        switch condition {
        case .off: return .off
        case .noAccounts: return .burrow
        case .hibernating: return .den
        case .asleep: return .nap
        case .unsure, .awake: return !introDone ? .burrow : away ? .doze : .open
        }
    }

    /// The open-ended behaviour the state calls for when nothing else is going on.
    func restingBehaviour(at t: PetTime) -> PetBehaviour {
        switch condition {
        case .off: return .off
        case .noAccounts: return .denWait
        case .hibernating: return den.isWaiting ? .stirring : .hibernating
        case .asleep: return nap.isWaiting ? .drowsy : .asleep
        case .unsure: return !introDone ? .denWait : away ? .doze : .unsureIdle(unsureMood)
        case .awake(let mood):
            if !introDone { return .denWait }
            if away { return .doze }
            if eagerUntil != nil { return .eager }
            if let lastInput, t.mono - lastInput >= PetTuning.Presence.settled { return .settled(mood) }
            return .idle(mood)
        }
    }

    /// The hunger clock: the pet on, someone at the Mac, awake with fresh numbers.
    func hungerClockRuns(at t: PetTime) -> Bool {
        guard showPet, isAwake, !away, !systemAsleep, !presence.displayAsleep, !presence.screenLocked,
              !presence.sessionInactive else { return false }
        return lastInput.map { t.mono - $0 < PetTuning.Presence.away } ?? true
    }

    func peekGap(_ index: Int) -> TimeInterval {
        PetTuning.Den.peekMinimum
            + (PetTuning.Den.peekMaximum - PetTuning.Den.peekMinimum) * PetNoise.hash(seed, .denPeek, index)
    }

    func sinceLastMeal(at t: PetTime) -> TimeInterval? {
        if let lastMealMono { return t.mono - lastMealMono }
        return lastMealWall.map { max(0, t.wall.timeIntervalSince($0)) }
    }

    func mono(_ wall: Date) -> TimeInterval { wall.timeIntervalSince1970 - offset }
}

// MARK: - Time

extension PetBrain {
    /// Plays the brain's own deadlines up to `now`, each at its own instant.
    mutating func advance(to now: PetTime) {
        offset = now.wall.timeIntervalSince1970 - now.mono
        guard clock != nil else {
            clock = now.mono
            return
        }
        while let due = nextWakeup(), due <= now.mono {
            step(at: PetTime(wall: now.wall.addingTimeInterval(due - now.mono), mono: due))
        }
    }

    /// One update at `t`: the clocks, the rules, then whatever the state says should start.
    mutating func step(at t: PetTime) {
        integrate(to: t)
        clock = max(clock ?? t.mono, t.mono)
        updateRules(at: t)
        for _ in 0..<8 {
            guard let next = decide(at: t) else { break }
            commit(next, at: t)
        }
        refreshMeter(at: t)
    }

    /// Hunger since `clock` at the rate held since then, stopping where the person went away by
    /// input (the clock stops 600 s after the last input), and the swallows that came due.
    mutating func integrate(to t: PetTime) {
        swallows.removeAll { $0.at <= t.mono }
        guard let clock, t.mono > clock, let line = hungerLine else { return }
        hunger = PetHunger(value: line.value(at: t.mono, stoppingAt: lastInput.map { $0 + PetTuning.Presence.away }))
    }

    /// The earliest instant after `clock` at which a rule could change something.
    func nextWakeup() -> TimeInterval? {
        guard showPet, let clock else { return nil }
        typealias P = PetTuning.Plate
        var times: [TimeInterval] = []
        // Between events the timeline also holds the plan: the segment playing is the last one that
        // has started, and the next planned start is a deadline of its own, so that what starts then
        // is committed then, with what starting it means.
        if let next = timeline.segments.first(where: { $0.start > clock }) { times.append(next.start) }
        if let playing = timeline.segments.last(where: { $0.start <= clock }) {
            if let duration = playing.behaviour.duration { times.append(playing.start + duration) }
            switch playing.behaviour {
            case .satisfied:
                times.append(playing.start + PetTuning.Meal.satisfiedMinimum)
            case .eager:
                times.append(playing.start + PetTuning.Eager.minimum)
            case .denWait where introDone && audience:
                times.append(playing.start + peekGap(peeks))
            default:
                break
            }
        }
        times += swallows.map(\.at)
        if plate.points > 0 {
            times.append(plate.lastFood + P.flushAfter)
            if let lastMealMono { times.append(lastMealMono + P.mealGap) }
        }
        if let eagerUntil { times.append(eagerUntil) }
        if let queuedPrompt { times.append(queuedPrompt + PetTuning.Eager.afterPrompt) }
        let wall = Date(timeIntervalSince1970: clock + offset)
        if let close = food.nextClose(after: wall) { times.append(mono(close)) }
        if let accounts, !accounts.isEmpty {
            let e5 = PetLimits.aggregate(accounts, .fiveHour, now: wall, food: food)
            let e7 = PetLimits.aggregate(accounts, .sevenDay, now: wall, food: food)
            for (rest, used) in [(nap, e5), (den, e7)] {
                if let wake = rest.wakesAt { times.append(mono(wake)) }
                if let deadline = rest.deadline(effective: used) { times.append(deadline) }
            }
            if isAwake, let newest = accounts.compactMap({ $0.reading?.fetchedAt }).max() {
                times.append(mono(newest.addingTimeInterval(PetTuning.Stale.unsure)))
            }
        }
        if let lastInput {
            times.append(lastInput + PetTuning.Presence.settled)
            times.append(lastInput + PetTuning.Presence.away)
        }
        // Worked out from the line, not from `clock`, so they are the same instants whenever asked.
        if let line = hungerLine, line.rate > 0, hunger.value < PetTuning.Hunger.maximum {
            times.append(line.t + (PetTuning.Hunger.maximum - line.value) / line.rate)
            if let threshold = PetHunger.nextThreshold(above: meterValue, mood: mood) {
                times.append(max(clock + PetTuning.Brain.step, line.t + (threshold - pendingDrop - line.value) / line.rate))
            }
        }
        return times.filter { $0 > clock }.min()
    }
}

// MARK: - The rules

extension PetBrain {
    /// Everything that follows from the state and the time alone, in the order it depends on itself.
    mutating func updateRules(at t: PetTime) {
        guard showPet else {
            setCondition(.off)
            return
        }
        for close in food.closeElapsed(now: t.wall) { periodClosed(close, at: t) }

        let accounts = self.accounts ?? []
        if accounts.isEmpty {
            nap.forget()
            den.forget()
        } else {
            let newest = accounts.compactMap { $0.reading?.fetchedAt }.max()
            let e7 = PetLimits.aggregate(accounts, .sevenDay, now: t.wall, food: food)
            _ = den.update(effective: e7, wakeInstant: PetLimits.wakeInstant(accounts, .sevenDay, now: t.wall, food: food),
                           newestFetch: newest, seen: audience, at: t)
            // While it hibernates, the 5-hour wait is nobody's to watch: a reset just wakes that rest.
            let e5 = PetLimits.aggregate(accounts, .fiveHour, now: t.wall, food: food)
            _ = nap.update(effective: e5, wakeInstant: PetLimits.wakeInstant(accounts, .fiveHour, now: t.wall, food: food),
                           newestFetch: newest, seen: audience && !den.isResting, at: t)
        }

        mood = PetHunger.mood(meterValue, from: mood)
        setCondition(evaluateCondition(at: t))

        if let until = eagerUntil, t.mono >= until || !isAwake || away {
            if let since = eagerSince, t.mono >= since + PetTuning.Eager.maximum { capped = true }
            eagerSince = nil
            eagerUntil = nil
        }
        if let queued = queuedPrompt, t.mono - queued > PetTuning.Eager.afterPrompt || !isAwake { queuedPrompt = nil }
        // A boop waits only for the short beat it came during; at rest it has nobody to reach.
        if queuedBoop != nil, let current, current.behaviour.duration == nil, currentPlace != .open { queuedBoop = nil }

        // Crumbs: less than 0.1 point that no more food followed is dropped, unseen.
        if plate.points > 0, plate.points < PetTuning.Plate.flushMinimum,
           t.mono - plate.lastFood >= PetTuning.Plate.flushAfter {
            plate = Plate()
        }
        // Asleep, hibernating, in the den: the hunger model has the food already, and there is no
        // meal. The meal that fills the window is the exception, eaten before it falls asleep.
        switch condition {
        case .hibernating, .noAccounts: plate = Plate()
        case .asleep where currentPlace != .open: plate = Plate()
        default: break
        }

        // A new pet first seen asleep or hibernating has no intro: it is simply found that way.
        if !introDone, audience, self.accounts != nil {
            switch condition {
            case .asleep, .hibernating: introDone = true
            default: break
            }
        }

        pendingCelebrations.removeAll { $0.until <= t.wall }
        pendingCelebrations.removeAll {
            $0.celebration == .goodWeek && !moments.mayCelebrateGoodWeek(at: t.wall)
        }
        if let due = pendingFreshWindow, t.mono - due > PetTuning.Brain.freshWindowWait { pendingFreshWindow = nil }
        if let due = returnPending, t.mono - due > PetTuning.Brain.returnWait { returnPending = nil }
    }

    func evaluateCondition(at t: PetTime) -> PetCondition {
        guard showPet else { return .off }
        switch forced {
        case .idle?: return .awake(mood)
        case .asleep?: return .asleep
        case .hibernating?: return .hibernating
        case nil: break
        }
        guard let accounts else { return .unsure }
        if accounts.isEmpty { return .noAccounts }
        if den.isResting { return .hibernating }
        if nap.isResting { return .asleep }
        let readings = accounts.compactMap(\.reading)
        if readings.isEmpty
            || readings.allSatisfy({ t.wall.timeIntervalSince($0.fetchedAt) >= PetTuning.Stale.unsure }) {
            return .unsure
        }
        return .awake(mood)
    }

    mutating func setCondition(_ new: PetCondition) {
        guard new != condition else { return }
        if case .unsure = new {
            // The words freeze on the mood it had while the numbers were fresh.
            if case .awake(let last) = condition { unsureMood = last } else { unsureMood = mood }
        }
        condition = new
        conditionChanges += 1
    }

    /// A period ended: a weekly close is where a good week is judged, a 5-hour close where a fresh
    /// window is.
    mutating func periodClosed(_ close: PetPeriodClose, at t: PetTime) {
        switch close.window {
        case .sevenDay:
            guard moments.weekClosed(account: close.account, resetAt: close.resetAt, used: close.high) else { return }
            pendingCelebrations.append(PendingCelebration(
                celebration: .goodWeek, until: close.resetAt.addingTimeInterval(PetTuning.Moments.goodWeekLine)))
        case .fiveHour:
            guard isAwake, t.wall.timeIntervalSince(close.resetAt) <= PetTuning.Brain.freshWindowWait,
                  lastFreshWindow.map({ t.mono - $0 >= PetTuning.Moments.freshWindowEvery }) ?? true
            else { return }
            let share = PetFood.shares(accounts ?? [])[close.account] ?? 0
            if share * close.high >= PetTuning.Moments.freshWindowFreed { pendingFreshWindow = t.mono }
        }
    }

    /// The meter's track: a new key wherever the value jumped or the rate changed.
    mutating func refreshMeter(at t: PetTime) {
        running = hungerClockRuns(at: t)
        if running, let accounts {
            let raw = PetLimits.pace(accounts, now: t.wall, food: food)
            pace = (raw / PetTuning.Brain.paceGrid).rounded() * PetTuning.Brain.paceGrid
        }
        let rate = running && hunger.value < PetTuning.Hunger.maximum ? PetHunger.rate(pace: pace) : 0
        let stop = lastInput.map { $0 + PetTuning.Presence.away }
        if hungerLine.map({ $0.rate != rate || $0.value(at: t.mono, stoppingAt: stop) != hunger.value }) ?? true {
            hungerLine = HungerLine(t: t.mono, value: hunger.value, rate: rate)
        }
        let value = meterValue
        if let last = timeline.meter.last {
            let predicted = last.value + last.rate * (t.mono - last.t)
            guard abs(predicted - value) > 1e-9 || last.rate != rate else { return }
            if last.t == t.mono { timeline.meter.removeLast() }
        } else if value == PetTuning.Hunger.newPet && rate == 0 {
            return                                  // no key reads as a new pet's 30
        }
        timeline.meter.append(PetMeterKey(t: t.mono, value: value, rate: rate))
    }
}

// MARK: - Events

extension PetBrain {
    mutating func apply(_ event: PetEvent, at t: PetTime) {
        if bornAt == nil { bornAt = t.wall }
        switch event {
        case .readings(let accounts):
            self.accounts = accounts
            if showPet { take(accounts, at: t) }
        case .prompt:
            prompt(at: t)
        case .presence(let presence):
            sense(presence, at: t)
        case .systemSleep:
            systemAsleep = true
            goAway(at: t)
        case .systemWake:
            // Away until the next presence check says otherwise; the gap's closes and resets are
            // played at the next update, in their own order.
            systemAsleep = false
        case .clockChanged:
            break                                   // every rule reads the wall clock afresh
        case .timeZone(let zone):
            timeZone = zone
        case .visible(let visible):
            visibleFlag = visible
        case .showPet(let on):
            turn(on: on, at: t)
        case .motion(let motion):
            self.motion = motion
        case .pointer(let distance):
            pointer(at: distance, time: t)
        case .boop:
            boop(at: t)
        case .tick:
            break
        case .debugHunger(let value):
            hunger = PetHunger(value: value)
        case .forceState(let state):
            forced = state
        }
    }

    /// Food from a set of readings, and the periods they closed.
    mutating func take(_ accounts: [PetAccount], at t: PetTime) {
        let intake = food.take(accounts)
        for close in intake.closes { periodClosed(close, at: t) }
        guard intake.points > 0 else { return }
        let drop = hunger.eat(intake.points)
        if let milestone = moments.credit(intake.points, at: t.wall, timeZone: timeZone) {
            pendingCelebrations.append(PendingCelebration(celebration: .streak(days: milestone),
                                                          until: PetMoments.endOfDay(t.wall, in: timeZone)))
        }
        // At rest H has it and there is no meal; still out in the open, it is the meal that fills
        // the window, eaten before the yawn.
        if isResting && currentPlace != .open { return }
        plate.points += intake.points
        plate.drop += drop
        plate.lastFood = t.mono
    }

    var isResting: Bool {
        switch condition {
        case .asleep, .hibernating, .noAccounts: return true
        default: return false
        }
    }

    mutating func prompt(at t: PetTime) {
        guard showPet, let current else { return }
        let previous = lastPrompt
        lastPrompt = t.mono
        switch place(after: current.behaviour) {
        case .nap:
            // Asleep, a prompt is one brow twitch at most once a minute; it does not wake.
            guard current.behaviour != .fallAsleep,
                  lastPromptTwitch.map({ t.mono - $0 >= PetTuning.Eager.sleepTwitchEvery }) ?? true,
                  lastTwitch.map({ t.mono - $0 >= PetTuning.Pointer.sleepTwitchEvery }) ?? true else { return }
            lastPromptTwitch = t.mono
            lastTwitch = t.mono
            cue(.twitch, at: t)
        case .open:
            guard isAwake, !away, introDone else { return }
            if capped {
                // After the 600 s of eager, idle until a minute passes with no prompt.
                guard let previous, t.mono - previous >= PetTuning.Eager.cooldown else { return }
                capped = false
            }
            if eagerUntil != nil, let since = eagerSince {
                eagerUntil = min(t.mono + PetTuning.Eager.afterPrompt, since + PetTuning.Eager.maximum)
                if lastPerk.map({ t.mono - $0 >= PetTuning.Eager.reperk }) ?? true { queuedPrompt = t.mono }
            } else {
                queuedPrompt = t.mono
            }
        default:
            return                                  // hibernating or in the den: no reaction
        }
    }

    mutating func sense(_ new: PetPresence, at t: PetTime) {
        presence = new
        lastInput = t.mono - max(0, new.inputIdle)
        let gone = new.displayAsleep || new.screenLocked || new.sessionInactive || systemAsleep
            || new.inputIdle >= PetTuning.Presence.away
        if gone && !away {
            goAway(at: t)
        } else if !gone && away {
            away = false
            if let since = awaySince, t.wall.timeIntervalSince(since) >= PetTuning.Presence.away {
                returnPending = t.mono
            }
            awaySince = nil
        }
    }

    /// Away at once: eager ends, and the absence is counted from the last input.
    mutating func goAway(at t: PetTime) {
        guard !away else { return }
        away = true
        awaySince = lastInput.map { t.wall.addingTimeInterval($0 - t.mono) } ?? t.wall
        eagerSince = nil
        eagerUntil = nil
        queuedPrompt = nil
    }

    mutating func turn(on: Bool, at t: PetTime) {
        guard on != showPet else { return }
        showPet = on
        if on {
            // The time it was off is away time: the trackers stood still, so what grew meanwhile
            // is a catch-up meal now.
            if let accounts { take(accounts, at: t) }
        } else {
            // Off: no hunger, no plans, no moments waiting. Turned on again, it is judged afresh.
            nap.forget()
            den.forget()
            plate = Plate()
            swallows = []
            eagerSince = nil
            eagerUntil = nil
            queuedPrompt = nil
            queuedBoop = nil
            pendingFreshWindow = nil
            returnPending = nil
            noticed = false
        }
    }

    mutating func pointer(at distance: Double, time t: PetTime) {
        // The segment playing at `t`: on the fast path the plan after it is still on the timeline.
        guard showPet, let playing = timeline.segments.last(where: { $0.start <= t.mono }) else { return }
        typealias P = PetTuning.Pointer
        switch place(after: playing.behaviour) {
        case .nap:
            guard distance <= P.sleepTwitch,
                  lastTwitch.map({ t.mono - $0 >= P.sleepTwitchEvery }) ?? true else { return }
            lastTwitch = t.mono
            cue(.twitch, at: t)
        case .open:
            guard introDone else { return }
            if !noticed && distance <= P.notice {
                noticed = true
                cue(.notice, at: t)
            } else if noticed && distance > P.release {
                noticed = false
                cue(.release, at: t)
            }
        default:
            return
        }
    }

    /// A click on the pet in the panel.
    mutating func boop(at t: PetTime) {
        guard showPet, let current,
              lastBoop.map({ t.mono - $0 >= PetTuning.Boop.spacing }) ?? true,
              quietUntil.map({ t.mono >= $0 }) ?? true else { return }
        switch place(after: current.behaviour) {
        case .nap where current.behaviour != .fallAsleep:
            // A reaction, not a wake: one eye opens and closes.
            lastBoop = t.mono
            cue(.sleepyEye, at: t)
        case .den where !isEnteringOrLeaving(current.behaviour), .burrow where !isEnteringOrLeaving(current.behaviour):
            // In the den, or curled up where there is none: the glow pulses once.
            lastBoop = t.mono
            cue(.glowPulse, at: t)
        case .open where !ignoresBoops(current.behaviour):
            lastBoop = t.mono
            boops = boops.filter { t.mono - $0 < PetTuning.Boop.giggleWindow } + [t.mono]
            let giggle = boops.count >= PetTuning.Boop.giggleCount
            if giggle {
                boops = []
                quietUntil = t.mono + PetTuning.Boop.giggleQuiet
            }
            queuedBoop = giggle
        default:
            return                                  // dozing, off, or in a beat a boop never cuts
        }
    }

    func isEnteringOrLeaving(_ behaviour: PetBehaviour) -> Bool {
        switch behaviour {
        case .enterDen, .leaveDen: return true
        default: return false
        }
    }

    /// A boop during these is ignored, not queued; `fallAsleep` too, which is not in the open.
    func ignoresBoops(_ behaviour: PetBehaviour) -> Bool {
        switch behaviour {
        case .eat, .celebrate, .wake, .leaveDen: return true
        default: return false
        }
    }

    /// Cues stay in time order, also when the plan already holds later ones (a pointer between
    /// updates, ahead of a release planned at a yawn).
    mutating func cue(_ kind: PetCue.Kind, at t: PetTime) {
        let index = timeline.cues.firstIndex { $0.t > t.mono } ?? timeline.cues.endIndex
        timeline.cues.insert(PetCue(t: t.mono, kind: kind), at: index)
    }
}

// MARK: - Deciding

extension PetBrain {
    /// What should start at `t`, or nil to let the current segment go on. Priorities, highest first:
    /// `off` · the intro · changes of condition · `eat` · `celebrate` · `boop` · `perk` and `eager` ·
    /// `freshWindow` · a welcome back · the open behaviour.
    func decide(at t: PetTime) -> PetBehaviour? {
        let target = restingBehaviour(at: t)
        // Until it has heard the accounts it cannot know whether the pet is out, asleep or in the
        // den, so it plays nothing; the controller sends them in the same turn as the rest.
        guard let current else { return accounts == nil && condition != .off ? nil : target }
        let behaviour = current.behaviour
        let elapsed = t.mono - current.start
        let done = behaviour.duration.map { elapsed >= $0 - 1e-9 } ?? false

        if condition == .off { return behaviour == .off ? nil : .off }
        if behaviour == .off { return target }                 // fade in at the data's condition
        // An action finishes; whatever comes meanwhile waits. `satisfied` is the one action that
        // may be cut.
        if behaviour.duration != nil, !done, !isSatisfied(behaviour) { return nil }

        if !introDone, introDue, behaviour == .denWait { return .intro(noAccounts: accounts?.isEmpty ?? true) }

        let from = place(after: behaviour)
        if let change = transition(from: from, behaviour: behaviour, done: done, target: target, at: t) {
            return change
        }
        if case .eat(let meal) = behaviour, done {
            return .satisfied(satisfaction(after: meal))
        }
        guard from == .open || (from == .doze && targetPlace == .open) else {
            return done ? held(from, target: target) : nil
        }

        func mayCut(_ kind: QueueKind) -> Bool {
            if done { return true }
            switch behaviour {
            case .idle, .settled, .unsureIdle, .doze: return true
            case .eager: return kind != .freshWindow && kind != .welcomeBack
            case .satisfied:
                if kind == .eat || kind == .celebrate { return elapsed >= PetTuning.Meal.satisfiedMinimum - 1e-9 }
                return kind == .boop
            default: return false
            }
        }
        if mealDue(at: t), mayCut(.eat) { return .eat(planMeal(at: t)) }
        if audience, isAwake, let pending = pendingCelebrations.first, mayCut(.celebrate) {
            return .celebrate(pending.celebration)
        }
        if let giggle = queuedBoop, mayCut(.boop) { return .boop(giggle: giggle) }
        if queuedPrompt != nil, isAwake, audience, mayCut(.perk) {
            // A perk at most once a minute; a prompt inside the minute goes straight to eager.
            if lastPerk.map({ t.mono - $0 >= PetTuning.Eager.reperk }) ?? true { return .perk(.prompt) }
            if behaviour != .eager { return .eager }
        }
        if pendingFreshWindow != nil, audience, isAwake, mayCut(.freshWindow) { return .freshWindow }
        if returnPending != nil, audience, mayCut(.welcomeBack) {
            switch condition {
            case .awake, .unsure: return .welcomeBack
            default: break
            }
        }
        guard done || isOpenEnded(behaviour) else { return nil }
        guard behaviour != target else { return nil }
        if behaviour == .eager, elapsed < PetTuning.Eager.minimum - 1e-9, !done { return nil }
        if case .unsureIdle = behaviour, isAwake, audience { return .perk(.freshData) }
        return target
    }

    enum QueueKind { case eat, celebrate, boop, perk, freshWindow, welcomeBack }

    /// What a change of place plays. Nobody watching, a change into rest happens at once; a change out of
    /// rest waits to be seen, so the stretch the person missed still plays.
    func transition(from: Place, behaviour: PetBehaviour, done: Bool, target: PetBehaviour,
                    at t: PetTime) -> PetBehaviour? {
        let seen = audience
        let to = targetPlace
        switch (from, to) {
        case (_, .off):
            return .off
        case (.off, _):
            return target
        case (.open, .open), (.doze, .open), (.doze, .doze):
            return nil
        case (.open, .nap):
            if case .leaveDen = behaviour { return .asleep }        // out of the den still full: no yawn
            // The meal that fills the window, then straight into the yawn.
            if seen, plate.points >= PetTuning.Plate.flushMinimum, !isEat(behaviour) { return .eat(planMeal(at: t)) }
            return seen ? .fallAsleep : .asleep
        case (.open, .den), (.nap, .den):
            return seen ? .enterDen(retreat: false) : .hibernating
        case (.open, .burrow), (.nap, .burrow):
            return seen ? .enterDen(retreat: true) : .denWait
        case (.open, .doze):
            return isVisible ? .dozeIn : .doze
        case (.nap, .open):
            return seen ? .wake : done ? .asleep : nil
        case (.nap, .nap):
            switch (behaviour, target) {
            case (.drowsy, .asleep): return .rollOver
            case (.asleep, .drowsy): return .drowsy
            case (.fallAsleep, _), (.rollOver, _): return done ? target : nil
            default: return nil
            }
        case (.nap, .doze), (.den, .doze), (.burrow, .doze):
            return done ? held(from, target: target) : nil
        case (.den, .open):
            return seen ? .leaveDen(stretch: true) : done ? .hibernating : nil
        case (.den, .nap):
            return seen ? .leaveDen(stretch: false) : .asleep
        case (.den, .den):
            if behaviour == target { return nil }
            if case .enterDen = behaviour, !done { return nil }
            return target
        case (.den, .burrow):
            return .denWait
        case (.burrow, .open):
            guard introDone else { return done ? .denWait : nil }
            return seen ? .leaveDen(stretch: false) : done ? .denWait : nil
        case (.burrow, .nap):
            return seen && introDone ? .leaveDen(stretch: false) : .asleep
        case (.burrow, .den):
            return .hibernating
        case (.burrow, .burrow):
            if behaviour == .denWait {
                guard introDone, seen, t.mono - (current?.start ?? t.mono) >= peekGap(peeks) - 1e-9 else { return nil }
                return .peek
            }
            return done ? .denWait : nil
        case (.doze, .nap):
            return .asleep
        case (.doze, .den):
            return .hibernating
        case (.doze, .burrow):
            return .denWait
        }
    }

    /// Where an action that played out unseen leaves the pet.
    func held(_ place: Place, target: PetBehaviour) -> PetBehaviour {
        switch place {
        case .nap: return .asleep
        case .den: return .hibernating
        case .burrow: return .denWait
        case .doze: return .doze
        case .open, .off: return target
        }
    }

    var introDue: Bool {
        guard !introDone, audience, let accounts else { return false }
        if accounts.isEmpty { return true }
        guard accounts.contains(where: { $0.reading != nil }) else { return false }
        switch condition {
        case .awake, .unsure: return true
        default: return false
        }
    }

    /// A meal starts when the plate holds half a point (or a flush is due), the pet is seen and awake,
    /// and the last meal started 40 s ago or more.
    func mealDue(at t: PetTime) -> Bool {
        typealias P = PetTuning.Plate
        guard audience, isAwake, plate.points >= P.flushMinimum else { return false }
        guard plate.points >= P.mealMinimum || t.mono - plate.lastFood >= P.flushAfter - 1e-9 else { return false }
        return sinceLastMeal(at: t).map { $0 >= P.mealGap - 1e-9 } ?? true
    }

    func planMeal(at t: PetTime) -> PetMeal {
        typealias P = PetTuning.Plate
        let points = plate.points
        let feast = points >= P.feastFrom
        let flush = points < P.mealMinimum
        let quiet = sinceLastMeal(at: t).map { $0 >= P.fullMealAfter } ?? true
        let chews = points < P.twoChewsFrom ? 1 : points < P.threeChewsFrom ? 2 : P.maxChews
        return PetMeal(size: feast || (quiet && !flush) ? .full : .nibble, chews: chews, feast: feast,
                       points: points, reduceMotion: motion.reduceMotion, mood: mood)
    }

    /// What follows a meal that has just ended, its drop already on the meter: after a nibble a lick;
    /// a full meal or a feast eaten famished, the grateful one; a feast its own; a full meal that leaves
    /// it stuffed, the brim; any other full meal, the plain one.
    func satisfaction(after meal: PetMeal) -> PetBehaviour.Satisfaction {
        guard meal.size == .full || meal.feast else { return .lick }
        if meal.mood == .famished { return .grateful }
        if meal.feast { return .feast }
        return mood == .stuffed ? .brim : .meal
    }

    func isSatisfied(_ behaviour: PetBehaviour) -> Bool {
        if case .satisfied = behaviour { return true }
        return false
    }

    func isEat(_ behaviour: PetBehaviour) -> Bool {
        if case .eat = behaviour { return true }
        return false
    }

    func isOpenEnded(_ behaviour: PetBehaviour) -> Bool { behaviour.duration == nil }
}

// MARK: - Committing

extension PetBrain {
    /// Starts `behaviour` at `t`, and does what starting it means.
    mutating func commit(_ behaviour: PetBehaviour, at t: PetTime) {
        // A segment planned for this very instant is replaced: the last decision wins, and the rig
        // never sees a segment of no length.
        while let last = timeline.segments.last, last.start >= t.mono { timeline.segments.removeLast() }
        timeline.segments.append(PetSegment(start: t.mono, behaviour: behaviour))

        switch behaviour {
        case .eat(let meal):
            swallows.append(Swallow(at: t.mono + meal.swallowStart, drop: plate.drop))
            plate = Plate()
            lastMealMono = t.mono
            lastMealWall = t.wall
            lastMealPoints = meal.points
            meals += 1
            // Food arriving ends eager, and the morning's catch-up meal stands in for the welcome back.
            eagerSince = nil
            eagerUntil = nil
            returnPending = nil
        case .intro:
            introDone = true
        case .celebrate(let celebration):
            pendingCelebrations.removeAll { $0.celebration == celebration }
            if celebration == .goodWeek { moments.lastGoodWeekCelebratedAt = t.wall }
            returnPending = nil
        case .boop:
            queuedBoop = nil
        case .perk(.prompt), .eager:
            if let prompt = queuedPrompt {
                if behaviour == .perk(.prompt) { lastPerk = t.mono }
                let since = eagerSince ?? t.mono
                eagerSince = since
                eagerUntil = min(prompt + PetTuning.Eager.afterPrompt, since + PetTuning.Eager.maximum)
                queuedPrompt = nil
            }
        case .freshWindow:
            pendingFreshWindow = nil
            lastFreshWindow = t.mono
        case .welcomeBack, .wake, .leaveDen(stretch: true):
            returnPending = nil
        case .peek:
            peeks += 1
        default:
            break
        }

        let place = self.place(after: behaviour)
        // At rest the hunger model has had the food all along, and nobody eats it.
        if place == .nap || place == .den || place == .burrow {
            switch condition {
            case .asleep, .hibernating, .noAccounts: plate = Plate()
            default: break
            }
        }
        // Out of the open, nothing watches the pointer: close the notice so the rig's gaze is free.
        if noticed && place != .open {
            noticed = false
            cue(.release, at: t)
        }
    }
}

// MARK: - Planning and memory

extension PetBrain {
    /// Plays a copy forward to the end of the action in progress and of every action after it, and
    /// takes its timeline: the plan.
    mutating func plan(from now: PetTime) {
        guard showPet else { return }
        var forecast = self
        for _ in 0..<PetTuning.Brain.chainLimit {
            guard let segment = forecast.current, let duration = segment.behaviour.duration else { break }
            let end = segment.start + duration
            let at = PetTime(wall: now.wall.addingTimeInterval(end - now.mono), mono: end)
            forecast.advance(to: at)
            if forecast.current == segment { forecast.step(at: at) }
            if forecast.current == segment { break }
        }
        timeline = forecast.timeline
    }

    /// Keeps `PetTimeline.memory` of the past: the segment that was playing at its start and what
    /// came after, the cues in it, and the meter key in force at its start.
    mutating func prune(at now: PetTime) {
        let horizon = now.mono - PetTimeline.memory
        if let keep = timeline.segments.lastIndex(where: { $0.start <= horizon }), keep > 0 {
            timeline.segments.removeFirst(keep)
        }
        timeline.cues.removeAll { $0.t < horizon }
        if let keep = timeline.meter.lastIndex(where: { $0.t <= horizon }), keep > 0 {
            timeline.meter.removeFirst(keep)
        }
    }
}

extension PetTimeline {
    /// Forgets everything planned after `time`: the plan is made again from what really happened.
    mutating func dropPlans(after time: TimeInterval) {
        segments.removeAll { $0.start > time }
        cues.removeAll { $0.t > time }
        meter.removeAll { $0.t > time }
    }
}
