// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// `ClaudeService.isSessionLive(among:sessionId:)`: the guard of everything that moves or
/// links a transcript. By id only: every live process is joined to the one session it
/// runs, so a plain `claude` in the same folder running another session is no reason to
/// refuse.
final class SessionLivePredicateTests: XCTestCase {
    /// A session resumed by id runs, wherever its process sits.
    func testASessionRunningByItsIdIsLive() {
        let process = LiveProcess(pid: 1001, sessionId: "S1", cwd: "", status: "idle", accountName: "")
        XCTAssertTrue(ClaudeService.isSessionLive(among: [process], sessionId: "S1"))
    }

    /// A process in the session's folder running ANOTHER session does not make it live:
    /// that is what raised "live under a running session" on sessions nothing ran.
    func testAnotherSessionInTheSameFolderIsNotThisOne() {
        let process = LiveProcess(pid: 1002, sessionId: "S9", cwd: "/Users/x/Projects/myapp", status: "busy",
                                  accountName: "")
        XCTAssertFalse(ClaudeService.isSessionLive(among: [process], sessionId: "S2"))
    }

    /// A process whose session could not be told runs none of the listed ones.
    func testAProcessWithoutASessionRunsNone() {
        let process = LiveProcess(pid: 1003, sessionId: "", cwd: "/Users/x/Projects/myapp", status: "busy",
                                  accountName: "")
        XCTAssertFalse(ClaudeService.isSessionLive(among: [process], sessionId: "S2"))
        XCTAssertFalse(ClaudeService.isSessionLive(among: [process], sessionId: ""),
                       "an empty id never matches an empty id")
    }

    func testNothingRunningIsNothingLive() {
        XCTAssertFalse(ClaudeService.isSessionLive(among: [], sessionId: "S1"))
    }
}
