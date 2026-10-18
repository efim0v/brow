// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

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

    /// The squircle is the default; the old quadratic corner is kept only to compare.
    func testBottomCornersAreContinuousByDefault() {
        XCTAssertTrue(NotchShape().continuousCorners)
        XCTAssertFalse(NotchShape(continuousCorners: false).continuousCorners)
    }

    /// The flares are drawn beside the body, not over it: both sides of the edge they
    /// share are black, so no hairline of bezel shows between them.
    func testTheFlaresMeetTheBodyWithoutASeam() {
        let shape = NotchShape(topFlare: 6, bottomRadius: NotchGeometry.expandedBottomRadius)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 472, height: 300))
        for y in stride(from: CGFloat(0.5), through: 5, by: 0.5) {
            XCTAssertTrue(path.contains(CGPoint(x: 5.99, y: y)), "left flare at y \(y)")
            XCTAssertTrue(path.contains(CGPoint(x: 6.01, y: y)), "left body at y \(y)")
            XCTAssertTrue(path.contains(CGPoint(x: 466.01, y: y)), "right flare at y \(y)")
            XCTAssertTrue(path.contains(CGPoint(x: 465.99, y: y)), "right body at y \(y)")
        }
    }

    /// The quadratic corner hugs the corner (its control point sits on it), which is what
    /// read as a plain, sharp radius; the continuous one of the same radius takes the
    /// corner away more gently. 9 pt above the bottom, the quadratic edge is 1.8 pt in from
    /// the side and the continuous one 2.9 pt.
    func testTheContinuousCornerIsSofterThanTheQuadraticOne() {
        let rect = CGRect(x: 0, y: 0, width: 472, height: 300)
        let continuous = NotchShape(topFlare: 6, bottomRadius: 18).path(in: rect)
        let quadratic = NotchShape(topFlare: 6, bottomRadius: 18, continuousCorners: false).path(in: rect)
        let point = CGPoint(x: 6 + 2.4, y: rect.maxY - 9)
        XCTAssertTrue(quadratic.contains(point))
        XCTAssertFalse(continuous.contains(point))
    }

    /// The path honours the rect it is handed, not a zero origin.
    func testPathHonoursANonZeroOrigin() {
        let offset = CGRect(x: 100, y: 50, width: 200, height: 40)
        let bounds = NotchShape().path(in: offset).boundingRect
        XCTAssertEqual(bounds.minX, 100, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 50, accuracy: 0.001)
    }
}
