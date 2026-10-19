// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// After every close of the open panel — Esc, a click outside, Settings, a hand-off to a
/// session — the notch stays shut until the pointer has left, once, the area the expanded
/// panel covers.
///
/// The pointer is usually still resting where the panel was: without the latch it would
/// open the panel again the moment it closed, over the terminal it just handed the user
/// to, or the Settings window it just opened.
struct NotchHoverLatch: Equatable {
    private(set) var isEngaged = false

    mutating func engage() { isEngaged = true }

    /// Whether the notch may react to the pointer now. Engaged, it may not while the
    /// pointer is inside `expandedArea`; the first position outside releases it.
    mutating func allowsHover(pointerInExpandedArea inside: Bool) -> Bool {
        guard isEngaged else { return true }
        if inside { return false }
        isEngaged = false
        return true
    }
}
