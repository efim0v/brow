// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore

final class ScaffoldTests: XCTestCase {
    func testVersionConstant() {
        XCTAssertEqual(BrowVersion.current, "0.5.0")
    }
}
