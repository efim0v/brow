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
        XCTAssertEqual(s.earsPlacement, .beside)
    }

    /// The picker's order is the setting's order.
    func testEarsPlacementCases() {
        XCTAssertEqual(EarsPlacement.allCases, [.beside, .below])
        XCTAssertEqual(EarsPlacement(rawValue: "below"), .below)
    }

    func testEarsPlacementIsAbsentInOlderFilesAndRoundTrips() throws {
        let dir = try Fixture.tempDir("settings-ears").path
        let store = BrowSettingsStore(directory: dir)
        // A config written before the setting existed.
        try #"{"accounts":{},"allowPromptFallback":false}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load().earsPlacement, .beside)
        XCTAssertFalse(store.load().allowPromptFallback, "the rest of the file still decodes")

        var s = BrowSettings()
        s.earsPlacement = .below
        try store.save(s)
        XCTAssertEqual(store.load().earsPlacement, .below)
        XCTAssertEqual(store.load(), s)
    }

    /// `decodeIfPresent` answers nil only for a MISSING key. A key that is present with
    /// an unmatched value throws `dataCorrupted`, which used to fail `init(from:)`,
    /// which makes `load()` return a fresh `BrowSettings` — so one typo in one field
    /// silently discarded every account name, every alias dir, the `claude` path and
    /// `allowPromptFallback` (turning the limit-spending `-p` leg back on), and the next
    /// settings write made the loss permanent. The plan's own Task 10 tells the owner to
    /// hand-edit this very key with `plutil`.
    func testAnUnknownEarsPlacementKeepsEveryOtherField() throws {
        let dir = try Fixture.tempDir("settings-bad-ears").path
        let store = BrowSettingsStore(directory: dir)
        try #"""
        {"accounts":{"org":{"name":"Work","hidden":false}},"extraDirs":["~/alt"],
         "allowPromptFallback":false,"claudePath":"/opt/claude","earsPlacement":"sideways"}
        """#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)

        let loaded = store.load()
        XCTAssertEqual(loaded.earsPlacement, .beside, "the unusable field falls back to its default")
        XCTAssertEqual(loaded.accounts["org"]?.name, "Work", "…and takes nothing else with it")
        XCTAssertEqual(loaded.extraDirs, ["~/alt"])
        XCTAssertFalse(loaded.allowPromptFallback)
        XCTAssertEqual(loaded.claudePath, "/opt/claude")
    }

    /// The same for a value that is not even a string — a hand-edited number, or a key
    /// a later build writes as an object.
    func testAnEarsPlacementOfTheWrongTypeAlsoKeepsTheFile() throws {
        let dir = try Fixture.tempDir("settings-typed-ears").path
        let store = BrowSettingsStore(directory: dir)
        try #"{"claudePath":"/opt/claude","earsPlacement":3}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = store.load()
        XCTAssertEqual(loaded.earsPlacement, .beside)
        XCTAssertEqual(loaded.claudePath, "/opt/claude")
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
