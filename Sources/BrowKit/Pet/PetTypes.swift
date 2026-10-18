// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

// The words the pet's two halves share. The brain (`PetBrain`) hears events and writes a timeline of
// behaviours; the rig (`PetRig`) reads a timeline at an instant and poses the pet. The timeline is all
// they share, and nothing in this file decides anything.

// MARK: - Time

/// One instant on both clocks the pet uses. `mono` is `ProcessInfo.systemUptime`: it stops while the
/// Mac sleeps and never jumps, so hunger and animation run on it. `wall` is for what the server dates
/// (reset instants) and for calendar days. The controller reads both once per event and hands them in;
/// nothing inside the brain or the rig asks the system what time it is.
public struct PetTime: Sendable, Equatable {
    public var wall: Date
    public var mono: TimeInterval

    public init(wall: Date, mono: TimeInterval) {
        self.wall = wall
        self.mono = mono
    }

    /// The same instant `seconds` later on both clocks: a deadline worked out from either clock.
    public func adding(_ seconds: TimeInterval) -> PetTime {
        PetTime(wall: wall.addingTimeInterval(seconds), mono: mono + seconds)
    }
}

// MARK: - What the brain hears

/// Everything the brain is told: by `PetController` in the app, by a `PetScript` in tests. The
/// controller sends the whole state once at start (`showPet`, `motion`, `timeZone`, `presence`,
/// `visible`, `readings`) and then each change, every event with its own `PetTime`.
public enum PetEvent: Sendable, Equatable {
    /// The visible accounts in panel order, read one main-actor turn after each `LimitsStore` publish.
    /// Hidden accounts are not in it, so they never feed or wake the pet.
    case readings([PetAccount])
    /// A visible account's `history.jsonl`, or one of its alias dirs', was written: a prompt.
    case prompt
    /// The person at the Mac, from the 5 s presence check and every display, lock and session
    /// notification.
    case presence(PetPresence)
    /// `NSWorkspace.willSleepNotification`: away at once.
    case systemSleep
    /// `NSWorkspace.didWakeNotification`. Its time shows the gap: `wall` moved on, `mono` did not.
    case systemWake
    /// `NSSystemClockDidChange`: the wall clock was set.
    case clockChanged
    /// The time zone fed days are dated in: at start and on `NSSystemTimeZoneDidChange`. The brain
    /// keeps no `Calendar.autoupdatingCurrent` of its own, so a script can move the zone.
    case timeZone(TimeZone)
    /// Whether anyone can see the pet: the panel window is on screen and not occluded, the display is
    /// awake, the screen unlocked, the session active, and either the strip shows the pet (readouts on)
    /// or the panel is open. Meals, moments and transitions wait for it.
    case visible(Bool)
    /// Settings › General › Show the pet.
    case showPet(Bool)
    /// Reduce Motion and the other display options, at start and on each change. The brain needs them
    /// because Reduce Motion's meal is timed differently.
    case motion(PetMotion)
    /// The pointer moved; `distance` is from the pet's eyes (`PetTuning.Pointer.eyeHeight` × scale above
    /// the anchor of the zone it is in) to the pointer, in points.
    case pointer(distance: Double)
    /// A click on the pet in the panel, or VoiceOver's "Pet" action.
    case boop
    /// The instant `PetBrain.nextDeadline(after:)` asked for has come.
    case tick
    /// Script-only: sets H, so a test can make the pet hungry without hours of script.
    case debugHunger(Double)
    /// Pins the condition for a measurement, `-petForceState idle|asleep|hibernating`, or in a script;
    /// nil lets the data decide again.
    case forceState(PetForcedState?)
}

/// One visible account as the pet sees it, built by the controller from a `LimitsStore` row: `id` is
/// `organizationUuid` and `weight` is `RateLimitModel.weight(forTier:)` (20, 5, 1; unknown 1). The
/// model weekly window (Fable, Opus) is left out on purpose: it never feeds the pet or puts it to
/// sleep, since other models still work when it is used up.
public struct PetAccount: Sendable, Equatable {
    public var id: String
    public var weight: Double
    /// nil: the account is visible but has no reading yet (the readout's `—`).
    public var reading: PetReading?
}

