import XCTest
@testable import BrowKit

/// The fixture is the owner's MacBook Pro 14" (M1 Max) as `NSScreen` reports it:
/// frame 1512 × 982, `auxiliaryTopLeftArea` = (0, 950, 663.5, 32), `auxiliaryTopRightArea`
/// = (848.5, 950, 663.5, 32), `safeAreaInsets.top` = 32, menu bar 33 pt. The notch is
/// x 663.5…848.5 (185 pt wide) and **32** pt tall — one point shorter than the menu bar,
/// which is exactly why the menu-bar height must never stand in for it.
final class NotchGeometryTests: XCTestCase {
    private let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                        topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                        menuBarHeight: 33,
                                        notchHeight: 32)
    private let plain = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                      topLeftArea: nil, topRightArea: nil, menuBarHeight: 24, notchHeight: 0)

    // MARK: beside

    func testBesideCollapsedIsTheNotchPlusTwoWingsPlusFlares() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .beside)
        XCTAssertTrue(f.hasNotch)
        XCTAssertEqual(f.placement, .beside)
        // 663.5 − 96 − 6 … 848.5 + 96 + 6, top flush, notch tall.
        XCTAssertEqual(f.collapsed, CGRect(x: 561.5, y: 950, width: 389, height: 32))
        XCTAssertEqual(f.collapsed.maxY, notched.frame.maxY)
        XCTAssertEqual(f.earWidth, NotchGeometry.wingWidth)
        XCTAssertEqual(f.flare, NotchGeometry.flare)
    }

    func testCollapsedHeightIsTheNotchNotTheMenuBar() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .beside)
        XCTAssertEqual(f.notchHeight, 32)
        XCTAssertEqual(f.collapsed.height, 32)
        XCTAssertNotEqual(f.collapsed.height, notched.menuBarHeight, "a 33 pt strip stands 1 pt proud of the notch")
    }

    func testBesideIsTheDefaultPlacement() {
        XCTAssertEqual(NotchGeometry.frames(for: notched, expandedHeight: 300).collapsed,
                       NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .beside).collapsed)
    }

    // MARK: below

    func testBelowCollapsedIsNotchWidePlusFlaresAndTheStrip() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .below)
        XCTAssertEqual(f.placement, .below)
        // 663.5 − 6 … 848.5 + 6, notch height + the 22 pt ear strip.
        XCTAssertEqual(f.collapsed, CGRect(x: 657.5, y: 928, width: 197, height: 54))
        XCTAssertEqual(f.collapsed.height, f.notchHeight + NotchGeometry.belowStripHeight)
        XCTAssertEqual(f.collapsed.maxY, notched.frame.maxY, "still top flush")
        XCTAssertEqual(f.earWidth, 92.5, "the row splits the notch-wide strip in two")
    }

    // MARK: the notch height itself

    func testNotchHeightFallsBackToTheAuxiliaryAreaWhenThereIsNoSafeAreaInset() {
        let noInset = ScreenMetrics(frame: notched.frame, topLeftArea: notched.topLeftArea,
                                    topRightArea: notched.topRightArea, menuBarHeight: 33, notchHeight: 0)
        let f = NotchGeometry.frames(for: noInset, expandedHeight: 300)
        XCTAssertEqual(f.notchHeight, 32)
        XCTAssertEqual(f.collapsed.height, 32)
    }

    // MARK: expanded

    func testExpandedIsCentredOnTheNotchFlushTopAndFlareWidened() {
        for placement in EarsPlacement.allCases {
            let f = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: placement)
            XCTAssertEqual(f.expanded, CGRect(x: 520, y: 682, width: 472, height: 300), "\(placement)")
            XCTAssertEqual(f.expanded.midX, 756, "\(placement)")
            XCTAssertEqual(f.expanded.width, NotchGeometry.expandedWidth + 2 * NotchGeometry.flare, "\(placement)")
        }
    }

    /// Nothing may sit under the notch, so the panel's content starts below it.
    func testContentTopInsetClearsTheNotch() {
        let f = NotchGeometry.frames(for: notched, expandedHeight: 300)
        XCTAssertEqual(f.contentTopInset, 40)
        XCTAssertEqual(f.contentTopInset, f.notchHeight + 8)
    }

    // MARK: the pill (external display)

    func testPlainScreenUsesPill() {
        let f = NotchGeometry.frames(for: plain, expandedHeight: 300)
        XCTAssertFalse(f.hasNotch)
        XCTAssertEqual(f.collapsed.width, NotchGeometry.pillWidth)
        XCTAssertEqual(f.collapsed.height, NotchGeometry.pillHeight)
        XCTAssertEqual(f.collapsed.midX, 1280)
        XCTAssertEqual(f.collapsed.maxY, 1440)
        XCTAssertEqual(f.expanded.midX, 1280)
    }

    /// There is no notch to sit below, so the setting cannot reshape the pill: it stays
    /// the 180 × 24 pt rectangle with no flare and no inset to clear.
    func testPillIgnoresTheBelowPlacement() {
        let f = NotchGeometry.frames(for: plain, expandedHeight: 300, placement: .below)
        XCTAssertEqual(f.placement, .beside)
        XCTAssertEqual(f.flare, 0)
        XCTAssertEqual(f.notchHeight, 0)
        XCTAssertEqual(f.contentTopInset, 8)
        XCTAssertEqual(f.collapsed, NotchGeometry.frames(for: plain, expandedHeight: 300, placement: .beside).collapsed)
        XCTAssertEqual(f.expanded.width, NotchGeometry.expandedWidth)
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

    // MARK: clamping and multi-screen

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
