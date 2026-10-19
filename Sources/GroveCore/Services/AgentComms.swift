// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CryptoKit
import Foundation

// Who messages whom among the Claude Code agents on this Mac: sessions messaging each
// other (a Unix socket each, 2.1.224 and later; another Mac's through Anthropic's
// servers), a session and its subagents, an agent team and its lead.
//
// Read-only by construction, from what Claude Code already writes in each account's
// config folder: the session records (`sessions/<pid>.json`), the transcripts — the
// sender's `SendMessage` call and its result, the receiver's envelope — the subagents'
// sidecars and an agent team's config and mailboxes. It never connects to a session's
// socket (that would make it a participant), never opens an inbox key
// (`sessions/<pid>.<hash>.key`), takes no lock, writes nothing and runs nothing. Of a
// message it keeps the first line or the sender's summary, at most 140 characters, in
// memory only.
//
// The formats are Claude Code's own (checked against 2.1.302) and may change between
// versions: everything is read leniently, and what is not understood is skipped.

/// One account's config folder, as the reader is given it.
public struct AgentAccount: Sendable, Equatable, Hashable {
    public let name: String
    public let configDir: String

    public init(name: String, configDir: String) {
        self.name = name
        self.configDir = configDir
    }
}

/// A node of the picture: a session, a subagent or teammate of one, or a session elsewhere.
public struct AgentNode: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case session, subagent, teammate, remote
    }

    /// `session:<account>:<id>`, `agent:<account>:<session>:<agent id>`,
    /// `teammate:<account>:<team>:<name>`, `remote:<id>`; and for a peer the reader cannot
    /// name yet, `uds:<socket>` or `name:<name>`.
    public let id: String
    public var name: String
    public let kind: Kind
    /// The session a subagent or teammate belongs to.
    public var parent: String?
    public var account: String?
    /// The session's record, while it runs.
    public var live: LiveProcess?
    /// What a subagent was asked to do.
    public var detail: String?
    public var cwd: String?
    /// A subagent that has finished.
    public var finished = false

    public init(id: String, name: String, kind: Kind, parent: String? = nil, account: String? = nil,
                live: LiveProcess? = nil, detail: String? = nil, cwd: String? = nil, finished: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parent = parent
        self.account = account
        self.live = live
        self.detail = detail
        self.cwd = cwd
        self.finished = finished
    }
}

/// One message from one agent to another.
public struct AgentMessage: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// Between two sessions.
        case crossSession
        /// Between a session and one of its subagents.
        case subagent
        /// Between teammates of an agent team.
        case teammate
        /// An agent team's own bookkeeping (idle, shutdown, plan approval): not a message
        /// anyone wrote.
        case teammateProtocol
    }

    /// Where it got to. Joined from both ends, the furthest one wins.
    public enum Delivery: String, Sendable, Equatable {
        case failed, sending, sent, held, refused, denied, expired, delivered

        var rank: Int {
            switch self {
            case .failed: return 0
            case .sending: return 1
            case .sent: return 2
            case .held: return 3
            case .refused, .denied, .expired: return 4
            case .delivered: return 5
            }
        }
    }

    public let id: String
    public let from: String
    public let to: String
    public let kind: Kind
    public var delivery: Delivery
    /// When it was sent (the sender's line), else when it arrived.
    public var at: Date?
    /// When it arrived: the receiver's line.
    public var arrivedAt: Date?
    /// Its first line: at most 140 characters, never more.
    public var text: String
    /// The sender's own summary of it, as short.
    public var summary: String?
    public var msgId: String?

    public init(id: String, from: String, to: String, kind: Kind, delivery: Delivery, at: Date?,
                arrivedAt: Date? = nil, text: String, summary: String? = nil, msgId: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.delivery = delivery
        self.at = at
        self.arrivedAt = arrivedAt
        self.text = text
        self.summary = summary
        self.msgId = msgId
    }
}

/// A session starting a subagent or a teammate.
public struct AgentSpawn: Sendable, Equatable {
    public let parent: String
    public let child: String
    public let kind: AgentNode.Kind
    public let at: Date?
    /// What it was started for, in a line.
    public let description: String?
}

/// Who talks to whom, as read: the nodes, the messages joined from both ends, newest
/// first, and the spawns.
public struct AgentGraph: Sendable, Equatable {
    public var nodes: [String: AgentNode]
    public var messages: [AgentMessage]
    public var spawns: [AgentSpawn]

    public init(nodes: [String: AgentNode] = [:], messages: [AgentMessage] = [], spawns: [AgentSpawn] = []) {
        self.nodes = nodes
        self.messages = messages
        self.spawns = spawns
    }
}

/// The reader. Not thread-safe: one queue drives it (the observer's).
public final class AgentCommsReader {
    /// Of a message, this much is kept.
    public static let maxText = 140
    /// What a cold start reads of each transcript: its end only.
    public static let coldTail = 512 << 10

    public private(set) var accounts: [AgentAccount]
    /// Every file this reader opened, in order — tests check an inbox key is never among
    /// them. Kept only when `recordsReads` is on.
    var readsLog: [String] = []
    var recordsReads = false
    /// Tests watch the lines a follower takes, by their uuid.
    var onLineTaken: ((String) -> Void)?

    public init(accounts: [AgentAccount]) {
        self.accounts = accounts
    }

    // MARK: - What is known about the sessions

    struct Record {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let name: String?
        let kind: String?
        let socket: String?
        let live: LiveProcess
    }

