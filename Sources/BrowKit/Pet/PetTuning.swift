// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// Every number the pet runs on, in one place and grouped by what it tunes. Units: seconds, points on
/// screen (pt), percent used (0 to 100) and food points, where one point of food is one point of the
/// left readout. Angles are in degrees.
///
/// Brow's own numbers are not repeated here, so they cannot drift apart: the grey-dot age is
/// `LimitSnapshot.staleAfter`, the strip and pill sizes are `NotchGeometry`'s, the readouts'
/// padding, dot and fonts are `EarsMetrics`'s and the tier weights are `RateLimitModel`'s. The one
/// exception is the outline's two springs (`Hop`), which `NotchPanelController` holds as
/// `Animation` values that cannot be read back as numbers.
public enum PetTuning {

    // MARK: - Mechanics

    /// What counts as food.
    public enum Food {
        /// Two reset instants this close are the same period. Absorbs the endpoint's `…:59.64`
        /// beside `:00`, as `LimitWarnings.samePeriod` does; two 5-hour periods are never this close.
        public static let samePeriod: TimeInterval = 600
        /// A reading whose reset instant lies more than this before its own `fetchedAt` describes a
        /// window that had already closed when it was fetched, and is ignored.
        public static let closedReadingSlack: TimeInterval = 60
    }

    /// The plate: the queue of food the pet has not been seen eating yet.
    public enum Plate {
        /// A meal starts once the plate holds this much (and the pet is visible, awake and free).
        public static let mealMinimum: Double = 0.5
        /// A plate this full that gets no more food for `flushAfter` is eaten as a nibble. Less than
        /// this, never followed by more, is crumbs: dropped, with no animation.
        public static let flushMinimum: Double = 0.1
        public static let flushAfter: TimeInterval = 120
        /// From the start of one meal to the start of the next; food arriving meanwhile waits.
        public static let mealGap: TimeInterval = 40
        /// The first meal after this long without one is a full meal; any other is a nibble.
        public static let fullMealAfter: TimeInterval = 600
        /// Chews by plate size: under 1.5 points one, under 2.5 two, otherwise three, never more.
        public static let twoChewsFrom: Double = 1.5
        public static let threeChewsFrom: Double = 2.5
        public static let maxChews = 3
        /// A plate this full is a feast: always a full meal, a bigger swallow, a round belly.
        public static let feastFrom: Double = 8
    }

    /// The meal's timing, which the rig hits to one frame. A full meal of three chews, such as
    /// 41 → 44 % after a quiet while, is 1.98 s.
    public enum Meal {
        public static let fullAnticipation: TimeInterval = 0.30
        public static let fullLunge: TimeInterval = 0.12
        public static let fullHold: TimeInterval = 0.06
        public static let fullRecoil: TimeInterval = 0.18
        public static let fullChew: TimeInterval = 0.32
        public static let fullSwallow: TimeInterval = 0.36
        public static let nibbleAnticipation: TimeInterval = 0.10
        public static let nibbleLunge: TimeInterval = 0.10
        public static let nibbleHold: TimeInterval = 0
        public static let nibbleRecoil: TimeInterval = 0.14
        public static let nibbleChew: TimeInterval = 0.28
        public static let nibbleSwallow: TimeInterval = 0.24
        /// A feast's swallow is this much longer: 0.76 s instead of 0.36.
        public static let feastSwallowExtra: TimeInterval = 0.40
        /// After a full meal, `satisfied` plays this long; after a feast, `satisfiedFeast`; after a
        /// nibble, only a lick.
        public static let satisfied: TimeInterval = 3.0
        public static let satisfiedFeast: TimeInterval = 4.0
        public static let lick: TimeInterval = 0.6
        /// `eat` and `celebrate` may cut `satisfied` only after this much of it.
        public static let satisfiedMinimum: TimeInterval = 1.5
        /// A feast leaves the belly this round, easing back to 0 over `feastBellyDecay`.
        public static let feastBelly: Double = 1.0
        public static let feastBellyDecay: TimeInterval = 20 * 60
        /// Crumbs from the food source to the mouth: how many, how big, how opaque (of the source
        /// readout's dot colour) and how long their arc takes, landing on the snap.
        public static let crumbsMinimum = 2
        public static let crumbsMaximum = 4
        public static let crumbSizeMinimum: Double = 1.0
        public static let crumbSizeMaximum: Double = 1.5
        public static let crumbOpacity: Double = 0.8
        public static let crumbFlight: TimeInterval = 0.35
    }

