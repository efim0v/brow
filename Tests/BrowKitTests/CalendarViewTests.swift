// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// The month under the accounts is always as tall as a six-week grid, and the day column
/// beside it never runs past it: hovering a busy day, or walking to a month of another
/// length, cannot change the height of the panel the month sits in.
@MainActor
final class CalendarViewTests: XCTestCase {
    /// The month is always as tall as its six-week grid: a four-, five- or six-week month, and
    /// any day hovered — even one on which all eight accounts reset.
    func testTheMonthHasOneHeightWhateverTheMonthAndTheHoveredDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        // February 2027 takes four Monday-first weeks, February 2026 five, March 2026 six.
        let months = [(2027, 2), (2026, 2), (2026, 3)].map { year, month in
            calendar.date(from: DateComponents(year: year, month: month, day: 10, hour: 9))!
        }
        for month in months {
            let store = try MadeUpLimits.store(count: 8, sameDay: true, now: month, appDir: newAppDir())
            let hover = CalendarHoverTracker()
            let days = ResetCalendar.weeks(inMonthOf: month, calendar: calendar).flatMap { $0 }.compactMap { $0 }
            XCTAssertGreaterThanOrEqual(days.count, 28)
            var heights = Set<Int>()
            for (index, day) in ([nil] + days.map(Optional.some)).enumerated() {
                if let day {
                    let cell = CGRect(x: CGFloat(index) * 30, y: 0, width: 20, height: 20)
                    hover.frames = [calendar.startOfDay(for: day): cell]
                    hover.update(pointer: CGPoint(x: cell.midX, y: cell.midY))
                    XCTAssertNotNil(hover.hoveredDay)
                }
                let view = CalendarView(rows: store.rows, now: month, hover: hover, calendar: calendar,
                                        maxDayCards: 3)
                    .frame(width: 432)
                    .fixedSize(horizontal: false, vertical: true)
                heights.insert(Int(try renderedHeight(view).rounded()))
            }
            XCTAssertEqual(heights, [Int(CalendarView.estimatedHeight)],
                           "\(month): one height for every hovered day")
        }
    }

    /// Three cards fit beside the month when each has one line; with more accounts the column
    /// says how many more, and it never runs past the grid.
    func testTheDayColumnStopsAtTheMonth() {
        XCTAssertEqual(CalendarView.shownCards(rowsPerCard: [1, 1, 1], maxCards: 3), 3)
        XCTAssertEqual(CalendarView.shownCards(rowsPerCard: [1, 1, 1, 1, 1], maxCards: 3), 3)
        XCTAssertEqual(CalendarView.shownCards(rowsPerCard: [3, 3, 3], maxCards: 3), 2)
        XCTAssertEqual(CalendarView.shownCards(rowsPerCard: [2, 2, 2, 2], maxCards: nil), 2)
        XCTAssertEqual(CalendarView.shownCards(rowsPerCard: [], maxCards: 3), 0)
        for rows in [[1], [2, 2], [3, 3, 3], [1, 2, 3, 1, 2, 3, 1, 2]] {
            let shown = CalendarView.shownCards(rowsPerCard: rows, maxCards: 3)
            var column = CalendarView.titleHeight
            for card in rows.prefix(shown) { column += CalendarView.cardSpacing + CalendarView.cardHeight(rows: card) }
            if shown < rows.count { column += CalendarView.cardSpacing + CalendarView.moreLineHeight }
            XCTAssertLessThanOrEqual(column, CalendarView.estimatedHeight, "\(rows)")
        }
    }

    func testEveryMonthIsDrawnWithSixWeeks() {
        let week: [Date?] = Array(repeating: nil, count: 7)
        XCTAssertEqual(CalendarView.sixWeeks([week, week, week, week]).count, 6)
        XCTAssertEqual(CalendarView.sixWeeks(Array(repeating: week, count: 6)).count, 6)
    }

    private func newAppDir() throws -> String { try Fixture.tempDir("calendar").path }

    private func renderedHeight<V: View>(_ view: V) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return CGFloat(image.height)
    }
}
