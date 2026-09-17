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
    /// How much of each side of the window `NotchShape`'s concave flares occupy —
    /// `NotchFrames.flare`, NOT the constant. On a screen with no notch the frame is
    /// the un-widened 460 pt and `frames.flare` is 0: clipping that with a 6 pt flare
    /// nicked ~6 pt of black out of each top corner of a panel that has no notch to
    /// match, above a collapsed pill whose corners are square.
    let flare: CGFloat
    /// False when `NotchRootView` hosts this panel inside its own animated outline
    /// (the one that grows out of the notch on hover); true when the panel is on its
    /// own, e.g. in tests.
    let drawsBackground: Bool
    let onSettings: () -> Void
    let onRefresh: () -> Void

    /// The panel's own top/bottom/side padding. `topInset` is the notch clearance and
    /// REPLACES the top padding, so on a screen with no notch to clear (inset 8) it
    /// has to be floored here or the panel reads 8 pt top against 14 pt bottom.
    static let padding: CGFloat = 14

    public init(store: LimitsStore, clock: PanelClock, topInset: CGFloat, flare: CGFloat,
                drawsBackground: Bool = true,
                onSettings: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.topInset = topInset
        self.flare = flare
        self.drawsBackground = drawsBackground
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
                AccountBlockView(row: row, now: clock.now,
                                 claudePath: store.settings.claudePath ?? store.claudeDetected ?? "claude")
                Divider().overlay(Color.white.opacity(0.15))
            }
            if store.settings.showCalendar, !store.rows.isEmpty {
                CalendarView(rows: store.rows, now: clock.now)
                Divider().overlay(Color.white.opacity(0.15))
            }
            footer
        }
        // The inset REPLACES the top padding rather than stacking on it: `contentTopInset`
        // is already "notch + 8 pt of breathing room", and the height model below is
        // sized from the same two numbers.
        .padding(EdgeInsets(top: max(topInset, Self.padding), leading: Self.padding,
                            bottom: Self.padding, trailing: Self.padding))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .background { if drawsBackground { Color.black } }
        // Same outline as the collapsed strip, with the wider bottom radius the spec
        // gives the panel; the fill is behind the clip, so the black — inset included —
        // is what gets the flared top corners. Inside `NotchRootView` the animated
        // outline does the clipping instead.
        .clipShape(drawsBackground ? outline : AnyShape(Rectangle()))
    }

    /// The notch outline where there is a notch; the pill's rounded rectangle — the very
    /// shape `EarsView` draws collapsed — where there is not.
    private var outline: AnyShape {
        flare > 0
            ? AnyShape(NotchShape(topFlare: flare, bottomRadius: NotchGeometry.expandedBottomRadius))
            : AnyShape(RoundedRectangle(cornerRadius: NotchGeometry.collapsedBottomRadius, style: .continuous))
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
                Text(PanelText.footer(dataAsOf: store.dataAsOf, error: store.panelError,
                                      retryAt: store.pendingRetryAt, now: clock.now))
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(store.panelError == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            // The button STAYS: the 60 s background poll must not take the only manual
            // refresh off the screen — a cycle is budgeted at up to 210 s of CLI work,
            // and a dead ⟳ for minutes at a time is the failure this whole spec exists
            // to fix. `isForcing` is the ONLY gate (spec, The cycle §7): `isRefreshing`
            // is true for every background cycle and must never reach `.disabled`.
            // Pinned by PanelRefreshGateTests.
            // A refresh queued behind the rate limit (`pendingRetryAt`) is a forced
            // refresh that has not finished: same spinner, same gate, and the footer
            // says when it will go out.
            let busy = store.isForcing || store.pendingRetryAt != nil
            Button(action: onRefresh) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(busy ? 0 : 1)
                    if busy { ProgressView().controlSize(.mini) }
                }
                .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy).help("Refresh now")
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Settings")
        }
    }
}
