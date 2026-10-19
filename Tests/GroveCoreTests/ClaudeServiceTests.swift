// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

final class ClaudeServiceTests: XCTestCase {
    private var configDir: URL!
    private var account: AccountConfig!
    private var service: ClaudeService!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("claude-config")
        account = AccountConfig(name: "work", configDir: configDir.path)
        service = ClaudeService()
    }

    // MARK: - Helpers

    private func makeProjectsDir(for cwd: String) throws -> URL {
        let dir = configDir
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeJSONL(_ lines: [String], to dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Realistic Claude Code transcript: metadata lines first, then a user record
    /// (sessionId/cwd/gitBranch/timestamp), an assistant reply, and optionally an ai-title record.
    private func transcriptLines(cwd: String, sessionId: String, branch: String,
                                 userText: String, aiTitle: String?) -> [String] {
        var lines = [
            #"{"type":"summary","summary":"Earlier exploration of the bug","leafUuid":"7f3c9d2e-1111-4222-8333-444455556666"}"#,
            #"{"type":"file-history-snapshot","messageId":"msg-001","snapshot":{"trackedFiles":[]},"isSnapshotUpdate":false}"#,
            #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(sessionId)","version":"2.0.14","gitBranch":"\#(branch)","type":"user","message":{"role":"user","content":"\#(userText)"},"uuid":"\#(sessionId)-u1","timestamp":"2026-06-10T10:00:00.000Z"}"#,
            #"{"parentUuid":"\#(sessionId)-u1","isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(sessionId)","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at it now."}]},"uuid":"\#(sessionId)-a1","timestamp":"2026-06-10T10:00:05.000Z"}"#,
        ]
        if let aiTitle {
            lines.append(#"{"type":"ai-title","aiTitle":"\#(aiTitle)","sessionId":"\#(sessionId)","timestamp":"2026-06-10T10:01:00.000Z"}"#)
        }
        return lines
    }

    // MARK: - mangle

    func testMangleExampleFromContract() {
        XCTAssertEqual(ClaudeService.mangle("/a/b.c"), "-a-b-c")
    }

    func testMangleReplacesUnderscoreDotSlashAndUnicode() {
        // underscore, dot, slash all become "-"
        XCTAssertEqual(ClaudeService.mangle("/Users/dev/my_app.v2"), "-Users-dev-my-app-v2")
        // unicode (non-ASCII) chars each become "-": "папка" = 5 scalars -> 5 dashes
        XCTAssertEqual(ClaudeService.mangle("/tmp/папка"), "-tmp------")
        // ASCII letters and digits pass through unchanged
        XCTAssertEqual(ClaudeService.mangle("/Users/A1/B2"), "-Users-A1-B2")
    }

    func testMangleIsLossy() {
        // This collision is exactly why sessions() must verify the cwd field inside the jsonl.
        XCTAssertEqual(ClaudeService.mangle("/work/demo_app"), ClaudeService.mangle("/work/demo-app"))
    }

    /// Claude Code replaces UTF-16 units, not characters: an emoji outside the basic plane
    /// is two of them, and two dashes.
    func testMangleCountsUTF16Units() {
        XCTAssertEqual(ClaudeService.mangle("/Users/demo/Code/🚀rocket"), "-Users-demo-Code---rocket")
        XCTAssertEqual(ClaudeService.mangle("/Users/demo/Code/é"), "-Users-demo-Code--")
    }

    /// Past 200 units the name is cut and ends in the path's Java hash, in base 36 and
    /// without its sign (this path's hash is negative).
    func testMangleCutsALongPathAndAddsItsHash() {
        let path = "/Users/demo/" + String(repeating: "very-long-folder-name/", count: 10) + "harbor"
        let name = ClaudeService.mangle(path)
        XCTAssertEqual(name, "-Users-demo-" + String(repeating: "very-long-folder-name-", count: 8) + "very-long-fo-4owx6w")
        XCTAssertEqual(name.count, 200 + 1 + 6)
        XCTAssertEqual(ClaudeService.mangle("/x/" + String(repeating: "a", count: 197)).count, 200, "200 exactly is not cut")
    }

    // MARK: - identity

    func testIdentityReadsOAuthAccountFromConfigDir() throws {
        let json = """
        {
          "numStartups": 17,
          "installMethod": "native",
          "oauthAccount": {
            "accountUuid": "f0e1d2c3-b4a5-4697-8809-aabbccddeeff",
            "emailAddress": "work@example.com",
            "organizationName": "Acme Corp",
            "organizationUuid": "11223344-5566-4788-99aa-bbccddeeff00",
            "userRateLimitTier": "max_20x"
          }
        }
        """
        try json.write(to: configDir.appendingPathComponent(".claude.json"),
                       atomically: true, encoding: .utf8)

        let identity = try XCTUnwrap(service.identity(account: account))
        XCTAssertEqual(identity.email, "work@example.com")
        XCTAssertEqual(identity.organization, "Acme Corp")
        XCTAssertEqual(identity.tier, "max_20x")
    }

    func testIdentityNilWhenConfigJsonMissing() {
        XCTAssertNil(service.identity(account: account))
    }

    // MARK: - sessions

    func testSessionsReadsMatchingTranscriptWithAiTitle() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0001-4000-8000-000000000001"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/media-pipeline",
                            userText: "Fix the flaky media upload retries",
                            aiTitle: "Flaky media upload retries"),
            to: dir, name: "\(id).jsonl")

        let sessions = service.sessions(for: cwd, account: account)
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.cwd, cwd)
        XCTAssertEqual(session.title, "Flaky media upload retries")
        XCTAssertEqual(session.gitBranch, "feat/media-pipeline")
        XCTAssertEqual(session.accountName, "work")
    }

    func testSessionsFiltersFileWhoseCwdMismatches() throws {
        let cwd = "/work/demo_app"
        // "/work/demo-app" mangles to the SAME directory name -> lands in the same projects dir.
        let dir = try makeProjectsDir(for: cwd)
        let goodId = "0a1b2c3d-0002-4000-8000-000000000002"
        let imposterId = "0a1b2c3d-0003-4000-8000-000000000003"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: goodId, branch: "feat/good",
                            userText: "Work in the right checkout", aiTitle: "Right checkout work"),
            to: dir, name: "\(goodId).jsonl")
        try writeJSONL(
            transcriptLines(cwd: "/work/demo-app", sessionId: imposterId, branch: "feat/imposter",
                            userText: "Work in a different checkout", aiTitle: "Imposter"),
            to: dir, name: "\(imposterId).jsonl")

        let sessions = service.sessions(for: cwd, account: account)
        XCTAssertEqual(sessions.map(\.id), [goodId])
    }

    func testSessionsIgnoresJsonlInsideSubdirectories() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let nested = dir.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedId = "0a1b2c3d-0004-4000-8000-000000000004"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: nestedId, branch: "feat/archived",
                            userText: "Archived conversation", aiTitle: "Archived"),
            to: nested, name: "\(nestedId).jsonl")

        XCTAssertEqual(service.sessions(for: cwd, account: account), [])
    }

    func testSessionsTitleFallsBackToFirstExternalUserMessagePrefix80() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0005-4000-8000-000000000005"
        let longMessage = String(repeating: "abcdefghij", count: 10) // 100 chars
        let lines = [
            #"{"type":"summary","summary":"Old context","leafUuid":"7f3c9d2e-2222-4222-8333-444455556666"}"#,
            // Internal user record (tool result, no "userType":"external") comes FIRST:
            // it supplies sessionId/gitBranch but must NOT supply the fallback title.
            #"{"parentUuid":null,"isSidechain":false,"cwd":"/work/demo_app","sessionId":"\#(id)","gitBranch":"feat/long","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"ok"}]},"uuid":"\#(id)-u0","timestamp":"2026-06-10T11:00:00.000Z"}"#,
            #"{"parentUuid":"\#(id)-u0","isSidechain":false,"userType":"external","cwd":"/work/demo_app","sessionId":"\#(id)","gitBranch":"feat/long","type":"user","message":{"role":"user","content":"\#(longMessage)"},"uuid":"\#(id)-u1","timestamp":"2026-06-10T11:00:10.000Z"}"#,
        ]
        try writeJSONL(lines, to: dir, name: "\(id).jsonl")

        let session = try XCTUnwrap(service.sessions(for: cwd, account: account).first)
        XCTAssertEqual(session.title, String(repeating: "abcdefghij", count: 8)) // first 80 chars
        XCTAssertEqual(session.title?.count, 80)
        XCTAssertEqual(session.gitBranch, "feat/long")
    }

    func testSessionsSortedNewestFirstByMtime() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let oldId = "0a1b2c3d-0006-4000-8000-000000000006"
        let newId = "0a1b2c3d-0007-4000-8000-000000000007"
        let oldURL = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: oldId, branch: "feat/old",
                            userText: "old work", aiTitle: "Old"),
            to: dir, name: "\(oldId).jsonl")
        let newURL = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: newId, branch: "feat/new",
                            userText: "new work", aiTitle: "New"),
            to: dir, name: "\(newId).jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: newURL.path)

        XCTAssertEqual(service.sessions(for: cwd, account: account).map(\.id), [newId, oldId])
    }

    // MARK: - parse cache

    /// Cache-invalidation: after a file is rewritten with new content AND a newer mtime,
    /// sessions() must re-parse and return the updated title rather than a stale cached result.
    func testCacheInvalidatedWhenMtimeChanges() throws {
        let cwd = "/work/cache_test_invalidation"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0008-4000-8000-000000000008"
        let fileName = "\(id).jsonl"

        // Initial write — prime the cache.
        let url = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/cache",
                            userText: "initial message", aiTitle: "Original Title"),
            to: dir, name: fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path)

        let firstResult = service.sessions(for: cwd, account: account)
        XCTAssertEqual(firstResult.first?.title, "Original Title", "pre-condition: first parse gives original title")

        // Overwrite with new content and a strictly later mtime — cache should be invalidated.
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/cache",
                            userText: "updated message", aiTitle: "Updated Title"),
            to: dir, name: fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: url.path)

        let secondResult = service.sessions(for: cwd, account: account)
        XCTAssertEqual(secondResult.first?.title, "Updated Title",
                       "cache must be invalidated when mtime changes — new title should be returned")
    }

    /// Cache-hit: after a file is rewritten with new content but the SAME mtime is restored,
    /// sessions() must return the previously-cached (old) result, proving the cache is consulted.
    func testCacheHitWhenMtimeIsUnchanged() throws {
        let cwd = "/work/cache_test_hit"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0009-4000-8000-000000000009"
        let fileName = "\(id).jsonl"
        let fixedMtime = Date(timeIntervalSince1970: 1_700_000_000)

        // Initial write — prime the cache with the original title.
        let url = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/cache-hit",
                            userText: "original message", aiTitle: "Cached Title"),
            to: dir, name: fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedMtime],
            ofItemAtPath: url.path)

        let firstResult = service.sessions(for: cwd, account: account)
        XCTAssertEqual(firstResult.first?.title, "Cached Title", "pre-condition: first parse gives cached title")

        // Overwrite with different content, but restore the EXACT same mtime.
        // The cache key (path + mtime) is unchanged, so cachedParse must return the stored result.
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/cache-hit",
                            userText: "rewritten message", aiTitle: "Stale Title Should Not Appear"),
            to: dir, name: fileName)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedMtime],
            ofItemAtPath: url.path)

        let secondResult = service.sessions(for: cwd, account: account)
        XCTAssertEqual(secondResult.first?.title, "Cached Title",
                       "cache must be hit when mtime is unchanged — stale on-disk content must be ignored")
    }

    // MARK: - liveProcesses

    private func makeSessionsDir() throws -> URL {
        let dir = configDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLiveProcessesKeepsOnlyValidatedPidsAndSkipsMalformedJson() throws {
        let dir = try makeSessionsDir()
        try #"{"pid":54321,"sessionId":"0a1b2c3d-0001-4000-8000-000000000001","cwd":"/work/demo_app","status":"busy","startedAt":"2026-06-10T09:58:11.000Z","procStart":"Wed Jun 10 09:58:10 2026"}"#
            .write(to: dir.appendingPathComponent("54321.json"), atomically: true, encoding: .utf8)
        try #"{"pid":61234,"sessionId":"0a1b2c3d-0002-4000-8000-000000000002","cwd":"/work/other_app","status":"idle","startedAt":"2026-06-09T18:12:00.000Z","procStart":"Tue Jun  9 18:11:58 2026"}"#
            .write(to: dir.appendingPathComponent("61234.json"), atomically: true, encoding: .utf8)
        try "{ not valid json at all"
            .write(to: dir.appendingPathComponent("70001.json"), atomically: true, encoding: .utf8)
        // pid > Int32.max — must be skipped before validator is called (regression for Int32(exactly:) fix)
        try #"{"pid":99999999999,"sessionId":"0a1b2c3d-0099-4000-8000-000000000099","cwd":"/work/overflow","status":"busy","startedAt":"2026-06-10T09:58:11.000Z","procStart":"Wed Jun 10 09:58:10 2026"}"#
            .write(to: dir.appendingPathComponent("99999999999.json"), atomically: true, encoding: .utf8)

        var checkedPids: [Int32] = []
        service.processValidator = { pid in
            checkedPids.append(pid)
            return pid == 54321        // 54321 alive, 61234 dead
        }

        let live = service.liveProcesses(account: account)
        XCTAssertEqual(live.count, 1)
        let process = try XCTUnwrap(live.first)
        XCTAssertEqual(process.pid, 54321)
        XCTAssertEqual(process.sessionId, "0a1b2c3d-0001-4000-8000-000000000001")
        XCTAssertEqual(process.cwd, "/work/demo_app")
        XCTAssertEqual(process.status, "busy")
        XCTAssertEqual(process.accountName, "work")
        // startedAt parsed from the ISO8601 fractional timestamp in the record.
        XCTAssertEqual(process.startedAt,
                       isoDateWithFractional.date(from: "2026-06-10T09:58:11.000Z"))
        XCTAssertEqual(checkedPids.sorted(), [54321, 61234],
                       "malformed json must be skipped before pid validation")
    }

    func testLiveProcessStartedAtParsesPlainIsoVariant() throws {
        let dir = try makeSessionsDir()
        // No fractional seconds — must still parse via the plain ISO8601 formatter.
        try #"{"pid":54322,"sessionId":"0a1b2c3d-0010-4000-8000-000000000010","cwd":"/work/plain","status":"waiting","startedAt":"2026-06-10T09:58:11Z"}"#
            .write(to: dir.appendingPathComponent("54322.json"), atomically: true, encoding: .utf8)
        service.processValidator = { _ in true }

        let process = try XCTUnwrap(service.liveProcesses(account: account).first)
        XCTAssertEqual(process.startedAt, isoDatePlain.date(from: "2026-06-10T09:58:11Z"))
    }

    func testLiveProcessStartedAtNilWhenAbsentOrUnparseable() throws {
        let dir = try makeSessionsDir()
        try #"{"pid":54323,"sessionId":"0a1b2c3d-0011-4000-8000-000000000011","cwd":"/work/nodate","status":"idle"}"#
            .write(to: dir.appendingPathComponent("54323.json"), atomically: true, encoding: .utf8)
        try #"{"pid":54324,"sessionId":"0a1b2c3d-0012-4000-8000-000000000012","cwd":"/work/baddate","status":"idle","startedAt":"not-a-date"}"#
            .write(to: dir.appendingPathComponent("54324.json"), atomically: true, encoding: .utf8)
        service.processValidator = { _ in true }

        let live = service.liveProcesses(account: account)
        XCTAssertEqual(live.count, 2)
        XCTAssertNil(live.first { $0.pid == 54323 }?.startedAt)
        XCTAssertNil(live.first { $0.pid == 54324 }?.startedAt)
    }

    func testLiveProcessesEmptyWhenSessionsDirMissing() {
        service.processValidator = { _ in
            XCTFail("validator must not be called when sessions dir is absent")
            return true
        }
        XCTAssertEqual(service.liveProcesses(account: account), [])
    }

    // MARK: - a session id on the command line

    func testResumeSessionIdParsesUuidFromCommandLine() {
        XCTAssertEqual(
            ClaudeService.sessionId(in: "claude --resume 41f451c9-1658-4981-9465-a4dbb252ff11"),
            "41f451c9-1658-4981-9465-a4dbb252ff11")
        // flags after the id don't bleed in
        XCTAssertEqual(
            ClaudeService.sessionId(in: "/Users/x/.local/bin/claude --resume 2c07347f-f9bc-4d2c-afcf-1c295d20dd32 --dangerously-skip-permissions"),
            "2c07347f-f9bc-4d2c-afcf-1c295d20dd32")
    }

    func testResumeSessionIdAcceptsEqualsForm() {
        // Both `--resume <id>` and `--resume=<id>` must resolve; the equals form would
        // otherwise leave the session unmatchable (read as fresh/closed).
        XCTAssertEqual(
            ClaudeService.sessionId(in: "claude --resume=41f451c9-1658-4981-9465-a4dbb252ff11"),
            "41f451c9-1658-4981-9465-a4dbb252ff11")
        XCTAssertEqual(
            ClaudeService.sessionId(in: "claude --resume=41f451c9-1658-4981-9465-a4dbb252ff11 --foo"),
            "41f451c9-1658-4981-9465-a4dbb252ff11")
    }

    func testSessionIdParsesSessionIdFlag() {
        // cmux launches Claude with `--session-id <uuid>` (NOT `--resume`). The
        // extractor must recognize it, otherwise the process is misread as a bare,
        // ID-less `claude` and surfaces as an empty-id, cwd-only table row — which then
        // colors EVERY closed session sharing that directory as "running" (the
        // stuck-running bug; live witness pid 8148 was exactly this command).
        XCTAssertEqual(
            ClaudeService.sessionId(in: "/Users/x/.local/bin/claude --session-id 5561b7f2-1f5d-4ad9-8d73-25341dfaa5e5 --dangerously-skip-permissions"),
            "5561b7f2-1f5d-4ad9-8d73-25341dfaa5e5")
        // equals form too (parity with --resume=)
        XCTAssertEqual(
            ClaudeService.sessionId(in: "claude --session-id=5561b7f2-1f5d-4ad9-8d73-25341dfaa5e5"),
            "5561b7f2-1f5d-4ad9-8d73-25341dfaa5e5")
        // a non-uuid value is still rejected (no false matches)
        XCTAssertNil(ClaudeService.sessionId(in: "claude --session-id not-a-uuid"))
    }

    /// A host's claude wins over the engine's guesses; an empty one is no choice at all.
    func testLaunchCommandUsesTheClaudeItIsGiven() {
        let account = AccountConfig(name: "w", configDir: "/tmp/w-launch")
        XCTAssertTrue(ClaudeService.launchCommand(account: account, claude: "/opt/c/claude")
            .hasSuffix(" '/opt/c/claude'"))
        XCTAssertEqual(ClaudeService.launchCommand(account: account, claude: "  "),
                       ClaudeService.launchCommand(account: account))
    }

    func testLaunchCommandTreatsEmptyModelEffortAsNil() {
        // A hand-edited config with model: "" / effort: "" must NOT emit `--model ''`.
        let account = AccountConfig(name: "def", configDir: NSHomeDirectory() + "/.claude")
        let cmd = ClaudeService.launchCommand(account: account, resume: "", model: "", effort: "")
        XCTAssertFalse(cmd.contains("--model"))
        XCTAssertFalse(cmd.contains("--effort"))
        XCTAssertFalse(cmd.contains("--resume"))
    }

    /// One process runs one session: the join is by id, and a process whose session
    /// could not be told stands for none of the sessions in its folder.
    func testLiveProcessJoinsByIdOnly() {
        let live = [
            LiveProcess(pid: 1, sessionId: "S1", cwd: "/ws/a", status: "busy", accountName: "x"),
            LiveProcess(pid: 2, sessionId: "", cwd: "/ws/b", status: "idle", accountName: ""),
        ]
        XCTAssertEqual(live.liveProcess(forSessionId: "S1", cwd: "/anything")?.pid, 1)
        XCTAssertNil(live.liveProcess(forSessionId: "S2", cwd: "/ws/b"), "no session of its own: not S2's")
        XCTAssertNil(live.liveProcess(forSessionId: "S3", cwd: "/ws/a"), "S1's process is not S3's")
        XCTAssertNil(live.liveProcess(forSessionId: "", cwd: "/ws/b"))
    }

    func testResumeSessionIdRejectsNonResumeAndWrappers() {
        XCTAssertNil(ClaudeService.sessionId(in: "claude"))                       // bare new session
        XCTAssertNil(ClaudeService.sessionId(in: "claude --print hello"))          // no --resume
        // the cmux wrapper script path mentions claude + an id but has no --resume flag
        XCTAssertNil(ClaudeService.sessionId(in: "/bin/zsh /tmp/cmux-agent-resume/claude-2d6192be-e3d-9D80.zsh"))
        XCTAssertNil(ClaudeService.sessionId(in: "claude --resume not-a-uuid"))    // not a 36-char id
    }

    // MARK: - launchCommand

    /// Forces bare-"claude" resolution so string expectations are machine-independent.
    private func withBareClaudeResolution(_ body: () -> Void) {
        let saved = ClaudeService.claudeCandidatePaths
        ClaudeService.claudeCandidatePaths = []
        defer { ClaudeService.claudeCandidatePaths = saved }
        body()
    }

    func testLaunchCommandDefaultAccountIsPlainClaude() {
        withBareClaudeResolution {
            let def = AccountConfig(name: "default", configDir: "~/.claude")
            XCTAssertEqual(ClaudeService.launchCommand(account: def), "'claude'")
        }
    }

    func testLaunchCommandCustomDirPrefixesQuotedConfigDir() {
        withBareClaudeResolution {
            let custom = AccountConfig(name: "work", configDir: "/Users/dev/.claude-accounts/work")
            XCTAssertEqual(ClaudeService.launchCommand(account: custom),
                           "CLAUDE_CONFIG_DIR='/Users/dev/.claude-accounts/work' 'claude'")
        }
    }

    func testLaunchCommandAppendsQuotedResumeId() {
        withBareClaudeResolution {
            let custom = AccountConfig(name: "work", configDir: "/Users/dev/.claude-accounts/work")
            XCTAssertEqual(
                ClaudeService.launchCommand(account: custom, resume: "0a1b2c3d-0001-4000-8000-000000000001"),
                "CLAUDE_CONFIG_DIR='/Users/dev/.claude-accounts/work' 'claude' --resume '0a1b2c3d-0001-4000-8000-000000000001'")
            let def = AccountConfig(name: "default", configDir: "~/.claude")
            XCTAssertEqual(
                ClaudeService.launchCommand(account: def, resume: "0a1b2c3d-0001-4000-8000-000000000001"),
                "'claude' --resume '0a1b2c3d-0001-4000-8000-000000000001'")
        }
    }

    func testLaunchCommandQuotesSingleQuoteInConfigDir() {
        withBareClaudeResolution {
            let odd = AccountConfig(name: "odd", configDir: "/tmp/it's here/claude")
            XCTAssertEqual(ClaudeService.launchCommand(account: odd),
                           "CLAUDE_CONFIG_DIR='/tmp/it'\\''s here/claude' 'claude'")
        }
    }

    func testLaunchCommandAppendsModelAndEffortQuoted() {
        withBareClaudeResolution {
            let custom = AccountConfig(name: "work", configDir: "/Users/dev/.claude-accounts/work")
            XCTAssertEqual(
                ClaudeService.launchCommand(account: custom, resume: "sess-1",
                                            model: "claude-opus-4-6", effort: "high"),
                "CLAUDE_CONFIG_DIR='/Users/dev/.claude-accounts/work' 'claude' "
                + "--resume 'sess-1' --model 'claude-opus-4-6' --effort 'high'")
            let def = AccountConfig(name: "default", configDir: "~/.claude")
            // Order: --resume (if any) then --model then --effort; nils omit their flag.
            XCTAssertEqual(ClaudeService.launchCommand(account: def, model: "claude-sonnet-4-6"),
                           "'claude' --model 'claude-sonnet-4-6'")
            XCTAssertEqual(ClaudeService.launchCommand(account: def, effort: "low"),
                           "'claude' --effort 'low'")
            // No model/effort -> unchanged from the resume-only form.
            XCTAssertEqual(ClaudeService.launchCommand(account: def, resume: "x"),
                           "'claude' --resume 'x'")
        }
    }

    func testLaunchCommandAppendsSkipPermissionsFlag() {
        withBareClaudeResolution {
            let def = AccountConfig(name: "default", configDir: "~/.claude")
            // Off by default: no flag.
            XCTAssertEqual(ClaudeService.launchCommand(account: def), "'claude'")
            // On: appended last, after resume/model/effort, on BOTH new and resume.
            XCTAssertEqual(ClaudeService.launchCommand(account: def, skipPermissions: true),
                           "'claude' --dangerously-skip-permissions")
            XCTAssertEqual(
                ClaudeService.launchCommand(account: def, resume: "x",
                                            model: "claude-opus-4-6", effort: "high",
                                            skipPermissions: true),
                "'claude' --resume 'x' --model 'claude-opus-4-6' --effort 'high' "
                + "--dangerously-skip-permissions")
        }
    }

    func testLaunchCommandQuotesSingleQuoteInModel() {
        withBareClaudeResolution {
            let def = AccountConfig(name: "default", configDir: "~/.claude")
            XCTAssertEqual(ClaudeService.launchCommand(account: def, model: "o'pus"),
                           "'claude' --model 'o'\\''pus'")
        }
    }

    // MARK: - claudeExecutable resolution

    func testClaudeExecutableResolvesFirstExistingCandidate() throws {
        let dir = try Fixture.tempDir("claude-bin")
        let fake = dir.appendingPathComponent("claude")
        try "#!/bin/zsh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let saved = ClaudeService.claudeCandidatePaths
        defer { ClaudeService.claudeCandidatePaths = saved }

        ClaudeService.claudeCandidatePaths = ["/nonexistent/claude", fake.path]
        XCTAssertEqual(ClaudeService.claudeExecutable(), fake.path)

        // The resolved absolute path flows into the launch command, quoted —
        // making it immune to shells whose PATH lacks the install dir.
        let def = AccountConfig(name: "default", configDir: "~/.claude")
        XCTAssertEqual(ClaudeService.launchCommand(account: def), shellQuote(fake.path))
    }

    func testClaudeExecutableFallsBackToBareName() {
        let saved = ClaudeService.claudeCandidatePaths
        defer { ClaudeService.claudeCandidatePaths = saved }
        ClaudeService.claudeCandidatePaths = ["/nonexistent/a", "/nonexistent/b"]
        XCTAssertEqual(ClaudeService.claudeExecutable(), "claude")
    }
}
