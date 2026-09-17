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
        PanelText.accountTag(tier: row.account.tier, snapshot: row.snapshot, status: row.status, now: now)
    }
    private var tagColor: Color {
        switch row.status { case .ok: return .secondary; case .stale: return .secondary; case .error: return .orange }
    }

    /// A row whose snapshot is past `staleAfter` shows grey bars, the same signal the
    /// ears carry; the age itself is already in the tag. Asking the SNAPSHOT, not the
    /// status: `.error` outranks `.stale` in `LimitsStore.row(for:)`, so a failed fetch
    /// over a three-day-old capture used to paint it confident green.
    private var isStale: Bool { row.snapshot?.isStale(now: now) ?? true }

    private func bar(_ title: String, _ window: CapturedWindow?) -> some View {
        let used = window?.usedPercentage ?? 0
        let stale = isStale
        return HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(EarsView.color(for: EarReadout(usedPercentage: used, modelInitial: nil,
                                                                 severity: LimitsAggregate.severity(used), stale: stale)))
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
