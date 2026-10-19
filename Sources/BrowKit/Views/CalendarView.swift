// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// The month under the accounts: a dot per weekly reset in the account's colour, a
/// diamond for an (estimated) subscription renewal, and the hovered day's detail
/// beside the grid — no popover, nothing to wait for. ‹ › walk the months; today is
/// ringed.
///
/// The view is always exactly as tall as the month grid, and the grid always has six
/// week rows: walking from a five-week month to a six-week one, or hovering a day on
/// which every account resets, never changes the height of the panel it sits in. The
/// day's cards are drawn over the space beside the grid and stop where it ends.
struct CalendarView: View {
    let rows: [AccountRow]
    let now: Date
    /// Fed by the controller's mouse monitor — see `CalendarHoverTracker`.
    @ObservedObject var hover: CalendarHoverTracker
    var calendar: Calendar = .autoupdatingCurrent
    /// At most this many account cards beside the grid, then "+N more on this day". Fewer
    /// when the day's cards would not fit beside the month. nil: as many as fit.
    var maxDayCards: Int? = nil
    @State private var monthOffset = 0
    private var hovered: Date? { hover.hoveredDay }

    static let cell = CGSize(width: 26, height: 22)
    /// Every month is drawn with this many week rows, the ones it does not need left empty.
    static let weekRows = 6
    /// The grid's height: title, weekday row, six week rows and the spacing between them.
    /// The whole view is this tall, whatever the day column holds.
    static let estimatedHeight: CGFloat = 16 + 6 + 12 + 6 + CGFloat(weekRows) * 22 + CGFloat(weekRows - 1) * 2
    /// The grid's width, and the gap before the day column.
    static let gridWidth: CGFloat = cell.width * 7
    static let columnGap: CGFloat = 14

    static func color(_ index: Int) -> Color {
        let palette: [Color] = [.cyan, .orange, .green, .pink, .yellow, .purple]
        return palette[index % palette.count]
    }

