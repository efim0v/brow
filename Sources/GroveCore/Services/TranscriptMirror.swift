// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

public struct MirrorAccount: Sendable, Equatable {
    public let key: String        // accountKey(configDir)
    public let configDir: String  // expanded, no trailing slash
    /// How long Claude Code itself keeps this folder's transcripts, in days
    /// (`ClaudeRetention`). The mirror keeps nothing older and restores nothing within
    /// a day of it. nil: no period of its own, only `RetentionPolicy.maxDays` applies.
    public let retentionDays: Int?
    /// False when that period could not be read for certain (a settings file that does
    /// not parse): the real one may be shorter, so nothing is restored.
    public let mayRestore: Bool

    public init(key: String, configDir: String, retentionDays: Int? = nil, mayRestore: Bool = true) {
        self.key = key
        self.configDir = configDir
        self.retentionDays = retentionDays
        self.mayRestore = mayRestore
    }

    /// The account as the app builds it: its folder plus Claude Code's period for it.
    public init(configDir: String, retention: ClaudeRetention.Resolution) {
        self.init(key: accountKey(configDir), configDir: configDir,
                  retentionDays: retention.days, mayRestore: retention.isCertain)
    }
}

public struct RetentionPolicy: Sendable {
    public let maxDays: Int       // 0 = no age cap
    public let maxBytes: Int64    // 0 = no size cap
    /// The period for mirror entries whose account is no longer configured — the
    /// smallest Claude Code could be applying to them. nil: `maxDays` alone.
    public let orphanRetentionDays: Int?
    public init(maxDays: Int, maxBytes: Int64, orphanRetentionDays: Int? = nil) {
        self.maxDays = maxDays; self.maxBytes = maxBytes; self.orphanRetentionDays = orphanRetentionDays
    }
}

public struct ReconcileReport: Sendable, Equatable {
    public var linked:   [String] = []
    public var restored: [String] = []
    public var evicted:  [String] = []
    /// Mirror entries whose transcript is gone and that were NOT put back: too close to
    /// (or past) the account's retention, or the retention could not be read.
    public var heldBack: [String] = []
    public var issues:   [String] = []
    public init() {}
}

/// Injectable filesystem ops so tests can force the cross-volume fallback.
public struct FileOps: Sendable {
    public var hardlink:     @Sendable (_ src: String, _ dst: String) throws -> Void
    public var copyFallback: @Sendable (_ src: String, _ dst: String) throws -> Void
    public init(hardlink: @escaping @Sendable (String, String) throws -> Void,
                copyFallback: @escaping @Sendable (String, String) throws -> Void) {
        self.hardlink = hardlink; self.copyFallback = copyFallback
    }
    public static let live = FileOps(
        hardlink:     { try FileManager.default.linkItem(atPath: $0, toPath: $1) },
        copyFallback: { try FileManager.default.copyItem(atPath: $0, toPath: $1) }
    )
}

/// Hardlink safety-net for Claude session transcripts (spec 2026-07-08). Same
/// conventions as `SharedSessionStore`: struct over `FileManager`, explicit string
/// paths (never hardcodes ~/.claude), idempotent, never throws out of `reconcile`.
///
/// It never outlives Claude Code's own retention (grove#6). Claude Code deletes a
/// transcript once its last activity is older than `cleanupPeriodDays`; a mirror that
/// put such a file back, or kept a hard link to it, would undo a period the user — or
/// their organisation, through managed settings — set precisely to have those files
/// gone. So per account: entries older than the account's period are evicted like any
/// over-age entry, and a vanished transcript is restored only while it is more than
/// `restoreMarginDays` younger than that period, so a file Claude Code's sweep may have
/// taken is never the one brought back.
///
/// A workspace shared between accounts (`SharedSessionStore`: the account's
/// `projects/<cwd>` is a link into the default account's) holds transcripts every one of
/// those accounts' Claude Code sweeps. Its entries are filed under the default account,
/// and judged by the shortest period of all the accounts that reach the folder.
public struct TranscriptMirror: Sendable {
    /// How far inside the account's retention a vanished transcript has to be to be
    /// restored: a sweep that judged age a little differently (another clock, another
    /// reference time) must still never see its deletion undone.
    public static let restoreMarginDays: Double = 1

    private let ops: FileOps
    public init(fileOps: FileOps = .live) { self.ops = fileOps }

    /// The age, in days, past which an entry is evicted: the smaller of the mirror's own
    /// cap (0 = none) and Claude Code's period. nil: no cap at all.
    static func keepDays(policy: RetentionPolicy, retentionDays: Int?) -> Int? {
        [policy.maxDays > 0 ? policy.maxDays : nil, retentionDays].compactMap { $0 }.min()
    }

    /// Whether a vanished transcript of this age may be put back for `account`.
    static func mayRestore(ageDays: Double, account: MirrorAccount) -> Bool {
        guard account.mayRestore else { return false }
        guard let days = account.retentionDays else { return true }
        return ageDays <= Double(days) - restoreMarginDays
    }

