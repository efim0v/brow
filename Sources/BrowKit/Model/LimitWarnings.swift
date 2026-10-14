import Foundation
import GroveCore

/// The windows a limit warning can be about: the 5-hour, the weekly and the
/// model-scoped weekly one (Fable, Opus).
public enum LimitWindowKind: String, Sendable, CaseIterable { case fiveHour, weekly, weeklyScoped }

/// One notification Brow wants on screen, now or at `deliverAt`.
public struct LimitNotice: Sendable, Equatable {
    /// `.test` is the Settings button's notice, never produced by `LimitWarnings`.
    public enum Kind: Sendable, Equatable { case warning(level: Int), reset, test }
    /// `limit.<org>.<kind>.<periodEpoch>`: the same id for every level of one period, so
    /// the 95 replaces the 80 in Notification Center instead of stacking under it.
    /// A reset notice is `reset.<org>.<kind>.<periodEpoch>`.
    public let id: String
    public let kind: Kind
    public let title: String
    public let body: String
    /// nil: now. For `.reset`, the reset instant itself.
    public let deliverAt: Date?
}

/// Decides which readings deserve a notification. Pure: the rows, the settings and
/// `now` go in, notices come out, and the only state is what has been seen per
/// (account, window) since launch.
///
/// The first fresh reading of a window is a silent baseline — after launch, after the
/// account appears, after any `notify*` setting changes. Levels already passed then are
/// on the panel's dot; a warning on every relaunch would be noise. A level crossed while
/// Brow was not running is never announced: the trade for writing no file.
public struct LimitWarnings: Sendable {
    public static let defaultLevels = [80, 95]
    /// The Settings picker's choices, in its order.
    public static let presets: [[Int]] = [[80, 95], [70, 90], [90]]
    /// Two readings of one window whose reset instants are this close are the same
    /// period. Absorbs the endpoint's `…:59.64` vs `:00` (see `Formatting.resetInstant`);
    /// two 5-hour periods are never this close.
    static let samePeriod: TimeInterval = 600

    /// 1...100, unique, ascending; empty -> `defaultLevels`.
    public static func sanitized(_ levels: [Int]) -> [Int] {
        let clean = Set(levels.filter { (1...100).contains($0) }).sorted()
        return clean.isEmpty ? defaultLevels : clean
    }

    private struct Key: Hashable { let org: String; let kind: LimitWindowKind }
    private struct Seen { let period: Date; var highest: Double }
    private struct Config: Equatable { let on: Bool; let levels: [Int]; let resets: Bool }

    private var seen: [Key: Seen] = [:]
    private var config: Config?

    public init() {}

    /// The next fresh reading of every window is a baseline.
    public mutating func reset() { seen.removeAll() }

    public mutating func evaluate(rows: [AccountRow], settings: BrowSettings,
                                  now: Date, timeZone: TimeZone = .current) -> [LimitNotice] {
        let levels = Self.sanitized(settings.notifyThresholds)
        let current = Config(on: settings.notifyLimits, levels: levels, resets: settings.notifyResets)
        if current != config { seen.removeAll(); config = current }
        guard settings.notifyLimits, let lowest = levels.first else { return [] }

        var notices: [LimitNotice] = []
        for row in rows {
            guard let snap = row.snapshot else { continue }
            let scopedModel = snap.weeklyScopedModel ?? "Model"
            let windows: [(LimitWindowKind, CapturedWindow?, Bool, String?)] = [
                (.fiveHour, snap.fiveHour, snap.isStale(now: now), nil),
                (.weekly, snap.sevenDay, snap.isStale(now: now), nil),
                (.weeklyScoped, snap.weeklyScoped, snap.isScopedStale(now: now), scopedModel),
            ]
            for (kind, window, stale, model) in windows {
                // A persisted or stale reading, a window that has not started and one
                // whose reset has passed say nothing about now: no notice, no baseline.
                guard !stale, let window, let reset = Formatting.resetInstant(window.resetsAt), reset > now
                else { continue }
                let key = Key(org: row.id, kind: kind)
                let used = window.usedPercentage
                let baseline: Bool
                let previous: Double
                let period: Date
                switch seen[key] {
                case let entry? where abs(entry.period.timeIntervalSince(reset)) <= Self.samePeriod:
                    (baseline, previous, period) = (false, entry.highest, entry.period)
                case .some:
                    (baseline, previous, period) = (false, 0, reset)   // a new period counts from 0
                case nil:
                    (baseline, previous, period) = (true, used, reset)
                }
                seen[key] = Seen(period: period, highest: max(previous, used))

                // Compared as shown: the panel's "95%" is the rounded figure, and a 79.6
                // that announced 80 must not announce it again at 79.7.
                let shown = used.rounded(), before = previous.rounded()
                let crossed = levels.filter { before < Double($0) && Double($0) <= shown }
                let epoch = Int(period.timeIntervalSince1970)
                if let level = crossed.last {
                    notices.append(LimitNotice(
                        id: "limit.\(row.id).\(kind.rawValue).\(epoch)", kind: .warning(level: level),
                        title: row.name,
                        body: NoticeText.warningBody(used: used, kind: kind, model: model, reset: reset,
                                                     now: now, timeZone: timeZone),
                        deliverAt: nil))
                }
                // Only for a window Brow warned about in this period, or would have.
                let warned = baseline ? shown >= Double(lowest) : crossed.contains(lowest)
                if settings.notifyResets && warned {
                    notices.append(LimitNotice(
                        id: "reset.\(row.id).\(kind.rawValue).\(epoch)", kind: .reset, title: row.name,
                        body: NoticeText.resetBody(kind: kind, model: model), deliverAt: reset))
                }
            }
        }
        // A hidden or removed account's next reading is a baseline again.
        let present = Set(rows.map(\.id))
        seen = seen.filter { present.contains($0.key.org) }
        return notices
    }
}

/// Every word a limit notification says. Pure, like `PanelText`.
public enum NoticeText {
    /// "5-hour limit", "weekly limit", "Fable weekly limit".
    static func windowName(_ kind: LimitWindowKind, model: String?) -> String {
        switch kind {
        case .fiveHour: return "5-hour limit"
        case .weekly: return "weekly limit"
        case .weeklyScoped: return "\(model ?? "Model") weekly limit"
        }
    }

    /// `82% of the 5-hour limit used. Resets at 18:40.` — or, on another day,
    /// `Resets 22 Oct 02:00.`: the date, not the weekday, as in `Formatting.countdown`.
    static func warningBody(used: Double, kind: LimitWindowKind, model: String?, reset: Date,
                            now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        let sameDay = calendar.isDate(reset, inSameDayAs: now)
        f.dateFormat = sameDay ? "HH:mm" : "d MMM HH:mm"
        let when = sameDay ? "at \(f.string(from: reset))" : f.string(from: reset)
        return "\(Formatting.percent(used)) of the \(windowName(kind, model: model)) used. Resets \(when)."
    }

    /// `5-hour limit has reset.` / `Weekly limit has reset.` / `Fable weekly limit has reset.`
    static func resetBody(kind: LimitWindowKind, model: String?) -> String {
        let name = windowName(kind, model: model)
        return name.prefix(1).uppercased() + name.dropFirst() + " has reset."
    }

    /// `[80, 95]` -> "80% and 95%", `[90]` -> "90%", `[70, 80, 90]` -> "70%, 80% and 90%".
    static func levels(_ levels: [Int]) -> String {
        let items = levels.map { "\($0)%" }
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
    }

    static func testBody(levels: [Int]) -> String {
        "Test: limit warnings are on. Brow warns at \(Self.levels(levels))."
    }
}
