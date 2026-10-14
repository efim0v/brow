import XCTest
import GroveCore
@testable import BrowKit

@MainActor
final class LimitNotifierTests: XCTestCase {
    /// Records every call; answers with a scripted status.
    private final class FakePoster: NotificationPosting {
        var status: NotificationAuthorization
        /// What a permission request turns the status into — the user's answer.
        var answer: NotificationAuthorization = .allowed
        var requests = 0
        var posted: [LimitNotice] = []
        var removals = 0
        var withdrawn: [[String]] = []
        init(_ status: NotificationAuthorization) { self.status = status }
        func authorization() async -> NotificationAuthorization { status }
        func requestAuthorization() async -> NotificationAuthorization { requests += 1; status = answer; return status }
        func post(_ notice: LimitNotice) async { posted.append(notice) }
        func removePending() { removals += 1 }
        func removePending(ids: [String]) { withdrawn.append(ids) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_792_065_600)   // 2026-10-15 12:00:00 UTC

    private func row(_ org: String = "org-a", five: Double) -> AccountRow {
        let account = DiscoveredAccount(organizationUuid: org, email: "\(org)@example.com", tier: nil,
                                        configDir: "/tmp/brow-tests/.claude-accounts/\(org)", aliasDirs: [],
                                        tokenExpiresAt: nil)
        return AccountRow(account: account, name: "Work",
                          snapshot: LimitSnapshot(organizationUuid: org, fetchedAt: t0.addingTimeInterval(-10),
                                                  fiveHour: CapturedWindow(usedPercentage: five, resetsAt: "2026-10-15T18:40:00Z"),
                                                  sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil),
                          status: .ok, tokenStatus: "valid")
    }

    private func settings(on: Bool, resets: Bool = false) -> BrowSettings {
        var s = BrowSettings()
        s.notifyLimits = on
        s.notifyResets = resets
        return s
    }

    private func notifier(_ poster: FakePoster) -> LimitNotifier {
        LimitNotifier(poster: poster, now: { [t0] in t0 })
    }

    private func settle(_ n: LimitNotifier) async {
        await n.permissionRequest?.value
        await n.delivery?.value
    }

    func testNothingIsRequestedWhileTheSettingIsOff() async {
        let poster = FakePoster(.notDetermined)
        let n = notifier(poster)
        n.settingsChanged(to: settings(on: false))
        n.settingsChanged(to: settings(on: false, resets: true))
        n.evaluate(rows: [row(five: 70)], settings: settings(on: false))
        n.evaluate(rows: [row(five: 96)], settings: settings(on: false))
        await settle(n)
        XCTAssertEqual(poster.requests, 0)
        XCTAssertEqual(poster.posted, [])
    }

    func testTurningWarningsOnAsksOnceAndOnlyWhileUndetermined() async {
        let poster = FakePoster(.notDetermined)
        let n = notifier(poster)
        n.settingsChanged(to: settings(on: false))
        n.settingsChanged(to: settings(on: true))
        await settle(n)
        XCTAssertEqual(poster.requests, 1)
        XCTAssertEqual(n.authorization, .allowed)

        n.settingsChanged(to: settings(on: true, resets: true))   // still on: no edge
        n.settingsChanged(to: settings(on: false))
        n.settingsChanged(to: settings(on: true))                 // an edge, but already answered
        await settle(n)
        XCTAssertEqual(poster.requests, 1)
    }

    func testDeniedPostsNothingAndSaysSo() async {
        let poster = FakePoster(.denied)
        let n = notifier(poster)
        await n.refreshAuthorization()
        XCTAssertEqual(n.authorization, .denied)
        n.settingsChanged(to: settings(on: true))
        await settle(n)
        XCTAssertEqual(poster.requests, 0, "macOS asks only once; after a no, Settings points to System Settings")
        n.evaluate(rows: [row(five: 70)], settings: settings(on: true))
        n.evaluate(rows: [row(five: 96)], settings: settings(on: true))
        await settle(n)
        XCTAssertEqual(poster.posted, [])
    }

    /// Turned on in System Settings, which tells Brow nothing — and Brow, an accessory
    /// app behind a non-activating panel, may not become active again for days.
    func testAllowingInSystemSettingsIsPickedUpByTheNextNotice() async {
        let poster = FakePoster(.denied)
        let n = notifier(poster)
        await n.refreshAuthorization()
        n.evaluate(rows: [row(five: 70)], settings: settings(on: true))
        poster.status = .allowed
        n.evaluate(rows: [row(five: 96)], settings: settings(on: true))
        await settle(n)
        XCTAssertEqual(poster.posted.map(\.kind), [.warning(level: 95)])
        XCTAssertEqual(n.authorization, .allowed, "and Settings shows it")
    }

    /// A relaunch within 3 min finds a fresh `limits.json`: the baseline at launch owes a
    /// reset notice before the status has been read.
    func testANoticeDueBeforeTheStatusIsKnownIsNotLost() async {
        let poster = FakePoster(.allowed)
        let n = notifier(poster)
        XCTAssertEqual(n.authorization, .unknown)
        n.evaluate(rows: [row(five: 85)], settings: settings(on: true, resets: true))
        await settle(n)
        XCTAssertEqual(poster.posted.map(\.kind), [.reset])
    }

