// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit

/// Where the Workspaces panel hangs from (`PanelAnchor.resolve`).
final class PanelAnchorTests: XCTestCase {
    /// A 1512 × 982 screen with a 33 pt menu bar: the visible frame stops under it.
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)

    func testUnderAnItemThatSitsInTheMenuBar() {
        let icon = CGRect(x: 1200, y: 952, width: 24, height: 24)
        XCTAssertEqual(PanelAnchor.resolve(iconRect: icon, visibleFrame: visible),
                       PanelAnchor(rightX: 1224, topY: 946))
    }

    /// The 26.4 layout cache parks a broken item at the origin: the panel would open in
    /// the bottom-left corner. It goes to the top-right instead.
    func testAnItemParkedAtTheOriginFallsBackToTheTopRight() {
        let icon = CGRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertEqual(PanelAnchor.resolve(iconRect: icon, visibleFrame: visible),
                       PanelAnchor(rightX: 1504, topY: 945))
    }

    func testNoItemAtAllIsTheTopRight() {
        XCTAssertEqual(PanelAnchor.resolve(iconRect: nil, visibleFrame: visible), .topRight(of: visible))
    }

    /// An item reported on another screen (off this one's width) is not hung from.
    func testAnItemOutsideTheScreensWidthFallsBackToTheTopRight() {
        let icon = CGRect(x: 2000, y: 952, width: 24, height: 24)
        XCTAssertEqual(PanelAnchor.resolve(iconRect: icon, visibleFrame: visible), .topRight(of: visible))
    }

    func testTheTopRightSitsJustUnderTheMenuBar() {
        let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        XCTAssertEqual(PanelAnchor.topRight(of: secondScreen), PanelAnchor(rightX: 3424, topY: 1051))
    }
}