    /// The hunger meter. H runs from `minimum` to `maximum`; the meter shows it clamped to 0...100.
    public enum Hunger {
        public static let minimum: Double = -50
        public static let maximum: Double = 100
        public static let newPet: Double = 30
        /// While the hunger clock runs, at an even weekly pace (f = 1).
        public static let perHour: Double = 20
        /// What one food point takes off H: one point is 18 minutes of hunger, and the break-even
        /// intake is 20 / 6 = 3.3 points per hour of hunger time.
        public static let perPoint: Double = 6
        /// Pace damping: f = clamp(1 − ahead / paceStop, 0, 1). Fifteen points ahead of an even pace
        /// the pet gets hungry at half speed; thirty ahead, not at all.
        public static let paceStop: Double = 30
        /// The weekly window's length, for an even week's pace (`PetLimits.evenPace`).
        public static let week: TimeInterval = 7 * 86_400
        /// Mood thresholds, judged on H + pendingDrop: Full above −30, Content above 0, Peckish from 35,
        /// Hungry from 65, Famished from 90. A mood is entered at its threshold on the way up and left
        /// `moodHysteresis` below it on the way down: Stuffed from −35 coming down, Hungry again below 85.
        /// Stuffed takes a big meal (about six points from H = 0, a feast from 13 or below) and lasts up to
        /// an hour of hunger time from the floor; Famished comes 4 h 30 min after H = 0 at an even pace.
        public static let fullAbove: Double = -30
        public static let contentAbove: Double = 0
        public static let peckishFrom: Double = 35
        public static let hungryFrom: Double = 65
        public static let famishedFrom: Double = 90
        public static let moodHysteresis: Double = 5
    }

    /// A limit used up. The 5-hour window puts the pet to sleep and the weekly one into hibernation, by
    /// the same rules.
    public enum Limits {
        /// The effective aggregate at which the readout rounds to `100%`: asleep, or hibernating.
        public static let enter: Double = 99.5
        /// Stays asleep (or hibernating) while the aggregate is at least this: a jittery API 99
        /// after a statusline 100 does not wake it.
        public static let stay: Double = 97
        /// The shortest stay before an exit that is not a reset. A reset wakes it whenever it comes.
        public static let minimumStay: TimeInterval = 60
        /// After the wake instant, how long it waits drowsy for a fresh reading before it gets up.
        public static let confirmationWait: TimeInterval = 180
        /// It falls asleep again no sooner than this after a wake (5-hour window only).
        public static let sleepAfterWake: TimeInterval = 30
        /// Drowsy: eyes this open, a slow blink every 3 to 5 s, a yawn at once and every 40 s.
        public static let drowsyEyes: Double = 0.35
        public static let drowsyBlinkMinimum: TimeInterval = 3
        public static let drowsyBlinkMaximum: TimeInterval = 5
        public static let drowsyYawnEvery: TimeInterval = 40
    }

    /// Claude Code is working: food is coming.
    public enum Eager {
        /// A small bounce every 1.6 to 2.2 s.
        public static let bounceMinimum: TimeInterval = 1.6
        public static let bounceMaximum: TimeInterval = 2.2
        /// Eager lasts this long after the latest prompt; each prompt extends it.
        public static let afterPrompt: TimeInterval = 90
        /// At most this long from the first perk; then idle until `cooldown` passes with no prompt.
        public static let maximum: TimeInterval = 600
        public static let cooldown: TimeInterval = 60
        /// At most one perk per this long.
        public static let reperk: TimeInterval = 60
        /// The shortest `eager` before it may end.
        public static let minimum: TimeInterval = 2.0
        /// Asleep, a prompt makes the pet twitch at most once per this long; it does not wake.
        public static let sleepTwitchEvery: TimeInterval = 60
        /// A watched `history.jsonl` that was deleted or renamed is opened again after this long.
        public static let watcherReopen: TimeInterval = 1
    }

    /// The pointer.
    public enum Pointer {
        /// Noticed within this distance of the eyes, which sit `eyeHeight × scale` above the anchor.
        public static let notice: Double = 160
        public static let eyeHeight: Double = 15
        /// Released beyond this distance, after holding the gaze for `releaseHold`.
        public static let release: Double = 200
        public static let releaseHold: TimeInterval = 0.6
        /// The eyes track critically damped at this rate (rad/s)...
        public static let eyeOmega: Double = 18
        /// ...and the head follows once the angle to the pointer passes `headFollowDegrees`.
        public static let headFollowDegrees: Double = 25
        public static let headOmega: Double = 9
        public static let headZeta: Double = 0.9
        /// Asleep, the pointer moving within this distance makes it twitch, at most once per
        /// `sleepTwitchEvery`.
        public static let sleepTwitch: Double = 40
        public static let sleepTwitchEvery: TimeInterval = 20
    }

