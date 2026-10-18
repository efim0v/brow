// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation
import GroveCore

extension ProcessTable {
    /// Where every running Claude Code session of this user works: its pid and the
    /// working directory the kernel has for it (the real path, symlinks resolved; it
    /// follows the session into a worktree). Read only for processes the matcher took
    /// for Claude Code, so nothing else of other processes is looked at. Headless runs
    /// are left out (`ClaudeCodeMatcher.isHeadless`). `parent`'s children are left out
    /// as in `claudeCodeProcesses`.
    static func claudeCodeFolders(excludingChildrenOf parent: pid_t = getpid(),
                                  candidate: (String) -> Bool = ClaudeCodeMatcher.mayBeClaudeCode,
                                  pathOf: (pid_t) -> String? = { ProcessTable.executablePath(of: $0) })
        -> [ProjectSuggestions.Live] {
        let me = getpid()
        return userProcesses().compactMap { process in
            guard process.pid != me, process.ppid != parent else { return nil }
            let path = pathOf(process.pid) ?? process.name
            guard !path.isEmpty, candidate(path),
                  let arguments = arguments(of: process.pid),
                  ClaudeCodeMatcher.isClaudeCode(executable: path, arguments: arguments),
                  !ClaudeCodeMatcher.isHeadless(arguments),
                  let cwd = workingDirectory(of: process.pid) else { return nil }
            return ProjectSuggestions.Live(pid: process.pid, cwd: cwd)
        }
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
