import Foundation
import GroveCore

public enum AccountStatus: Sendable, Equatable {
    case ok
    /// Last snapshot older than `LimitSnapshot.staleAfter`, last fetch fine.
    case stale
    /// Last fetch failed; the snapshot (if any) is retained and still shown.
    case error(String)
}

public struct AccountRow: Sendable, Equatable, Identifiable {
    public var id: String { account.organizationUuid }
    public let account: DiscoveredAccount
    public let name: String
    public let snapshot: LimitSnapshot?
    public let status: AccountStatus
    public let tokenStatus: String
    /// The next (estimated) subscription renewal — see `SubscriptionInfo.nextRenewal`.
    public let renewsAt: Date?

    public init(account: DiscoveredAccount, name: String, snapshot: LimitSnapshot?, status: AccountStatus,
                tokenStatus: String, renewsAt: Date? = nil) {
        self.account = account
        self.name = name
        self.snapshot = snapshot
        self.status = status
        self.tokenStatus = tokenStatus
        self.renewsAt = renewsAt
    }
}

/// What auto-detection has to say about the `claude` binary. Three states, not an
/// optional: "still looking" and "looked, and it is not there" must not render the
/// same. Detection runs a `/bin/zsh -lic` login shell with a 10 s timeout, while
/// `Cmd-,` and the panel's ⚙ are live from the first frame.
public enum ClaudeDetection: Sendable, Equatable {
    case pending
    case found(String)
    case notFound
}

/// Single source of truth for everything the ears, the panel and the settings
/// window show. One refresh cycle, several triggers (see RefreshTriggers).
@MainActor
public final class LimitsStore: ObservableObject {
    public struct Dependencies: Sendable {
        public var directory: AccountDirectory
        public var keeper: TokenKeeper
        public var client: OAuthUsageClient
        public var snapshotStore: LimitSnapshotStore
        public var settingsStore: BrowSettingsStore
        public var now: @Sendable () -> Date
        /// The cycle's two deadlines (watchdog, Keychain patience) go through here so
        /// tests reach 240 s and 5 s in microseconds and never sleep for real.
        public var sleep: @Sendable (TimeInterval) async -> Void
        /// Fetch accounts one after another (oldest reading first) instead of all at
        /// once. Required when the client's bucket is shared across accounts.
        public var sequentialFetch: Bool
        /// `api/oauth/profile`, for the subscription facts. nil: never asked (tests).
        public var profileClient: OAuthProfileClient?
        /// Claude Code's own statusline captures — see `StatuslineCaptures`. nil: none.
        public var statusline: StatuslineCaptures?
        public init(directory: AccountDirectory, keeper: TokenKeeper, client: OAuthUsageClient,
                    snapshotStore: LimitSnapshotStore, settingsStore: BrowSettingsStore,
                    now: @escaping @Sendable () -> Date,
                    sleep: @escaping @Sendable (TimeInterval) async -> Void = Dependencies.realSleep,
                    sequentialFetch: Bool = false, profileClient: OAuthProfileClient? = nil,
                    statusline: StatuslineCaptures? = nil) {
            self.directory = directory; self.keeper = keeper; self.client = client
            self.snapshotStore = snapshotStore; self.settingsStore = settingsStore; self.now = now
            self.sleep = sleep
            self.sequentialFetch = sequentialFetch
            self.profileClient = profileClient
            self.statusline = statusline
        }

        /// Cancellation is how the winner of a race stops the loser, and it is not a
        /// failure: the deadline simply stops mattering.
        public static let realSleep: @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    /// What the Keychain is doing to us right now. Three states, not a flag: "still
    /// waiting for the prompt" and "the prompt was refused" are different problems with
    /// different fixes, and neither of them is "this account has no token".
    public enum KeychainState: Sendable, Equatable { case ok, waiting, denied }

    /// A cycle still running after this is abandoned (spec, The cycle §1).
    ///
    /// It has to be strictly LARGER than everything one account's turn can legitimately
    /// spend, or a slow-but-working account is abandoned every cycle forever: the
    /// watchdog retires the generation, every result of that cycle is dropped by
    /// `cycle == generation`, and the panel shows "Refresh timed out" over ageing
    /// numbers with no way out. The spec's table says 240 s from `doctor` 90 + `-p` 120;
    /// the real worst case has four more terms in it:
    ///
    ///     keychainPatience                       5
    ///     doctor  (timeout + SIGKILL + drain)   90 + 0.5 + 2
    ///     -p      (timeout + SIGKILL + drain)  120 + 0.5 + 2
    ///     usage   (request timeout, ×2 — the client retries once on 401/403)  2 × 15
    ///     ------------------------------------------------------------------------
    ///                                                                        250
    ///
    /// 270 leaves 20 s of scheduling slack on top. `testTheCycleWatchdogOutlastsEveryDeadlineInsideIt`
    /// recomputes this sum from the constants themselves, so no later timeout change can
    /// quietly reintroduce the gap.
    public static let cycleWatchdog: TimeInterval = 270
    /// How long a cycle waits for `AccountDirectory.scan` before carrying on with the
    /// accounts it already knows (spec, The cycle §3).
    public static let keychainPatience: TimeInterval = 5

