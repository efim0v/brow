// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import XCTest
import DemoFixture
import GroveCore
@testable import BrowKit

/// A `LimitsStore` holding made-up accounts, for the tests and renders of the one-window
/// panel: the README's three (`DemoAccounts`) and five more invented ones. Nothing real is
/// read: the accounts are handed to the store as a scan would find them, in a home folder
/// that does not exist, the "Keychain" is a canned reader, the app-support directory is a
/// temp dir, and no refresh cycle ever runs (no network, no `claude`).
@MainActor
enum MadeUpLimits {
    struct Account {
        let folder: String
        let name: String
        let email: String
        let organization: String
        let tier: String
        let fiveHour: Double
        let fiveHourResetHours: Double
        let weekly: Double
        let weeklyResetDays: Double
        let opusWeekly: Double?
        let renewsInDays: Int?
    }

    /// The README's three, then five more: eight in all.
    static let all: [Account] = DemoAccounts.all.map {
        Account(folder: $0.folder, name: $0.name, email: $0.email, organization: $0.organizationUUID, tier: $0.tier,
                fiveHour: $0.fiveHour, fiveHourResetHours: $0.fiveHourResetHours, weekly: $0.weekly,
                weeklyResetDays: $0.weeklyResetDays, opusWeekly: $0.opusWeekly, renewsInDays: $0.renewsInDays)
    } + [
        Account(folder: ".claude-accounts/side", name: "Side project", email: "alex.side@example.com",
                organization: "org-demo-side", tier: "default_claude_pro", fiveHour: 64, fiveHourResetHours: 2.3,
                weekly: 48, weeklyResetDays: 2.1, opusWeekly: nil, renewsInDays: 2),
        Account(folder: ".claude-accounts/northwind", name: "Client — Northwind", email: "alex@northwind.example",
                organization: "org-demo-northwind", tier: "default_claude_max_5x", fiveHour: 22, fiveHourResetHours: 0.3,
                weekly: 71, weeklyResetDays: 5.4, opusWeekly: 58, renewsInDays: 16),
        Account(folder: ".claude-accounts/lab", name: "Research lab", email: "lab@example.org",
                organization: "org-demo-lab", tier: "default_claude_max_20x", fiveHour: 5, fiveHourResetHours: 5.3,
                weekly: 17, weeklyResetDays: 6.2, opusWeekly: nil, renewsInDays: nil),
        Account(folder: ".claude-accounts/weekend", name: "Weekend hacks", email: "alex.weekend@example.com",
                organization: "org-demo-weekend", tier: "default_claude_pro", fiveHour: 0, fiveHourResetHours: 5.3,
                weekly: 9, weeklyResetDays: 2.1, opusWeekly: nil, renewsInDays: 11),
        Account(folder: ".claude-accounts/oncall", name: "Ops on-call", email: "oncall@example.com",
                organization: "org-demo-oncall", tier: "default_claude_max_5x", fiveHour: 88, fiveHourResetHours: 0.3,
                weekly: 66, weeklyResetDays: 3.3, opusWeekly: nil, renewsInDays: 25),
    ]

    private final class Credentials: CredentialsReading, @unchecked Sendable {
        let expiries: [String: Date]
        init(_ expiries: [String: Date]) { self.expiries = expiries }
        func token(configDir: String) -> ClaudeToken? {
            expiries[configDir].map { ClaudeToken(value: "made-up", expiresAt: $0) }
        }
        func invalidate(configDir: String) {}
        func grant(configDir: String) -> CredentialsAccess { access(configDir: configDir) }
    }

    /// Never called: no refresh cycle runs.
    private struct NoNetwork: UsageFetching {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
    }
    private struct NoCommands: CommandRunning {
        func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                 timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, stdout: "", stderr: "made-up: commands are not run")
        }
    }

    /// The first `count` accounts of `all`, read at `now`. `sameDay`: every weekly window
    /// resets on one day, the day after `now` — the panel's tallest calendar.
    /// `settings` adjusts what Settings has on (the calendar, the pet, Workspaces).
    static func store(count: Int = 3, sameDay: Bool = false, now: Date, appDir: String,
                      settings adjust: (inout BrowSettings) -> Void = { _ in }) throws -> LimitsStore {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var discovered: [DiscoveredAccount] = []
        var expiries: [String: Date] = [:]
        var snapshots: [String: LimitSnapshot] = [:]
        var subscriptions: [String: SubscriptionInfo] = [:]
        var settings = BrowSettings()
        for account in all.prefix(count) {
            let dir = DemoAccounts.home + "/" + account.folder
            let expiry = now.addingTimeInterval(5 * 3600)
            expiries[dir] = expiry
            discovered.append(DiscoveredAccount(organizationUuid: account.organization, email: account.email,
                                                tier: account.tier, configDir: dir, aliasDirs: [],
                                                tokenExpiresAt: expiry))
            func window(_ used: Double, in seconds: Double) -> CapturedWindow {
                let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
                return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
            }
            let weeklyDays = sameDay ? 1.1 : account.weeklyResetDays
            snapshots[account.organization] = LimitSnapshot(
                organizationUuid: account.organization, fetchedAt: now.addingTimeInterval(-25),
                fiveHour: window(account.fiveHour, in: account.fiveHourResetHours * 3600),
                sevenDay: window(account.weekly, in: weeklyDays * 86_400),
                weeklyScoped: account.opusWeekly.map { window($0, in: weeklyDays * 86_400) },
                weeklyScopedModel: account.opusWeekly == nil ? nil : "Opus")
            if let days = account.renewsInDays {
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let renewal = utc.date(byAdding: .day, value: days, to: now)!
                subscriptions[account.organization] = SubscriptionInfo(
                    organizationUuid: account.organization, status: "active", billingType: "stripe_subscription",
                    createdAt: utc.date(byAdding: .month, value: -3, to: renewal), fetchedAt: now)
            }
            settings.accounts[account.organization] = AccountOverride(name: account.name, hidden: false)
        }
        adjust(&settings)
        try LimitSnapshotStore(directory: appDir)
            .saveFile(LimitsFile(snapshots: snapshots, accounts: [], subscriptions: subscriptions))
        try BrowSettingsStore(directory: appDir).save(settings)

        let credentials = Credentials(expiries)
        let client = OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: credentials)
        let keeper = TokenKeeper(runner: NoCommands(), credentials: credentials, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { now })
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: DemoAccounts.home, credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir),
                                            now: { now }))
        store.preview(accounts: discovered)
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        return store
    }

    /// Today at 09:41 in the time zone the test runs in.
    static func morning() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
    }

    /// A 14" MacBook Pro: 1512 × 982 pt, a 185 pt notch, 32 pt tall, the Dock at the bottom
    /// (the visible frame ends 70 pt above the screen's bottom edge).
    nonisolated static let screen14 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                        topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                        menuBarHeight: 33, notchHeight: 32,
                                        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))

    /// An external display without a notch: 1920 × 1080 pt, a 25 pt menu bar, the Dock hidden.
    nonisolated static let externalScreen = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                              topLeftArea: nil, topRightArea: nil, menuBarHeight: 25,
                                              visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
}
