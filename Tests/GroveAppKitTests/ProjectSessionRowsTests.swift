// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit
import GroveCore

final class ProjectSessionRowsTests: XCTestCase {
    private func session(_ id: String, cwd: String = "/ws/a", title: String? = "T",
                         account: String = "default", turn: SessionPreview.Turn? = nil) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: title, lastActivity: Date(),
                      accountName: account, gitBranch: nil,
                      preview: turn.map { SessionPreview(prompt: "p", reply: nil, tool: nil, title: nil, turn: $0, at: nil) })
    }

    private func live(_ sessionId: String, status: String, waitingFor: String? = nil) -> LiveProcess {
        LiveProcess(pid: 1, sessionId: sessionId, cwd: "/ws/a", status: status, accountName: "default",
                    waitingFor: waitingFor)
    }

    func testClosedWhenNoLiveProcess() {
        let rows = buildProjectSessionRows(sessions: [session("s1")], live: [], cmuxMap: [:])
        XCTAssertEqual(rows.first?.state, .closed)
        XCTAssertNil(rows.first?.cmuxWorkspaceId)
        XCTAssertFalse(rows.first?.canGo ?? true)
    }

    /// The one mapping, from the session's own record.
    func testEveryRecordedStatusMapsToOneState() {
        let rows = buildProjectSessionRows(
            sessions: ["busy", "permission", "sandbox", "worker", "goal", "input", "dialog", "other", "idle", "shell"]
                .map { session($0) },
            live: [live("busy", status: "busy"),
                   live("permission", status: "waiting", waitingFor: "permission prompt"),
                   live("sandbox", status: "waiting", waitingFor: "sandbox request"),
                   live("worker", status: "waiting", waitingFor: "worker request"),
                   live("goal", status: "waiting", waitingFor: "goal proposal"),
                   live("input", status: "waiting", waitingFor: "input needed"),
                   live("dialog", status: "waiting", waitingFor: "dialog open"),
                   live("other", status: "waiting", waitingFor: "something new"),
                   live("idle", status: "idle"),
                   live("shell", status: "shell")],
            cmuxMap: [:])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.state) })
        XCTAssertEqual(byId["busy"], .working)
        for id in ["permission", "sandbox", "worker", "goal"] { XCTAssertEqual(byId[id], .needsPermission, id) }
        for id in ["input", "dialog", "other"] { XCTAssertEqual(byId[id], .asksYou, id) }
        XCTAssertEqual(byId["idle"], .yourTurn)
        XCTAssertEqual(byId["shell"], .yourTurn)
    }

    /// A record without a status yet, or a process without a record: the transcript's
    /// last turn says.
    func testWithoutAStatusTheTranscriptsTurnSays() {
        let rows = buildProjectSessionRows(
            sessions: [session("w", turn: .working), session("t", turn: .tool), session("a", turn: .answered),
                       session("i", turn: .interrupted), session("n")],
            live: ["w", "t", "a", "i", "n"].map { live($0, status: "") },
            cmuxMap: [:])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.state) })
        XCTAssertEqual(byId["w"], .working)
        XCTAssertEqual(byId["t"], .working)
        XCTAssertEqual(byId["a"], .yourTurn)
        XCTAssertEqual(byId["i"], .yourTurn)
        XCTAssertEqual(byId["n"], .yourTurn)
    }

    /// One process runs one session: a process whose session could not be told marks none
    /// of the sessions in its folder live.
    func testAProcessWithoutASessionMarksNoSessionInItsFolder() {
        let rows = buildProjectSessionRows(
            sessions: [session("a", cwd: "/ws/group-chats"), session("b", cwd: "/ws/group-chats")],
            live: [LiveProcess(pid: 9, sessionId: "", cwd: "/ws/group-chats", status: "busy", accountName: "")],
            cmuxMap: [:])
        XCTAssertEqual(rows.map(\.state), [.closed, .closed])
    }

    func testTheRunningProcessesAccountWins() {
        let rows = buildProjectSessionRows(
            sessions: [session("s1", account: "default")],
            live: [LiveProcess(pid: 1, sessionId: "s1", cwd: "/ws/a", status: "idle", accountName: "work")],
            cmuxMap: [:])
        XCTAssertEqual(rows.first?.accountName, "work")
        XCTAssertEqual(rows.first?.state, .yourTurn)
    }

    func testGoTargetFromCmuxMap() {
        let rows = buildProjectSessionRows(sessions: [session("s1")],
                                           live: [live("s1", status: "busy")],
                                           cmuxMap: ["s1": "ws-3"])
        XCTAssertEqual(rows.first?.cmuxWorkspaceId, "ws-3")
        XCTAssertTrue(rows.first?.canGo ?? false)
    }

    func testTitleFallsBackToSessionIdPrefixAndLocationIsLeaf() {
        let rows = buildProjectSessionRows(sessions: [session("abcdefgh12345", cwd: "/p/work", title: nil)],
                                           live: [], cmuxMap: [:])
        XCTAssertEqual(rows.first?.title, "abcdefgh")
        XCTAssertEqual(rows.first?.location, "work")
    }

    /// A workspace by its folder under the root; the project's own folder by its branch.
    func testThePlaceIsTheWorkspaceOrTheBranch() {
        let sessions = [
            ClaudeSession(id: "w", cwd: "/ws/acme/checkout/web", title: "t", lastActivity: Date(), accountName: "a",
                          gitBranch: "feat/checkout"),
            ClaudeSession(id: "p", cwd: "/code/acme", title: "t", lastActivity: Date(), accountName: "a",
                          gitBranch: "main"),
            ClaudeSession(id: "r", cwd: "/code/acme/web", title: "t", lastActivity: Date(), accountName: "a",
                          gitBranch: "main"),
        ]
        let rows = buildProjectSessionRows(sessions: sessions, live: [], cmuxMap: [:],
                                           projectPath: "/code/acme", workspacesRoot: "/ws/acme")
        XCTAssertEqual(rows.map(\.location), ["checkout", "main", "web"])
    }
}
