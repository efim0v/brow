import Foundation

/// Every string the notch puts on screen, in one pure place. The views below hold
/// no string logic of their own: the age is the single most load-bearing thing Brow
/// says — a confident `32 %` over a three-day-old capture is worse than no number —
/// and a rule that lives in three view bodies is a rule that drifts in three view
/// bodies. `now` is always injected so the tests never look at the wall clock.
public enum PanelText {

    /// The panel's one-line footer. The age comes FIRST and never gives up its slot:
    /// an error that takes the whole line (the old behaviour) hides exactly the fact
    /// that decides whether the numbers above it can be trusted.
    /// `"Updated 3 h ago"` / `"Updated 3 h ago · Offline"` / `"No data yet · Offline"` / `"No data yet"`.
    public static func footer(dataAsOf: Date?, error: String?, now: Date) -> String {
        footer(dataAsOf: dataAsOf, error: error, retryAt: nil, now: now)
    }

    /// With a refresh queued behind the endpoint's rate limit, the line says WHEN
    /// instead of just "rate limited": `Updated 2 min ago · retrying in 47 s`. The
    /// countdown replaces the rate-limit error text (it is the same fact, with a time
    /// on it); any other error still follows the age.
    public static func footer(dataAsOf: Date?, error: String?, retryAt: Date?, now: Date) -> String {
        let age = dataAsOf.map { "Updated \(Formatting.age($0, now: now))" } ?? "No data yet"
        if let retryAt {
            let seconds = max(0, Int(retryAt.timeIntervalSince(now).rounded(.up)))
            return "\(age) · retrying in \(seconds) s"
        }
        guard let error, !error.isEmpty else { return age }
        return "\(age) · \(error)"
    }

    /// One account's tag: tier, then the age of what is still on screen, then why the
    /// last fetch failed. A failed fetch keeps its snapshot, so it keeps its age too —
    /// `Max 20x · 3 d ago · sign-in expired`, never a bare error over stale bars.
    public static func accountTag(tier: String?, snapshot: LimitSnapshot?,
                                  status: AccountStatus, now: Date) -> String {
        let label = tierLabel(tier)
        // "no data" rather than an invented age: nothing was ever captured for this one.
        let age = snapshot.map { Formatting.age($0.fetchedAt, now: now) } ?? "no data"
        switch status {
        case .ok: return label
        case .stale: return "\(label) · \(age)"
        case .error(let text): return "\(label) · \(age) · \(text)"
        }
    }

    public static func tierLabel(_ tier: String?) -> String {
        switch tier {
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_max_5x":  return "Max 5x"
        case "default_claude_pro":     return "Pro"
        case nil: return "—"
        case let t?: return t
        }
    }

    /// An ear's readout. Without a single snapshot behind it the aggregate is a
    /// weighted average of nothing, which arrives as `0` — and `0 %` in the notch
    /// reads as "you have used none of your limit", the most confident lie Brow
    /// could tell. It shows `—` instead (the caller greys the dot).
    public static func earsText(_ ear: EarReadout?, hasData: Bool) -> String {
        guard let ear, hasData else { return "—" }
        return Formatting.percent(ear.usedPercentage)
    }
}
