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
        public init(directory: AccountDirectory, keeper: TokenKeeper, client: OAuthUsageClient,
                    snapshotStore: LimitSnapshotStore, settingsStore: BrowSettingsStore,
                    now: @escaping @Sendable () -> Date) {
            self.directory = directory; self.keeper = keeper; self.client = client
            self.snapshotStore = snapshotStore; self.settingsStore = settingsStore; self.now = now
        }
    }

    /// Visible accounts only — what the ears and the panel show.
    @Published public private(set) var rows: [AccountRow] = []
    /// Every discovered account, hidden ones included. Settings lists these, so a
    /// hidden account can be un-hidden again.
    @Published public private(set) var allRows: [AccountRow] = []
    @Published public private(set) var aggregate: LimitsAggregate
    /// Newest `fetchedAt` across visible accounts; nil until any fetch succeeded.
    @Published public private(set) var dataAsOf: Date?
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
    /// Bumped at the top of every cycle; a cycle whose generation has moved on drops
    /// its results instead of writing them.
    private var generation = 0

    /// NO I/O beyond the persisted snapshot file: `AccountDirectory.scan` reads one
    /// Keychain item per config dir, and on a new bundle id macOS puts a modal prompt
    /// in front of each one. Doing that here parked the main thread before the panel
    /// existed — no ears, no footer error slot, no working Cmd-Q. Discovery happens in
    /// `bootstrap()`, after the first frame is on screen.
    public init(deps: Dependencies) {
        self.deps = deps
        self.settings = deps.settingsStore.load()
        self.snapshots = deps.snapshotStore.load()
        self.aggregate = LimitsAggregate.compute(accounts: [], snapshots: [:], now: deps.now())
        recompute()
    }

    /// First account discovery. Call AFTER the panel is visible: the persisted
    /// snapshots are already on screen, so the Keychain prompts are answered by a
    /// user who can see the app they belong to.
    public func bootstrap() async {
        let discovered = await Self.scan(deps.directory, extraDirs: settings.extraDirs)
        accounts = discovered
        recompute()
        BrowLog.limits.info("discovered \(discovered.count, privacy: .public) account(s)")
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
    private static func scan(_ directory: AccountDirectory, extraDirs: [String]) async -> [DiscoveredAccount] {
        await Task.detached { directory.scan(extraDirs: extraDirs) }.value
    }

    private func runCycle(force: Bool) async {
        generation += 1
        let cycle = generation
        isRefreshing = true
        if force { isForcing = true }
        defer {
            isRefreshing = false
            if force { isForcing = false }
        }
        accounts = await Self.scan(deps.directory, extraDirs: settings.extraDirs)
        guard cycle == generation else { return }
        // The rows (names, tiers, persisted values with their real age) are worth
        // showing before the network answers.
        recompute()
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }

        struct FetchResult: Sendable {
            let org: String
            let snapshot: LimitSnapshot?
            let error: String?
            let token: TokenRefreshOutcome
        }
        let results = await withTaskGroup(of: FetchResult.self, returning: [String: FetchResult].self) { group in
            for account in visible {
                group.addTask { [deps] in
                    let token = await deps.keeper.ensureFresh(configDir: account.configDir)
                    // Sampled AFTER the token work: `claude doctor` (90 s) plus
                    // `claude -p` (120 s) can sit between the top of the cycle and
                    // this request, and the reading must be stamped with the instant
                    // it was really taken — that stamp is the panel's "Updated …".
                    let at = deps.now()
                    do {
                        let usage = try await deps.client.usage(configDir: account.configDir, now: at, force: force)
                        let snap = LimitSnapshot(organizationUuid: account.organizationUuid, usage: usage, now: at)
                        return FetchResult(org: account.organizationUuid, snapshot: snap,
                                           error: snap == nil ? "No limit windows in response" : nil, token: token)
                    } catch {
                        return FetchResult(org: account.organizationUuid, snapshot: nil,
                                           error: Self.errorText(error), token: token)
                    }
                }
            }
            var out: [String: FetchResult] = [:]
            for await r in group { out[r.org] = r }
            return out
        }
        // A superseded cycle drops its whole result set rather than writing older
        // numbers over newer ones.
        guard cycle == generation else { return }

        var anySucceeded = false
        var firstError: String?
        // Discovery order, not completion order: the footer must not flip between
        // two accounts' errors from one cycle to the next.
        for account in visible {
            guard let r = results[account.organizationUuid] else { continue }
            tokenOutcome[r.org] = r.token
            if let snap = r.snapshot {
                snapshots[r.org] = snap
                lastError[r.org] = nil
                anySucceeded = true
            } else {
                lastError[r.org] = r.error
                if firstError == nil { firstError = r.error }
                BrowLog.limits.error("fetch failed for \(r.org, privacy: .public): \(r.error ?? "?", privacy: .public)")
            }
        }
        setFooterError(anySucceeded ? nil : firstError)
        do { try deps.snapshotStore.save(snapshots) }
        catch { BrowLog.limits.error("snapshot save failed: \(String(describing: error), privacy: .public)") }
        recompute()
    }

    private func setFooterError(_ text: String?) {
        guard text != footerError else { return }
        footerError = text
    }

    private func recompute() {
        let now = deps.now()
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }
        rows = visible.map { row(for: $0, now: now) }
        allRows = accounts.map { row(for: $0, now: now) }
        aggregate = LimitsAggregate.compute(accounts: visible, snapshots: snapshots, now: now)
        dataAsOf = visible.compactMap { snapshots[$0.organizationUuid]?.fetchedAt }.max()
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
                                                        error: lastError[account.organizationUuid], now: now))
    }

    /// The account row's token slot. "no token" comes FIRST: when the Keychain
    /// gives us nothing, that — not the refresh attempt it made impossible — is
    /// what the user has to fix (spec, Error handling table).
    nonisolated static func tokenStatus(_ account: DiscoveredAccount, outcome: TokenRefreshOutcome?,
                                        error: String?, now: Date) -> String {
        guard let exp = account.tokenExpiresAt else { return "no token" }
        if error == "Claude sign-in expired" { return "sign-in revoked" }
        switch outcome {
        case .refreshedByDoctor?: return "refreshing (doctor)"
        case .refreshedByPrompt?: return "refreshing (-p)"
        case .failed(let why)?: return "token refresh failed: \(why)"
        // The keeper's throttle, NOT a healthy token: falling through to the fresh
        // branch made an 18-day-dead token read "fresh · 0 min" for the rest of every
        // throttle window, one cycle after the honest failure.
        case .skippedRateLimited?: return "token refresh failed (retrying)"
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
