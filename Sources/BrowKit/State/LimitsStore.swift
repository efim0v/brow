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

    @Published public private(set) var rows: [AccountRow] = []
    @Published public private(set) var aggregate: LimitsAggregate
    /// Newest `fetchedAt` across visible accounts; nil until any fetch succeeded.
    @Published public private(set) var dataAsOf: Date?
    /// Set only when NO visible account succeeded in the last cycle.
    @Published public private(set) var footerError: String?
    @Published public private(set) var isRefreshing = false
    @Published public var settings: BrowSettings {
        didSet {
            do { try deps.settingsStore.save(settings) }
            catch { BrowLog.limits.error("settings save failed: \(String(describing: error), privacy: .public)") }
            recompute()
        }
    }

    private let deps: Dependencies
    private var accounts: [DiscoveredAccount] = []
    private var snapshots: [String: LimitSnapshot]
    private var lastError: [String: String] = [:]
    private var tokenOutcome: [String: TokenRefreshOutcome] = [:]

    public init(deps: Dependencies) {
        self.deps = deps
        self.settings = deps.settingsStore.load()
        self.snapshots = deps.snapshotStore.load()
        self.aggregate = LimitsAggregate.compute(accounts: [], snapshots: [:], now: deps.now())
        self.accounts = deps.directory.scan(extraDirs: settings.extraDirs)
        recompute()
    }

    public func refreshIfOlderThan(_ seconds: TimeInterval) async {
        let now = deps.now()
        if let asOf = dataAsOf, now.timeIntervalSince(asOf) < seconds { return }
        await refresh(force: false)
    }

    public func refresh(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let now = deps.now()
        accounts = deps.directory.scan(extraDirs: settings.extraDirs)
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
                    do {
                        let usage = try await deps.client.usage(configDir: account.configDir, now: now, force: force)
                        let snap = LimitSnapshot(organizationUuid: account.organizationUuid, usage: usage, now: now)
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
        footerError = anySucceeded ? nil : firstError
        do { try deps.snapshotStore.save(snapshots) }
        catch { BrowLog.limits.error("snapshot save failed: \(String(describing: error), privacy: .public)") }
        recompute()
    }

    private func recompute() {
        let now = deps.now()
        let visible = accounts.filter { !settings.isHidden($0.organizationUuid) }
        rows = visible.map { account in
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
        aggregate = LimitsAggregate.compute(accounts: visible, snapshots: snapshots, now: now)
        dataAsOf = visible.compactMap { snapshots[$0.organizationUuid]?.fetchedAt }.max()
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
        default: break
        }
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
