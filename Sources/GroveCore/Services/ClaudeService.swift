// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import os

public struct AccountIdentity: Sendable, Equatable {
    public let email: String?
    public let organization: String?
    public let tier: String?
    /// FIX I2: the CANONICAL tier namespace `RateLimitModel.tierWeights` keys on
    /// (e.g. `default_claude_max_20x`) — distinct from `tier`'s `userRateLimitTier`
    /// namespace (e.g. `max_20x`). The accounts card surfaces this one.
    public let organizationRateLimitTier: String?

    public init(email: String?, organization: String?, tier: String?,
                organizationRateLimitTier: String? = nil) {
        self.email = email
        self.organization = organization
        self.tier = tier
        self.organizationRateLimitTier = organizationRateLimitTier
    }
}

public struct ClaudeSession: Sendable, Equatable {
    public let id: String
    public let cwd: String
    public let title: String?
    public let lastActivity: Date
    public let accountName: String
    public let gitBranch: String?
    /// Session creation moment (first transcript timestamp); survives resumes.
    public let createdAt: Date?
    /// Human-prompt count ("N turns").
    public let turnCount: Int
    /// Last model the session was driven with (e.g. "claude-opus-4-8").
    public let model: String?
    /// How the transcript ends — the newest prompt, Claude's newest line, the turn — read
    /// from its last 64 KiB (`TranscriptTail`); nil when nothing there says.
    public let preview: SessionPreview?

    public init(id: String, cwd: String, title: String?, lastActivity: Date,
                accountName: String, gitBranch: String?,
                createdAt: Date? = nil, turnCount: Int = 0, model: String? = nil,
                preview: SessionPreview? = nil) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.lastActivity = lastActivity
        self.accountName = accountName
        self.gitBranch = gitBranch
        self.createdAt = createdAt
        self.turnCount = turnCount
        self.model = model
        self.preview = preview
    }
}

/// One running Claude Code session: its own record (`<config dir>/sessions/<pid>.json`),
/// or — for a process that keeps none — what the host's process table says about it.
public struct LiveProcess: Sendable, Equatable {
    public let pid: Int32
    /// The session it runs: the record's, the one its command line resumes, or the
    /// transcript it is writing. Empty while none of them can be told: a session that has
    /// not written a word yet. Such a process stands for no listed session.
    public let sessionId: String
    public let cwd: String
    /// Claude Code's own word for what it does: "busy", "waiting", "idle", "shell". Empty
    /// when it has not said (no record, or a record without one yet): the transcript's
    /// last turn says it then (`SessionState.of`).
    public let status: String
    public let accountName: String
    /// When the process started: the record's `startedAt` (milliseconds since 1970, or an
    /// ISO 8601 string), or the kernel's. nil when unknown.
    public let startedAt: Date?
    /// With "waiting": "permission prompt", "input needed", "sandbox request", …
    public let waitingFor: String?
    /// The session's name in Claude Code's own list (`/rename`, `--name`, or derived).
    public let name: String?
    /// "interactive", "bg", "daemon" or "daemon-worker".
    public let kind: String?
    /// What started it: "cli", an editor, the desktop app, an SDK ("sdk-ts", …).
    public let entrypoint: String?

    public init(pid: Int32, sessionId: String, cwd: String, status: String,
                accountName: String, startedAt: Date? = nil, waitingFor: String? = nil,
                name: String? = nil, kind: String? = nil, entrypoint: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.accountName = accountName
        self.startedAt = startedAt
        self.waitingFor = waitingFor
        self.name = name
        self.kind = kind
        self.entrypoint = entrypoint
    }

    /// A record, as the session wrote it, under the account it was found in.
    public init(record: RegisteredSession, accountName: String) {
        self.init(pid: record.pid, sessionId: record.sessionId, cwd: record.cwd,
                  status: record.status?.rawValue ?? "", accountName: accountName,
                  startedAt: record.startedAt, waitingFor: record.waitingFor, name: record.name,
                  kind: record.kind, entrypoint: record.entrypoint)
    }

    /// Run by a program rather than a person: an SDK, or a background job or daemon.
    /// Suggestions and the "needs you" count leave these out.
    public var isAutomated: Bool {
        (entrypoint?.hasPrefix("sdk") ?? false) || kind == "bg" || kind == "daemon" || kind == "daemon-worker"
    }
}

