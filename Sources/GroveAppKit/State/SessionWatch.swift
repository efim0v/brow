// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Darwin
import Foundation
import GroveCore

/// Keeps the Projects list current while it is in view, without polling the disk for
/// what the kernel can say at once:
///
/// - each account's `sessions/` folder, watched (`O_EVTONLY`, a dispatch source on its
///   writes): a session starting, stopping or changing what it does rewrites its record
///   there — the states are read again within a fifth of a second;
/// - each live session's process, watched for its exit;
/// - every 1.5 s, the live sessions' transcripts looked at (a `stat`), and a preview read
///   again only from one that changed;
/// - every 5 s, the processes looked at for folders to suggest.
///
/// Nothing runs while the list is not in view (`AppState.isPanelOpen`).
@MainActor
final class SessionWatch {
    private weak var state: AppState?
    private var folders: [DispatchSourceFileSystemObject] = []
    private var exits: [Int32: DispatchSourceProcess] = [:]
    private var previews: Timer?
    private var suggestions: Timer?
    private var liveRead: DispatchWorkItem?
    private var indexRead: DispatchWorkItem?
    private(set) var isRunning = false

    /// How long a burst of record writes is gathered into one read.
    static let settle: TimeInterval = 0.2
    static let previewInterval: TimeInterval = 1.5
    static let suggestionInterval: TimeInterval = 5

    init(state: AppState) {
        self.state = state
    }

    func start() {
        guard !isRunning, let state else { return }
        isRunning = true
        for dir in Set(state.config.accounts.flatMap(\.allConfigDirs).map(expandTilde)) {
            let path = dir + "/sessions"
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.liveSoon() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            folders.append(source)
        }
        liveChanged(state.liveSessions)
        previews = Timer.scheduledTimer(withTimeInterval: Self.previewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let state = self?.state else { return }
                Task { await state.refreshPreviews() }
            }
        }
        suggestions = Timer.scheduledTimer(withTimeInterval: Self.suggestionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let state = self?.state else { return }
                Task { await state.refreshSuggestions() }
            }
        }
        Task { await state.refreshSuggestions() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        folders.forEach { $0.cancel() }
        folders = []
        exits.values.forEach { $0.cancel() }
        exits = [:]
        previews?.invalidate()
        previews = nil
        suggestions?.invalidate()
        suggestions = nil
        liveRead?.cancel()
        liveRead = nil
        indexRead?.cancel()
        indexRead = nil
    }

    /// The live sessions changed: watch the exit of each one's process.
    func liveChanged(_ live: [LiveProcess]) {
        guard isRunning else { return }
        let pids = Set(live.map(\.pid))
        for (pid, source) in exits where !pids.contains(pid) {
            source.cancel()
            exits[pid] = nil
        }
        for pid in pids where exits[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.liveSoon() }
            }
            source.resume()
            exits[pid] = source
        }
    }

    /// Reads what runs, once a burst of changes has settled.
    func liveSoon() {
        guard isRunning else { return }
        liveRead?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let state = self?.state else { return }
                Task { await state.refreshLive() }
            }
        }
        liveRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// A session runs that the list does not have yet: the index is read again, once.
    func indexSoon() {
        guard isRunning, indexRead == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.indexRead = nil
                guard let state = self?.state else { return }
                Task { await state.refreshSessionIndex() }
            }
        }
        indexRead = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// For tests: how many folders and processes are watched.
    var watchedFolders: Int { folders.count }
    var watchedProcesses: Set<Int32> { Set(exits.keys) }
}
