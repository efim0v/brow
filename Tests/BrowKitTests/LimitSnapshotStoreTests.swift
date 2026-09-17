import XCTest
import GroveCore
@testable import BrowKit

final class LimitSnapshotStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFromUsageMapsWindowsAndFetchedAt() {
        let usage = OAuthUsage(fiveHour: OAuthWindow(utilization: 32, resetsAt: "2026-09-16T20:00:00Z"),
                               sevenDay: OAuthWindow(utilization: 68, resetsAt: "2026-09-22T00:00:00Z"),
                               sevenDaySonnet: nil, sevenDayOpus: nil,
                               weeklyScoped: OAuthScopedWindow(utilization: 98, resetsAt: "2026-09-22T00:00:00Z", modelDisplayName: "Fable"),
                               fetchedAt: t0)
        let snap = LimitSnapshot(organizationUuid: "org", usage: usage, now: t0.addingTimeInterval(500))
        XCTAssertEqual(snap?.fiveHour, CapturedWindow(usedPercentage: 32, resetsAt: "2026-09-16T20:00:00Z"))
        XCTAssertEqual(snap?.sevenDay?.usedPercentage, 68)
        XCTAssertEqual(snap?.weeklyScoped?.usedPercentage, 98)
        XCTAssertEqual(snap?.weeklyScopedModel, "Fable")
        XCTAssertEqual(snap?.fetchedAt, t0, "dated by the FETCH, not the tick")
    }

    func testFromUsageClampsAndFallsBackToNow() {
        let usage = OAuthUsage(fiveHour: OAuthWindow(utilization: 140, resetsAt: nil), sevenDay: nil,
                               sevenDaySonnet: nil, sevenDayOpus: nil)
        let snap = LimitSnapshot(organizationUuid: "org", usage: usage, now: t0)
        XCTAssertEqual(snap?.fiveHour?.usedPercentage, 100)
        XCTAssertEqual(snap?.fetchedAt, t0)
    }

    func testFromUsageWithNoWindowsIsNil() {
        let usage = OAuthUsage(fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil)
        XCTAssertNil(LimitSnapshot(organizationUuid: "org", usage: usage, now: t0))
    }

    func testStaleAfterThreeMinutes() {
        let snap = LimitSnapshot(organizationUuid: "o", fetchedAt: t0, fiveHour: nil, sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        XCTAssertFalse(snap.isStale(now: t0.addingTimeInterval(179)))
        XCTAssertTrue(snap.isStale(now: t0.addingTimeInterval(181)))
    }

    func testRoundTripThroughDisk() throws {
        let dir = try Fixture.tempDir("limits").path + "/nested"   // store must create it
        let store = LimitSnapshotStore(directory: dir)
        XCTAssertEqual(store.load(), [:], "missing file → empty, not an error")
        let a = LimitSnapshot(organizationUuid: "a", fetchedAt: t0,
                              fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: "x"),
                              sevenDay: nil, weeklyScoped: CapturedWindow(usedPercentage: 2, resetsAt: nil),
                              weeklyScopedModel: "Fable")
        try store.save(["a": a])
        XCTAssertEqual(store.load(), ["a": a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/limits.json"))
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let dir = try Fixture.tempDir("limits-corrupt").path
        try "not json".write(toFile: dir + "/limits.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(LimitSnapshotStore(directory: dir).load(), [:])
    }
}

// MARK: - Persisted accounts

extension LimitSnapshotStoreTests {
    private var accountA: DiscoveredAccount {
        DiscoveredAccount(organizationUuid: "org-a", email: "a@example.com", tier: "default_claude_max_20x",
                          configDir: "/tmp/a", aliasDirs: ["/tmp/a-alias"], tokenExpiresAt: t0)
    }

    func testFileRoundTripWithAccounts() throws {
        let dir = try Fixture.tempDir("limits-file").path + "/nested"   // store must create it
        let store = LimitSnapshotStore(directory: dir)
        XCTAssertEqual(store.loadFile(), LimitsFile(snapshots: [:], accounts: []), "missing file → empty file, not an error")

        let snap = LimitSnapshot(organizationUuid: "org-a", fetchedAt: t0,
                                 fiveHour: CapturedWindow(usedPercentage: 41, resetsAt: "2026-09-16T20:00:00Z"),
                                 sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        let accounts = [
            PersistedAccount(from: accountA, order: 0),
            PersistedAccount(from: DiscoveredAccount(organizationUuid: "org-b", email: nil, tier: nil,
                                                     configDir: "/tmp/b", aliasDirs: [], tokenExpiresAt: nil), order: 1),
        ]
        try store.saveFile(LimitsFile(snapshots: ["org-a": snap], accounts: accounts))

        XCTAssertEqual(store.loadFile(), LimitsFile(snapshots: ["org-a": snap], accounts: accounts))
        XCTAssertEqual(store.load(), ["org-a": snap], "the snapshot-only wrapper reads the new shape")

        try store.save(["org-a": snap])
        XCTAssertEqual(store.loadFile().accounts, accounts, "saving snapshots alone must not drop the accounts")
    }

    func testLegacySnapshotMapStillLoads() throws {
        let dir = try Fixture.tempDir("limits-legacy").path
        let legacy = """
        {
          "org-a" : {
            "fetchedAt" : "2023-11-14T22:13:20Z",
            "fiveHour" : { "resetsAt" : "2026-09-16T20:00:00Z", "usedPercentage" : 41 },
            "organizationUuid" : "org-a"
          }
        }
        """
        try legacy.write(toFile: dir + "/limits.json", atomically: true, encoding: .utf8)

        let loaded = LimitSnapshotStore(directory: dir).loadFile()
        XCTAssertEqual(loaded.snapshots["org-a"]?.fetchedAt, t0)
        XCTAssertEqual(loaded.snapshots["org-a"]?.fiveHour,
                       CapturedWindow(usedPercentage: 41, resetsAt: "2026-09-16T20:00:00Z"))
        XCTAssertEqual(loaded.accounts, [], "an old file names no accounts")
    }

    func testPersistedAccountRoundTripsToDiscovered() {
        let persisted = PersistedAccount(from: accountA, order: 3)
        XCTAssertEqual(persisted.order, 3, "display order survives the file")
        XCTAssertEqual(persisted.organizationUuid, "org-a")

        let back = persisted.discovered
        XCTAssertEqual(back.organizationUuid, "org-a")
        XCTAssertEqual(back.email, "a@example.com")
        XCTAssertEqual(back.tier, "default_claude_max_20x")
        XCTAssertEqual(back.configDir, "/tmp/a")
        XCTAssertEqual(back.aliasDirs, [], "alias dirs come from the scan, never from the seed")
        XCTAssertNil(back.tokenExpiresAt, "a persisted expiry would be a lie about a live token")
    }
}