public extension Array where Element == LiveProcess {
    /// The live process backing a session: the one running it, by its id. A process
    /// whose session could not be told (`sessionId` empty) stands for none: a folder can
    /// hold many sessions, and a plain `claude` running in it runs at most one of them —
    /// marking every session there live is what put "live under a running session" on
    /// sessions nothing ran. `cwd` is kept for the call sites; it decides nothing.
    func liveProcess(forSessionId id: String, cwd: String) -> LiveProcess? {
        guard !id.isEmpty else { return nil }
        return first { $0.sessionId == id }
    }
}

public extension ClaudeService {
    /// Whether a session runs now, under any account: the safety guard of everything that
    /// moves or links a transcript (Share, Resume as). By its id only — a process is
    /// joined to the one session it runs (`allLiveProcesses`). An empty id runs nothing.
    static func isSessionLive(among live: [LiveProcess], sessionId: String) -> Bool {
        !sessionId.isEmpty && live.contains { $0.sessionId == sessionId }
    }
}

/// Reads Claude Code account identity, session transcripts and (Task 9) live processes
/// from a `CLAUDE_CONFIG_DIR`. A class (not a struct) so it can keep an mtime-keyed
/// parse cache: a jsonl file is re-parsed only when its modification date changes.
///
/// `@unchecked Sendable`: `sessionCache` is guarded by `cacheLock` and `processValidator`
/// is set once at construction, so one instance can be kept on AppState (so the parse
/// cache survives across scans — item 2 perf) and used from the background scan.
public final class ClaudeService: @unchecked Sendable {
    private struct ParsedSession {
        let id: String
        let cwd: String
        let title: String?
        let gitBranch: String?
        /// First record's `timestamp` — the session's TRUE creation moment. It
        /// survives resumes: a resumed transcript replays the original messages
        /// with their original timestamps, so the first line still dates day one.
        let createdAt: Date?
        /// Count of human prompts (external `user` records) — how developed the
        /// session is, for the "N turns" meta.
        let turnCount: Int
        /// Last model seen on a message record — the model to resume under.
        let model: String?
    }

    private let cacheLock = NSLock()
    private var sessionCache: [String: (mtime: Date, parsed: ParsedSession?)] = [:]

    public init() {}

    // MARK: - cwd mangling

    /// The longest folder name Claude Code gives a working directory under `projects/`.
    static let maxFolderName = 200

    /// The folder Claude Code keeps a working directory's transcripts in, under
    /// `projects/`, named as Claude Code names it: every UTF-16 unit of the path that is
    /// not an ASCII letter or digit becomes "-" — "/a/b.c" is "-a-b-c", an emoji two
    /// dashes. A name longer than 200 is cut to 200, then "-" and the path's hash in base
    /// 36: Java's `String.hashCode` over the same units, an Int32, without its sign. Lossy:
    /// a transcript's own `cwd` says which folder it really is.
    public static func mangle(_ absolutePath: String) -> String {
        var name = String(decoding: absolutePath.utf16.map { unit -> UInt8 in
            let isAsciiAlnum = (unit >= 0x30 && unit <= 0x39)   // 0-9
                || (unit >= 0x41 && unit <= 0x5A)                // A-Z
                || (unit >= 0x61 && unit <= 0x7A)                // a-z
            return isAsciiAlnum ? UInt8(unit) : UInt8(ascii: "-")
        }, as: UTF8.self)
        guard name.utf8.count > maxFolderName else { return name }
        name = String(name.prefix(maxFolderName))
        var hash: Int32 = 0
        for unit in absolutePath.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return name + "-" + String(abs(Int64(hash)), radix: 36)
    }

    // MARK: - Account identity

    /// Default account (configDir == $HOME/.claude) keeps its identity in $HOME/.claude.json;
    /// custom accounts keep it in <configDir>/.claude.json. nil = not logged in / unreadable.
    /// Never reads tokens (those live in the Keychain — not our business).
    public func identity(account: AccountConfig) -> AccountIdentity? {
        let dir = expandTilde(account.configDir)
        let home = NSHomeDirectory()
        let jsonPath = (dir == home + "/.claude") ? home + "/.claude.json"
                                                  : dir + "/.claude.json"
        return Self.identity(claudeJSONPath: jsonPath)
    }

