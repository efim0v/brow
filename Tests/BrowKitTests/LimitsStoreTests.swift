import XCTest
import GroveCore
@testable import BrowKit

@MainActor
final class LimitsStoreTests: XCTestCase {
    private var home: URL!
    private var appDir: String!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The test's clock lives in a box, not in `self`: the injected `now` closure is
    /// `@Sendable` and must not capture this @MainActor test case. `now` still reads
    /// and writes like a plain stored property.
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }
    private let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    private var now: Date {
        get { clock.date }
        set { clock.date = newValue }
    }

    /// Scripted fetcher keyed by bearer: each configDir's token is "tok-<dir>".
    private final class Fetcher: UsageFetching, @unchecked Sendable {
        var responses: [String: (Data, Int)] = [:]   // bearer → response
        var calls: [String] = []
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            calls.append(bearer)
            return responses[bearer] ?? (Data("{}".utf8), 500)
        }
    }
    private final class Creds: CredentialsReading, @unchecked Sendable {
        var expiry: [String: Date] = [:]
        func token(configDir: String) -> ClaudeToken? {
            expiry[configDir].map { ClaudeToken(value: "tok-\(configDir)", expiresAt: $0) }
        }
        /// Stands in for the real CLI: re-reading after `claude doctor` sees a token
        /// whose expiry moved forward, which is how TokenKeeper judges success.
        func invalidate(configDir: String) {
            if let current = expiry[configDir] {
                expiry[configDir] = current.addingTimeInterval(8 * 3600)
            }
        }
    }

    private func body(five: Int, seven: Int, scoped: Int? = nil) -> Data {
        var limits = ""
        if let scoped {
            limits = #","limits":[{"kind":"weekly_scoped","percent":\#(scoped),"is_active":true,"resets_at":"2026-09-22T00:00:00Z","scope":{"model":{"display_name":"Fable"}}}]"#
        }
        return Data(#"{"five_hour":{"utilization":\#(five),"resets_at":"2026-09-16T20:00:00Z"},"seven_day":{"utilization":\#(seven),"resets_at":"2026-09-22T00:00:00Z"}\#(limits)}"#.utf8)
    }

    private func makeAccount(_ rel: String, org: String, email: String) throws -> String {
        let dir = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["oauthAccount": ["organizationUuid": org, "emailAddress": email, "organizationRateLimitTier": "default_claude_max_20x"]])
        try json.write(to: dir.appendingPathComponent(".claude.json"))
        return dir.path
    }

    private func makeStore(fetcher: Fetcher, creds: Creds, runner: CommandRunning = MockRunnerBK(results: [])) -> LimitsStore {
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "t", cacheSeconds: 30, backoffCap: 300, credentials: creds)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { [clock] in clock.date })
        return LimitsStore(deps: .init(directory: AccountDirectory(home: home.path, credentials: creds),
                                       keeper: keeper, client: client,
                                       snapshotStore: LimitSnapshotStore(directory: appDir),
                                       settingsStore: BrowSettingsStore(directory: appDir),
                                       now: { [clock] in clock.date }))
    }

    override func setUpWithError() throws {
        home = try Fixture.tempDir("home")
        appDir = try Fixture.tempDir("app").path
        now = t0
    }

    func testFetchesEveryVisibleAccountAndAggregates() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let b = try makeAccount(".claude-accounts/b", org: "org-b", email: "b@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600); creds.expiry[b] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60, scoped: 98), 200)
        fetcher.responses["Bearer tok-\(b)"] = (body(five: 0, seven: 20), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertEqual(store.rows.map(\.name), ["a@x", "b@x"])
        XCTAssertEqual(store.rows[0].snapshot?.fiveHour?.usedPercentage, 40)
        XCTAssertEqual(store.rows[0].status, .ok)
        XCTAssertEqual(store.aggregate.fiveHour, 20, accuracy: 0.001)
        XCTAssertEqual(store.aggregate.rightEar.modelInitial, "F")
        XCTAssertEqual(store.dataAsOf, t0)
        XCTAssertNil(store.footerError)
        XCTAssertEqual(store.rows[0].tokenStatus, "fresh · 1 h")
        // Persisted.
        XCTAssertEqual(LimitSnapshotStore(directory: appDir).load().count, 2)
    }

    func testFailureKeepsPreviousSnapshotAndSurfacesError() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 401)
        now = t0.addingTimeInterval(120)
        await store.refresh(force: true)
        XCTAssertEqual(store.rows[0].snapshot?.fiveHour?.usedPercentage, 40, "last good value retained")
        XCTAssertEqual(store.rows[0].status, .error("Claude sign-in expired"))
        XCTAssertEqual(store.footerError, "Claude sign-in expired", "no account succeeded → footer shows the error")
    }

    func testFooterErrorOnlyWhenNoAccountSucceeded() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let b = try makeAccount(".claude-accounts/b", org: "org-b", email: "b@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600); creds.expiry[b] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        fetcher.responses["Bearer tok-\(b)"] = (Data(), 429)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertNil(store.footerError)
        XCTAssertEqual(store.rows[1].status, .error("Rate limited — try again shortly"))
    }

    func testHiddenAccountIsExcludedFromRowsAndAggregate() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let b = try makeAccount(".claude-accounts/b", org: "org-b", email: "b@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600); creds.expiry[b] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 100, seven: 0), 200)
        fetcher.responses["Bearer tok-\(b)"] = (body(five: 0, seven: 0), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        store.settings.accounts["org-b"] = AccountOverride(name: nil, hidden: true)
        await store.refresh(force: false)
        XCTAssertEqual(store.rows.map(\.id), ["org-a"])
        XCTAssertEqual(store.aggregate.fiveHour, 100, accuracy: 0.001)
        XCTAssertEqual(fetcher.calls.count, 1, "hidden accounts are not fetched")
    }

    func testRefreshIfOlderThanRespectsAge() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refreshIfOlderThan(60)               // nothing yet → fetch
        XCTAssertEqual(fetcher.calls.count, 1)
        now = t0.addingTimeInterval(30)
        await store.refreshIfOlderThan(60)               // 30 s old → skip
        XCTAssertEqual(fetcher.calls.count, 1)
        now = t0.addingTimeInterval(61)
        await store.refreshIfOlderThan(60)               // 61 s old → fetch (cache is 30 s, so it really fetches)
        XCTAssertEqual(fetcher.calls.count, 2)
    }

    func testLoadsPersistedSnapshotsAtInit() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let old = LimitSnapshot(organizationUuid: "org-a", fetchedAt: t0.addingTimeInterval(-86400),
                                fiveHour: CapturedWindow(usedPercentage: 7, resetsAt: nil), sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        try LimitSnapshotStore(directory: appDir).save(["org-a": old])
        let store = makeStore(fetcher: Fetcher(), creds: creds)
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 7)
        XCTAssertEqual(store.rows.first?.status, .stale)
    }

    func testTokenKeeperRunsForExpiringAccount() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(60)     // below 30 min threshold
        let runner = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        let store = makeStore(fetcher: fetcher, creds: creds, runner: runner)
        await store.refresh(force: false)
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]])
        XCTAssertEqual(store.rows[0].tokenStatus, "refreshing (doctor)")
    }

    /// Spec, Error handling: an account whose token cannot be read at all reads
    /// "no token" — not the refresh failure that the missing token caused.
    func testAccountWithoutReadableTokenReadsNoToken() async throws {
        _ = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")   // no Keychain entry
        let fetcher = Fetcher()
        let store = makeStore(fetcher: fetcher, creds: Creds())
        await store.refresh(force: false)
        XCTAssertEqual(store.rows[0].tokenStatus, "no token")
        XCTAssertEqual(store.rows[0].status, .error("No Claude credentials found"))
        XCTAssertTrue(fetcher.calls.isEmpty, "nothing is sent without a bearer")
    }

    func testErrorTextMapping() {
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.http(401)), "Claude sign-in expired")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.http(403)), "Claude sign-in expired")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.tooManyRequests), "Rate limited — try again shortly")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.backoff), "Rate limited — waiting to retry")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.noCredentials), "No Claude credentials found")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.malformed), "Unexpected response from Anthropic")
        XCTAssertEqual(LimitsStore.errorText(OAuthUsageError.http(503)), "Anthropic returned HTTP 503")
        XCTAssertEqual(LimitsStore.errorText(URLError(.notConnectedToInternet)), "Offline")
    }
}

/// Local copy of GroveCoreTests' MockRunner (test targets can't share support files).
final class MockRunnerBK: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ProcessResult]
    private var recorded: [(executable: String, args: [String], env: [String: String]?)] = []
    init(results: [ProcessResult]) { self.script = results }
    var invocations: [(executable: String, args: [String], env: [String: String]?)] { lock.withLock { recorded } }
    func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            recorded.append((executable, args, env))
            guard !script.isEmpty else { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
            return script.removeFirst()
        }
    }
}