    private var shownMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: now) ?? now
    }
    private var marks: [CalendarMark] { ResetCalendar.marks(rows: rows) }
    private var detailDay: Date? {
        hovered ?? ResetCalendar.nextMarkedDay(marks, now: now, calendar: calendar)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            grid.frame(width: Self.gridWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        // The day column lives over the space the grid leaves, proposed the grid's own
        // height: it can never make the view taller, and what does not fit is cut.
        .overlay(alignment: .topLeading) {
            dayColumn
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, Self.gridWidth + Self.columnGap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(ResetCalendar.monthTitle(shownMonth, calendar: calendar))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                arrow("chevron.left", label: "Previous month") { monthOffset -= 1 }
                arrow("chevron.right", label: "Next month") { monthOffset += 1 }
            }
            .frame(width: Self.gridWidth, height: 16)
            HStack(spacing: 0) {
                ForEach(Array(ResetCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(width: Self.cell.width, height: 12)
                }
            }
            VStack(spacing: 2) {
                ForEach(Array(Self.sixWeeks(ResetCalendar.weeks(inMonthOf: shownMonth, calendar: calendar)).enumerated()),
                        id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day { cell(day) } else { Color.clear.frame(width: Self.cell.width, height: Self.cell.height) }
                        }
                    }
                }
            }
            .onPreferenceChange(CellFrames.self) { frames in hover.frames = frames }
        }
    }

    /// `weeks` padded with empty weeks to `weekRows`: a month never changes the grid's height.
    static func sixWeeks(_ weeks: [[Date?]]) -> [[Date?]] {
        weeks + Array(repeating: Array(repeating: nil, count: 7), count: max(0, weekRows - weeks.count))
    }

    @ViewBuilder
    private var dayColumn: some View {
        if let detailDay {
            detail(ResetCalendar.dayDetail(for: detailDay, marks: marks, now: now, calendar: calendar))
        } else {
            Text("No weekly resets known yet").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    // MARK: - The day column

    /// One account card's height for `rows` lines: padding, the name, and the rows of the
    /// table. A generous estimate (system text at 10 pt is under 12 pt a line), used only
    /// to decide how many cards to draw; the column is cut at the grid's height anyway.
    static func cardHeight(rows: Int) -> CGFloat {
        5 + 12 + 3 + CGFloat(rows) * 12 + CGFloat(max(0, rows - 1)) * 2 + 5
    }
    static let titleHeight: CGFloat = 14
    static let moreLineHeight: CGFloat = 12
    static let cardSpacing: CGFloat = 6

    /// How many of the day's cards are drawn: as many as fit beside the month with the
    /// "+N more" line under them when some are left out, and at most `maxCards`.
    static func shownCards(rowsPerCard: [Int], maxCards: Int?, room: CGFloat = estimatedHeight) -> Int {
        let total = rowsPerCard.count
        let limit = min(total, maxCards ?? total)
        func column(_ count: Int, more: Bool) -> CGFloat {
            var h = titleHeight
            for rows in rowsPerCard.prefix(count) { h += cardSpacing + cardHeight(rows: rows) }
            if more { h += cardSpacing + moreLineHeight }
            return h
        }
        if limit == total, column(total, more: false) <= room { return total }
        var shown = limit
        while shown > 0, column(shown, more: true) > room { shown -= 1 }
        return shown
    }

    /// The day as a table, one card per account: window · time · countdown.
    private func detail(_ day: ResetCalendar.DayDetail) -> some View {
        let shown = Self.shownCards(rowsPerCard: day.accounts.map(\.rows.count), maxCards: maxDayCards)
        let hidden = day.accounts.dropFirst(shown)
        return VStack(alignment: .leading, spacing: Self.cardSpacing) {
            Text(day.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            if day.accounts.isEmpty {
                Text("No resets").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Array(day.accounts.prefix(shown)), id: \.accountID) { account in
                card(account)
            }
            if !hidden.isEmpty {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(Array(hidden.prefix(5)), id: \.accountID) { account in
                            Circle().fill(Self.color(account.colorIndex)).frame(width: 5, height: 5)
                        }
                    }
                    Text("+\(hidden.count) more on this day")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(hidden.map(\.name).joined(separator: ", "))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hidden.count) more on this day: \(hidden.map(\.name).joined(separator: ", "))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ account: ResetCalendar.AccountDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(Self.color(account.colorIndex)).frame(width: 5, height: 5)
                Text(account.name).font(.system(size: 10, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(account.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.time).monospacedDigit()
                        Text(row.remaining).foregroundStyle(.secondary)
                        if row.estimated { Text("estimate").foregroundStyle(.tertiary).italic() }
                    }
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .padding(EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func arrow(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func cell(_ day: Date) -> some View {
        let today = calendar.isDate(day, inSameDayAs: now)
        let dots = ResetCalendar.dots(on: day, marks: marks, calendar: calendar)
        let isHovered = hovered.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 10, weight: today ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(today ? Color.white : Color.white.opacity(0.75))
            HStack(spacing: 2) {
                ForEach(Array(dots.prefix(5).enumerated()), id: \.offset) { _, dot in
                    if dot.renewal {
                        Rectangle().fill(Self.color(dot.colorIndex)).frame(width: 4, height: 4).rotationEffect(.degrees(45))
                    } else {
                        Circle().fill(Self.color(dot.colorIndex)).frame(width: 4, height: 4)
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(width: Self.cell.width, height: Self.cell.height)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.14 : 0))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(today ? 0.35 : 0), lineWidth: 1))
        )
        .contentShape(Rectangle())
        .background(GeometryReader { geo in
            Color.clear.preference(key: CellFrames.self, value: [calendar.startOfDay(for: day): geo.frame(in: .global)])
        })
    }

    /// Every cell's frame in the hosting view's space, merged up the tree.
    private struct CellFrames: PreferenceKey {
        static let defaultValue: [Date: CGRect] = [:]
        static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }
}
