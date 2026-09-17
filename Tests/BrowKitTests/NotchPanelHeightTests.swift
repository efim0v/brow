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
    /// The 14" fixture: `NotchGeometry` insets the expanded content by the notch
    /// height (32) + 8 pt so nothing sits under the notch.
    private let inset: CGFloat = 40

    func testTwoAccountsWithThreeBarsAskForMoreThanTheOldFloor() {
        let height = NotchPanelController.estimatedExpandedHeight(barCounts: [3, 3], topInset: inset)
        XCTAssertGreaterThan(height, 200, "two three-bar accounts need far more than the 120 pt floor")
    }

    func testHeightGrowsWithAccountsAndWithBars() {
        let one = NotchPanelController.estimatedExpandedHeight(barCounts: [2], topInset: inset)
        let two = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 2], topInset: inset)
        let threeBars = NotchPanelController.estimatedExpandedHeight(barCounts: [3], topInset: inset)
        XCTAssertGreaterThan(two, one)
        XCTAssertGreaterThan(threeBars, one)
        XCTAssertGreaterThan(one, NotchPanelController.estimatedExpandedHeight(barCounts: [], topInset: inset))
    }

    /// The content now starts `contentTopInset` below the frame's top edge, and the
    /// window is sized from this model when SwiftUI has not laid the tree out yet. A
    /// floor that ignores the inset is one notch too short — the footer (the only ⟳
    /// and ⚙ there are) falls off the bottom exactly as it used to off the top.
    func testTheTopInsetIsAddedToTheFloor() {
        let bare = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 3], topInset: 0)
        let notched = NotchPanelController.estimatedExpandedHeight(barCounts: [2, 3], topInset: inset)
        XCTAssertEqual(notched, bare + inset, accuracy: 0.001)
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
