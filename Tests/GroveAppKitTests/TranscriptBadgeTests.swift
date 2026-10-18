// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit

final class TranscriptBadgeTests: XCTestCase {
    func testBadgeState() {
        XCTAssertEqual(TranscriptBadge.state(liveExists: true,  mirrored: true),  .mirrored)
        XCTAssertEqual(TranscriptBadge.state(liveExists: false, mirrored: true),  .restorable)
        XCTAssertEqual(TranscriptBadge.state(liveExists: true,  mirrored: false), .unmirrored)
    }
}