    /// Whether anyone is at the Mac.
    public enum Presence {
        /// Input idle this long: `settled`, idle motion at `settledAmplitude`, no rare idles.
        public static let settled: TimeInterval = 120
        public static let settledAmplitude: Double = 0.5
        /// Input idle this long: away. The doze starts, the hunger clock stops (counted from this
        /// long after the last input), and coming back after it is a welcome back.
        public static let away: TimeInterval = 600
        /// The presence check runs this often while the display is awake and the session active.
        public static let checkEvery: TimeInterval = 5
        public static let checkTolerance: TimeInterval = 1
        /// Two checks further apart than this mean the Mac slept and the wake notification was missed.
        public static let missedCheck: TimeInterval = 30
    }

    /// No fresh numbers.
    public enum Stale {
        /// Every visible reading older than this, or none at all: `unsure`, and the hunger clock stops
        /// (it also needs one visible reading younger than this to run).
        public static let unsure: TimeInterval = 600
        /// Unsure, a head tilt every 20 to 40 s.
        public static let tiltMinimum: TimeInterval = 20
        public static let tiltMaximum: TimeInterval = 40
    }

    /// The den behind the camera.
    public enum Den {
        /// No visible account: a peek out of the den every 60 to 120 s (on the pill, a look around).
        public static let peekMinimum: TimeInterval = 60
        public static let peekMaximum: TimeInterval = 120
        /// Hibernating beside, at least this share of the body's area is past the notch's edge.
        public static let hiddenArea: Double = 0.70
        /// What stays visible breathes: glow 0.15 to 0.25 on a 6 s cycle, a Zzz from the edge every 6 s.
        public static let glowMinimum: Double = 0.15
        public static let glowMaximum: Double = 0.25
        public static let glowCycle: TimeInterval = 6.0
        public static let zzzEvery: TimeInterval = 6.0
        /// Below, hibernating leaves a line of glow this thick along the notch's bottom edge: light
        /// under the door.
        public static let doorLight: Double = 1
        /// On the pill there is no den: hibernation curls into a ball with its glow at this share.
        public static let pillGlow: Double = 0.30
    }

    /// The Mac asleep, and clocks that jump.
    public enum Clock {
        /// Wall and monotonic deltas between two checks that differ by more than this are a jump.
        public static let jump: TimeInterval = 5
        /// After a night asleep, what plays at the first visible frame (wake, catch-up meal, one
        /// moment) never takes much more than this.
        public static let morningAtMost: TimeInterval = 10
    }

    /// The pet's file, `pet.json`.
    public enum Store {
        public static let fileName = "pet.json"
        public static let version = 1
        /// Kept: points eaten for the last 60 local dates, the last 16 good weeks.
        public static let keptDays = 60
        public static let keptGoodWeeks = 16
        /// Written at most this often after a meal, and this often while running.
        public static let afterMealAtMost: TimeInterval = 60
        public static let every: TimeInterval = 10 * 60
        /// The file stays under this size.
        public static let maximumBytes = 8 * 1024
    }

    /// Moments. Nothing random, nothing lost.
    public enum Moments {
        /// A 5-hour period that closes and frees this many points of the left readout (its high-water
        /// mark times the account's share) is a fresh window, at most once per `freshWindowEvery`.
        public static let freshWindowFreed: Double = 20
        public static let freshWindowEvery: TimeInterval = 30 * 60
        /// A local day with this many food points eaten is a fed day. A streak survives `restDays`
        /// unfed days in a row; the next one ends it, silently.
        public static let fedDay: Double = 10
        public static let restDays = 2
        public static let milestones = [3, 7, 14, 30, 60, 100]
        /// An account's weekly period that closes with its high-water mark at this or more is a good
        /// week.
        public static let goodWeek: Double = 70
        /// The panel's good-week line stays this long, and there is at most one good-week celebration
        /// per `celebrationEvery`.
        public static let goodWeekLine: TimeInterval = 86_400
        public static let celebrationEvery: TimeInterval = 86_400
    }

    // MARK: - The state machine

