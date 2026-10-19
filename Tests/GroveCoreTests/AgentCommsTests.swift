// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// Who messages whom, read from a made-up config folder laid out as Claude Code 2.1.302
/// writes it (`AgentCommsFixture`): the reference reader's cases, then the reader's own.
final class AgentCommsTests: XCTestCase {
    private typealias F = AgentCommsFixture
    private var root: URL!
    private var cfg: String!

    private let atlas = "session:work:" + AgentCommsFixture.atlas
    private let harbor = "session:work:" + AgentCommsFixture.harbor
    private let lumen = "agent:work:\(AgentCommsFixture.atlas):\(AgentCommsFixture.lumen)"
    private let scout = "teammate:work:\(AgentCommsFixture.team):scout"
    private let remote = "remote:session_01FixtureRemote7"

    override func setUpWithError() throws {
        root = try Fixture.tempDir("agent-comms")
        cfg = try F.build(at: root)
        addTeardownBlock { [cfg] in AgentCommsFixture.release(cfg!) }
    }

    private func reader() -> AgentCommsReader {
        let reader = AgentCommsReader(accounts: [AgentAccount(name: "work", configDir: cfg)])
        reader.loadStatic()
        reader.readRecent(since: Date().addingTimeInterval(-30 * 60))
        return reader
    }

