// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

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

/// Where the account pickers get those numbers: the app hosting the engine.
@MainActor
public protocol AccountLimitsProviding: AnyObject {
    /// The limits of the account that owns any of `dirs` (its config folder or an alias).
    func limits(forConfigDirs dirs: [String]) -> AccountLimits?
}
