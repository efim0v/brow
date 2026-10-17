// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// grove#6: the safety net never brings back, or keeps, a transcript Claude Code's own
/// retention (`cleanupPeriodDays`) has removed.
final class TranscriptMirrorRetentionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var canonical: URL!
    private let mirror = TranscriptMirror()
    private let now = Date()
    private let cwd = "-Users-x-proj"

    override func setUpWithError() throws {
        root = try Fixture.tempDir("transcript-retention")
        canonical = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
    }

    /// A transcript last active `daysAgo` days ago, already in the mirror, then deleted
    /// the way Claude Code's sweep deletes it. Returns (live, mirror) paths.
    private func mirroredThenDeleted(id: String, daysAgo: Double, account: MirrorAccount) throws -> (String, String) {
        let dir = canonical.appendingPathComponent("projects/\(cwd)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let live = dir.appendingPathComponent("\(id).jsonl").path
        try "turn\n".write(toFile: live, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: live)
        // Mirrored back when it was still young enough to keep.
        let young = MirrorAccount(key: account.key, configDir: account.configDir)
        _ = mirror.reconcile(accounts: [young], canonicalDir: canonical.path, policy: policy(), now: now)
        let mirrored = TranscriptMirror.mirrorRoot(canonicalDir: canonical.path) + "/\(account.key)/\(cwd)/\(id).jsonl"
        XCTAssertTrue(fm.fileExists(atPath: mirrored), "fixture: the transcript is in the mirror")
        try fm.removeItem(atPath: live)
        return (live, mirrored)
    }

    private func policy() -> RetentionPolicy { RetentionPolicy(maxDays: 90, maxBytes: 0) }

    private func account(retention days: Int?, certain: Bool = true) -> MirrorAccount {
        MirrorAccount(key: accountKey(canonical.path), configDir: canonical.path,
                      retentionDays: days, mayRestore: certain)
    }

    /// The case from grove#6: 45 days old, the account keeps 7. Before the fix the
    /// next reconcile restored it; now it stays gone and its mirror copy is dropped.
    func testATranscriptPastTheAccountsRetentionIsNotRestoredAndLeavesTheMirror() throws {
        let acct = account(retention: 7)
        let (live, mirrored) = try mirroredThenDeleted(id: "old1", daysAgo: 45, account: acct)
        let report = mirror.reconcile(accounts: [acct], canonicalDir: canonical.path, policy: policy(), now: now)
        XCTAssertFalse(fm.fileExists(atPath: live), "Claude Code's sweep must not be undone")
        XCTAssertFalse(fm.fileExists(atPath: mirrored), "and nothing older than the period stays on disk")
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertEqual(report.evicted, [mirrored])
    }

    /// Well inside the period: something else deleted it, and it comes back.
    func testATranscriptWellInsideTheRetentionIsRestored() throws {
        let acct = account(retention: 7)
        let (live, _) = try mirroredThenDeleted(id: "young", daysAgo: 3, account: acct)
        let report = mirror.reconcile(accounts: [acct], canonicalDir: canonical.path, policy: policy(), now: now)
        XCTAssertTrue(fm.fileExists(atPath: live))
        XCTAssertEqual(report.restored, [live])
    }

    /// Within a day of the period it might be the sweep's: held back, but kept in the
    /// mirror until it ages out.
    func testATranscriptWithinADayOfTheRetentionIsHeldBack() throws {
        let acct = account(retention: 7)
        let (live, mirrored) = try mirroredThenDeleted(id: "edge", daysAgo: 6.5, account: acct)
        let report = mirror.reconcile(accounts: [acct], canonicalDir: canonical.path, policy: policy(), now: now)
        XCTAssertFalse(fm.fileExists(atPath: live))
        XCTAssertTrue(fm.fileExists(atPath: mirrored))
        XCTAssertEqual(report.heldBack, [mirrored])
    }

    /// An account whose settings could not be read restores nothing at all.
    func testAnUncertainRetentionRestoresNothing() throws {
        let acct = account(retention: 30, certain: false)
        let (live, mirrored) = try mirroredThenDeleted(id: "unsure", daysAgo: 1, account: acct)
        let report = mirror.reconcile(accounts: [acct], canonicalDir: canonical.path, policy: policy(), now: now)
        XCTAssertFalse(fm.fileExists(atPath: live))
        XCTAssertEqual(report.heldBack, [mirrored])
    }

    /// A live transcript older than the period is not mirrored, and an old link to it
    /// goes: the mirror holds nothing Claude Code would no longer hold.
    func testALiveTranscriptPastTheRetentionIsNotMirrored() throws {
        let dir = canonical.appendingPathComponent("projects/\(cwd)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let live = dir.appendingPathComponent("stale.jsonl").path
        try "turn\n".write(toFile: live, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: live)
        let report = mirror.reconcile(accounts: [account(retention: 7)], canonicalDir: canonical.path,
                                      policy: policy(), now: now)
        XCTAssertTrue(report.linked.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: live), "the live file is Claude Code's, never touched")
    }

    /// An entry whose account left the config falls under the orphan period.
    func testAnOrphanEntryAgesOutWithTheOrphanPeriod() throws {
        let acct = account(retention: nil)
        let (_, mirrored) = try mirroredThenDeleted(id: "orphan", daysAgo: 40, account: acct)
        let orphanPolicy = RetentionPolicy(maxDays: 90, maxBytes: 0, orphanRetentionDays: 30)
        let report = mirror.reconcile(accounts: [], canonicalDir: canonical.path, policy: orphanPolicy, now: now)
        XCTAssertFalse(fm.fileExists(atPath: mirrored))
        XCTAssertEqual(report.evicted, [mirrored])
    }

    func testKeepDaysIsTheSmallerCap() {
        XCTAssertEqual(TranscriptMirror.keepDays(policy: RetentionPolicy(maxDays: 90, maxBytes: 0), retentionDays: 7), 7)
        XCTAssertEqual(TranscriptMirror.keepDays(policy: RetentionPolicy(maxDays: 5, maxBytes: 0), retentionDays: 30), 5)
        XCTAssertEqual(TranscriptMirror.keepDays(policy: RetentionPolicy(maxDays: 0, maxBytes: 0), retentionDays: 30), 30)
        XCTAssertNil(TranscriptMirror.keepDays(policy: RetentionPolicy(maxDays: 0, maxBytes: 0), retentionDays: nil))
    }

    func testABuiltAccountCarriesItsResolution() {
        let r = ClaudeRetention.Resolution(days: 12, source: .accountSettings, unreadable: ["x"])
        let acct = MirrorAccount(configDir: "/tmp/acct", retention: r)
        XCTAssertEqual(acct.key, accountKey("/tmp/acct"))
        XCTAssertEqual(acct.retentionDays, 12)
        XCTAssertFalse(acct.mayRestore)
    }
}
