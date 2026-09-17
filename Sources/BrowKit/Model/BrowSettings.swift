import Foundation
import GroveCore

/// Where the two ear readouts sit on a notched screen: in the wings on either side of
/// the notch, or in a strip under it.
public enum EarsPlacement: String, Codable, Sendable, CaseIterable {
    case beside, below
}

public struct AccountOverride: Codable, Sendable, Equatable {
    public var name: String?
    public var hidden: Bool
    public init(name: String?, hidden: Bool) { self.name = name; self.hidden = hidden }
}

/// `~/Library/Application Support/Brow/config.json`. Every field has a default so
/// a file written by an older build still loads.
public struct BrowSettings: Codable, Sendable, Equatable {
    public var accounts: [String: AccountOverride] = [:]
    public var extraDirs: [String] = []
    /// Allow `claude -p` when `claude doctor` fails to refresh a token. Costs a
    /// sliver of that account's limit and starts its 5-hour window.
    public var allowPromptFallback: Bool = true
    public var claudePath: String? = nil
    public var earsPlacement: EarsPlacement = .beside
    /// False: nothing is drawn while collapsed — the notch is just the notch — and the
    /// panel appears only when the pointer reaches the notch itself.
    public var showEars: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case accounts, extraDirs, allowPromptFallback, claudePath, earsPlacement, showEars }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([String: AccountOverride].self, forKey: .accounts) ?? [:]
        extraDirs = try c.decodeIfPresent([String].self, forKey: .extraDirs) ?? []
        allowPromptFallback = try c.decodeIfPresent(Bool.self, forKey: .allowPromptFallback) ?? true
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        showEars = (try? c.decodeIfPresent(Bool.self, forKey: .showEars)) ?? true
        // Decoded through its raw value, not as the enum, and never allowed to throw.
        // `decodeIfPresent` answers nil only for a MISSING key: a key that is PRESENT
        // with an unmatched value (a hand-edited config — the plan's own Task 10 asks
        // the owner to edit this very key with `plutil` — or a third case written by a
        // later build) throws `dataCorrupted`, which fails `init(from:)`, which makes
        // `load()` fall back to a fresh `BrowSettings`. One typo would take the account
        // names, the alias dirs, the `claude` path and `allowPromptFallback` with it —
        // against this file's own "every field has a default" contract — and the next
        // settings write would make the loss permanent.
        // `String??`: the outer nil is "the value is not even a string", the inner one
        // "the key is absent or null".
        let rawPlacement: String?? = try? c.decodeIfPresent(String.self, forKey: .earsPlacement)
        switch rawPlacement {
        case .some(.some(let raw)):
            earsPlacement = EarsPlacement(rawValue: raw) ?? .beside
            if EarsPlacement(rawValue: raw) == nil {
                BrowLog.panel.error("config.json: unknown earsPlacement \"\(raw, privacy: .public)\"; using beside")
            }
        case .some(.none):
            earsPlacement = .beside                 // absent (an older file) or null
        case .none:
            BrowLog.panel.error("config.json: earsPlacement is not a string; using beside")
            earsPlacement = .beside
        }
    }

    /// Override → email → last path component of the config dir.
    public func displayName(for account: DiscoveredAccount) -> String {
        if let name = accounts[account.organizationUuid]?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        if let email = account.email, !email.isEmpty { return email }
        return (account.configDir as NSString).lastPathComponent
    }

    public func isHidden(_ organizationUuid: String) -> Bool {
        accounts[organizationUuid]?.hidden ?? false
    }
}

public struct BrowSettingsStore: Sendable {
    public static let defaultDirectory = NSHomeDirectory() + "/Library/Application Support/Brow"
    private let directory: String
    private var file: String { directory + "/config.json" }

    public init(directory: String = BrowSettingsStore.defaultDirectory) { self.directory = directory }

    public func load() -> BrowSettings {
        let path = file
        guard let data = FileManager.default.contents(atPath: path) else { return BrowSettings() }
        do {
            return try JSONDecoder().decode(BrowSettings.self, from: data)
        } catch {
            // Defaults are the recovery, but an unreadable settings file is still a
            // failure: log it rather than swallow it.
            BrowLog.panel.error("settings unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return BrowSettings()
        }
    }

    public func save(_ settings: BrowSettings) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}
