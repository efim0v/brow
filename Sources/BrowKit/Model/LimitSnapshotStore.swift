import Foundation

/// `<directory>/limits.json`, keyed by organisation. Atomic writes; any read
/// error is an empty map — a corrupt cache must never keep the app from starting.
public struct LimitSnapshotStore: Sendable {
    public static let defaultDirectory =
        NSHomeDirectory() + "/Library/Application Support/Brow"

    private let directory: String
    private var file: String { directory + "/limits.json" }

    public init(directory: String = LimitSnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    public func load() -> [String: LimitSnapshot] {
        let path = file
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: LimitSnapshot].self, from: data)
        } catch {
            // Degrading to empty is the recovery, but the cache being unreadable is
            // still a failure: log it rather than swallow it.
            BrowLog.limits.error("limits cache unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func save(_ snapshots: [String: LimitSnapshot]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(snapshots).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
