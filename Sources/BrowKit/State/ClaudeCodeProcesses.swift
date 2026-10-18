// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// One running Claude Code process, as far as Brow needs to know it: the account it
/// runs as. Nothing else is kept from its environment.
public struct ClaudeCodeProcess: Sendable, Equatable {
    public let pid: Int32
    /// `CLAUDE_CONFIG_DIR` exactly as the process has it; nil when it is unset, which
    /// makes the CLI use `~/.claude`.
    public let configDir: String?
    /// The process's working directory, looked up only when `configDir` is relative.
    public let cwd: String?

    public init(pid: Int32, configDir: String?, cwd: String? = nil) {
        self.pid = pid
        self.configDir = configDir
        self.cwd = cwd
    }
}

/// A process's `KERN_PROCARGS2` area, parsed: the path it was started with, its
/// arguments, and ONE variable of its environment.
struct ProcessArguments: Sendable, Equatable {
    let executablePath: String
    let argv: [String]
    /// `CLAUDE_CONFIG_DIR`; nil when unset. The rest of the environment is skipped
    /// over, never kept: it can hold anything, API keys included.
    let claudeConfigDir: String?

    private static let configDirKey = Array("CLAUDE_CONFIG_DIR=".utf8)

    /// Layout: `argc` (Int32), the path the process was started with, NUL padding,
    /// `argc` NUL-terminated arguments, then the environment as NUL-terminated
    /// `KEY=value` strings up to an empty one.
    ///
    /// NUL runs before the environment are skipped rather than taken as its end. A node
    /// process that sets `process.title` has libuv write the title over the argument
    /// area and zero the rest of it: counting `argc` strings then stops in the middle of
    /// the zeroes, and stopping at the first empty string there would read the process
    /// as "variable unset", that is as `~/.claude`.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> ProcessArguments? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        guard argc >= 0 else { return nil }
        var index = MemoryLayout<Int32>.size

        func nextString() -> (start: Int, end: Int)? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let end = index
            index += 1                                  // the NUL
            return (start, end)
        }
        func text(_ range: (start: Int, end: Int)) -> String {
            String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range.start..<range.end]), as: UTF8.self)
        }
        func skipNULs() { while index < bytes.count, bytes[index] == 0 { index += 1 } }

        guard let exec = nextString() else { return nil }
        skipNULs()
        var argv: [String] = []
        while argv.count < argc, let arg = nextString() { argv.append(text(arg)) }
        skipNULs()
        var configDir: String?
        while configDir == nil, let entry = nextString(), entry.end > entry.start {
            let length = entry.end - entry.start
            guard length >= configDirKey.count,
                  bytes[entry.start..<(entry.start + configDirKey.count)].elementsEqual(configDirKey) else { continue }
            configDir = text((entry.start + configDirKey.count, entry.end))
        }
        return ProcessArguments(executablePath: text(exec), argv: argv, claudeConfigDir: configDir)
    }
}

/// Which processes are Claude Code. Two steps, so the arguments and environment of
/// unrelated processes are never read at all: a cheap filter on the executable's path
/// as the kernel has it (a process cannot rewrite it), then a decision on the
/// arguments of what passed.
enum ClaudeCodeMatcher {
    /// JavaScript runtimes an npm install of Claude Code runs under.
    static let runtimes: Set<String> = ["node", "bun", "deno"]
    /// npm packages whose script, run under a runtime, is a Claude Code session: the CLI
    /// itself, and older Agent SDK releases, which start their bundled `cli.js` with
    /// `node` and sign in the same way. Newer SDK releases ship a binary called `claude`.
    static let packages = ["/@anthropic-ai/claude-code/", "/@anthropic-ai/claude-agent-sdk/"]

    /// The native installer names its binary after its version
    /// (`~/.local/share/claude/versions/2.1.299`, started through `~/.local/bin/claude`),
    /// so the name alone is not enough; Homebrew and the editor extensions ship a file
    /// called `claude`; an npm install runs under a runtime.
    ///
    /// `path` can also be the kernel's short name alone, with no slash: that is all
    /// there is once the file has been deleted under a running process (an update or
    /// `brew upgrade` removing the old version while a session still runs it). The
    /// native installer's binary then shows up as its bare version number.
    static func mayBeClaudeCode(executable path: String) -> Bool {
        let name = basename(path)
        if name == "claude" || runtimes.contains(name)
            || path.contains("/claude/") || path.contains("claude-code") { return true }
        return !path.contains("/") && isVersionNumber(name)
    }

