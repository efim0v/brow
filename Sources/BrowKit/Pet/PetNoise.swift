// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// Where all of the pet's variety comes from. Neither the brain nor the rig calls `random()`: every
/// phase, quirk and choice is `hash(seed, channel, index)`, so the same pet does the same thing at the
/// same moment on every run and in every render, and two pets (two seeds) differ.
///
/// The arithmetic is integer only, and the fraction is the top 53 bits of the result, which a
/// `Double` holds exactly: the numbers are the same on every Mac, and a pet keeps its quirks across
/// launches and updates as long as this function does not change.
public enum PetNoise {
    /// One stream of numbers. Each use draws from a channel of its own, so a new use never shifts what
    /// an existing one gets. The brain numbers its channels from 0x100, the rig from 0x200 and the
    /// controller and views that host them from 0x300, each as a `static let` in its own files.
    public struct Channel: Sendable, Hashable {
        public let raw: UInt64
        public init(_ raw: UInt64) { self.raw = raw }
    }

    /// A uniform number in [0, 1) for (seed, channel, index): SplitMix64 applied to each in turn.
    public static func hash(_ seed: UInt64, _ channel: Channel, _ index: Int) -> Double {
        let mixed = splitMix64(splitMix64(splitMix64(seed) ^ channel.raw) ^ UInt64(bitPattern: Int64(index)))
        return Double(mixed >> 11) * 0x1p-53
    }

    /// One SplitMix64 output for the state `x`: the golden-ratio step, then the finaliser. A
    /// bijection, so different inputs never collide, and one changed input bit changes about half
    /// of the output's.
    static func splitMix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
