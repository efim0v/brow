// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// Why Brow thinks Claude Code is using an account right now.
public enum ClaudeCodeUse: Sendable, Equatable {
    /// A running `claude` process has this account's config dir.
    case process(pid: Int32)
    /// A prompt was typed in this account (`history.jsonl`) within
    /// `ClaudeCodeActivity.recentPromptWindow`.
    case recentPrompt(at: Date)

    var logText: String {
        switch self {
        case .process(let pid): return "claude process \(pid)"
        case .recentPrompt(let at): return "prompt at \(at)"
        }
    }
}

/// Answers "is Claude Code using this config dir right now?". A protocol so the store
/// can be tested without real processes.
public protocol ClaudeCodeActivityProbing: Sendable {
    func use(configDir: String, now: Date) -> ClaudeCodeUse?
}

/// Before the keeper runs the CLI for a due token, the store asks this, to give a
/// session the first go (see `LimitsStore.holderRule`): a session at work renews its
/// own token with its next request inside the token's last five minutes. That is a
/// courtesy, not a safeguard. Claude Code takes a lock in the config dir around every
/// refresh and re-reads the token under it (seen in 2.1.290–2.1.302), so a `claude
/// doctor` and a session no longer race each other into a dead refresh token.
///
/// Two signals, either one is enough:
///
/// - A live Claude Code process whose `CLAUDE_CONFIG_DIR` is this account (unset means
///   `~/.claude`), however long it has been quiet. A quiet one renews nothing, which is
///   why it holds the keeper off only briefly. The CLI's own helpers, such as the
///   `grep` its Bash tool runs, are not sessions (`ClaudeCodeMatcher.helpers`).
/// - A prompt typed in this account in the last 15 minutes: `history.jsonl`, which
///   Claude Code appends to on every prompt, belongs to one config dir and is not
///   shared. It covers a session the process list cannot see.
///
/// Session transcripts are deliberately NOT a signal. Grove links each workspace's
/// `projects/<dir>` across accounts into `~/.claude`, so a transcript's age cannot be
/// pinned on one account without reading it, and counting them would mark every linked
/// account (and `~/.claude` always) busy while any one of them works. They are not
/// written steadily either: a long run of subagents can leave the main transcript
/// untouched for longer than any useful window.
///
/// Reads process info and one file's modification time. Never a file's contents, never
/// the Keychain, and no subprocess.
public final class ClaudeCodeActivity: ClaudeCodeActivityProbing, @unchecked Sendable {
    public static let recentPromptWindow: TimeInterval = 15 * 60
    /// The process list is reused for this long, so a cycle that asks about several
    /// accounts at once walks the list once.
    static let processListReuse: TimeInterval = 2

    private let home: String
    private let listProcesses: @Sendable () -> [ClaudeCodeProcess]
    private let lock = NSLock()
    private var lastList: (at: Date, processes: [ClaudeCodeProcess])?

    /// The live process table.
    public convenience init(home: String = NSHomeDirectory()) {
        self.init(home: home, processes: { ProcessTable.claudeCodeProcesses() })
    }

    /// A process list of the caller's choosing (tests).
    init(home: String, processes: @escaping @Sendable () -> [ClaudeCodeProcess]) {
        self.home = home
        self.listProcesses = processes
    }

    public func use(configDir: String, now: Date) -> ClaudeCodeUse? {
        guard let dir = Self.canonicalConfigDir(configDir, cwd: nil, home: home) else { return nil }
        for process in processes(now: now)
        where Self.canonicalConfigDir(process.configDir, cwd: process.cwd, home: home) == dir {
            return .process(pid: process.pid)
        }
        if let at = Self.lastPrompt(configDir: dir), abs(now.timeIntervalSince(at)) < Self.recentPromptWindow {
            return .recentPrompt(at: at)
        }
        return nil
    }

    /// The walk happens under the lock: the store asks about every due account at once
    /// (one task per account), and the ones that arrive while a walk is running wait for
    /// it (about 25 ms) and reuse its list instead of each walking the table again.
    private func processes(now: Date) -> [ClaudeCodeProcess] {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastList, abs(now.timeIntervalSince(last.at)) < Self.processListReuse {
            return last.processes
        }
        let fresh = listProcesses()
        lastList = (now, fresh)
        return fresh
    }

    /// The config dir a process (or an account) means, in one comparable spelling.
    /// Unset or empty is `~/.claude`; `~` is expanded; a relative path is taken from the
    /// process's working directory (nil when that is unknown); then `realpath`, which
    /// resolves symlinks, `.`/`..`, doubled and trailing slashes and the letter case the
    /// disk stores. A path that does not exist is only standardized.
    ///
    /// A process with `CLAUDE_CONFIG_DIR` set to `~/.claude` itself uses a different
    /// Keychain item than one with it unset (see GroveCore's `isDefaultClaudeDir`), so it
    /// cannot race the default login. It still counts: both see the same files, and
    /// leaving a token alone for a while is the cheap mistake.
    static func canonicalConfigDir(_ raw: String?, cwd: String?, home: String) -> String? {
        var path = raw.flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath     // ~otheruser/…
        }
        if !path.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            path = cwd + "/" + path
        }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// When the account's prompt history was last written, if it is a plain file of the
    /// account's own. A symlinked one is shared with other accounts and says nothing
    /// about this one.
    static func lastPrompt(configDir: String) -> Date? {
        let path = configDir + "/history.jsonl"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return attributes[.modificationDate] as? Date
    }
}