    static let waitingMessage = "Waiting for Keychain access…"
    static let deniedMessage = "Keychain access needed — press the key on the account"
    static let timedOutMessage = "Refresh timed out"

    // The four derived values are published BY HAND (`recompute`), not with `@Published`:
    // the 5 s staleness ticker recomputes all four on every tick, and a per-property
    // publisher would send one notification per assignment — three per changed tick and
    // one per unchanged one — while the panel re-renders on every notification.
    /// Visible accounts only — what the ears and the panel show.
    public private(set) var rows: [AccountRow] = []
    /// Every discovered account, hidden ones included. Settings lists these, so a
    /// hidden account can be un-hidden again.
    public private(set) var allRows: [AccountRow] = []
    public private(set) var aggregate: LimitsAggregate
    /// Newest `fetchedAt` across visible accounts; nil until any fetch succeeded.
    public private(set) var dataAsOf: Date?
    /// Set only when NO visible account succeeded in the last cycle.
    @Published public private(set) var footerError: String?
    /// A configuration problem that no fetch can fix — today only "`claude` not
    /// found", which the spec's error table puts in BOTH settings and the panel
    /// footer. See `panelError` for which of the two the one-line footer shows.
    @Published public private(set) var configError: String?
    /// What auto-detection found. Published, because Settings can be opened before
    /// detection returns and that window is built once and cached — a detected path
    /// captured at construction stayed nil for the life of the process.
    @Published public private(set) var claudeDetection: ClaudeDetection = .pending
    /// Any cycle is running. Disables the ⟳ button; does NOT drive the spinner.
    @Published public private(set) var isRefreshing = false
    /// A FORCED fetch is running. The spec's spinner rule (design.md) is about this
    /// one only — a background poll must not take the refresh button away.
    @Published public private(set) var isForcing = false
    /// What the last scan learned about the Keychain. Drives the account rows' token
    /// slot and, when no account can fetch, the footer.
    @Published public private(set) var keychainState: KeychainState = .ok
    /// Network reachability as `RefreshTriggers`' path monitor sees it.
    @Published public private(set) var isOnline = true
    /// When the forced refresh the user asked for will actually be sent, while the
    /// endpoint's rate limit holds it back; nil when nothing is queued. The footer
    /// counts down to it and the ⟳ button shows its spinner until then.
    @Published public private(set) var pendingRetryAt: Date?
    private var retryTask: Task<Void, Never>?
    private var retryRounds = 0
    @Published public var settings: BrowSettings {
        didSet {
            do { try deps.settingsStore.save(settings) }
            catch { BrowLog.limits.error("settings save failed: \(String(describing: error), privacy: .public)") }
            recompute()
        }
    }

    /// The path auto-detection found, or nil while it is pending / found nothing.
    public var claudeDetected: String? {
        if case .found(let path) = claudeDetection { return path }
        return nil
    }

    /// The single line the panel footer has room for: the configuration error while it
    /// is set, the fetch error otherwise. The config error is the CAUSE — with `claude`
    /// missing, every fetch error is a symptom of it, and the missing binary is the one
    /// thing the user can act on. Ranking the two by recency instead made the config
    /// error unreachable: detection stamps it before the first refresh cycle can run,
    /// so a live fetch error was always newer. This ordering is only safe because the
    /// config error can no longer go stale — `BrowAppController.applyClaudeSettings`
    /// clears it when a path is typed into Settings or detection lands late.
    public var panelError: String? { configError ?? footerError }

    private let deps: Dependencies
    private var accounts: [DiscoveredAccount] = []
    private var snapshots: [String: LimitSnapshot]
    private var lastError: [String: String] = [:]
    private var tokenOutcome: [String: TokenRefreshOutcome] = [:]
    /// The one cycle allowed to be in flight. Overlapping cycles let an older
    /// capture overwrite a newer one (dataAsOf walking backwards, a cleared
    /// footerError resurrecting) and clear the spinner while a fetch is still out.
    private var inFlight: Task<Void, Never>?
    /// The one account scan allowed to be in flight, with the `extraDirs` it was started
    /// for and an id the task uses to clear this slot only if it is still its own. See
    /// `liveScan()`: two overlapping scans are two Keychain prompts per account.
    private var scanInFlight: (extraDirs: [String], id: Int, task: Task<[DiscoveredAccount], Never>)?
    /// Scans started, ever — the id `scanInFlight` is stamped with.
    private var scanCount = 0
    /// Bumped at the top of every cycle; a cycle whose generation has moved on drops
    /// its results instead of writing them.
    private var generation = 0
    /// Accounts the server answered 401/403 for. The NEXT cycle spends one forced
    /// refresh attempt on them (spec, The cycle §4) and the flag is cleared there.
    private var authRejected: [String: Bool] = [:]
    /// What the cycle currently in flight has heard back, keyed by organisation. Reset
    /// at the top of each cycle; the footer is computed from it in DISCOVERY order.
    private var cycleResults: [String: FetchResult] = [:]
    /// What the cycle is waiting on, for the watchdog's log line.
    private var phase: CyclePhase = .idle
    /// Every organisation a scan has EVER handed a token for. The Keychain verdict is
    /// judged against this, not against the last scan: a denied scan leaves `accounts`
    /// tokenless, so a verdict judged against the previous scan alone is edge-triggered —
    /// it says `.denied` for one cycle and `.ok` from the next one on, taking the one
    /// message that tells the user how to fix it off the screen 60 s after it went up.
    private var everHadTokens: Set<String> = []