    public static func mirrorRoot(canonicalDir: String) -> String { canonicalDir + "/grove/transcripts" }

    /// The folder `<configDir>/projects/<encodedCwd>` stands for: where a shared-store link
    /// points — even one whose target is gone — else the folder itself, with the links
    /// above it resolved. Two accounts whose `projects/<cwd>` stand for the same folder
    /// hold the same transcripts, and each one's Claude Code sweeps them.
    static func sharedFolder(configDir: String, encodedCwd: String) -> String {
        let projects = configDir + "/projects"
        var target = projects + "/" + encodedCwd
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target) {
            target = destination.hasPrefix("/") ? destination : projects + "/" + destination
        }
        target = (target as NSString).standardizingPath
        // The parent exists (or existed); the leaf may be gone and still names its folder.
        let parent = canonicalPath((target as NSString).deletingLastPathComponent)
        return (parent as NSString).appendingPathComponent((target as NSString).lastPathComponent)
    }

    /// The folders among `configDirs` whose `projects/<encodedCwd>` is the same folder as
    /// `configDir`'s, in `configDirs`' order: `configDir` itself, and every account that
    /// shares that workspace with it, or shares it into.
    public static func foldersSharing(encodedCwd: String, with configDir: String, among configDirs: [String]) -> [String] {
        let folder = sharedFolder(configDir: configDir, encodedCwd: encodedCwd)
        let sharing = configDirs.filter { sharedFolder(configDir: $0, encodedCwd: encodedCwd) == folder }
        return sharing.contains(configDir) ? sharing : [configDir] + sharing
    }

    /// One period for a transcript several accounts can reach: the shortest any of them
    /// keeps it for, and restorable only if every one of them is certain of its own.
    static func strictest(_ group: [MirrorAccount]) -> (retentionDays: Int?, mayRestore: Bool) {
        (group.compactMap(\.retentionDays).min(), group.allSatisfy(\.mayRestore))
    }

    struct EntryRef: Hashable { let accountKey: String; let encodedCwd: String; let file: String }
    struct EntryState { var livePath: String?; var mirrorPath: String? }

    @discardableResult
    public func reconcile(accounts: [MirrorAccount], canonicalDir: String,
                          policy: RetentionPolicy, now: Date = Date()) -> ReconcileReport {
        let fm = FileManager.default
        var report = ReconcileReport()
        let mirrorRoot = Self.mirrorRoot(canonicalDir: canonicalDir)
        var entries: [EntryRef: EntryState] = [:]

        // Which accounts reach each workspace folder: its owner, and every account whose
        // `projects/<cwd>` is a shared-store link to it. All of their sweeps apply to it.
        var accountsByFolder: [String: Set<String>] = [:]

        // 1. live transcripts (ground truth)
        for acc in accounts {
            let projects = acc.configDir + "/projects"
            for cwd in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let cwdDir = projects + "/" + cwd
                accountsByFolder[Self.sharedFolder(configDir: acc.configDir, encodedCwd: cwd), default: []].insert(acc.key)
                if (try? fm.destinationOfSymbolicLink(atPath: cwdDir)) != nil { continue } // shared-store symlink → canonical mirrors it, skip
                for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] {
                    guard name.hasSuffix(".jsonl") else { continue }
                    let live = cwdDir + "/" + name
                    if (try? fm.destinationOfSymbolicLink(atPath: live)) != nil { continue } // skip symlinks
                    entries[EntryRef(accountKey: acc.key, encodedCwd: cwd, file: name), default: EntryState()].livePath = live
                }
            }
        }
        // 2. existing mirror entries
        for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
            let keyDir = mirrorRoot + "/" + key
            for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                let cwdDir = keyDir + "/" + cwd
                for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] {
                    guard name.hasSuffix(".jsonl") else { continue }
                    entries[EntryRef(accountKey: key, encodedCwd: cwd, file: name), default: EntryState()].mirrorPath = cwdDir + "/" + name
                }
            }
        }

        let accountByKey = Dictionary(accounts.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        /// The entry's account and every other account that reaches the same folder.
        func accountsReaching(_ ref: EntryRef, owner: MirrorAccount) -> [MirrorAccount] {
            let keys = accountsByFolder[Self.sharedFolder(configDir: owner.configDir, encodedCwd: ref.encodedCwd)] ?? []
            return [owner] + keys.subtracting([owner.key]).sorted().compactMap { accountByKey[$0] }
        }

        // size cap: scan mirror-only inodes (nlink == 1) BEFORE the reconcile loop so
        // that we measure the true cost before any restoration inflates the link count.
        var sizeEvicted: Set<String> = []
        if policy.maxBytes > 0 {
            var mirrorOnly: [(path: String, mtime: Date, size: Int64)] = []
            for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
                let keyDir = mirrorRoot + "/" + key
                for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                    let cwdDir = keyDir + "/" + cwd
                    for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] where name.hasSuffix(".jsonl") {
                        let p = cwdDir + "/" + name
                        if (nlink(p) ?? 2) == 1, let m = mtime(p) { mirrorOnly.append((p, m, size(p))) }
                    }
                }
            }
            var total = mirrorOnly.reduce(Int64(0)) { $0 + $1.size }
            for e in mirrorOnly.sorted(by: { $0.mtime < $1.mtime }) where total > policy.maxBytes {
                try? fm.removeItem(atPath: e.path); report.evicted.append(e.path); total -= e.size
                sizeEvicted.insert(e.path)
            }
        }

        for (ref, st) in entries {
            let mp = st.mirrorPath ?? (mirrorRoot + "/\(ref.accountKey)/\(ref.encodedCwd)/\(ref.file)")
            // skip entries whose mirror was just size-evicted
            if let existing = st.mirrorPath, sizeEvicted.contains(existing) { continue }
            let refMtime = st.livePath.flatMap(mtime) ?? st.mirrorPath.flatMap(mtime)
            let ageDays = refMtime.map { now.timeIntervalSince($0) / 86400 } ?? 0
            let account = accountByKey[ref.accountKey]
            // Judged by every account that reaches the transcript, not only the one it
            // is filed under: in a shared workspace each of their sweeps can remove it.
            let reaching = account.map { Self.strictest(accountsReaching(ref, owner: $0)) }
            let retention = reaching.map(\.retentionDays) ?? policy.orphanRetentionDays
            let withinAge = Self.keepDays(policy: policy, retentionDays: retention).map { ageDays <= Double($0) } ?? true

            guard withinAge else {
                if let existing = st.mirrorPath { try? fm.removeItem(atPath: existing); report.evicted.append(existing) }
                continue
            }

            if let live = st.livePath {
                if st.mirrorPath == nil {
                    placeMirror(src: live, dst: mp, report: &report)
                } else if inode(live) != inode(mp) {
                    try? fm.removeItem(atPath: mp); placeMirror(src: live, dst: mp, report: &report)
                }
            } else if let existingMirror = st.mirrorPath {
                guard let account else {
                    report.issues.append("mirror \(ref.file): account \(ref.accountKey) unknown"); continue
                }
                let live = account.configDir + "/projects/\(ref.encodedCwd)/\(ref.file)"
                // Already there — reached through a shared-store symlink (the account's
                // `projects/<cwd>` points into canonical, so step 1 skipped it and this
                // mirror is a leftover from before the workspace was shared) or written
                // back by Claude itself. Nothing to restore, and a leftover that is the
                // very same inode is a redundant link: drop it rather than fail on it
                // every ninety seconds ("… couldn't be linked to …" was exactly this).
                if fm.fileExists(atPath: live) {
                    if inode(live) == inode(existingMirror) {
                        try? fm.removeItem(atPath: existingMirror)
                        report.evicted.append(existingMirror)
                    }
                    continue
                }
                // Gone, and maybe by Claude Code's own sweep: put back only what no sweep
                // that reaches it can have taken. The entry stays in the mirror until it
                // ages out.
                let judged = MirrorAccount(key: account.key, configDir: account.configDir,
                                           retentionDays: reaching?.retentionDays,
                                           mayRestore: reaching?.mayRestore ?? false)
                guard Self.mayRestore(ageDays: ageDays, account: judged) else {
                    report.heldBack.append(existingMirror)
                    continue
                }
                do {
                    try fm.createDirectory(atPath: (live as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try ops.hardlink(mp, live)
                    report.restored.append(live)
                } catch { report.issues.append("restore \(ref.file): \(error.localizedDescription)") }
            }
        }
        return report
    }

    private func placeMirror(src: String, dst: String, report: inout ReconcileReport) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try ops.hardlink(src, dst); report.linked.append(dst) }
        catch {
            do { try ops.copyFallback(src, dst); report.issues.append("cross-volume snapshot (copy): \(dst)") }
            catch { report.issues.append("mirror failed \(dst): \(error.localizedDescription)") }
        }
    }

    /// Permanent delete: unlink the mirror(s) for `sessionId` AND every live
    /// transcript path across `accounts`. After this, `reconcile` finds no mirror
    /// and will not restore it.
    public func purge(sessionId: String, accounts: [MirrorAccount], canonicalDir: String) throws {
        let fm = FileManager.default
        let mirrorRoot = Self.mirrorRoot(canonicalDir: canonicalDir)
        let file = sessionId + ".jsonl"
        // mirror side
        for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
            let keyDir = mirrorRoot + "/" + key
            for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                let p = keyDir + "/\(cwd)/\(file)"
                if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
            }
        }
        // live side
        for acc in accounts {
            let projects = acc.configDir + "/projects"
            for cwd in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let p = projects + "/\(cwd)/\(file)"
                if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
            }
        }
    }

    func inode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
    func nlink(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.referenceCount] as? Int }
    func size(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }
    func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
}