    /// How long each behaviour plays when nothing cuts it. `PetBehaviour.duration` reads these; the
    /// meal's own timing is `Meal`'s.
    public enum Behaviour {
        /// Peeks out, looks around, notices the readout, steps out and sits; with no accounts it
        /// peeks, looks at the `—` and goes back in.
        public static let intro: TimeInterval = 3.6
        public static let introNoAccounts: TimeInterval = 2.2
        /// After a prompt, and the longer one at the readout when fresh numbers end `unsureIdle`.
        public static let perk: TimeInterval = 0.5
        public static let freshDataPerk: TimeInterval = 0.8
        public static let celebrateStreak: TimeInterval = 2.4
        public static let celebrateGoodWeek: TimeInterval = 2.8
        public static let freshWindow: TimeInterval = 1.0
        public static let fallAsleepYawn: TimeInterval = 1.0
        public static let fallAsleepDroop: TimeInterval = 0.8
        public static let fallAsleepCurl: TimeInterval = 0.8
        public static let fallAsleep = fallAsleepYawn + fallAsleepDroop + fallAsleepCurl
        public static let wakeStir: TimeInterval = 0.6
        public static let wakeStretch: TimeInterval = 1.6
        public static let wakeShake: TimeInterval = 0.5
        public static let wake = wakeStir + wakeStretch + wakeShake
        public static let rollOver: TimeInterval = 1.0
        /// Into the den at the weekly limit. With no visible account it plays only the second half,
        /// a retreat.
        public static let enterDen: TimeInterval = 3.2
        public static let retreat = enterDen / 2
        public static let leaveDenPeek: TimeInterval = 0.8
        public static let leaveDenOut: TimeInterval = 0.8
        public static let leaveDenStretch: TimeInterval = 1.6
        public static let leaveDenShake: TimeInterval = 0.5
        public static let leaveDen = leaveDenPeek + leaveDenOut + leaveDenStretch + leaveDenShake
        /// Out of the den without the stretch and the shake: an account became visible again.
        public static let leaveDenShort = leaveDenPeek + leaveDenOut
        /// One look out of the den during `denWait`.
        public static let peek: TimeInterval = 2.2
        public static let dozeIn: TimeInterval = 2.0
        public static let welcomeBack: TimeInterval = 1.8
        /// `showPet` turned off fades the pet out over this; turned on, it fades in over `fadeIn`.
        public static let fadeOut: TimeInterval = 0.2
        public static let fadeIn: TimeInterval = 0.3
        /// The pointer noticed: eyes widen, the head turns.
        public static let notice: TimeInterval = 0.25
    }

    /// The greeting when the panel opens at an end of the meter: a thumbs-up stuffed, please famished.
    public enum Greet {
        /// After the panel opens: the hop into the header has landed.
        public static let after: TimeInterval = 0.6
        /// At most one greeting this often, however often the panel opens.
        public static let every: TimeInterval = 180
        /// A greeting waits at most this long for a gesture already playing to end, or is let go.
        public static let wait: TimeInterval = 1.5
    }

    /// Boops, in the panel only.
    public enum Boop {
        public static let boop: TimeInterval = 0.6
        /// No new boop until this long after the last one.
        public static let spacing: TimeInterval = 0.8
        /// This many boops within `giggleWindow` play a giggle, and boops are then ignored for
        /// `giggleQuiet`.
        public static let giggleCount = 5
        public static let giggleWindow: TimeInterval = 6
        public static let giggle: TimeInterval = 1.2
        public static let giggleQuiet: TimeInterval = 10
        /// Booped asleep, it opens one eye and closes it; hibernating, its glow pulses once.
        public static let sleepyEye: TimeInterval = 0.9
        public static let glowPulse: TimeInterval = 0.6
        /// A click within this of the body's box is a boop.
        public static let hitSlop: Double = 4
    }

    // MARK: - Where it lives

    /// The readouts the pet must not cover. Widths in `EarsMetrics.readoutFont` (tabular digits, so
    /// every reading of a class is one width), as SwiftUI lays them out at 8x: to the eighth of a point.
    /// On a 2x screen each text's frame rounds up to the half point (`100%` takes 35.5), which moves a
    /// readout that hugs its right edge, as the pill's right one does, up to 0.375 pt to the left.
    public enum Readout {
        /// `—`, `0%`, `41%` and `100%`.
        public static let dashWidth: Double = 12.625
        public static let oneDigitWidth: Double = 18.875
        public static let twoDigitWidth: Double = 27.0
        public static let threeDigitWidth: Double = 35.125
        /// The model initial `F` in `EarsMetrics.initialFont`; `EarsMetrics.initialSpacing` follows it.
        public static let initialWidth: Double = 6.125
        /// The pet's zone keeps this much black between it and the readout.
        public static let gap: Double = 4
    }