    /// NO I/O beyond the persisted snapshot file: `AccountDirectory.scan` reads one
    /// Keychain item per config dir, and on a new bundle id macOS puts a modal prompt
    /// in front of each one. Doing that here parked the main thread before the panel
    /// existed — no ears, no footer error slot, no working Cmd-Q. Discovery happens in
    /// `bootstrap()`, after the first frame is on screen.
    ///
    /// The accounts saved beside the snapshots ARE read here: they cost no Keychain
    /// access, and without them the first frame has numbers it cannot label, so the
    /// panel came up blank until the scan returned (spec, The cycle §5).
    public init(deps: Dependencies) {
        self.deps = deps
        self.settings = deps.settingsStore.load()
        let file = deps.snapshotStore.loadFile()
        self.snapshots = file.snapshots
        self.subscriptions = file.subscriptions
        self.aggregate = LimitsAggregate.compute(accounts: [], snapshots: [:], now: deps.now())
        self.accounts = file.accounts.sorted { $0.order < $1.order }.map(\.discovered)
        // The Keychain verdict needs evidence that OUTLIVES the process. `everHadTokens`
        // is filled by successful scans, and a denial already in force at launch makes
        // every scan of that process tokenless — so without this seed `.denied` needed a
        // successful scan earlier in the SAME run, and a relaunch under a standing denial
        // (Brow ships with Launch at login: the normal way the user meets this state)
        // showed "no token" plus a generic fetch error instead of the one message that
        // says what to do. The trade-off is deliberate and one-sided: an account that
        // genuinely signed out but left its dir on disk reads `.denied` until the first
        // scan that answers for some other account, which is a wrong sentence; showing
        // nothing actionable while the Keychain is refusing us is a wrong app.
        self.everHadTokens = Set(file.accounts.filter(\.hadToken).map(\.organizationUuid))
        recompute()
    }

    /// First account discovery. Call AFTER the panel is visible: the persisted
    /// snapshots are already on screen, so the Keychain prompts are answered by a
    /// user who can see the app they belong to.
    ///
    /// This is the scan most likely to be parked behind a prompt (it is the first one),
    /// and the poll timer is already armed by the time it runs — so it SHARES that
    /// cycle's scan (`liveScan`) rather than issuing a second set of Keychain reads, it
    /// is bounded by the same patience as a cycle's scan, and its answer is dropped if a
    /// cycle has since scanned. Writing an older account list over a newer one would
    /// also judge the Keychain against the wrong baseline.
    public func bootstrap() async {
        let gate = generation
        let discovered = await scanWithPatience(gate: gate)
        guard gate == generation else {
            BrowLog.limits.info("bootstrap scan superseded by a refresh cycle; dropped")
            return
        }
        guard let discovered else { return }    // the patience path applies it late
        applyScan(discovered)
        BrowLog.limits.info("discovered \(discovered.count, privacy: .public) account(s)")
    }

    /// The clock-driven half of freshness: ages, the stale flag and the grey dot follow
    /// the 5 s ticker, with no network and no Keychain. Publishes only when something
    /// actually moved, so a panel that is up all day re-renders when the numbers change
    /// and not twelve times a minute (spec, The cycle §6).
    public func tick() { recompute() }

    /// Reachability, pushed in by `RefreshTriggers`' path monitor.
    public func markOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        BrowLog.limits.info("network is \(online ? "up" : "down", privacy: .public)")
    }

    /// The `claude` binary could not be found (or the configured path is wrong).
    /// Shown in the panel footer as well as Settings › General (spec, Error handling).
    /// Passing nil clears it — a path typed into Settings, or a detection that lands
    /// after the banner went up, has to take the banner back off the screen.
    public func setConfigError(_ text: String?) {
        guard text != configError else { return }
        configError = text
    }

    /// The result of auto-detection, once it has one.
    public func setClaudeDetection(_ detection: ClaudeDetection) { claudeDetection = detection }

    public func refreshIfOlderThan(_ seconds: TimeInterval) async {
        let now = deps.now()
        if let asOf = dataAsOf, now.timeIntervalSince(asOf) < seconds { return }
        await refresh(force: false)
    }

    /// One cycle at a time. A `force: false` caller joins the cycle already running
    /// instead of starting a second; a `force: true` caller queues behind it, so the
    /// newest data always wins the write. A full cycle can take 210 s (doctor 90 s +
    /// `-p` 120 s) while the 60 s expanded timer keeps firing — overlap is the normal
    /// case, not a coincidence.
    public func refresh(force: Bool) async {
        if !force, let running = inFlight {
            await running.value
            return
        }
        let previous = inFlight
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.runCycle(force: force)
        }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    /// `AccountDirectory.scan` blocks on the Keychain; it must never run on the main
    /// actor, where a modal prompt would freeze the whole UI.
    private static func scanTask(_ directory: AccountDirectory, extraDirs: [String]) -> Task<[DiscoveredAccount], Never> {
        Task.detached { directory.scan(extraDirs: extraDirs) }
    }

