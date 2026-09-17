import Foundation
import GroveCore

/// Pure string helpers for the panel. `now` is always injected.
public enum Formatting {
    public static func age(_ from: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(from))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }

    /// A window's reset instant, to the nearest minute. The endpoint dates a reset a
    /// fraction of a second BEFORE the boundary it means — `18:59:59.641069+00:00` for a
    /// window claude.ai itself shows as "Wednesday 12:00 AM" — and one account's Weekly
    /// and Fable windows can differ by that fraction (`19:59:58.96` next to `20:00:00`).
    /// Shown raw that was "Tue 23:59" beside "Wed 00:00" for the same reset.
    public static func resetInstant(_ resetsAt: String?) -> Date? {
        guard let raw = resetsAt, let reset = parseISODate(raw) else { return nil }
        return Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60)
    }

    public static func countdown(_ resetsAt: String?, now: Date) -> String {
        guard let reset = resetInstant(resetsAt) else { return "not started" }
        let remaining = reset.timeIntervalSince(now)
        if remaining <= 0 { return "resets now" }
        if remaining < 86400 {
            let h = Int(remaining / 3600)
            let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return h == 0 ? "resets in \(m) min" : "resets in \(h) h \(m) min"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "resets \(f.string(from: reset))"
    }

    /// `in 3 d 4 h` / `in 4 h 12 min` / `in 12 min` / `now` — for the calendar's detail line.
    public static func remaining(_ date: Date, now: Date) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let d = Int(s / 86400), h = Int(s.truncatingRemainder(dividingBy: 86400) / 3600)
        let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if d > 0 { return "in \(d) d \(h) h" }
        if h > 0 { return "in \(h) h \(m) min" }
        return "in \(m) min"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
