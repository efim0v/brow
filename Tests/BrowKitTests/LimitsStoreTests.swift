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
    ///
    /// Lock-guarded, like `MockRunnerBK` below. `UsageFetching.fetch` is a nonisolated
    /// async requirement, so `OAuthUsageClient` releases its executor at the await and
    /// this body runs off-actor — and `LimitsStore.refresh` runs one child task per
    /// account, so two accounts would otherwise mutate the same Array on two threads.
    private final class Fetcher: UsageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [String: (Data, Int)] = [:]   // bearer → response
        private var recorded: [String] = []
        var responses: [String: (Data, Int)] {
            get { lock.withLock { scripted } }
            set { lock.withLock { scripted = newValue } }
        }
        var calls: [String] { lock.withLock { recorded } }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return lock.withLock {
                recorded.append(bearer)
                return scripted[bearer] ?? (Data("{}".utf8), 500)
            }
        }
    }
    private final class Creds: CredentialsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var expiries: [String: Date] = [:]
        private var reads = 0
        var expiry: [String: Date] {
            get { lock.withLock { expiries } }
            set { lock.withLock { expiries = newValue } }
        }
        /// How many times the "Keychain" was really consulted — the count the panel's
        /// prompt behaviour depends on.
        var readCount: Int { lock.withLock { reads } }
        func token(configDir: String) -> ClaudeToken? {
            lock.withLock {
                reads += 1
                return expiries[configDir].map { ClaudeToken(value: "tok-\(configDir)", expiresAt: $0) }
            }
        }
        /// Stands in for the real CLI: re-reading after `claude doctor` sees a token
        /// whose expiry moved forward, which is how TokenKeeper judges success.
        func invalidate(configDir: String) {
            lock.withLock {
                if let current = expiries[configDir] {
                    expiries[configDir] = current.addingTimeInterval(8 * 3600)
                }
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

    /// The first frame shows last-known values with their real age — before any fetch,
    /// and (see `testInitTouchesNoCredentials`) before any Keychain read.
    func testBootstrapShowsPersistedSnapshotsBeforeAnyFetch() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let old = LimitSnapshot(organizationUuid: "org-a", fetchedAt: t0.addingTimeInterval(-86400),
                                fiveHour: CapturedWindow(usedPercentage: 7, resetsAt: nil), sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        try LimitSnapshotStore(directory: appDir).save(["org-a": old])
        let fetcher = Fetcher()
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.bootstrap()
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 7)
        XCTAssertEqual(store.rows.first?.status, .stale)
        XCTAssertTrue(fetcher.calls.isEmpty, "bootstrap discovers accounts; it does not fetch")
    }

    /// The C2 freeze: `LimitsStore.init` used to run `AccountDirectory.scan` — one
    /// `SecItemCopyMatching` per config dir — synchronously on the main actor, inside
    /// `applicationDidFinishLaunching`, BEFORE the panel was ever shown. On a new
    /// bundle id macOS parks the main thread in a modal prompt per account, so nothing
    /// was drawn, nothing was logged and Cmd-Q was inert.
    func testInitTouchesNoCredentials() async throws {
        _ = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry["/anything"] = t0
        let store = makeStore(fetcher: Fetcher(), creds: creds)
        XCTAssertEqual(creds.readCount, 0, "no Keychain read before the panel is on screen")
        XCTAssertTrue(store.rows.isEmpty)
        await store.bootstrap()
        XCTAssertGreaterThan(creds.readCount, 0, "discovery happens in bootstrap, off the main actor")
        XCTAssertEqual(store.rows.map(\.id), ["org-a"])
    }

    /// Six triggers call `refresh`, a cycle can be in flight for 210 s (doctor 90 s +
    /// `-p` 120 s), and the 60 s expanded timer keeps firing: overlap is the normal
    /// case. Overlapping cycles let an older capture overwrite a newer one and cleared
    /// the spinner while a fetch was still out.
    func testConcurrentRefreshesRunASingleCycle() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)   // fresh: keeper does one read
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.bootstrap()

        // Measure one cycle (scan + TokenKeeper + the bearer read), then run two
        // callers at once and require the SAME cost.
        let baseline = creds.readCount
        await store.refresh(force: false)
        let perCycle = creds.readCount - baseline
        XCTAssertGreaterThan(perCycle, 0)
        let afterOne = creds.readCount
        now = t0.addingTimeInterval(60)          // past the client's 30 s cache

        async let first: Void = store.refresh(force: false)
        async let second: Void = store.refresh(force: false)
        _ = await (first, second)

        XCTAssertEqual(creds.readCount - afterOne, perCycle, "the second caller joins the running cycle")
        XCTAssertEqual(fetcher.calls.count, 2, "one request per cycle, not one per caller")
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.isForcing)
    }

    /// Spec, Testing: "force bypasses cache but not backoff" — at the store level,
    /// where the refresh button actually lives.
    func testForceBypassesTheCacheButNotTheBackoff() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertEqual(fetcher.calls.count, 1)
        now = t0.addingTimeInterval(5)                    // well inside the 30 s cache
        await store.refresh(force: false)
        XCTAssertEqual(fetcher.calls.count, 1, "a background poll is served from the cache")
        await store.refresh(force: true)
        XCTAssertEqual(fetcher.calls.count, 2, "force refetches inside the cache window")

        // Now a 429 puts the account in backoff; hammering ⟳ must not punch through it.
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 429)
        now = t0.addingTimeInterval(60)
        await store.refresh(force: true)
        XCTAssertEqual(fetcher.calls.count, 3)
        let afterBackoff = fetcher.calls.count
        now = t0.addingTimeInterval(61)
        await store.refresh(force: true)
        XCTAssertEqual(fetcher.calls.count, afterBackoff, "force must not punch through the 429 backoff")
        XCTAssertEqual(store.rows[0].status, .error("Rate limited — waiting to retry"))
    }

    /// Spec: the spinner shows "while a FORCED fetch is in flight". A 120 s background
    /// poll (or AddAccountFlow's poll) must not take the ⟳ button off the screen.
    func testIsForcingIsSetOnlyByAForcedRefresh() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 1, seven: 1), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)

        async let background: Void = store.refresh(force: false)
        XCTAssertFalse(store.isForcing, "a background poll never spins the footer")
        await background
        XCTAssertFalse(store.isForcing)
        XCTAssertFalse(store.isRefreshing)
    }

    func testConfigErrorIsPublishedForThePanelFooter() async throws {
        let store = makeStore(fetcher: Fetcher(), creds: Creds())
        XCTAssertNil(store.configError)
        store.setConfigError("`claude` not found — set the path in Settings › General")
        XCTAssertEqual(store.configError, "`claude` not found — set the path in Settings › General")
        store.setConfigError(nil)
        XCTAssertNil(store.configError)
    }

    /// The footer has room for ONE line and used to render `configError ?? footerError`,
    /// with a `configError` that was set once at launch and never cleared: a single
    /// "`claude` not found" hid every fetch error — offline, sign-in expired, rate
    /// limited — for the life of the process, even after the path was fixed.
    func testFooterShowsTheMostRecentErrorAndClearingConfigErrorRestoresTheFetchError() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 401)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertEqual(store.footerError, "Claude sign-in expired")
        XCTAssertEqual(store.panelError, "Claude sign-in expired")

        let notFound = "`claude` not found — set the path in Settings › General"
        store.setConfigError(notFound)
        XCTAssertEqual(store.panelError, notFound, "the cause outranks a symptom raised at the same instant")

        // A fetch error raised AFTER the config error is the news the user has not
        // seen yet, and it is the one they can act on.
        now = t0.addingTimeInterval(600)
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 503)
        await store.refresh(force: true)
        XCTAssertEqual(store.panelError, "Anthropic returned HTTP 503")

        // Clearing the config error (a path typed in Settings, or a detection that
        // landed late) must leave the fetch error visible, not blank the footer.
        store.setConfigError(nil)
        XCTAssertNil(store.configError)
        XCTAssertEqual(store.panelError, "Anthropic returned HTTP 503")
        XCTAssertEqual(store.panelError, store.footerError)
    }

    /// `skippedRateLimited` is TokenKeeper's throttle, not a healthy token: falling
    /// through to the "fresh" branch made a long-dead token read "fresh · 0 min".
    func testTokenStatusNeverCallsADeadTokenFresh() {
        let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: nil,
                                        configDir: "/d", aliasDirs: [],
                                        tokenExpiresAt: t0.addingTimeInterval(-18 * 86400))
        XCTAssertEqual(LimitsStore.tokenStatus(account, outcome: .skippedRateLimited, error: nil, now: t0),
                       "token refresh failed (retrying)")
        XCTAssertEqual(LimitsStore.tokenStatus(account, outcome: nil, error: nil, now: t0),
                       "expired 18 d ago")
        let live = DiscoveredAccount(organizationUuid: "org", email: nil, tier: nil, configDir: "/d",
                                     aliasDirs: [], tokenExpiresAt: t0.addingTimeInterval(7200))
        XCTAssertEqual(LimitsStore.tokenStatus(live, outcome: nil, error: nil, now: t0), "fresh · 2 h")
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

    /// Settings must be able to un-hide an account, so it lists `allRows` — every
    /// discovered account — while the ears and the panel keep using `rows`.
    func testAllRowsIncludesHiddenAccounts() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let store = makeStore(fetcher: Fetcher(), creds: creds)
        await store.bootstrap()
        store.settings.accounts["org-a"] = AccountOverride(name: nil, hidden: true)
        XCTAssertEqual(store.rows.map(\.id), [])
        XCTAssertEqual(store.allRows.map(\.id), ["org-a"])
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

