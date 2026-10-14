import AppKit
import XCTest
@testable import BrowKit

/// The card as `WeekCardExport` draws it. The size check always runs; the review images
/// are written only when `BROW_REVIEW_DIR` is set:
///
///     BROW_REVIEW_DIR=/path/to/dir swift test --filter WeekCardRenderTests
///
/// which fills `/path/to/dir/week-card/` with the PNGs, from the fictional demo accounts.
@MainActor
final class WeekCardRenderTests: XCTestCase {
    private typealias F = WeekCardFixture

    func testThePNGIsExactlyTheAdvertisedSize() throws {
        let now = Date()
        let rows = F.three.map { F.row($0, now: now) }
        for (shape, width, height) in [(CardShape.wide, 1200, 630), (.square, 1080, 1080)] {
            let data = try XCTUnwrap(WeekCardExport.png(F.model(rows, settings: BrowSettings(), shape: shape, now: now),
                                                        shape: shape))
            XCTAssertFalse(data.isEmpty)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data), "not a PNG")
            XCTAssertEqual(rep.pixelsWide, width, "\(shape)")
            XCTAssertEqual(rep.pixelsHigh, height, "\(shape)")
        }
    }

    func testFileNameIsDated() {
        let october15 = Date(timeIntervalSince1970: 1_792_066_800)
        XCTAssertEqual(WeekCardExport.fileName(now: october15, timeZone: TimeZone(identifier: "UTC")!),
                       "Claude Code usage 2026-10-15.png")
    }

    func testWriteReviewImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["BROW_REVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("set BROW_REVIEW_DIR to write the week card review images")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("week-card", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let now = Date()
        func rows(_ demos: [F.Demo]) -> [AccountRow] { demos.map { F.row($0, now: now) } }
        // Stale, a stale model window under a fresh reading, and no reading at all.
        let stale = [F.row(F.personal, now: now, fetchedAgo: 20 * 60),
                     F.row(F.work, now: now, scopedAgo: 15 * 60),
                     F.row(F.team, now: now, snapshot: false)]
        let cards: [(String, [AccountRow], Bool, CardShape)] = [
            ("wide-1", rows([F.work]), false, .wide),
            ("wide-1-names", rows([F.work]), true, .wide),
            ("wide-3", rows(F.three), false, .wide),
            ("wide-3-names", rows(F.three), true, .wide),
            ("wide-6-overflow", rows(F.six), false, .wide),
            ("wide-stale", stale, false, .wide),
            ("square-1", rows([F.work]), false, .square),
            ("square-2", rows([F.personal, F.work]), false, .square),
            ("square-3", rows(F.three), false, .square),
            ("square-3-names", rows(F.three), true, .square),
            ("square-4", rows(Array(F.six.prefix(4))), false, .square),
        ]
        for (name, rows, names, shape) in cards {
            let model = F.model(rows, settings: F.settings(names: names), shape: shape, now: now, timeZone: .current)
            let data = try XCTUnwrap(WeekCardExport.png(model, shape: shape), name)
            let url = out.appendingPathComponent("\(name).png")
            try data.write(to: url)
            print("week card: \(url.path)")
        }
    }
}
