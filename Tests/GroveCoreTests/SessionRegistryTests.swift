// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// `<config dir>/sessions/<pid>.json`, the record a running session keeps of itself.
final class SessionRegistryTests: XCTestCase {
    private var configDir: URL!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("session-registry")
        try FileManager.default.createDirectory(at: configDir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    /// A process of the test's own that sleeps, to stand for a session.
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process
    }

    /// A record shaped as Claude Code 2.1 writes it. Every value is made up.
    private func record(pid: Int32, procStart: String?, status: String = "waiting",
                        waitingFor: String? = "permission prompt") -> String {
        var fields = [
            #""pid":\#(pid)"#, #""sessionId":"9c2d7e1a-4b3f-4a6e-8d1c-2f5e6a7b8c9d""#,
            #""cwd":"/Users/demo/Code/harbor""#, #""startedAt":1792000000000"#, #""version":"2.1.302""#,
            #""peerProtocol":1"#, #""kind":"interactive""#, #""entrypoint":"cli""#, #""name":"harbor""#,
            #""nameSince":1792000000500"#, #""status":"\#(status)""#, #""updatedAt":1792000100000"#,
            #""statusUpdatedAt":1792000100000"#,
        ]
        if let procStart { fields.append(#""procStart":"\#(procStart)""#) }
        if let waitingFor { fields.append(#""waitingFor":"\#(waitingFor)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func write(_ text: String, pid: Int32) throws {
        try Data(text.utf8).write(to: configDir.appendingPathComponent("sessions/\(pid).json"))
    }

    func testTheRecordAsClaudeCodeWritesIt() throws {
        let parsed = try XCTUnwrap(SessionRegistry.parse(Data(record(pid: 4242, procStart: "Wed Oct 14 18:26:40 2026").utf8),
                                                         configDir: configDir.path))
        XCTAssertEqual(parsed.pid, 4242)
        XCTAssertEqual(parsed.sessionId, "9c2d7e1a-4b3f-4a6e-8d1c-2f5e6a7b8c9d")
        XCTAssertEqual(parsed.cwd, "/Users/demo/Code/harbor")
        XCTAssertEqual(parsed.status, .waiting)
        XCTAssertEqual(parsed.waitingFor, "permission prompt")
        XCTAssertEqual(parsed.kind, "interactive")
        XCTAssertEqual(parsed.entrypoint, "cli")
        XCTAssertEqual(parsed.startedAt, Date(timeIntervalSince1970: 1_792_000_000), "milliseconds since 1970")
        XCTAssertEqual(parsed.statusUpdatedAt, Date(timeIntervalSince1970: 1_792_000_100))
        XCTAssertEqual(parsed.configDir, configDir.path)
        for status in ["busy", "idle", "shell"] {
            XCTAssertEqual(SessionRegistry.parse(Data(record(pid: 1, procStart: nil, status: status).utf8), configDir: "/c")?.status?.rawValue, status)
        }
        XCTAssertNil(SessionRegistry.parse(Data(record(pid: 1, procStart: nil, status: "new-one").utf8), configDir: "/c")?.status,
                     "a status this version doesn't know is no status, not a dropped record")
        XCTAssertNotNil(SessionRegistry.parse(Data(#"{"pid":7,"sessionId":"s","cwd":"/w","startedAt":"2026-10-14T18:26:40.000Z"}"#.utf8), configDir: "/c")?.startedAt,
                        "an ISO string is read too")
        XCTAssertNil(SessionRegistry.parse(Data(#"{"pid":99999999999,"sessionId":"s","cwd":"/w"}"#.utf8), configDir: "/c"))
        XCTAssertNil(SessionRegistry.parse(Data("{not json".utf8), configDir: "/c"))
    }

    /// The kernel's start time, printed the way `ps -o lstart=` prints it in UTC, which
    /// is what Claude Code stores as `procStart`.
    func testTheStartTimeReadsAsPsPrintsIt() throws {
        let child = try sleeper()
        let ours = try XCTUnwrap(SessionRegistry.startTime(of: child.processIdentifier))
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(child.processIdentifier)]
        ps.environment = ["LC_ALL": "C", "TZ": "UTC", "PATH": "/bin:/usr/bin"]
        let out = Pipe()
        ps.standardOutput = out
        try ps.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        XCTAssertEqual(ours, printed.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A record counts while its pid runs and is the process that wrote it: a crash
    /// leaves a record behind, and a later process can get the same pid.
    func testOnlyRecordsOfRunningProcessesCount() throws {
        let child = try sleeper()
        let pid = child.processIdentifier
        let started = try XCTUnwrap(SessionRegistry.startTime(of: pid))
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()

        try write(record(pid: pid, procStart: started), pid: pid)
        try write(record(pid: gone.processIdentifier, procStart: nil), pid: gone.processIdentifier)
        try write("{\"pid\":", pid: 3)
        let live = SessionRegistry.sessions(configDir: configDir.path)
        XCTAssertEqual(live.map(\.pid), [pid])

        let reused = RegisteredSession(pid: pid, sessionId: "s", cwd: "/w", status: .idle,
                                       procStart: "Thu Jan  1 00:00:00 1970", configDir: "/c")
        XCTAssertFalse(SessionRegistry.isLive(reused), "same pid, another process")
        let unknownStart = RegisteredSession(pid: pid, sessionId: "s", cwd: "/w", status: .idle, configDir: "/c")
        XCTAssertTrue(SessionRegistry.isLive(unknownStart), "no start time recorded: the pid alone decides")
    }

    /// Twenty records, each checked against the kernel (run with `TRANSCRIPT_PERF=1`, in release).
    func testWhatReadingTheRecordsCosts() throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPT_PERF"] != nil else { throw XCTSkip("set TRANSCRIPT_PERF=1") }
        let child = try sleeper()
        let started = try XCTUnwrap(SessionRegistry.startTime(of: child.processIdentifier))
        for i in 0..<20 {
            try Data(record(pid: child.processIdentifier, procStart: started).utf8)
                .write(to: configDir.appendingPathComponent("sessions/\(90_000 + i).json"))
        }
        var times: [Double] = []
        var count = 0
        for _ in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            count = SessionRegistry.sessions(configDir: configDir.path).count
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        XCTAssertEqual(count, 20)
        print(String(format: "registry: 20 records read and checked in %.3f ms (worst %.3f)", times[100], times[199]))
    }

    func testAConfigDirWithoutRecordsHasNoSessions() {
        XCTAssertEqual(SessionRegistry.sessions(configDir: configDir.appendingPathComponent("nowhere").path), [])
        XCTAssertEqual(SessionRegistry.sessions(configDir: configDir.path), [])
    }
}
