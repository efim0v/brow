import Foundation
import os

/// Central os.Logger handles for Brow. Stream with:
///   log stream --predicate 'subsystem == "dev.artemefimov.brow"'
public enum BrowLog {
    public static let limits = Logger(subsystem: "dev.artemefimov.brow", category: "limits")
    public static let tokens = Logger(subsystem: "dev.artemefimov.brow", category: "tokens")
    public static let panel  = Logger(subsystem: "dev.artemefimov.brow", category: "panel")
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
