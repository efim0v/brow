// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit
import GroveCore

/// The Agents tab's reader at work on a made-up config folder: a cold start reads what was
/// written in the last half hour, the folder is followed while the panel is open and for a
/// while after, and an observer that does not read never looks. The two sessions are the
/// test's own `/bin/sleep`; every name, path and line is invented.
@MainActor
final class AgentsObserverTests: XCTestCase {
    private var cfg: String!
    private var processes: [Process] = []
    private let atlasId = "1a2b3c4d-1111-4111-8111-aaaaaaaaaaaa"
    private let harborId = "2b3c4d5e-2222-4222-8222-bbbbbbbbbbbb"
    private let cwd = "/Users/demo/Code/atlas"

    override func setUpWithError() throws {
        cfg = try FixtureLite.tempDir("agents-observer-cfg").path
        for (name, id) in [("atlas", atlasId), ("harbor", harborId)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            processes.append(process)
            let pid = process.processIdentifier
            let started = try XCTUnwrap(SessionRegistry.startTime(of: pid))
            try write(["pid": Int(pid), "sessionId": id, "cwd": cwd, "name": name, "status": "busy", "procStart": started],
                      to: cfg + "/sessions/\(pid).json")
        }
        addTeardownBlock { [processes] in
            for process in processes { process.terminate(); process.waitUntilExit() }
        }
    }

    private func write(_ object: Any, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path))
    }

    private var transcript: String { cfg + "/projects/-Users-demo-Code-atlas/" + atlasId + ".jsonl" }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// atlas's SendMessage to harbor and what it returned, `ago` seconds back.
    private func send(_ text: String, msgId: String, ago: TimeInterval, tool: String) -> String {
        let at = Self.stamp.string(from: Date().addingTimeInterval(-ago))
        let use: [String: Any] = [
            "type": "assistant", "uuid": "u-\(tool)-1", "sessionId": atlasId, "cwd": cwd, "timestamp": at,
            "message": ["role": "assistant", "content": [["type": "tool_use", "id": tool, "name": "SendMessage",
                                                          "input": ["to": "harbor", "message": text]]]],
        ]
        let result: [String: Any] = [
            "type": "user", "uuid": "u-\(tool)-2", "sessionId": atlasId, "cwd": cwd, "timestamp": at,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": tool,
                                                     "content": [["type": "text", "text": "sent"]]]]],
            "toolUseResult": ["success": true, "message": "sent to harbor", "msg_id": msgId],
        ]
        return [use, result].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }
            .joined()
    }

    private func observer(reads: Bool = true) -> AgentsObserver {
        let observer = AgentsObserver(accounts: [AgentsAccount(name: "Work", dot: nil, configDirs: [cfg])], reads: reads)
        addTeardownBlock { @MainActor in observer.stop() }
        return observer
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The panel opening reads the last half hour; a line written while it is open shows
    /// within a moment; "● Live" while a message is under a minute old.
    func testItReadsWhatWasWrittenAndFollowsWhatIsWritten() async throws {
        try FileManager.default.createDirectory(atPath: (transcript as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(send("The schema migration is done.", msgId: "5f0e2a10-0000-4000-8000-000000000001", ago: 20,
                      tool: "toolu_first").utf8).write(to: URL(fileURLWithPath: transcript))
        let observer = observer()
        observer.panelOpened()
        XCTAssertTrue(observer.isWatching)
        try await waitFor("the first message") { observer.graph.messages.count == 1 }
        let first = try XCTUnwrap(observer.graph.messages.first)
        let key = observer.accounts[0].key
        XCTAssertEqual(first.from, "session:\(key):\(atlasId)")
        XCTAssertEqual(first.to, "session:\(key):\(harborId)", "the name resolves to the session that has it")
        XCTAssertEqual(observer.graph.nodes[first.to]?.live?.status, "busy")
        XCTAssertTrue(observer.isLive)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(send("Rebase on main when you can.", msgId: "5f0e2a10-0000-4000-8000-000000000002",
                                               ago: 0, tool: "toolu_second").utf8))
        try handle.close()
        try await waitFor("the message written while watching") { observer.graph.messages.count == 2 }
        XCTAssertEqual(observer.graph.messages.first?.text, "Rebase on main when you can.")
    }

    /// The watch outlives the panel's close by `linger`, and stops then; opening again
    /// before that keeps it.
    func testTheWatchStopsAWhileAfterThePanelCloses() async throws {
        let observer = observer()
        observer.linger = 0.3
        observer.panelOpened()
        observer.panelClosed()
        observer.panelOpened()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(observer.isWatching, "opened again before the watch stopped")
        observer.panelClosed()
        XCTAssertTrue(observer.isWatching)
        try await waitFor("the watch to stop") { !observer.isWatching }
    }

    /// A pointer passing over the notch opens the panel for a moment: a watch asked for a
    /// moment on starts only if the panel is still open then.
    func testAPassOverTheNotchStartsNoWatch() async throws {
        let observer = observer()
        observer.panelOpened(after: 0.2)
        XCTAssertFalse(observer.isWatching, "not at once")
        observer.panelClosed()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(observer.isWatching, "closed before the watch was due")
        observer.panelOpened(after: 0.2)
        try await waitFor("the watch, once the panel stayed open") { observer.isWatching }
    }

    /// An observer that does not read — the host's, in tests and renders — never looks.
    func testAnObserverThatDoesNotReadNeverLooks() async throws {
        try FileManager.default.createDirectory(atPath: (transcript as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(send("Anyone there?", msgId: "5f0e2a10-0000-4000-8000-000000000003", ago: 5,
                      tool: "toolu_third").utf8).write(to: URL(fileURLWithPath: transcript))
        let observer = observer(reads: false)
        observer.panelOpened()
        observer.rescan()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(observer.isWatching)
        XCTAssertTrue(observer.graph.messages.isEmpty)
    }

    /// Two folders that are one (a link) are read once, under the account's key.
    func testFoldersThatAreOneAreReadOnce() throws {
        let link = try FixtureLite.tempDir("agents-observer-link").appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cfg)
        let account = AgentsAccount(name: "Work", dot: nil, configDirs: [cfg, link])
        let readers = AgentsObserver.readerAccounts([account])
        XCTAssertEqual(readers.count, 1)
        XCTAssertEqual(readers.first?.name, account.key)
        XCTAssertTrue(account.key.hasPrefix("acct-"))
        XCTAssertFalse(account.key.contains("Work"), "the key never carries a name the user typed")
    }
}
