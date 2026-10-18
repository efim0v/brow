// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import BrowKit

/// One Workspaces engine at a time on one Grove config: the lock two copies of Brow
/// share. Two locks on one file here stand for two processes: `flock` locks taken
/// through separate opens of a file exclude each other within one process too.
final class WorkspacesEngineLockTests: XCTestCase {
    private func lockPath() throws -> String {
        try Fixture.tempDir("engine-lock").appendingPathComponent("Grove/workspaces.lock").path
    }

    func testOneHolderAtATime() throws {
        let path = try lockPath()
        let first = WorkspacesEngineLock(path: path)
        let second = WorkspacesEngineLock(path: path)
        XCTAssertTrue(first.acquire())
        XCTAssertTrue(first.isHeld)
        XCTAssertFalse(second.acquire(), "taken")
        XCTAssertFalse(second.isHeld)
        XCTAssertTrue(first.acquire(), "taking it again is harmless")

        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertTrue(second.acquire(), "free once the first lets go")
    }

    /// The folder is made when needed (a new setup has no Grove folder yet), and the lock
    /// goes with its owner — as the kernel lets go of it when a process exits.
    func testTheFolderIsMadeAndTheLockGoesWithItsOwner() throws {
        let path = try lockPath()
        var first: WorkspacesEngineLock? = WorkspacesEngineLock(path: path)
        XCTAssertTrue(first?.acquire() == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(WorkspacesEngineLock(path: path).acquire())
        first = nil
        XCTAssertTrue(WorkspacesEngineLock(path: path).acquire())
    }

    /// Beside Grove's config, so a test's folders keep it in their temp dir.
    func testItLivesBesideGrovesConfig() throws {
        let config = try Fixture.tempDir("engine-lock-folders").appendingPathComponent("config.json")
        let lock = WorkspacesEngineLock(folders: .beside(configFile: config))
        XCTAssertEqual(lock.path, config.deletingLastPathComponent().appendingPathComponent("workspaces.lock").path)
    }

    /// A lock file that can't be made does not stop Workspaces: the lock keeps a second
    /// copy of Brow out, it is not a condition for running.
    func testAFolderThatCannotBeWrittenDoesNotStopTheEngine() throws {
        let dir = try Fixture.tempDir("engine-lock-readonly")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let lock = WorkspacesEngineLock(path: dir.appendingPathComponent("workspaces.lock").path)
        XCTAssertTrue(lock.acquire())
        XCTAssertFalse(lock.isHeld)
    }
}
