import Foundation
import GroveCore

/// One Claude account as both halves of Brow know it: the notch's `DiscoveredAccount`
/// (an organisation, found by scanning folders) and Workspaces' `AccountConfig` (an
/// entry in Grove's config). They are the same account when they share a config folder.
public enum WorkspacesAccountJoin {
    /// The Workspaces account that shares a config folder — its own or an alias — with
    /// `account`, if any.
    public static func match(_ account: DiscoveredAccount, in accounts: [AccountConfig]) -> AccountConfig? {
        let dirs = Set(([account.configDir] + account.aliasDirs).map(normalized))
        return accounts.first { !dirs.isDisjoint(with: $0.allConfigDirs.map(normalized)) }
    }

    /// The notch's account for a Workspaces account, the other way round.
    public static func match(_ account: AccountConfig, in accounts: [DiscoveredAccount]) -> DiscoveredAccount? {
        let dirs = Set(account.allConfigDirs.map(normalized))
        return accounts.first { !dirs.isDisjoint(with: ([$0.configDir] + $0.aliasDirs).map(normalized)) }
    }

    /// The Workspaces accounts no card shows: one whose folder the notch's scan does not
    /// list (no sign-in Brow can read there), and a second Workspaces account of an
    /// organisation the notch shows once (`match` gives a card the first). Settings
    /// lists them on their own, so their sharing, status-line capture and defaults can
    /// still be changed — turning capture off before an uninstall included.
    public static func unmatched(_ accounts: [AccountConfig], cards: [DiscoveredAccount]) -> [AccountConfig] {
        let shown = Set(cards.compactMap { match($0, in: accounts)?.name })
        return accounts.filter { !shown.contains($0.name) }
    }

    /// Workspaces' folders the notch's scan would not find by itself — anything outside
    /// `~/.claude` and `~/.claude-accounts` — so they are scanned too.
    public static func extraDirs(for accounts: [AccountConfig], home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        return accounts.flatMap(\.allConfigDirs).map(normalized).filter { dir in
            guard dir != home + "/.claude", !dir.hasPrefix(home + "/.claude-accounts/") else { return false }
            return seen.insert(dir).inserted
        }
    }

    /// Tilde expanded, no trailing slash: the form both halves compare in.
    static func normalized(_ path: String) -> String {
        var dir = expandTilde(path)
        if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }
}
