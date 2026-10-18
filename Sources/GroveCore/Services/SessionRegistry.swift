// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation

/// One running interactive Claude Code session, as the session itself records it in
/// `<config dir>/sessions/<pid>.json`.
///
/// Claude Code writes the file when an interactive session starts (not for `-p`, a
/// teammate, or a session that keeps nothing on disk), keeps `status` and `cwd` current
/// while it runs, and deletes it on exit. A crash can leave one behind, and pids get
/// reused, so a record counts only while its pid runs and started when the record says
/// (`procStart`, the same `ps -o lstart=` text Claude Code checks).
public struct RegisteredSession: Sendable, Equatable {
    /// What the session is doing, in Claude Code's words.
    public enum Status: String, Sendable, Equatable {
        /// A turn is under way: Claude is thinking, writing, or running tools or subagents.
        case busy
        /// Stopped on the user: see `waitingFor`.
        case waiting
        /// The turn is over; the prompt is the user's.
        case idle
        /// The turn is over, and a shell command it started still runs in the background.
        case shell
    }

    public let pid: Int32
    public let sessionId: String
    /// The session's working directory, kept current (a session can move into a worktree).
    public let cwd: String
    public let status: Status?
    /// With `waiting`: "permission prompt", "input needed", "sandbox request",
    /// "worker request", "goal proposal" or "dialog open".
    public let waitingFor: String?
    /// "interactive", "bg", "daemon" or "daemon-worker".
    public let kind: String?
    /// What started it: "cli", an editor extension, the desktop app, an SDK…
    public let entrypoint: String?
    /// The session's name in Claude Code's own list.
    public let name: String?
    public let startedAt: Date?
    public let statusUpdatedAt: Date?
    /// The process's start time as `ps -o lstart=` prints it in UTC, for telling a reused pid.
    public let procStart: String?
    /// The config dir the record was found in: the account the session runs as.
    public let configDir: String

    public init(pid: Int32, sessionId: String, cwd: String, status: Status?, waitingFor: String? = nil,
                kind: String? = nil, entrypoint: String? = nil, name: String? = nil, startedAt: Date? = nil,
                statusUpdatedAt: Date? = nil, procStart: String? = nil, configDir: String) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waitingFor = waitingFor
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.procStart = procStart
        self.configDir = configDir
    }
}

public enum SessionRegistry {
    /// The live sessions recorded in `configDir`. Files that don't parse, and records
    /// whose process is gone or is another process now, are left out. One small file per
    /// running session, no subprocess.
    public static func sessions(configDir: String,
                                isLive: (RegisteredSession) -> Bool = SessionRegistry.isLive) -> [RegisteredSession] {
        let dir = (configDir as NSString).expandingTildeInPath + "/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let record = parse(data, configDir: configDir), isLive(record) else { return nil }
            return record
        }.sorted { $0.pid < $1.pid }
    }

    /// One record. `startedAt` and `statusUpdatedAt` are milliseconds since 1970 in the
    /// versions that write `status` (an ISO 8601 string is read too).
    static func parse(_ data: Data, configDir: String) -> RegisteredSession? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pidNumber = object["pid"] as? Int, let pid = Int32(exactly: pidNumber), pid > 0,
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String else { return nil }
        return RegisteredSession(
            pid: pid, sessionId: sessionId, cwd: cwd,
            status: (object["status"] as? String).flatMap(RegisteredSession.Status.init(rawValue:)),
            waitingFor: object["waitingFor"] as? String,
            kind: object["kind"] as? String,
            entrypoint: object["entrypoint"] as? String,
            name: object["name"] as? String,
            startedAt: date(object["startedAt"]),
            statusUpdatedAt: date(object["statusUpdatedAt"]),
            procStart: object["procStart"] as? String,
            configDir: configDir)
    }

    static func date(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let text = value as? String { return parseISODate(text) }
        return nil
    }

    /// The pid runs, and, when the record says when its process started, it is that
    /// process and not a later one that got the same pid.
    public static func isLive(_ record: RegisteredSession) -> Bool {
        guard kill(record.pid, 0) == 0 || errno == EPERM else { return false }
        guard let recorded = record.procStart?.trimmingCharacters(in: .whitespaces), !recorded.isEmpty else { return true }
        guard let started = startTime(of: record.pid) else { return false }
        return recorded == started
    }

    /// When `pid` started, as `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` prints it
    /// ("Sun Oct 19 08:05:09 2026"), from the kernel and without running `ps`.
    public static func startTime(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var seconds = time_t(info.pbi_start_tvsec)
        var t = tm()
        guard gmtime_r(&seconds, &t) != nil, (0..<7).contains(t.tm_wday), (0..<12).contains(t.tm_mon) else { return nil }
        // `%a %b %e %H:%M:%S %Y` in the C locale, spelled out so no locale can change it.
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "%@ %@ %2d %02d:%02d:%02d %d", days[Int(t.tm_wday)], months[Int(t.tm_mon)],
                      t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, t.tm_year + 1900)
    }
}
