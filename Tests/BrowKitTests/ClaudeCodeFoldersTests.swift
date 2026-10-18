// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import GroveCore
import XCTest
@testable import BrowKit

/// Where running sessions work, read from the kernel, and turned into project
/// suggestions. The processes are the test's own stand-ins (`ClaudeCodeStandIn`, started
/// through a symlink called `claude`), in folders the test makes.
final class ClaudeCodeFoldersTests: XCTestCase {
    private var lab: URL!
    private let fm = FileManager.default
    /// The stand-ins this test started: the only processes whose arguments and folder it reads.
    private var mine: Set<pid_t> = []

    override func setUpWithError() throws {
        lab = try Fixture.tempDir("claude-folders")
    }

    private func makeRepo(_ relative: String) throws -> URL {
        let repo = lab.appendingPathComponent(relative)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.sh("git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base", in: repo)
        return repo
    }

    @discardableResult
    private static func sh(_ command: String, in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "sh", code: Int(process.terminationStatus)) }
        return text
    }

    private func standIn(in dir: URL) throws -> Process {
        let runner = try XCTUnwrap(ProcessTable.executablePath(of: getpid()))
        let bin = lab.appendingPathComponent("bin")
        let link = bin.appendingPathComponent("claude")
        if !fm.fileExists(atPath: link.path) {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: runner))
        }
        var env = ProcessInfo.processInfo.environment
        env[ClaudeCodeStandIn.sleepVariable] = "30"
        let process = Process()
        process.executableURL = link
        process.arguments = ["-XCTest", "BrowKitTests.ClaudeCodeStandIn/testStandInForAClaudeCodeSession",
                             Bundle(for: ClaudeCodeStandIn.self).bundlePath]
        process.environment = env
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        mine.insert(process.processIdentifier)
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process
    }

    /// The look, kept to this test's stand-ins: any other process has no path here, so
    /// only its kernel name is seen, and that never passes `candidate`.
    private func folders() throws -> [ProjectSuggestions.Live] {
        let runner = try XCTUnwrap(ProcessTable.executablePath(of: getpid()))
        let mine = self.mine
        return ProcessTable.claudeCodeFolders(excludingChildrenOf: -1, candidate: { $0 == runner },
                                              pathOf: { mine.contains($0) ? ProcessTable.executablePath(of: $0) : nil })
    }

    func testTheKernelReportsEachSessionsFolderAndTheSuggestionsFollow() throws {
        let harbor = try makeRepo("Code/harbor")
        try fm.createDirectory(at: harbor.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: lab.appendingPathComponent("Code/harbor-link"), withDestinationURL: harbor)
        _ = try makeRepo("Code/fleet/api")
        let worktree = lab.appendingPathComponent("Workspaces/harbor/feature-x")
        try fm.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.sh("git worktree add -q -b feature-x \(worktree.path)", in: harbor)

        let inSources = try standIn(in: harbor.appendingPathComponent("Sources"))
        let viaLink = try standIn(in: lab.appendingPathComponent("Code/harbor-link"))
        let inWorktree = try standIn(in: worktree)
        let inFleet = try standIn(in: lab.appendingPathComponent("Code/fleet"))
        Thread.sleep(forTimeInterval: 0.3)

        let found = try folders()
        let byPid = Dictionary(uniqueKeysWithValues: found.map { ($0.pid, $0.cwd) })
        let real = { (url: URL) in ProjectSuggestions.canonical(url.path) }
        XCTAssertEqual(byPid[inSources.processIdentifier], real(harbor.appendingPathComponent("Sources")))
        XCTAssertEqual(byPid[viaLink.processIdentifier], real(harbor), "the kernel keeps the real path, not the link")
        XCTAssertEqual(byPid[inWorktree.processIdentifier], real(worktree))
        XCTAssertEqual(found.count, 4)
        XCTAssertTrue(real(lab).hasPrefix("/private/"), "and /var is /private/var to the kernel")

        let suggestions = ProjectSuggestions.suggest(live: found, covered: [], home: lab.path, temporaryRoots: [])
        XCTAssertEqual(suggestions.map(\.path), [real(harbor), real(lab.appendingPathComponent("Code/fleet"))])
        XCTAssertEqual(suggestions.first?.pids.sorted(),
                       [inSources, viaLink, inWorktree].map(\.processIdentifier).sorted())
        XCTAssertEqual(ProjectSuggestions.suggest(live: found, covered: [harbor.path], home: lab.path, temporaryRoots: [])
            .map(\.path), [real(lab.appendingPathComponent("Code/fleet"))])
        _ = inFleet
    }

    func testHeadlessRunsAreNotSessions() {
        func args(_ argv: [String]) -> ProcessArguments {
            ProcessArguments(executablePath: argv[0], argv: argv, claudeConfigDir: nil)
        }
        XCTAssertTrue(ClaudeCodeMatcher.isHeadless(args(["claude", "-p", "summarise"])))
        XCTAssertTrue(ClaudeCodeMatcher.isHeadless(args(["claude", "--print"])))
        XCTAssertTrue(ClaudeCodeMatcher.isHeadless(args(["claude", "--output-format", "stream-json", "--verbose"])))
        XCTAssertTrue(ClaudeCodeMatcher.isHeadless(args(["node", "cli.js", "--output-format=stream-json"])))
        XCTAssertFalse(ClaudeCodeMatcher.isHeadless(args(["claude"])))
        XCTAssertFalse(ClaudeCodeMatcher.isHeadless(args(["claude", "--resume", "9c2d7e1a-4b3f-4a6e-8d1c-2f5e6a7b8c9d"])))
        XCTAssertFalse(ClaudeCodeMatcher.isHeadless(args(["claude", "--output-format"])), "a flag cut short")
    }

    /// A session ending is seen at once, without polling: the kernel tells a dispatch
    /// source the moment the process exits. A new session's record appearing in a
    /// `sessions` folder is seen the same way, from the folder.
    func testExitsAndNewRecordsArriveAsEvents() throws {
        let child = try standIn(in: lab)
        let exited = expectation(description: "exit")
        let source = DispatchSource.makeProcessSource(identifier: child.processIdentifier, eventMask: .exit, queue: .global())
        source.setEventHandler { exited.fulfill() }
        source.resume()
        let killedAt = Date()
        child.terminate()
        wait(for: [exited], timeout: 2)
        source.cancel()
        let exitLatency = Date().timeIntervalSince(killedAt)

        let sessions = lab.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let fd = open(sessions.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let changed = expectation(description: "folder changed")
        changed.assertForOverFulfill = false
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global())
        watch.setEventHandler { changed.fulfill() }
        watch.setCancelHandler { close(fd) }
        watch.resume()
        let wroteAt = Date()
        try Data("{}".utf8).write(to: sessions.appendingPathComponent("4242.json"))
        wait(for: [changed], timeout: 2)
        watch.cancel()
        print(String(format: "events: process exit seen after %.1f ms, new record after %.1f ms",
                     exitLatency * 1000, Date().timeIntervalSince(wroteAt) * 1000))
    }

    /// What one look costs (run with `FOLDERS_PERF=1`, in release): the walk over this
    /// user's processes, and for each stand-in its path, arguments and folder.
    func testWhatALookCosts() throws {
        guard ProcessInfo.processInfo.environment["FOLDERS_PERF"] != nil else { throw XCTSkip("set FOLDERS_PERF=1") }
        let repo = try makeRepo("Code/harbor")
        var children: [Process] = []
        for _ in 0..<8 { children.append(try standIn(in: repo)) }
        Thread.sleep(forTimeInterval: 0.3)
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            var times: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return times.sorted()[runs / 2]
        }
        var count = 0
        let walk = median(50) { count = ProcessTable.userProcesses().count }
        let runner = try XCTUnwrap(ProcessTable.executablePath(of: getpid()))
        var found = 0
        let mine = self.mine
        let look = median(50) {
            found = ProcessTable.claudeCodeFolders(excludingChildrenOf: -1, candidate: { $0 == runner },
                                                   pathOf: { mine.contains($0) ? ProcessTable.executablePath(of: $0) : nil }).count
        }
        let pids = children.map(\.processIdentifier)
        let cwd = median(200) { for pid in pids { _ = ProcessTable.workingDirectory(of: pid) } } / Double(pids.count)
        let args = median(200) { for pid in pids { _ = ProcessTable.arguments(of: pid) } } / Double(pids.count)
        let paths = median(50) { for process in ProcessTable.userProcesses() { _ = ProcessTable.executablePath(of: process.pid) } }
        let suggest = median(200) {
            _ = ProjectSuggestions.suggest(live: pids.map { ProjectSuggestions.Live(pid: $0, cwd: repo.path) },
                                           covered: [], home: lab.path, temporaryRoots: [])
        }
        print(String(format: "look: %d processes walked in %.3f ms; proc_pidpath for all of them %.3f ms; whole look with %d stand-ins %.3f ms; per stand-in: cwd %.4f ms, arguments %.4f ms; suggest for 8 sessions %.3f ms",
                     count, walk, paths, found, look, cwd, args, suggest))
        XCTAssertEqual(found, children.count)
    }
}
