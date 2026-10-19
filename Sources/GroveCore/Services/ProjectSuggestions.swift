// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// A folder Claude Code is running in that no project shows yet, offered for adding.
public struct ProjectSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// What would be added: the repository the sessions run in (a linked worktree counts
    /// as its repository, a submodule as the repository around it), or a folder holding
    /// repositories, which is what a multi-repository project is.
    public let path: String
    public let name: String
    /// The live sessions behind it, by pid, and the folders they run in.
    public let pids: [Int32]
    public let cwds: [String]
    /// The config folders they run as (`~/.claude` spelled out for one with no
    /// `CLAUDE_CONFIG_DIR`), each once, the busiest first: the accounts a row names.
    public let configDirs: [String]

    public init(path: String, pids: [Int32], cwds: [String], configDirs: [String] = []) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.pids = pids
        self.cwds = cwds
        self.configDirs = configDirs
    }
}

public enum ProjectSuggestions {
    /// The folders the `running` sessions work in that are not under any of `covered` (the
    /// projects' folders and their workspaces folders), not the home folder or a system,
    /// temporary or hidden one, and not `dismissed`; leaving out the `automated` pids (an
    /// SDK's runs, background jobs: what their records say). One suggestion per folder, the
    /// folder with the most sessions first. Paths are compared real (`realpath`) on both
    /// sides, as the kernel reports a process's folder.
    public static func suggest(running: [RunningClaude], automated: Set<Int32> = [], covered: [String],
                               dismissed: Set<String> = [], home: String = NSHomeDirectory(),
                               temporaryRoots: [String] = ProjectSuggestions.temporaryRoots) -> [ProjectSuggestion] {
        let home = canonical(home)
        let roots = covered.filter { !$0.isEmpty }.map(canonical)
        let dismissed = Set(dismissed.map(canonical))
        func isCovered(_ path: String) -> Bool { roots.contains { path == $0 || path.hasPrefix($0 + "/") } }

        var byFolder: [String: (pids: [Int32], cwds: [String], dirs: [String])] = [:]
        for session in running where !session.cwd.isEmpty && !automated.contains(session.pid) {
            let cwd = canonical(session.cwd)
            guard !isCovered(cwd), let folder = folder(for: cwd, home: home),
                  !isCovered(folder), !dismissed.contains(folder),
                  !isNoise(folder, home: home, temporaryRoots: temporaryRoots) else { continue }
            var entry = byFolder[folder] ?? ([], [], [])
            entry.pids.append(session.pid)
            if !entry.cwds.contains(cwd) { entry.cwds.append(cwd) }
            entry.dirs.append(session.configDir ?? (home + "/.claude"))
            byFolder[folder] = entry
        }
        return byFolder.map { folder, entry in
            // Each account once, the one most sessions run as first.
            let counts = Dictionary(entry.dirs.map { ($0, 1) }, uniquingKeysWith: +)
            let dirs = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
            return ProjectSuggestion(path: folder, pids: entry.pids.sorted(), cwds: entry.cwds.sorted(), configDirs: dirs)
        }
        .sorted { ($0.pids.count, $1.name) > ($1.pids.count, $0.name) }
    }

    /// The folder a session at `cwd` works on: the nearest repository above it (a linked
    /// worktree's own repository; a submodule's enclosing one), never climbing to the home
    /// folder or above; else `cwd` itself when it holds repositories. nil for a folder
    /// that is neither.
    public static func folder(for cwd: String, home: String) -> String? {
        let start = canonical(cwd)
        var dir = start
        var submodule: String?
        while dir != "/" && dir != home {
            let git = dir + "/.git"
            var info = stat()
            if lstat(git, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFDIR { return dir }
                if (info.st_mode & S_IFMT) == S_IFREG, let target = gitDir(fileAt: git, in: dir) {
                    if let range = target.range(of: "/.git/worktrees/") { return String(target[..<range.lowerBound]) }
                    if target.contains("/.git/modules/") {
                        if submodule == nil { submodule = dir }   // the repository around it, if there is one, wins
                    } else {
                        return dir                                // a repository whose git dir lives elsewhere
                    }
                }
            }
            let parent = (dir as NSString).deletingLastPathComponent
            guard parent != dir else { break }
            dir = parent
        }
        if let submodule { return submodule }
        return holdsRepositories(start) ? start : nil
    }

    /// Where a `.git` file points (`gitdir: …`, relative to the folder it is in).
    static func gitDir(fileAt path: String, in dir: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return target.hasPrefix("/") ? canonical(target) : canonical(dir + "/" + target)
    }

    /// A folder with a repository among its own folders.
    static func holdsRepositories(_ dir: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return names.contains { name in
            guard !name.hasPrefix(".") else { return false }
            var info = stat()
            return lstat(dir + "/" + name + "/.git", &info) == 0
        }
    }

    /// The system's temporary folders, real spellings.
    public static let temporaryRoots: [String] = {
        var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        roots.append(canonical(NSTemporaryDirectory()))
        return roots
    }()

    /// A folder no one means as a project: the root, the home folder, what the system
    /// keeps (`/System`, `/Library`, `/usr`, …), a temporary folder, the home folder's
    /// `Library`, a hidden folder right in the home folder (`~/.claude`, `~/.config`), or
    /// a volume's root.
    public static func isNoise(_ path: String, home: String, temporaryRoots: [String] = ProjectSuggestions.temporaryRoots) -> Bool {
        if path == "/" || path == home { return true }
        let system = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/private/etc",
                      "/cores", "/dev"]
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if system.contains(where: under) || temporaryRoots.contains(where: under) { return true }
        if under(home + "/Library") { return true }
        if path.hasPrefix(home + "/.") { return true }
        let parts = path.split(separator: "/")
        if parts.first == "Volumes", parts.count <= 2 { return true }
        return false
    }

    /// `realpath`, which also turns `/var` and `/tmp` into `/private/…` as the kernel
    /// reports a process's directory; a path that does not exist is only standardized.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (expanded as NSString).standardizingPath
    }
}