    /// The scan already in flight for these dirs, or a new one. Discovery is
    /// single-flight because every scan reads one Keychain item per config dir, and on a
    /// new bundle id macOS puts a modal prompt in front of each read: the poll timer is
    /// armed before `bootstrap()` runs (spec, The cycle §8), so those two overlap by
    /// design, and a second scan issued while the first is parked on that prompt asks
    /// the user a second time for every account. `CachingCredentialsReader` cannot
    /// dedupe them — it fills its cache when a read RETURNS, and a read parked on a
    /// prompt has not returned.
    ///
    /// Keyed on `extraDirs`: a scan started before a dir was typed into Settings never
    /// looked at that dir and cannot answer for it.
    private func liveScan() -> Task<[DiscoveredAccount], Never> {
        let dirs = settings.extraDirs
        if let live = scanInFlight, live.extraDirs == dirs {
            BrowLog.limits.info("joining the account scan already in flight")
            return live.task
        }
        scanCount += 1
        let id = scanCount
        let directory = deps.directory
        // The slot is emptied by the task ITSELF, before it publishes its value, so a
        // caller that arrives after the scan finished starts a fresh one rather than
        // joining a task whose accounts are already history.
        let task = Task { @MainActor [weak self] in
            let scanned = await Self.scanTask(directory, extraDirs: dirs).value
            if let self, self.scanInFlight?.id == id { self.scanInFlight = nil }
            return scanned
        }
        scanInFlight = (dirs, id, task)
        return task
    }

    /// One discovery scan, bounded by `keychainPatience` (spec, The cycle §3). Returns
    /// the accounts when the Keychain answers in time. When it does not, the caller is
    /// released with nil — the wait is on screen and the caller carries on with the
    /// accounts it already has — and the late answer is applied here, once, if `gate` is
    /// still the current generation when it lands.
    private func scanWithPatience(gate: Int) async -> [DiscoveredAccount]? {
        let scan = liveScan()
        if let scanned = await firstResult(of: scan, within: Self.keychainPatience) { return scanned }
        guard gate == generation else { return nil }
        setKeychainState(.waiting)
        setFooterError(Self.waitingMessage)
        BrowLog.limits.error("""
            account scan still blocked after \(Self.keychainPatience, privacy: .public) s — \
            continuing with \(self.accounts.count, privacy: .public) known account(s)
            """)
        // Not abandoned: when the Keychain finally answers, the result is applied (if
        // this generation is still the current one) and the message goes.
        Task { @MainActor [weak self] in
            let late = await scan.value
            guard let self, gate == self.generation else { return }
            self.applyScan(late)
            self.updateFooter()
        }
        return nil
    }

