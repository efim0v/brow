// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// The folders a config folder's sessions ran in, read from the transcripts' own `cwd`
/// records: what `ClaudeRetention` reads project settings for.
final class TranscriptCwdsTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = try Fixture.tempDir("transcript-cwds")
    }

    private func transcript(_ lines: [String], at path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func turn(_ cwd: String) -> String {
        #"{"type":"user","sessionId":"s","cwd":"\#(cwd)","message":{"role":"user","content":"hi"}}"#
    }

    func testTheFirstRecordWithACwdCounts() throws {
        let path = root.appendingPathComponent("a.jsonl").path
        try transcript([#"{"type":"summary","summary":"Fix the build","leafUuid":"x"}"#,
                        turn("/Users/demo/Code/shop"), turn("/Users/demo/Code/elsewhere")], at: path)
        XCTAssertEqual(TranscriptCwds.cwd(ofTranscriptAt: path), "/Users/demo/Code/shop")
    }

    /// A long first record — a snapshot of many files — is read past, a chunk at a time.
    func testALongRecordBeforeTheFirstTurnIsReadPast() throws {
        let path = root.appendingPathComponent("long.jsonl").path
        let big = #"{"type":"file-history-snapshot","files":""# + String(repeating: "x", count: 100_000) + #""}"#
        try transcript([big, turn("/Users/demo/Code/notes")], at: path)
        XCTAssertEqual(TranscriptCwds.cwd(ofTranscriptAt: path), "/Users/demo/Code/notes")
    }

    /// No turn yet: nothing, and asked again once the file has grown.
    func testATranscriptWithoutATurnIsAskedAgainOnceItChanges() throws {
        let path = root.appendingPathComponent("young.jsonl").path
        try transcript([#"{"type":"summary","summary":"…"}"#], at: path)
        XCTAssertNil(TranscriptCwds.cwd(ofTranscriptAt: path))
        try transcript([#"{"type":"summary","summary":"…"}"#, turn("/Users/demo/later")], at: path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
        XCTAssertEqual(TranscriptCwds.cwd(ofTranscriptAt: path), "/Users/demo/later")
    }

    func testAMissingOrGarbledFileHasNone() throws {
        XCTAssertNil(TranscriptCwds.cwd(ofTranscriptAt: root.appendingPathComponent("none.jsonl").path))
        let path = root.appendingPathComponent("garbled.jsonl").path
        try transcript([#"{"cwd": 7}"#, #"{"cwd": "relative/path"}"#, #"not json "cwd""#], at: path)
        XCTAssertNil(TranscriptCwds.cwd(ofTranscriptAt: path))
    }

    /// Every project folder, a shared workspace's link followed, and the safety net's
    /// copies of transcripts that are gone. Two projects whose paths turn into the same
    /// folder name are both found.
    func testAllOfAConfigFoldersProjects() throws {
        let account = root.appendingPathComponent("account")
        try transcript([turn("/Users/demo/my-app")], at: account.appendingPathComponent("projects/-Users-demo-my-app/1.jsonl").path)
        try transcript([turn("/Users/demo/my.app")], at: account.appendingPathComponent("projects/-Users-demo-my-app/2.jsonl").path)
        let canonical = root.appendingPathComponent("canonical")
        try transcript([turn("/Users/demo/shared")], at: canonical.appendingPathComponent("projects/-Users-demo-shared/3.jsonl").path)
        try fm.createSymbolicLink(atPath: account.appendingPathComponent("projects/-Users-demo-shared").path,
                                  withDestinationPath: canonical.appendingPathComponent("projects/-Users-demo-shared").path)
        let mirror = root.appendingPathComponent("mirror/abcd1234")
        try transcript([turn("/Users/demo/gone")], at: mirror.appendingPathComponent("-Users-demo-gone/4.jsonl").path)
        try transcript([turn("/Users/demo/x")], at: account.appendingPathComponent("projects/-Users-demo-x/memory.md").path)

        XCTAssertEqual(TranscriptCwds.all(configDir: account.path, extraFolders: [mirror.path]),
                       ["/Users/demo/gone", "/Users/demo/my-app", "/Users/demo/my.app", "/Users/demo/shared"])
        XCTAssertEqual(TranscriptCwds.all(configDir: root.appendingPathComponent("nowhere").path), [])
    }
}