    /// The strip's zones. Offsets are from the notch (`frames.notch`) and from the bottom of the room
    /// the pet stands in, so they hold on any notched Mac.
    public enum Zone {
        /// The body's rest envelope at scale 1, centred on the anchor and standing on it. The drawing
        /// may change the silhouette, not this.
        public static let restWidth: Double = 24
        public static let restHeight: Double = 22
        /// Extremes every pose is clamped to: squash keeps the area (`sx = 1 / sy`), so the width
        /// reaches `maxWidth` × rest at the deepest squash.
        public static let minimumSquash: Double = 0.80
        public static let maxWidth: Double = 1.25
        public static let maxLeanDegrees: Double = 14
        /// Every zone stops this far from its room's top and bottom edges (y 1 to 31 beside).
        public static let edgeInset: Double = 1
        /// Beside: the anchor sits `besideAnchorFromNotch` left of the notch, the feet
        /// `besideFeetAboveBottom` above the strip's bottom; scale 1.
        public static let besideAnchorFromNotch: Double = 20
        public static let besideFeetAboveBottom: Double = 3.5
        public static let besideScale: Double = 1.0
        public static let besideMaxStretch: Double = 1.20
        /// Below: the zone starts `belowLeftFromNotch` right of the notch's left edge, clear of the
        /// strip's bottom-left corner at the feet; the anchor sits `belowAnchorFromNotch` right of
        /// that edge, the feet `belowFeetAboveBottom` above the strip's bottom. The one layout where
        /// the pet is under 18 pt tall, because the strip is 22 pt tall; stretch is held lower so the
        /// head stays under the notch.
        public static let belowLeftFromNotch: Double = 5
        public static let belowAnchorFromNotch: Double = 20.5
        public static let belowFeetAboveBottom: Double = 2.5
        public static let belowScale: Double = 0.80
        public static let belowMaxStretch: Double = 1.10
        /// The pill: the anchor at its centre, the feet `pillFeetAboveBottom` above its bottom.
        public static let pillFeetAboveBottom: Double = 3
        public static let pillScale: Double = 0.82
        public static let pillMaxStretch: Double = 1.15
        /// Asleep in the open, lying at the anchor, the pet is at most this tall; its Zzz rise toward
        /// `zzzCeiling` below the screen's top edge.
        public static let asleepMaxHeight: Double = 14
        public static let zzzCeiling: Double = 2
    }

    /// The panel header: the first row of `PanelView` while the pet is on.
    public enum Panel {
        /// The row: the stage, the words, the meter.
        public static let rowHeight: Double = 52
        public static let rowSpacing: Double = 12
        /// `NotchPanelController.estimatedExpandedHeight` grows by the row plus one stack spacing.
        public static let addedHeight: Double = rowHeight + 10
        /// The stage the pet layer draws in, at the panel's leading padding.
        public static let stageWidth: Double = 64
        public static let stageHeight: Double = 52
        /// The anchor in the stage: (46, top + 48) on the 14", scale 2.
        public static let anchorFromStageLeft: Double = 32
        public static let anchorFromStageTop: Double = 48
        public static let scale: Double = 2.0
        /// Particles may rise into the black above the stage up to this far below the window's top
        /// edge (y 6 to 40 is clear of the notch, which starts at x 143.5).
        public static let particleCeiling: Double = 6
        /// The words: state word 13 pt semibold, detail and moment line 10 pt, 2 pt apart. The spacer
        /// before the meter may close up: the row's spacing on both sides of it still keeps the words
        /// 24 pt from the meter, and the words need the room on a panel with no notch, where the widest
        /// detail, `Weekly limit used up · wakes 30 May 04:44`, takes 209 of their 212 pt.
        public static let wordSize: Double = 13
        public static let detailSize: Double = 10
        public static let textSpacing: Double = 2
        public static let spacerMinimum: Double = 0
        /// The meter: a 120 × 6 pt capsule under its 10 pt "Hunger" label, 4 pt apart. The track is
        /// white at 12 %, the fill the pet's accent at 85 % (never the severity colours), the ticks at
        /// 35 and 65 white at 30 %, 1 pt wide. A change animates over 0.6 s; no number is shown.
        public static let meterWidth: Double = 120
        public static let meterHeight: Double = 6
        public static let meterSpacing: Double = 4
        public static let meterTrackOpacity: Double = 0.12
        public static let meterFillOpacity: Double = 0.85
        public static let meterTicks: [Double] = [35, 65]
        public static let tickWidth: Double = 1
        public static let tickOpacity: Double = 0.30
        public static let meterAnimation: TimeInterval = 0.6
    }

