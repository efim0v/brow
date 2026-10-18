// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

final class ClaudeCodeActivityTests: XCTestCase {
    // MARK: - KERN_PROCARGS2

    /// The area as the kernel lays it out: argc, the start path, NUL padding, the
    /// arguments, the environment ended by an empty string, then the "apple" strings.
    private func procArgs(exec: String, argv: [String], env: [String], padding: Int = 3,
                          argvArea: [UInt8]? = nil) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(argv.count).littleEndian) { Array($0) }
        bytes += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        bytes += argvArea ?? argv.flatMap { Array($0.utf8) + [0] }
        for entry in env { bytes += Array(entry.utf8) + [0] }
        bytes += [0]
        bytes += Array("executable_path=\(exec)".utf8) + [0] + Array("ptr_munge=".utf8) + [0]
        return bytes
    }

    private func parse(_ bytes: [UInt8]) -> ProcessArguments? {
        bytes.withUnsafeBytes { ProcessArguments.parse($0) }
    }

    func testParseReadsTheArgumentsAndOnlyTheConfigDirFromTheEnvironment() throws {
        let parsed = try XCTUnwrap(parse(procArgs(
            exec: "/Users/u/.local/bin/claude",
            argv: ["/Users/u/.local/bin/claude", "--resume", "abc"],
            env: ["PATH=/usr/bin:/bin", "SOME_API_KEY=not-for-brow", "CLAUDE_CONFIG_DIR=/Users/u/.claude-accounts/work", "TERM=xterm"])))
        XCTAssertEqual(parsed.executablePath, "/Users/u/.local/bin/claude")
        XCTAssertEqual(parsed.argv, ["/Users/u/.local/bin/claude", "--resume", "abc"])
        XCTAssertEqual(parsed.claudeConfigDir, "/Users/u/.claude-accounts/work")
        XCTAssertFalse(String(describing: parsed).contains("not-for-brow"), "nothing else from the environment is kept")
    }

    func testParseWithoutTheVariableReportsItUnset() throws {
        let parsed = try XCTUnwrap(parse(procArgs(exec: "/x/claude", argv: ["claude"], env: ["HOME=/Users/u"])))
        XCTAssertNil(parsed.claudeConfigDir)
        let empty = try XCTUnwrap(parse(procArgs(exec: "/x/claude", argv: ["claude"], env: ["CLAUDE_CONFIG_DIR="])))
        XCTAssertEqual(empty.claudeConfigDir, "", "set but empty is passed on as it is; the probe maps it")
    }

    /// The apple strings after the environment are not the environment.
    func testParseStopsAtTheEndOfTheEnvironment() throws {
        var bytes = procArgs(exec: "/x/claude", argv: ["claude"], env: ["A=1"])
        bytes += Array("CLAUDE_CONFIG_DIR=/not/the/env".utf8) + [0]
        XCTAssertNil(try XCTUnwrap(parse(bytes)).claudeConfigDir)
    }

    /// A node process that set its title has its argument area overwritten with the
    /// title and zero-filled. Counting argc strings then ends inside the zeroes, and the
    /// environment after them must still be found, or the process reads as `~/.claude`.
    func testParseFindsTheEnvironmentAfterARewrittenTitle() throws {
        let original = ["node", "/opt/homebrew/bin/claude", "--resume"]
        let length = original.reduce(0) { $0 + $1.utf8.count + 1 }
        let rewritten = Array("claude".utf8) + [UInt8](repeating: 0, count: length - "claude".utf8.count)
        let parsed = try XCTUnwrap(parse(procArgs(exec: "/opt/homebrew/bin/node", argv: original,
                                                  env: ["CLAUDE_CONFIG_DIR=/Users/u/.claude-accounts/b"],
                                                  argvArea: rewritten)))
        XCTAssertEqual(parsed.argv.first, "claude")
        XCTAssertEqual(parsed.claudeConfigDir, "/Users/u/.claude-accounts/b")
    }

    func testParseSurvivesShortAndOddBuffers() {
        XCTAssertNil(parse([]))
        XCTAssertNil(parse([1, 0]))
        XCTAssertNil(parse(withUnsafeBytes(of: Int32(-1)) { Array($0) }), "a negative argc is not an argument area")
        // argc far larger than what follows: the arguments simply run out.
        var huge = withUnsafeBytes(of: Int32(1_000_000)) { Array($0) }
        huge += Array("/x/claude".utf8) + [0, 0] + Array("claude".utf8) + [0]
        XCTAssertEqual(parse(huge)?.argv, ["claude"])
    }

    // MARK: - which processes are Claude Code

    private func args(_ argv: [String], exec: String? = nil) -> ProcessArguments {
        ProcessArguments(executablePath: exec ?? argv.first ?? "", argv: argv, claudeConfigDir: nil)
    }

    func testMatchesEveryWayClaudeCodeIsInstalled() {
        let cases: [(path: String, argv: [String], why: String)] = [
            // Native installer: the binary is named after its version, started via a symlink.
            ("/Users/u/.local/share/claude/versions/2.1.299", ["/Users/u/.local/bin/claude", "--resume"], "native installer"),
            ("/Users/u/.local/share/claude/versions/2.1.299", ["2.1.299"], "native installer, argv rewritten"),
            ("/opt/homebrew/Caskroom/claude-code/2.1.299/claude", ["claude"], "Homebrew cask"),
            ("/Users/u/.vscode/extensions/anthropic.claude-code-2.1.299-darwin-arm64/resources/native-binary/claude",
             ["/Users/u/.vscode/extensions/anthropic.claude-code-2.1.299-darwin-arm64/resources/native-binary/claude"], "editor extension"),
            ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude", "-p", "hi"], "npm global, via its bin link"),
            ("/Users/u/.nvm/versions/node/v22.0.0/bin/node",
             ["node", "--no-warnings", "/Users/u/.nvm/versions/node/v22.0.0/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
             "npm global, runtime flags first"),
            ("/opt/homebrew/bin/bun", ["bun", "/Users/u/.bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js"], "bun"),
            ("/opt/homebrew/bin/node",
             ["node", "/Users/u/app/node_modules/@anthropic-ai/claude-agent-sdk/cli.js", "--output-format", "stream-json"],
             "an older Agent SDK running its bundled CLI"),
            ("/Users/u/app/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude",
             ["/Users/u/app/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude", "--output-format", "stream-json"],
             "a newer Agent SDK running its bundled binary"),
            ("/opt/homebrew/bin/node", ["claude"], "node after process.title = claude"),
        ]
        for c in cases {
            XCTAssertTrue(ClaudeCodeMatcher.mayBeClaudeCode(executable: c.path), "filter: \(c.why)")
            XCTAssertTrue(ClaudeCodeMatcher.isClaudeCode(executable: c.path, arguments: args(c.argv)), c.why)
        }
    }

    func testDoesNotMatchWhatIsNotAClaudeCodeSession() {
        // The desktop app is "Claude", capitalised, and it is not the CLI.
        XCTAssertFalse(ClaudeCodeMatcher.mayBeClaudeCode(executable: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertFalse(ClaudeCodeMatcher.mayBeClaudeCode(executable: "/bin/zsh"))
        XCTAssertFalse(ClaudeCodeMatcher.isClaudeCode(
            executable: "/opt/homebrew/bin/node", arguments: args(["node", "/Users/u/project/server.js"])),
                       "another node program")
        XCTAssertFalse(ClaudeCodeMatcher.isClaudeCode(
            executable: "/opt/homebrew/bin/node", arguments: args(["node", "--inspect"])), "no script at all")
        XCTAssertFalse(ClaudeCodeMatcher.isClaudeCode(
            executable: "/Users/u/.claude/plugins/some-server/bin/server", arguments: args(["server"])),
                       "an MCP server living under ~/.claude")
        // Claude in Chrome's bridge: it lives as long as Chrome and runs no session.
        XCTAssertFalse(ClaudeCodeMatcher.isClaudeCode(
            executable: "/Users/u/.local/share/claude/versions/2.1.299",
            arguments: args(["/Users/u/.local/bin/claude", "--chrome-native-host"])))
    }

    /// An update can delete the binary a running session was started from (`brew
    /// upgrade`, an editor extension update, the native installer's clean-up). The
    /// kernel then has no path for the process, only its short name: the file name it
    /// was started from, which for the native installer is the version number.
    func testAProcessWhoseFileIsGoneIsJudgedByItsKernelName() {
        for name in ["2.1.290", "claude", "node", "bun"] {
            XCTAssertTrue(ClaudeCodeMatcher.mayBeClaudeCode(executable: name), name)
        }
        for name in ["zsh", "Claude", "1", "2.", ".1", "v2.1.0", "2.1.0-beta", "1..2"] {
            XCTAssertFalse(ClaudeCodeMatcher.mayBeClaudeCode(executable: name), name)
        }
        XCTAssertFalse(ClaudeCodeMatcher.mayBeClaudeCode(executable: "/usr/local/lib/tool/1.2.3"),
                       "with a full path a version-named file counts only under claude/")

        let viaLink = ProcessArguments(executablePath: "/Users/u/.local/bin/claude",
                                       argv: ["/Users/u/.local/bin/claude", "--resume"], claudeConfigDir: "/d")
        XCTAssertTrue(ClaudeCodeMatcher.isClaudeCode(executable: "2.1.290", arguments: viaLink))
        let direct = ProcessArguments(executablePath: "/Users/u/.local/share/claude/versions/2.1.290",
                                      argv: ["2.1.290"], claudeConfigDir: "/d")
        XCTAssertTrue(ClaudeCodeMatcher.isClaudeCode(executable: "2.1.290", arguments: direct))
        XCTAssertFalse(ClaudeCodeMatcher.isClaudeCode(executable: "1.2.3", arguments: args(["/usr/local/lib/tool/1.2.3"])),
                       "a version-named program that is not Claude Code")
    }

    // MARK: - one spelling per config dir

    private var home: URL!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("activity-home")
        for dir in [".claude", ".claude-accounts/a", ".claude-accounts/b"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link-to-a"),
                                                   withDestinationURL: home.appendingPathComponent(".claude-accounts/a"))
    }

    private func canonical(_ raw: String?, cwd: String? = nil) -> String? {
        ClaudeCodeActivity.canonicalConfigDir(raw, cwd: cwd, home: home.path)
    }

    func testAnUnsetOrEmptyVariableMeansTheDefaultDir() {
        let defaultDir = canonical(home.path + "/.claude")
        XCTAssertNotNil(defaultDir)
        XCTAssertEqual(canonical(nil), defaultDir)
        XCTAssertEqual(canonical(""), defaultDir)
        XCTAssertNotEqual(canonical(home.path + "/.claude-accounts/a"), defaultDir)
    }

    func testOneDirHasOneSpelling() {
        let a = canonical(home.path + "/.claude-accounts/a")
        XCTAssertEqual(canonical(home.path + "/.claude-accounts/a/"), a, "trailing slash")
        XCTAssertEqual(canonical(home.path + "//.claude-accounts/./a"), a, "doubled slash and dot")
        XCTAssertEqual(canonical(home.path + "/.claude-accounts/b/../a"), a, "dot-dot")
        XCTAssertEqual(canonical("~/.claude-accounts/a"), a, "tilde")
        XCTAssertEqual(canonical("~/.claude-accounts/a/"), a, "tilde and trailing slash")
        XCTAssertEqual(canonical(home.path + "/link-to-a"), a, "symlink")
        XCTAssertEqual(canonical(".claude-accounts/a", cwd: home.path), a, "relative to the process's cwd")
        XCTAssertNil(canonical(".claude-accounts/a"), "relative, with no cwd to resolve it against")
        XCTAssertNotEqual(canonical(home.path + "/.claude-accounts/b"), a)
        // Letter case, where the volume ignores it (the default on macOS).
        let shouted = home.path + "/.CLAUDE-ACCOUNTS/A"
        if FileManager.default.fileExists(atPath: shouted) {
            XCTAssertEqual(canonical(shouted), a, "realpath gives the case the disk stores")
        }
        XCTAssertEqual(canonical("/nonexistent/x/../y/"), "/nonexistent/y", "a missing dir is only standardized")
    }

    // MARK: - the probe

    private func probe(_ processes: [ClaudeCodeProcess]) -> ClaudeCodeActivity {
        ClaudeCodeActivity(home: home.path, processes: { processes })
    }

    func testAProcessWithoutTheVariableIsUsingTheDefaultDir() {
        let activity = probe([ClaudeCodeProcess(pid: 41, configDir: nil)])
        XCTAssertEqual(activity.use(configDir: home.path + "/.claude", now: Date()), .process(pid: 41))
        XCTAssertNil(activity.use(configDir: home.path + "/.claude-accounts/a", now: Date()))
    }

    func testAProcessMatchesItsAccountHoweverEitherSpellsTheDir() {
        let activity = probe([ClaudeCodeProcess(pid: 42, configDir: "~/.claude-accounts/a/")])
        XCTAssertEqual(activity.use(configDir: home.path + "/.claude-accounts/a", now: Date()), .process(pid: 42))
        XCTAssertEqual(activity.use(configDir: home.path + "/link-to-a/", now: Date()), .process(pid: 42))
        XCTAssertNil(activity.use(configDir: home.path + "/.claude-accounts/b", now: Date()))
        XCTAssertNil(activity.use(configDir: home.path + "/.claude", now: Date()), "a set variable is not the default dir")

        let relative = probe([ClaudeCodeProcess(pid: 43, configDir: ".claude-accounts/b", cwd: home.path)])
        XCTAssertEqual(relative.use(configDir: home.path + "/.claude-accounts/b", now: Date()), .process(pid: 43))
    }

    private func writeHistory(_ dir: String, at date: Date) throws {
        let path = home.path + "/" + dir + "/history.jsonl"
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    func testAPromptTypedInTheLastFifteenMinutesCounts() throws {
        let now = Date()
        let activity = probe([])
        let a = home.path + "/.claude-accounts/a"
        XCTAssertNil(activity.use(configDir: a, now: now), "no history at all")

        try writeHistory(".claude-accounts/a", at: now.addingTimeInterval(-14 * 60))
        guard case .recentPrompt? = activity.use(configDir: a, now: now) else {
            return XCTFail("a prompt 14 min ago means a session in use")
        }
        try writeHistory(".claude-accounts/a", at: now.addingTimeInterval(-16 * 60))
        XCTAssertNil(activity.use(configDir: a, now: now), "16 min ago is idle")
        XCTAssertEqual(ClaudeCodeActivity.recentPromptWindow, 15 * 60)

        // A clock that jumped: a far-future stamp is not "just now" forever.
        try writeHistory(".claude-accounts/a", at: now.addingTimeInterval(3 * 3600))
        XCTAssertNil(activity.use(configDir: a, now: now))
    }

    /// A history file reached through a symlink is shared with other accounts and says
    /// nothing about this one; transcripts are shared the same way (Grove links each
    /// workspace's `projects/<dir>` into `~/.claude`) and are not a signal at all.
    func testOnlyTheAccountsOwnPromptHistoryCounts() throws {
        let now = Date()
        let b = home.path + "/.claude-accounts/b"
        try writeHistory(".claude", at: now)
        try FileManager.default.createSymbolicLink(atPath: b + "/history.jsonl",
                                                   withDestinationPath: home.path + "/.claude/history.jsonl")
        let transcripts = b + "/projects/-Users-u-work"
        try FileManager.default.createDirectory(atPath: transcripts, withIntermediateDirectories: true)
        for i in 0..<50 { try Data("{}\n".utf8).write(to: URL(fileURLWithPath: transcripts + "/s\(i).jsonl")) }

        XCTAssertNil(probe([]).use(configDir: b, now: now))
        guard case .recentPrompt? = probe([]).use(configDir: home.path + "/.claude", now: now) else {
            return XCTFail("the history's own account does count it")
        }
    }

    /// Several accounts asked about in one cycle cost one walk of the process table.
    func testTheProcessListIsReusedForAMoment() {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let activity = ClaudeCodeActivity(home: home.path, processes: { count.value += 1; return [] })
        let now = Date()
        _ = activity.use(configDir: home.path + "/.claude", now: now)
        _ = activity.use(configDir: home.path + "/.claude-accounts/a", now: now.addingTimeInterval(1))
        XCTAssertEqual(count.value, 1)
        _ = activity.use(configDir: home.path + "/.claude-accounts/a", now: now.addingTimeInterval(3))
        XCTAssertEqual(count.value, 2)
    }

    /// The store asks about every due account at once, one task each. Those arriving
    /// while a walk is under way wait for it rather than each walking the table again.
    func testQuestionsAskedAtTheSameTimeShareOneWalk() {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int { lock.withLock { count } }
            func add() { lock.withLock { count += 1 } }
        }
        let count = Count()
        let activity = ClaudeCodeActivity(home: home.path, processes: {
            Thread.sleep(forTimeInterval: 0.05)
            count.add()
            return []
        })
        let now = Date()
        let dirs = [".claude", ".claude-accounts/a", ".claude-accounts/b"].map { home.path + "/" + $0 }
        DispatchQueue.concurrentPerform(iterations: 9) { i in
            _ = activity.use(configDir: dirs[i % dirs.count], now: now)
        }
        XCTAssertEqual(count.value, 1)
    }

    // MARK: - the real process table

    /// A real process under the name `claude`, with the environment the test chooses:
    /// this test runner itself, started through a symlink called `claude` and running
    /// only `ClaudeCodeStandIn`, which sleeps. (System binaries such as `/bin/sleep`
    /// will not do: the kernel withholds a platform binary's environment.)
    private func spawnStandIn(configDir: String?, cwd: URL? = nil) throws -> Process {
        let runner = try XCTUnwrap(ProcessTable.executablePath(of: getpid()))
        let bin = home.appendingPathComponent("bin")
        let link = bin.appendingPathComponent("claude")
        if !FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: runner))
        }
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir
        env[ClaudeCodeStandIn.sleepVariable] = "30"
        let process = Process()
        process.executableURL = link
        process.arguments = ["-XCTest", "BrowKitTests.ClaudeCodeStandIn/testStandInForAClaudeCodeSession",
                             Bundle(for: ClaudeCodeStandIn.self).bundlePath]
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let cwd { process.currentDirectoryURL = cwd }
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process
    }

    private static func liveTable(excludingChildrenOf parent: pid_t) -> [ClaudeCodeProcess] {
        let runner = ProcessTable.executablePath(of: getpid())
        return ProcessTable.claudeCodeProcesses(excludingChildrenOf: parent, candidate: { $0 == runner })
    }

    func testTheProcessTableReadsALiveProcessesConfigDir() throws {
        let a = home.path + "/.claude-accounts/a"
        let withDir = try spawnStandIn(configDir: a + "/")
        let withoutDir = try spawnStandIn(configDir: nil)

        let arguments = try XCTUnwrap(ProcessTable.arguments(of: withDir.processIdentifier))
        XCTAssertEqual(ClaudeCodeMatcher.basename(arguments.argv.first ?? ""), "claude")
        XCTAssertEqual(arguments.claudeConfigDir, a + "/")
        XCTAssertNil(try XCTUnwrap(ProcessTable.arguments(of: withoutDir.processIdentifier)).claudeConfigDir)
        XCTAssertTrue(ProcessTable.userProcesses().contains { $0.pid == withDir.processIdentifier && $0.ppid == getpid() })

        // -1: nobody's children are left out here, so the test's own children count.
        let table = Self.liveTable(excludingChildrenOf: -1)
        XCTAssertTrue(table.contains(ClaudeCodeProcess(pid: withDir.processIdentifier, configDir: a + "/")))
        XCTAssertTrue(table.contains(ClaudeCodeProcess(pid: withoutDir.processIdentifier, configDir: nil)))

        let activity = ClaudeCodeActivity(home: home.path, processes: { Self.liveTable(excludingChildrenOf: -1) })
        XCTAssertEqual(activity.use(configDir: a, now: Date()), .process(pid: withDir.processIdentifier))
        XCTAssertEqual(activity.use(configDir: home.path + "/.claude", now: Date()),
                       .process(pid: withoutDir.processIdentifier), "no variable: the default dir")
        XCTAssertNil(activity.use(configDir: home.path + "/.claude-accounts/b", now: Date()))
    }

    /// `claude doctor` and `claude -p` that Brow runs itself are its own children, and
    /// they are not "Claude Code using the account".
    func testTheAppsOwnChildrenAreLeftOut() throws {
        let child = try spawnStandIn(configDir: home.path + "/.claude-accounts/a")
        XCTAssertTrue(Self.liveTable(excludingChildrenOf: -1).contains { $0.pid == child.processIdentifier })
        XCTAssertFalse(Self.liveTable(excludingChildrenOf: getpid()).contains { $0.pid == child.processIdentifier })
    }

    /// The real kernel short name stands in for a deleted file: the process is still
    /// found, with its account. (`proc_pidpath` really does fail once the file is
    /// deleted; the test makes it fail for the stand-in rather than delete the runner.)
    func testALiveProcessWithNoPathIsStillFound() throws {
        let a = home.path + "/.claude-accounts/a"
        let child = try spawnStandIn(configDir: a)
        let runner = try XCTUnwrap(ProcessTable.executablePath(of: getpid()))
        let kernelName = String(ClaudeCodeMatcher.basename(runner).utf8.prefix(16))!
        let row = try XCTUnwrap(ProcessTable.userProcesses().first { $0.pid == child.processIdentifier })
        XCTAssertEqual(row.name, kernelName, "the file the process runs, not the link it was started through")

        let table = ProcessTable.claudeCodeProcesses(
            excludingChildrenOf: -1,
            candidate: { $0 == runner || $0 == kernelName },
            pathOf: { $0 == child.processIdentifier ? nil : ProcessTable.executablePath(of: $0) })
        XCTAssertTrue(table.contains(ClaudeCodeProcess(pid: child.processIdentifier, configDir: a)))
    }

    func testARelativeConfigDirIsResolvedAgainstTheProcessesCwd() throws {
        let child = try spawnStandIn(configDir: ".claude-accounts/b", cwd: home)
        let entry = try XCTUnwrap(Self.liveTable(excludingChildrenOf: -1).first { $0.pid == child.processIdentifier })
        XCTAssertNotNil(entry.cwd)
        let activity = ClaudeCodeActivity(home: home.path, processes: { [entry] })
        XCTAssertEqual(activity.use(configDir: home.path + "/.claude-accounts/b", now: Date()),
                       .process(pid: child.processIdentifier))
    }
}

/// The child the live tests above start as `claude`. In a normal run the variable is
/// not set and this returns at once.
final class ClaudeCodeStandIn: XCTestCase {
    static let sleepVariable = "BROW_TEST_STAND_IN_SECONDS"

    func testStandInForAClaudeCodeSession() {
        guard let seconds = ProcessInfo.processInfo.environment[Self.sleepVariable].flatMap(Double.init) else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
