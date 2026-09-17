import Foundation

/// Everything `limits.json` holds: the per-organisation snapshots and the
/// accounts the last scan found. Both halves are written together so a relaunch
/// can pair each number with the account it belongs to.
public struct LimitsFile: Codable, Sendable, Equatable {
    public var snapshots: [String: LimitSnapshot]
    public var accounts: [PersistedAccount]
    /// Billing facts per organisation (see `SubscriptionInfo`), refreshed about daily.
    public var subscriptions: [String: SubscriptionInfo]

    public init(snapshots: [String: LimitSnapshot] = [:], accounts: [PersistedAccount] = [],
                subscriptions: [String: SubscriptionInfo] = [:]) {
        self.snapshots = snapshots
        self.accounts = accounts
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey { case snapshots, accounts, subscriptions }

    /// The two halves decode independently. The snapshots are the file's reason to
    /// exist; the accounts are a convenience for the first frame. So an `accounts`
    /// array this build cannot read — absent, or written by a later build whose
    /// `PersistedAccount` carries a field this one cannot fill — degrades to no
    /// accounts instead of failing the whole decode and costing every cached number.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = try container.decode([String: LimitSnapshot].self, forKey: .snapshots)
        do {
            accounts = try container.decodeIfPresent([PersistedAccount].self, forKey: .accounts) ?? []
        } catch {
            // Best-effort is not silent: the snapshots survive, but the seed was lost.
            BrowLog.limits.error("""
                limits cache: accounts unreadable, keeping the snapshots alone: \
                \(String(describing: error), privacy: .public)
                """)
            accounts = []
        }
        // Same best-effort as the accounts: a renewal estimate is never worth a cache.
        subscriptions = (try? container.decodeIfPresent([String: SubscriptionInfo].self, forKey: .subscriptions)) ?? [:]
    }
}

/// `<directory>/limits.json`. Atomic writes; any read error is an empty file —
/// a corrupt cache must never keep the app from starting.
public struct LimitSnapshotStore: Sendable {
    public static let defaultDirectory =
        NSHomeDirectory() + "/Library/Application Support/Brow"

    private let directory: String
    private var file: String { directory + "/limits.json" }

    public init(directory: String = LimitSnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    /// Reads the current shape; falls back to the pre-accounts shape (a bare
    /// `[String: LimitSnapshot]` map) so an existing cache keeps its numbers
    /// across the upgrade instead of starting blank.
    public func loadFile() -> LimitsFile {
        let path = file
        guard let data = FileManager.default.contents(atPath: path) else { return LimitsFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let currentShapeError: Error
        do {
            return try decoder.decode(LimitsFile.self, from: data)
        } catch {
            currentShapeError = error
        }
        do {
            return LimitsFile(snapshots: try decoder.decode([String: LimitSnapshot].self, from: data))
        } catch {
            // Degrading to empty is the recovery, but the cache being unreadable is
            // still a failure: log it rather than swallow it. BOTH errors go in the
            // line — either shape could be the one that was meant, so reporting only
            // one of them points at the wrong problem half the time.
            BrowLog.limits.error("""
                limits cache unreadable at \(path, privacy: .public): \
                \(String(describing: currentShapeError), privacy: .public); \
                legacy snapshot-map fallback also failed: \(String(describing: error), privacy: .public)
                """)
            return LimitsFile()
        }
    }

    public func saveFile(_ contents: LimitsFile) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(contents).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    public func load() -> [String: LimitSnapshot] { loadFile().snapshots }

    /// Snapshot-only write: the accounts already on disk are carried over, so a
    /// fetch that lands before the next scan cannot erase the seed.
    public func save(_ snapshots: [String: LimitSnapshot]) throws {
        let file = loadFile()
        try saveFile(LimitsFile(snapshots: snapshots, accounts: file.accounts, subscriptions: file.subscriptions))
    }
}
