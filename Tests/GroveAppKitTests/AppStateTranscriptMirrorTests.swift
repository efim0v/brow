import XCTest
@testable import GroveAppKit
@testable import GroveCore

@MainActor
final class AppStateTranscriptMirrorTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-mirror")
        configURL = root.appendingPathComponent("config.json")
    }

    // MARK: - helpers

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        // Fail-safe: always point canonical away from the real ~/.claude.
        state.folders.canonicalDir = root.appendingPathComponent("canonical-default").path
        return state
    }

    // MARK: - tests

    func testReconcileTranscriptsRestoresAMissingTranscript() async throws {
        let canonical = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: canonical.appendingPathComponent("projects/-p"),
                               withIntermediateDirectories: true)
        let live = canonical.appendingPathComponent("projects/-p/iiii.jsonl")
        try "hi\n".write(to: live, atomically: true, encoding: .utf8)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])

        await state.reconcileTranscripts()      // links live → mirror
        try fm.removeItem(at: live)             // out-of-band delete
        await state.reconcileTranscripts()      // restores from mirror
        XCTAssertTrue(fm.fileExists(atPath: live.path),
                      "AppState should restore via the mirror")
    }

    func testDisabledIsANoOp() async throws {
        let canonical = root.appendingPathComponent("canonical-off")
        try fm.createDirectory(at: canonical.appendingPathComponent("projects/-p"),
                               withIntermediateDirectories: true)
        try "hi\n".write(to: canonical.appendingPathComponent("projects/-p/jjjj.jsonl"),
                         atomically: true, encoding: .utf8)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        var cfg = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        cfg.transcriptMirror = TranscriptMirrorSettings(enabled: false)
        state.config = cfg

        await state.reconcileTranscripts()
        XCTAssertFalse(
            fm.fileExists(atPath: TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)),
            "disabled → no mirror dir created")
    }

    /// The case from grove#6, end to end through AppState: an account that keeps transcripts
    /// for 7 days (its own settings.json), a transcript last active 45 days ago, deleted
    /// the way Claude Code's sweep deletes it. The engine's default settings (on, 90
    /// days) restored it before grove#6 was fixed.
    func testReconcileTranscriptsDoesNotUndoClaudeCodesRetention() async throws {
        let canonical = root.appendingPathComponent("canonical-retention")
        let dir = canonical.appendingPathComponent("projects/-p")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.jsonl")
        let young = dir.appendingPathComponent("young.jsonl")
        for file in [old, young] { try "turn\n".write(to: file, atomically: true, encoding: .utf8) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-45 * 86_400)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: young.path)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        // Mirrored while it was still kept: the account kept 60 days then, 7 now.
        try #"{"cleanupPeriodDays": 60}"#.write(to: canonical.appendingPathComponent("settings.json"),
                                                atomically: true, encoding: .utf8)
        await state.reconcileTranscripts()
        let mirrored = TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)
            + "/\(accountKey(canonical.path))/-p/old.jsonl"
        XCTAssertTrue(fm.fileExists(atPath: mirrored), "fixture: the old transcript is in the mirror")
        try #"{"cleanupPeriodDays": 7}"#.write(to: canonical.appendingPathComponent("settings.json"),
                                               atomically: true, encoding: .utf8)

        try fm.removeItem(at: old)
        try fm.removeItem(at: young)
        await state.reconcileTranscripts()

        XCTAssertFalse(fm.fileExists(atPath: old.path), "past the account's 7 days: stays deleted")
        XCTAssertTrue(fm.fileExists(atPath: young.path), "inside it: restored")
        XCTAssertEqual(state.transcriptRetention["default"]?.days, 7)
        XCTAssertEqual(state.transcriptRetention["default"]?.source, .accountSettings)
        XCTAssertFalse(fm.fileExists(atPath: mirrored), "and the mirror does not keep it either")
    }

    /// Settings shows each account's period even with the safety net off.
    func testRetentionIsReadWithTheSafetyNetOff() async throws {
        let canonical = root.appendingPathComponent("canonical-read-only")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        try #"{"cleanupPeriodDays": 12}"#.write(to: canonical.appendingPathComponent("settings.json"),
                                                atomically: true, encoding: .utf8)
        let state = makeState()
        state.folders.canonicalDir = canonical.path
        var cfg = GroveConfig(version: 1, workspacesRootTemplate: "~/w", projects: [],
                              accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        cfg.transcriptMirror = TranscriptMirrorSettings(enabled: false)
        state.config = cfg
        await state.refreshTranscriptRetention()
        XCTAssertEqual(state.transcriptRetention["default"]?.days, 12)
        XCTAssertFalse(fm.fileExists(atPath: TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)))
    }

    /// A config Brow creates (no file yet) starts with the safety net off; a Grove
    /// config without the key keeps reading as on, as Grove always read it.
    func testANewConfigStartsWithTheSafetyNetOff() throws {
        XCTAssertFalse(makeState().config.transcriptMirror.enabled)
        try #"{"version":1,"workspacesRootTemplate":"~/w","projects":[],"accounts":[]}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(makeState().config.transcriptMirror.enabled)
    }
}
