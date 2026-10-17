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
/// - the account's own `<config dir>/settings.json`;
/// - the project settings, `.claude/settings.json` and `.claude/settings.local.json`, of
///   every folder the account's sessions ran in (`TranscriptCwds`). A session reads its own
///   project's settings, and its sweep then deletes old transcripts in EVERY project of the
///   config folder — so the shortest period any one project sets applies to all of them.
///
/// One source can't be read from outside: a period passed on the command line with
/// `--settings`. It lasts one session, and nothing records it.
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
        case projectSettings
        case projectLocalSettings
        case claudeDefault

        public var label: String {
            switch self {
            case .managedFile: return "managed settings"
            case .managedDropIn: return "a managed settings drop-in"
            case .managedPreferences: return "a configuration profile"
            case .remoteSettings: return "settings from your organisation"
            case .accountSettings: return "this account's settings.json"
            case .projectSettings: return "a project's .claude/settings.json"
            case .projectLocalSettings: return "a project's .claude/settings.local.json"
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
        /// The file that set `days`, when it was a file.
        public let origin: String?

        public init(days: Int, source: Source, unreadable: [String] = [], origin: String? = nil) {
            self.days = days
            self.source = source
            self.unreadable = unreadable
            self.origin = origin
        }

        public var isCertain: Bool { unreadable.isEmpty }

        /// "30 days (Claude Code's default)", "7 days (this account's settings.json)",
        /// "3 days (~/Code/shop/.claude/settings.local.json)".
        public var summary: String {
            let period = days == 1 ? "1 day" : "\(days) days"
            guard isCertain else {
                return "\(period) or less (\(unreadable.count == 1 ? "a settings file" : "settings files") could not be read)"
            }
            if let origin, source == .projectSettings || source == .projectLocalSettings {
                return "\(period) (\((origin as NSString).abbreviatingWithTildeInPath))"
            }
            return "\(period) (\(source.label))"
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

    /// The period Claude Code applies to the transcripts in `configDir`, whose sessions
    /// ran in `projectCwds` (`TranscriptCwds.all`).
    public func resolve(configDir: String, projectCwds: [String] = []) -> Resolution {
        resolveSources(configDir: configDir, projectCwds: projectCwds)
    }

    /// The managed sources alone (files, drop-ins, configuration profile), else the
    /// default: what applies to a folder whose own settings are unknown.
    public func resolveManaged() -> Resolution {
        resolveSources(configDir: nil, projectCwds: [])
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
                          unreadable: unreadable.filter { seen.insert($0).inserted }, origin: first.origin)
    }

    private func resolveSources(configDir: String?, projectCwds: [String]) -> Resolution {
        let dir = configDir.map(expandTilde)
        var candidates: [(days: Int, source: Source, origin: String?)] = []
        var unreadable: [String] = []

        func take(_ reading: Reading, _ source: Source, _ name: String) {
            switch reading {
            case .absent: break
            case .days(let days): candidates.append((max(0, days), source, name.hasPrefix("/") ? name : nil))
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
        var projectFiles = Set<String>()
        for cwd in projectCwds {
            for file in Self.projectSettingsFiles(cwd: cwd) where projectFiles.insert(file).inserted {
                take(Self.readSettingsFile(file),
                     file.hasSuffix("/settings.local.json") ? .projectLocalSettings : .projectSettings, file)
            }
        }

        // Smallest wins; on a tie the earlier (more managed) source is named.
        guard let smallest = candidates.enumerated().min(by: { a, b in
            a.element.days != b.element.days ? a.element.days < b.element.days : a.offset < b.offset
        })?.element else {
            return Resolution(days: Self.defaultDays, source: .claudeDefault, unreadable: unreadable)
        }
        return Resolution(days: smallest.days, source: smallest.source, unreadable: unreadable,
                          origin: smallest.origin)
    }

    /// The project settings files that can set the period of a session started in `cwd`:
    /// `.claude/settings.json` and `.claude/settings.local.json` in `cwd` and in every folder
    /// above it up to the root of its git repository (Claude Code keeps a repository's
    /// project settings at its root), plus, for a git worktree, the main checkout's root,
    /// where Claude Code keeps a worktree's local settings. Outside a repository, `cwd`'s own.
    public static func projectSettingsFiles(cwd: String) -> [String] {
        let start = (expandTilde(cwd) as NSString).standardizingPath
        guard start.hasPrefix("/") else { return [] }
        let fm = FileManager.default
        var folders: [String] = []
        var folder = start
        var inRepository = false
        while true {
            folders.append(folder)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: folder + "/.git", isDirectory: &isDirectory) {
                inRepository = true
                if !isDirectory.boolValue, let main = mainCheckout(ofGitFile: folder + "/.git") {
                    folders.append(main)
                }
                break
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { break }
            folder = parent
        }
        if !inRepository { folders = [start] }
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
            .flatMap { [$0 + "/.claude/settings.json", $0 + "/.claude/settings.local.json"] }
    }

    /// For a worktree's `.git` file (`gitdir: <main>/.git/worktrees/<name>`): `<main>`, the
    /// main checkout. nil for anything else, such as a submodule's.
    static func mainCheckout(ofGitFile path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") {
            gitDir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(gitDir)
        }
        gitDir = (gitDir as NSString).standardizingPath
        // `<main>/.git/worktrees/<name>`, or wherever its `commondir` says the shared one is.
        var common: String
        if let relative = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty {
            common = relative.hasPrefix("/") ? relative : (gitDir as NSString).appendingPathComponent(relative)
        } else {
            let parent = (gitDir as NSString).deletingLastPathComponent
            guard (parent as NSString).lastPathComponent == "worktrees" else { return nil }
            common = (parent as NSString).deletingLastPathComponent
        }
        common = (common as NSString).standardizingPath
        guard (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
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
