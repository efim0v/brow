import XCTest
import GroveCore
@testable import BrowKit

final class BrowSettingsTests: XCTestCase {
    private func account(_ org: String, email: String?, dir: String) -> DiscoveredAccount {
        DiscoveredAccount(organizationUuid: org, email: email, tier: nil, configDir: dir, aliasDirs: [], tokenExpiresAt: nil)
    }

    func testDefaults() {
        let s = BrowSettings()
        XCTAssertTrue(s.allowPromptFallback)
        XCTAssertNil(s.claudePath)
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertTrue(s.extraDirs.isEmpty)
    }

    func testDisplayNamePrecedence() {
        var s = BrowSettings()
        let a = account("org", email: "me@x", dir: "/Users/me/.claude-accounts/work")
        XCTAssertEqual(s.displayName(for: a), "me@x")
        s.accounts["org"] = AccountOverride(name: "Work", hidden: false)
        XCTAssertEqual(s.displayName(for: a), "Work")
        s.accounts["org"] = AccountOverride(name: "   ", hidden: false)
        XCTAssertEqual(s.displayName(for: a), "me@x", "blank override falls through")
        XCTAssertEqual(BrowSettings().displayName(for: account("o2", email: nil, dir: "/x/.claude-accounts/apple")), "apple")
    }

    func testHidden() {
        var s = BrowSettings()
        XCTAssertFalse(s.isHidden("org"))
        s.accounts["org"] = AccountOverride(name: nil, hidden: true)
        XCTAssertTrue(s.isHidden("org"))
    }

    func testRoundTripAndMissingFieldsDecodeToDefaults() throws {
        let dir = try Fixture.tempDir("settings").path
        let store = BrowSettingsStore(directory: dir)
        XCTAssertEqual(store.load(), BrowSettings())
        var s = BrowSettings()
        s.accounts["org"] = AccountOverride(name: "Work", hidden: true)
        s.extraDirs = ["~/alt"]
        s.allowPromptFallback = false
        s.claudePath = "/opt/claude"
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        // Old file without the newer keys still loads.
        try #"{"accounts":{}}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), BrowSettings())
    }
}
