// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import XCTest
@testable import BrowKit

/// The Workspaces menu-bar item is Brow's mark: the notch, drawn by the bar's own tint,
/// with its two readout dots knocked out.
final class BrowMarkTests: XCTestCase {
    private func alpha(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
        rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide) / rep.size.width),
                    y: Int(y * CGFloat(rep.pixelsHigh) / rep.size.height))?.alphaComponent ?? -1
    }

    func testItIsATemplateTheMenuBarTints() {
        let image = BrowMark.templateImage()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 22, height: 16))
    }

    func testTheNotchIsFilledAndTheDotsAreHoles() throws {
        let image = BrowMark.templateImage(width: 50)       // 1 pt per unit of the artwork, 50 × 28
        XCTAssertEqual(image.size, NSSize(width: 50, height: 28))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        func at(_ x: CGFloat, _ y: CGFloat) -> CGFloat { alpha(rep, x: x, y: y) }
        XCTAssertGreaterThan(at(25, 4), 0.9, "the body of the notch is drawn")
        XCTAssertLessThan(at(12.5, 14), 0.1, "the left dot is a hole")
        XCTAssertLessThan(at(37.5, 14), 0.1, "the right dot is a hole")
        XCTAssertLessThan(at(1, 27), 0.1, "the rounded bottom corner is outside the shape")
    }
}
