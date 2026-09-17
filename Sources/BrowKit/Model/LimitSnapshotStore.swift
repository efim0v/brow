import Foundation

/// Everything `limits.json` holds: the per-organisation snapshots and the
/// accounts the last scan found. Both halves are written together so a relaunch
/// can pair each number with the account it belongs to.
public struct LimitsFile: Codable, Sendable, Equatable {
    public var snapshots: [String: LimitSnapshot]
    public var accounts: [PersistedAccount]

    public init(snapshots: [String: LimitSnapshot] = [:], accounts: [PersistedAccount] = []) {
        self.snapshots = snapshots
        self.accounts = accounts
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
        try saveFile(LimitsFile(snapshots: snapshots, accounts: loadFile().accounts))
    }
}