    func testAllowedPostsTheEvaluatorsNotices() async {
        let poster = FakePoster(.allowed)
        let n = notifier(poster)
        await n.refreshAuthorization()
        var reference = LimitWarnings()
        var expected: [LimitNotice] = []
        for five in [70.0, 82, 83, 96] {
            n.evaluate(rows: [row(five: five)], settings: settings(on: true, resets: true))
            expected += reference.evaluate(rows: [row(five: five)], settings: settings(on: true, resets: true), now: t0)
        }
        await settle(n)
        XCTAssertEqual(poster.posted.map(\.id), expected.map(\.id))
        XCTAssertEqual(poster.posted.map(\.kind), [.warning(level: 80), .reset, .warning(level: 95)])
    }

    func testTurningEitherSettingOffRemovesPendingNotices() async {
        let poster = FakePoster(.allowed)
        let n = notifier(poster)
        n.settingsChanged(to: settings(on: true, resets: true))
        n.settingsChanged(to: settings(on: true, resets: false))
        await settle(n)
        XCTAssertEqual(poster.removals, 1)
        n.settingsChanged(to: settings(on: false))
        await settle(n)
        XCTAssertEqual(poster.removals, 2)
        n.settingsChanged(to: settings(on: true))
        await settle(n)
        XCTAssertEqual(poster.removals, 2, "turning things on removes nothing")
    }

    /// Hidden accounts never notify: a reset notice already handed to macOS for one is
    /// taken back when it leaves the panel.
    func testHidingAnAccountTakesBackItsResetNotice() async {
        let poster = FakePoster(.allowed)
        let n = notifier(poster)
        let s = settings(on: true, resets: true)
        n.evaluate(rows: [row(five: 70), row("org-b", five: 70)], settings: s)
        n.evaluate(rows: [row(five: 82), row("org-b", five: 82)], settings: s)
        await settle(n)
        let resets = poster.posted.filter { $0.kind == .reset }.map(\.id)
        XCTAssertEqual(resets.count, 2)
        n.evaluate(rows: [row("org-b", five: 83)], settings: s)       // org-a hidden
        n.evaluate(rows: [row("org-b", five: 84)], settings: s)
        await settle(n)
        XCTAssertEqual(poster.withdrawn, [resets.filter { $0.hasPrefix("reset.org-a.") }], "once, and only org-a's")
        XCTAssertEqual(poster.removals, 0, "the other account's notice stays")
    }

    func testTheTestNotification() async {
        let poster = FakePoster(.allowed)
        let n = notifier(poster)
        var s = settings(on: true)
        s.notifyThresholds = [70, 90]
        n.settingsChanged(to: s)
        n.sendTest()
        await settle(n)
        XCTAssertEqual(poster.posted.map(\.title), ["Brow"])
        XCTAssertEqual(poster.posted.map(\.body), ["Test: limit warnings are on. Brow warns at 70% and 90%."])
        XCTAssertEqual(poster.posted.first?.kind, .test)
    }

    // MARK: - Wired to a store

    private struct NoCredentials: CredentialsReading {
        func token(configDir: String) -> ClaudeToken? { nil }
        func invalidate(configDir: String) {}
        func grant(configDir: String) -> CredentialsAccess { .missing }
    }
    private struct NoNetwork: UsageFetching {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
    }

    /// A store with no accounts and no refresh cycle: only its settings matter here.
    private func makeStore(warningsOn: Bool) throws -> LimitsStore {
        let dir = try Fixture.tempDir("notifier-store").path
        var s = BrowSettings()
        s.notifyLimits = warningsOn
        try BrowSettingsStore(directory: dir).save(s)
        let creds = NoCredentials()
        let keeper = TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { [t0] in t0 })
        return LimitsStore(deps: .init(directory: AccountDirectory(home: dir, credentials: creds), keeper: keeper,
                                       client: OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: creds),
                                       snapshotStore: LimitSnapshotStore(directory: dir),
                                       settingsStore: BrowSettingsStore(directory: dir), now: { [t0] in t0 }))
    }

    /// Warnings turned on in an earlier run: the user has already opted in.
    func testStartAsksAtLaunchOnlyWhenWarningsAreAlreadyOn() async throws {
        let poster = FakePoster(.notDetermined)
        let n = notifier(poster)
        n.start(store: try makeStore(warningsOn: true))
        await settle(n)
        XCTAssertEqual(poster.requests, 1)
        n.stop()

        let quiet = FakePoster(.notDetermined)
        let m = notifier(quiet)
        m.start(store: try makeStore(warningsOn: false))
        await settle(m)
        XCTAssertEqual(quiet.requests, 0)
        XCTAssertEqual(m.authorization, .notDetermined)
        m.stop()
    }

    func testStartFollowsTheStoresSettings() async throws {
        let poster = FakePoster(.notDetermined)
        let n = notifier(poster)
        let store = try makeStore(warningsOn: false)
        n.start(store: store)
        await settle(n)
        store.settings.notifyLimits = true
        await settle(n)
        XCTAssertEqual(poster.requests, 1)
        XCTAssertEqual(n.authorization, .allowed)
        store.settings.notifyLimits = false
        await settle(n)
        XCTAssertEqual(poster.removals, 1)
        n.stop()
        store.settings.notifyLimits = true
        await settle(n)
        XCTAssertEqual(poster.requests, 1, "stopped: no longer listening")
    }

    func testWithoutAnAppBundleNotificationsAreUnavailable() async {
        let poster = UnavailableNotifications()
        let status = await poster.authorization()
        let asked = await poster.requestAuthorization()
        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(asked, .unavailable)
        XCTAssertFalse(SystemNotifications.isSupported, "the test runner is not an app bundle")
    }
}
