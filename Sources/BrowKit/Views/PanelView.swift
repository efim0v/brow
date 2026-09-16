import SwiftUI
import Combine

/// Ticks once a second so countdowns and ages move without a network round-trip.
@MainActor
public final class PanelClock: ObservableObject {
    @Published public private(set) var now: Date
    private var timer: Timer?
    private let source: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = now
        self.now = now()
    }
    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = self?.source() ?? Date() }
        }
    }
    public func stop() { timer?.invalidate(); timer = nil }
}

/// The expanded panel: overall line, one block per account, footer.
public struct PanelView: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var clock: PanelClock
    let onSettings: () -> Void
    let onRefresh: () -> Void

    public init(store: LimitsStore, clock: PanelClock, onSettings: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.onSettings = onSettings
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            overall
            Divider().overlay(Color.white.opacity(0.15))
            if store.rows.isEmpty {
                Text("No Claude accounts found").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.rows) { row in
                AccountBlockView(row: row, now: clock.now)
                Divider().overlay(Color.white.opacity(0.15))
            }
            footer
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(Color.black)
    }

    private var overall: some View {
        HStack(spacing: 14) {
            Text("Overall").font(.system(size: 12, weight: .semibold))
            Spacer()
            stat("5h", store.aggregate.fiveHour)
            stat("Weekly", store.aggregate.weekly)
            if let s = store.aggregate.weeklyScoped { stat(s.model, s.percentage) }
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Formatting.percent(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(EarsView.color(for: EarReadout(usedPercentage: value, modelInitial: nil,
                                                               severity: LimitsAggregate.severity(value), stale: false)))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = store.footerError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            } else {
                Text(store.dataAsOf.map { "Updated \(Formatting.age($0, now: clock.now))" } ?? "No data yet")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Refresh now")
            }
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Settings")
        }
    }
}