/// One account's last reading: its snapshot's 5-hour and weekly windows.
public struct PetReading: Sendable, Equatable {
    /// `LimitSnapshot.fetchedAt`.
    public var fetchedAt: Date
    /// nil: the window has not started (0 % used, no reset instant).
    public var fiveHour: PetWindow?
    public var sevenDay: PetWindow?
}

/// One window of one reading.
public struct PetWindow: Sendable, Equatable {
    /// `usedPercentage`, 0 to 100.
    public var used: Double
    /// `Formatting.resetInstant(resetsAt)`, to the minute as the panel and `LimitWarnings` round it;
    /// nil for a reading that carries no date (it counts toward the aggregate, never as food).
    public var resetAt: Date?
}

/// The person at the Mac. Present means the display awake, the screen unlocked, the session active, and
/// input within `PetTuning.Presence.away`.
public struct PetPresence: Sendable, Equatable {
    /// From `screensDidSleepNotification` until `screensDidWakeNotification`.
    public var displayAsleep = false
    /// From `com.apple.screenIsLocked` until `com.apple.screenIsUnlocked`.
    public var screenLocked = false
    /// From `sessionDidResignActiveNotification` (fast user switching) until it is active again.
    public var sessionInactive = false
    /// Seconds since the last input of any kind:
    /// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`.
    public var inputIdle: TimeInterval = 0
}

/// What `-petForceState` can pin for a measurement.
public enum PetForcedState: String, Sendable, CaseIterable {
    case idle, asleep, hibernating
}

// MARK: - Conditions and moods

/// What the hunger meter means to the pet: thresholds −30, 0, 35, 65 and 90 on H + pendingDrop, each
/// entered at its threshold on the way up and left 5 points below it on the way down.
public enum PetMood: String, Sendable, Hashable, CaseIterable {
    /// Fed far past the brim, and loving it: a round belly, eyes shut in bliss, a pat on the tummy and
    /// now and then a thumbs-up. Never heavy, unwell or sleepy, and always glad of another bite.
    case stuffed
    /// Rounder, breathing slower.
    case full
    case content
    case peckish
    /// Hopeful, never sad, because hunger is a nudge and never a reproach: big eyes on the number, a
    /// lick, a tummy rumble.
    case hungry
    /// The meter near the top: the most hopeful face it has. Up on its toes and leaning toward the
    /// number, shining eyes, a tummy it pats; never sad, thin, tearful or sickly.
    case famished
}

/// What the data says the pet's state is, highest first. It is re-evaluated on every brain update, and
/// the behaviours follow from it.
public enum PetCondition: Sendable, Equatable {
    /// `showPet` is off. No hunger, no frames.
    case off
    /// No visible account. In the den.
    case noAccounts
    /// The effective weekly aggregate reached 99.5 and has not dropped below 97.
    case hibernating
    /// The same for the 5-hour aggregate.
    case asleep
    /// No reading yet, or every visible reading is older than 600 s.
    case unsure
    /// Otherwise. The hunger clock runs while someone is present.
    case awake(PetMood)
}

// MARK: - Behaviours

