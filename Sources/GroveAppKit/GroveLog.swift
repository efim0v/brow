import os

/// Central os.Logger handles for Workspaces, under Brow's one subsystem. Stream with:
///   log stream --predicate 'subsystem == "dev.artemefimov.brow" AND category IN {"workspaces", "perf"}'
/// or open Console.app and filter on the subsystem.
public enum GroveLog {
    public static let workspaces = Logger(subsystem: "dev.artemefimov.brow", category: "workspaces")
    /// Open/scan/usage timings (item 2 perf work).
    public static let perf = Logger(subsystem: "dev.artemefimov.brow", category: "perf")
}