    private func message(_ graph: AgentGraph, _ from: String, _ to: String, _ start: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> AgentMessage {
        let hits = graph.messages.filter { $0.from == from && $0.to == to && $0.text.hasPrefix(start) }
        XCTAssertEqual(hits.count, 1, "one message \(from) → \(to) “\(start)”, got \(hits)", file: file, line: line)
        return try XCTUnwrap(hits.first, file: file, line: line)
    }

    // MARK: - The formats Claude Code itself accepts

    /// 2.1.302's own check of "exactly one envelope its harness formed", copied from it.
    private static let strictCrossSession = try! NSRegularExpression(pattern:
        #"^<cross-session-message(?: from="([A-Za-z0-9%:_/.\\-]+)")?(?: from-session="([A-Za-z0-9_-]{1,80})")?"#
        + #"(?: hop-chain="([0-9a-f]{24}(?:,[0-9a-f]{24}){0,31})")?(?: from-name="([^"<>\n\r]+)")?"#
        + #"(?: from-mode="(bypass|prompting)")?(?: from-plugin="([^"<>\n\r]+)")?>\n([\s\S]*)\n"#
        + #"</cross-session-message>$"#)
    private static let strictTeammateOpen = try! NSRegularExpression(pattern:
        #"<teammate-message\s+teammate_id="([^"]+)"(?:\s+color="([^"]+)")?(?:\s+summary="([^"]+)")?(?:\s+verified="(false)")?>\n?"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func testTheFixturesEnvelopesAreTheOnesClaudeCodeWrites() throws {
        let path = cfg + "/projects/-Users-demo-Code-harbor/" + F.harbor + ".jsonl"
        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .filter { $0.hasSuffix("}") }
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let contents = rows.compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
        XCTAssertEqual(contents.count, 3)
        for text in contents.prefix(2) {
            XCTAssertTrue(Self.matches(Self.strictCrossSession, text), text)
        }
        let odd = contents[2]
        XCTAssertFalse(Self.matches(Self.strictCrossSession, odd), "2.1.302 would not take it")
        XCTAssertEqual(AgentEnvelope.all(in: odd).first?.attributes["from"], "uds:" + F.atlasSocket, "this reader does")
    }

    func testTheTeammateEnvelopeIsTheOneClaudeCodeWrites() {
        let text = F.envelope("teammate-message", [("teammate_id", "scout"), ("color", "blue"), ("summary", "x")], "hi")
        XCTAssertTrue(Self.matches(Self.strictTeammateOpen, text))
        let two = text + "\n\n" + F.envelope("teammate-message", [("teammate_id", "team-lead")], "bye")
        XCTAssertEqual(AgentEnvelope.all(in: two).map { $0.attributes["teammate_id"] }, ["scout", "team-lead"])
    }

    // MARK: - The records

    func testTheRecordsGiveNamesSocketsAndStates() {
        let graph = reader().graph()
        XCTAssertEqual(graph.nodes[atlas]?.name, "atlas")
        XCTAssertEqual(graph.nodes[atlas]?.live?.status, "busy")
        XCTAssertEqual(graph.nodes[atlas]?.live?.startedAt, Date(timeIntervalSince1970: 1_792_400_280),
                       "startedAt in milliseconds")
        XCTAssertEqual(graph.nodes[harbor]?.live?.status, "", "no status yet")
        XCTAssertEqual(graph.nodes[harbor]?.live?.kind, "bg")
    }

    /// The inbox key beside the records is never opened, whatever the reader does.
    func testTheInboxKeyIsNeverOpened() {
        let reader = AgentCommsReader(accounts: [AgentAccount(name: "work", configDir: cfg)])
        reader.recordsReads = true
        reader.loadStatic()
        reader.readRecent(since: .distantPast)
        reader.changed(cfg + "/sessions/" + F.keyFile)
        reader.changed(cfg + "/sessions/41001.json")
        _ = reader.graph()
        XCTAssertFalse(reader.readsLog.isEmpty)
        XCTAssertFalse(reader.readsLog.contains { $0.hasSuffix(".key") }, "opened: \(reader.readsLog.filter { $0.hasSuffix(".key") })")
    }

    /// /private/tmp and /tmp are one folder; a socket moved aside keeps its pid.
    func testASocketIsItsSessionHoweverItIsSpelled() {
        let reader = reader()
        XCTAssertEqual(reader.socketNode("/private/tmp/cc-socks/41001.sock", pid: nil, account: "work"), atlas)
        XCTAssertEqual(reader.socketNode("/tmp/cc-socks/41002-0a1b2c3d.sock", pid: nil, account: "work"), harbor)
        XCTAssertEqual(reader.socketNode("/tmp/cc-socks/99999.sock", pid: nil, account: "work"), "uds:/tmp/cc-socks/99999.sock")
    }

    // MARK: - The messages

    func testTwoSessionsTalkingBothWays() throws {
        let graph = reader().graph()
        let out = try message(graph, atlas, harbor, "Schema migration finished")
        XCTAssertEqual(out.kind, .crossSession)
        XCTAssertEqual(out.delivery, .delivered)
        XCTAssertEqual(out.msgId, F.m1)
        XCTAssertEqual(out.summary, "schema migration done")
        XCTAssertEqual(out.text, "Schema migration finished", "the first line only")
        let back = try message(graph, harbor, atlas, "Thanks")
        XCTAssertEqual(back.delivery, .delivered)
        XCTAssertEqual(back.msgId, F.m2)
        XCTAssertEqual(back.at, parseISODate("2026-10-19T09:00:08.000Z"), "sent when the sender's line says")
        XCTAssertEqual(back.arrivedAt, parseISODate("2026-10-19T09:00:09.000Z"), "arrived with the queue record")
    }

    func testASessionOnAnotherMacAndAttributesInAnyOrder() throws {
        let graph = reader().graph()
        XCTAssertEqual(try message(graph, remote, harbor, "Release notes").kind, .crossSession)
        XCTAssertEqual(graph.nodes[remote]?.name, "studio-mac")
        XCTAssertEqual(graph.nodes[remote]?.kind, .remote)
        XCTAssertEqual(try message(graph, atlas, harbor, "One more thing").delivery, .delivered)
    }

    func testASubagentBothWays() throws {
        let graph = reader().graph()
        let down = try message(graph, atlas, lumen, "Also check the foreign keys")
        XCTAssertEqual(down.kind, .subagent)
        XCTAssertEqual(down.delivery, .delivered)
        let up = try message(graph, lumen, atlas, "Indexes are fine")
        XCTAssertEqual(up.kind, .subagent)
        XCTAssertEqual(up.delivery, .delivered)
        XCTAssertTrue(graph.spawns.contains { $0.parent == atlas && $0.child == lumen && $0.kind == .subagent })
        XCTAssertEqual(graph.nodes[lumen]?.name, "lumen")
        XCTAssertEqual(graph.nodes[lumen]?.parent, atlas)
        XCTAssertEqual(graph.nodes[lumen]?.detail, "Check tenant indexes")
    }

    func testTeammatesThroughTheMailbox() throws {
        let graph = reader().graph()
        let down = try message(graph, atlas, scout, "Start with the last three CI runs.")
        XCTAssertEqual(down.kind, .teammate)
        XCTAssertEqual(down.delivery, .delivered)
        XCTAssertEqual(down.msgId, F.m3)
        let up = try message(graph, scout, atlas, "It depends on the wall clock.")
        XCTAssertEqual(up.delivery, .delivered)
        XCTAssertEqual(up.msgId, F.m4)
        let bookkeeping = graph.messages.filter { $0.kind == .teammateProtocol }
        XCTAssertEqual(bookkeeping.map { [$0.from, $0.to, $0.delivery.rawValue] }, [[scout, atlas, "sent"]])
        XCTAssertEqual(bookkeeping.first?.text, "idle notification: found the cause")
        XCTAssertTrue(graph.spawns.contains { $0.parent == atlas && $0.child == scout && $0.kind == .teammate })
        XCTAssertEqual(graph.messages.filter { $0.text.hasPrefix("Find which test") }, [],
                       "the spawn prompt is the spawn, not a message")
        XCTAssertEqual(graph.nodes[scout]?.parent, atlas)
    }

    func testASendNobodyTookFailed() throws {
        XCTAssertEqual(try message(reader().graph(), atlas, "name:nobody-here", "Are you there?").delivery, .failed)
    }

    func testTenMessagesInAll() {
        XCTAssertEqual(reader().graph().messages.count, 10)
    }

    // MARK: - Following a file

    func testAPartialLastLineWaitsForItsNewline() throws {
        let reader = reader()
        let path = cfg + "/projects/-Users-demo-Code-harbor/" + F.harbor + ".jsonl"
        var taken: [String] = []
        reader.onLineTaken = { taken.append($0) }
        reader.changed(path)
        XCTAssertEqual(taken, [], "nothing new, and half a line is not a line")
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(F.partialRest.utf8))
        try handle.close()
        reader.changed(path)
        XCTAssertEqual(taken, ["u-h06"])
    }

    /// A rewrite swaps the file: it is read again from the start, and a line already taken
    /// is not taken twice.
    func testARewrittenFileIsReadAgainWithoutCountingTwice() throws {
        let reader = reader()
        let path = cfg + "/projects/-Users-demo-Code-harbor/" + F.harbor + ".jsonl"
        let before = reader.graph().messages.count
        var taken: [String] = []
        reader.onLineTaken = { taken.append($0) }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let rewritten = text.components(separatedBy: "\n").filter { !$0.isEmpty && $0.hasSuffix("}") }.joined(separator: "\n") + "\n"
            + F.json(F.entry(F.harbor, F.harborCwd, "user", "u-h07", "u-h05", "2026-10-19T09:07:00.000Z",
                             ["message": ["role": "user", "content": F.envelope(
                                 "cross-session-message", [("from", "uds:" + F.atlasSocket), ("from-name", "atlas")],
                                 "Last one.")], "isMeta": true])) + "\n"
        try Data(rewritten.utf8).write(to: URL(fileURLWithPath: path + ".new"))
        XCTAssertEqual(rename(path + ".new", path), 0, "a rewrite swaps the file: a new inode")
        reader.changed(path)
        XCTAssertEqual(taken, ["u-h07"])
        XCTAssertEqual(reader.graph().messages.count, before + 1)
    }

    /// A file that shrank is read again from its start.
    func testAShrunkFileIsReadFromItsStart() throws {
        let reader = reader()
        let path = cfg + "/projects/-Users-demo-Code-harbor/" + F.harbor + ".jsonl"
        var taken: [String] = []
        reader.onLineTaken = { taken.append($0) }
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((F.json(F.entry(F.harbor, F.harborCwd, "user", "u-h08", nil, "2026-10-19T09:08:00.000Z",
            ["message": ["role": "user", "content": F.envelope("cross-session-message",
                [("from", "uds:" + F.atlasSocket), ("from-name", "atlas")], "After the cut.")], "isMeta": true])) + "\n").utf8))
        try handle.close()
        reader.changed(path)
        XCTAssertEqual(taken, ["u-h08"])
        XCTAssertNotNil(try? message(reader.graph(), atlas, harbor, "After the cut."))
    }