    /// The words' thresholds (`PetText`).
    public enum Words {
        /// A meal within this long reads `Ate 3 % · 2 min ago`; later, `Last meal 3 h ago`.
        public static let recentMeal: TimeInterval = 10 * 60
        /// A meal below this many points reads `<1 %`.
        public static let lessThanOne: Double = 0.5
        /// At or below this pace factor f, the detail adds `· well fed this week`.
        public static let wellFedPace: Double = 0.5
    }

    /// The hop between the strip and the panel. The flight takes
    /// T = clamp(`flightBase` + `flightPerPoint` · distance, `flightMinimum`, `flightMaximum`).
    public enum Hop {
        /// Expand: a crouch, a takeoff stretch, a ballistic flight, a landing squash, a spring.
        public static let crouch: TimeInterval = 0.08
        public static let crouchSquash: Double = 0.88
        public static let takeoffStretch: Double = 1.06
        public static let flightBase: TimeInterval = 0.22
        public static let flightPerPoint: TimeInterval = 0.0006
        public static let flightMinimum: TimeInterval = 0.26
        public static let flightMaximum: TimeInterval = 0.40
        /// Beside, the expand's apex is this far above the strip anchor. Below and on the pill, which
        /// start at the top of their room, it steps off with no upward speed.
        public static let expandApexBeside: Double = 3
        /// Speed stretch along the velocity:
        /// 1 + min(`speedStretchMaximum`, speed / `speedStretchSpeed`), speed in pt/s.
        public static let speedStretchMaximum: Double = 0.12
        public static let speedStretchSpeed: Double = 2500
        public static let landingSquash: Double = 0.86
        public static let landing: TimeInterval = 0.08
        public static let settleOmega: Double = 28
        public static let settleZeta: Double = 0.45
        /// In flight the head, at that instant's scale and stretch, never goes above this line (the
        /// screen's top edge) nor into the notch.
        public static let topClearance: Double = 0.5
        /// Collapse: x eases out over `collapseX`, y flies over `collapseY` to an apex 2 pt above the
        /// strip anchor beside and 1 pt below and on the pill, then a shorter landing squash.
        public static let collapseX: TimeInterval = 0.16
        public static let collapseY: TimeInterval = 0.22
        public static let collapseApexBeside: Double = 2
        public static let collapseApexOther: Double = 1
        public static let collapseLanding: TimeInterval = 0.06
        /// Asleep, drowsy or hibernating there is no hop: a glide along the straight line, eased in and
        /// out.
        public static let glide: TimeInterval = 0.34
        /// The hop overlay lasts 0.26 to 0.80 s.
        public static let overlayMinimum: TimeInterval = 0.26
        public static let overlayMaximum: TimeInterval = 0.80
        /// Reduce Motion: the strip pet fades out while the header pet fades in, overlapping a little.
        public static let reducedFadeOut: TimeInterval = 0.15
        public static let reducedFadeIn: TimeInterval = 0.15
        public static let reducedOverlap: TimeInterval = 0.05
        /// A layout change (the Ears picker, another display): out at the old anchor, in at the new.
        public static let relayoutFadeOut: TimeInterval = 0.15
        public static let relayoutFadeIn: TimeInterval = 0.20
        /// Readouts hidden, the pet appears only in the panel, fading in with it.
        public static let panelOnlyFade: TimeInterval = 0.2
        /// Brow's outline springs (`NotchPanelController.openAnimation` and `closeAnimation`), which
        /// the hop is timed against. Mirrored, because an `Animation` cannot be read back.
        public static let openResponse: Double = 0.32
        public static let openDamping: Double = 0.86
        public static let closeResponse: Double = 0.26
        public static let closeDamping: Double = 1.0
    }

    /// The pet's own canvas, which moves with it; its size follows the scale during the hop.
    public enum Canvas {
        public static let width: Double = 64
        public static let height: Double = 44
        public static let panelWidth: Double = 128
        public static let panelHeight: Double = 112
    }

