// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreServices
import Foundation
import SwiftUI
import GroveCore

/// One account whose agents the Agents tab shows: its folders, and how the notch names and
/// colours it.
public struct AgentsAccount: Equatable, Sendable {
    /// A key that names the account in the picture (a hash of its first folder): stable,
    /// and never a name a user typed.
    public let key: String
    public let name: String
    /// The account's colour: a dot before its name.
    public let dot: Color?
    /// Its config folder, then the others signed in to the same login.
    public let configDirs: [String]

    public init(name: String, dot: Color?, configDirs: [String]) {
        self.key = "acct-" + accountKey(configDirs.first ?? name)
        self.name = name
        self.dot = dot
        self.configDirs = configDirs
    }
}

/// Watches the agents of every account while the notch panel is open — any section, so the
/// switch's dot is right — and for half a minute after it closes: one FSEvents stream over
/// each account's `projects/`, `sessions/` and `teams/`, files followed from where they were
/// read (`AgentCommsReader`). Nothing runs while the panel stays closed.
///
/// Read-only: it never connects to a session's socket, opens an inbox key, takes a lock,
/// writes a file or runs `claude`; of a message it keeps the first line, in memory.
@MainActor
public final class AgentsObserver: ObservableObject {
    /// What the reader has, as of its last change.
    @Published public private(set) var graph = AgentGraph()
    /// The order the row keeps its sessions in: chosen as each one appears, then kept.
    @Published public var order: [String] = []
    /// The node a click picked: the others dim, RECENT narrows to it.
    @Published public var selected: String?
    @Published public private(set) var isWatching = false
    /// A message moved in the last minute: the Agents switch's dot and "● Live".
    @Published public private(set) var isLive = false

    /// Names the project and the place in it a folder is: the host's (Workspaces' projects).
    public var place: ((String) -> String?)?

