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

    public static func countdown(_ resetsAt: String?, now: Date) -> String {
        guard let raw = resetsAt, let reset = parseISODate(raw) else { return "not started" }
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

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
