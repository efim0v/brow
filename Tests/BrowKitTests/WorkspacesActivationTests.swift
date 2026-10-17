import XCTest
import GroveCore
@testable import BrowKit

/// When Workspaces runs, the Grove-running guard, and the settings that carry the choice.
final class WorkspacesActivationTests: XCTestCase {
    // MARK: - the activation matrix

    func testItFollowsTheGroveConfigUntilTheUserChooses() {
        XCTAssertEqual(WorkspacesActivation.decide(setting: nil, groveConfigExists: false, groveRunning: false), .off,
                       "a Brow-only Mac: nothing of the engine runs")
        XCTAssertEqual(WorkspacesActivation.decide(setting: nil, groveConfigExists: true, groveRunning: false), .on,
                       "someone who used Grove gets their projects without asking")
    }

    func testTheUsersChoiceWinsEitherWay() {
        XCTAssertEqual(WorkspacesActivation.decide(setting: true, groveConfigExists: false, groveRunning: false), .on)
        XCTAssertEqual(WorkspacesActivation.decide(setting: false, groveConfigExists: true, groveRunning: false), .off)
    }

    /// Two engines would race on Grove's config.json and run two mirrors.
    func testNothingRunsWhileGroveAppRuns() {
        XCTAssertEqual(WorkspacesActivation.decide(setting: nil, groveConfigExists: true, groveRunning: true), .paused)
        XCTAssertEqual(WorkspacesActivation.decide(setting: true, groveConfigExists: false, groveRunning: true), .paused)
        XCTAssertEqual(WorkspacesActivation.decide(setting: false, groveConfigExists: true, groveRunning: true), .off,
                       "turned off is off, Grove or not")
        XCTAssertTrue(WorkspacesActivation.paused.isWanted)
        XCTAssertFalse(WorkspacesActivation.off.isWanted)
    }

    // MARK: - the guard

    func testGroveIsRecognisedByEitherBundleId() {
        XCTAssertTrue(GroveAppGuard(runningBundleIdentifiers: { ["com.apple.finder", "dev.artemefimov.grove3"] }).isGroveRunning)
        XCTAssertTrue(GroveAppGuard(runningBundleIdentifiers: { ["dev.artemefimov.grove"] }).isGroveRunning)
        XCTAssertFalse(GroveAppGuard(runningBundleIdentifiers: { ["dev.artemefimov.brow", "com.cmuxterm.app"] }).isGroveRunning)
        XCTAssertTrue(GroveAppGuard.isGrove("dev.artemefimov.grove3"))
        XCTAssertFalse(GroveAppGuard.isGrove("dev.artemefimov.brow"))
        XCTAssertFalse(GroveAppGuard.isGrove(nil))
    }

    // MARK: - the settings

    func testWorkspacesSettingsRoundTripAndDefault() throws {
        let dir = try Fixture.tempDir("settings-workspaces").path
        let store = BrowSettingsStore(directory: dir)
        XCTAssertNil(store.load().workspaces.enabled)
        XCTAssertTrue(store.load().workspaces.showInMenuBar)
        var s = BrowSettings()
        s.workspaces = WorkspacesSettings(enabled: true, showInMenuBar: false, panelMaterial: "visualEffect",
                                          importedGroveMaterial: true)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupFile), "a good file leaves no copy")
    }

    /// A 0.3.x file has no `workspaces` key; it loads with Workspaces undecided.
    func testAnOlderFileLoadsWithWorkspacesUndecided() throws {
        let dir = try Fixture.tempDir("settings-031").path
        try #"{"accounts":{},"allowPromptFallback":false,"earsPlacement":"below"}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = BrowSettingsStore(directory: dir).load()
        XCTAssertEqual(loaded.workspaces, WorkspacesSettings())
        XCTAssertEqual(loaded.earsPlacement, .below)
    }

    /// brow#7: one bad value used to reset every setting. It costs that field now, and
    /// the file as it was is kept as config.json.bak before anything overwrites it.
    func testOneBadValueCostsOnlyThatFieldAndTheFileIsKept() throws {
        let dir = try Fixture.tempDir("settings-lenient").path
        let original = #"""
        {"accounts":5,"extraDirs":["~/alt"],"claudePath":"/opt/claude","showEars":false,
         "allowPromptFallback":"no","workspaces":{"enabled":true,"showInMenuBar":"sometimes"}}
        """#
        try original.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let store = BrowSettingsStore(directory: dir)
        let loaded = store.load()
        XCTAssertEqual(loaded.accounts, [:])
        XCTAssertTrue(loaded.allowPromptFallback, "the unreadable value takes its default")
        XCTAssertEqual(loaded.extraDirs, ["~/alt"])
        XCTAssertEqual(loaded.claudePath, "/opt/claude")
        XCTAssertFalse(loaded.showEars)
        XCTAssertEqual(loaded.workspaces.enabled, true, "inside the object too, field by field")
        XCTAssertTrue(loaded.workspaces.showInMenuBar)
        XCTAssertEqual(try String(contentsOfFile: store.backupFile, encoding: .utf8), original)
    }

    func testOneBadAccountFieldKeepsTheName() throws {
        let dir = try Fixture.tempDir("settings-account-field").path
        try #"{"accounts":{"org":{"name":"Work","hidden":"yes"}}}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = BrowSettingsStore(directory: dir).load()
        XCTAssertEqual(loaded.accounts["org"]?.name, "Work")
        XCTAssertEqual(loaded.accounts["org"]?.hidden, false)
    }

    func testAFileThatIsNotSettingsAtAllIsKeptAndDefaultsLoad() throws {
        let dir = try Fixture.tempDir("settings-garbage").path
        try "not json {".write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let store = BrowSettingsStore(directory: dir)
        XCTAssertEqual(store.load(), BrowSettings())
        XCTAssertEqual(try String(contentsOfFile: store.backupFile, encoding: .utf8), "not json {")
    }
}