/// `ClaudePathResolver` + `AddAccountFlow`'s pure parts. They live in this file
/// because Task 14's commit step names only `LimitsStoreTests.swift`.
@MainActor
final class ClaudePathAndAddAccountTests: XCTestCase {
    func testResolveAsksTheLoginShellAndTrimsThePath() async throws {
        let runner = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "/opt/homebrew/bin/claude \n", stderr: "")])
        let path = await ClaudePathResolver.resolve(runner: runner)
        XCTAssertEqual(path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(runner.invocations.map(\.executable), ["/bin/zsh"])
        XCTAssertEqual(runner.invocations.map(\.args), [["-lic", "command -v claude"]])
        XCTAssertEqual(ClaudePathResolver.detectionCommand, "/bin/zsh -lic 'command -v claude'")
    }

    /// A login shell prints its own noise first; the path is the LAST line.
    func testResolveTakesTheLastLine() async throws {
        let runner = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "nvm: loaded\n/usr/local/bin/claude\n", stderr: "")])
        let path = await ClaudePathResolver.resolve(runner: runner)
        XCTAssertEqual(path, "/usr/local/bin/claude")
    }

    func testResolveIsNilWhenNotFound() async throws {
        let notFound = MockRunnerBK(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "")])
        let nonPath = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "claude: aliased to foo\n", stderr: "")])
        let empty = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let thrown = ThrowingRunnerBK()
        var results: [String?] = []
        for runner in [notFound, nonPath, empty] as [CommandRunning] { results.append(await ClaudePathResolver.resolve(runner: runner)) }
        results.append(await ClaudePathResolver.resolve(runner: thrown))
        XCTAssertEqual(results.compactMap { $0 }, [], "non-zero exit, non-path output, empty output and a thrown error all read as 'not found'")
    }

    func testTerminalCommandQuotesDirAndPath() {
        XCTAssertEqual(
            AddAccountFlow.terminalCommand(dir: "/Users/a/.claude-accounts/my work", claudePath: "/opt/homebrew/bin/claude", subcommand: "auth login"),
            "CLAUDE_CONFIG_DIR='/Users/a/.claude-accounts/my work' '/opt/homebrew/bin/claude' auth login")
        XCTAssertEqual(
            AddAccountFlow.terminalCommand(dir: "/Users/a/.claude", claudePath: "/bin/claude"),
            "CLAUDE_CONFIG_DIR='/Users/a/.claude' '/bin/claude'", "no subcommand → no trailing space")
    }

    func testAppleScriptQuoteEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AddAccountFlow.appleScriptQuote(#"a"b\c"#), #""a\"b\\c""#)
    }

    /// A name with a path separator would escape ~/.claude-accounts; the flow
    /// must refuse it instead of creating a directory somewhere else.
    ///
    /// `.` and `..` are single path components and used to pass: `..` made the dir
    /// `$HOME`, `createDirectory` succeeded on it, and Terminal was handed
    /// `CLAUDE_CONFIG_DIR=$HOME claude auth login`. A dot-prefixed name passed too and
    /// then could never be discovered (`candidateDirs` skips dot-names), so a real
    /// sign-in reported "No sign-in detected in 10 minutes".
    func testBeginRejectsNamesThatAreNotASinglePathComponent() throws {
        let home = try Fixture.tempDir("addflow")
        let flow = AddAccountFlow(store: makeEmptyStore(home: home), home: home.path)
        for bad in ["", "   ", "../evil", "a/b", ".", "..", " .. ", ".work", "./x"] {
            flow.begin(folderName: bad, claudePath: "/bin/claude")
            XCTAssertEqual(flow.status, "Folder name must be a single path component and must not start with a dot",
                           "rejected: \(bad)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path + "/.claude-accounts"),
                       "nothing is created for a rejected name")
    }

    /// The same guard, without going near Terminal: a rejected name resolves to no
    /// directory at all, and an accepted one always lands under ~/.claude-accounts.
    func testAccountDirResolvesOnlyUnderTheAccountsRoot() {
        for bad in ["", "   ", "..", ".", "../evil", "a/b", ".hidden", "/etc"] {
            XCTAssertNil(AddAccountFlow.accountDir(forName: bad, home: "/Users/x"), "rejected: \(bad)")
        }
        XCTAssertEqual(AddAccountFlow.accountDir(forName: " work ", home: "/Users/x"),
                       "/Users/x/.claude-accounts/work")
    }

    /// Detection is STATE, not a value captured when the settings window was built.
    /// `Cmd-,` and the panel's ⚙ are live from the first frame while detection runs a
    /// `/bin/zsh -lic` login shell (10 s timeout), and the window is built once and
    /// cached — so Settings opened during that window showed the orange "Not found.
    /// Ran: …" for the rest of the session even though detection succeeded.
    func testDetectedPathIsObservableStateAndClearsTheConfigError() throws {
        let home = try Fixture.tempDir("detect")
        let store = makeEmptyStore(home: home)
        let notFound = "`claude` not found — set the path in Settings › General"

        XCTAssertEqual(store.claudeDetection, .pending)
        XCTAssertNil(store.claudeDetected)
        XCTAssertNil(BrowAppController.configError(override: nil, detection: store.claudeDetection),
                     "nothing is claimed while the login shell is still running")

        store.setClaudeDetection(.notFound)
        XCTAssertEqual(BrowAppController.configError(override: nil, detection: store.claudeDetection), notFound)

        // Detection lands late: Settings and the footer both follow it.
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        XCTAssertEqual(store.claudeDetected, "/opt/homebrew/bin/claude")
        XCTAssertNil(BrowAppController.configError(override: nil, detection: store.claudeDetection))

        // …or the user sets the path by hand, which also clears the banner.
        XCTAssertNil(BrowAppController.configError(override: "/usr/local/bin/claude", detection: .notFound))
        XCTAssertEqual(BrowAppController.configError(override: "   ", detection: .notFound), notFound,
                       "blank is not a path")
    }

    /// A rename typed and then "finished" by closing the settings window was silently
    /// discarded: the field committed on Return or focus loss only, and the window's
    /// SwiftUI tree — holding the typed text in `@State` — is torn down on close.
    func testPendingNameDraftSurvivesTheWindowTeardown() throws {
        let home = try Fixture.tempDir("drafts")
        let appDir = home.appendingPathComponent("app").path
        let store = makeEmptyStore(home: home)
        let drafts = SettingsDrafts()

        for keystroke in ["W", "Wo", "Wor", "Work"] { drafts.record(keystroke, for: "org-a") }
        XCTAssertNil(store.settings.accounts["org-a"]?.name, "nothing is written per keystroke")

        // What `windowWillClose` does before the teardown.
        XCTAssertTrue(drafts.flush(into: store))
        XCTAssertEqual(store.settings.accounts["org-a"]?.name, "Work")
        XCTAssertEqual(BrowSettingsStore(directory: appDir).load().accounts["org-a"]?.name, "Work",
                       "the persisted name is the last typed value")
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertFalse(drafts.flush(into: store), "a second close writes nothing")

        // Clearing the field back to blank removes the override rather than storing "".
        drafts.record("  ", for: "org-a")
        XCTAssertTrue(drafts.flush(into: store))
        XCTAssertNil(store.settings.accounts["org-a"]?.name)
        XCTAssertNil(BrowSettingsStore(directory: appDir).load().accounts["org-a"]?.name)
    }

    private func makeEmptyStore(home: URL) -> LimitsStore {
        let creds = NoCredsBK()
        let appDir = home.appendingPathComponent("app").path
        return LimitsStore(deps: .init(directory: AccountDirectory(home: home.path, credentials: creds),
                                       keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                                           claudePath: "/x/claude", allowPromptFallback: { false },
                                                           now: { Date() }),
                                       client: OAuthUsageClient(fetcher: NeverFetchBK(), appVersion: "t",
                                                                cacheSeconds: 30, backoffCap: 300, credentials: creds),
                                       snapshotStore: LimitSnapshotStore(directory: appDir),
                                       settingsStore: BrowSettingsStore(directory: appDir),
                                       now: { Date() }))
    }
}

private final class NoCredsBK: CredentialsReading, @unchecked Sendable {
    func token(configDir: String) -> ClaudeToken? { nil }
    func invalidate(configDir: String) {}
}

private final class NeverFetchBK: UsageFetching, @unchecked Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        XCTFail("no network in unit tests")
        return (Data(), 500)
    }
}

private final class ThrowingRunnerBK: CommandRunning, @unchecked Sendable {
    func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        throw GroveError.processFailed(command: executable, exitCode: -1, stderr: "boom")
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
