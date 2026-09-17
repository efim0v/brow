import Combine
import XCTest
import GroveCore
@testable import BrowKit

@MainActor
final class LimitsStoreTests: XCTestCase {
    /// `sink` cannot mutate a captured local, and the count has to survive the closure.
    private final class Counter { var value = 0 }

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
        /// Bearers whose NEXT request parks until `releaseAll()`. One account's fetch is
        /// held while the other lands (per-account publication), and a whole cycle is
        /// hung on it for the watchdog.
        private var heldBearers: Set<String> = []
        private var parked: [CheckedContinuation<Void, Never>] = []
        var responses: [String: (Data, Int)] {
            get { lock.withLock { scripted } }
            set { lock.withLock { scripted = newValue } }
        }
        var calls: [String] { lock.withLock { recorded } }
        /// Requests sitting in the gate right now — what a test waits on before it
        /// asserts "this cycle is still out".
        var parkedCalls: Int { lock.withLock { parked.count } }

        func holdNextCall(for bearer: String) { lock.withLock { _ = heldBearers.insert(bearer) } }

        /// Lets every parked request through and disarms the gate. Every test that holds
        /// one calls this: a continuation destroyed without a resume prints a runtime
        /// "leaked its continuation" warning and the output stops being pristine.
        func releaseAll() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                heldBearers.removeAll()
                let all = parked
                parked = []
                return all
            }
            waiting.forEach { $0.resume() }
        }

        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            // The answer is picked the moment the request goes out, not when the gate
            // opens: a held call has to come back with what the server would have said
            // then, which is what makes "a late result must not overwrite a newer one"
            // observable at all.
            let (park, response) = lock.withLock { () -> (Bool, (Data, Int)) in
                recorded.append(bearer)
                return (heldBearers.remove(bearer) != nil, scripted[bearer] ?? (Data("{}".utf8), 500))
            }
            if park {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { parked.append(continuation) }
                }
            }
            return response
        }
    }

    /// Drives `LimitsStore.Dependencies.sleep`: every sleeper parks until the test fires
    /// its exact interval, so the 240 s watchdog and the 5 s Keychain patience are
    /// reached in microseconds and no test depends on the wall clock.
    private final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [(seconds: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []

        var pending: [TimeInterval] { lock.withLock { waiters.map(\.seconds) } }

        var closure: @Sendable (TimeInterval) async -> Void {
            { [self] seconds in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { waiters.append((seconds, continuation)) }
                }
            }
        }

        func fire(_ seconds: TimeInterval) { resume { $0.seconds == seconds } }
        /// Whatever the test did not fire — an unresumed continuation is a runtime
        /// warning in the test log.
        func drain() { resume { _ in true } }

        private func resume(_ matches: ((seconds: TimeInterval, continuation: CheckedContinuation<Void, Never>)) -> Bool) {
            let hit = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                let matched = waiters.filter(matches).map(\.continuation)
                waiters.removeAll(where: matches)
                return matched
            }
            hit.forEach { $0.resume() }
        }
    }
    private final class Creds: CredentialsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var expiries: [String: Date] = [:]
        private var reads = 0
        /// The real Keychain blocks the calling thread behind a modal prompt; `holdReads`
        /// reproduces exactly that, synchronously, for the scan's `Task.detached`.
        private let gate = NSCondition()
        private var closed = false
        private var waiting = 0
        /// Config dirs whose NEXT read parks, one-shot. `holdReads` stops every scan at
        /// once; this stops ONE scan at a known point and lets a second one run past it
        /// to completion — which is the only way to order two overlapping scans.
        private var heldDirs: Set<String> = []
        /// Bumped by `releaseReads`, so a one-shot hold knows its release has happened.
        private var releaseEpoch = 0
        var expiry: [String: Date] {
            get { lock.withLock { expiries } }
            set { lock.withLock { expiries = newValue } }
        }
        /// How many times the "Keychain" was really consulted — the count the panel's
        /// prompt behaviour depends on.
        var readCount: Int { lock.withLock { reads } }
        /// Reads blocked in the gate right now.
        var parkedReads: Int { gate.lock(); defer { gate.unlock() }; return waiting }

        func holdReads() { gate.lock(); closed = true; gate.unlock() }
        func holdNextRead(for dir: String) { gate.lock(); heldDirs.insert(dir); gate.unlock() }
        func releaseReads() {
            gate.lock(); closed = false; heldDirs.removeAll(); releaseEpoch += 1
            gate.broadcast(); gate.unlock()
        }

        func token(configDir: String) -> ClaudeToken? {
            gate.lock()
            let held = heldDirs.remove(configDir) != nil
            if closed || held {
                let epoch = releaseEpoch
                waiting += 1
                while closed || (held && epoch == releaseEpoch) { gate.wait() }
                waiting -= 1
            }
            gate.unlock()
            return lock.withLock {
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

    private func makeStore(fetcher: Fetcher, creds: Creds, runner: CommandRunning = MockRunnerBK(results: []),
                           sleeper: Sleeper? = nil) -> LimitsStore {
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "t", cacheSeconds: 30, backoffCap: 300, credentials: creds)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { [clock] in clock.date })
        var deps = LimitsStore.Dependencies(directory: AccountDirectory(home: home.path, credentials: creds),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir),
                                            now: { [clock] in clock.date })
        if let sleeper { deps.sleep = sleeper.closure }
        return LimitsStore(deps: deps)
    }

    /// Polls a main-actor condition on the REAL clock (the injected one is frozen by
    /// design) while the store's tasks run. Every wait has a reason, so a timeout names
    /// what never happened instead of failing on an assertion three lines later.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Gives an abandoned cycle every chance to write before asserting that it did not.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
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

    /// The footer has room for ONE line, and while `claude` is missing that line is
    /// "`claude` not found": the cause, not the fetch failures it produces. Ranking the
    /// two errors by recency made the config error structurally unreachable — detection
    /// stamps it before the first refresh cycle can run, so any live fetch error was
    /// always newer and the user never saw the one thing they could act on. The config
    /// error can no longer go stale (BrowAppController.applyClaudeSettings clears it
    /// when a path is typed or detection lands late), so config-wins is safe.
    func testFooterShowsTheConfigErrorWhileItIsLiveAndTheFetchErrorOnceItClears() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 401)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertEqual(store.footerError, "Claude sign-in expired")
        XCTAssertEqual(store.panelError, "Claude sign-in expired", "with no config error, the fetch error shows")

        let notFound = "`claude` not found — set the path in Settings › General"
        store.setConfigError(notFound)
        XCTAssertEqual(store.panelError, notFound, "the cause outranks the symptom")

        // A NEWER fetch error is still only the symptom: `claude` is missing, and that
        // is what the user has to fix.
        now = t0.addingTimeInterval(600)
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 503)
        await store.refresh(force: true)
        XCTAssertEqual(store.footerError, "Anthropic returned HTTP 503")
        XCTAssertEqual(store.panelError, notFound, "a newer fetch error must not bury the config error")

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

    // MARK: - the bounded cycle

    /// A cycle that never comes back must not own the app. After `cycleWatchdog` the
    /// generation is retired, the flags clear, the footer says so — and the next trigger
    /// runs a clean cycle whose numbers the abandoned one can no longer overwrite.
    func testWatchdogAbandonsAHungCycleAndTheNextTriggerStartsFresh() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        let bearer = "Bearer tok-\(a)"
        fetcher.responses[bearer] = (body(five: 11, seven: 11), 200)
        let sleeper = Sleeper()
        addTeardownBlock { sleeper.drain(); fetcher.releaseAll() }
        let store = makeStore(fetcher: fetcher, creds: creds, sleeper: sleeper)

        fetcher.holdNextCall(for: bearer)
        let hung = Task { await store.refresh(force: true) }
        try await waitUntil("the cycle to park in the fetch") { fetcher.parkedCalls == 1 }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertTrue(store.isForcing)
        try await waitUntil("the watchdog to be armed") { sleeper.pending.contains(LimitsStore.cycleWatchdog) }
        sleeper.fire(LimitsStore.cycleWatchdog)
        await hung.value

        XCTAssertEqual(store.footerError, "Refresh timed out")
        XCTAssertFalse(store.isRefreshing, "the abandoned cycle no longer holds the flags")
        XCTAssertFalse(store.isForcing)
        XCTAssertNil(store.rows.first?.snapshot, "it published nothing")

        // The next trigger is not queued behind the cycle that timed out.
        fetcher.responses[bearer] = (body(five: 77, seven: 77), 200)
        now = t0.addingTimeInterval(60)
        await store.refresh(force: false)
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 77)
        XCTAssertNil(store.footerError)

        // The abandoned fetch finally returns: its generation is retired, so its 11 must
        // not land on top of the 77 the live cycle published.
        fetcher.releaseAll()
        try await waitUntil("the abandoned fetch to unwind") { fetcher.parkedCalls == 0 }
        await settle()
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 77,
                       "a retired generation writes nothing")
        XCTAssertEqual(store.dataAsOf, t0.addingTimeInterval(60), "and the age does not walk backwards")
    }

    /// One account's `doctor`/`-p` can take 210 s; the other account's number must not
    /// wait for it. Each result is applied the moment it lands.
    func testResultsArePublishedPerAccountAsTheyLand() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let b = try makeAccount(".claude-accounts/b", org: "org-b", email: "b@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600); creds.expiry[b] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        fetcher.responses["Bearer tok-\(b)"] = (body(five: 10, seven: 20), 200)
        addTeardownBlock { fetcher.releaseAll() }
        let store = makeStore(fetcher: fetcher, creds: creds)

        fetcher.holdNextCall(for: "Bearer tok-\(b)")
        let cycle = Task { await store.refresh(force: false) }
        try await waitUntil("account A's number to reach the panel") {
            store.rows.first { $0.id == "org-a" }?.snapshot != nil
        }
        XCTAssertTrue(store.isRefreshing, "B is still out")
        XCTAssertEqual(store.rows.first { $0.id == "org-a" }?.snapshot?.fiveHour?.usedPercentage, 40)
        XCTAssertNil(store.rows.first { $0.id == "org-b" }?.snapshot, "B has not landed yet")
        XCTAssertEqual(store.dataAsOf, t0, "the age counts from the result that DID land")

        fetcher.releaseAll()
        await cycle.value
        XCTAssertEqual(store.rows.first { $0.id == "org-b" }?.snapshot?.fiveHour?.usedPercentage, 10)
        XCTAssertFalse(store.isRefreshing)
    }

    /// The Keychain can park a scan behind a modal prompt for as long as it likes. After
    /// `keychainPatience` the cycle says so and carries on with the accounts it already
    /// knows; when the scan lands, its result is applied and the message goes.
    func testScanPatienceSurfacesWaitingAndContinuesWithLastAccounts() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        let sleeper = Sleeper()
        addTeardownBlock { sleeper.drain(); creds.releaseReads() }
        let store = makeStore(fetcher: fetcher, creds: creds, sleeper: sleeper)
        await store.refresh(force: false)
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 40)
        XCTAssertEqual(store.keychainState, .ok)

        creds.holdReads()
        now = t0.addingTimeInterval(300)
        let blocked = Task { await store.refresh(force: false) }
        try await waitUntil("the scan to park in the Keychain") { creds.parkedReads > 0 }
        try await waitUntil("the patience timer to be armed") { sleeper.pending.contains(LimitsStore.keychainPatience) }
        sleeper.fire(LimitsStore.keychainPatience)
        try await waitUntil("the wait to reach the panel") { store.keychainState == .waiting }

        XCTAssertEqual(store.footerError, "Waiting for Keychain access…")
        XCTAssertEqual(store.rows.map(\.id), ["org-a"], "the cycle continues with the last known accounts")
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 40, "with their last numbers")

        creds.releaseReads()
        await blocked.value
        try await waitUntil("the late scan to be applied") { store.keychainState == .ok }
        XCTAssertNil(store.footerError, "the message clears when the scan returns")
        XCTAssertEqual(store.rows.first?.tokenStatus, "fresh · 55 min")
    }

    /// A scan that comes back with no token for every account that had one is the
    /// Keychain refusing us — not every account signing out at once. And the verdict
    /// has to SURVIVE the next cycle: the denial leaves the account list tokenless, so a
    /// verdict judged against the previous scan alone decays to `.ok` one poll later and
    /// takes the only actionable message off the screen while the denial is still live.
    func testAScanThatLosesEveryTokenReadsAsKeychainDenied() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)
        XCTAssertEqual(store.keychainState, .ok)

        creds.expiry = [:]                                  // every read now comes back empty
        now = t0.addingTimeInterval(300)
        await store.refresh(force: false)
        XCTAssertEqual(store.keychainState, .denied)
        XCTAssertEqual(store.rows.first?.tokenStatus, "Keychain access denied")
        XCTAssertEqual(store.footerError, "Keychain access denied — grant it in Keychain Access")
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 40, "the last numbers stay on screen")

        // The steady state, 60 s later: still denied, still saying so.
        now = t0.addingTimeInterval(600)
        await store.refresh(force: false)
        XCTAssertEqual(store.keychainState, .denied, "the verdict does not decay on the next cycle")
        XCTAssertEqual(store.rows.first?.tokenStatus, "Keychain access denied")
        XCTAssertEqual(store.footerError, "Keychain access denied — grant it in Keychain Access")

        // And it is not permanent: the first scan that gets a token back clears it.
        now = t0.addingTimeInterval(900)
        creds.expiry[a] = now.addingTimeInterval(3600)
        await store.refresh(force: false)
        XCTAssertEqual(store.keychainState, .ok)
        XCTAssertEqual(store.rows.first?.tokenStatus, "fresh · 1 h")
        XCTAssertNil(store.footerError)
    }

    /// `BrowAppController` arms the poll timer BEFORE it calls `bootstrap`, so
    /// bootstrap's scan and a cycle's scan can sit in the Keychain at the same time —
    /// and bootstrap's is the one parked behind the first-run prompt. Its answer is then
    /// the OLDER one: applying it would restore a stale account list and judge the
    /// Keychain against a baseline the cycle has already replaced.
    func testBootstrapDropsItsScanWhenACycleHasMovedOn() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let b = try makeAccount(".claude-accounts/b", org: "org-b", email: "b@x")
        let creds = Creds()
        creds.expiry[a] = t0.addingTimeInterval(3600)
        creds.expiry[b] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        fetcher.responses["Bearer tok-\(b)"] = (body(five: 10, seven: 20), 200)
        // Never fired: the patience must not expire here, or bootstrap would take the
        // late-apply path instead of returning its own (stale) answer.
        let sleeper = Sleeper()
        addTeardownBlock { sleeper.drain(); creds.releaseReads() }
        let store = makeStore(fetcher: fetcher, creds: creds, sleeper: sleeper)

        // Dirs are read in name order: bootstrap's scan reads a's token (1 h), then
        // parks on b's for as long as the test likes.
        creds.holdNextRead(for: b)
        let boot = Task { await store.bootstrap() }
        try await waitUntil("bootstrap's scan to park in the Keychain") { creds.parkedReads == 1 }

        // A whole cycle runs to completion while bootstrap is parked, and reads a's
        // token as it is NOW.
        creds.expiry[a] = t0.addingTimeInterval(9 * 3600)
        await store.refresh(force: false)
        XCTAssertEqual(store.rows.first?.tokenStatus, "fresh · 9 h")

        // Bootstrap's scan finally returns, carrying the 1 h it read before the cycle.
        creds.releaseReads()
        await boot.value
        await settle()
        XCTAssertEqual(store.rows.first?.tokenStatus, "fresh · 9 h", "the superseded scan writes nothing")
        XCTAssertEqual(store.rows.map(\.id), ["org-a", "org-b"])
        XCTAssertEqual(store.keychainState, .ok)
        XCTAssertNil(store.footerError)
    }

    /// The first scan is the one the first-run Keychain prompt parks, and until Task 6
    /// arms the poll timer nothing else would say so: bootstrap is bounded by the same
    /// patience as a cycle, and the late answer still lands when the prompt is answered.
    func testBootstrapSurfacesTheWaitOnTheFirstRun() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let sleeper = Sleeper()
        addTeardownBlock { sleeper.drain(); creds.releaseReads() }
        let store = makeStore(fetcher: Fetcher(), creds: creds, sleeper: sleeper)

        creds.holdReads()
        let boot = Task { await store.bootstrap() }
        try await waitUntil("the scan to park in the Keychain") { creds.parkedReads > 0 }
        try await waitUntil("bootstrap's patience timer to be armed") {
            sleeper.pending.contains(LimitsStore.keychainPatience)
        }
        sleeper.fire(LimitsStore.keychainPatience)
        await boot.value
        XCTAssertEqual(store.keychainState, .waiting, "bootstrap does not wait silently")
        XCTAssertEqual(store.footerError, "Waiting for Keychain access…")

        creds.releaseReads()
        try await waitUntil("the late scan to be applied") { store.keychainState == .ok }
        XCTAssertEqual(store.rows.map(\.id), ["org-a"])
        XCTAssertEqual(store.rows.first?.tokenStatus, "fresh · 1 h")
        XCTAssertNil(store.footerError, "the message clears when the scan returns")
    }

    /// 401/403 is the server's word on the token and it outranks `expiresAt`: a token
    /// with five hours of nominal life left still gets one forced `doctor` on the cycle
    /// after the rejection.
    func testAuthRejectionForcesAKeeperAttemptNextCycle() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(5 * 3600)
        let runner = MockRunnerBK(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (Data(), 401)
        let store = makeStore(fetcher: fetcher, creds: creds, runner: runner)

        await store.refresh(force: false)
        XCTAssertEqual(store.footerError, "Claude sign-in expired")
        XCTAssertTrue(runner.invocations.isEmpty, "a token with 5 h of life is not refreshed on its own")

        now = t0.addingTimeInterval(60)
        await store.refresh(force: true)
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]], "the rejection forced one attempt")
        XCTAssertEqual(store.rows.first?.tokenStatus, "sign-in revoked")
    }

    /// The first frame after a relaunch shows the last real numbers, labelled with the
    /// right account and in the order the user last saw — before the scan's Keychain
    /// reads have returned anything.
    func testInitSeedsAccountsFromThePersistedFile() async throws {
        let old = LimitSnapshot(organizationUuid: "org-a", fetchedAt: t0.addingTimeInterval(-7200),
                                fiveHour: CapturedWindow(usedPercentage: 33, resetsAt: nil),
                                sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        let first = DiscoveredAccount(organizationUuid: "org-a", email: "a@x", tier: "default_claude_max_20x",
                                      configDir: "/dir-a", aliasDirs: [], tokenExpiresAt: t0)
        let second = DiscoveredAccount(organizationUuid: "org-b", email: "b@x", tier: nil,
                                       configDir: "/dir-b", aliasDirs: [], tokenExpiresAt: t0)
        try LimitSnapshotStore(directory: appDir).saveFile(
            LimitsFile(snapshots: ["org-a": old],
                       accounts: [PersistedAccount(from: second, order: 1), PersistedAccount(from: first, order: 0)]))

        let creds = Creds()
        let store = makeStore(fetcher: Fetcher(), creds: creds)
        XCTAssertEqual(store.rows.map(\.name), ["a@x", "b@x"], "seeded in the persisted display order")
        XCTAssertEqual(store.rows.first?.snapshot?.fiveHour?.usedPercentage, 33)
        XCTAssertEqual(store.rows.first?.status, .stale, "with their real age, not a pretend-fresh one")
        XCTAssertEqual(store.dataAsOf, t0.addingTimeInterval(-7200))
        XCTAssertEqual(creds.readCount, 0, "the seed costs no Keychain read")
        XCTAssertEqual(store.rows.first?.tokenStatus, "no token",
                       "the seed carries no token facts; the scan fills them in")
    }

    /// The 5 s ticker runs forever. A tick that changes nothing must publish nothing, or
    /// the panel re-renders twelve times a minute for no reason.
    func testTickPublishesOnlyOnChange() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        fetcher.responses["Bearer tok-\(a)"] = (body(five: 40, seven: 60), 200)
        let store = makeStore(fetcher: fetcher, creds: creds)
        await store.refresh(force: false)

        let counter = Counter()
        let subscription = store.objectWillChange.sink { _ in counter.value += 1 }
        defer { subscription.cancel() }

        store.tick(); store.tick(); store.tick()
        XCTAssertEqual(counter.value, 0, "a frozen clock changes nothing")

        now = t0.addingTimeInterval(LimitSnapshot.staleAfter + 1)
        store.tick()
        XCTAssertEqual(counter.value, 1, "the stale flip publishes once")
        XCTAssertEqual(store.rows.first?.status, .stale)
        XCTAssertTrue(store.aggregate.stale)

        store.tick()
        XCTAssertEqual(counter.value, 1, "and nothing more while nothing moves")
    }

    /// Spec: ⟳ is disabled only while a FORCED fetch is running. A background poll is in
    /// flight for most of every minute; it must never take the button away.
    func testIsForcingIsTheOnlyRefreshGate() async throws {
        let a = try makeAccount(".claude-accounts/a", org: "org-a", email: "a@x")
        let creds = Creds(); creds.expiry[a] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        let bearer = "Bearer tok-\(a)"
        fetcher.responses[bearer] = (body(five: 1, seven: 1), 200)
        addTeardownBlock { fetcher.releaseAll() }
        let store = makeStore(fetcher: fetcher, creds: creds)

        fetcher.holdNextCall(for: bearer)
        let background = Task { await store.refresh(force: false) }
        try await waitUntil("the background cycle to be out") { fetcher.parkedCalls == 1 }
        XCTAssertTrue(store.isRefreshing, "a cycle IS running")
        XCTAssertFalse(store.isForcing, "…and the ⟳ button stays live")
        fetcher.releaseAll()
        await background.value

        now = t0.addingTimeInterval(60)
        fetcher.holdNextCall(for: bearer)
        let forced = Task { await store.refresh(force: true) }
        try await waitUntil("the forced cycle to be out") { fetcher.parkedCalls == 1 }
        XCTAssertTrue(store.isForcing, "only the forced one gates the button")
        fetcher.releaseAll()
        await forced.value
        XCTAssertFalse(store.isForcing)
        XCTAssertFalse(store.isRefreshing)
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
