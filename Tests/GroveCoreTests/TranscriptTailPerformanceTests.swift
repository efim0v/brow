// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// What a preview costs next to reading the whole transcript, which is what the session
/// list does today. Skipped unless `TRANSCRIPT_PERF` is set; run in release:
///
///     TRANSCRIPT_PERF=1 Scripts/test-in-empty-home.sh -c release --filter TranscriptTailPerformanceTests
final class TranscriptTailPerformanceTests: XCTestCase {
    private var configDir: URL!
    private let cwd = "/Users/demo/Code/harbor"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPT_PERF"] != nil else { throw XCTSkip("set TRANSCRIPT_PERF=1") }
        configDir = try Fixture.tempDir("tail-perf")
    }

    private func milliseconds(_ runs: Int, _ body: () -> Void) -> (median: Double, worst: Double) {
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        return (times[runs / 2], times[runs - 1])
    }

    private func transcript(megabytes: Int, id: String) throws -> URL {
        let dir = configDir.appendingPathComponent("projects/" + ClaudeService.mangle(cwd))
        let url = dir.appendingPathComponent(id + ".jsonl")
        try TranscriptBuilder.long(bytes: megabytes << 20, sessionId: id, cwd: cwd).write(to: url)
        return url
    }

    func testOneTranscriptWholeAgainstItsEnd() throws {
        let account = AccountConfig(name: "demo", configDir: configDir.path)
        for megabytes in [1, 10, 50] {
            let id = String(format: "5b1f0c2a-7d3e-4c1b-9a8f-%012d", megabytes)
            let url = try transcript(megabytes: megabytes, id: id)
            var sessions: [ClaudeSession] = []
            let whole = milliseconds(megabytes >= 50 ? 3 : 7) { sessions = ClaudeService().sessions(for: cwd, account: account) }
            var preview: SessionPreview?
            let tail = milliseconds(200) { preview = TranscriptTail.preview(path: url.path) }
            XCTAssertNotNil(preview?.reply)
            XCTAssertFalse(sessions.isEmpty)
            print(String(format: "transcript %d MB: whole file %.1f ms (worst %.1f), preview %.3f ms (worst %.3f)",
                         megabytes, whole.median, whole.worst, tail.median, tail.worst))
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The session index reads every recent transcript; a refresh after one of them
    /// changed parses that one again in full. Fifty 2 MB transcripts:
    func testManyTranscripts() throws {
        let account = AccountConfig(name: "demo", configDir: configDir.path)
        var urls: [URL] = []
        let template = TranscriptBuilder.long(bytes: 2 << 20, sessionId: "5b1f0c2a-7d3e-4c1b-9a8f-000000000000", cwd: cwd).text
        let dir = configDir.appendingPathComponent("projects/" + ClaudeService.mangle(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<50 {
            let id = String(format: "5b1f0c2a-7d3e-4c1b-9a8f-%012d", i + 100)
            let url = dir.appendingPathComponent(id + ".jsonl")
            try Data(template.replacingOccurrences(of: "5b1f0c2a-7d3e-4c1b-9a8f-000000000000", with: id).utf8).write(to: url)
            urls.append(url)
        }
        let now = Date()
        var rows: [ClaudeSession] = []
        let whole = milliseconds(3) {
            rows = ClaudeService().allRecentSessions(accounts: [account], limit: 500, sinceDays: 90, now: now)
        }
        var previews = 0
        let tails = milliseconds(20) { previews = urls.compactMap { TranscriptTail.preview(path: $0.path) }.count }
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(previews, 50)

        // One of them grows by a turn: the index parses it whole again; a preview reads its end.
        let service = ClaudeService()
        _ = service.allRecentSessions(accounts: [account], limit: 500, sinceDays: 90, now: now)
        var grown = TranscriptBuilder(sessionId: "x", cwd: cwd)
        grown.prompt("One more thing", at: 1)
        grown.reply("Done.", at: 2)
        let handle = try FileHandle(forWritingTo: urls[0])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(grown.text.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: urls[0].path)
        let again = milliseconds(1) { _ = service.allRecentSessions(accounts: [account], limit: 500, sinceDays: 90, now: now) }
        let onePreview = milliseconds(50) { _ = TranscriptTail.preview(path: urls[0].path) }
        print(String(format: "50 transcripts of 2 MB: index cold %.1f ms, previews of all %.2f ms; after one grew: index %.1f ms, its preview %.3f ms",
                     whole.median, tails.median, again.median, onePreview.median))
    }
}
