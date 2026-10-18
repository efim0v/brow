// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import BrowKit

final class BrowSettingsTests: XCTestCase {
    private func account(_ org: String, email: String?, dir: String) -> DiscoveredAccount {
        DiscoveredAccount(organizationUuid: org, email: email, tier: nil, configDir: dir, aliasDirs: [], tokenExpiresAt: nil)
    }

    func testDefaults() {
        let s = BrowSettings()
        XCTAssertTrue(s.showNotch, "the notch is on unless turned off")
        XCTAssertTrue(s.allowPromptFallback)
        XCTAssertNil(s.claudePath)
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertTrue(s.extraDirs.isEmpty)
        XCTAssertEqual(s.earsPlacement, .beside)
    }

    /// A file from before the switch shows the notch; the switch round-trips; a bad value
    /// costs only that field.
    func testShowNotchLoadsFromOlderFilesAndRoundTrips() throws {
        let dir = try Fixture.tempDir("settings-notch").path
        let store = BrowSettingsStore(directory: dir)
        try #"{"showEars":false}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertTrue(store.load().showNotch)
        var settings = store.load()
        settings.showNotch = false
        try store.save(settings)
        XCTAssertFalse(store.load().showNotch)
        try #"{"showNotch":"no","claudePath":"/opt/claude"}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertTrue(store.load().showNotch)
        XCTAssertEqual(store.load().claudePath, "/opt/claude")
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

    /// The pet is on by default. A `config.json` from before it existed, or with a value that is not a
    /// bool, reads as on, and that one field takes nothing else with it.
    func testShowPetIsOnByDefaultAndNeverCostsTheRestOfTheFile() throws {
        XCTAssertTrue(BrowSettings().showPet)
        let dir = try Fixture.tempDir("settings-pet").path
        let store = BrowSettingsStore(directory: dir)
        try #"{"claudePath":"/opt/claude","showCalendar":false}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertTrue(store.load().showPet, "absent in an older file")
        XCTAssertFalse(store.load().showCalendar)
        for odd in [#""yes""#, "1", "null", #"{"on":true}"#] {
            try #"{"claudePath":"/opt/claude","showCalendar":false,"showPet":\#(odd)}"#
                .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
            let loaded = store.load()
            XCTAssertTrue(loaded.showPet, odd)
            XCTAssertEqual(loaded.claudePath, "/opt/claude", "the rest of the file is intact (\(odd))")
            XCTAssertFalse(loaded.showCalendar, odd)
        }
        var off = BrowSettings()
        off.showPet = false
        try store.save(off)
        XCTAssertFalse(store.load().showPet)
        XCTAssertEqual(store.load(), off)
    }

    /// What someone updating to this build has on disk: a `config.json` that 0.3.1 wrote, or that 0.4.0
    /// wrote after it, neither of which knew the pet. Every value it holds comes back, nothing is set
    /// aside as unreadable, and the pet is on; the next save keeps all of it and adds the pet's key.
    func testSettingsFromBeforeThePetKeepEveryValueAndShowThePet() throws {
        // Every key 0.3.1 wrote, none of them at its default, as its encoder wrote them.
        let from031 = #"""
        {
          "accounts" : {
            "org-old" : {
              "hidden" : true
            },
            "org-work" : {
              "hidden" : false,
              "name" : "Work"
            }
          },
          "allowPromptFallback" : false,
          "cardShape" : "square",
          "cardShowNames" : true,
          "claudePath" : "/opt/homebrew/bin/claude",
          "earsPlacement" : "below",
          "extraDirs" : [
            "~/clients/.claude"
          ],
          "notifyLimits" : true,
          "notifyResets" : true,
          "notifyThresholds" : [
            50,
            90
          ],
          "showCalendar" : false,
          "showEars" : false
        }
        """#
        var settings031 = BrowSettings()
        settings031.accounts = ["org-old": AccountOverride(name: nil, hidden: true),
                                "org-work": AccountOverride(name: "Work", hidden: false)]
        settings031.allowPromptFallback = false
        settings031.cardShape = .square
        settings031.cardShowNames = true
        settings031.claudePath = "/opt/homebrew/bin/claude"
        settings031.earsPlacement = .below
        settings031.extraDirs = ["~/clients/.claude"]
        settings031.notifyLimits = true
        settings031.notifyResets = true
        settings031.notifyThresholds = [50, 90]
        settings031.showCalendar = false
        settings031.showEars = false
        // The same file after 0.4.0 saved it: those keys, and its own, the notch switch and Workspaces.
        let from040 = #"""
        {
          "accounts" : {
            "org-old" : {
              "hidden" : true
            },
            "org-work" : {
              "hidden" : false,
              "name" : "Work"
            }
          },
          "allowPromptFallback" : false,
          "cardShape" : "square",
          "cardShowNames" : true,
          "claudePath" : "/opt/homebrew/bin/claude",
          "earsPlacement" : "below",
          "extraDirs" : [
            "~/clients/.claude"
          ],
          "notifyLimits" : true,
          "notifyResets" : true,
          "notifyThresholds" : [
            50,
            90
          ],
          "showCalendar" : false,
          "showEars" : false,
          "showNotch" : true,
          "workspaces" : {
            "enabled" : true,
            "groveSetup" : true,
            "importedGroveMaterial" : true,
            "panelMaterial" : "visualEffect",
            "showInMenuBar" : false
          }
        }
        """#
        var settings040 = settings031
        settings040.workspaces = WorkspacesSettings(enabled: true, showInMenuBar: false, panelMaterial: "visualEffect",
                                                    importedGroveMaterial: true, groveSetup: true)
        for (written, file, settings) in [("0.3.1", from031, settings031), ("0.4.0", from040, settings040)] {
            let dir = try Fixture.tempDir("settings-before-pet").path
            let store = BrowSettingsStore(directory: dir)
            try file.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
            let loaded = store.load()
            XCTAssertTrue(loaded.showPet, "\(written) had no such key: the pet is on")
            XCTAssertEqual(loaded, settings, "every value \(written) wrote")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupFile), "\(written): nothing unreadable")
            try store.save(loaded)
            let saved = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: dir + "/config.json"))) as? [String: Any])
            XCTAssertEqual(saved["showPet"] as? Bool, true, written)
            XCTAssertEqual(store.load(), settings, "\(written), saved again")
        }
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
