// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The notch stays shut after its Workspaces button until the pointer has left the
/// expanded panel's area once.
final class NotchHoverLatchTests: XCTestCase {
    func testAnIdleLatchNeverHolds() {
        var latch = NotchHoverLatch()
        XCTAssertTrue(latch.allowsHover(pointerInExpandedArea: true))
        XCTAssertTrue(latch.allowsHover(pointerInExpandedArea: false))
    }

    func testEngagedItHoldsWhileThePointerStaysInside() {
        var latch = NotchHoverLatch()
        latch.engage()
        XCTAssertFalse(latch.allowsHover(pointerInExpandedArea: true))
        XCTAssertFalse(latch.allowsHover(pointerInExpandedArea: true))
        XCTAssertTrue(latch.isEngaged)
    }

    func testLeavingOnceReleasesItForGood() {
        var latch = NotchHoverLatch()
        latch.engage()
        XCTAssertFalse(latch.allowsHover(pointerInExpandedArea: true))
        XCTAssertTrue(latch.allowsHover(pointerInExpandedArea: false), "the first position outside releases it")
        XCTAssertFalse(latch.isEngaged)
        XCTAssertTrue(latch.allowsHover(pointerInExpandedArea: true), "and the notch opens normally again")
    }
}
