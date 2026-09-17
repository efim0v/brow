import AppKit
import Combine
import Foundation
import Network

/// Everything that can make `LimitsStore` re-evaluate itself. Intervals from the
/// spec: one 60 s poll timer for the life of the app (the expanded panel uses the
/// same one), a 5 s staleness ticker that costs no network, an immediate pass on
/// expand when the data is > 60 s old, and immediate forced passes on wake and on
/// the network coming back — the two events behind most "the number is frozen"
/// reports.
///
/// Every trigger guards on its OWN state. A single `guard timer == nil` used to
/// cover all of them, and `setExpanded` created the timer: a hover over the notch
/// while the app was still launching therefore made `start()` return before it
/// installed the wake observer and the path monitor, for the life of the process.
@MainActor
public final class RefreshTriggers {
    /// One interval, whatever the panel is doing. Restarting the timer on expand
    /// pushed the next poll a full interval into the future every time the pointer
    /// crossed the notch, so the most attentive user got the stalest numbers.
    ///
    /// 30 s, not 60: the endpoint refills one request per ~100 s per account and
    /// `OAuthUsageClient` paces to that, answering an early poll from its cache at no
    /// network cost — so a short tick only decides how soon after the window opens the
    /// next reading is taken (≤ 30 s late instead of ≤ 60).
    public static let pollInterval: TimeInterval = 30
    /// Clock-only: re-evaluates ages and the stale flag, never the network.
    public static let tickerInterval: TimeInterval = 5

    private let store: LimitsStore
    /// Internal, not private: the tests assert that expand and a second `start()`
    /// keep the SAME objects rather than stacking new ones.
    private(set) var timer: Timer?
    private(set) var ticker: Timer?
    private(set) var wakeObserver: (any NSObjectProtocol)?
    /// Built inside `start()`: `NWPathMonitor.cancel()` is terminal, so a monitor
    /// created once could never survive a stop()/start() round trip.
    private(set) var pathMonitor: NWPathMonitor?
    private var pathWasSatisfied = true
    /// Every `Timer` this object has scheduled (poll + ticker). The guards are the
    /// behaviour under test and a leaked duplicate is invisible in the nil checks.
    private(set) var timersCreated = 0

    /// Reachability as the path monitor sees it. Read by the controller, which feeds
    /// it to `TokenKeeper` — an actor that cannot look at the main-actor store.
    @Published public private(set) var isOnline = true

    /// What `start()` has actually put in place. Each flag is one trigger.
    var installed: (timer: Bool, ticker: Bool, wake: Bool, path: Bool) {
        (timer != nil, ticker != nil, wakeObserver != nil, pathMonitor != nil)
    }

    public init(store: LimitsStore) { self.store = store }

    /// Idempotent per trigger: a second call installs only what is missing. It used
    /// to add a second wake observer (leaking the first), so every wake then fired N
    /// cache-bypassing refreshes.
    public func start() {
        var startedPolling = false
        if timer == nil {
            timer = schedule(Self.pollInterval) { [weak self] in
                Task { @MainActor in await self?.store.refresh(force: false) }
            }
            startedPolling = true
        }
        if ticker == nil {
            ticker = schedule(Self.tickerInterval) { [weak self] in
                Task { @MainActor in self?.store.tick() }
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.store.refresh(force: true) }
                }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
            // Seeded SYNCHRONOUSLY, before the first cycle is queued below.
            // `isOnline` starts optimistic and `pathUpdateHandler` is asynchronous, so a
            // launch made with no network could run its first cycle believing it was
            // online: `TokenKeeper.ensureFresh` then skips `.skippedOffline`, runs
            // `claude doctor`, and — a plain non-zero exit not being `cliNeverRan` —
            // falls through to `claude -p`, which spends the account's limit and starts
            // its 5-hour window for a refresh that could never have worked, and counts
            // a failure that walks the breaker up. `pathChanged` records before it acts
            // and is idempotent, so seeding it costs nothing when the path is fine.
            pathChanged(satisfied: monitor.currentPath.status == .satisfied)
        }
        // Only on the call that armed the poll: `start()` is now safe to call twice
        // and must not spend a cycle for it.
        if startedPolling { Task { await store.refresh(force: false) } }
    }

    /// Expand/collapse touches NO trigger. Hovering the notch is the most frequent
    /// event in the app; the only thing it may cost is one fetch of data older than
    /// the poll interval.
    public func setExpanded(_ expanded: Bool) {
        guard expanded else { return }
        Task { await store.refreshIfOlderThan(Self.pollInterval) }
    }

    /// One path update. Synchronous, and the new state is recorded before anything is
    /// awaited: a second update arriving while the forced refresh is in flight must
    /// not see the stale `false` and fire a second forced fetch.
    func pathChanged(satisfied: Bool) {
        let returned = satisfied && !pathWasSatisfied
        pathWasSatisfied = satisfied
        if isOnline != satisfied { isOnline = satisfied }
        store.markOnline(satisfied)
        if returned { Task { await store.refresh(force: true) } }
    }

    /// Fully reversible: `start()` after `stop()` rebuilds every trigger.
    public func stop() {
        timer?.invalidate(); timer = nil
        ticker?.invalidate(); ticker = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pathMonitor?.cancel(); pathMonitor = nil
        pathWasSatisfied = true
    }

    private func schedule(_ interval: TimeInterval, _ body: @escaping @Sendable () -> Void) -> Timer {
        timersCreated += 1
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in body() }
        timer.tolerance = interval * 0.1
        return timer
    }
}
