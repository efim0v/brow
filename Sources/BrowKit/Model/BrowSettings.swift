// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// Where the two ear readouts sit on a notched screen: in the wings on either side of
/// the notch, or in a strip under it.
public enum EarsPlacement: String, Codable, Sendable, CaseIterable {
    case beside, below
}

/// The "my week" image: 1200 × 630, the size link previews use, or 1080 × 1080.
public enum CardShape: String, Codable, Sendable, CaseIterable {
    case wide, square
}

public struct AccountOverride: Codable, Sendable, Equatable {
    public var name: String?
    public var hidden: Bool
    public init(name: String?, hidden: Bool) { self.name = name; self.hidden = hidden }

    enum CodingKeys: String, CodingKey { case name, hidden }

    /// Lenient like the file around it: a hand edit that breaks `hidden` keeps the name.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issues = decoder.userInfo[.browSettingsIssues] as? SettingsIssues
        do { name = try c.decodeIfPresent(String.self, forKey: .name) } catch { name = nil; issues?.record("accounts.name") }
        do { hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false } catch { hidden = false; issues?.record("accounts.hidden") }
    }
}

/// The fields of a settings file that did not decode, collected while it is read so the
/// store can keep a copy of the file before the next save replaces them with defaults.
public final class SettingsIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: [String] = []
    public init() {}
    public func record(_ field: String) { lock.withLock { fields.append(field) } }
    public var all: [String] { lock.withLock { fields } }
}

public extension CodingUserInfoKey {
    /// A `SettingsIssues` the settings decoders record their failures in.
    static let browSettingsIssues = CodingUserInfoKey(rawValue: "browSettingsIssues")!
}

