// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// What the pet senses: the clocks between presence checks, and the `history.jsonl` watchers, against
/// real files in a temporary directory. The watchers only ever learn that a file was written; none
/// of these tests needs it to have contents worth reading.
@MainActor
final class PetSensesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The clocks

    func testTheClockWatchTellsASleepFromAJump() {
        var watch = PetClockWatch()
        XCTAssertEqual(watch.check(PetTime(wall: t0, mono: 100)), .steady, "the first check has nothing to compare")
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(5), mono: 105)), .steady)
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(14), mono: 110)), .steady, "4 s of drift is noise")
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(3600 + 19), mono: 115)), .slept(for: 3600))
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(3600 + 19 - 600 + 5), mono: 120)),
                       .jumped(by: -600), "the clock set back")
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(3600 + 19 - 600 + 5 + 25), mono: 125)),
                       .jumped(by: 20), "20 s ahead is a jump, not a sleep")
        watch.reset()
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(90_000), mono: 130)), .steady,
                       "after a wake the notification announced, no second wake")
        // After `NSSystemClockDidChange`, a big step forward is the clock being set, not a sleep; once.
        watch.clockWasSet()
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(90_000 + 3600 + 5), mono: 135)), .jumped(by: 3600))
        XCTAssertEqual(watch.check(PetTime(wall: t0.addingTimeInterval(90_000 + 7200 + 10), mono: 140)), .slept(for: 3600))
    }

    func testNowReadsTheMonotonicClock() {
        let before = ProcessInfo.processInfo.systemUptime
        let now = PetTime.now()
        XCTAssertGreaterThanOrEqual(now.mono, before)
        XCTAssertLessThan(now.mono - before, 1)
    }

    // MARK: - history.jsonl

    private var prompts = 0
    private var promptArrived: XCTestExpectation?

    private func watchers() -> PetHistoryWatchers {
        PetHistoryWatchers { [weak self] in
            guard let self else { return }
            self.prompts += 1
            self.promptArrived?.fulfill()
        }
    }

    private func expectPrompt(_ description: String, within timeout: TimeInterval = 3, _ action: () throws -> Void) rethrows {
        let expectation = expectation(description: description)
        expectation.assertForOverFulfill = false
        promptArrived = expectation
        try action()
        wait(for: [expectation], timeout: timeout)
        promptArrived = nil
    }

    private func expectNoPrompt(_ description: String, _ action: () throws -> Void) rethrows {
        let expectation = expectation(description: description)
        expectation.isInverted = true
        promptArrived = expectation
        try action()
        wait(for: [expectation], timeout: 0.5)
        promptArrived = nil
    }

    private func append(_ path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
    }

    /// Long enough after a prompt for the next write to be a prompt of its own.
    private func pastTheBurst() {
        RunLoop.main.run(until: Date().addingTimeInterval(PetTuning.Eager.promptBurst + 0.1))
    }

    private func dir(_ label: String) throws -> String {
        // The real path, as the watchers key them: the temporary directory is reached through /var, a
        // symlink to /private/var (which `URL.resolvingSymlinksInPath` maps back to /var).
        let path = try Fixture.tempDir("pet-history-\(label)").path
        return try XCTUnwrap(ClaudeCodeActivity.canonicalConfigDir(path, cwd: nil, home: NSHomeDirectory()))
    }

    func testAPromptWrittenToTheHistoryIsSensed() throws {
        let account = try dir("plain")
        FileManager.default.createFile(atPath: account + "/history.jsonl", contents: Data("{}\n".utf8))
        let watching = watchers()
        watching.watch(configDirs: [account])
        try expectPrompt("an append") { try append(account + "/history.jsonl") }
        pastTheBurst()
        try expectPrompt("another") { try append(account + "/history.jsonl") }
        XCTAssertEqual(watching.directories, [account])
    }

    /// Writes a moment apart are one prompt, as one append that reaches the watcher as two events is.
    func testABurstOfWritesIsOnePrompt() throws {
        let account = try dir("burst")
        FileManager.default.createFile(atPath: account + "/history.jsonl", contents: Data("{}\n".utf8))
        let watching = watchers()
        watching.watch(configDirs: [account])
        prompts = 0
        try expectPrompt("three quick appends") {
            for _ in 0..<3 {
                try append(account + "/history.jsonl")
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
        }
        pastTheBurst()
        XCTAssertEqual(prompts, 1)
        try expectPrompt("one later") { try append(account + "/history.jsonl") }
        XCTAssertEqual(prompts, 2)
        watching.stop()
    }

    /// No history yet: the directory is watched until the file appears, and its appearing is the
    /// first prompt.
    func testAHistoryThatDoesNotExistYetIsWaitedFor() throws {
        let account = try dir("missing")
        let watching = watchers()
        watching.watch(configDirs: [account])
        expectNoPrompt("another file in the folder") {
            FileManager.default.createFile(atPath: account + "/settings.json", contents: Data("{}".utf8))
        }
        expectPrompt("the history appears") {
            FileManager.default.createFile(atPath: account + "/history.jsonl", contents: Data("{}\n".utf8))
        }
        pastTheBurst()
        try expectPrompt("and is then watched itself") { try append(account + "/history.jsonl") }
    }

    /// A symlinked history is shared with other accounts and says nothing about this one.
    func testASymlinkedHistoryIsNotAPrompt() throws {
        let shared = try dir("shared"), account = try dir("linked")
        FileManager.default.createFile(atPath: shared + "/history.jsonl", contents: Data("{}\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: account + "/history.jsonl", withDestinationPath: shared + "/history.jsonl")
        let watching = watchers()
        watching.watch(configDirs: [account])
        try expectNoPrompt("a write through the link") { try append(shared + "/history.jsonl") }
        // It becomes a file of the account's own: from then on it counts.
        try FileManager.default.removeItem(atPath: account + "/history.jsonl")
        FileManager.default.createFile(atPath: account + "/history.jsonl", contents: Data())
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expectPrompt("its own file now") { try append(account + "/history.jsonl") }
    }

    /// Replaced by a rename, the file is watched again a second later; the replacement itself is not a
    /// prompt.
    func testAReplacedHistoryIsWatchedAgain() throws {
        let account = try dir("replaced")
        let path = account + "/history.jsonl"
        FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8))
        let watching = watchers()
        watching.watch(configDirs: [account])
        prompts = 0
        FileManager.default.createFile(atPath: account + "/history.new", contents: Data("{}\n".utf8))
        XCTAssertEqual(rename(account + "/history.new", path), 0)
        RunLoop.main.run(until: Date().addingTimeInterval(PetTuning.Eager.watcherReopen + 0.4))
        XCTAssertEqual(prompts, 0, "the rename and the reopen are not prompts")
        try expectPrompt("the new file") { try append(path) }
        XCTAssertEqual(prompts, 1)
    }

    func testTwoSpellingsOfOneFolderAreOneWatcherAndStopClosesThemAll() throws {
        let account = try dir("spelled")
        let link = try dir("spelling") + "/alias"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: account)
        FileManager.default.createFile(atPath: account + "/history.jsonl", contents: Data())
        let watching = watchers()
        watching.watch(configDirs: [account, link, account + "/"])
        XCTAssertEqual(watching.directories, [account])
        prompts = 0
        try expectPrompt("one prompt") { try append(account + "/history.jsonl") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(prompts, 1, "one watcher, one prompt")

        watching.watch(configDirs: [])
        XCTAssertEqual(watching.directories, [])
        try expectNoPrompt("an account no longer visible") { try append(account + "/history.jsonl") }
        watching.watch(configDirs: [account])
        watching.stop()
        try expectNoPrompt("the pet off") { try append(account + "/history.jsonl") }
    }

    func testAFolderThatDoesNotExistIsNoError() throws {
        let watching = watchers()
        watching.watch(configDirs: [try dir("gone") + "/not-there"])
        XCTAssertEqual(watching.directories.count, 1)
        watching.stop()
    }
}
