// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// After the notch panel's Workspaces button: the notch stays shut until the pointer
/// has left, once, the area the expanded panel covers.
///
/// The Workspaces panel opens under the menu bar, right where the expanded notch hangs,
/// and the notch's window sits in a layer above it. Without the latch the pointer, still
/// resting where the button was, would open the notch again on top of the panel it had
/// just asked for.
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
