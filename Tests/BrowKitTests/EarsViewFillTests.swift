import XCTest
import SwiftUI
@testable import BrowKit

/// The gap every other test in this bundle leaves open.
///
/// `NotchGeometryTests` proves the frame is 389 × 32 flush with the screen edge and
/// `NotchShapeTests` proves the path fills whatever rect it is handed — and the strip
/// still shipped 15 pt tall, floating 8.5 pt below the edge, because `EarsView` put
/// `.background` behind content that nothing pinned to the proposed height: an `HStack`
/// of `Text`s takes its intrinsic ~15 pt and is centred in the 32 pt frame, so the black
/// was painted behind the text, not behind the notch. Pure geometry cannot see that; this
/// renders the real view at the frame `NotchPanelController` hands it and reads the drawn
/// pixels back.
@MainActor
final class EarsViewFillTests: XCTestCase {
    /// The owner's MacBook Pro 14", as `NotchGeometryTests` describes it.
    private let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                        topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                        menuBarHeight: 33,
                                        notchHeight: 32)
    /// An external display: no notch, so `EarsView` draws the pill.
    private let plain = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                      topLeftArea: nil, topRightArea: nil, menuBarHeight: 24, notchHeight: 0)

    // MARK: the three shapes

    /// `beside` is the default placement — the one every user gets.
    func testBesideStripIsDrawnFromTheScreenEdgeToTheBottomOfItsFrame() throws {
        let frames = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .beside)
        XCTAssertEqual(frames.collapsed.height, 32, "fixture check: the frame really is the notch's height")
        try assertDrawnEdgeToEdge(frames)
    }

    func testBelowStripIsDrawnFromTheScreenEdgeToTheBottomOfItsFrame() throws {
        let frames = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .below)
        XCTAssertEqual(frames.collapsed.height, 54, "fixture check: notch + the 22 pt ear strip")
        try assertDrawnEdgeToEdge(frames)
    }

    /// The pill shares the `beside` branch, so it shared the bug.
    func testPillIsDrawnFromTheScreenEdgeToTheBottomOfItsFrame() throws {
        let frames = NotchGeometry.frames(for: plain, expandedHeight: 300)
        XCTAssertFalse(frames.hasNotch)
        XCTAssertEqual(frames.collapsed.height, NotchGeometry.pillHeight)
        try assertDrawnEdgeToEdge(frames)
    }

    // MARK: the readouts stay put

    /// Filling the frame must not drag the ears to the top of it: the readouts are still
    /// vertically centred in the black (`beside` has no strip to sit in).
    func testBesideReadoutsStayVerticallyCentred() throws {
        let frames = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .beside)
        let rep = try render(frames)
        let rows = try XCTUnwrap(rowsContainingInk(rep), "the ears must draw something")
        let centre = Double(rows.lowerBound + rows.upperBound) / 2
        XCTAssertEqual(centre, Double(rep.pixelsHigh - 1) / 2, accuracy: 1.5,
                       "the readouts' ink is centred in the \(rep.pixelsHigh) px frame, not pinned to its top")
    }

    /// `below` keeps the notch's own height empty and puts the readouts in the strip.
    func testBelowReadoutsSitInTheStripUnderTheNotch() throws {
        let frames = NotchGeometry.frames(for: notched, expandedHeight: 300, placement: .below)
        let rep = try render(frames)
        let rows = try XCTUnwrap(rowsContainingInk(rep), "the ears must draw something")
        XCTAssertGreaterThanOrEqual(Double(rows.lowerBound), frames.notchHeight,
                                    "nothing is drawn under the notch — there is a camera behind it")
    }

    // MARK: rendering

    /// Renders `EarsView` exactly as `NotchPanelController.render()` installs it:
    /// `.frame(width:height:)` applied from outside, at 1 pt = 1 px.
    private func render(_ frames: NotchFrames) throws -> NSBitmapImageRep {
        let view = EarsView(aggregate: Self.aggregate, frames: frames)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI rendered nothing")
        let rep = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(CGFloat(rep.pixelsHigh), frames.collapsed.height.rounded(),
                       "the render must cover the whole proposed frame")
        return rep
    }

    /// Asserts the shape reaches both the top and the bottom edge of its frame down the
    /// middle column, where neither the flares nor the bottom corners cut in.
    private func assertDrawnEdgeToEdge(_ frames: NotchFrames,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let rep = try render(frames)
        let x = rep.pixelsWide / 2
        let run = try XCTUnwrap(drawnRun(rep, x: x), "nothing is drawn at all", file: file, line: line)
        XCTAssertEqual(run.lowerBound, 0,
                       "the shape must be flush with the screen edge; it starts \(run.lowerBound) px down",
                       file: file, line: line)
        XCTAssertEqual(run.upperBound, rep.pixelsHigh - 1,
                       "the shape must reach the bottom of its \(rep.pixelsHigh) px frame",
                       file: file, line: line)
        XCTAssertTrue(isBlack(rep, x: x, y: 0), "the topmost drawn pixel is the black shape itself",
                      file: file, line: line)
        XCTAssertTrue(isBlack(rep, x: x, y: rep.pixelsHigh - 1), "and so is the bottommost",
                      file: file, line: line)
    }

    // MARK: pixels

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private func isBlack(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        let p = pixel(rep, x, y)
        return p.a > 0.9 && p.r < 0.1 && p.g < 0.1 && p.b < 0.1
    }

    /// First and last drawn (non-transparent) row in column `x`. Anything the view paints
    /// counts — the shape or a glyph on top of it — so the bound is "where the drawing is",
    /// not "where the black is", and a stray white pixel cannot flatter the result.
    private func drawnRun(_ rep: NSBitmapImageRep, x: Int) -> ClosedRange<Int>? {
        let rows = (0..<rep.pixelsHigh).filter { pixel(rep, x, $0).a > 0.5 }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    /// The rows carrying the readouts themselves: the ink is white text and coloured dots,
    /// i.e. anything opaque that is not the black shape.
    private func rowsContainingInk(_ rep: NSBitmapImageRep) -> ClosedRange<Int>? {
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            if (0..<rep.pixelsWide).contains(where: { x in
                let p = pixel(rep, x, y)
                return p.a > 0.5 && (p.r > 0.4 || p.g > 0.4 || p.b > 0.4)
            }) { rows.append(y) }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    private static let aggregate: LimitsAggregate = {
        let left = EarReadout(usedPercentage: 6, modelInitial: nil, severity: .ok, stale: false)
        let right = EarReadout(usedPercentage: 34, modelInitial: nil, severity: .ok, stale: false)
        return LimitsAggregate(fiveHour: 6, weekly: 34, weeklyScoped: nil, stale: false,
                               hasData: true, leftEar: left, rightEar: right)
    }()
}
