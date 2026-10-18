// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The hunger meter's number, H. It rises while the hunger clock runs, at 20 points an hour slowed by
/// the week's pace, and falls by 6 a point of food. Its range is −50 to 100, so a big meal is
/// remembered for a while (2 h 30 min from the floor back to 0); the meter shows it clamped to 0...100.
///
/// Whether the clock runs (the pet on, someone at the Mac, awake, fresh numbers) is the brain's
/// call; this only does the arithmetic, so the tests can drive it directly.
public struct PetHunger: Sendable, Equatable {
    public var value: Double

    public init(value: Double = PetTuning.Hunger.newPet) {
        self.value = min(max(value, PetTuning.Hunger.minimum), PetTuning.Hunger.maximum)
    }

    /// Points per second while the clock runs at pace `f`.
    public static func rate(pace f: Double) -> Double {
        PetTuning.Hunger.perHour * min(max(f, 0), 1) / 3600
    }

    /// `seconds` of hunger time at pace `f`. Nothing happens at 100 but staying Hungry.
    public mutating func pass(_ seconds: TimeInterval, pace f: Double) {
        guard seconds > 0 else { return }
        value = min(PetTuning.Hunger.maximum, value + Self.rate(pace: f) * seconds)
    }

    /// `points` of food, at once: the meter waits for the swallow, H does not. Returns how far H fell,
    /// after the floor: the part the meter holds back as `pendingDrop` until the pet is seen eating it.
    @discardableResult
    public mutating func eat(_ points: Double) -> Double {
        let before = value
        value = max(PetTuning.Hunger.minimum, value - PetTuning.Hunger.perPoint * max(points, 0))
        return before - value
    }

    /// The mood of a meter value (H + pendingDrop, before the clamp), coming from `previous`. A mood is
    /// entered at its threshold on the way up and left 5 points below it on the way down, so a pet
    /// on the line does not flicker between two faces.
    public static func mood(_ value: Double, from previous: PetMood?) -> PetMood {
        guard var mood = previous else { return moodOnTheWayUp(value) }
        typealias H = PetTuning.Hunger
        // A big meal can drop it several moods at once, a debug value raise it several: step until
        // the mood holds.
        for _ in 0..<PetMood.allCases.count {
            let next: PetMood
            switch mood {
            case .full:
                next = value > H.contentAbove ? .content : .full
            case .content:
                next = value >= H.peckishFrom ? .peckish
                    : value <= H.contentAbove - H.moodHysteresis ? .full : .content
            case .peckish:
                next = value >= H.hungryFrom ? .hungry
                    : value < H.peckishFrom - H.moodHysteresis ? .content : .peckish
            case .hungry:
                next = value < H.hungryFrom - H.moodHysteresis ? .peckish : .hungry
            }
            if next == mood { break }
            mood = next
        }
        return mood
    }

    /// The mood a value gives with no history: a new pet's, or one restored from `pet.json`.
    public static func moodOnTheWayUp(_ value: Double) -> PetMood {
        typealias H = PetTuning.Hunger
        if value >= H.hungryFrom { return .hungry }
        if value >= H.peckishFrom { return .peckish }
        if value > H.contentAbove { return .content }
        return .full
    }

    /// The next value above `value` at which the mood changes on the way up; nil when Hungry, which
    /// has nowhere higher to go.
    public static func nextThreshold(above value: Double, mood: PetMood) -> Double? {
        typealias H = PetTuning.Hunger
        switch mood {
        case .full: return max(value, H.contentAbove)
        case .content: return max(value, H.peckishFrom)
        case .peckish: return max(value, H.hungryFrom)
        case .hungry: return nil
        }
    }
}
