import AppKit
import Foundation
import Network

/// Everything that can make `LimitsStore.refresh` run. Intervals from the spec:
/// 120 s in the background, 60 s while the panel is expanded, an immediate
/// pass on expand when the data is > 60 s old, and immediate forced passes on
/// wake and on the network coming back — the two events behind most "the number
/// is frozen" reports.
@MainActor
public final class RefreshTriggers {
    public static let backgroundInterval: TimeInterval = 120
    public static let expandedInterval: TimeInterval = 60

    private let store: LimitsStore
    private var timer: Timer?
    private var wakeObserver: (any NSObjectProtocol)?
    /// Built inside `start()`: `NWPathMonitor.cancel()` is terminal, so a monitor
    /// created once could never survive a stop()/start() round trip.
    private var pathMonitor: NWPathMonitor?
    private var pathWasSatisfied = true

    public init(store: LimitsStore) { self.store = store }

    /// Idempotent: a second call used to add a second wake observer (leaking the
    /// first), so every wake then fired N cache-bypassing refreshes.
    public func start() {
        guard timer == nil else { return }
        schedule(Self.backgroundInterval)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.store.refresh(force: true) }
            }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let returned = satisfied && !self.pathWasSatisfied
                // Record the new state BEFORE awaiting: a second path update
                // arriving while the forced refresh is in flight must not see
                // the stale `false` and fire a second forced fetch.
                self.pathWasSatisfied = satisfied
                if returned { await self.store.refresh(force: true) }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        Task { await store.refresh(force: false) }
    }

    public func setExpanded(_ expanded: Bool) {
        schedule(expanded ? Self.expandedInterval : Self.backgroundInterval)
        if expanded { Task { await store.refreshIfOlderThan(60) } }
    }

    /// Fully reversible: `start()` after `stop()` rebuilds every trigger.
    public func stop() {
        timer?.invalidate(); timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pathMonitor?.cancel(); pathMonitor = nil
        pathWasSatisfied = true
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh(force: false) }
        }
        timer?.tolerance = interval * 0.1
    }
}
