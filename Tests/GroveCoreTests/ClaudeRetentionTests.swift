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

    func testFoldersOutsideTheRealManagedFolderNeverReadTheProfileDomain() {
        let folders = WorkspacesFolders.beside(configFile: root.appendingPathComponent("config.json"))
        XCTAssertNotEqual(folders.claudeManagedDir, ClaudeRetention.managedDirectory)
        XCTAssertEqual(folders.claudeRetention.resolve(configDir: account.path).days, 30)
        XCTAssertEqual(WorkspacesFolders.live().claudeManagedDir, "/Library/Application Support/ClaudeCode")
    }
}
