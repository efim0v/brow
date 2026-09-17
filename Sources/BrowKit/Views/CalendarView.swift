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
                Text(ResetCalendar.detail(for: detailDay, marks: marks, now: now, calendar: calendar))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                Text("No weekly resets known yet").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            }
        }
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
        let dayMarks = ResetCalendar.marks(marks, on: day, calendar: calendar)
        let isHovered = hovered.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 10, weight: today ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(today ? Color.white : Color.white.opacity(0.75))
            HStack(spacing: 2) {
                ForEach(Array(dayMarks.prefix(4).enumerated()), id: \.offset) { _, mark in
                    if mark.kind == .renewal {
                        Rectangle().fill(Self.color(mark.colorIndex)).frame(width: 4, height: 4).rotationEffect(.degrees(45))
                    } else {
                        Circle().fill(Self.color(mark.colorIndex)).frame(width: 4, height: 4)
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
