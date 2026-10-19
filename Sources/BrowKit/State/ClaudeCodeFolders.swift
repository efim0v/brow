// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation
import GroveCore

extension ProcessTable {
    /// Every running Claude Code session of this user, as the kernel has it: its pid, its
    /// working directory (the real path, symlinks resolved; it follows the session into a
    /// worktree), the `CLAUDE_CONFIG_DIR` it runs as, the session its command line names
    /// (`--resume`, `--session-id`) and when it started. Read only for processes the
    /// matcher took for Claude Code, so nothing else of other processes is looked at.
    /// Headless runs are left out (`ClaudeCodeMatcher.isHeadless`), and `parent`'s children
    /// as in `claudeCodeProcesses`.
    static func claudeCodeFolders(excludingChildrenOf parent: pid_t = getpid(),
                                  candidate: (String) -> Bool = ClaudeCodeMatcher.mayBeClaudeCode,
                                  pathOf: (pid_t) -> String? = { ProcessTable.executablePath(of: $0) })
        -> [RunningClaude] {
        let me = getpid()
        return userProcesses().compactMap { process in
            guard process.pid != me, process.ppid != parent else { return nil }
            let path = pathOf(process.pid) ?? process.name
            guard !path.isEmpty, candidate(path),
                  let arguments = arguments(of: process.pid),
                  ClaudeCodeMatcher.isClaudeCode(executable: path, arguments: arguments),
                  !ClaudeCodeMatcher.isHeadless(arguments),
                  let cwd = workingDirectory(of: process.pid) else { return nil }
            return RunningClaude(pid: process.pid, cwd: cwd,
                                 configDir: Self.absoluteConfigDir(arguments.claudeConfigDir, cwd: cwd),
                                 sessionId: ClaudeService.sessionId(in: arguments.argv.joined(separator: " ")),
                                 startedAt: SessionRegistry.startDate(of: process.pid))
        }
    }

    /// `CLAUDE_CONFIG_DIR` as a path to compare: `~` expanded, a relative one resolved
    /// against the process's folder (as the CLI does), no trailing slash; nil when unset.
    static func absoluteConfigDir(_ dir: String?, cwd: String) -> String? {
        guard var dir, !dir.isEmpty else { return nil }
        if dir.hasPrefix("~") { dir = (dir as NSString).expandingTildeInPath }
        else if !dir.hasPrefix("/") { dir = cwd + "/" + dir }
        dir = (dir as NSString).standardizingPath
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }
}

extension ClaudeCodeMatcher {
    /// A run with no one at it: `-p`/`--print`, or a stream-json pipe (the Agent SDK).
    /// It comes and goes in seconds, and so would a suggestion made of it.
    static func isHeadless(_ arguments: ProcessArguments) -> Bool {
        let argv = arguments.argv.dropFirst()
        if argv.contains(where: { $0 == "-p" || $0 == "--print" }) { return true }
        if let format = argv.firstIndex(of: "--output-format"), argv.index(after: format) < argv.endIndex,
           argv[argv.index(after: format)] == "stream-json" { return true }
        return argv.contains("--output-format=stream-json")
    }
}
