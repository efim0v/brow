import os

/// Central os.Logger handles for Brow. Stream with:
///   log stream --predicate 'subsystem == "dev.artemefimov.brow"'
public enum BrowLog {
    public static let limits = Logger(subsystem: "dev.artemefimov.brow", category: "limits")
    public static let tokens = Logger(subsystem: "dev.artemefimov.brow", category: "tokens")
    public static let panel  = Logger(subsystem: "dev.artemefimov.brow", category: "panel")
}
