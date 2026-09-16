import XCTest
import GroveCore
@testable import BrowKit

/// `expandedHeight()` read `host.fittingSize` in the same turn `render()` assigned
/// `host.rootView`, i.e. before SwiftUI had laid the new tree out, so the first hover
/// opened at the `max(120, …)` floor and cut off the footer — the only ⟳ and ⚙ there
/// are. The layout pass fixes the ordering; this model-derived floor is the belt to
/// that braces, and it is the half that can be tested without a display.
@MainActor
final class NotchPanelHeightTests: XCTestCase {
    func testTwoAccountsWithThreeBarsAskForMoreThanTheOldFloor() {
        let height = NotchPanelController.estimatedExpandedHeight(barCounts: [3, 3])
        XCTAssertGreaterThan(height, 200, "two three-bar accounts need far more than the 120 pt floor")
    }

    func testHeightGrowsWithAccountsAndWithBars() {
        let one = NotchPanelController.estimatedExpandedHeight(barCounts: [2])
        let two = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 2])
        let threeBars = NotchPanelController.estimatedExpandedHeight(barCounts: [3])
        XCTAssertGreaterThan(two, one)
        XCTAssertGreaterThan(threeBars, one)
        XCTAssertGreaterThan(one, NotchPanelController.estimatedExpandedHeight(barCounts: []))
    }

    /// The third bar exists only when the payload carried a model-scoped weekly window.
    func testBarCountFollowsTheSnapshot() {
        let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: nil,
                                        configDir: "/d", aliasDirs: [], tokenExpiresAt: nil)
        let base = LimitSnapshot(organizationUuid: "org", fetchedAt: Date(),
                                 fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: nil),
                                 sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        let scoped = LimitSnapshot(organizationUuid: "org", fetchedAt: Date(),
                                   fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: nil),
                                   sevenDay: nil,
                                   weeklyScoped: CapturedWindow(usedPercentage: 9, resetsAt: nil),
                                   weeklyScopedModel: "Fable")
        func row(_ snapshot: LimitSnapshot?) -> AccountRow {
            AccountRow(account: account, name: "a", snapshot: snapshot, status: .ok, tokenStatus: "fresh · 1 h")
        }
        XCTAssertEqual(NotchPanelController.barCount(row(base)), 2)
        XCTAssertEqual(NotchPanelController.barCount(row(scoped)), 3)
        XCTAssertEqual(NotchPanelController.barCount(row(nil)), 2)
    }
}
