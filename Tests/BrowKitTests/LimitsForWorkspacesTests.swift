import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// Brow's limits store as the source of the account pickers' numbers, and Workspaces'
/// folders joining the notch's scan.
@MainActor
final class LimitsForWorkspacesTests: XCTestCase {
    private var home: URL!
    private var appDir: String!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("limits-ws-home")
        appDir = try Fixture.tempDir("limits-ws-app").path
    }

    /// A store whose first frame already has two accounts and a reading for one, from
    /// the file a previous run left — no scan, no network.
    private func makeStore(now: Date, readingAge: TimeInterval = 30) throws -> LimitsStore {
        let work = DiscoveredAccount(organizationUuid: "org-work", email: "w@example.com", tier: nil,
                                     configDir: "/x/work", aliasDirs: ["/x/work-2"], tokenExpiresAt: nil)
        let team = DiscoveredAccount(organizationUuid: "org-team", email: "t@example.com", tier: nil,
                                     configDir: "/x/team", aliasDirs: [], tokenExpiresAt: nil)
        let snapshot = LimitSnapshot(organizationUuid: "org-work", fetchedAt: now.addingTimeInterval(-readingAge),
                                     fiveHour: CapturedWindow(usedPercentage: 42, resetsAt: nil),
                                     sevenDay: CapturedWindow(usedPercentage: 61, resetsAt: nil),
                                     weeklyScoped: nil, weeklyScopedModel: nil)
        try LimitSnapshotStore(directory: appDir).saveFile(LimitsFile(
            snapshots: ["org-work": snapshot],
            accounts: [PersistedAccount(from: work, order: 0), PersistedAccount(from: team, order: 1)],
            subscriptions: [:]))
        let creds = SilentCreds()
        return LimitsStore(deps: .init(
            directory: AccountDirectory(home: home.path, credentials: creds),
            keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                claudePath: "/x/claude", allowPromptFallback: { false }),
            client: OAuthUsageClient(fetcher: UnusedFetcher(), appVersion: "t",
                                     cacheSeconds: 30, backoffCap: 300, credentials: creds),
            snapshotStore: LimitSnapshotStore(directory: appDir),
            settingsStore: BrowSettingsStore(directory: appDir),
            now: { now }))
    }

    /// The persisted accounts carry no aliases (a scan fills those in), so the folder
    /// itself is asked for here, with the trailing slash a hand-written config may have.
    func testTheStoreAnswersForAnAccountByItsFolder() throws {
        let store = try makeStore(now: Date())
        let limits = try XCTUnwrap(store.limits(forConfigDirs: ["/x/elsewhere", "/x/work/"]))
        XCTAssertEqual(limits, AccountLimits(fiveHour: 42, weekly: 61, stale: false))
        XCTAssertNil(store.limits(forConfigDirs: ["/x/team"]), "an account without a reading has no numbers")
        XCTAssertNil(store.limits(forConfigDirs: ["/x/nobody"]))
    }

    func testAnOldReadingIsMarkedStale() throws {
        let store = try makeStore(now: Date(), readingAge: 3_600)
        XCTAssertEqual(store.limits(forConfigDirs: ["/x/work"])?.stale, true)
    }

    /// Workspaces' folders outside ~/.claude and ~/.claude-accounts join the scan, once
    /// each, without being written to Brow's settings.
    func testWorkspacesFoldersOutsideTheUsualPlacesJoinTheScan() throws {
        let home = "/Users/u"
        let accounts = [AccountConfig(name: "default", configDir: "/Users/u/.claude"),
                        AccountConfig(name: "work", configDir: "/Users/u/.claude-accounts/work"),
                        AccountConfig(name: "old", configDir: "/Volumes/ext/claude-old/", aliasDirs: ["/Volumes/ext/claude-old"])]
        XCTAssertEqual(WorkspacesAccountJoin.extraDirs(for: accounts, home: home), ["/Volumes/ext/claude-old"])

        let store = try makeStore(now: Date())
        store.settings.extraDirs = ["~/alt"]
        store.runtimeExtraDirs = ["/Volumes/ext/claude-old", "~/alt"]
        XCTAssertEqual(store.scanExtraDirs, ["~/alt", "/Volumes/ext/claude-old"])
        XCTAssertEqual(store.settings.extraDirs, ["~/alt"], "the settings keep only the user's own")
    }

    private final class SilentCreds: CredentialsReading, @unchecked Sendable {
        func token(configDir: String) -> ClaudeToken? { nil }
        func invalidate(configDir: String) {}
    }

    private final class UnusedFetcher: UsageFetching, @unchecked Sendable {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            XCTFail("nothing here fetches")
            return (Data(), 500)
        }
    }
}
