import Foundation
import GroveCore

/// An account as the last scan saw it, kept beside the snapshots so the first
/// frame after a relaunch can show the last real numbers — labelled with the
/// right email, weighted by the right tier, in the order the user last saw —
/// instead of blanks until `bootstrap()`'s Keychain reads return.
///
/// `DiscoveredAccount` itself is not `Codable` on purpose: only the durable
/// half of it belongs on disk. `aliasDirs` and `tokenExpiresAt` are facts about
/// the filesystem and the Keychain *right now*, so `discovered` deliberately
/// leaves them empty rather than replay a stale answer; the scan fills them in.
public struct PersistedAccount: Codable, Sendable, Equatable {
    public let organizationUuid: String
    public let email: String?
    public let tier: String?
    public let configDir: String
    /// Display position at the time of writing — the seed must not reshuffle the rows.
    public let order: Int

    public init(from account: DiscoveredAccount, order: Int) {
        self.organizationUuid = account.organizationUuid
        self.email = account.email
        self.tier = account.tier
        self.configDir = account.configDir
        self.order = order
    }

    public var discovered: DiscoveredAccount {
        DiscoveredAccount(organizationUuid: organizationUuid, email: email, tier: tier,
                          configDir: configDir, aliasDirs: [], tokenExpiresAt: nil)
    }
}
