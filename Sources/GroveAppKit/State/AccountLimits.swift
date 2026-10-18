// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// One account's use of its 5-hour and weekly limits as the host app last read them —
/// Brow's notch — for the account pickers: "which account has room" next to "move the
/// work there". The engine itself never fetches a limit.
public struct AccountLimits: Equatable, Sendable {
    /// Percent used, 0…100; nil when the window is not known.
    public var fiveHour: Double?
    public var weekly: Double?
    /// The reading is older than the host calls fresh.
    public var stale: Bool

    public init(fiveHour: Double?, weekly: Double?, stale: Bool) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.stale = stale
    }

    /// "5h 42% · week 61%", with "· old" when the reading is stale; nil when neither
    /// window is known.
    public var label: String? {
        let parts = [fiveHour.map { "5h \(Self.percent($0))" }, weekly.map { "week \(Self.percent($0))" }]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + (stale ? " · old" : "")
    }

    static func percent(_ used: Double) -> String { "\(Int(min(max(used, 0), 100).rounded()))%" }
}

/// One account as the host app shows it — Brow's notch and Settings › Accounts — so
/// Workspaces calls it the same: the name the user gave it there (else its email) and
/// its plan as the notch writes it ("Max 20x"), not Grove's own account name and the
/// raw tier id.
public struct AccountLabel: Equatable, Sendable {
    public var name: String
    /// nil when the host does not know the plan.
    public var plan: String?

    public init(name: String, plan: String?) {
        self.name = name
        self.plan = plan
    }
}

/// Where the account pickers get those numbers, and the names: the app hosting the
/// engine. Both are joined to an account by its config folders.
@MainActor
public protocol AccountLimitsProviding: AnyObject {
    /// The limits of the account that owns any of `dirs` (its config folder or an alias).
    func limits(forConfigDirs dirs: [String]) -> AccountLimits?
    /// What the host calls the account that owns any of `dirs`; nil when it does not know
    /// the account. A provider without names leaves Grove's own.
    func label(forConfigDirs dirs: [String]) -> AccountLabel?
}

public extension AccountLimitsProviding {
    func label(forConfigDirs dirs: [String]) -> AccountLabel? { nil }

    /// What `account`, one of Grove's `accounts`, is called: the host's name for it, else
    /// Grove's own. Two of Grove's accounts can get one name from the host — two folders of
    /// an organisation the notch shows as one account — and would then read alike in every
    /// picker. Only the first keeps the host's name, as Settings › Accounts gives the
    /// notch's card the first; the others keep Grove's own names, which tell them apart.
    func displayName(for account: AccountConfig, among accounts: [AccountConfig]) -> String {
        func hostName(_ account: AccountConfig) -> String? {
            label(forConfigDirs: account.allConfigDirs.map(expandTilde))?.name
        }
        guard let name = hostName(account) else { return account.name }
        let first = accounts.first { hostName($0) == name }
        return first == nil || first?.name == account.name ? name : account.name
    }
}
