// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// How often the pet layer's `TimelineView` draws.
public enum PetFrameRate: Sendable, Equatable {
    /// No frames at all.
    case paused
    /// At most this many frames a second. 30, 15 and 10 divide 60 and 120 Hz evenly, so
    /// `.animation(minimumInterval:)` keeps them on the display link without judder.
    case fps(Double)
    /// The display's own rate (120 Hz on ProMotion): `minimumInterval: nil`.
    case native

    /// For `TimelineView(.animation(minimumInterval: minimumInterval, paused: paused))`.
    public var minimumInterval: TimeInterval? {
        if case .fps(let fps) = self { return 1 / fps }
        return nil
    }

    public var paused: Bool { self == .paused }
}

/// What can stop the frames altogether: with any one of them closed, nobody can see the pet and the
/// layer is paused.
public struct PetFrameGates: Sendable, Equatable {
    public var petOn = true
    /// Between `screensDidSleepNotification` and `screensDidWakeNotification`, false.
    public var displayAwake = true
    /// `com.apple.screenIsLocked` on `DistributedNotificationCenter`.
    public var unlocked = true
    /// Fast user switching: `sessionDidResignActiveNotification`.
    public var sessionActive = true
    /// From `willSleepNotification` until `didWakeNotification`, false.
    public var systemAwake = true
    /// The panel window's `occlusionState` contains `.visible`.
    public var windowVisible = true
    /// Something shows the pet: the readouts are on, or the panel is open. Collapsed with the readouts
    /// off there is nothing to draw.
    public var showsPet = true
    /// Input in the last 600 s: away is no frames, whatever the pet is doing.
    public var present = true

    public init() {}

    var open: Bool {
        petOn && displayAwake && unlocked && sessionActive && systemAwake && windowVisible && showsPet && present
    }
}

/// The rest of what sets the rate: the power source, the display options and the person.
public struct PetFrameConditions: Sendable, Equatable {
    /// `IOPSGetProvidingPowerSourceType` says AC power.
    public var onAC = true
    /// `ProcessInfo.isLowPowerModeEnabled`.
    public var lowPower = false
    public var reduceMotion = false
    /// Seconds since the last input.
    public var inputIdle: TimeInterval = 0
    /// The pointer moved within 160 pt of the pet's eyes in the last 0.5 s
    /// (`PetFramePolicy.pointerIsNear`): the eyes are tracking it.
    public var pointerNear = false

    public init() {}
}

/// Frame classes to rates, the caps and the gates. Pure: the rate changes only at behaviour boundaries
/// (`nextChange`) and when a gate or a condition changes, a few times a minute.
public enum PetFramePolicy {

    /// The rate for the behaviour playing at `t`.
    public static func rate(_ timeline: PetTimeline, at t: TimeInterval, gates: PetFrameGates,
                            conditions: PetFrameConditions) -> PetFrameRate {
        let segment = timeline.segments.last { $0.start <= t }
        let frameClass = segment.map { $0.behaviour.frameClass(elapsed: t - $0.start) } ?? .off
        let eyesFollow = segment.map { followsThePointer($0.behaviour) } ?? false
        return rate(for: frameClass, gates: gates, conditions: conditions, eyesFollow: eyesFollow)
    }

    /// The rate for a frame class. `eyesFollow`: the behaviour watches the pointer when it moves near,
    /// which needs the action rate; asleep, in the den or dozing it does not.
    public static func rate(for frameClass: PetFrameClass, gates: PetFrameGates, conditions: PetFrameConditions,
                            eyesFollow: Bool = true) -> PetFrameRate {
        guard gates.open, frameClass != .off else { return .paused }
        typealias F = PetTuning.Frames
        var effective = frameClass
        if conditions.pointerNear, eyesFollow, effective < .action { effective = .action }
        // nil is the display's own rate.
        var fps: Double?
        switch effective {
        case .off: return .paused
        case .still: fps = F.still
        case .sleep: fps = F.sleep
        case .idle: fps = F.idle
        case .action: fps = F.action
        case .fast: fps = nil
        }
        func cap(_ limit: Double) { fps = min(fps ?? .infinity, limit) }
        // The caps: each only ever lowers the rate, so the order they come in changes nothing.
        if !conditions.onAC, effective == .fast { cap(F.batteryFast) }
        if conditions.lowPower {
            switch effective {
            case .idle: cap(F.lowPowerIdle)
            case .sleep: cap(F.lowPowerSleep)
            case .action, .fast: cap(F.lowPowerAction)
            default: break
            }
        }
        if conditions.reduceMotion {
            switch effective {
            case .idle: cap(F.reducedIdle)
            case .action, .fast: cap(F.reducedAction)
            default: break
            }
        }
        if conditions.inputIdle >= PetTuning.Presence.settled && conditions.inputIdle < PetTuning.Presence.away {
            cap(F.settledAtMost)
        }
        return fps.map { .fps($0) } ?? .native
    }

    /// The next instant after `t` at which the frame class changes without an event: the next
    /// segment's start, or a change inside the one playing (the wake's shake, a streak's twirl, the end
    /// of the fade out). The controller reads the rate again then.
    public static func nextChange(_ timeline: PetTimeline, after t: TimeInterval) -> TimeInterval? {
        typealias B = PetTuning.Behaviour
        var times = timeline.segments.first(where: { $0.start > t }).map { [$0.start] } ?? []
        if let segment = timeline.segments.last(where: { $0.start <= t }) {
            switch segment.behaviour {
            case .wake: times.append(segment.start + B.wakeStir + B.wakeStretch)
            case .celebrate(.streak): times += [segment.start + B.streakTwirl.lowerBound, segment.start + B.streakTwirl.upperBound]
            case .off: times.append(segment.start + B.fadeOut)
            default: break
            }
        }
        return times.filter { $0 > t }.min()
    }

    /// Whether the pointer moved within `PetTuning.Pointer.notice` of `eyes` in the last
    /// `PetTuning.Frames.pointerRecent`: every sample is a move.
    public static func pointerIsNear(_ track: PetPointerTrack, eyes: CGPoint, at t: TimeInterval) -> Bool {
        track.samples.contains { sample in
            t - sample.t <= PetTuning.Frames.pointerRecent && t >= sample.t
                && hypot(Double(sample.location.x - eyes.x), Double(sample.location.y - eyes.y)) <= PetTuning.Pointer.notice
        }
    }

    /// Behaviours whose eyes are the pointer's when it comes near. Asleep, in the den, yawning or
    /// dozing they are not, and the pointer is no reason for more frames.
    static func followsThePointer(_ behaviour: PetBehaviour) -> Bool {
        switch behaviour {
        case .fallAsleep, .asleep, .drowsy, .rollOver, .enterDen, .hibernating, .stirring, .denWait, .peek, .dozeIn, .doze,
             .off:
            return false
        default:
            return true
        }
    }
}
