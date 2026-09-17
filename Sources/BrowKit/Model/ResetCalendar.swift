import Foundation
import GroveCore

/// One thing that happens on a day: an account's weekly window resetting, or its
/// subscription renewing. `colorIndex` is the account's position in the panel, the
/// key the calendar's palette is indexed by.
public struct CalendarMark: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The window's label as the bar shows it: "Weekly", "Fable".
        case weekly(String)
        case renewal
    }
    public let accountID: String
    public let accountName: String
    public let colorIndex: Int
    public let kind: Kind
    public let at: Date

    public init(accountID: String, accountName: String, colorIndex: Int, kind: Kind, at: Date) {
        self.accountID = accountID
        self.accountName = accountName
        self.colorIndex = colorIndex
        self.kind = kind
        self.at = at
    }
}

/// The pure half of the panel's calendar: which marks the rows produce, how a month
/// lays out as weeks, and the one line the hovered day reads as. `calendar` is always
/// injected so the tests never depend on the machine's zone or first weekday.
public enum ResetCalendar {
    /// The weekly windows and the (estimated) renewal of every row, in row order.
    public static func marks(rows: [AccountRow]) -> [CalendarMark] {
        var marks: [CalendarMark] = []
        for (index, row) in rows.enumerated() {
            func add(_ kind: CalendarMark.Kind, _ at: Date?) {
                guard let at else { return }
                marks.append(CalendarMark(accountID: row.id, accountName: row.name, colorIndex: index, kind: kind, at: at))
            }
            add(.weekly("Weekly"), row.snapshot?.sevenDay?.resetsAt.flatMap(parseISODate))
            if let scoped = row.snapshot?.weeklyScoped {
                add(.weekly(row.snapshot?.weeklyScopedModel ?? "Model"), scoped.resetsAt.flatMap(parseISODate))
            }
            add(.renewal, row.renewsAt)
        }
        return marks
    }

    /// The month containing `date` as rows of seven, padded with nil outside the month,
    /// starting on the calendar's first weekday.
    public static func weeks(inMonthOf date: Date, calendar: Calendar) -> [[Date?]] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in days { cells.append(calendar.date(byAdding: .day, value: day - 1, to: month.start)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// Weekday initials in the calendar's own order (Monday first where the locale says so).
    public static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    public static func marks(_ marks: [CalendarMark], on day: Date, calendar: Calendar) -> [CalendarMark] {
        marks.filter { calendar.isDate($0.at, inSameDayAs: day) }
    }

    /// The first day at or after `now` that carries a mark — what the detail line shows
    /// while nothing is hovered.
    public static func nextMarkedDay(_ marks: [CalendarMark], now: Date, calendar: Calendar) -> Date? {
        marks.map(\.at).filter { $0 >= now || calendar.isDate($0, inSameDayAs: now) }.min()
    }

    /// One dot per ACCOUNT per day — two windows resetting the same day are one
    /// event to the eye — plus a diamond when its renewal falls there. Row order.
    public struct Dot: Equatable, Sendable {
        public let colorIndex: Int
        public let renewal: Bool
    }
    public static func dots(on day: Date, marks: [CalendarMark], calendar: Calendar) -> [Dot] {
        var dots: [Dot] = []
        for mark in Self.marks(marks, on: day, calendar: calendar) {
            let dot = Dot(colorIndex: mark.colorIndex, renewal: mark.kind == .renewal)
            if !dots.contains(dot) { dots.append(dot) }
        }
        return dots.sorted { ($0.colorIndex, $0.renewal ? 1 : 0) < ($1.colorIndex, $1.renewal ? 1 : 0) }
    }

    /// One line of the day's table: `Weekly · 02:00 · in 4 d 1 h`. A renewal row is
    /// marked as the estimate it is.
    public struct DayRow: Equatable, Sendable {
        public let label: String
        public let time: String
        public let remaining: String
        public let estimated: Bool
    }
    /// One account's card for the day.
    public struct AccountDay: Equatable, Sendable {
        public let accountID: String
        public let name: String
        public let colorIndex: Int
        public let rows: [DayRow]
    }
    /// The hovered day, structured: a title (`Tuesday 22 September`) and a card per
    /// account in row order, each with one row per window resetting that day.
    public struct DayDetail: Equatable, Sendable {
        public let title: String
        public let accounts: [AccountDay]
    }

    public static func dayDetail(for day: Date, marks: [CalendarMark], now: Date, calendar: Calendar) -> DayDetail {
        let title = formatter("EEEE d MMMM", calendar).string(from: day)
        let time = formatter("HH:mm", calendar)
        var order: [String] = []
        var byAccount: [String: [CalendarMark]] = [:]
        for mark in Self.marks(marks, on: day, calendar: calendar) {
            if byAccount[mark.accountID] == nil { order.append(mark.accountID) }
            byAccount[mark.accountID, default: []].append(mark)
        }
        let accounts = order.compactMap { id -> AccountDay? in
            guard let ms = byAccount[id], let first = ms.first else { return nil }
            let rows = ms.map { m -> DayRow in
                switch m.kind {
                case .weekly(let label):
                    return DayRow(label: label, time: time.string(from: m.at),
                                  remaining: Formatting.remaining(m.at, now: now), estimated: false)
                case .renewal:
                    return DayRow(label: "Renewal", time: "~" + time.string(from: m.at),
                                  remaining: Formatting.remaining(m.at, now: now), estimated: true)
                }
            }
            return AccountDay(accountID: id, name: first.accountName, colorIndex: first.colorIndex, rows: rows)
        }
        return DayDetail(title: title, accounts: accounts)
    }

    public static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        formatter("LLLL yyyy", calendar).string(from: date)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f
    }
}
