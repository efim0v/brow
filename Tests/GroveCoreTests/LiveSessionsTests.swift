// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// Which sessions run, and what each one is doing: the records Claude Code keeps of itself,
/// each checked against the kernel, and the processes that keep none, each joined to the
/// one session it runs. The processes are the test's own `/bin/sleep`, in folders it makes;
/// every record and transcript is made up.
final class LiveSessionsTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("live-sessions")
        folder = try Fixture.tempDir("live-sessions-work")
        try fm.createDirectory(at: configDir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    private var account: AccountConfig { AccountConfig(name: "work", configDir: configDir.path) }

    /// A process of the test's own that sleeps, to stand for a session.
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = folder
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process
    }

    /// A transcript of `id` in `cwd`'s folder, last written `at`.
    private func transcript(_ id: String, cwd: String, at date: Date) throws {
        let dir = configDir.appendingPathComponent("projects/" + ClaudeService.mangle(cwd))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(id + ".jsonl")
        try Data(#"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(id)","message":{"role":"user","content":"hi"}}"#.utf8 + [0x0A])
            .write(to: file)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func record(pid: Int32, sessionId: String, cwd: String, extra: String) throws {
        try Data(#"{"pid":\#(pid),"sessionId":"\#(sessionId)","cwd":"\#(cwd)"\#(extra)}"#.utf8)
            .write(to: configDir.appendingPathComponent("sessions/\(pid).json"))
    }

    /// 2.1.30x writes `startedAt` in milliseconds, and `status` only once the session has
    /// one: such a record is live all the same, its start time read.
    func testARecordWithoutAStatusAndAMillisecondStartIsLive() throws {
        let child = try sleeper()
        let pid = child.processIdentifier
        let started = try XCTUnwrap(SessionRegistry.startTime(of: pid))
        try record(pid: pid, sessionId: "s-new", cwd: folder.path,
                   extra: #","startedAt":1792400280000,"procStart":"\#(started)","kind":"interactive""#)
        let live = ClaudeService().liveProcesses(account: account)
        XCTAssertEqual(live.map(\.sessionId), ["s-new"])
        XCTAssertEqual(live.first?.status, "")
        XCTAssertEqual(live.first?.startedAt, Date(timeIntervalSince1970: 1_792_400_280))
        XCTAssertEqual(SessionState.of(live.first, turn: .answered), .yourTurn)
        XCTAssertEqual(SessionState.of(live.first, turn: .tool), .working)
    }

    /// A record whose process started at another moment is a leftover whose pid went to
    /// another process: the session is closed.
    func testAProcStartMismatchIsClosed() throws {
        let child = try sleeper()
        try record(pid: child.processIdentifier, sessionId: "s-old", cwd: folder.path,
                   extra: #","status":"busy","procStart":"Thu Jan  1 00:00:00 1970""#)
        XCTAssertEqual(ClaudeService().liveProcesses(account: account), [])
    }

    /// A process that keeps no record, in a folder with three transcripts: exactly one of
    /// them is live, the one written since it started.
    func testAProcessWithoutARecordRunsExactlyOneSession() throws {
        let child = try sleeper()
        let started = try XCTUnwrap(SessionRegistry.startDate(of: child.processIdentifier))
        let cwd = folder.path
        try transcript("s-yesterday", cwd: cwd, at: started.addingTimeInterval(-86_400))
        try transcript("s-hour-ago", cwd: cwd, at: started.addingTimeInterval(-3_600))
        try transcript("s-now", cwd: cwd, at: started.addingTimeInterval(5))
        let service = ClaudeService()
        service.runningProcesses = { [RunningClaude(pid: child.processIdentifier, cwd: cwd, configDir: self.configDir.path,
                                                    startedAt: started)] }
        let live = service.allLiveProcesses(accounts: [account])
        XCTAssertEqual(live.map(\.sessionId), ["s-now"])
        XCTAssertEqual(live.first?.accountName, "work", "the account its CLAUDE_CONFIG_DIR names")
        XCTAssertEqual(SessionState.of(live.liveProcess(forSessionId: "s-now", cwd: cwd)), .yourTurn)
        for closed in ["s-yesterday", "s-hour-ago"] {
            XCTAssertNil(live.liveProcess(forSessionId: closed, cwd: cwd), closed)
            XCTAssertFalse(ClaudeService.isSessionLive(among: live, sessionId: closed), "no banner for \(closed)")
        }
    }

    /// Two record-less processes in one folder take two transcripts, the newest process the
    /// newest one; one that has written nothing yet runs none of them. A session a record
    /// already holds is never taken.
    func testProcessesWithoutRecordsShareAFolderFairly() throws {
        let cwd = folder.path
        let base = Date().addingTimeInterval(-600)
        try transcript("s-recorded", cwd: cwd, at: base.addingTimeInterval(500))
        try transcript("s-first", cwd: cwd, at: base.addingTimeInterval(300))
        try transcript("s-second", cwd: cwd, at: base.addingTimeInterval(400))
        let processes = [
            RunningClaude(pid: 101, cwd: cwd, configDir: configDir.path, startedAt: base),
            RunningClaude(pid: 102, cwd: cwd, configDir: configDir.path, startedAt: base.addingTimeInterval(200)),
            RunningClaude(pid: 103, cwd: cwd, configDir: configDir.path, startedAt: base.addingTimeInterval(450)),
        ]
        let live = ClaudeService.attribute(processes, accounts: [account], claimed: ["s-recorded"], home: "/nowhere")
        let byPid = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0.sessionId) })
        XCTAssertEqual(byPid[103], "", "started after every transcript but the recorded one: nothing of its own yet")
        XCTAssertEqual(byPid[102], "s-second")
        XCTAssertEqual(byPid[101], "s-first")
    }

    /// The session a command line names wins over any transcript.
    func testTheCommandLinesSessionWins() throws {
        let cwd = folder.path
        try transcript("s-newer", cwd: cwd, at: Date())
        let live = ClaudeService.attribute(
            [RunningClaude(pid: 7, cwd: cwd, configDir: nil, sessionId: "9c2d7e1a-4b3f-4a6e-8d1c-2f5e6a7b8c9d",
                           startedAt: Date().addingTimeInterval(-60))],
            accounts: [account, AccountConfig(name: "default", configDir: "/home/demo/.claude")],
            claimed: [], home: "/home/demo")
        XCTAssertEqual(live.first?.sessionId, "9c2d7e1a-4b3f-4a6e-8d1c-2f5e6a7b8c9d")
        XCTAssertEqual(live.first?.accountName, "default", "no CLAUDE_CONFIG_DIR: ~/.claude")
    }

    /// A record speaks for its process: the host's look at the same pid adds nothing.
    func testARecordedProcessIsListedOnce() throws {
        let child = try sleeper()
        let pid = child.processIdentifier
        let started = try XCTUnwrap(SessionRegistry.startTime(of: pid))
        try record(pid: pid, sessionId: "s-rec", cwd: folder.path,
                   extra: #","status":"waiting","waitingFor":"permission prompt","procStart":"\#(started)""#)
        let service = ClaudeService()
        service.runningProcesses = { [RunningClaude(pid: pid, cwd: self.folder.path, configDir: self.configDir.path)] }
        let live = service.allLiveProcesses(accounts: [account])
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(SessionState.of(live.first), .needsPermission)
    }

    /// The inbox keys beside the records are never read; only `<pid>.json` is a record.
    func testOnlyRecordFilesAreRead() {
        XCTAssertTrue(SessionRegistry.isRecordName("41001.json"))
        XCTAssertFalse(SessionRegistry.isRecordName("41001." + String(repeating: "0", count: 64) + ".key"))
        XCTAssertFalse(SessionRegistry.isRecordName("notes.json"))
        XCTAssertFalse(SessionRegistry.isRecordName(".json"))
    }

    /// A process that is gone has no terminal to focus.
    func testAGoneProcessHasNoTerminal() throws {
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        XCTAssertNil(SessionRegistry.terminal(of: gone.processIdentifier))
    }
}