/// `~/Library/Application Support/Brow/config.json`. Every field has a default so
/// a file written by an older build still loads, and every field decodes ON ITS OWN:
/// a value that does not fit costs that field, never the rest of the file (brow#7).
public struct BrowSettings: Codable, Sendable, Equatable {
    public var accounts: [String: AccountOverride] = [:]
    public var extraDirs: [String] = []
    /// Allow `claude -p` when `claude doctor` fails to refresh a token. Costs a
    /// sliver of that account's limit and starts its 5-hour window.
    public var allowPromptFallback: Bool = true
    public var claudePath: String? = nil
    public var earsPlacement: EarsPlacement = .beside
    /// The "my week" image numbers its accounts unless this is on; even then only a
    /// name set here is used, never the email or the folder `displayName` falls back to.
    public var cardShowNames: Bool = false
    public var cardShape: CardShape = .wide
    /// False: Brow draws nothing at the top of the screen and no panel opens there — for
    /// someone who uses Brow for Workspaces only. Limit warnings still post, and opening
    /// Brow again shows Workspaces or Settings.
    public var showNotch: Bool = true
    /// False: nothing is drawn while collapsed — the notch is just the notch — and the
    /// panel appears only when the pointer reaches the notch itself.
    public var showEars: Bool = true
    /// The month of weekly resets and renewals under the accounts in the panel.
    public var showCalendar: Bool = true
    /// The pet beside the notch that eats what the accounts use. On by default, like the readouts and
    /// the calendar: it draws only in Brow's own black, covers no number, interrupts nothing and needs
    /// no permission. Off: no frames, no timers, no file watchers; `pet.json` is kept.
    public var showPet: Bool = true
    /// A macOS notification when a visible account passes one of `notifyThresholds`
    /// on any of its windows — see `LimitWarnings`. Off until the user opts in.
    public var notifyLimits: Bool = false
    /// Percent levels, 1...100 ascending. Read through `LimitWarnings.sanitized`.
    public var notifyThresholds: [Int] = LimitWarnings.defaultLevels
    /// A second notice when a window Brow warned about resets.
    public var notifyResets: Bool = false
    /// Whether Workspaces runs, its menu-bar item, its panel's material. Older builds
    /// ignore the key and drop it on their next save, and nothing else changes.
    public var workspaces: WorkspacesSettings = WorkspacesSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case accounts, extraDirs, allowPromptFallback, claudePath, earsPlacement, showNotch, showEars, showCalendar, showPet, cardShowNames, cardShape, notifyLimits, notifyThresholds, notifyResets, workspaces }

    // `decodeIfPresent` answers nil only for a MISSING key: a key that is PRESENT with a
    // value of the wrong type or an unmatched raw value (a hand edit, or a value a later
    // build writes) throws, and one throwing field used to fail `init(from:)` — so
    // `load()` fell back to a fresh `BrowSettings`, and one typo took the account names,
    // the alias dirs, the `claude` path and `allowPromptFallback` with it; the next
    // settings write made the loss permanent. Every field is caught on its own now, and
    // recorded, so `BrowSettingsStore.load` keeps a copy of the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issues = decoder.userInfo[.browSettingsIssues] as? SettingsIssues
        func field<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) } catch {
                issues?.record(key.stringValue)
                BrowLog.panel.error("config.json: \(key.stringValue, privacy: .public) unreadable; using the default")
                return nil
            }
        }
        accounts = field(.accounts, [String: AccountOverride].self) ?? [:]
        extraDirs = field(.extraDirs, [String].self) ?? []
        allowPromptFallback = field(.allowPromptFallback, Bool.self) ?? true
        claudePath = field(.claudePath, String.self)
        cardShowNames = field(.cardShowNames, Bool.self) ?? false
        cardShape = Self.rawValue(field(.cardShape, String.self), CardShape.self, key: "cardShape", issues) ?? .wide
        showNotch = field(.showNotch, Bool.self) ?? true
        showEars = field(.showEars, Bool.self) ?? true
        showCalendar = field(.showCalendar, Bool.self) ?? true
        showPet = field(.showPet, Bool.self) ?? true
        notifyLimits = field(.notifyLimits, Bool.self) ?? false
        notifyThresholds = LimitWarnings.sanitized(field(.notifyThresholds, [Int].self) ?? LimitWarnings.defaultLevels)
        notifyResets = field(.notifyResets, Bool.self) ?? false
        // Through its raw value: an unknown placement (a later build's third case, a
        // typo from the `plutil` edit the docs suggest) costs this field only.
        earsPlacement = Self.rawValue(field(.earsPlacement, String.self), EarsPlacement.self,
                                      key: "earsPlacement", issues) ?? .beside
        workspaces = field(.workspaces, WorkspacesSettings.self) ?? WorkspacesSettings()
    }

    /// A string field as an enum; an unknown value is recorded and reads as nil.
    private static func rawValue<E: RawRepresentable>(_ raw: String?, _ type: E.Type, key: String,
                                                      _ issues: SettingsIssues?) -> E? where E.RawValue == String {
        guard let raw else { return nil }
        guard let value = E(rawValue: raw) else {
            issues?.record(key)
            BrowLog.panel.error("config.json: unknown \(key, privacy: .public) \"\(raw, privacy: .public)\"; using the default")
            return nil
        }
        return value
    }

    /// Override → email → last path component of the config dir.
    public func displayName(for account: DiscoveredAccount) -> String {
        if let name = accounts[account.organizationUuid]?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        if let email = account.email, !email.isEmpty { return email }
        return (account.configDir as NSString).lastPathComponent
    }

    /// The name set in Settings, trimmed; nil without one. Unlike `displayName`, never
    /// the email or the folder: this is for what leaves the panel (a notification, the
    /// week card).
    public func setName(for organizationUuid: String) -> String? {
        guard let name = accounts[organizationUuid]?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// "Account 1", "Account 2": an account by its place among the visible accounts in
    /// panel order (`LimitsStore.rows`), `index` counting from 0. Limit warnings and the
    /// week card number the same way, so "Account 2" is the same account in both.
    public static func numberedName(index: Int) -> String { "Account \(index + 1)" }

    public func isHidden(_ organizationUuid: String) -> Bool {
        accounts[organizationUuid]?.hidden ?? false
    }
}

public struct BrowSettingsStore: Sendable {
    public static let defaultDirectory = NSHomeDirectory() + "/Library/Application Support/Brow"
    private let directory: String
    private var file: String { directory + "/config.json" }
    /// Where a copy of an unreadable `config.json` goes before defaults replace it.
    public var backupFile: String { directory + "/config.json.bak" }

    public init(directory: String = BrowSettingsStore.defaultDirectory) { self.directory = directory }

    /// Defaults are the recovery, but an unreadable value is still a failure: it is
    /// logged, and the file as it was is copied to `config.json.bak` first — the next
    /// settings write replaces the unreadable values with defaults for good.
    public func load() -> BrowSettings {
        let path = file
        guard let data = FileManager.default.contents(atPath: path) else { return BrowSettings() }
        let issues = SettingsIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[.browSettingsIssues] = issues
        do {
            let settings = try decoder.decode(BrowSettings.self, from: data)
            if !issues.all.isEmpty { keepCopy(data, because: issues.all.joined(separator: ", ")) }
            return settings
        } catch {
            BrowLog.panel.error("settings unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            keepCopy(data, because: "not a settings object")
            return BrowSettings()
        }
    }

    public func save(_ settings: BrowSettings) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(settings).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    private func keepCopy(_ data: Data, because reason: String) {
        do {
            try data.write(to: URL(fileURLWithPath: backupFile), options: .atomic)
            BrowLog.panel.error("config.json kept as config.json.bak (\(reason, privacy: .public))")
        } catch {
            BrowLog.panel.error("config.json.bak not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
