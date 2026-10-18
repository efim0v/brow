// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore
@testable import BrowKit

/// A `LimitsStore` with fictional accounts, for the pet's controller tests and the renders through Brow's
/// real views. As in `DemoScreenshotTests`, nothing real is read: the accounts live in a temporary
/// `$HOME` stand-in, the "Keychain" is a canned reader, the app-support directory is a temporary one,
/// and no refresh cycle ever runs (no network, no `claude`).
@MainActor
enum PetAppFixture {
    struct Account {
        var org = "org-demo-personal"
        var name = "Personal"
        var tier = "default_claude_max_5x"
        var five: Double = 41
        var fiveResetHours: Double = 3.2
        var week: Double = 63
        var weekResetDays: Double = 2.5
        /// Seconds before `now` the reading was fetched.
        var age: TimeInterval = 25
    }

    private final class Credentials: CredentialsReading, @unchecked Sendable {
        let expiry: Date
        init(_ expiry: Date) { self.expiry = expiry }
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "demo", expiresAt: expiry) }
        func invalidate(configDir: String) {}
        func grant(configDir: String) -> CredentialsAccess { access(configDir: configDir) }
    }

    private struct NoNetwork: UsageFetching {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
    }

    private struct NoCommands: CommandRunning {
        func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                 timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, stdout: "", stderr: "fixture: commands are not run")
        }
    }

    /// The store after its first account scan, and the temporary directory everything lives in.
    static func store(_ accounts: [Account], now: Date, edit: (inout BrowSettings) -> Void = { _ in },
                      scan: Bool = true) async throws -> (store: LimitsStore, dir: URL) {
        let root = try Fixture.tempDir("pet-app")
        let home = root.appendingPathComponent("home").path
        let appDir = root.appendingPathComponent("app").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func window(_ used: Double, in seconds: Double) -> CapturedWindow {
            // Resets land on the hour, as the real ones do.
            let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
            return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
        }
        var snapshots: [String: LimitSnapshot] = [:]
        var settings = BrowSettings()
        for account in accounts {
            let dir = home + "/.claude-accounts/" + account.name.lowercased()
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: ["oauthAccount": [
                "organizationUuid": account.org, "emailAddress": "\(account.name.lowercased())@example.com",
                "organizationRateLimitTier": account.tier]])
            try json.write(to: URL(fileURLWithPath: dir + "/.claude.json"))
            snapshots[account.org] = LimitSnapshot(organizationUuid: account.org, fetchedAt: now.addingTimeInterval(-account.age),
                                                   fiveHour: window(account.five, in: account.fiveResetHours * 3600),
                                                   sevenDay: window(account.week, in: account.weekResetDays * 86_400),
                                                   weeklyScoped: nil, weeklyScopedModel: nil)
            settings.accounts[account.org] = AccountOverride(name: account.name, hidden: false)
        }
        settings.showCalendar = false
        edit(&settings)
        try LimitSnapshotStore(directory: appDir).saveFile(LimitsFile(snapshots: snapshots, accounts: [], subscriptions: [:]))
        try BrowSettingsStore(directory: appDir).save(settings)
        let credentials = Credentials(now.addingTimeInterval(6 * 3600))
        let keeper = TokenKeeper(runner: NoCommands(), credentials: credentials, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { now })
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: home, credentials: credentials),
                                            keeper: keeper,
                                            client: OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: credentials),
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir), now: { now }))
        if scan { await store.bootstrap() }
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        return (store, root)
    }
}

/// A clock a test moves by hand: both of `PetTime`'s clocks, together.
@MainActor
final class PetTestClock {
    var now: PetTime
    init(_ now: PetTime) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.adding(seconds) }
}
