import SwiftUI

/// The month under the accounts: a dot per weekly reset in the account's colour, a
/// diamond for an (estimated) subscription renewal, and the hovered day's detail
/// beside the grid — no popover, nothing to wait for. ‹ › walk the months; today is
/// ringed.
struct CalendarView: View {
    let rows: [AccountRow]
    let now: Date
    var calendar: Calendar = .autoupdatingCurrent
    @State private var monthOffset = 0
    @State private var hovered: Date?

    static let cell = CGSize(width: 26, height: 22)
    /// The height `NotchPanelController` budgets for this view before it is laid out:
    /// title, weekday row, six week rows and the spacing between them.
    static let estimatedHeight: CGFloat = 16 + 6 + 12 + 6 + 6 * 22 + 5 * 2

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
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(ResetCalendar.monthTitle(shownMonth, calendar: calendar))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    arrow("chevron.left") { monthOffset -= 1 }
                    arrow("chevron.right") { monthOffset += 1 }
                }
                .frame(width: Self.cell.width * 7)
                HStack(spacing: 0) {
                    ForEach(Array(ResetCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: Self.cell.width)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(Array(ResetCalendar.weeks(inMonthOf: shownMonth, calendar: calendar).enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                if let day { cell(day) } else { Color.clear.frame(width: Self.cell.width, height: Self.cell.height) }
                            }
                        }
                    }
                }
            }
            if let detailDay {
                detail(ResetCalendar.dayDetail(for: detailDay, marks: marks, now: now, calendar: calendar))
            } else {
                Text("No weekly resets known yet").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            }
        }
    }

    /// The day as a table, one card per account: window · time · countdown.
    private func detail(_ day: ResetCalendar.DayDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.title).font(.system(size: 11, weight: .semibold))
            if day.accounts.isEmpty {
                Text("No resets").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(day.accounts, id: \.accountID) { account in
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
                }
                .padding(EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.secondary)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .onHover { inside in
            if inside { hovered = day } else if isHovered { hovered = nil }
        }
    }
}