    static func isClaudeCode(executable path: String, arguments: ProcessArguments) -> Bool {
        // The bridge Claude in Chrome starts from the browser. It runs no session and
        // lives as long as Chrome does, so counting it would hold `~/.claude` forever.
        if arguments.argv.contains("--chrome-native-host") { return false }
        if basename(path) == "claude" || basename(arguments.executablePath) == "claude" { return true }
        if let first = arguments.argv.first, basename(first) == "claude" { return true }
        if path.contains("/claude/versions/") || arguments.executablePath.contains("/claude/versions/") { return true }
        // `node /opt/homebrew/bin/claude …` or `node …/@anthropic-ai/claude-code/cli.js …`,
        // with the runtime's own flags possibly in between.
        guard runtimes.contains(basename(path)) else { return false }
        guard let script = arguments.argv.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return false }
        return basename(script) == "claude" || packages.contains { script.contains($0) }
    }

    /// `2.1.299`: digits in at least two dot-separated groups.
    static func isVersionNumber(_ name: String) -> Bool {
        let groups = name.split(separator: ".", omittingEmptySubsequences: false)
        return groups.count >= 2 && groups.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}

/// The current user's processes, read with `sysctl` and `libproc`: no subprocess, no
/// extra permission. Only processes of the same user are visible this way, which is
/// exactly the set that can share a Claude Code login with Brow.
enum ProcessTable {
    /// Live Claude Code processes. `parent`'s children are left out: those are the
    /// `claude doctor` and `claude -p` runs Brow started itself.
    ///
    /// A process whose executable file is gone has no path any more (`proc_pidpath`
    /// fails), but it is still running and still holds its account's tokens; it is
    /// judged by the kernel's short name for it instead of being skipped.
    static func claudeCodeProcesses(excludingChildrenOf parent: pid_t = getpid(),
                                    candidate: (String) -> Bool = ClaudeCodeMatcher.mayBeClaudeCode,
                                    pathOf: (pid_t) -> String? = { ProcessTable.executablePath(of: $0) })
        -> [ClaudeCodeProcess] {
        let me = getpid()
        return userProcesses().compactMap { process in
            guard process.pid != me, process.ppid != parent else { return nil }
            let path = pathOf(process.pid) ?? process.name
            guard !path.isEmpty, candidate(path),
                  let arguments = arguments(of: process.pid),
                  ClaudeCodeMatcher.isClaudeCode(executable: path, arguments: arguments) else { return nil }
            let dir = arguments.claudeConfigDir
            let relative = dir.map { !$0.isEmpty && !$0.hasPrefix("/") && !$0.hasPrefix("~") } ?? false
            return ClaudeCodeProcess(pid: process.pid, configDir: dir,
                                     cwd: relative ? workingDirectory(of: process.pid) : nil)
        }
    }

    /// Every live (not zombie) process of this user, with the kernel's short name for
    /// its executable (`p_comm`: the file name it was started from, at most 16 bytes,
    /// which the process cannot change).
    static func userProcesses() -> [(pid: pid_t, ppid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            // Room for processes started between the two calls.
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, u_int(mib.count), &table, &size, nil, 0) == 0 {
                return table.prefix(size / MemoryLayout<kinfo_proc>.stride)
                    .filter { $0.kp_proc.p_pid > 0 && Int32($0.kp_proc.p_stat) != SZOMB }
                    .map { entry in
                        let name = withUnsafeBytes(of: entry.kp_proc.p_comm) {
                            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                        }
                        return (entry.kp_proc.p_pid, entry.kp_eproc.e_ppid, name)
                    }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// The executable's path as the kernel resolved it.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The process's arguments and its `CLAUDE_CONFIG_DIR`. The kernel hands over the
    /// whole environment with them; the buffer is zeroed before it is let go.
    static func arguments(of pid: pid_t) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        size += 4096                                    // the area can grow between the calls
        var buffer = [UInt8](repeating: 0, count: size)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: $0.prefix(size))) }
    }

    /// For a relative `CLAUDE_CONFIG_DIR`, which the CLI resolves against its own cwd.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