    struct SessionKey: Hashable { let account: String; let session: String }
    struct AgentKey: Hashable { let account: String; let session: String; let agent: String }
    struct TeamKey: Hashable { let account: String; let team: String }

    struct AgentMeta {
        let name: String?
        let taskKind: String?
        let teamName: String?
        let description: String?
        let finished: Bool
    }

    struct TeamConfig {
        let leadSessionId: String?
        let members: [String]
    }

    private var records: [String: [Record]] = [:]
    private var bySocket: [String: SessionKey] = [:]
    private var byPid: [String: [Int32: String]] = [:]
    private var agentMeta: [AgentKey: AgentMeta] = [:]
    private var agentNames: [SessionKey: [String: String]] = [:]
    private var teams: [TeamKey: TeamConfig] = [:]
    private var teamOfSession: [SessionKey: String] = [:]
    private var sessionCwds: [SessionKey: String] = [:]
    /// Names the envelopes give peers this reader cannot name otherwise.
    private var peerNames: [String: String] = [:]

    /// Reads the session records, the agent teams and the subagents' sidecars: what names
    /// the nodes. Cheap; read again on every change to `sessions/` or `teams/`.
    public func loadStatic() {
        records = [:]
        bySocket = [:]
        byPid = [:]
        teams = [:]
        teamOfSession = [:]
        for account in accounts {
            let recs = readRegistry(account)
            records[account.name] = recs
            for record in recs {
                byPid[account.name, default: [:]][record.pid] = record.sessionId
                if let socket = record.socket { bySocket[socket] = SessionKey(account: account.name, session: record.sessionId) }
                if let cwd = record.cwd { sessionCwds[SessionKey(account: account.name, session: record.sessionId)] = cwd }
            }
            readTeams(account)
        }
    }

    private func readRegistry(_ account: AgentAccount) -> [Record] {
        let folder = account.configDir + "/sessions"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return names.compactMap { name in
            // Only `<pid>.json`: the inbox keys beside them are never opened.
            guard SessionRegistry.isRecordName(name), let data = read(folder + "/" + name),
                  let record = SessionRegistry.parse(data, configDir: account.configDir),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let socket = (object["messagingSocketPath"] as? String).flatMap { $0.isEmpty ? nil : Self.canonicalSocket($0) }
            return Record(pid: record.pid, sessionId: record.sessionId, cwd: record.cwd, name: record.name,
                          kind: record.kind, socket: socket, live: LiveProcess(record: record, accountName: account.name))
        }
    }

