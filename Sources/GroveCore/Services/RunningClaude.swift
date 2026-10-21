// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// A Claude Code process that runs now, as the host's look at the kernel's process table
/// found it. GroveCore never reads another process itself: the host does (Brow, with
/// libproc, `ProcessTable.claudeCodeFolders`) and hands the answer in through a closure
/// (`ClaudeService.runningProcesses`, `AppState.runningClaude`). Headless runs (`-p`,
/// the SDK's stream-json) are never in it.
public struct RunningClaude: Sendable, Equatable {
    public let pid: Int32
    /// Its working directory: the real path, as the kernel has it (`/private/var/…`).
    public let cwd: String
    /// `CLAUDE_CONFIG_DIR` as the process has it, made absolute; nil when unset, which is
    /// `~/.claude`.
    public let configDir: String?
    /// The session its command line names: `--resume <id>` or `--session-id <id>`.
    public let sessionId: String?
    /// When the process started, from the kernel.
    public let startedAt: Date?

    public init(pid: Int32, cwd: String, configDir: String? = nil, sessionId: String? = nil, startedAt: Date? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.configDir = configDir
        self.sessionId = sessionId
        self.startedAt = startedAt
    }
}
