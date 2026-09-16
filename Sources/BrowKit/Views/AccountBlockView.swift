import SwiftUI
import GroveCore

/// One account: header line + up to three bars (5h, weekly, model weekly).
public struct AccountBlockView: View {
    let row: AccountRow
    let now: Date

    public init(row: AccountRow, now: Date) {
        self.row = row
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(tag).font(.system(size: 10)).foregroundStyle(tagColor).lineLimit(1)
            }
            bar("5h", row.snapshot?.fiveHour)
            bar("Weekly", row.snapshot?.sevenDay)
            if let scoped = row.snapshot?.weeklyScoped {
                bar(row.snapshot?.weeklyScopedModel ?? "Model", scoped)
            }
        }
    }

    private var tag: String {
        let tier = Self.tierLabel(row.account.tier)
        switch row.status {
        case .ok: return tier
        case .stale: return row.snapshot.map { "\(tier) · \(Formatting.age($0.fetchedAt, now: now))" } ?? "\(tier) · no data"
        case .error(let text): return "\(tier) · \(text)"
        }
    }
    private var tagColor: Color {
        switch row.status { case .ok: return .secondary; case .stale: return .secondary; case .error: return .orange }
    }

    static func tierLabel(_ tier: String?) -> String {
        switch tier {
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_max_5x":  return "Max 5x"
        case "default_claude_pro":     return "Pro"
        case nil: return "—"
        case let t?: return t
        }
    }

    private func bar(_ title: String, _ window: CapturedWindow?) -> some View {
        let used = window?.usedPercentage ?? 0
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(EarsView.color(for: EarReadout(usedPercentage: used, modelInitial: nil,
                                                                 severity: LimitsAggregate.severity(used), stale: false)))
                        .frame(width: max(0, geo.size.width * used / 100))
                }
            }
            .frame(height: 6)
            Text(window.map { Formatting.percent($0.usedPercentage) } ?? "—")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 36, alignment: .trailing)
            Text(window.map { Formatting.countdown($0.resetsAt, now: now) } ?? "not started")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).lineLimit(1)
        }
    }
}
