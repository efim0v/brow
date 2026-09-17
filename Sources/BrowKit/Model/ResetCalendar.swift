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

    /// `Tue 22 Sep — 900tr345: Weekly & Fable reset 02:00 (in 3 d 4 h) · artem: Weekly resets 00:00 (in 3 d 2 h)`
    /// One entry per account, in row order; a renewal reads as what it is, an estimate.
    public static func detail(for day: Date, marks: [CalendarMark], now: Date, calendar: Calendar) -> String {
        let dayLabel = formatter("EEE d MMM", calendar).string(from: day)
        let today = Self.marks(marks, on: day, calendar: calendar)
        guard !today.isEmpty else { return "\(dayLabel) — no resets" }
        let time = formatter("HH:mm", calendar)
        var order: [String] = []
        var byAccount: [String: [CalendarMark]] = [:]
        for mark in today {
            if byAccount[mark.accountID] == nil { order.append(mark.accountID) }
            byAccount[mark.accountID, default: []].append(mark)
        }
        let parts = order.map { id -> String in
            let ms = byAccount[id] ?? []
            var pieces: [String] = []
            let resets = ms.compactMap { m -> (label: String, at: Date)? in
                if case .weekly(let label) = m.kind { return (label, m.at) }
                return nil
            }
            if let first = resets.first {
                let times = Set(resets.map { time.string(from: $0.at) })
                if times.count == 1 {
                    let labels = resets.map(\.label).joined(separator: " & ")
                    pieces.append("\(labels) reset \(time.string(from: first.at)) (\(Formatting.remaining(first.at, now: now)))")
                } else {
                    pieces.append(contentsOf: resets.map {
                        "\($0.label) resets \(time.string(from: $0.at)) (\(Formatting.remaining($0.at, now: now)))"
                    })
                }
            }
            if let renewal = ms.first(where: { $0.kind == .renewal }) {
                pieces.append("subscription renews ~\(time.string(from: renewal.at)) (\(Formatting.remaining(renewal.at, now: now)), estimated from the start date)")
            }
            return "\(ms.first?.accountName ?? id): \(pieces.joined(separator: ", "))"
        }
        return "\(dayLabel) — " + parts.joined(separator: " · ")
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
