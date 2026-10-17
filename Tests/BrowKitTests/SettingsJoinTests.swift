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
