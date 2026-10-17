// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// One made-up Claude account of the README screenshots.
public struct DemoAccount: Sendable, Equatable {
    /// The account's folder under the demo home: `.claude` is the default account, the
    /// one the others share their sessions into.
    public let folder: String
    /// The name given in Settings › Accounts, which the notch and Workspaces show.
    public let name: String
    public let email: String
    public let organizationUUID: String
    public let organizationName: String
    /// Claude Code's tier id, and the plan as Brow writes it.
    public let tier: String
    public let plan: String
    /// Percent used of the 5-hour limit, the weekly one and, where the plan has one, the
    /// weekly Opus limit; and when the first two reset, from now.
    public let fiveHour: Double
    public let fiveHourResetHours: Double
    public let weekly: Double
    public let weeklyResetDays: Double
    public let opusWeekly: Double?
    /// What the sign-in token has left, and the days to the estimated renewal (nil: no
    /// subscription facts).
    public let tokenHours: Double
    public let renewsInDays: Int?
    /// In Workspaces: sessions shared into the default account, the status line
    /// captured, the default model and effort.
    public let shared: Bool
    public let capturing: Bool
    public let defaultModel: String?
    public let defaultEffort: String?

    /// Its name in Grove's config: the email, as the engine names an account.
    public var configName: String { email }

    /// The account as Grove's config holds it, its folder under `root`: `~`, or the demo
    /// home where a test needs the folders spelled out.
    public func accountConfig(root: String) -> AccountConfig {
        AccountConfig(name: configName, configDir: root + "/" + folder, sharedStore: shared,
                      monitoring: capturing, defaultModel: defaultModel, defaultEffort: defaultEffort)
    }

    /// Whether `dir` — absolute, or as `~/…` expanded against any home — is this
    /// account's folder.
    public func owns(_ dir: String) -> Bool {
        var dir = dir
        if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir.hasSuffix("/" + folder)
    }
}

/// The accounts every README screenshot shows — the notch, Settings, Workspaces — in one
/// place, so the pictures agree wherever two of them meet: the same folders, names,
/// plans and limits. Every name and number here is invented.
public enum DemoAccounts {
    /// A home that reads like one in Settings. Nothing exists there, and nothing is read
    /// from it or written to it.
    public static let home = "/Users/demo"

    public static let personal = DemoAccount(
        folder: ".claude", name: "Personal", email: "alex@example.com",
        organizationUUID: "org-demo-personal", organizationName: "Personal",
        tier: "default_claude_max_5x", plan: "Max 5x",
        fiveHour: 12, fiveHourResetHours: 3.7, weekly: 34, weeklyResetDays: 4.3, opusWeekly: nil,
        tokenHours: 6.4, renewsInDays: 9,
        shared: false, capturing: true, defaultModel: "sonnet", defaultEffort: nil)

    public static let work = DemoAccount(
        folder: ".claude-accounts/work", name: "Work", email: "alex.morgan@example.com",
        organizationUUID: "org-demo-work", organizationName: "Acme Shop",
        tier: "default_claude_max_20x", plan: "Max 20x",
        fiveHour: 78, fiveHourResetHours: 1.2, weekly: 61, weeklyResetDays: 2.1, opusWeekly: 45,
        tokenHours: 3.1, renewsInDays: 20,
        shared: true, capturing: true, defaultModel: "opus", defaultEffort: "high")

    public static let team = DemoAccount(
        folder: ".claude-accounts/team", name: "Team", email: "platform-team@example.com",
        organizationUUID: "org-demo-team", organizationName: "Acme Platform",
        tier: "default_claude_max_20x", plan: "Max 20x",
        fiveHour: 41, fiveHourResetHours: 4.4, weekly: 93, weeklyResetDays: 0.9, opusWeekly: nil,
        tokenHours: 7.8, renewsInDays: nil,
        shared: true, capturing: false, defaultModel: nil, defaultEffort: nil)

    /// In the panel's order.
    public static let all = [personal, work, team]

    /// The two projects, as Grove's config holds them: a multi-repo shop that launches on
    /// Work by default, and a small app.
    public static let shopPath = home + "/Code/acme-shop"
    public static let notesPath = home + "/Code/field-notes"

    /// The account that owns any of `dirs`.
    public static func account(owning dirs: [String]) -> DemoAccount? {
        all.first { account in dirs.contains(where: account.owns) }
    }

    /// The account with this name in Grove's config.
    public static func account(configName: String) -> DemoAccount? {
        all.first { $0.configName == configName }
    }
}
