// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// How long Claude Code keeps a session transcript: `cleanupPeriodDays`, read from
/// every place Claude Code reads it from, the smallest value winning.
///
/// Claude Code deletes transcripts whose last activity is older than that many days
/// (default 30) at startup. The transcript safety net (`TranscriptMirror`) keeps
/// hard links to transcripts so that a file deleted by accident can be put back; it
/// must never bring back, or keep on disk, what that sweep was set up to remove — a
/// user who shortened the period, or an organisation that set it in managed settings,
/// did so to have the files gone.
///
/// The sources, all of them optional (see Claude Code's settings documentation):
/// - the managed settings file `/Library/Application Support/ClaudeCode/managed-settings.json`
///   and every `*.json` drop-in in `managed-settings.d/` beside it;
/// - the MDM preferences domain `com.anthropic.claudecode`;
/// - server-managed settings, cached as `<config dir>/remote-settings.json`;
/// - the account's own `<config dir>/settings.json`.
///
/// Precedence between them does not matter here: the SMALLEST value any of them sets is
/// the one used, so the mirror is never more generous than any layer Claude Code might
/// apply. A value of 0 or less (rejected by current Claude Code; "keep nothing" in older
/// versions) counts as 0 days. A source that exists but cannot be read — a file
/// caught mid-write, a hand edit that broke the JSON, a value that is not a number — makes
/// the answer UNCERTAIN: the real period may be shorter than the one computed, so
/// nothing is restored on the strength of it.
public struct ClaudeRetention: Sendable {
    /// What Claude Code keeps when nothing sets `cleanupPeriodDays`.
    public static let defaultDays = 30
    public static let settingKey = "cleanupPeriodDays"
    /// Where Claude Code looks for managed settings on macOS.
    public static let managedDirectory = "/Library/Application Support/ClaudeCode"
    /// The MDM preferences domain Claude Code reads managed settings from.
    public static let preferencesDomain = "com.anthropic.claudecode"

    /// Where a value came from, for the settings text.
    public enum Source: String, Sendable, Equatable, CaseIterable {
        case managedFile
        case managedDropIn
        case managedPreferences
        case remoteSettings
        case accountSettings
        case claudeDefault

        public var label: String {
            switch self {
            case .managedFile: return "managed settings"
            case .managedDropIn: return "a managed settings drop-in"
            case .managedPreferences: return "a configuration profile"
            case .remoteSettings: return "settings from your organisation"
            case .accountSettings: return "this account's settings.json"
            case .claudeDefault: return "Claude Code's default"
            }
        }
    }

    /// The effective period for one config dir.
    public struct Resolution: Sendable, Equatable {
        /// Days a transcript is kept: the smallest value any source sets, else 30.
        public let days: Int
        /// The source that set `days`.
        public let source: Source
        /// Files that exist but could not be read, or held something other than a number.
        /// Non-empty means the period may really be shorter, and nothing is restored.
        public let unreadable: [String]

        public init(days: Int, source: Source, unreadable: [String] = []) {
            self.days = days
            self.source = source
            self.unreadable = unreadable
        }

        public var isCertain: Bool { unreadable.isEmpty }

        /// "30 days (Claude Code's default)", "7 days (this account's settings.json)".
        public var summary: String {
            let period = days == 1 ? "1 day" : "\(days) days"
            return isCertain ? "\(period) (\(source.label))"
                             : "\(period) or less (\(unreadable.count == 1 ? "a settings file" : "settings files") could not be read)"
        }
    }

    /// One read of a source: absent, a number, or present but unusable.
    public enum Reading: Sendable, Equatable {
        case absent
        case days(Int)
        case unreadable
    }

    private let managedDirectory: String
    private let preferences: @Sendable () -> Reading

    /// `managedDirectory` and `preferences` are injectable so tests never read the
    /// machine's real managed settings.
    public init(managedDirectory: String = ClaudeRetention.managedDirectory,
                preferences: @escaping @Sendable () -> Reading = ClaudeRetention.readPreferencesDomain) {
        self.managedDirectory = managedDirectory
        self.preferences = preferences
    }

    /// The period Claude Code applies to the transcripts in `configDir`.
    public func resolve(configDir: String) -> Resolution {
        resolveSources(configDir: configDir)
    }

    /// The managed sources alone (files, drop-ins, configuration profile), else the
    /// default: what applies to a folder whose own settings are unknown.
    public func resolveManaged() -> Resolution {
        resolveSources(configDir: nil)
    }

    /// The strictest of several folders' periods — one account signed in to several
    /// config folders keeps its transcripts for the shortest of them.
    public static func strictest(_ resolutions: [Resolution]) -> Resolution {
        guard let first = resolutions.min(by: { $0.days < $1.days }) else {
            return Resolution(days: defaultDays, source: .claudeDefault)
        }
        let unreadable = resolutions.flatMap(\.unreadable)
        var seen = Set<String>()
        return Resolution(days: first.days, source: first.source,
                          unreadable: unreadable.filter { seen.insert($0).inserted })
    }

    private func resolveSources(configDir: String?) -> Resolution {
        let dir = configDir.map(expandTilde)
        var candidates: [(days: Int, source: Source)] = []
        var unreadable: [String] = []

        func take(_ reading: Reading, _ source: Source, _ name: String) {
            switch reading {
            case .absent: break
            case .days(let days): candidates.append((max(0, days), source))
            case .unreadable: unreadable.append(name)
            }
        }

        let fm = FileManager.default
        let managedFile = managedDirectory + "/managed-settings.json"
        take(Self.readSettingsFile(managedFile), .managedFile, managedFile)
        let dropIns = managedDirectory + "/managed-settings.d"
        for name in ((try? fm.contentsOfDirectory(atPath: dropIns)) ?? []).sorted()
        where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = dropIns + "/" + name
            take(Self.readSettingsFile(path), .managedDropIn, path)
        }
        take(preferences(), .managedPreferences, Self.preferencesDomain)
        if let dir {
            let remote = dir + "/remote-settings.json"
            take(Self.readSettingsFile(remote), .remoteSettings, remote)
            let account = dir + "/settings.json"
            take(Self.readSettingsFile(account), .accountSettings, account)
        }

        // Smallest wins; on a tie the earlier (more managed) source is named.
        guard let smallest = candidates.enumerated().min(by: { a, b in
            a.element.days != b.element.days ? a.element.days < b.element.days : a.offset < b.offset
        })?.element else {
            return Resolution(days: Self.defaultDays, source: .claudeDefault, unreadable: unreadable)
        }
        return Resolution(days: smallest.days, source: smallest.source, unreadable: unreadable)
    }

    /// `cleanupPeriodDays` from one JSON settings file.
    public static func readSettingsFile(_ path: String) -> Reading {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .unreadable }
        return reading(object[settingKey])
    }

    /// A settings value as a period. Absent and JSON `null` are "not set"; a whole number
    /// is a period; anything else (a string, a fraction, a bool) is unusable.
    static func reading(_ value: Any?) -> Reading {
        guard let value, !(value is NSNull) else { return .absent }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .unreadable
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return .unreadable }
        return .days(Int(max(Double(Int32.min), min(double, Double(Int32.max)))))
    }

    /// The MDM domain, through CFPreferences: a configuration profile's forced value,
    /// or one set with `defaults write com.anthropic.claudecode cleanupPeriodDays`.
    public static let readPreferencesDomain: @Sendable () -> Reading = {
        reading(CFPreferencesCopyAppValue(settingKey as CFString, preferencesDomain as CFString))
    }
}
