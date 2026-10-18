// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import os

/// Central os.Logger handles for Brow. Stream with:
///   log stream --predicate 'subsystem == "dev.artemefimov.brow"'
public enum BrowLog {
    public static let limits = Logger(subsystem: "dev.artemefimov.brow", category: "limits")
    public static let tokens = Logger(subsystem: "dev.artemefimov.brow", category: "tokens")
    public static let panel  = Logger(subsystem: "dev.artemefimov.brow", category: "panel")
    public static let notify = Logger(subsystem: "dev.artemefimov.brow", category: "notify")
    /// Hosting Workspaces: activation, the Grove-running guard. The engine itself logs
    /// under the same subsystem (GroveLog).
    public static let workspaces = Logger(subsystem: "dev.artemefimov.brow", category: "workspaces")
    /// The pet: an unreadable `pet.json`, a clock that jumped, and the `-petPerfLog` lines once a
    /// minute.
    public static let pet    = Logger(subsystem: "dev.artemefimov.brow", category: "pet")
}

/// "Say this once per process." For conditions that are real failures but are
/// re-evaluated on every render — logging them at that rate buries the signal.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// True exactly once, for the first caller.
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