/// What the pet does, which the rig plays: every behaviour, with what the rig needs to play it.
/// Durations are `duration`'s; which behaviour follows which is the brain's.
public enum PetBehaviour: Sendable, Hashable {
    /// A new pet's first visibility with data loaded: it peeks out of the den, looks around, notices
    /// the readout, steps out and sits (3.6 s). With no accounts it peeks, looks at the `—` and goes
    /// back in (2.2 s).
    case intro(noAccounts: Bool)
    /// Awake with nothing to do: breathing, glances, blinks, rare idles, the posture of its mood.
    case idle(PetMood)
    /// Input idle for 120 to 600 s: the mood's idle at half amplitude, no rare idles.
    case settled(PetMood)
    /// Sits up, brows up, eyes on the food source.
    case perk(Perk)
    /// The perk's loop while Claude Code works: taller, a small bounce every 1.6 to 2.2 s, eyes on
    /// the food source. Over the hungry posture too: the most hopeful face it has.
    case eager
    /// A meal: anticipation, the bite, the chews, the swallow.
    case eat(PetMeal)
    /// After a meal: 3.0 s, 4.0 after a feast; after a nibble, a 0.6 s lick. A full meal that leaves it
    /// stuffed, and one eaten famished, have satisfactions of their own (`brim`, `grateful`).
    case satisfied(Satisfaction)
    /// A click on the pet in the panel: 0.6 s, or the 1.2 s giggle after five boops in 6 s.
    case boop(giggle: Bool)
    /// A streak milestone (2.4 s) or a good week (2.8 s).
    case celebrate(Celebration)
    /// A 5-hour period closed and freed 20 points or more: it looks at the readout and hops once,
    /// 1.0 s.
    case freshWindow
    /// Stuffed: a yawn, a droop, a curl, 2.6 s.
    case fallAsleep
    /// Asleep at the 5-hour limit, lying at the anchor at most 14 pt tall, Zzz rising.
    case asleep
    /// The reset instant passed: sitting up, eyes at 0.35, slow blinks and yawns, waiting up to 180 s
    /// for fresh numbers.
    case drowsy
    /// The weekly reset passed: still in the den, it stirs while it waits up to 180 s for fresh
    /// numbers, its glow brightening and an eye at the edge. The den's own `drowsy`: a case of
    /// its own, so the rig never has to guess from the segment before it whether the pet is in the
    /// open or in the den.
    case stirring
    /// A stir, a stretch, a shake, 2.7 s.
    case wake
    /// A fresh reading in `drowsy` still says full: back to sleep in 1.0 s, no yawn.
    case rollOver
    /// Into the den at the weekly limit, 3.2 s; `retreat` is its second half, 1.6 s, when no account
    /// is visible any more.
    case enterDen(retreat: Bool)
    /// In the den at the weekly limit: most of the body past the edge, and what still shows breathes
    /// with a dim glow. On the pill, curled into a ball.
    case hibernating
    /// Out of the den: a peek, out, a stretch, a shake, 3.7 s; without the stretch and the shake,
    /// 1.6 s, when an account becomes visible again.
    case leaveDen(stretch: Bool)
    /// No visible account: in the den, between peeks. On the pill, curled and dim.
    case denWait
    /// One 2.2 s look out of the den during `denWait`; on the pill, a look around. A segment of its
    /// own, so that the frame policy and the rig both see where it starts and ends.
    case peek
    /// Every reading older than 600 s, or none yet: it looks at the grey dot (or the `—`) with a head
    /// tilt every 20 to 40 s, in the last mood it had.
    case unsureIdle(PetMood)
    /// Away for 600 s: 2.0 s of settling into a doze.
    case dozeIn
    /// Away: nothing is drawn.
    case doze
    /// Back after 600 s or more away: a blink and a small stretch, 1.8 s.
    case welcomeBack
    /// `showPet` turned off: a 0.2 s fade, then nothing. Whatever segment follows fades in over 0.3 s.
    case off

    /// What a perk answers: a prompt (0.5 s), or fresh numbers ending `unsureIdle` (0.8 s, at the readout).
    public enum Perk: Sendable, Hashable {
        case prompt, freshData
    }

    /// Which meal `satisfied` follows.
    public enum Satisfaction: Sendable, Hashable {
        case meal, feast, lick
        /// A full meal that leaves it stuffed: a pat-pat on the round belly, a thumbs-up, a contented
        /// sigh. 3.0 s, like `meal`.
        case brim
        /// A full meal or a feast eaten famished, the most grateful of all: it hugs itself, sparkles, a
        /// little bounce, then a hopeful look at the number for more. 3.0 s, like `meal`.
        case grateful
    }

    /// What is being celebrated.
    public enum Celebration: Sendable, Hashable {
        /// A fed-day milestone: 3, 7, 14, 30, 60 or 100 days.
        case streak(days: Int)
        case goodWeek
    }
}

/// One meal as the brain planned it.
public struct PetMeal: Sendable, Hashable {
    public enum Size: Sendable, Hashable {
        /// The first meal after 600 s without one, and every feast.
        case full
        /// Any other meal, and every flush.
        case nibble
    }