    private func readTeams(_ account: AgentAccount) {
        let dir = account.configDir + "/teams"
        for team in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            guard let data = read(dir + "/" + team + "/config.json"),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let lead = config["leadSessionId"] as? String
            let members = (config["members"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            teams[TeamKey(account: account.name, team: team)] = TeamConfig(leadSessionId: lead, members: members)
            if let lead { teamOfSession[SessionKey(account: account.name, session: lead)] = team }
        }
    }

    /// A subagent's sidecar, `agent-<id>.meta.json` beside its transcript.
    private func readSidecar(_ path: String, account: String, session: String) {
        let file = (path as NSString).lastPathComponent
        guard file.hasPrefix("agent-"), file.hasSuffix(".meta.json"), let data = read(path),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let agent = String(file.dropFirst("agent-".count).dropLast(".meta.json".count))
        let entry = AgentMeta(name: meta["name"] as? String, taskKind: meta["taskKind"] as? String,
                              teamName: meta["teamName"] as? String,
                              description: (meta["description"] as? String).flatMap(Self.line),
                              finished: meta["finished"] as? Bool ?? false)
        agentMeta[AgentKey(account: account, session: session, agent: agent)] = entry
        if let name = entry.name { agentNames[SessionKey(account: account, session: session), default: [:]][name] = agent }
    }

    // MARK: - Reading the transcripts

    /// The state kept for one file followed: where it was read to, and the end of a line
    /// still being written.
    struct Follower {
        var device: UInt64
        var inode: UInt64
        var offset: Int64
        var rest = Data()
        /// The lines already taken, by their `uuid`: a file rewritten from the start is read
        /// again without a message counted twice.
        var seen = Set<String>()
    }

    private var followers: [String: Follower] = [:]

    /// A transcript as the reader places it: which account and session it belongs to, and,
    /// for a subagent's, which agent.
    struct Place {
        let account: String
        let session: String
        let agent: String?
    }

    /// Where `path` sits: `<config>/projects/<folder>/<session>.jsonl`, or
    /// `<config>/projects/<folder>/<session>/subagents/[…/]agent-<id>.jsonl`.
    func place(of path: String) -> Place? {
        for account in accounts {
            let projects = account.configDir + "/projects/"
            guard path.hasPrefix(projects) else { continue }
            let parts = path.dropFirst(projects.count).split(separator: "/").map(String.init)
            guard parts.count >= 2, let last = parts.last, last.hasSuffix(".jsonl") else { return nil }
            if parts.count == 2 { return Place(account: account.name, session: String(last.dropLast(6)), agent: nil) }
            guard parts.count >= 4, parts[2] == "subagents", last.hasPrefix("agent-") else { return nil }
            return Place(account: account.name, session: parts[1], agent: String(last.dropFirst(6).dropLast(6)))
        }
        return nil
    }

    /// Every transcript of the accounts written since `since`, newest last, read from its
    /// end (`coldTail`) and followed from there; the sidecars of their subagents too.
    public func readRecent(since: Date) {
        var files: [(path: String, mtime: Date)] = []
        let fm = FileManager.default
        for account in accounts {
            let projects = account.configDir + "/projects"
            for folder in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let dir = projects + "/" + folder
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    let path = dir + "/" + name
                    if name.hasSuffix(".jsonl") {
                        if let mtime = Self.modified(path), mtime >= since { files.append((path, mtime)) }
                    } else if let enumerator = fm.enumerator(atPath: path + "/subagents") {
                        let session = name
                        for case let sub as String in enumerator {
                            let subPath = path + "/subagents/" + sub
                            if sub.hasSuffix(".meta.json") {
                                readSidecar(subPath, account: account.name, session: session)
                            } else if sub.hasSuffix(".jsonl"), let mtime = Self.modified(subPath), mtime >= since {
                                files.append((subPath, mtime))
                            }
                        }
                    }
                }
            }
        }
        // The main transcripts first: a spawn's result names its agent before the agent's
        // own file is read. (The names are joined late anyway; this keeps it tidy.)
        for file in files.sorted(by: { ($0.path.contains("/subagents/") ? 1 : 0, $0.mtime) < ($1.path.contains("/subagents/") ? 1 : 0, $1.mtime) }) {
            follow(file.path, fromTail: Self.coldTail)
        }
        readMailboxes()
    }

    /// A file that changed: a transcript read on from where it was left, a sidecar, a
    /// record, a team's config or mailbox.
    public func changed(_ path: String) {
        if path.hasSuffix(".meta.json") {
            if let place = place(of: path.replacingOccurrences(of: ".meta.json", with: ".jsonl")) {
                readSidecar(path, account: place.account, session: place.session)
            }
        } else if path.hasSuffix(".jsonl") {
            follow(path, fromTail: nil)
        } else if path.contains("/teams/") {
            loadStatic()
            readMailboxes()
        } else if path.contains("/sessions/") {
            loadStatic()
        }
    }

    /// Reads `path` on from where it was left, whole lines only; a replaced or shrunk file
    /// from the start. A new file: from `fromTail` bytes before its end (nil: its start).
    func follow(_ path: String, fromTail tail: Int?) {
        guard let place = place(of: path) else { return }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            followers[path] = nil
            return
        }
        let device = UInt64(info.st_dev), inode = UInt64(info.st_ino), size = Int64(info.st_size)
        var follower = followers[path]
            ?? Follower(device: device, inode: inode, offset: tail.map { max(0, size - Int64($0)) } ?? 0)
        var startsMidLine = follower.offset > 0 && followers[path] == nil
        if follower.device != device || follower.inode != inode || size < follower.offset {
            // Replaced (a rewrite swaps the file) or shrunk: from the start, the lines
            // already taken skipped by their uuid.
            follower = Follower(device: device, inode: inode, offset: 0, rest: Data(), seen: follower.seen)
            startsMidLine = false
        }
        guard size > follower.offset, let chunk = read(path, from: follower.offset) else {
            followers[path] = follower
            return
        }
        follower.offset += Int64(chunk.count)
        var data = follower.rest + chunk
        if startsMidLine, let newline = data.firstIndex(of: 0x0A) {
            data = data[(newline + 1)...]                   // the first piece of a tail is half a line
        }
        var lineStart = data.startIndex
        var lines: [Data] = []
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart { lines.append(Data(data[lineStart..<newline])) }
            lineStart = data.index(after: newline)
        }
        follower.rest = Data(data[lineStart...])            // an unfinished last line waits
        for line in lines {
            guard mayMatter(line, path: path),
                  let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let key = (row["uuid"] as? String) ?? Self.digest(line)
            guard follower.seen.insert(key).inserted else { continue }
            onLineTaken?(key)
            take(row, place: place, path: path)
        }
        if follower.seen.count > 20_000 { follower.seen.removeAll(keepingCapacity: true) }
        followers[path] = follower
    }

    private static let needles: [Data] = [
        #""SendMessage""#, #""Agent""#, #""Task""#, "-message", #""kind":"peer""#, #""kind":"coordinator""#,
        "[Cross-session",
    ].map { Data($0.utf8) }

    /// Whether the line, as written (compact JSON), can carry a message: it names a send
    /// or a spawn, holds an envelope or a peer's origin, or is the result of a call this
    /// reader waits on. The rest — nearly all of a transcript — is never parsed.
    private func mayMatter(_ line: Data, path: String) -> Bool {
        if Self.needles.contains(where: { line.range(of: $0) != nil }) { return true }
        let waiting = pendingSends.keys.filter { $0.path == path }.map(\.toolUse)
            + pendingSpawns.keys.filter { $0.path == path }.map(\.toolUse)
        return waiting.contains { line.range(of: Data($0.utf8)) != nil }
    }

    // MARK: - One line

    struct CallKey: Hashable { let path: String; let toolUse: String }

    struct Send {
        let from: Endpoint
        let to: String
        let summary: String?
        let text: String
        let bodyKey: String
        let at: Date?
        let account: String
        let session: String
    }

    struct SpawnCall {
        let parent: Endpoint
        let name: String?
        let promptKey: String
        let description: String?
        let at: Date?
        let account: String
        let session: String
    }

    /// An end of a message, as far as the line it was read from tells: resolved to a node
    /// only when the picture is drawn, with everything read by then.
    indirect enum Endpoint: Hashable {
        case session(account: String, session: String)
        case agent(account: String, session: String, agent: String)
        case agentNamed(account: String, session: String, name: String)
        case teammate(account: String, team: String, name: String)
        case teammateOf(account: String, lead: String, name: String)
        case socket(path: String, pid: Int32?, account: String)
        case remote(String)
        case target(account: String, session: String, to: String, pin: String?, routing: String?)
        case unknown(String)
    }

    struct RawMessage {
        let from: Endpoint
        let to: Endpoint
        let kind: AgentMessage.Kind
        let delivery: AgentMessage.Delivery
        let at: Date?
        let text: String
        let summary: String?
        let bodyKey: String
        let msgId: String?
        let fromSender: Bool
    }

    struct RawSpawn {
        let parent: Endpoint
        let child: Endpoint
        let kind: AgentNode.Kind
        let at: Date?
        let description: String?
        let promptKey: String
    }

    struct Notice {
        let account: String
        let session: String
        let at: Date?
        let delivery: AgentMessage.Delivery
        let msgId: String?
    }

    private var pendingSends: [CallKey: Send] = [:]
    private var pendingSpawns: [CallKey: SpawnCall] = [:]
    private var rawMessages: [RawMessage] = []
    private var rawSpawns: [RawSpawn] = []
    private var notices: [Notice] = []

    private func take(_ row: [String: Any], place: Place, path: String) {
        let me: Endpoint = place.agent.map { .agent(account: place.account, session: place.session, agent: $0) }
            ?? .session(account: place.account, session: place.session)
        let at = (row["timestamp"] as? String).flatMap(parseISODate)
        if let cwd = row["cwd"] as? String, place.agent == nil {
            sessionCwds[SessionKey(account: place.account, session: place.session)] = cwd
        }
        switch row["type"] as? String {
        case "assistant":
            let blocks = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let key = CallKey(path: path, toolUse: id)
                switch block["name"] as? String {
                case "SendMessage":
                    guard let to = input["to"] as? String else { continue }
                    let body = Self.bodyText(input["message"])
                    pendingSends[key] = Send(from: me, to: to, summary: (input["summary"] as? String).flatMap(Self.line),
                                             text: Self.shown(body),
                                             bodyKey: Self.bodyKey(body), at: at, account: place.account,
                                             session: place.session)
                case "Agent", "Task":
                    pendingSpawns[key] = SpawnCall(parent: me, name: input["name"] as? String,
                                                   promptKey: Self.bodyKey((input["prompt"] as? String) ?? ""),
                                                   description: (input["description"] as? String).flatMap(Self.line),
                                                   at: at, account: place.account, session: place.session)
                default:
                    break
                }
            }
        case "user":
            let message = row["message"] as? [String: Any]
            let content = message?["content"]
            if let blocks = content as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String {
                        result(CallKey(path: path, toolUse: id), data: row["toolUseResult"])
                    }
                }
            }
            let origin = row["origin"] as? [String: Any] ?? [:]
            let text = TranscriptTail.Message.texts(content).joined(separator: "\n\n")
            delivered(text, origin: origin, me: me, place: place, at: at)
            if place.agent != nil, origin["kind"] as? String == "coordinator" {
                rawMessages.append(RawMessage(from: .session(account: place.account, session: place.session), to: me,
                                              kind: .subagent, delivery: .delivered, at: at, text: Self.shown(text),
                                              summary: nil, bodyKey: Self.bodyKey(text), msgId: nil, fromSender: false))
            }
            if row["isMeta"] as? Bool == true, text.hasPrefix("[Cross-session delivery notice]") {
                notice(text, place: place, at: at)
            }
        case "attachment":
            let attachment = row["attachment"] as? [String: Any] ?? [:]
            guard attachment["type"] as? String == "queued_command" else { return }
            let text = TranscriptTail.Message.texts(attachment["prompt"]).joined(separator: "\n\n")
            delivered(text, origin: attachment["origin"] as? [String: Any] ?? [:], me: me, place: place, at: at)
        case "queue-operation":
            guard row["operation"] as? String == "enqueue", let text = row["content"] as? String else { return }
            delivered(text, origin: [:], me: me, place: place, at: at)
        default:
            break
        }
    }

    /// The envelopes in a text that reached `me`.
    private func delivered(_ text: String, origin: [String: Any], me: Endpoint, place: Place, at: Date?) {
        for envelope in AgentEnvelope.all(in: text) {
            let shown = Self.shown(envelope.body)
            let summary = envelope.attributes["summary"].flatMap(Self.line)
            let key = Self.bodyKey(envelope.body)
            switch envelope.kind {
            case .crossSession:
                let address = envelope.attributes["from"] ?? (origin["from"] as? String) ?? ""
                let from = endpoint(forAddress: address, pid: (origin["verifiedPeerPid"] as? Int).flatMap { Int32(exactly: $0) },
                                    account: place.account)
                if let name = envelope.senderName ?? (origin["name"] as? String) { peerNames[address] = name }
                rawMessages.append(RawMessage(from: from, to: me, kind: .crossSession, delivery: .delivered, at: at,
                                              text: shown, summary: summary, bodyKey: key, msgId: origin["msg_id"] as? String,
                                              fromSender: false))
            case .agent:
                let who = envelope.attributes["from"] ?? ""
                rawMessages.append(RawMessage(from: local(who, account: place.account, session: place.session), to: me,
                                              kind: .subagent, delivery: .delivered, at: at, text: shown, summary: summary,
                                              bodyKey: key, msgId: origin["msg_id"] as? String, fromSender: false))
            case .teammate:
                let sender = envelope.attributes["teammate_id"] ?? ""
                rawMessages.append(RawMessage(from: .teammateOf(account: place.account, lead: place.session, name: sender),
                                              to: me, kind: Self.isProtocol(envelope.body) ? .teammateProtocol : .teammate,
                                              delivery: .delivered, at: at, text: shown, summary: summary, bodyKey: key,
                                              msgId: nil, fromSender: false))
            }
        }
    }

    /// The result of a call this reader waits on: a send's outcome, a spawn's agent.
    private func result(_ key: CallKey, data: Any?) {
        let data = data as? [String: Any]
        if let spawn = pendingSpawns.removeValue(forKey: key) {
            guard let data else { return }
            if data["status"] as? String == "teammate_spawned", let name = data["name"] as? String {
                let team = (data["team_name"] as? String) ?? teamOfSession[SessionKey(account: spawn.account, session: spawn.session)]
                let child: Endpoint = team.map { .teammate(account: spawn.account, team: $0, name: name) }
                    ?? .teammateOf(account: spawn.account, lead: spawn.session, name: name)
                rawSpawns.append(RawSpawn(parent: spawn.parent, child: child, kind: .teammate, at: spawn.at,
                                          description: spawn.description, promptKey: spawn.promptKey))
                if let agent = data["agent_id"] as? String {
                    agentNames[SessionKey(account: spawn.account, session: spawn.session), default: [:]][name] = agent
                }
            } else if let agent = data["agentId"] as? String {
                rawSpawns.append(RawSpawn(parent: spawn.parent, child: .agent(account: spawn.account, session: spawn.session, agent: agent),
                                          kind: .subagent, at: spawn.at, description: spawn.description,
                                          promptKey: spawn.promptKey))
                if let name = spawn.name {
                    agentNames[SessionKey(account: spawn.account, session: spawn.session), default: [:]][name] = agent
                }
            }
            return
        }
        guard let send = pendingSends.removeValue(forKey: key) else { return }
        let ok = data?["success"] as? Bool == true
        let pin = (data?["pin"] as? [String: Any])?["id"] as? String
        let routing = (data?["routing"] as? [String: Any])?["target"] as? String
        rawMessages.append(RawMessage(from: send.from,
                                      to: .target(account: send.account, session: send.session, to: send.to, pin: pin, routing: routing),
                                      kind: .crossSession, delivery: ok ? .sent : .failed, at: send.at, text: send.text,
                                      summary: send.summary, bodyKey: send.bodyKey, msgId: data?["msg_id"] as? String,
                                      fromSender: true))
    }

    /// `[Cross-session delivery notice]`: what became of a message this session sent.
    private func notice(_ text: String, place: Place, at: Date?) {
        let lower = text.lowercased()
        let delivery: AgentMessage.Delivery?
        if lower.contains("approved and released") || lower.contains("released") { delivery = .sent }
        else if lower.contains("not approved") || lower.contains("expir") { delivery = .expired }
        else if lower.contains("denied") { delivery = .denied }
        else if lower.contains("refused") { delivery = .refused }
        else if lower.contains("held") { delivery = .held }
        else { delivery = nil }
        guard let delivery else { return }
        let msgId = Self.uuid.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range, in: text) }.map { String(text[$0]) }
        notices.append(Notice(account: place.account, session: place.session, at: at, delivery: delivery, msgId: msgId))
    }

    private static let uuid = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    // MARK: - Mailboxes

    struct InboxEntryKey: Hashable { let file: String; let key: String }
    private var mailbox: [InboxEntryKey: RawMessage] = [:]

    /// Every team's mailboxes, read whole (they are small): a message's state is whether its
    /// recipient has read it.
    public func readMailboxes() {
        var next: [InboxEntryKey: RawMessage] = [:]
        for (key, _) in teams {
            guard let account = accounts.first(where: { $0.name == key.account }) else { continue }
            let dir = account.configDir + "/teams/" + key.team + "/inboxes"
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where file.hasSuffix(".json") {
                guard let data = read(dir + "/" + file),
                      let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
                let recipient = String(file.dropLast(5))
                for entry in entries {
                    guard let from = entry["from"] as? String, let text = entry["text"] as? String else { continue }
                    let stamp = entry["timestamp"] as? String
                    let id = (entry["msg_id"] as? String) ?? [from, stamp ?? "", text].joined(separator: "|")
                    next[InboxEntryKey(file: dir + "/" + file, key: Self.digest(Data(id.utf8)))] = RawMessage(
                        from: .teammate(account: key.account, team: key.team, name: from),
                        to: .teammate(account: key.account, team: key.team, name: recipient),
                        kind: Self.isProtocol(text) ? .teammateProtocol : .teammate,
                        delivery: entry["read"] as? Bool == true ? .delivered : .sent,
                        at: stamp.flatMap(parseISODate), text: Self.shown(text),
                        summary: (entry["summary"] as? String).flatMap(Self.line),
                        bodyKey: Self.bodyKey(text), msgId: entry["msg_id"] as? String, fromSender: false)
                }
            }
        }
        mailbox = next
    }

    /// Forgets what happened before `cutoff`: the picture keeps the last hour, and nothing of
    /// a message outlives it.
    public func prune(before cutoff: Date) {
        rawMessages.removeAll { ($0.at ?? .distantFuture) < cutoff }
        rawSpawns.removeAll { ($0.at ?? .distantFuture) < cutoff }
        notices.removeAll { ($0.at ?? .distantFuture) < cutoff }
        pendingSends = pendingSends.filter { ($0.value.at ?? .distantFuture) >= cutoff }
        pendingSpawns = pendingSpawns.filter { ($0.value.at ?? .distantFuture) >= cutoff }
    }

    /// Stops following files that are gone, and changes the accounts read.
    public func setAccounts(_ next: [AgentAccount]) {
        guard next != accounts else { return }
        accounts = next
        let kept = Set(next.map(\.name))
        followers = followers.filter { place(of: $0.key).map { kept.contains($0.account) } ?? false }
        loadStatic()
    }

    // MARK: - The picture

    /// Who talks to whom: every message joined from both ends — by `msg_id` when both carry
    /// it, else by sender, receiver and body within two minutes — newest first, the
    /// furthest delivery winning; a spawn prompt is the spawn, not a message.
    public func graph() -> AgentGraph {
        var nodes: [String: AgentNode] = [:]
        // The sessions that run, by their records.
        for account in accounts {
            for record in records[account.name] ?? [] {
                let id = Self.sessionNode(account.name, record.sessionId)
                nodes[id] = AgentNode(id: id, name: record.name ?? record.cwd.map { ($0 as NSString).lastPathComponent } ?? String(record.sessionId.prefix(8)),
                                      kind: .session, account: account.name, live: record.live, cwd: record.cwd)
            }
        }
        var spawnPrompts: [String: String] = [:]
        var spawns: [AgentSpawn] = []
        for spawn in rawSpawns {
            let parent = resolve(spawn.parent), child = resolve(spawn.child)
            spawnPrompts[child] = spawn.promptKey
            spawns.append(AgentSpawn(parent: parent, child: child, kind: spawn.kind, at: spawn.at, description: spawn.description))
        }
        var merged: [AgentMessage] = []
        var bodyKeys: [String] = []
        let pending = pendingSends.values.map {
            RawMessage(from: $0.from, to: .target(account: $0.account, session: $0.session, to: $0.to, pin: nil, routing: nil),
                       kind: .crossSession, delivery: .sending, at: $0.at, text: $0.text, summary: $0.summary,
                       bodyKey: $0.bodyKey, msgId: nil, fromSender: true)
        }
        let all = (rawMessages + mailbox.values.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) } + pending)
        for raw in all {
            let from = resolve(raw.from)
            let resolvedTo = resolve(raw.to)
            var kind = raw.kind
            if case .target = raw.to { kind = targetKind(raw.to, resolved: resolvedTo) }
            // The prompt a subagent or a teammate was started with is the spawn, not a message.
            if kind == .subagent || kind == .teammate, spawnPrompts[resolvedTo] == raw.bodyKey { continue }
            let index = merged.indices.first { i in
                let m = merged[i]
                if let id = raw.msgId, let other = m.msgId { return id == other }
                guard m.from == from, m.to == resolvedTo, m.kind == kind, bodyKeys[i] == raw.bodyKey else { return false }
                guard let a = m.at ?? m.arrivedAt, let b = raw.at else { return true }
                return abs(a.timeIntervalSince(b)) <= 120
            }
            if let index {
                var m = merged[index]
                if raw.delivery.rank > m.delivery.rank { m.delivery = raw.delivery }
                m.msgId = m.msgId ?? raw.msgId
                m.summary = m.summary ?? raw.summary
                if m.text.isEmpty { m.text = raw.text }
                if raw.fromSender {
                    m.at = raw.at ?? m.at
                } else if raw.delivery == .delivered {
                    m.arrivedAt = m.arrivedAt.map { a in raw.at.map { min(a, $0) } ?? a } ?? raw.at
                }
                merged[index] = m
            } else {
                merged.append(AgentMessage(id: raw.msgId ?? from + ">" + resolvedTo + ">" + raw.bodyKey + ">" + (raw.at.map { String($0.timeIntervalSince1970) } ?? ""),
                                           from: from, to: resolvedTo, kind: kind, delivery: raw.delivery,
                                           at: raw.fromSender ? raw.at : nil,
                                           arrivedAt: raw.fromSender ? nil : raw.at, text: raw.text, summary: raw.summary,
                                           msgId: raw.msgId))
                bodyKeys.append(raw.bodyKey)
            }
        }
        // What became of a message: the notices its sender got.
        for notice in notices {
            let sender = Self.sessionNode(notice.account, notice.session)
            let index = merged.indices.last { i in
                if let id = notice.msgId { return merged[i].msgId == id }
                let m = merged[i]
                return m.from == sender && [.sent, .sending, .held].contains(m.delivery)
                    && (m.at ?? .distantPast) <= (notice.at ?? .distantFuture)
            }
            if let index, merged[index].delivery != .delivered { merged[index].delivery = notice.delivery }
        }
        for i in merged.indices where merged[i].at == nil { merged[i].at = merged[i].arrivedAt }
        merged.sort { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }

        // Every end of a message or a spawn is a node.
        func ensure(_ id: String) {
            guard nodes[id] == nil else { return }
            nodes[id] = node(for: id)
        }
        for message in merged { ensure(message.from); ensure(message.to) }
        for spawn in spawns { ensure(spawn.parent); ensure(spawn.child) }
        // Subagents still at work, named by their sidecars, though they have not talked.
        for (key, meta) in agentMeta where !meta.finished {
            let id = canonical(Self.agentNode(key.account, key.session, key.agent))
            if nodes[Self.sessionNode(key.account, key.session)] != nil { ensure(id) }
        }
        return AgentGraph(nodes: nodes, messages: merged, spawns: spawns)
    }

    // MARK: - Resolving

    static func sessionNode(_ account: String, _ session: String) -> String { "session:\(account):\(session)" }
    static func agentNode(_ account: String, _ session: String, _ agent: String) -> String { "agent:\(account):\(session):\(agent)" }

    private func teammateNode(_ account: String, team: String, name: String) -> String {
        if name == "team-lead", let lead = teams[TeamKey(account: account, team: team)]?.leadSessionId {
            return Self.sessionNode(account, lead)
        }
        return "teammate:\(account):\(team):\(name)"
    }

    /// An in-process teammate has an agent id (its transcript) and a team address; the
    /// picture shows it once, as the teammate.
    private func canonical(_ id: String) -> String {
        guard id.hasPrefix("agent:") else { return id }
        let parts = id.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4, let meta = agentMeta[AgentKey(account: parts[1], session: parts[2], agent: parts[3])],
              meta.taskKind == "in_process_teammate", let team = meta.teamName, let name = meta.name else { return id }
        return teammateNode(parts[1], team: team, name: name)
    }

    private func resolve(_ endpoint: Endpoint) -> String {
        switch endpoint {
        case .session(let account, let session):
            return Self.sessionNode(account, session)
        case .agent(let account, let session, let agent):
            return canonical(Self.agentNode(account, session, agent))
        case .agentNamed(let account, let session, let name):
            if name == "main" { return Self.sessionNode(account, session) }
            if let agent = agentNames[SessionKey(account: account, session: session)]?[name] {
                return canonical(Self.agentNode(account, session, agent))
            }
            return "agent:\(account):\(session):?\(name)"
        case .teammate(let account, let team, let name):
            return teammateNode(account, team: team, name: name)
        case .teammateOf(let account, let lead, let name):
            if let team = teamOfSession[SessionKey(account: account, session: lead)] {
                return teammateNode(account, team: team, name: name)
            }
            return "teammate:\(account):?:\(name)"
        case .socket(let path, let pid, let account):
            return socketNode(path, pid: pid, account: account)
        case .remote(let id):
            return "remote:" + id
        case .target(let account, let session, let to, let pin, let routing):
            return target(account: account, session: session, to: to, pin: pin, routing: routing).node
        case .unknown(let text):
            return "unknown:" + text
        }
    }

    private func targetKind(_ endpoint: Endpoint, resolved: String) -> AgentMessage.Kind {
        guard case .target(let account, let session, let to, let pin, let routing) = endpoint else { return .crossSession }
        return target(account: account, session: session, to: to, pin: pin, routing: routing).kind
    }

    /// Whom a SendMessage's `to` names: its result's pin (a subagent) or routing (a
    /// teammate), else an address, `main`, an agent of the session (in-process names win),
    /// a member of its team, or a session of the account by its name.
    private func target(account: String, session: String, to raw: String, pin: String?, routing: String?)
        -> (node: String, kind: AgentMessage.Kind) {
        if let pin { return (canonical(Self.agentNode(account, session, pin)), .subagent) }
        let team = teamOfSession[SessionKey(account: account, session: session)]
        if let routing, routing.hasPrefix("@"), let team {
            return (teammateNode(account, team: team, name: String(routing.dropFirst())), .teammate)
        }
        let to = raw.replacingOccurrences(of: #"\s*\[[0-9a-f]{4,16}\]$"#, with: "", options: .regularExpression)
        switch Self.address(to) {
        case .socket(let path, _, _):
            return (socketNode(path, pid: nil, account: account), .crossSession)
        case .remote(let id):
            return ("remote:" + id, .crossSession)
        default:
            break
        }
        if to == "main" { return (Self.sessionNode(account, session), .subagent) }
        let local = agentNames[SessionKey(account: account, session: session)] ?? [:]
        if let agent = local[to] { return (canonical(Self.agentNode(account, session, agent)), .subagent) }
        if Self.isAgentId(to) { return (canonical(Self.agentNode(account, session, to)), .subagent) }
        if let team, teams[TeamKey(account: account, team: team)]?.members.contains(to) == true {
            return (teammateNode(account, team: team, name: to), .teammate)
        }
        let named = (records[account] ?? []).filter { $0.name == to }
        if named.count == 1 { return (Self.sessionNode(account, named[0].sessionId), .crossSession) }
        return ("name:" + to, .crossSession)
    }

    /// The session behind a socket: by the records' socket paths, else by the pid in the
    /// file's name (or the kernel-verified one) in the records. Unknown: the socket itself.
    func socketNode(_ path: String, pid: Int32?, account: String) -> String {
        let socket = Self.canonicalSocket(path)
        if let hit = bySocket[socket] { return Self.sessionNode(hit.account, hit.session) }
        var pid = pid
        if pid == nil, let match = Self.socketFile.firstMatch(in: (socket as NSString).lastPathComponent,
                                                              range: NSRange(location: 0, length: (socket as NSString).lastPathComponent.utf16.count)),
           let range = Range(match.range(at: 1), in: (socket as NSString).lastPathComponent) {
            pid = Int32((socket as NSString).lastPathComponent[range])
        }
        if let pid {
            for candidate in [account] + accounts.map(\.name) {
                if let session = byPid[candidate]?[pid] { return Self.sessionNode(candidate, session) }
            }
        }
        return "uds:" + socket
    }

    private func local(_ who: String, account: String, session: String) -> Endpoint {
        if who == "main" { return .session(account: account, session: session) }
        if Self.isAgentId(who) { return .agent(account: account, session: session, agent: who) }
        return .agentNamed(account: account, session: session, name: who)
    }

    private func endpoint(forAddress address: String, pid: Int32?, account: String) -> Endpoint {
        switch Self.address(address) {
        case .socket(let path, _, _): return .socket(path: path, pid: pid, account: account)
        case let other: return other
        }
    }

    /// `uds:<percent-encoded path>`, `bridge:<session>`, `did:…`, a bare socket path, or a name.
    static func address(_ text: String) -> Endpoint {
        if text.hasPrefix("uds:") {
            return .socket(path: canonicalSocket(String(text.dropFirst(4)).removingPercentEncoding ?? String(text.dropFirst(4))),
                           pid: nil, account: "")
        }
        if text.hasPrefix("bridge:") { return .remote(String(text.dropFirst(7)).removingPercentEncoding ?? String(text.dropFirst(7))) }
        if text.hasPrefix("did:") { return .remote(text) }
        if text.hasPrefix("/"), text.hasSuffix(".sock") { return .socket(path: canonicalSocket(text), pid: nil, account: "") }
        return .unknown(text)
    }

    /// macOS spells /tmp, /var and /etc under /private; Claude Code drops the prefix.
    static func canonicalSocket(_ path: String) -> String {
        for root in ["/private/tmp", "/private/var", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static let socketFile = try! NSRegularExpression(pattern: #"^(\d+)(?:-[0-9a-f]{8})?\.sock$"#)
    private static let agentId = try! NSRegularExpression(pattern: #"^a(?:[\w-]{1,63}-)?[0-9a-f]{16}$"#)

    static func isAgentId(_ text: String) -> Bool {
        agentId.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A node for an end the records do not name.
    private func node(for id: String) -> AgentNode {
        let parts = id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "session":
            let key = SessionKey(account: parts[1], session: parts.count > 2 ? parts[2] : "")
            let cwd = sessionCwds[key]
            return AgentNode(id: id, name: cwd.map { ($0 as NSString).lastPathComponent } ?? String(key.session.prefix(8)),
                             kind: .session, account: parts[1], cwd: cwd)
        case "agent":
            let session = parts.count > 2 ? parts[2] : ""
            let agent = parts.count > 3 ? parts[3] : ""
            let meta = agentMeta[AgentKey(account: parts[1], session: session, agent: agent)]
            let name = meta?.name ?? agentNames[SessionKey(account: parts[1], session: session)]?.first { $0.value == agent }?.key
                ?? (agent.hasPrefix("?") ? String(agent.dropFirst()) : String(agent.prefix(8)))
            return AgentNode(id: id, name: name, kind: .subagent, parent: Self.sessionNode(parts[1], session),
                             account: parts[1], detail: meta?.description, finished: meta?.finished ?? false)
        case "teammate":
            let team = parts.count > 2 ? parts[2] : ""
            let lead = teams[TeamKey(account: parts[1], team: team)]?.leadSessionId
            return AgentNode(id: id, name: parts.count > 3 ? parts[3] : "", kind: .teammate,
                             parent: lead.map { Self.sessionNode(parts[1], $0) }, account: parts[1])
        case "remote":
            let address = "bridge:" + parts.dropFirst().joined(separator: ":")
            return AgentNode(id: id, name: peerNames[address] ?? peerNames[parts.dropFirst().joined(separator: ":")] ?? "another Mac",
                             kind: .remote)
        default:
            let address = parts.dropFirst().joined(separator: ":")
            let name = peerNames["uds:" + address] ?? peerNames[address] ?? (address as NSString).lastPathComponent
            return AgentNode(id: id, name: name, kind: .remote)
        }
    }

    // MARK: - Text

    /// A message as the reader keeps it: its first line, at most `maxText` characters; an
    /// agent team's bookkeeping as what it is ("idle notification: found the cause").
    static func shown(_ body: String) -> String {
        if isProtocol(body), let data = body.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let type = (object["type"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
            let detail = (object["summary"] as? String) ?? (object["idleReason"] as? String)
            return line(detail.map { "\(type): \($0)" } ?? type) ?? type
        }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        return line(first) ?? ""
    }

    /// One line, at most `maxText` characters, cut at a character.
    static func line(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxText else { return joined }
        return String(joined.prefix(maxText - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static func bodyText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What joins the two ends of a message without keeping it: a hash of its body.
    static func bodyKey(_ body: String) -> String {
        digest(Data(body.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    static func digest(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isProtocol(_ text: String) -> Bool {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["type"] is String
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    // MARK: - Files

    /// Reads a whole small file: a record, a sidecar, a team's config or mailbox.
    private func read(_ path: String) -> Data? {
        if recordsReads { readsLog.append(path) }
        return FileManager.default.contents(atPath: path)
    }

    /// Reads a file from `offset` to its end.
    private func read(_ path: String, from offset: Int64) -> Data? {
        if recordsReads { readsLog.append(path) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }
}