    public private(set) var accounts: [AgentsAccount] = []
    /// Time, for tests and renders.
    public var now: () -> Date = { Date() }
    /// How long the watch outlives the panel's close.
    public var linger: TimeInterval = 30
    /// What a cold start reads: the transcripts written in the last half hour.
    public static let coldStart: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "dev.artemefimov.brow.agents", qos: .utility)
    /// Driven on `queue` only.
    nonisolated private let reader: AgentCommsReader
    private var stream: FSEventStreamRef?
    /// The folders the stream watches: a `teams/` made later (the first agent team) is
    /// added when the next change is published.
    private var watchedPaths: [String] = []
    private var stopping: DispatchWorkItem?
    private var publishing = false
    /// While watching: "● Live" turns to "● Quiet" a minute after the last message, with
    /// nothing new on disk to say so.
    private var liveTimer: Timer?

    /// Whether it reads at all: false keeps it to what `preview` hands it — what tests of the
    /// host and offscreen renders get, so none of them looks at an account's folders.
    public let reads: Bool

    public init(accounts: [AgentsAccount] = [], reads: Bool = true) {
        self.accounts = accounts
        self.reads = reads
        reader = AgentCommsReader(accounts: Self.readerAccounts(accounts))
    }

    static func readerAccounts(_ accounts: [AgentsAccount]) -> [AgentAccount] {
        var seen = Set<String>()
        return accounts.flatMap { account in
            account.configDirs.map(resolved).filter { seen.insert($0).inserted }
                .map { AgentAccount(name: account.key, configDir: $0) }
        }
    }

    /// A config folder as FSEvents names what changes in it: `~` expanded, links followed
    /// (`/var` is `/private/var`). Two folders that are one are read once.
    static func resolved(_ dir: String) -> String {
        let path = expandTilde(dir)
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The accounts to watch: the notch's visible ones, with their alias folders.
    public func setAccounts(_ next: [AgentsAccount]) {
        guard next != accounts else { return }
        accounts = next
        let readerAccounts = Self.readerAccounts(next)
        let reader = self.reader
        queue.async { reader.setAccounts(readerAccounts) }
        if isWatching, reads {
            restartStream()
            publish()
        }
    }

    /// The account a node runs as.
    public func account(key: String?) -> AgentsAccount? {
        guard let key else { return nil }
        return accounts.first { $0.key == key }
    }

    // MARK: - Watching

    /// The panel opened: watch, after a cold start that reads the last half hour.
    public func panelOpened() {
        stopping?.cancel()
        stopping = nil
        guard reads, !isWatching else { return }
        isWatching = true
        let reader = self.reader
        let since = now().addingTimeInterval(-Self.coldStart)
        queue.async {
            reader.loadStatic()
            reader.readRecent(since: since)
        }
        restartStream()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLive() }
        }
        publish()
    }

    /// The panel closed: the watch stops half a minute later, unless it opens again.
    public func panelClosed() {
        guard isWatching else { return }
        stopping?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        stopping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    /// Stops watching now; what was read is kept until the next start.
    public func stop() {
        stopping?.cancel()
        stopping = nil
        stopStream()
        liveTimer?.invalidate()
        liveTimer = nil
        isWatching = false
    }

    private func updateLive() {
        let newest = graph.messages.filter { $0.kind != .teammateProtocol }.compactMap(\.at).max()
        let live = newest.map { now().timeIntervalSince($0) <= AgentsScene.liveFor } ?? false
        if live != isLive { isLive = live }
    }

    /// ⟳: the records, teams and mailboxes read again, and the recent transcripts from where
    /// they were left.
    public func rescan() {
        guard reads else { return }
        let reader = self.reader
        let since = now().addingTimeInterval(-Self.coldStart)
        queue.async {
            reader.loadStatic()
            reader.readRecent(since: since)
        }
        publish()
    }

    private var pathsToWatch: [String] {
        Self.readerAccounts(accounts).map(\.configDir).flatMap { dir in
            ["projects", "sessions", "teams"].map { dir + "/" + $0 }
        }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func restartStream() {
        stopStream()
        let paths = pathsToWatch
        watchedPaths = paths
        guard !paths.isEmpty else { return }
        // The stream holds a box with a weak reference: an event that arrives as the observer
        // goes away finds nobody, not freed memory.
        let box = StreamTarget(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<StreamTarget>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<StreamTarget>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let target = Unmanaged<StreamTarget>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            target.observer?.changed(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// FSEvents, on the reader's queue: each file read on, then one publish.
    nonisolated fileprivate func changed(_ paths: [String]) {
        for path in paths where !path.hasSuffix(".key") && !path.hasSuffix(".lock") {
            reader.changed(path)
        }
        Task { @MainActor in self.publish() }
    }

    /// The reader's picture, onto the main actor, at most once per burst; older than an
    /// hour forgotten first.
    func publish() {
        guard !publishing else { return }
        publishing = true
        let reader = self.reader
        let cutoff = now().addingTimeInterval(-AgentsScene.memory)
        queue.async { [weak self] in
            reader.prune(before: cutoff)
            reader.readMailboxes()
            let graph = reader.graph()
            Task { @MainActor in
                guard let self else { return }
                self.publishing = false
                if graph != self.graph { self.graph = graph }
                self.updateLive()
                if self.isWatching, self.pathsToWatch != self.watchedPaths { self.restartStream() }
            }
        }
    }

    /// Waits for what has been asked of the reader to land: tests.
    func settle() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        publishing = false
        publish()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        await Task.yield()
    }

    /// Offscreen renders: this picture, no reading.
    public func preview(graph: AgentGraph, now: Date) {
        self.graph = graph
        self.now = { now }
        updateLive()
    }

    /// The scene at this moment.
    public var scene: AgentsScene { scene(at: now()) }

    public func scene(at date: Date) -> AgentsScene { AgentsScene.make(graph: graph, now: date, place: place) }
}

/// What an FSEvents stream calls: the observer, held weakly.
private final class StreamTarget: @unchecked Sendable {
    weak var observer: AgentsObserver?
    init(_ observer: AgentsObserver) { self.observer = observer }
}
