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
    /// A token WAS readable for this account when the file was written. Not a token fact
    /// to replay — `discovered` still refuses to do that — but the one durable piece of
    /// evidence `LimitsStore` needs to tell "the Keychain is refusing us" from "this
    /// account has no token": a denial that is already in force at process start leaves
    /// every scan tokenless, so without a seed the in-memory `everHadTokens` set can
    /// never fill and the actionable "Keychain access denied" message is unreachable in
    /// exactly the case a login-item app meets most — a relaunch under a standing denial.
    public let hadToken: Bool

    public init(from account: DiscoveredAccount, order: Int) {
        self.organizationUuid = account.organizationUuid
        self.email = account.email
        self.tier = account.tier
        self.configDir = account.configDir
        self.order = order
        self.hadToken = account.tokenExpiresAt != nil
    }

    private enum CodingKeys: String, CodingKey {
        case organizationUuid, email, tier, configDir, order, hadToken
    }

    /// Hand-written for `hadToken` alone: the synthesised decoder would throw
    /// `keyNotFound` on every `limits.json` written before this field existed, and
    /// `LimitsFile` degrades an unreadable `accounts` array to `[]` — so the first
    /// launch after the update would come up with no seed at all, which is the very
    /// blank first frame the persisted accounts exist to prevent.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organizationUuid = try c.decode(String.self, forKey: .organizationUuid)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        configDir = try c.decode(String.self, forKey: .configDir)
        order = try c.decode(Int.self, forKey: .order)
        hadToken = try c.decodeIfPresent(Bool.self, forKey: .hadToken) ?? false
    }

    public var discovered: DiscoveredAccount {
        DiscoveredAccount(organizationUuid: organizationUuid, email: email, tier: tier,
                          configDir: configDir, aliasDirs: [], tokenExpiresAt: nil)
    }
}
