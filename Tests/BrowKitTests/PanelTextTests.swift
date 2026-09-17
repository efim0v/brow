import XCTest
import GroveCore
@testable import BrowKit

final class PanelTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)   // 2025-09-16 04:26:40 UTC
    private var threeHoursAgo: Date { t0.addingTimeInterval(-3 * 3600) }
    private var threeDaysAgo: Date { t0.addingTimeInterval(-3 * 86400) }

    private func snap(at: Date) -> LimitSnapshot {
        LimitSnapshot(organizationUuid: "a", fetchedAt: at,
                      fiveHour: CapturedWindow(usedPercentage: 12, resetsAt: nil),
                      sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
    }

    // MARK: - Footer: the age is always first

    func testFooterIsTheAgeWhenNothingIsWrong() {
        XCTAssertEqual(PanelText.footer(dataAsOf: threeHoursAgo, error: nil, now: t0), "Updated 3 h ago")
        // An error that has no text is not an error: it must not leave a dangling " · ".
        XCTAssertEqual(PanelText.footer(dataAsOf: threeHoursAgo, error: "", now: t0), "Updated 3 h ago")
    }

    func testFooterKeepsTheAgeInFrontOfALiveError() {
        XCTAssertEqual(PanelText.footer(dataAsOf: threeHoursAgo, error: "Offline", now: t0),
                       "Updated 3 h ago · Offline")
    }

    func testFooterBeforeAnyDataWithALiveError() {
        XCTAssertEqual(PanelText.footer(dataAsOf: nil, error: "Offline", now: t0), "No data yet · Offline")
    }

    func testFooterBeforeAnyData() {
        XCTAssertEqual(PanelText.footer(dataAsOf: nil, error: nil, now: t0), "No data yet")
    }

    // MARK: - Account tag

    func testTagIsJustTheTierWhileFresh() {
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: snap(at: t0),
                                            status: .ok, now: t0),
                       "Max 20x")
    }

    func testStaleTagCarriesTheAgeOfWhatIsStillOnScreen() {
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: snap(at: threeDaysAgo),
                                            status: .stale, now: t0),
                       "Max 20x · 3 d ago")
    }

    func testFailedFetchStillNamesTheAgeOfTheSnapshotItKept() {
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: snap(at: threeDaysAgo),
                                            status: .error("sign-in expired"), now: t0),
                       "Max 20x · 3 d ago · sign-in expired")
    }

    func testWithoutASnapshotTheAgeSlotReadsNoData() {
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: nil,
                                            status: .error("Offline"), now: t0),
                       "Max 20x · no data · Offline")
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: nil,
                                            status: .stale, now: t0),
                       "Max 20x · no data")
    }

    func testTierLabels() {
        XCTAssertEqual(PanelText.tierLabel("default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(PanelText.tierLabel("default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(PanelText.tierLabel("default_claude_pro"), "Pro")
        XCTAssertEqual(PanelText.tierLabel("something_new"), "something_new")
        XCTAssertEqual(PanelText.tierLabel(nil), "—")
    }

    // MARK: - Ears: never a fabricated 0 %

    func testEarsReadDashWhenThereIsNoDataAtAll() {
        let ear = EarReadout(usedPercentage: 0, modelInitial: nil, severity: .ok, stale: true)
        XCTAssertEqual(PanelText.earsText(ear, hasData: false), "—")
        XCTAssertEqual(PanelText.earsText(nil, hasData: true), "—")
        XCTAssertEqual(PanelText.earsText(nil, hasData: false), "—")
    }

    func testEarsReadThePercentageWhenThereIsData() {
        let ear = EarReadout(usedPercentage: 27.4, modelInitial: nil, severity: .ok, stale: false)
        XCTAssertEqual(PanelText.earsText(ear, hasData: true), "27%")
    }

    /// A refresh queued behind the rate limit says WHEN, in place of the bare error;
    /// the age keeps its slot in front of it.
    func testFooterCountsDownToAQueuedRefresh() {
        let t0 = Date(timeIntervalSince1970: 1_758_000_000)
        let twoMinutesAgo = t0.addingTimeInterval(-120)
        XCTAssertEqual(PanelText.footer(dataAsOf: twoMinutesAgo, error: "Rate limited — waiting to retry",
                                        retryAt: t0.addingTimeInterval(47), now: t0),
                       "Updated 2 min ago · retrying in 47 s")
        XCTAssertEqual(PanelText.footer(dataAsOf: nil, error: nil, retryAt: t0.addingTimeInterval(0.2), now: t0),
                       "No data yet · retrying in 1 s")
        XCTAssertEqual(PanelText.footer(dataAsOf: twoMinutesAgo, error: nil, retryAt: t0.addingTimeInterval(-5), now: t0),
                       "Updated 2 min ago · retrying in 0 s", "a countdown never goes negative")
    }
}
