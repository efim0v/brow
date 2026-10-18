// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// How a readout is laid out in its ear, in one place. The pet's zones (`PetLayout`) are worked out from
/// the same numbers, so the free black the pet lives in cannot drift from what the strip draws. The text
/// widths each class takes in these fonts are `PetTuning.Readout`'s.
public enum EarsMetrics {
    /// Between an ear's outer edge and its dot, in the left ear, or its text, in the right one.
    public static let padding: CGFloat = 8
    /// The status dot's diameter.
    public static let dotSize: CGFloat = 7
    /// Between the dot and the text.
    public static let dotSpacing: CGFloat = 5
    /// Between the model initial (the right ear's `F`) and its percentage.
    public static let initialSpacing: CGFloat = 3
    /// The percentage: 12 pt semibold rounded with tabular digits, so every reading of a width class
    /// is the same width.
    public static var readoutFont: Font { .system(size: 12, weight: .semibold, design: .rounded).monospacedDigit() }
    /// The model initial.
    public static var initialFont: Font { .system(size: 10, weight: .bold, design: .rounded) }
}