    public var size: Size
    /// 1 to 3: under 1.5 points one, under 2.5 two, otherwise three. Under Reduce Motion, one per
    /// point, up to three.
    public var chews: Int
    /// The plate held 8 points or more: always full, a longer swallow, a round belly for 20 minutes.
    public var feast: Bool
    /// What the plate held, in food points: the panel's "Ate 3 %".
    public var points: Double
    /// Planned as Reduce Motion's meal: a crossfade to a chewing pose, the chews, a crossfade back.
    /// Stamped when it is planned, so a setting changed mid-meal cannot change its length.
    public var reduceMotion: Bool
    /// The mood it was planned in, before this food reached the meter: a famished pet eats the most
    /// grateful meal, a stuffed one a lazy, happy one. How it looks only; its timing never depends on it.
    public var mood: PetMood = .content

    /// From the meal's start to the swallow's: where the meter's drop lands. Under Reduce Motion, the
    /// start of the crossfade back.
    public var swallowStart: TimeInterval {
        typealias M = PetTuning.Meal
        if reduceMotion { return PetTuning.Reduced.mealFade + Double(chews) * PetTuning.Reduced.chew }
        switch size {
        case .full:
            return M.fullAnticipation + M.fullLunge + M.fullHold + M.fullRecoil + Double(chews) * M.fullChew
        case .nibble:
            return M.nibbleAnticipation + M.nibbleLunge + M.nibbleHold + M.nibbleRecoil
                + Double(chews) * M.nibbleChew
        }
    }

    /// The whole meal, anticipation to the end of the swallow: 1.34, 1.66 or 1.98 s full, 0.86, 1.14
    /// or 1.42 s as a nibble, 2.38 s for a three-chew feast.
    public var duration: TimeInterval {
        typealias M = PetTuning.Meal
        if reduceMotion { return swallowStart + PetTuning.Reduced.mealFade }
        switch size {
        case .full: return swallowStart + M.fullSwallow + (feast ? M.feastSwallowExtra : 0)
        case .nibble: return swallowStart + M.nibbleSwallow
        }
    }
}

/// How often a behaviour needs a frame. `PetFramePolicy` turns a class into a rate and applies the
/// caps; the speed tests in `PetRigTests` hold each behaviour to its class's rate.
public enum PetFrameClass: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Paused: `doze`, `denWait` between peeks, and every closed gate.
    case off
    /// 10 fps: `hibernating`, `settled`.
    case still
    /// 15 fps: `asleep`, `drowsy`, `stirring`, `rollOver`.
    case sleep
    /// 30 fps: idle in every mood, `eager`, `unsureIdle`, `dozeIn`.
    case idle
    /// 60 fps: transitions, `satisfied`, celebrations, pointer tracking, and meals on battery.
    case action
    /// The display's own rate, on AC power: `eat`, `boop`, the hop, the wake's shake.
    case fast

    public static func < (a: PetFrameClass, b: PetFrameClass) -> Bool { a.rawValue < b.rawValue }
}

extension PetBehaviour {
    /// How long the behaviour plays when nothing cuts it; nil for the open ones, which last until the
    /// brain plans what comes next. `drowsy` and `stirring` are open too: the brain ends them within
    /// `PetTuning.Limits.confirmationWait`.
    public var duration: TimeInterval? {
        typealias B = PetTuning.Behaviour
        switch self {
        case .intro(let noAccounts): return noAccounts ? B.introNoAccounts : B.intro
        case .perk(let perk): return perk == .prompt ? B.perk : B.freshDataPerk
        case .eat(let meal): return meal.duration
        case .satisfied(.meal), .satisfied(.brim), .satisfied(.grateful): return PetTuning.Meal.satisfied
        case .satisfied(.feast): return PetTuning.Meal.satisfiedFeast
        case .satisfied(.lick): return PetTuning.Meal.lick
        case .boop(let giggle): return giggle ? PetTuning.Boop.giggle : PetTuning.Boop.boop
        case .celebrate(.streak): return B.celebrateStreak
        case .celebrate(.goodWeek): return B.celebrateGoodWeek
        case .freshWindow: return B.freshWindow
        case .fallAsleep: return B.fallAsleep
        case .wake: return B.wake
        case .rollOver: return B.rollOver
        case .enterDen(let retreat): return retreat ? B.retreat : B.enterDen
        case .leaveDen(let stretch): return stretch ? B.leaveDen : B.leaveDenShort
        case .peek: return B.peek
        case .dozeIn: return B.dozeIn
        case .welcomeBack: return B.welcomeBack
        case .idle, .settled, .eager, .asleep, .drowsy, .stirring, .hibernating, .denWait, .unsureIdle, .doze, .off:
            return nil
        }
    }

