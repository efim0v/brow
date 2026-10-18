// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// grove#9: the deadline on the Keychain tool has to hold even when the tool hangs.
/// Every run here is a stand-in script in a temp dir; the real tool is never run.
final class ToolTimeoutTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixture.tempDir("tool-timeout")
    }

    private func standIn(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Before the fix the caller sat inside the pipe read for as long as the tool did.
    func testAToolThatHangsIsGivenUpOnAtTheDeadline() throws {
        let tool = try standIn("hangs", "exec sleep 30")
        let started = Date()
        let outcome = KeychainCredentialsReader.runTool(tool, [], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 5, "the deadline holds (took \(elapsed) s)")
    }

    /// A child that keeps stdout open after its parent is killed cannot hold the
    /// caller past the deadline either.
    func testAToolWhoseChildHoldsTheOutputIsGivenUpOnToo() throws {
        let tool = try standIn("forks", "sleep 30 &\nsleep 30")
        let started = Date()
        XCTAssertEqual(KeychainCredentialsReader.runTool(tool, [], timeout: 0.5), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testOutputAndStatusComeBack() throws {
        let ok = try standIn("ok", #"printf 'secret-json\n'"#)
        XCTAssertEqual(KeychainCredentialsReader.runTool(ok, [], timeout: 5),
                       .exited(0, Data("secret-json\n".utf8)))
        let missing = try standIn("missing", "exit 44")
        XCTAssertEqual(KeychainCredentialsReader.runTool(missing, [], timeout: 5), .exited(44, Data()))
        let args = try standIn("args", #"printf '%s|' "$@""#)
        XCTAssertEqual(KeychainCredentialsReader.runTool(args, ["a", "b c"], timeout: 5),
                       .exited(0, Data("a|b c|".utf8)))
    }

    func testAToolThatCannotStartIsReportedAsSuch() {
        XCTAssertEqual(KeychainCredentialsReader.runTool(dir.appendingPathComponent("absent").path, [], timeout: 1),
                       .couldNotStart)
    }
}