    /// One bounded cycle. The body runs as its own task and is raced against the
    /// watchdog; when the watchdog wins, the generation is retired (everything the body
    /// still writes is dropped), the flags come off and the footer says so. The body is
    /// NOT cancelled: a `claude doctor` we cannot interrupt safely is left to unwind on
    /// its own, it simply stops being able to speak for the app.
    private func runCycle(force: Bool) async {
        generation += 1
        let cycle = generation
        isRefreshing = true
        if force { isForcing = true }
        phase = .scanning
        let body = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cycleBody(cycle: cycle, force: force)
        }
        if await firstResult(of: body, within: Self.cycleWatchdog) == nil {
            BrowLog.limits.error("""
                refresh timed out after \(Self.cycleWatchdog, privacy: .public) s, \
                waiting on \(self.phase.text, privacy: .public)
                """)
            generation += 1                     // retire it: its late writes are dropped
            // "Refresh timed out" is the right sentence only when nothing better is
            // known. A cycle parked behind an UNANSWERED Keychain dialog times out by
            // construction, and overwriting "Waiting for Keychain access…" with a
            // timeout tells the user the wrong thing — permanently, if the dialog is
            // never answered, since every later cycle times out the same way.
            if keychainState == .ok { setFooterError(Self.timedOutMessage) } else { updateFooter() }
        }
        phase = .idle
        isRefreshing = false
        if force { isForcing = false }
    }

    /// Once per process: hand the client the persisted readings' timestamps so a
    /// relaunch inside the endpoint's refill window does not spend a request per
    /// account on numbers it already has.
    private var clientSeeded = false
    private func seedClientIfNeeded() async {
        guard !clientSeeded else { return }
        clientSeeded = true
        for account in accounts {
            guard let snap = snapshots[account.organizationUuid] else { continue }
            await deps.client.seedLastSuccess(configDir: account.configDir, at: snap.fetchedAt)
        }
    }

    private func cycleBody(cycle: Int, force: Bool) async {
        await seedClientIfNeeded()
        // 0. A forced cycle means the user just did something — pressed ⟳, woke the
        //    Mac, came back on to Wi-Fi, finished `claude auth login`. That is the only
        //    moment a credential the Keychain refused us ten minutes ago can plausibly
        //    have changed, and `CachingCredentialsReader`'s nil floor answers "nothing
        //    here" for 600 s BEFORE any request — so without this the footer's own
        //    advice ("grant it in Keychain Access") did nothing for up to ten minutes
        //    and ⟳ was, by the user's reckoning, dead. The 60 s background poll is
        //    untouched: it still never re-raises a prompt the user declined.
        if force { invalidateCredentials() }
        // 1. Discovery. The Keychain can hold this behind a modal prompt for minutes;
        //    after `keychainPatience` the cycle says so and carries on with what it has.
        let scanned = await scanWithPatience(gate: cycle)
        guard cycle == generation else { return }
        if let scanned { applyScan(scanned) }
        // The rows (names, tiers, persisted values with their real age) are worth
        // showing before the network answers.
        recompute()

        // 2. Fetch. Every account's result is applied the moment it lands: one
        //    account's `doctor` (90 s) plus `-p` (120 s) must not hold another
        //    account's number off the screen.
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }
        let rejected = authRejected
        authRejected.removeAll()
        cycleResults = [:]
        var outstanding = visible.map(\.organizationUuid)
        phase = .fetching(outstanding)
        if deps.sequentialFetch {
            // One bucket for every account (the endpoint's limit is per user, not per
            // token): the second request has to SEE the first one's success, or both go
            // out together and the second is refused. Oldest reading first, so the
            // accounts take turns at the window.
            let ordered = visible.sorted {
                (snapshots[$0.organizationUuid]?.fetchedAt ?? .distantPast)
                    < (snapshots[$1.organizationUuid]?.fetchedAt ?? .distantPast)
            }
            for account in ordered {
                let result = await Self.fetch(deps: deps, account: account, force: force,
                                              forceAttempt: rejected[account.organizationUuid] ?? false)
                guard cycle == generation else { return }
                handle(result, outstanding: &outstanding)
            }
        } else {
            await withTaskGroup(of: FetchResult.self) { group in
                for account in visible {
                    let forceAttempt = rejected[account.organizationUuid] ?? false
                    group.addTask { [deps] in
                        await Self.fetch(deps: deps, account: account, force: force, forceAttempt: forceAttempt)
                    }
                }
                for await result in group {
                    // A superseded cycle drops the rest of its results rather than
                    // writing older numbers over newer ones.
                    guard cycle == generation else { continue }
                    handle(result, outstanding: &outstanding)
                }
            }
        }
        guard cycle == generation else { return }
        // 3. Whatever the endpoint said, the account's own sessions may have said
        //    something newer: their statusline captures cost nothing and outrun a
        //    token whose bucket those very sessions keep empty.
        await applyStatuslineCaptures(visible, cycle: cycle)
        guard cycle == generation else { return }
        // A forced cycle the rate limit held back re-queues itself for the moment the
        // client says a request will go through; one that got everything it asked for
        // clears any countdown.
        if force {
            let limited = visible.filter { cycleResults[$0.organizationUuid]?.rateLimited == true }
            await scheduleRetry(after: limited, now: deps.now())
            guard cycle == generation else { return }
        }
        updateFooter()
        persist(visible: visible)
        recompute()
        // Last, and never in the way of a reading: the billing facts change about
        // never, so one request per account per day is plenty.
        await refreshSubscriptions(visible, cycle: cycle)
    }

    /// A capture newer than the reading on screen replaces its 5h and weekly windows
    /// (the scoped one stays, dated on its own) and clears a fetch error — a number
    /// from ten seconds ago is not "rate limited", whatever the endpoint answered.
    private func applyStatuslineCaptures(_ visible: [DiscoveredAccount], cycle: Int) async {
        guard let source = deps.statusline else { return }
        let dirs = visible.map { (org: $0.organizationUuid, dirs: [$0.configDir] + $0.aliasDirs) }
        let readings = await Task.detached {
            dirs.compactMap { entry in source.latest(configDirs: entry.dirs).map { (entry.org, $0) } }
        }.value
        guard cycle == generation else { return }
        var changed = false
        for (org, capture) in readings {
            if let current = snapshots[org] {
                guard capture.capturedAt > current.fetchedAt else { continue }
                snapshots[org] = current.merging(capture)
            } else {
                snapshots[org] = LimitSnapshot(organizationUuid: org, capture: capture)
            }
            lastError[org] = nil
            // The endpoint's answer for this account no longer speaks for it: not in
            // the footer, and not as a rate-limit retry to queue.
            cycleResults[org] = nil
            changed = true
        }
        if changed { updateFooter(); recompute() }
    }

    /// Billing facts per organisation, from `api/oauth/profile`.
    private var subscriptions: [String: SubscriptionInfo]
    /// When a profile request last FAILED per organisation — an hour's rest before
    /// trying again, so a dead endpoint costs one request per cycle at most once an hour.
    private var subscriptionFailedAt: [String: Date] = [:]
    static let subscriptionRefresh: TimeInterval = 24 * 3600
    static let subscriptionRetry: TimeInterval = 3600

    private func refreshSubscriptions(_ visible: [DiscoveredAccount], cycle: Int) async {
        guard let client = deps.profileClient else { return }
        var changed = false
        for account in visible where account.tokenExpiresAt != nil {
            let id = account.organizationUuid
            let now = deps.now()
            if let known = subscriptions[id], now.timeIntervalSince(known.fetchedAt) < Self.subscriptionRefresh { continue }
            if let failed = subscriptionFailedAt[id], now.timeIntervalSince(failed) < Self.subscriptionRetry { continue }
            do {
                let profile = try await client.profile(configDir: account.configDir)
                guard cycle == generation else { return }
                subscriptions[id] = SubscriptionInfo(organizationUuid: id, profile: profile, fetchedAt: deps.now())
                subscriptionFailedAt[id] = nil
                changed = true
            } catch {
                guard cycle == generation else { return }
                subscriptionFailedAt[id] = deps.now()
                BrowLog.limits.error("profile fetch failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        guard changed else { return }
        persist(visible: visible)
        recompute()
    }

    /// Every dir a forced cycle is about to read: the known accounts AND their aliases
    /// (an alias dir is where a re-signed-in account's new token appears first), plus the
    /// dirs the next scan will walk — an account that was never discoverable because its
    /// token read was floored has no row to take a configDir from.
    private func invalidateCredentials() {
        for account in accounts {
            deps.directory.invalidate(configDir: account.configDir)
            for alias in account.aliasDirs { deps.directory.invalidate(configDir: alias) }
        }
        deps.directory.invalidateCandidates(extraDirs: settings.extraDirs)
    }

    /// One account's token upkeep and usage request, off the main actor. Sampled
    /// AFTER the token work: `claude doctor` (90 s) plus `claude -p` (120 s) can sit
    /// between the top of the cycle and this request, and the reading must be stamped
    /// with the instant it was really taken — that stamp is the panel's "Updated …".
    nonisolated private static func fetch(deps: Dependencies, account: DiscoveredAccount,
                                          force: Bool, forceAttempt: Bool) async -> FetchResult {
        let token = await deps.keeper.ensureFresh(configDir: account.configDir, authRejected: forceAttempt)
        let at = deps.now()
        // A background poll inside the endpoint's window is not sent and not an error:
        // the reading on screen is the freshest one there can be. (A forced refresh
        // goes on to the client, which throws so the store can queue it.)
        if !force, await deps.client.nextAllowedAt(configDir: account.configDir, force: false, now: at) > at {
            return FetchResult(org: account.organizationUuid, snapshot: nil, error: nil,
                               token: token, rejected: false, rateLimited: false)
        }
        do {
            let usage = try await deps.client.usage(configDir: account.configDir, now: at, force: force)
            let snap = LimitSnapshot(organizationUuid: account.organizationUuid, usage: usage, now: at)
            return FetchResult(org: account.organizationUuid, snapshot: snap,
                               error: snap == nil ? "No limit windows in response" : nil,
                               token: token, rejected: false, rateLimited: false)
        } catch {
            return FetchResult(org: account.organizationUuid, snapshot: nil,
                               error: Self.errorText(error), token: token,
                               rejected: Self.isAuthRejection(error),
                               rateLimited: Self.isRateLimit(error))
        }
    }

    /// One result as it lands: applied and published at once. Errors wait for the end
    /// of the cycle — an account that failed while another is still out is not yet
    /// "nothing worked"; a success is published immediately, message and all.
    private func handle(_ result: FetchResult, outstanding: inout [String]) {
        apply(result)
        outstanding.removeAll { $0 == result.org }
        phase = .fetching(outstanding)
        if result.snapshot != nil { updateFooter() }
        recompute()
    }

    /// One account's answer, as it lands.
    private func apply(_ result: FetchResult) {
        cycleResults[result.org] = result
        tokenOutcome[result.org] = result.token
        // Neither a reading nor an error: the poll was held back by the endpoint's
        // window. The row keeps what it had — status, error and all.
        if result.snapshot == nil && result.error == nil { return }
        if let snapshot = result.snapshot {
            snapshots[result.org] = snapshot
            lastError[result.org] = nil
        } else {
            lastError[result.org] = result.error
            BrowLog.limits.error("fetch failed for \(result.org, privacy: .public): \(result.error ?? "?", privacy: .public)")
        }
        // 401/403 is the server's word on the token and it outranks `expiresAt`: the
        // next cycle spends one forced refresh attempt on this account.
        if result.rejected { authRejected[result.org] = true }
    }

    /// The scan's answer, whenever it arrives. The Keychain verdict is read off the
    /// tokens: a scan that came back empty-handed for every account we have ever read a
    /// token for is the Keychain refusing us, not every account signing out at once.
    /// Only a scan that actually hands a token back reaches `.ok` again, so the verdict
    /// holds for as long as the denial does instead of decaying on the next cycle.
    private func applyScan(_ scanned: [DiscoveredAccount]) {
        let answered = scanned.filter { $0.tokenExpiresAt != nil }.map(\.organizationUuid)
        everHadTokens.formUnion(answered)
        // An account that vanished from disk stops voting: that is a removed directory,
        // not a refused prompt.
        let deniable = scanned.contains { everHadTokens.contains($0.organizationUuid) }
        // The reader now SAYS when an item is withheld, so a locked account is a
        // verdict on its own; the tokenless-but-once-had-tokens heuristic stays for a
        // denial the reader cannot see (a refused prompt floored for ten minutes).
        let locked = scanned.contains(where: \.keychainLocked)
        accounts = scanned
        setKeychainState(locked || (answered.isEmpty && deniable) ? .denied : .ok)
        recompute()
    }

    /// The user pressed the key: read this account's items WITH the Keychain dialog
    /// allowed — "Always Allow" there is what makes every later cycle silent — then
    /// refresh so the grant shows at once. Off the main actor: the dialog is modal
    /// system UI, and the read behind it must not park the app.
    public func grantKeychainAccess(_ account: DiscoveredAccount) async {
        let directory = deps.directory
        let dirs = [account.configDir] + account.aliasDirs
        let granted = await Task.detached { directory.grant(configDirs: dirs) }.value
        BrowLog.limits.info("keychain grant for \(account.organizationUuid, privacy: .public): \(granted ? "token read" : "still withheld", privacy: .public)")
        await refresh(force: true)
    }

    /// The accounts go to disk WITH the snapshots: without them the first frame after a
    /// relaunch has numbers it cannot label (spec, The cycle §5).
    private func persist(visible: [DiscoveredAccount]) {
        // A cycle that discovered nothing must not erase the seed — it is the only
        // reason the next launch has anything to show.
        let stored = visible.isEmpty
            ? deps.snapshotStore.loadFile().accounts
            : visible.enumerated().map { PersistedAccount(from: $1, order: $0) }
        do { try deps.snapshotStore.saveFile(LimitsFile(snapshots: snapshots, accounts: stored, subscriptions: subscriptions)) }
        catch { BrowLog.limits.error("snapshot save failed: \(String(describing: error), privacy: .public)") }
    }

    /// The one footer line for the state we are in right now. A Keychain problem
    /// outranks a fetch error (it is the cause of it), and any account that answered
    /// takes the whole line back off the screen.
    private func updateFooter() {
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }
        if visible.contains(where: { cycleResults[$0.organizationUuid]?.snapshot != nil }) {
            setFooterError(nil)
            return
        }
        switch keychainState {
        case .waiting: setFooterError(Self.waitingMessage)
        case .denied:  setFooterError(Self.deniedMessage)
        // Discovery order, not completion order: the footer must not flip between two
        // accounts' errors from one cycle to the next.
        case .ok:      setFooterError(visible.compactMap { cycleResults[$0.organizationUuid]?.error }.first)
        }
    }

    /// Races `work` against `deps.sleep(seconds)` and returns whichever came first —
    /// nil when the clock won. Cancelling the LOSER never cancels `work` itself: a
    /// timed-out cycle keeps running (its writes gated by `cycle == generation`), and a
    /// blocked Keychain read cannot be interrupted at all.
    private func firstResult<T: Sendable>(of work: Task<T, Never>, within seconds: TimeInterval) async -> T? {
        // `bufferingOldest(1)`, so a work task and a deadline that land in the same
        // instant still resolve as "the work got there first".
        let (stream, continuation) = AsyncStream<T?>.makeStream(of: T?.self, bufferingPolicy: .bufferingOldest(1))
        let watcher = Task { continuation.yield(await work.value) }
        let deadline = Task { [deps] in
            await deps.sleep(seconds)
            continuation.yield(nil)
        }
        defer {
            watcher.cancel()
            deadline.cancel()
            continuation.finish()
        }
        for await first in stream { return first }
        return nil
    }

    private func setFooterError(_ text: String?) {
        guard text != footerError else { return }
        footerError = text
    }

    private func setKeychainState(_ state: KeychainState) {
        guard state != keychainState else { return }
        keychainState = state
        if state != .ok {
            BrowLog.limits.error("keychain state: \(String(describing: state), privacy: .public)")
        }
        recompute()                             // every row's token slot follows this
    }

    private struct FetchResult: Sendable {
        let org: String
        let snapshot: LimitSnapshot?
        let error: String?
        let token: TokenRefreshOutcome
        /// The server rejected the bearer (401/403), whatever `expiresAt` claims.
        let rejected: Bool
        /// The endpoint's rate limit (a 429, or the client's own pacing) held this
        /// request back. A forced cycle re-queues itself for these — see `scheduleRetry`.
        let rateLimited: Bool
    }

    /// How many times a forced refresh re-queues itself behind the rate limit before
    /// it gives up and leaves the row's error where the user can read it.
    static let maxRetryRounds = 3

    nonisolated static func isRateLimit(_ error: Error) -> Bool {
        switch error {
        case OAuthUsageError.tooManyRequests, OAuthUsageError.backoff: return true
        default: return false
        }
    }

    /// A forced refresh that the endpoint held back is not over: it is queued for the
    /// instant the client says a request will go through, and the footer counts down
    /// to it. That is what makes ⟳ "work" under a rate limit — it can neither punch
    /// through the window (that earns a longer one) nor silently do nothing.
    private func scheduleRetry(after limited: [DiscoveredAccount], now: Date) async {
        guard !limited.isEmpty, retryRounds < Self.maxRetryRounds else {
            clearRetry()
            return
        }
        var earliest: Date?
        for account in limited {
            let at = await deps.client.nextAllowedAt(configDir: account.configDir, force: true, now: now)
            earliest = earliest.map { min($0, at) } ?? at
        }
        guard let retryAt = earliest else { clearRetry(); return }
        retryRounds += 1
        pendingRetryAt = retryAt
        retryTask?.cancel()
        retryTask = Task { [weak self, deps] in
            await deps.sleep(max(0.5, retryAt.timeIntervalSince(now)))
            guard !Task.isCancelled, let self else { return }
            await self.refresh(force: true)
        }
    }

    private func clearRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryRounds = 0
        if pendingRetryAt != nil { pendingRetryAt = nil }
    }

    private enum CyclePhase: Sendable, Equatable {
        case idle
        case scanning
        case fetching([String])
        var text: String {
            switch self {
            case .idle: return "nothing"
            case .scanning: return "the account scan"
            case .fetching(let orgs):
                return orgs.isEmpty ? "the last results" : "fetches for \(orgs.joined(separator: ", "))"
            }
        }
    }

    nonisolated static func isAuthRejection(_ error: Error) -> Bool {
        guard let usage = error as? OAuthUsageError else { return false }
        return usage == .http(401) || usage == .http(403)
    }

    /// Recomputes the four derived values and publishes ONCE, only if one of them
    /// moved. Called on every 5 s tick as well as on every landed result, so "nothing
    /// changed" has to cost nothing.
    private func recompute() {
        let now = deps.now()
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }
        let newRows = visible.map { row(for: $0, now: now) }
        let newAllRows = accounts.map { row(for: $0, now: now) }
        let newAggregate = LimitsAggregate.compute(accounts: visible, snapshots: snapshots, now: now)
        let newDataAsOf = visible.compactMap { snapshots[$0.organizationUuid]?.fetchedAt }.max()
        guard newRows != rows || newAllRows != allRows
                || newAggregate != aggregate || newDataAsOf != dataAsOf else { return }
        objectWillChange.send()
        rows = newRows
        allRows = newAllRows
        aggregate = newAggregate
        dataAsOf = newDataAsOf
    }

    private func row(for account: DiscoveredAccount, now: Date) -> AccountRow {
        let snap = snapshots[account.organizationUuid]
        let status: AccountStatus
        if let err = lastError[account.organizationUuid] { status = .error(err) }
        else if let snap, !snap.isStale(now: now) { status = .ok }
        else { status = .stale }
        return AccountRow(account: account, name: settings.displayName(for: account),
                          snapshot: snap, status: status,
                          tokenStatus: Self.tokenStatus(account, outcome: tokenOutcome[account.organizationUuid],
                                                        error: lastError[account.organizationUuid],
                                                        keychain: keychainState, now: now),
                          renewsAt: subscriptions[account.organizationUuid]?.nextRenewal(after: now))
    }

    /// The account row's token slot. The missing token comes FIRST: when the Keychain
    /// gives us nothing, that — not the refresh attempt it made impossible — is
    /// what the user has to fix (spec, Error handling table). And WHY it gave us
    /// nothing decides what the user can do about it: a prompt that has not been
    /// answered yet, a prompt that was refused, and an account that really has no
    /// token are three different problems.
    nonisolated static func tokenStatus(_ account: DiscoveredAccount, outcome: TokenRefreshOutcome?,
                                        error: String?, keychain: KeychainState = .ok, now: Date) -> String {
        guard let exp = account.tokenExpiresAt else {
            if account.keychainLocked { return "Keychain access needed" }
            switch keychain {
            case .waiting: return "waiting for Keychain access"
            case .denied:  return "Keychain access denied"
            case .ok:      return "no token"
            }
        }
        if error == "Claude sign-in expired" { return "sign-in revoked" }
        switch outcome {
        case .refreshedByDoctor?: return "refreshing (doctor)"
        case .refreshedByPrompt?: return "refreshing (-p)"
        case .failed(let why)?: return "token refresh failed: \(why)"
        // The keeper's throttle, NOT a healthy token: falling through to the fresh
        // branch made an 18-day-dead token read "fresh · 0 min" for the rest of every
        // throttle window, one cycle after the honest failure.
        case .skippedRateLimited?: return "token refresh failed (retrying)"
        // Neither of these is evidence about the token either: the CLI never ran. The
        // fresh branch would have called a dead token healthy for as long as the
        // network (or the `claude` path) stayed broken.
        case .skippedOffline?: return "offline"
        case .couldNotAttempt(let why)?: return "token refresh not attempted: \(why)"
        default: break
        }
        guard exp > now else { return "expired \(Formatting.age(exp, now: now))" }
        let h = Int(max(0, exp.timeIntervalSince(now)) / 3600)
        return h >= 1 ? "fresh · \(h) h" : "fresh · \(Int(max(0, exp.timeIntervalSince(now)) / 60)) min"
    }

    /// Same wording Grove's usage panel uses, so the two apps never disagree.
    nonisolated public static func errorText(_ error: Error) -> String {
        switch error {
        case OAuthUsageError.noCredentials:   return "No Claude credentials found"
        case OAuthUsageError.tooManyRequests: return "Rate limited — try again shortly"
        case OAuthUsageError.backoff:         return "Rate limited — waiting to retry"
        case OAuthUsageError.malformed:       return "Unexpected response from Anthropic"
        case OAuthUsageError.http(401), OAuthUsageError.http(403): return "Claude sign-in expired"
        case OAuthUsageError.http(let status): return "Anthropic returned HTTP \(status)"
        case let url as URLError where url.code == .notConnectedToInternet || url.code == .networkConnectionLost || url.code == .cannotFindHost:
            return "Offline"
        default: return (error as NSError).localizedDescription
        }
    }
}
