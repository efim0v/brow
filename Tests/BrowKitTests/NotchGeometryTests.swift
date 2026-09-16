import XCTest
@testable import BrowKit

final class NotchGeometryTests: XCTestCase {
    // 14" MacBook Pro-like: 1512×982, notch between x=596…916 (width 320), menu bar 37 pt.
    private let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        topLeftArea: CGRect(x: 0, y: 945, width: 596, height: 37),
                                        topRightArea: CGRect(x: 916, y: 945, width: 596, height: 37),
                                        menuBarHeight: 37)
    private let plain = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                      topLeftArea: nil, topRightArea: nil, menuBarHeight: 24)

    func testNotchedCollapsedSpansEarsAndNotch() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300)
        XCTAssertTrue(f.hasNotch)
        XCTAssertEqual(f.collapsed.minX, 596 - NotchGeometry.earWidth)
        XCTAssertEqual(f.collapsed.maxX, 916 + NotchGeometry.earWidth)
        XCTAssertEqual(f.collapsed.maxY, 982)
        XCTAssertEqual(f.collapsed.height, 37)
        XCTAssertEqual(f.earWidth, NotchGeometry.earWidth)
    }

    func testNotchedExpandedCentredOnNotchAndFlushTop() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300)
        XCTAssertEqual(f.expanded.midX, 756)
        XCTAssertEqual(f.expanded.width, NotchGeometry.expandedWidth)
        XCTAssertEqual(f.expanded.maxY, 982)
        XCTAssertEqual(f.expanded.height, 300)
    }

    func testPlainScreenUsesPill() {
        let f = NotchGeometry.frames(for: plain, expandedHeight: 300)
        XCTAssertFalse(f.hasNotch)
        XCTAssertEqual(f.collapsed.width, NotchGeometry.pillWidth)
        XCTAssertEqual(f.collapsed.height, NotchGeometry.pillHeight)
        XCTAssertEqual(f.collapsed.midX, 1280)
        XCTAssertEqual(f.collapsed.maxY, 1440)
        XCTAssertEqual(f.expanded.midX, 1280)
    }

    /// The pill exists FOR external displays, and it was the one place the readouts
    /// were clipped: two fixed `earWidth` ears plus `EarsView`'s 10 pt horizontal
    /// padding needed 200 pt inside a 180 pt window, cutting ~10 pt off each edge —
    /// exactly where the two status dots sit. Fixed-width children cannot compress, so
    /// the padding has to come out of the ear width.
    func testPillEarsPlusPaddingFitInsideThePill() {
        let f = NotchGeometry.frames(for: plain, expandedHeight: 300)
        XCTAssertEqual(2 * f.earWidth + 2 * NotchGeometry.pillPadding, f.collapsed.width)
        XCTAssertEqual(f.earWidth, 80)
    }

    func testExpandedIsClampedInsideNarrowScreen() {
        let narrow = ScreenMetrics(frame: CGRect(x: 100, y: 0, width: 400, height: 800),
                                   topLeftArea: nil, topRightArea: nil, menuBarHeight: 24)
        let f = NotchGeometry.frames(for: narrow, expandedHeight: 300)
        XCTAssertGreaterThanOrEqual(f.expanded.minX, 100)
        XCTAssertLessThanOrEqual(f.expanded.maxX, 500)
    }

    func testScreenOriginOffsetIsRespected() {
        let second = ScreenMetrics(frame: CGRect(x: 1512, y: 200, width: 1920, height: 1080),
                                   topLeftArea: nil, topRightArea: nil, menuBarHeight: 24)
        let f = NotchGeometry.frames(for: second, expandedHeight: 100)
        XCTAssertEqual(f.collapsed.maxY, 1280)
        XCTAssertEqual(f.collapsed.midX, 1512 + 960)
    }
}
