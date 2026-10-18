// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

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
    /// The way into Workspaces, and the one that is always there: macOS hides a status
    /// item that does not fit beside the notch. Left of share, so ⟳ keeps its place at
    /// the corner (`PanelRefreshGateTests`). nil: no button.
    let onWorkspaces: (() -> Void)?
    /// The calendar's hovered day, driven by the controller's mouse monitor.
    @ObservedObject var hover: CalendarHoverTracker
    /// The pet's words and meter for the header row; nil where the panel is drawn without a pet.
    let pet: PetPanelModel?
    /// The share button's checkmark, like the copy button's in `AccountBlockView`.
    @State private var copiedCard = false

    /// The panel's own top/bottom/side padding. `topInset` is the notch clearance and
    /// REPLACES the top padding, so on a screen with no notch to clear (inset 8) it
    /// has to be floored here or the panel reads 8 pt top against 14 pt bottom.
    static let padding: CGFloat = 14

    public init(store: LimitsStore, clock: PanelClock, topInset: CGFloat, flare: CGFloat,
                drawsBackground: Bool = true, hover: CalendarHoverTracker = CalendarHoverTracker(),
                pet: PetPanelModel? = nil, onSettings: @escaping () -> Void, onRefresh: @escaping () -> Void,
                onWorkspaces: (() -> Void)? = nil) {
        self.store = store
        self.clock = clock
        self.topInset = topInset
        self.flare = flare
        self.drawsBackground = drawsBackground
        self.hover = hover
        self.pet = pet
        self.onSettings = onSettings
        self.onRefresh = onRefresh
        self.onWorkspaces = onWorkspaces
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The pet's row, first, while the pet is on. Its own view, so the words re-render it alone.
            if let pet, store.settings.showPet {
                PetHeaderRow(model: pet)
            }
            overall
            Divider().overlay(Color.white.opacity(0.15))
            if store.rows.isEmpty {
                Text("No Claude accounts found").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.rows) { row in
                AccountBlockView(row: row, now: clock.now,
                                 claudePath: store.settings.claudePath ?? store.claudeDetected ?? "claude",
                                 onGrant: { [store] in Task { await store.grantKeychainAccess(row.account) } })
                Divider().overlay(Color.white.opacity(0.15))
            }
            if store.settings.showCalendar, !store.rows.isEmpty {
                CalendarView(rows: store.rows, now: clock.now, hover: hover)
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
        .onPreferenceChange(PetFiveHourFrame.self) { [pet] rect in
            if let rect { MainActor.assumeIsolated { pet?.fiveHourFrameChanged(rect) } }
        }
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
            stat("5h", store.aggregate.fiveHour, reportsFrame: pet != nil)
            stat("Weekly", store.aggregate.weekly)
            if let s = store.aggregate.weeklyScoped { stat(s.model, s.percentage) }
        }
    }

    /// `reportsFrame`: the 5-hour figure is where the pet's food comes from in the panel, so its frame
    /// goes up as a preference, the way `CalendarView` reports its cells.
    private func stat(_ label: String, _ value: Double, reportsFrame: Bool = false) -> some View {
        let readout = EarReadout(usedPercentage: value, modelInitial: nil,
                                 severity: LimitsAggregate.severity(value), stale: store.aggregate.stale)
        // Same rule as the ears, one inch away from them: with no snapshot behind it the
        // aggregate is 0, and the panel must not contradict the `—` in the notch.
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(PanelText.earsText(readout, hasData: store.aggregate.hasData))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(store.aggregate.hasData ? EarsView.color(for: readout) : Color.gray)
                .background {
                    if reportsFrame {
                        GeometryReader { geo in Color.clear.preference(key: PetFiveHourFrame.self, value: geo.frame(in: .global)) }
                    }
                }
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
            if let onWorkspaces {
                Button(action: onWorkspaces) {
                    Image(systemName: "square.stack.3d.up")
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Workspaces")
            }
            // Left of ⟳ on purpose: `PanelRefreshGateTests` finds ⟳ at a fixed offset
            // from the bottom-right corner. The clipboard needs no activation, so this
            // works from the non-activating panel; saving a file lives in Settings.
            Button {
                guard let png = WeekCardExport.png(store: store, now: clock.now) else { return }
                WeekCardExport.copy(png)
                copiedCard = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copiedCard = false
                }
            } label: {
                Image(systemName: copiedCard ? "checkmark" : "square.and.arrow.up")
                    .foregroundStyle(copiedCard ? Color.green : Color.white)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!store.aggregate.hasData).help("Copy my week as an image")
            // The button STAYS: the 30 s background poll must not take the only manual
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

/// The Overall line's "5h" figure, in the hosting view's space (window coordinates): the pet's food
/// source in the panel.
struct PetFiveHourFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

/// The pet's row at the top of the panel: the stage the pet layer draws in, the state word, the detail and
/// the moment line, and the hunger meter with no number. One VoiceOver element for all of it, whose action
/// boops the pet.
struct PetHeaderRow: View {
    @ObservedObject var model: PetPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private typealias P = PetTuning.Panel

    var body: some View {
        HStack(alignment: .center, spacing: P.rowSpacing) {
            // The pet layer draws here; the stage only holds the place, and its tooltip is the detail.
            Color.clear
                .frame(width: P.stageWidth, height: P.stageHeight)
                .contentShape(Rectangle())
                .help(model.header.detail)
            VStack(alignment: .leading, spacing: P.textSpacing) {
                Text(model.header.word).font(.system(size: P.wordSize, weight: .semibold)).foregroundStyle(.white)
                Text(model.header.detail).font(.system(size: P.detailSize)).foregroundStyle(.secondary).lineLimit(1)
                if let moment = model.header.moment {
                    Text(moment).font(.system(size: P.detailSize)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: P.spacerMinimum)
            VStack(alignment: .trailing, spacing: P.meterSpacing) {
                Text("Hunger").font(.system(size: P.detailSize)).foregroundStyle(.secondary)
                meter
            }
        }
        .frame(height: P.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PetText.label)
        .accessibilityValue(model.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: PetText.actionName) { model.boop() }
    }

    /// 120 × 6 pt: the track, the fill in the pet's own light (never a severity colour, which would read
    /// as a limit), the two mood thresholds. Under Reduce Motion it changes without animating.
    private var meter: some View {
        let fill = P.meterWidth * min(max(model.meter, 0), 100) / 100
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(P.meterTrackOpacity))
            Rectangle().fill(PetPalette.standard.colors.glow.color(opacity: P.meterFillOpacity))
                .frame(width: fill)
            ForEach(P.meterTicks, id: \.self) { tick in
                Rectangle().fill(Color.white.opacity(P.tickOpacity))
                    .frame(width: P.tickWidth, height: P.meterHeight)
                    .offset(x: P.meterWidth * tick / 100 - P.tickWidth / 2)
            }
        }
        .frame(width: P.meterWidth, height: P.meterHeight)
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeInOut(duration: P.meterAnimation), value: model.meter)
    }
}
