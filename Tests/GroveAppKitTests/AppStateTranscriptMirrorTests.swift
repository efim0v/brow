// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

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

    /// A transcript deleted out of band is listed, with where it ran, and comes back
    /// only when the user asks: nothing is put back by itself.
    func testAVanishedTranscriptComesBackOnlyWhenAskedFor() async throws {
        let canonical = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: canonical.appendingPathComponent("projects/-p"),
                               withIntermediateDirectories: true)
        let live = canonical.appendingPathComponent("projects/-p/iiii.jsonl")
        try #"{"type":"user","cwd":"/Users/demo/Code/shop"}"#.appending("\n")
            .write(to: live, atomically: true, encoding: .utf8)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])

        await state.reconcileTranscripts()      // links live → mirror
        XCTAssertTrue(state.restorableTranscripts.isEmpty)
        try fm.removeItem(at: live)             // out-of-band delete
        await state.reconcileTranscripts()
        XCTAssertFalse(fm.fileExists(atPath: live.path), "never put back by itself")
        let listed = try XCTUnwrap(state.restorableTranscripts.first)
        XCTAssertEqual(state.restorableTranscripts.count, 1)
        XCTAssertEqual(listed.entry.livePath, live.path)
        XCTAssertEqual(listed.accountName, "default")
        XCTAssertEqual(listed.cwd, "/Users/demo/Code/shop")

        let restored = await state.restoreTranscripts([listed])
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: live.path), "Restore puts it back from the mirror")
        XCTAssertTrue(state.restorableTranscripts.isEmpty)
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
        XCTAssertEqual(state.restorableTranscripts.map(\.entry.livePath), [young.path],
                       "inside them: offered back, the old one not")
        XCTAssertEqual(state.transcriptRetention["default"]?.days, 7)
        XCTAssertEqual(state.transcriptRetention["default"]?.source, .accountSettings)
        XCTAssertFalse(fm.fileExists(atPath: mirrored), "and the mirror does not keep it either")

        // Asking for the old one as well changes nothing for it.
        let stale = RestorableTranscript(
            entry: VanishedTranscript(mirrorPath: mirrored, livePath: old.path,
                                      accountKey: accountKey(canonical.path), lastActivity: Date()),
            accountName: "default", cwd: nil)
        let restored = await state.restoreTranscripts(state.restorableTranscripts + [stale])
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: young.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    /// A workspace the second account shares into the default one is judged by the second
    /// account's 7 days too: its Claude Code sweeps the shared folder.
    func testASharedWorkspaceIsJudgedByEveryAccountThatReachesIt() async throws {
        let canonical = root.appendingPathComponent("canonical-shared")
        let shared = canonical.appendingPathComponent("projects/-w")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let team = root.appendingPathComponent("team")
        try fm.createDirectory(at: team.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: team.appendingPathComponent("projects/-w"), withDestinationURL: shared)
        let transcript = shared.appendingPathComponent("s.jsonl")
        try "turn\n".write(to: transcript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: transcript.path)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path),
                       AccountConfig(name: "team", configDir: team.path, sharedStore: true)])
        await state.reconcileTranscripts()
        let mirrored = TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)
            + "/\(accountKey(canonical.path))/-w/s.jsonl"
        XCTAssertTrue(fm.fileExists(atPath: mirrored), "fixture: both accounts keep 30 days, so it is mirrored")

        // Team now keeps 7 days, and its sweep removes the transcript through its link.
        try #"{"cleanupPeriodDays": 7}"#.write(to: team.appendingPathComponent("settings.json"),
                                               atomically: true, encoding: .utf8)
        try fm.removeItem(at: team.appendingPathComponent("projects/-w/s.jsonl"))
        await state.reconcileTranscripts()

        XCTAssertFalse(fm.fileExists(atPath: transcript.path), "team's sweep is not undone")
        XCTAssertFalse(fm.fileExists(atPath: mirrored), "nor kept past team's 7 days")
    }

    /// One project's `.claude/settings.local.json` keeps 3 days. A session started there
    /// sweeps every project of the account, so a 5-day-old transcript of ANOTHER project
    /// that vanished is not put back, and Settings names the file that set the period.
    func testAProjectsSettingsCountForEveryTranscriptOfTheAccount() async throws {
        let canonical = root.appendingPathComponent("canonical-project")
        let shop = root.appendingPathComponent("code/shop")
        try fm.createDirectory(at: shop.appendingPathComponent(".git"), withIntermediateDirectories: true)
        func record(_ cwd: String) -> String { #"{"type":"user","sessionId":"s","cwd":"\#(cwd)"}"# + "\n" }
        let shopDir = canonical.appendingPathComponent("projects/" + ClaudeService.mangle(shop.path))
        let otherDir = canonical.appendingPathComponent("projects/-Users-demo-elsewhere")
        for dir in [shopDir, otherDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let shopTranscript = shopDir.appendingPathComponent("a.jsonl")
        let other = otherDir.appendingPathComponent("b.jsonl")
        try record(shop.path).write(to: shopTranscript, atomically: true, encoding: .utf8)
        try record("/Users/demo/elsewhere").write(to: other, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86_400)], ofItemAtPath: other.path)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(version: 1, workspacesRootTemplate: "~/w", projects: [],
                                   accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        await state.reconcileTranscripts()
        XCTAssertEqual(state.transcriptRetention["default"]?.days, 30)

        let local = shop.appendingPathComponent(".claude/settings.local.json")
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"cleanupPeriodDays": 3}"#.write(to: local, atomically: true, encoding: .utf8)
        try fm.removeItem(at: other)
        await state.reconcileTranscripts()

        XCTAssertFalse(fm.fileExists(atPath: other.path), "a session in shop sweeps it at 3 days")
        XCTAssertEqual(state.transcriptRetention["default"]?.days, 3)
        XCTAssertEqual(state.transcriptRetention["default"]?.source, .projectLocalSettings)
        XCTAssertEqual(state.transcriptRetention["default"]?.origin, local.path)
    }

    /// An entry whose account left the config ages out at the shortest period any
    /// configured account keeps, not at Claude Code's default.
    func testAnOrphanEntryAgesOutAtTheShortestConfiguredPeriod() async throws {
        let canonical = root.appendingPathComponent("canonical-orphan")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        try #"{"cleanupPeriodDays": 7}"#.write(to: canonical.appendingPathComponent("settings.json"),
                                               atomically: true, encoding: .utf8)
        let orphan = TranscriptMirror.mirrorRoot(canonicalDir: canonical.path) + "/0rphan00/-p/o.jsonl"
        try fm.createDirectory(atPath: (orphan as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "turn\n".write(toFile: orphan, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: orphan)

        let state = makeState()
        state.folders.canonicalDir = canonical.path
        state.config = GroveConfig(version: 1, workspacesRootTemplate: "~/w", projects: [],
                                   accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        await state.reconcileTranscripts()
        XCTAssertFalse(fm.fileExists(atPath: orphan))
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
