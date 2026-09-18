import XCTest
@testable import BrowKit

final class FormattingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)   // 2025-09-16 04:26:40 UTC

    func testAge() {
        XCTAssertEqual(Formatting.age(t0, now: t0.addingTimeInterval(20)), "just now")
        XCTAssertEqual(Formatting.age(t0, now: t0.addingTimeInterval(61)), "1 min ago")
        XCTAssertEqual(Formatting.age(t0, now: t0.addingTimeInterval(59 * 60)), "59 min ago")
        XCTAssertEqual(Formatting.age(t0, now: t0.addingTimeInterval(2 * 3600 + 5)), "2 h ago")
        XCTAssertEqual(Formatting.age(t0, now: t0.addingTimeInterval(2 * 86400 + 5)), "2 d ago")
    }

    func testCountdownUnderADay() {
        let iso = ISO8601DateFormatter().string(from: t0.addingTimeInterval(2 * 3600 + 10 * 60 + 20))
        XCTAssertEqual(Formatting.countdown(iso, now: t0), "resets in 2 h 10 min")
        // The endpoint's "one second before the boundary" is the boundary.
        let boundary = ISO8601DateFormatter().string(from: t0.addingTimeInterval(3 * 3600 - 1))
        XCTAssertEqual(Formatting.countdown(boundary, now: t0), "resets in 3 h 0 min")
        let soon = ISO8601DateFormatter().string(from: t0.addingTimeInterval(45 * 60))
        XCTAssertEqual(Formatting.countdown(soon, now: t0), "resets in 45 min")
        let past = ISO8601DateFormatter().string(from: t0.addingTimeInterval(-5))
        XCTAssertEqual(Formatting.countdown(past, now: t0), "resets now")
    }

    func testCountdownBeyondADayShowsDateAndTime() {
        let later = t0.addingTimeInterval(3 * 86400)
        let iso = ISO8601DateFormatter().string(from: later)
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(Formatting.countdown(iso, now: t0), "resets \(f.string(from: later))")
    }

    func testCountdownAcceptsFractionalSecondsAndOffset() {
        // The live API emits "2026-09-22T19:00:00.201765+00:00".
        let s = Formatting.countdown("2026-09-22T19:00:00.201765+00:00", now: Date(timeIntervalSince1970: 1_789_000_000))
        XCTAssertTrue(s.hasPrefix("resets "), s)
        XCTAssertNotEqual(s, "not started")
    }

    func testCountdownNil() {
        XCTAssertEqual(Formatting.countdown(nil, now: t0), "not started")
        XCTAssertEqual(Formatting.countdown("garbage", now: t0), "not started")
    }

    func testPercent() {
        XCTAssertEqual(Formatting.percent(32.4), "32%")
        XCTAssertEqual(Formatting.percent(99.6), "100%")
        XCTAssertEqual(Formatting.percent(0), "0%")
    }
}