    /// The frame class `elapsed` seconds into the behaviour. Three behaviours change class part-way: the
    /// wake's shake and a streak's twirl need the fast rate, and `off` needs frames only for its fade.
    public func frameClass(elapsed: TimeInterval) -> PetFrameClass {
        typealias B = PetTuning.Behaviour
        switch self {
        case .celebrate(.streak):
            return B.streakTwirl.contains(elapsed) ? .fast : .action
        case .idle, .eager, .unsureIdle, .dozeIn:
            return .idle
        case .settled, .hibernating:
            return .still
        case .asleep, .drowsy, .stirring, .rollOver:
            return .sleep
        case .eat, .boop:
            return .fast
        case .wake:
            return elapsed >= B.wakeStir + B.wakeStretch ? .fast : .action
        case .off:
            return elapsed < B.fadeOut ? .action : .off
        case .denWait, .doze:
            return .off
        case .intro, .perk, .satisfied, .celebrate, .freshWindow, .fallAsleep, .enterDen, .leaveDen, .peek,
             .welcomeBack:
            return .action
        }
    }
}

// MARK: - The timeline

/// One behaviour, from its start until the next segment starts. The brain plans what follows a
/// behaviour with a `duration` when it plans the behaviour, so the next segment starts at its end at
/// the latest, and the rig never has to guess what comes after an action.
public struct PetSegment: Sendable, Hashable {
    /// `PetTime.mono` seconds in the app; seconds from 0 in a hand-written segment script.
    public var start: TimeInterval
    public var behaviour: PetBehaviour
}

/// A short reaction on top of whatever behaviour is playing. The brain decides whether one happens,
/// with its conditions and rate limits; the rig decides how it looks.
public struct PetCue: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The pointer came within 160 pt: for 0.25 s the eyes widen and the head turns, and from then
        /// on the eyes follow `PetPointerTrack`.
        case notice
        /// The pointer went beyond 200 pt: the gaze holds 0.6 s, then it is back to its own glances.
        case release
        /// Asleep, a prompt or the pointer moving within 40 pt: a brow twitches in its sleep.
        case twitch
        /// A boop while asleep: one eye opens and closes, 0.9 s.
        case sleepyEye
        /// A boop while hibernating: the glow pulses once, 0.6 s.
        case glowPulse
    }

    public var t: TimeInterval
    public var kind: Kind
}

/// One straight piece of the hunger the meter shows: from `t` until the next key it is
/// `value + rate · (now − t)`. `value` is H + pendingDrop before the clamp (−50 to 100), so the light
/// changes at the swallow, not when a reading arrives.
public struct PetMeterKey: Sendable, Hashable {
    public var t: TimeInterval
    public var value: Double
    /// Points per second: 20 · f / 3600 while the hunger clock runs, 0 while it stands.
    public var rate: Double
}

/// What the brain writes and the rig reads. The same timeline at the same instant always gives the
/// same frame.
public struct PetTimeline: Sendable, Equatable {
    /// In start order. A showreel's segment script is a timeline written by hand.
    public var segments: [PetSegment] = []
    /// In time order.
    public var cues: [PetCue] = []
    /// In time order. Before the first key the meter reads as the first key's value, and with no key at
    /// all as a new pet's (`PetTuning.Hunger.newPet`).
    public var meter: [PetMeterKey] = []

    /// How much of the past the brain keeps: a past segment still shapes the pose for
    /// `PetTuning.Secondary.tail` of follow-through after it ends, and a feast's belly for 20 minutes.
    public static let memory: TimeInterval = PetTuning.Meal.feastBellyDecay
}

/// Events with their times, for the brain: the brain tests, and any render that wants the brain to
/// decide what plays.
public struct PetScript: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var time: PetTime
        public var event: PetEvent
    }

    public var steps: [Step] = []
}
