import XCTest
import GroveCore
@testable import BrowKit

final class LimitsAggregateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func acct(_ org: String, tier: String?) -> DiscoveredAccount {
        DiscoveredAccount(organizationUuid: org, email: nil, tier: tier, configDir: "/\(org)", aliasDirs: [], tokenExpiresAt: nil)
    }
    private func snap(_ org: String, five: Double?, seven: Double?, scoped: (Double, String)? = nil, at: Date? = nil) -> LimitSnapshot {
        LimitSnapshot(organizationUuid: org, fetchedAt: at ?? t0,
                      fiveHour: five.map { CapturedWindow(usedPercentage: $0, resetsAt: nil) },
                      sevenDay: seven.map { CapturedWindow(usedPercentage: $0, resetsAt: nil) },
                      weeklyScoped: scoped.map { CapturedWindow(usedPercentage: $0.0, resetsAt: nil) },
                      weeklyScopedModel: scoped?.1)
    }

    func testSingleAccountPassesThrough() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: "default_claude_max_20x")],
                                          snapshots: ["a": snap("a", five: 32, seven: 68, scoped: (98, "Fable"))], now: t0)
        XCTAssertEqual(agg.fiveHour, 32, accuracy: 0.001)
        XCTAssertEqual(agg.weekly, 68, accuracy: 0.001)
        XCTAssertEqual(agg.weeklyScoped?.percentage ?? -1, 98, accuracy: 0.001)
        XCTAssertEqual(agg.weeklyScoped?.model, "Fable")
        XCTAssertFalse(agg.stale)
    }

    func testTierWeighting() {
        // 20x at 50 % and Pro (1x) at 0 % → remaining = 20·0.5 + 1·1 = 11 of 21 → used 47.6 %.
        let agg = LimitsAggregate.compute(accounts: [acct("big", tier: "default_claude_max_20x"), acct("small", tier: "default_claude_pro")],
                                          snapshots: ["big": snap("big", five: 50, seven: 50), "small": snap("small", five: 0, seven: 0)], now: t0)
        XCTAssertEqual(agg.fiveHour, 100 * (1 - 11.0 / 21.0), accuracy: 0.01)
    }

    func testAbsentWindowCountsAsZeroUsed() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil), acct("b", tier: nil)],
                                          snapshots: ["a": snap("a", five: 100, seven: 10), "b": snap("b", five: nil, seven: 10)], now: t0)
        XCTAssertEqual(agg.fiveHour, 50, accuracy: 0.001)
    }

    func testAccountWithoutSnapshotIsZeroAndStale() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil), acct("b", tier: nil)],
                                          snapshots: ["a": snap("a", five: 40, seven: 40)], now: t0)
        XCTAssertEqual(agg.fiveHour, 20, accuracy: 0.001)
        XCTAssertTrue(agg.stale)
        XCTAssertTrue(agg.leftEar.stale)
    }

    func testStaleWhenAnySnapshotOld() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil)],
                                          snapshots: ["a": snap("a", five: 1, seven: 1, at: t0.addingTimeInterval(-200))], now: t0)
        XCTAssertTrue(agg.stale)
    }

    func testRightEarPicksStricterWeeklyWithInitial() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil)],
                                          snapshots: ["a": snap("a", five: 0, seven: 68, scoped: (98, "Fable"))], now: t0)
        XCTAssertEqual(agg.rightEar.usedPercentage, 98, accuracy: 0.001)
        XCTAssertEqual(agg.rightEar.modelInitial, "F")
        XCTAssertEqual(agg.rightEar.severity, .critical)
        let agg2 = LimitsAggregate.compute(accounts: [acct("a", tier: nil)],
                                           snapshots: ["a": snap("a", five: 0, seven: 68, scoped: (10, "Opus"))], now: t0)
        XCTAssertEqual(agg2.rightEar.usedPercentage, 68, accuracy: 0.001)
        XCTAssertNil(agg2.rightEar.modelInitial)
        XCTAssertEqual(agg2.rightEar.severity, .ok)
    }

    func testScopedAggregateOnlyOverAccountsThatHaveIt() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil), acct("b", tier: nil)],
                                          snapshots: ["a": snap("a", five: 0, seven: 0, scoped: (90, "Fable")), "b": snap("b", five: 0, seven: 0)], now: t0)
        XCTAssertEqual(agg.weeklyScoped?.percentage ?? -1, 90, accuracy: 0.001)
    }

    func testScopedModelLabelIsFromNewestSnapshot() {
        let agg = LimitsAggregate.compute(accounts: [acct("a", tier: nil), acct("b", tier: nil)],
                                          snapshots: ["a": snap("a", five: 0, seven: 0, scoped: (50, "Opus"), at: t0.addingTimeInterval(-10)),
                                                      "b": snap("b", five: 0, seven: 0, scoped: (50, "Fable"), at: t0)], now: t0)
        XCTAssertEqual(agg.weeklyScoped?.model, "Fable")
    }

    func testSeverityThresholds() {
        XCTAssertEqual(LimitsAggregate.severity(69.9), .ok)
        XCTAssertEqual(LimitsAggregate.severity(70), .warning)
        XCTAssertEqual(LimitsAggregate.severity(89.9), .warning)
        XCTAssertEqual(LimitsAggregate.severity(90), .critical)
    }

    func testNoSnapshotsMeansNoData() {
        // The ears show "—" off this flag: an account we have never fetched must not
        // read as a confident 0 %.
        XCTAssertFalse(LimitsAggregate.compute(accounts: [acct("a", tier: nil)], snapshots: [:], now: t0).hasData)
        XCTAssertFalse(LimitsAggregate.compute(accounts: [], snapshots: [:], now: t0).hasData)
        // One snapshot among several accounts is still data — a very old one included.
        XCTAssertTrue(LimitsAggregate.compute(accounts: [acct("a", tier: nil), acct("b", tier: nil)],
                                              snapshots: ["b": snap("b", five: 1, seven: 1, at: t0.addingTimeInterval(-86400))],
                                              now: t0).hasData)
    }

    func testNoAccountsIsZeroAndStale() {
        let agg = LimitsAggregate.compute(accounts: [], snapshots: [:], now: t0)
        XCTAssertEqual(agg.fiveHour, 0)
        XCTAssertTrue(agg.stale)
        XCTAssertNil(agg.weeklyScoped)
    }
}
