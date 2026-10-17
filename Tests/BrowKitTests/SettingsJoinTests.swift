// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import ServiceManagement
import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// The one Settings window: an account card meets its Workspaces account by config
/// folder; the panel's links land on the right tab; launch at login reads back.
final class SettingsJoinTests: XCTestCase {
    private func discovered(_ dir: String, aliases: [String] = []) -> DiscoveredAccount {
        DiscoveredAccount(organizationUuid: "org", email: "a@example.com", tier: nil, configDir: dir,
                          aliasDirs: aliases, tokenExpiresAt: nil)
    }

    func testAnAccountMeetsItsWorkspacesAccountByFolder() {
        let home = NSHomeDirectory()
        let accounts = [AccountConfig(name: "default", configDir: "~/.claude"),
                        AccountConfig(name: "work", configDir: "~/.claude-accounts/work/")]
        XCTAssertEqual(WorkspacesAccountJoin.match(discovered(home + "/.claude-accounts/work"), in: accounts)?.name, "work",
                       "tilde and a trailing slash do not keep them apart")
        XCTAssertEqual(WorkspacesAccountJoin.match(discovered(home + "/.claude"), in: accounts)?.name, "default")
        XCTAssertNil(WorkspacesAccountJoin.match(discovered(home + "/.claude-accounts/other"), in: accounts))
    }

    /// One login in two folders is one account on both sides: an alias on either side
    /// is enough to meet.
    func testAliasesOnEitherSideJoin() {
        let accounts = [AccountConfig(name: "work", configDir: "/x/main", aliasDirs: ["/x/second"])]
        XCTAssertEqual(WorkspacesAccountJoin.match(discovered("/x/second"), in: accounts)?.name, "work")
        XCTAssertEqual(WorkspacesAccountJoin.match(discovered("/x/third", aliases: ["/x/main"]), in: accounts)?.name, "work")
        XCTAssertEqual(WorkspacesAccountJoin.match(accounts[0], in: [discovered("/x/second")])?.configDir, "/x/second")
    }

    /// A Workspaces account no card shows still gets a section of its own: a second
    /// folder of an organisation the notch shows once, and a folder with no sign-in.
    func testWorkspacesAccountsWithoutACardAreListedOnTheirOwn() {
        let accounts = [AccountConfig(name: "default", configDir: "/x/main"),
                        AccountConfig(name: "same-login", configDir: "/x/second"),
                        AccountConfig(name: "never-signed-in", configDir: "/x/empty")]
        // The scan folded /x/main and /x/second, one organisation, into one card.
        let cards = [discovered("/x/main", aliases: ["/x/second"])]
        XCTAssertEqual(WorkspacesAccountJoin.match(cards[0], in: accounts)?.name, "default")
        XCTAssertEqual(WorkspacesAccountJoin.unmatched(accounts, cards: cards).map(\.name),
                       ["same-login", "never-signed-in"])
        XCTAssertEqual(WorkspacesAccountJoin.unmatched(accounts, cards: []).map(\.name),
                       ["default", "same-login", "never-signed-in"], "no cards yet: every account")
        XCTAssertTrue(WorkspacesAccountJoin.unmatched([], cards: cards).isEmpty)
    }

    /// An account is gone only when every folder of it is: Settings then offers to take it
    /// out of Workspaces, since nothing re-creates a deleted folder any more.
    func testAnAccountIsGoneWhenEveryFolderOfItIs() {
        let account = AccountConfig(name: "work", configDir: "/x/main/", aliasDirs: ["/x/second"])
        XCTAssertTrue(WorkspacesAccountJoin.isGone(account, exists: { _ in false }))
        XCTAssertFalse(WorkspacesAccountJoin.isGone(account, exists: { $0 == "/x/second" }), "one folder left")
        XCTAssertFalse(WorkspacesAccountJoin.isGone(account, exists: { $0 == "/x/main" }),
                       "compared without the trailing slash")
        XCTAssertFalse(WorkspacesAccountJoin.isGone(AccountConfig(name: "tmp", configDir: NSTemporaryDirectory())))
    }

    func testThePanelsLinksLandOnTheirTabs() {
        XCTAssertEqual(SettingsPane(.workspaces), .workspaces)
        XCTAssertEqual(SettingsPane(.accounts), .accounts)
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["General", "Accounts", "Workspaces", "About"])
    }

    /// brow#8: the toggle is on only when macOS says so. Waiting for approval is off,
    /// with a line saying where to approve it; a failed change says why.
    func testLaunchAtLoginReadsWhatMacOSSays() {
        XCTAssertTrue(LaunchAtLogin.isOn(.enabled))
        XCTAssertFalse(LaunchAtLogin.isOn(.requiresApproval))
        XCTAssertFalse(LaunchAtLogin.isOn(.notRegistered))
        XCTAssertFalse(LaunchAtLogin.isOn(.notFound))
        XCTAssertNotNil(LaunchAtLogin.note(status: .requiresApproval, failure: nil))
        XCTAssertNil(LaunchAtLogin.note(status: .enabled, failure: nil))
        XCTAssertEqual(LaunchAtLogin.note(status: .notRegistered, failure: "denied"), "macOS did not change it: denied")
    }
}