    /// Path-based variant so the `.claude.json` read can run OFF the main actor and be
    /// cached (the account-based version must not be called from a view body).
    public static func identity(claudeJSONPath: String) -> AccountIdentity? {
        guard
            let data = FileManager.default.contents(atPath: claudeJSONPath),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return AccountIdentity(
            email: oauth["emailAddress"] as? String,
            organization: oauth["organizationName"] as? String,
            tier: oauth["userRateLimitTier"] as? String,
            organizationRateLimitTier: oauth["organizationRateLimitTier"] as? String
        )
    }


    // MARK: - Sessions

    /// Sessions of `account` whose transcript belongs to `cwd`:
    /// `<configDir>/projects/<mangle(cwd)>/*.jsonl`, regular files only (subdirectories
    /// skipped), verified by the first record carrying a "cwd" key (mangling is lossy).
    /// Sorted newest first by file mtime.
    public func sessions(for cwd: String, account: AccountConfig) -> [ClaudeSession] {
        if !account.aliasDirs.isEmpty {
            return Self.dedupe(account.dirVariants.flatMap { sessions(for: cwd, account: $0) })
        }
        let fm = FileManager.default
        let dir = expandTilde(account.configDir) + "/projects/" + ClaudeService.mangle(cwd)
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [ClaudeSession] = []
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            guard
                let attributes = try? fm.attributesOfItem(atPath: path),
                let mtime = attributes[.modificationDate] as? Date
            else { continue }
            guard let parsed = cachedParse(path: path, mtime: mtime),
                  parsed.cwd == cwd else { continue }
            result.append(ClaudeSession(
                id: parsed.id,
                cwd: parsed.cwd,
                title: parsed.title,
                lastActivity: mtime,
                accountName: account.name,
                gitBranch: parsed.gitBranch,
                createdAt: parsed.createdAt,
                turnCount: parsed.turnCount,
                model: parsed.model
            ))
        }
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Recent sessions whose real cwd is under any of `roots` (expanded absolute
    /// paths), across all `accounts`, newest first by file mtime, capped at
    /// `limit`. Deliberately CHEAP (item 2): it lists transcript files, prefilters
    /// directories by the mangled-root prefix, and parses only a bounded buffer of
    /// the newest candidates to confirm the real cwd + read the title — never the
    /// whole transcript corpus, and no git/cmux. Powers the Projects tab's
    /// per-project session previews without a full workspace scan.
    public func recentSessions(underRoots roots: [String], accounts: [AccountConfig],
                               limit: Int) -> [ClaudeSession] {
        let accounts = accounts.flatMap(\.dirVariants)
        guard limit > 0, !roots.isEmpty else { return [] }
        let fm = FileManager.default
        let canonRoots = roots.map { canonicalPath($0) }
        let mangledPrefixes = Set(roots.map { ClaudeService.mangle($0) }
            + canonRoots.map { ClaudeService.mangle($0) })

        struct Candidate { let path: String; let mtime: Date; let account: String }
        var candidates: [Candidate] = []
        for account in accounts {
            let projectsDir = expandTilde(account.configDir) + "/projects"
            guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { continue }
            for dir in dirs where mangledPrefixes.contains(where: { dir.hasPrefix($0) }) {
                let dirPath = projectsDir + "/" + dir
                guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let path = dirPath + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    candidates.append(Candidate(path: path, mtime: mtime, account: account.name))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        var rows: [ClaudeSession] = []
        var seen = Set<String>()
        let budget = limit * 4 + 8   // bounded: only the newest candidates get parsed
        for cand in candidates.prefix(budget) {
            guard let parsed = cachedParse(path: cand.path, mtime: cand.mtime) else { continue }
            let canonCwd = canonicalPath(parsed.cwd)
            let underRoot = canonRoots.contains { canonCwd == $0 || canonCwd.hasPrefix($0 + "/") }
            guard underRoot else { continue }   // mangled-prefix false positive -> drop
            guard seen.insert(parsed.cwd + "\u{0}" + parsed.id).inserted else { continue }
            rows.append(ClaudeSession(id: parsed.id, cwd: parsed.cwd, title: parsed.title,
                                      lastActivity: cand.mtime, accountName: cand.account,
                                      gitBranch: parsed.gitBranch,
                                      createdAt: parsed.createdAt, turnCount: parsed.turnCount,
                                      model: parsed.model))
            if rows.count >= limit { break }
        }
        return rows
    }

    /// All recent sessions across ALL accounts with NO project/root filter — the
    /// disk-wide scanner that makes every recently-used Claude session discoverable
    /// regardless of whether it was opened through grove.
    ///
    /// Unlike `recentSessions(underRoots:accounts:limit:)`, this method:
    ///   - Does NOT filter by project root — every `projects/<dir>` is scanned.
    ///   - Applies a recency cap: only transcripts whose mtime >= now - sinceDays*86400
    ///     are considered (bounds the scan to the recent window).
    ///   - Still sorts newest-first, deduplicates by (cwd, sessionId), and caps at
    ///     `limit` exactly like the sibling method.
    ///   - Uses the same `cachedParse` mtime cache to bound parse work.
    ///
    /// The injected `now` keeps the method pure/deterministic — no `Date()` inside.
    public func allRecentSessions(accounts: [AccountConfig], limit: Int,
                                  sinceDays: Int, now: Date) -> [ClaudeSession] {
        let accounts = accounts.flatMap(\.dirVariants)
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(sinceDays) * 86400)

        struct Candidate { let path: String; let mtime: Date; let account: String }
        var candidates: [Candidate] = []
        for account in accounts {
            let projectsDir = expandTilde(account.configDir) + "/projects"
            guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { continue }
            for dir in dirs {
                let dirPath = projectsDir + "/" + dir
                guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let path = dirPath + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    // Recency cap: skip transcripts older than the cutoff.
                    guard mtime >= cutoff else { continue }
                    candidates.append(Candidate(path: path, mtime: mtime, account: account.name))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        var rows: [ClaudeSession] = []
        var seen = Set<String>()
        let budget = limit * 4 + 8
        for cand in candidates.prefix(budget) {
            guard let parsed = cachedParse(path: cand.path, mtime: cand.mtime) else { continue }
            guard seen.insert(parsed.cwd + "\u{0}" + parsed.id).inserted else { continue }
            rows.append(ClaudeSession(id: parsed.id, cwd: parsed.cwd, title: parsed.title,
                                      lastActivity: cand.mtime, accountName: cand.account,
                                      gitBranch: parsed.gitBranch,
                                      createdAt: parsed.createdAt, turnCount: parsed.turnCount,
                                      model: parsed.model))
            if rows.count >= limit { break }
        }
        return rows
    }

    private func cachedParse(path: String, mtime: Date) -> ParsedSession? {
        cacheLock.lock()
        if let entry = sessionCache[path], entry.mtime == mtime {
            let parsed = entry.parsed
            cacheLock.unlock()
            return parsed
        }
        cacheLock.unlock()
        let parsed = ClaudeService.parseSessionFile(path: path)
        cacheLock.lock()
        sessionCache[path] = (mtime: mtime, parsed: parsed)
        cacheLock.unlock()
        return parsed
    }

    private static func parseSessionFile(path: String) -> ParsedSession? {
        guard
            let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        var fileCwd: String?
        var sessionId: String?
        var gitBranch: String?
        var sawFirstUserRecord = false
        var aiTitle: String?
        var fallbackTitle: String?
        var createdAt: Date?        // first record carrying a timestamp
        var turnCount = 0           // external user prompts
        var model: String?          // last message.model seen

        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any]
            else { continue }                       // unparseable line: skip, keep going
            if fileCwd == nil, let recordCwd = object["cwd"] as? String {
                fileCwd = recordCwd                 // first record carrying "cwd" wins
            }
            // First timestamp wins → creation moment. Cheap: same loop already runs.
            if createdAt == nil, let ts = object["timestamp"] as? String {
                createdAt = gitISODate(ts)
            }
            // Last model wins → the model the session was last driven with.
            if let message = object["message"] as? [String: Any],
               let m = message["model"] as? String, !m.isEmpty {
                model = m
            }
            let type = object["type"] as? String
            if type == "user" {
                if sessionId == nil { sessionId = object["sessionId"] as? String }
                if !sawFirstUserRecord {
                    sawFirstUserRecord = true
                    gitBranch = object["gitBranch"] as? String
                }
                if (object["userType"] as? String) == "external" {
                    turnCount += 1                  // one human prompt
                    if fallbackTitle == nil,
                       let message = object["message"] as? [String: Any],
                       let textContent = extractText(message["content"]),
                       !textContent.isEmpty {
                        fallbackTitle = String(textContent.prefix(80))
                    }
                }
            } else if type == "ai-title" {
                if let title = object["aiTitle"] as? String { aiTitle = title }  // LAST one wins
            }
        }

        guard let id = sessionId, let cwd = fileCwd else { return nil }
        return ParsedSession(id: id, cwd: cwd, title: aiTitle ?? fallbackTitle, gitBranch: gitBranch,
                             createdAt: createdAt, turnCount: turnCount, model: model)
    }

    /// User message content is either a plain string or an array of content blocks;
    /// only "text" blocks contribute to the fallback title.
    private static func extractText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return nil
    }

    // MARK: - Live sessions

    /// Test seam: whether a record's process still runs and is the one that wrote it. nil:
    /// the kernel says (`SessionRegistry.isLive`: the pid runs, and started when the record
    /// says). Tests make a fixture's made-up pids count.
    internal var processValidator: ((Int32) -> Bool)? {
        get { cacheLock.withLock { validator } }
        set { cacheLock.withLock { validator = newValue } }
    }
    private var validator: ((Int32) -> Bool)?

    /// The host's look at the Claude Code processes that run (Brow reads them from the
    /// kernel, with libproc). It finds the sessions that keep no record of their own. nil
    /// — the command-line tool, a test — leaves the records alone to say what runs.
    /// GroveCore never runs `ps` or `lsof`, nor looks at another process itself.
    public var runningProcesses: (@Sendable () -> [RunningClaude])? {
        get { cacheLock.withLock { processSource } }
        set { cacheLock.withLock { processSource = newValue } }
    }
    private var processSource: (@Sendable () -> [RunningClaude])?

    /// The live sessions `account` has records of (`<configDir>/sessions/<pid>.json`), each
    /// checked against the kernel: a record whose process is gone, or is another process
    /// now, is left out. Sorted by pid.
    public func liveProcesses(account: AccountConfig) -> [LiveProcess] {
        if !account.aliasDirs.isEmpty {
            return account.dirVariants.flatMap { liveProcesses(account: $0) }
        }
        let validator = processValidator
        let records = SessionRegistry.sessions(configDir: expandTilde(account.configDir),
                                               isLive: validator.map { check in { check($0.pid) } } ?? SessionRegistry.isLive)
        return records.map { LiveProcess(record: $0, accountName: account.name) }
    }

    /// THE live sessions across `accounts`, one per process: every record (the session's
    /// own words for what it does), then each process the host found that keeps none,
    /// joined to the one session it runs (`RunningClaude.sessionId`, else its transcript:
    /// `attribute`). Every screen reads liveness from here, so none can disagree.
    public func allLiveProcesses(accounts: [AccountConfig]) -> [LiveProcess] {
        var result: [LiveProcess] = []
        var pids = Set<Int32>()
        for record in accounts.flatMap({ liveProcesses(account: $0) }) where pids.insert(record.pid).inserted {
            result.append(record)
        }
        let others = (runningProcesses?() ?? []).filter { !pids.contains($0.pid) }
        if !others.isEmpty {
            let claimed = Set(result.map(\.sessionId).filter { !$0.isEmpty })
            result += Self.attribute(others, accounts: accounts, claimed: claimed, home: NSHomeDirectory())
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// Processes that keep no record of their own, each joined to exactly one session:
    /// the one its command line names (`--resume`, `--session-id`), else the newest
    /// transcript in its folder written since it started that no other session holds —
    /// the newest process first, so two in one folder take two transcripts. One that
    /// has written nothing yet stays without a session: it runs none of those listed.
    /// Never every session in the folder. The account is the one whose folder the
    /// process's `CLAUDE_CONFIG_DIR` names (unset: `~/.claude` under `home`).
    static func attribute(_ processes: [RunningClaude], accounts: [AccountConfig], claimed: Set<String>,
                          home: String) -> [LiveProcess] {
        var taken = claimed
        var result: [LiveProcess] = []
        let fm = FileManager.default
        let newestFirst = processes.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        for process in newestFirst {
            let dir = normalizedConfigDir(process.configDir ?? home + "/.claude")
            let account = accounts.first { $0.allConfigDirs.map(normalizedConfigDir).contains(dir) }
            var sessionId = process.sessionId ?? ""
            if sessionId.isEmpty {
                // Claude Code may spell the folder as the kernel does (/private/var/…) or
                // without the /private: look under both.
                let spellings = Set([process.cwd, canonicalPath(process.cwd)]).map { dir + "/projects/" + mangle($0) }
                let since = (process.startedAt ?? .distantPast).addingTimeInterval(-2)
                var best: (id: String, mtime: Date)?
                for folder in spellings {
                    for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                        let id = String(name.dropLast(".jsonl".count))
                        guard !taken.contains(id),
                              let mtime = (try? fm.attributesOfItem(atPath: folder + "/" + name))?[.modificationDate] as? Date,
                              mtime >= since, mtime > (best?.mtime ?? .distantPast) else { continue }
                        best = (id, mtime)
                    }
                }
                sessionId = best?.id ?? ""
            }
            if !sessionId.isEmpty { taken.insert(sessionId) }
            result.append(LiveProcess(pid: process.pid, sessionId: sessionId, cwd: process.cwd, status: "",
                                      accountName: account?.name ?? "", startedAt: process.startedAt))
        }
        return result
    }

    /// `~/x/` → `/Users/me/x`: one spelling of a config folder to compare.
    static func normalizedConfigDir(_ dir: String) -> String {
        var path = expandTilde(dir)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The controlling terminal (`/dev/ttys025`) of the live process running `sessionId`,
    /// for focusing its Terminal.app tab; nil when none runs it or it has no terminal.
    /// From the kernel: no `ps`.
    public func ttyForSession(_ sessionId: String, accounts: [AccountConfig]) -> String? {
        guard let process = allLiveProcesses(accounts: accounts).first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return SessionRegistry.terminal(of: process.pid)
    }

    /// Extracts the session id from a `claude --resume <uuid>` or `claude --session-id
    /// <uuid>` command line (cmux launches with `--session-id`). nil for processes
    /// carrying neither flag (a truly bare new session can't be mapped to an id) and
    /// for the cmux wrapper scripts (whose path mentions claude but lacks either flag).
    public static func sessionId(in command: String) -> String? {
        // Accept `--resume <id>`/`--resume=<id>` AND `--session-id <id>`/`--session-id=<id>`
        // (cmux launches Claude with `--session-id`). The equals form would otherwise
        // leave the session unmatchable (read as fresh).
        guard let range = command.range(of: "--resume ") ?? command.range(of: "--resume=")
            ?? command.range(of: "--session-id ") ?? command.range(of: "--session-id=")
        else { return nil }
        let token = command[range.upperBound...].prefix { !$0.isWhitespace }
        let id = String(token)
        return id.count == 36 && id.allSatisfy { $0.isHexDigit || $0 == "-" } ? id : nil
    }

    /// Public seam so callers (AppState's concurrency guard) can inject a liveness
    /// predicate without reaching the internal `processValidator`. Returns a
    /// configured instance, with this one's host processes.
    public func withProcessValidator(_ validator: @escaping (Int32) -> Bool) -> ClaudeService {
        let copy = ClaudeService()
        copy.processValidator = validator
        copy.runningProcesses = runningProcesses
        return copy
    }

    // MARK: - Launch commands

    /// Effort levels accepted by `claude --effort` — the full set per `claude
    /// --help` (low, medium, high, xhigh, max). The single source of truth for the
    /// effort pickers, so xhigh/max can't be missed.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Candidate install locations for the claude CLI, checked in order.
    /// Injectable for tests.
    static var claudeCandidatePaths: [String] = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// Absolute path to the claude binary when one of the known install
    /// locations exists, else bare "claude" (PATH lookup). Resolving an
    /// absolute path makes launch commands immune to shells whose init files
    /// never add ~/.local/bin to PATH (fresh cmux workspaces, GUI-spawned
    /// shells) — the recurring "claude not found in PATH" failure.
    public static func claudeExecutable() -> String {
        let fm = FileManager.default
        for path in claudeCandidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }

    /// Shell command string for cmux `--command`. Default account (expanded configDir
    /// == $HOME/.claude) needs no env prefix; custom accounts get CLAUDE_CONFIG_DIR.
    /// Optional `model`/`effort` append `--model <id>` / `--effort <level>` (spec §C.6,
    /// applied at launch only — a running process can't be re-modeled, NG1).
    /// `skipPermissions` appends `--dangerously-skip-permissions` (per-project, for
    /// fully-autonomous agents). The binary path, config dir, resume id, model and
    /// effort are single-quote shell-quoted.
    /// One session per id: the same transcript can sit in two dirs of one account
    /// (a copy, a shared-store move); the newer activity wins.
    static func dedupe(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        var byId: [String: ClaudeSession] = [:]
        var order: [String] = []
        for session in sessions {
            if let existing = byId[session.id] {
                if session.lastActivity > existing.lastActivity { byId[session.id] = session }
            } else {
                byId[session.id] = session
                order.append(session.id)
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// A config dir Claude Code has never run interactively in — the folders
    /// `claude auth login` leaves behind — carries an `oauthAccount` and nothing
    /// else, so the first `claude` in it opens the onboarding wizard as if nobody
    /// were signed in. Stamps `hasCompletedOnboarding` (and the theme, copied from
    /// the default account) into `<configDir>/.claude.json`, touching nothing else.
    /// Never for the default dir itself. Returns whether the file was written.
    ///
    /// The merge goes through `HotJSONFile`: under Claude Code's lock, through a
    /// symlink, keeping the file's mode, and no write for a dir already onboarded. A
    /// `.claude.json` that exists but doesn't parse (caught mid-write, or a bad hand
    /// edit) is left alone and logged, and this returns false: rewriting it with these
    /// two keys would drop the sign-in, the MCP servers and every project's trust.
    @discardableResult
    public static func ensureOnboarded(configDir: String, home: String = NSHomeDirectory()) -> Bool {
        let dir = expandTilde(configDir)
        guard dir != home + "/.claude" else { return false }
        let path = dir + "/.claude.json"
        let fm = FileManager.default
        do {
            let outcome = try HotJSONFile.update(path: path) { existing in
                guard existing["hasCompletedOnboarding"] as? Bool != true else { return existing }
                var object = existing
                object["hasCompletedOnboarding"] = true
                if object["theme"] == nil,
                   let canonical = fm.contents(atPath: home + "/.claude.json"),
                   let canonicalObject = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any],
                   let theme = canonicalObject["theme"] {
                    object["theme"] = theme
                }
                return object
            }
            return outcome == .written
        } catch {
            log.error("onboarding not marked done: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let log = Logger(subsystem: "dev.artemefimov.brow", category: "ClaudeService")

    /// `browser`: the executable `claude auth login` should open (`$BROWSER`) — Brow's
    /// per-account router, so a re-login from a Grove-launched session lands in
    /// that account's own browser profile instead of the default browser.
    /// `claude`: the binary to run — the host's Path to claude — or nil for the
    /// engine's own guesses (`claudeExecutable()`). `environment`: what the command starts
    /// with instead of the variables built here — the host's own prefix for the account,
    /// already quoted (Brow's `env -u CLAUDE_CONFIG_DIR …` for the default account).
    public static func launchCommand(account: AccountConfig, resume sessionId: String? = nil,
                                     model: String? = nil, effort: String? = nil,
                                     skipPermissions: Bool = false, browser: String? = nil,
                                     claude path: String? = nil, environment: String? = nil) -> String {
        let dir = expandTilde(account.configDir)
        let isDefaultAccount = dir == NSHomeDirectory() + "/.claude"
        let chosen = path?.trimmingCharacters(in: .whitespaces)
        let claude = shellQuote(chosen.flatMap { $0.isEmpty ? nil : $0 } ?? claudeExecutable())
        var env: [String] = []
        if let environment, !environment.trimmingCharacters(in: .whitespaces).isEmpty {
            env.append(environment)
        } else {
            if !isDefaultAccount { env.append("CLAUDE_CONFIG_DIR=\(shellQuote(dir))") }
            if let browser, !browser.isEmpty { env.append("BROWSER=\(shellQuote(browser))") }
        }
        var command = env.isEmpty ? claude : env.joined(separator: " ") + " " + claude
        // Guard on non-empty so an empty value (e.g. a hand-edited config with
        // model: "") is treated like nil instead of emitting `--model ''`.
        if let sessionId, !sessionId.isEmpty { command += " --resume \(shellQuote(sessionId))" }
        if let model, !model.isEmpty { command += " --model \(shellQuote(model))" }
        if let effort, !effort.isEmpty { command += " --effort \(shellQuote(effort))" }
        // A literal flag (no value) — append last so it reads naturally in logs.
        if skipPermissions { command += " --dangerously-skip-permissions" }
        return command
    }
}
