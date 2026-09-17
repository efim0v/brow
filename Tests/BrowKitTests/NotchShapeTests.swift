import XCTest
import SwiftUI
@testable import BrowKit

/// The shape cannot be eyeballed from a unit test — the physical bezel is what it has
/// to match — but the two things that make it a *notch* rather than a rectangle can be:
/// the top corners are concave (the black widens as it meets the screen edge, so a point
/// just inside the top-left corner is bezel, not black) and the bottom corners are convex
/// (a point just inside the bottom-left corner is bezel too, for the opposite reason).
final class NotchShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 40)

    func testPathFillsItsRect() {
        for radius in [NotchGeometry.collapsedBottomRadius, NotchGeometry.expandedBottomRadius] {
            let bounds = NotchShape(bottomRadius: radius).path(in: rect).boundingRect
            XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.001, "radius \(radius)")
            XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.001, "radius \(radius)")
            XCTAssertEqual(bounds.maxX, rect.maxX, accuracy: 0.001, "radius \(radius)")
            XCTAssertEqual(bounds.maxY, rect.maxY, accuracy: 0.001, "radius \(radius)")
        }
    }

    func testCentreIsInsideTheBlack() {
        let path = NotchShape().path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    func testTopCornersAreConcave() {
        let shape = NotchShape()
        let path = shape.path(in: rect)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)), "the top-left flare leaves (1, 1) in the bezel")
        XCTAssertTrue(path.contains(CGPoint(x: shape.topFlare + 1, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 1, y: 1)), "and the same on the right")
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - shape.topFlare - 1, y: 1)))
    }

    func testBottomCornersAreConvex() {
        let shape = NotchShape()
        let path = shape.path(in: rect)
        let y = rect.maxY - 1
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: y)), "the rounded bottom-left leaves (1, H − 1) outside")
        XCTAssertTrue(path.contains(CGPoint(x: shape.topFlare + shape.bottomRadius, y: y)))
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 1, y: y)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - shape.topFlare - shape.bottomRadius, y: y)))
    }

    /// `below` draws the same outline over the notch **and** the 22 pt strip, so the
    /// taller rect must still be filled edge to edge.
    func testBelowPlacementRectIsFilledToo() {
        let below = CGRect(x: 0, y: 0, width: 197, height: 54)
        let path = NotchShape().path(in: below)
        XCTAssertEqual(path.boundingRect.width, below.width, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.height, below.height, accuracy: 0.001)
        XCTAssertTrue(path.contains(CGPoint(x: below.midX, y: below.maxY - 1)), "the strip below the notch is black")
    }

    func testDefaultsAreTheTunedConstants() {
        XCTAssertEqual(NotchShape().topFlare, NotchGeometry.flare)
        XCTAssertEqual(NotchShape().bottomRadius, NotchGeometry.collapsedBottomRadius)
        XCTAssertEqual(NotchShape(topFlare: 2, bottomRadius: 3).topFlare, 2)
        XCTAssertEqual(NotchShape(topFlare: 2, bottomRadius: 3).bottomRadius, 3)
    }

    /// The path honours the rect it is handed, not a zero origin.
    func testPathHonoursANonZeroOrigin() {
        let offset = CGRect(x: 100, y: 50, width: 200, height: 40)
        let bounds = NotchShape().path(in: offset).boundingRect
        XCTAssertEqual(bounds.minX, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 50, accuracy: 0.001)
    }
}
