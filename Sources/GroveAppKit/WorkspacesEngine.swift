// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import GroveCore

/// Workspaces' engine for whichever app hosts it: the launch work and the background
/// cadence. It draws nothing: the host shows the screens (Brow, in its notch panel).
///
/// `startEngine()` does the launch work — adopting signed-in folders, the status-line
/// reconcile, the first capture read, the 90 s background cadence and the offscreen
/// pre-render; `stopEngine()` stops the cadence.
@MainActor
public final class WorkspacesEngine {
    /// Single shared state for the lifetime of the engine.
    public let state: AppState
    public private(set) var isEngineRunning = false
    /// Background cadence for the captures and the transcript safety net while the
    /// screens are not showing.
    private var backgroundTimer: Timer?

    /// Asked before each background tick; false skips it. A host re-checks there whatever
    /// decides that the engine may run, and may stop the engine from inside it.
    public var tickGate: (() -> Bool)?

    public init(state: AppState) {
        self.state = state
    }

    /// The launch work. Signed-in folders under the accounts root join the list, then every
    /// account takes its email as its name once identities are read.
    public func startEngine() {
        guard !isEngineRunning else { return }
        isEngineRunning = true
        state.discoverAccountDirs()
        state.reconcileMonitoring()
        Task { @MainActor [state] in
            await state.refreshUsage(now: Date())
            if state.reconcileAccountNames() { await state.refreshUsage(now: Date()) }
        }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            // The timer's closure is Sendable; the state is the main actor's, so the
            // check runs inside the main-actor task, not out here.
            Task { @MainActor in await self?.runBackgroundTick() }
        }
        // Warm the heavier screens offscreen shortly after launch so the first
        // navigation is snappy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SnapshotMode.prewarm() }
    }

    /// The captures and the transcript safety net, every 90 s while the engine runs.
    /// Skipped while the screens show — RootView's 15 s loop already refreshes, so the
    /// two cadences never overlap (which could land out of order and overwrite newer
    /// data) — and when the host's `tickGate` says no.
    public func runBackgroundTick() async {
        guard isEngineRunning, !state.isPanelOpen else { return }
        if let tickGate, !tickGate() { return }
        // The gate may have stopped the engine.
        guard isEngineRunning else { return }
        await state.refreshUsage(now: Date())
        await state.reconcileTranscripts()
    }

    /// Stops the background cadence, and the screens' refresh loop with it.
    public func stopEngine() {
        guard isEngineRunning else { return }
        isEngineRunning = false
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        state.isPanelOpen = false
    }
}