    // MARK: - The animation runtime

    /// Idle life: layered cycles of periods that never line up, with phases from the seed.
    public enum Idle {
        /// Breathing scales y by ±1.5 %; sway leans ±1.2°; weight shift moves ±0.4 pt.
        public static let breathPeriod: TimeInterval = 3.7
        public static let breathAmplitude: Double = 0.015
        public static let swayPeriod: TimeInterval = 7.3
        public static let swayDegrees: Double = 1.2
        public static let shiftPeriod: TimeInterval = 11.9
        public static let shiftAmplitude: Double = 0.4
        public static let appendagePeriod: TimeInterval = 5.3
        /// Blinks come at intervals of `blinkBase` + `blinkSpread` · hash, a pet's rate set ±15 % by
        /// its seed. Each takes 0.14 s (close 0.05, hold 0.02, open 0.07); 12 % are double.
        public static let blinkBase: TimeInterval = 2.4
        public static let blinkSpread: TimeInterval = 4.1
        public static let blinkRateSpread: Double = 0.15
        public static let blinkClose: TimeInterval = 0.05
        public static let blinkHold: TimeInterval = 0.02
        public static let blinkOpen: TimeInterval = 0.07
        public static let blink = blinkClose + blinkHold + blinkOpen
        public static let doubleBlinkShare: Double = 0.12
        /// Glances at intervals of `glanceBase` + `glanceSpread` · hash, to the food source, the den,
        /// the viewer or down; the eyes lead the head by `eyeLead`.
        public static let glanceBase: TimeInterval = 4
        public static let glanceSpread: TimeInterval = 7
        public static let eyeLead: TimeInterval = 0.06
        /// A rare idle (scratch, small yawn, look around, a dust mote) at intervals of `rareBase` +
        /// `rareSpread` · hash; peckish and hungry add a tummy rumble every 40 to 70 s.
        public static let rareBase: TimeInterval = 45
        public static let rareSpread: TimeInterval = 75
        public static let rumbleMinimum: TimeInterval = 40
        public static let rumbleMaximum: TimeInterval = 70
        /// Moods shift posture and rates: Full breathes slower and rounder; Hungry leans forward,
        /// lower, with bigger eyes and three times the glances at the food source; Eager stands taller.
        public static let fullBreathPeriod: TimeInterval = 4.2
        public static let hungryLeanDegrees: Double = 3
        public static let hungryGlances: Double = 3
        public static let eagerHeight: Double = 1.04
        /// Moves ease in and out (cubic); pops ease out with this overshoot ("back"). No linear tweens.
        public static let popOvershoot: Double = 1.2
    }

    /// Secondary motion. Idle-driven responses are the springs' steady state in closed form; each
    /// action adds a transient integrated at `step` from its start until `tail` after its end.
    public enum Secondary {
        /// Appendages: Glim's brows and arms.
        public static let appendageOmega: Double = 22
        public static let appendageZeta: Double = 0.32
        public static let bellyOmega: Double = 30
        public static let bellyZeta: Double = 0.4
        public static let step: TimeInterval = 1.0 / 240
        public static let tail: TimeInterval = 2
    }

    /// Particles, each spawned on the timeline with hashed parameters.
    public enum Particles {
        public static let maximumAlive = 12
        /// Asleep, a Zzz (drawn strokes, not text) every 1.8 s, rising 10 pt over 2.6 s with ±2 pt of
        /// drift, three alive at most.
        public static let zzzEvery: TimeInterval = 1.8
        public static let zzzRise: Double = 10
        public static let zzzLife: TimeInterval = 2.6
        public static let zzzDrift: Double = 2
        public static let zzzAlive = 3
        /// Celebrations: 4 to 6 four-point stars, 1.5 to 3 pt, each twinkling 0.6 s.
        public static let sparklesMinimum = 4
        public static let sparklesMaximum = 6
        public static let sparkleSizeMinimum: Double = 1.5
        public static let sparkleSizeMaximum: Double = 3
        public static let sparkleTwinkle: TimeInterval = 0.6
    }

