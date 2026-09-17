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
    /// Samples `now` immediately: the controller stops the clock on collapse, so
    /// without this the first rendered frame of every expand computed its countdowns
    /// and ages against the instant the panel last CLOSED ("resets in 2 h 10 min" for
    /// a window resetting in 40 min). It self-corrected after a second — about as long
    /// as a hover panel is looked at.
    public func start() {
        now = source()
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
    /// How far the first row starts below the window's top edge — `notch height + 8`
    /// from `NotchGeometry`. The panel hangs off the screen edge, so without it the
    /// "Overall" line sat *under* the notch and the Weekly/Fable numbers were hidden
    /// behind the camera. The black fills the inset too: this is one continuous shape
    /// growing out of the notch, not a card floating below it.
    let topInset: CGFloat
    let onSettings: () -> Void
    let onRefresh: () -> Void

    public init(store: LimitsStore, clock: PanelClock, topInset: CGFloat,
                onSettings: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.topInset = topInset
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
        // The inset REPLACES the top padding rather than stacking on it: `contentTopInset`
        // is already "notch + 8 pt of breathing room", and the height model below is
        // sized from the same two numbers.
        .padding(EdgeInsets(top: topInset, leading: 14, bottom: 14, trailing: 14))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        // Same outline as the collapsed strip, with the wider bottom radius the spec
        // gives the panel; the fill is behind the clip, so the black — inset included —
        // is what gets the flared top corners.
        .clipShape(NotchShape(topFlare: NotchGeometry.flare, bottomRadius: NotchGeometry.expandedBottomRadius))
    }

    private var overall: some View {
        HStack(spacing: 14) {
            Text("Overall").font(.system(size: 12, weight: .semibold))
            Spacer()
            // Greyed out when the aggregate is stale: a three-day-old 32 % must not
            // render as confident green (spec, Staleness).
            stat("5h", store.aggregate.fiveHour)
            stat("Weekly", store.aggregate.weekly)
            if let s = store.aggregate.weeklyScoped { stat(s.model, s.percentage) }
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        let readout = EarReadout(usedPercentage: value, modelInitial: nil,
                                 severity: LimitsAggregate.severity(value), stale: store.aggregate.stale)
        // Same rule as the ears, one inch away from them: with no snapshot behind it the
        // aggregate is 0, and the panel must not contradict the `—` in the notch.
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(PanelText.earsText(readout, hasData: store.aggregate.hasData))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(store.aggregate.hasData ? EarsView.color(for: readout) : Color.gray)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // One line, the age first and an error only after it (spec, What the user
            // sees). The error used to take the whole line, which hid the one fact that
            // decides whether the numbers above it can be trusted. `panelError` is the
            // configuration error while it is live, the fetch error otherwise — the
            // spec's error table names this footer as one of the two slots for
            // "`claude` not found".
            HStack(spacing: 4) {
                if store.panelError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Text(PanelText.footer(dataAsOf: store.dataAsOf, error: store.panelError, now: clock.now))
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(store.panelError == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            // The button STAYS: a background poll (every 120 s, or every 60 s while the
            // panel is open) must not take the only manual refresh off the screen. The
            // spinner marks a forced fetch only.
            Button(action: onRefresh) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(store.isForcing ? 0 : 1)
                    if store.isForcing { ProgressView().controlSize(.mini) }
                }
                .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(store.isRefreshing).help("Refresh now")
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Settings")
        }
    }
}
