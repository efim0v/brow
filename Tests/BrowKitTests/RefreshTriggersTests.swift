import Foundation
import XCTest
import GroveCore
@testable import BrowKit

/// The triggers are the only thing standing between "the panel is up" and "the
/// numbers keep moving". Every regression they have had was an ordering one — a
/// hover during launch that disabled the wake and network observers for the life
/// of the process, and a second `start()` that stacked a second wake observer —
/// so these tests are about installation and identity, not about the network.
@MainActor
final class RefreshTriggersTests: XCTestCase {
    /// Reads nothing: the fixture home has no account directories, so the store's
    /// scan finds nobody and no fetch is ever attempted.
    private final class SilentCreds: CredentialsReading, @unchecked Sendable {
        func token(configDir: String) -> ClaudeToken? { nil }
        func invalidate(configDir: String) {}
    }

    /// A trigger firing a request would be a bug in these tests, not a scenario:
    /// there is no account to fetch for.
    private final class UnusedFetcher: UsageFetching, @unchecked Sendable {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            XCTFail("no account exists; nothing should have been fetched")
            return (Data(), 500)
        }
    }

    private var home: URL!
    private var appDir: String!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("triggers-home")
        appDir = try Fixture.tempDir("triggers-app").path
    }

    private func makeStore() -> LimitsStore {
        let creds = SilentCreds()
        return LimitsStore(deps: .init(
            directory: AccountDirectory(home: home.path, credentials: creds),
            keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                claudePath: "/x/claude", allowPromptFallback: { false }),
            client: OAuthUsageClient(fetcher: UnusedFetcher(), appVersion: "t",
                                     cacheSeconds: 30, backoffCap: 300, credentials: creds),
            snapshotStore: LimitSnapshotStore(directory: appDir),
            settingsStore: BrowSettingsStore(directory: appDir),
            now: { Date() }))
    }

    /// The reported bug: hovering the notch while the app was still launching called
    /// `setExpanded` first, which created the poll timer, and `start()`'s single
    /// `guard timer == nil` then returned before installing the wake observer and the
    /// path monitor — permanently. Waking the lid or coming back on to Wi-Fi refreshed
    /// nothing for the rest of the process.
    func testSetExpandedBeforeStartDoesNotPreventStartFromInstallingEverything() {
        let triggers = RefreshTriggers(store: makeStore())
        defer { triggers.stop() }

        triggers.setExpanded(true)
        XCTAssertFalse(triggers.installed.timer, "setExpanded must not install anything")

        triggers.start()
        XCTAssertTrue(triggers.installed.timer)
        XCTAssertTrue(triggers.installed.ticker)
        XCTAssertTrue(triggers.installed.wake)
        XCTAssertTrue(triggers.installed.path)
    }

    /// One 60 s timer for the life of the app. Restarting it on every expand pushed
    /// the next poll a full interval away each time the pointer crossed the notch, so
    /// a user who hovered often saw the numbers refresh least.
    func testExpandDoesNotRestartThePollTimer() {
        let triggers = RefreshTriggers(store: makeStore())
        defer { triggers.stop() }
        triggers.start()
        let poll = triggers.timer
        XCTAssertNotNil(poll)
        XCTAssertEqual(poll?.timeInterval, RefreshTriggers.pollInterval)

        triggers.setExpanded(true)
        XCTAssertIdentical(triggers.timer, poll, "expand must reuse the running poll timer")
        triggers.setExpanded(false)
        XCTAssertIdentical(triggers.timer, poll, "collapse must reuse the running poll timer")
        XCTAssertEqual(triggers.timersCreated, 2, "one poll timer and one ticker, once")
    }

    /// A second `start()` used to add a second wake observer (the first was leaked),
    /// so every wake fired N cache-bypassing refreshes. Each trigger now guards on its
    /// own state, which has to hold for all four of them.
    func testStartIsIdempotentPerTrigger() {
        let triggers = RefreshTriggers(store: makeStore())
        defer { triggers.stop() }

        triggers.start()
        let poll = triggers.timer
        let ticker = triggers.ticker
        let wake = triggers.wakeObserver
        let path = triggers.pathMonitor

        triggers.start()
        XCTAssertEqual(triggers.timersCreated, 2, "start() must not schedule a second timer or ticker")
        XCTAssertIdentical(triggers.timer, poll)
        XCTAssertIdentical(triggers.ticker, ticker)
        XCTAssertIdentical(triggers.wakeObserver as AnyObject?, wake as AnyObject?)
        XCTAssertIdentical(triggers.pathMonitor, path)
        XCTAssertTrue(triggers.installed.timer)
        XCTAssertTrue(triggers.installed.ticker)
        XCTAssertTrue(triggers.installed.wake)
        XCTAssertTrue(triggers.installed.path)
    }

    /// `isOnline` is read by two consumers that cannot see `NWPathMonitor`: the panel's
    /// footer (through the store) and `TokenKeeper`, which must not spend its attempt
    /// floor on refreshes that cannot reach the network. Only the down → up edge polls;
    /// a repeated "satisfied" must not.
    func testPathChangeMirrorsOnlineStateIntoTheStore() {
        let store = makeStore()
        let triggers = RefreshTriggers(store: store)
        defer { triggers.stop() }

        triggers.pathChanged(satisfied: false)
        XCTAssertFalse(triggers.isOnline)
        XCTAssertFalse(store.isOnline)

        triggers.pathChanged(satisfied: true)
        XCTAssertTrue(triggers.isOnline)
        XCTAssertTrue(store.isOnline)
    }

    /// `isOnline` starts optimistic and `NWPathMonitor` corrects it ASYNCHRONOUSLY,
    /// while `start()` queues the first refresh in the same turn. A launch made with no
    /// network could therefore run its first cycle believing it was online:
    /// `TokenKeeper.ensureFresh` skips `.skippedOffline`, runs `claude doctor`, and —
    /// a plain non-zero exit not being `cliNeverRan` — falls through to `claude -p`,
    /// which spends the account's limit and starts its 5-hour window for a refresh that
    /// could not have worked, and counts a failure that walks the breaker up. `start()`
    /// therefore seeds the flag from the monitor synchronously.
    ///
    /// The assertion is against the monitor's own answer rather than a constant: this
    /// test cannot turn the machine's Wi-Fi off. On a networked machine the stale `false`
    /// below is what the old code left behind, and the seeded `true` is the fix.
    func testStartSeedsOnlineStateFromTheMonitorRatherThanLeavingAStaleValue() {
        let store = makeStore()
        let triggers = RefreshTriggers(store: store)
        defer { triggers.stop() }

        triggers.pathChanged(satisfied: false)          // "the app was last told it is offline"
        XCTAssertFalse(triggers.isOnline)

        triggers.start()
        let monitorSays = triggers.pathMonitor?.currentPath.status == .satisfied
        XCTAssertEqual(triggers.isOnline, monitorSays,
                       "start() must read the monitor, not wait for its first callback")
        XCTAssertEqual(store.isOnline, monitorSays, "and push the same answer into the store")
    }
}
