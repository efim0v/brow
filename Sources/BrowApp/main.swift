import BrowKit

// main.swift (not @main) to match GroveApp: top-level code runs on the main
// thread, and assumeIsolated bridges into the @MainActor entry point.
MainActor.assumeIsolated { BrowApp.run() }