    /// Light, made of gradients only so that a frame stays cheap: no `.blur`, no `.shadow`, no
    /// offscreen pass per frame.
    public enum Light {
        /// The rim: a 0.75 pt stroke at scale 1, warm white at 35 %.
        public static let rimWidth: Double = 0.75
        public static let rimOpacity: Double = 0.35
        /// The glow: a radial gradient of this radius, the accent at 10 to 16 %, times the mood's
        /// factor. Where it reaches the readout it is under `glowAtReadout`.
        public static let glowRadius: Double = 18
        public static let glowMinimum: Double = 0.10
        public static let glowMaximum: Double = 0.16
        public static let glowEager: Double = 1.2
        public static let glowAsleep: Double = 0.6
        public static let glowHibernating: Double = 0.3
        public static let glowAtReadout: Double = 0.03
        /// A tint of the food source's dot colour on the near rim.
        public static let dotTint: Double = 0.03
        /// Increase Contrast: the rim at 60 %, and a 0.5 pt outline at 40 %. Reduce Transparency
        /// drops the glow and keeps the rim.
        public static let contrastRimOpacity: Double = 0.60
        public static let contrastOutlineWidth: Double = 0.5
        public static let contrastOutlineOpacity: Double = 0.40
    }

    /// What each frame class may move per frame at its own rate. Anything faster (the snap, the hop,
    /// the shake) runs in the fast class; blinks are exempt (classic blinks on twos).
    public enum Speed {
        /// Ambient motion: at most 0.5 pt per frame, so idle layers stay under 15 pt/s at 30 fps.
        public static let ambientPerFrame: Double = 0.5
        /// Actions: at most 1 pt per frame at 60 fps.
        public static let actionPerFrame: Double = 1.0
    }

    /// Frame rates per class, and the caps applied in order.
    public enum Frames {
        public static let still: Double = 10
        public static let sleep: Double = 15
        public static let idle: Double = 30
        public static let action: Double = 60
        /// The pointer moved within `Pointer.notice` this recently: at least the action rate.
        public static let pointerRecent: TimeInterval = 0.5
        /// On battery, `fast` is held to this.
        public static let batteryFast: Double = 60
        /// Low Power Mode: idle 15, sleep 10, action and fast 30.
        public static let lowPowerIdle: Double = 15
        public static let lowPowerSleep: Double = 10
        public static let lowPowerAction: Double = 30
        /// Reduce Motion: idle 10 (breathing only), action and fast 30.
        public static let reducedIdle: Double = 10
        public static let reducedAction: Double = 30
        /// Input idle 120 to 600 s: at most this.
        public static let settledAtMost: Double = 10
    }

    /// Reduce Motion.
    public enum Reduced {
        /// No squash or stretch beyond this.
        public static let squash: Double = 0.02
        /// A meal is a crossfade to a chewing pose over `mealFade`, one chew per point up to three at
        /// `chew` each, and a crossfade back.
        public static let mealFade: TimeInterval = 0.15
        public static let chew: TimeInterval = 0.4
        /// Idle is breathing at this share of its amplitude, and blinks.
        public static let breath: Double = 0.5
    }

    /// The CPU budget on the reference Mac (release build, AC power), and how it is measured.
    public enum Budget {
        /// `PetRig.pose`: mean and p99.
        public static let poseMean: TimeInterval = 0.05e-3
        public static let poseP99: TimeInterval = 0.15e-3
        /// Main thread per frame (TimelineView body and Canvas recording): mean and p99.
        public static let frameMean: TimeInterval = 0.40e-3
        public static let frameP99: TimeInterval = 1.0e-3
        /// Process CPU over 60 s, pet on minus pet off, in percent of one core.
        public static let idleCPU: Double = 1.5
        public static let asleepCPU: Double = 1.0
        public static let hibernatingCPU: Double = 0.5
        public static let pausedCPU: Double = 0.05
        /// Share of a working day at 60 fps or more.
        public static let fastShare: Double = 0.05
        /// `testPoseEvaluationCost`: this many poses over a scripted timeline this long that visits
        /// every behaviour; `testCanvasCost`: this many strip-size frames at `renderScale`.
        public static let poseSamples = 100_000
        public static let scriptLength: TimeInterval = 10 * 60
        public static let canvasFrames = 600
        public static let renderScale: Double = 2
        /// `-petPerfLog` writes one line this often.
        public static let logEvery: TimeInterval = 60
    }
}

extension PetTuning.Behaviour {
    /// A streak milestone's second hop is a twirl, the face going round the back: from just before its
    /// crouch to just after its landing it moves far beyond an action's 1 pt a frame, so this part of
    /// `celebrate(.streak)` is in the fast class. Times into the celebration.
    public static let streakTwirl: Range<TimeInterval> = 0.98..<1.6
}