    /// A cold start reads only the transcripts written in its window, and of them only the end.
    func testAColdStartReadsOnlyRecentTranscripts() throws {
        let old = Date().addingTimeInterval(-3_600)
        let fm = FileManager.default
        let enumerator = fm.enumerator(atPath: cfg + "/projects")
        while let path = enumerator?.nextObject() as? String {
            guard path.hasSuffix(".jsonl") else { continue }
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: cfg + "/projects/" + path)
        }
        let reader = AgentCommsReader(accounts: [AgentAccount(name: "work", configDir: cfg)])
        reader.loadStatic()
        reader.readRecent(since: Date().addingTimeInterval(-30 * 60))
        let graph = reader.graph()
        XCTAssertEqual(graph.messages.count, 3, "only the mailboxes, which have no window: \(graph.messages.map(\.text))")
        XCTAssertTrue(graph.messages.allSatisfy { $0.kind == .teammate || $0.kind == .teammateProtocol })
    }

    /// Of a message only its first line is kept, at most 140 characters.
    func testOnlyTheFirstLineIsKeptAndAtMost140Characters() throws {
        let long = String(repeating: "миграция ", count: 40) + "\nsecond line, never kept"
        let path = cfg + "/projects/-Users-demo-Code-harbor/" + F.harbor + ".jsonl"
        let reader = reader()
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + F.json(F.entry(F.harbor, F.harborCwd, "user", "u-h09", nil, "2026-10-19T09:09:00.000Z",
            ["message": ["role": "user", "content": F.envelope("cross-session-message",
                [("from", "uds:" + F.atlasSocket), ("from-name", "atlas")], long)], "isMeta": true])) + "\n").utf8))
        try handle.close()
        reader.changed(path)
        let kept = try XCTUnwrap(reader.graph().messages.first { $0.text.hasPrefix("миграция") })
        XCTAssertEqual(kept.text.count, AgentCommsReader.maxText)
        XCTAssertTrue(kept.text.hasSuffix("…"))
        XCTAssertFalse(kept.text.contains("second line"))
    }

    /// Nothing of a message outlives the window the picture keeps, and the reader writes
    /// nothing anywhere.
    func testPruningForgetsAndNothingIsWritten() throws {
        func snapshot() throws -> [String: Date] {
            var files: [String: Date] = [:]
            let enumerator = FileManager.default.enumerator(atPath: cfg)
            while let path = enumerator?.nextObject() as? String {
                let full = cfg + "/" + path
                files[path] = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            }
            return files
        }
        let before = try snapshot()
        let reader = reader()
        XCTAssertFalse(reader.graph().messages.isEmpty)
        reader.prune(before: Date())
        reader.readMailboxes()
        let after = reader.graph()
        XCTAssertEqual(after.messages.count, 3)
        XCTAssertTrue(after.messages.allSatisfy { $0.kind == .teammate || $0.kind == .teammateProtocol },
                      "the transcripts' messages are gone; a mailbox is read afresh each time")
        XCTAssertEqual(try snapshot(), before, "no file added or changed")
    }
}
