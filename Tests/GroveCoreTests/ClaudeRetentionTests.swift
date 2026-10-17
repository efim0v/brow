// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// `cleanupPeriodDays` from each source Claude Code reads, the smallest winning
/// (grove#6). Nothing here reads the machine's real managed settings: the managed
/// folder is a temp dir and the configuration-profile domain is injected.
final class ClaudeRetentionTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var managed: URL!
    private var account: URL!

    override func setUpWithError() throws {
        root = try Fixture.tempDir("claude-retention")
        managed = root.appendingPathComponent("managed")
        account = root.appendingPathComponent("account")
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
    }

    private func retention(profile: ClaudeRetention.Reading = .absent) -> ClaudeRetention {
        ClaudeRetention(managedDirectory: managed.path, preferences: { profile })
    }

    private func write(_ json: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testNothingSetIsClaudeCodesDefaultOfThirtyDays() {
        let r = retention().resolve(configDir: account.path)
        XCTAssertEqual(r.days, 30)
        XCTAssertEqual(r.source, .claudeDefault)
        XCTAssertTrue(r.isCertain)
        XCTAssertEqual(r.summary, "30 days (Claude Code's default)")
    }

    func testTheAccountsOwnSettingsCount() throws {
        try write(#"{"cleanupPeriodDays": 7, "model": "opus"}"#, to: account.appendingPathComponent("settings.json"))
        let r = retention().resolve(configDir: account.path)
        XCTAssertEqual(r.days, 7)
        XCTAssertEqual(r.source, .accountSettings)
        XCTAssertEqual(r.summary, "7 days (this account's settings.json)")
    }

    /// A LONGER account setting does not lift the managed one, and a shorter one wins
    /// over it: whichever layer Claude Code applies, the mirror is never more generous.
    func testTheSmallestOfManagedAndAccountWins() throws {
        try write(#"{"cleanupPeriodDays": 14}"#, to: managed.appendingPathComponent("managed-settings.json"))
        try write(#"{"cleanupPeriodDays": 60}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(retention().resolve(configDir: account.path).days, 14)
        XCTAssertEqual(retention().resolve(configDir: account.path).source, .managedFile)

        try write(#"{"cleanupPeriodDays": 5}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(retention().resolve(configDir: account.path).days, 5)
        XCTAssertEqual(retention().resolve(configDir: account.path).source, .accountSettings)
    }

    func testEveryManagedDropInIsRead() throws {
        try write(#"{"cleanupPeriodDays": 20}"#, to: managed.appendingPathComponent("managed-settings.d/10-base.json"))
        try write(#"{"cleanupPeriodDays": 3}"#, to: managed.appendingPathComponent("managed-settings.d/20-team.json"))
        try write(#"{"cleanupPeriodDays": 1}"#, to: managed.appendingPathComponent("managed-settings.d/notes.txt"))
        let r = retention().resolve(configDir: account.path)
        XCTAssertEqual(r.days, 3, "only *.json drop-ins are settings")
        XCTAssertEqual(r.source, .managedDropIn)
    }

    func testAConfigurationProfileCounts() {
        let r = retention(profile: .days(2)).resolve(configDir: account.path)
        XCTAssertEqual(r.days, 2)
        XCTAssertEqual(r.source, .managedPreferences)
    }

    func testServerManagedSettingsCachedInTheAccountCount() throws {
        try write(#"{"cleanupPeriodDays": 4}"#, to: account.appendingPathComponent("remote-settings.json"))
        try write(#"{"cleanupPeriodDays": 9}"#, to: account.appendingPathComponent("settings.json"))
        let r = retention().resolve(configDir: account.path)
        XCTAssertEqual(r.days, 4)
        XCTAssertEqual(r.source, .remoteSettings)
    }

    /// A settings file that does not parse may hold a shorter period: the answer is
    /// uncertain, which is what keeps the mirror from restoring anything.
    func testAnUnreadableSettingsFileMakesTheAnswerUncertain() throws {
        try write(#"{"cleanupPeriodDays": 7,"#, to: account.appendingPathComponent("settings.json"))
        let r = retention().resolve(configDir: account.path)
        XCTAssertFalse(r.isCertain)
        XCTAssertEqual(r.days, 30, "the other sources still give a number")
        XCTAssertEqual(r.unreadable, [account.appendingPathComponent("settings.json").path])
        XCTAssertEqual(r.summary, "30 days or less (a settings file could not be read)")
    }

    func testAValueThatIsNotAWholeNumberIsUnusable() throws {
        for value in [#""7""#, "7.5", "true", "[7]"] {
            try write(#"{"cleanupPeriodDays": \#(value)}"#, to: account.appendingPathComponent("settings.json"))
            XCTAssertFalse(retention().resolve(configDir: account.path).isCertain, value)
        }
        try write(#"{"cleanupPeriodDays": null}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertTrue(retention().resolve(configDir: account.path).isCertain, "null is simply not set")
    }

    /// Current Claude Code rejects 0; older versions read it as "keep nothing". Either
    /// way the mirror must keep nothing for it.
    func testZeroOrLessMeansKeepNothing() throws {
        try write(#"{"cleanupPeriodDays": 0}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(retention().resolve(configDir: account.path).days, 0)
        try write(#"{"cleanupPeriodDays": -5}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(retention().resolve(configDir: account.path).days, 0)
    }

    func testManagedAloneIgnoresAccountFolders() throws {
        try write(#"{"cleanupPeriodDays": 3}"#, to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(retention().resolveManaged().days, 30)
        try write(#"{"cleanupPeriodDays": 12}"#, to: managed.appendingPathComponent("managed-settings.json"))
        XCTAssertEqual(retention().resolveManaged().days, 12)
    }

    func testTheStrictestOfAnAccountsFoldersWins() {
        let a = ClaudeRetention.Resolution(days: 30, source: .claudeDefault)
        let b = ClaudeRetention.Resolution(days: 7, source: .accountSettings, unreadable: ["/x/settings.json"])
        let strictest = ClaudeRetention.strictest([a, b])
        XCTAssertEqual(strictest.days, 7)
        XCTAssertEqual(strictest.source, .accountSettings)
        XCTAssertFalse(strictest.isCertain)
        XCTAssertEqual(ClaudeRetention.strictest([]).days, 30)
    }

    // MARK: - project settings

    /// A repository with `.claude` settings at its root and a session started in a
    /// subfolder of it. Returns (repository root, the session's folder).
    private func repository(_ name: String) throws -> (root: URL, cwd: URL) {
        let repo = root.appendingPathComponent(name)
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let cwd = repo.appendingPathComponent("app/src")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        return (repo, cwd)
    }

    /// A session reads its project's settings, and its sweep deletes old transcripts in
    /// every project of the folder: the shortest any project sets is the folder's.
    func testAProjectsSettingsSetTheFoldersPeriod() throws {
        let (repo, cwd) = try repository("shop")
        try write(#"{"cleanupPeriodDays": 9}"#, to: repo.appendingPathComponent(".claude/settings.json"))
        try write(#"{"cleanupPeriodDays": 3}"#, to: repo.appendingPathComponent(".claude/settings.local.json"))
        let r = retention().resolve(configDir: account.path, projectCwds: [cwd.path])
        XCTAssertEqual(r.days, 3)
        XCTAssertEqual(r.source, .projectLocalSettings)
        XCTAssertEqual(r.origin, repo.appendingPathComponent(".claude/settings.local.json").path)
        XCTAssertTrue(r.summary.hasSuffix("/shop/.claude/settings.local.json)"), r.summary)
        XCTAssertEqual(retention().resolve(configDir: account.path).days, 30, "without its cwds, no project counts")
    }

    /// Every folder from the session's up to the repository root, and nothing above it.
    func testProjectSettingsAreReadUpToTheRepositoryRootOnly() throws {
        let (repo, cwd) = try repository("notes")
        try write(#"{"cleanupPeriodDays": 6}"#, to: cwd.appendingPathComponent(".claude/settings.json"))
        try write(#"{"cleanupPeriodDays": 1}"#, to: root.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(retention().resolve(configDir: account.path, projectCwds: [cwd.path]).days, 6)
        let files = ClaudeRetention.projectSettingsFiles(cwd: cwd.path)
        XCTAssertEqual(files.first, cwd.appendingPathComponent(".claude/settings.json").path)
        XCTAssertEqual(files.last, repo.appendingPathComponent(".claude/settings.local.json").path)
        XCTAssertEqual(files.count, 6, "src, app and the root, two files each")
    }

    /// A worktree's local settings live in the main checkout (Claude Code's worktree rule).
    func testAWorktreeAlsoReadsItsMainCheckout() throws {
        let (main, _) = try repository("main")
        let gitDir = main.appendingPathComponent(".git/worktrees/feature")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("Workspaces/shop/feature/main")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try write(#"{"cleanupPeriodDays": 2}"#, to: main.appendingPathComponent(".claude/settings.local.json"))

        XCTAssertEqual(ClaudeRetention.mainCheckout(ofGitFile: worktree.appendingPathComponent(".git").path), main.path)
        let r = retention().resolve(configDir: account.path, projectCwds: [worktree.path])
        XCTAssertEqual(r.days, 2)
        XCTAssertEqual(r.source, .projectLocalSettings)
    }

    /// A submodule's `.git` file points into the parent's `.git/modules`: no main checkout.
    func testASubmoduleHasNoMainCheckout() throws {
        let module = root.appendingPathComponent("parent/vendor/lib")
        try fm.createDirectory(at: module, withIntermediateDirectories: true)
        try "gitdir: ../../.git/modules/lib\n".write(to: module.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(ClaudeRetention.mainCheckout(ofGitFile: module.appendingPathComponent(".git").path))
    }

    /// A project file that does not parse may set a shorter period too.
    func testAnUnreadableProjectFileMakesTheAnswerUncertain() throws {
        let (repo, cwd) = try repository("broken")
        try write(#"{"cleanupPeriodDays": 4, // mine"#, to: repo.appendingPathComponent(".claude/settings.local.json"))
        let r = retention().resolve(configDir: account.path, projectCwds: [cwd.path])
        XCTAssertFalse(r.isCertain)
        XCTAssertEqual(r.unreadable, [repo.appendingPathComponent(".claude/settings.local.json").path])
    }

    /// The smallest of several projects, each file read once however many cwds share it.
    func testTheShortestOfSeveralProjectsWins() throws {
        let (a, aCwd) = try repository("a")
        let (b, bCwd) = try repository("b")
        try write(#"{"cleanupPeriodDays": 20}"#, to: a.appendingPathComponent(".claude/settings.json"))
        try write(#"{"cleanupPeriodDays": 8}"#, to: b.appendingPathComponent(".claude/settings.json"))
        let r = retention().resolve(configDir: account.path,
                                    projectCwds: [aCwd.path, a.path, bCwd.path, b.appendingPathComponent("app").path])
        XCTAssertEqual(r.days, 8)
        XCTAssertEqual(r.origin, b.appendingPathComponent(".claude/settings.json").path)
    }

    /// Outside a repository, the session's own folder.
    func testOutsideARepositoryOnlyTheFolderItself() throws {
        var probe = root!
        while probe.path != "/" {
            if fm.fileExists(atPath: probe.appendingPathComponent(".git").path) {
                throw XCTSkip("the temp folder is inside a git repository: \(probe.path)")
            }
            probe.deleteLastPathComponent()
        }
        let cwd = root.appendingPathComponent("plain/folder")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeRetention.projectSettingsFiles(cwd: cwd.path),
                       [cwd.appendingPathComponent(".claude/settings.json").path,
                        cwd.appendingPathComponent(".claude/settings.local.json").path])
    }

    func testFoldersOutsideTheRealManagedFolderNeverReadTheProfileDomain() {
        let folders = WorkspacesFolders.beside(configFile: root.appendingPathComponent("config.json"))
        XCTAssertNotEqual(folders.claudeManagedDir, ClaudeRetention.managedDirectory)
        XCTAssertEqual(folders.claudeRetention.resolve(configDir: account.path).days, 30)
        XCTAssertEqual(WorkspacesFolders.live().claudeManagedDir, "/Library/Application Support/ClaudeCode")
    }
}
