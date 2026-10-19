// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Combine
import GroveAppKit
import SwiftUI

/// The Limits section: the pet's row and the Overall line as a fixed header, the accounts and
/// the month under it. Only the part under the header scrolls, so the "5h" figure the pet
/// eats from never moves and no hop depends on scrolling.
@MainActor
final class LimitsSection: NotchSection {
    let store: LimitsStore
    let clock: PanelClock
    let hover: CalendarHoverTracker
    let pet: PetPanelModel?
    private let onRefresh: () -> Void

    init(store: LimitsStore, clock: PanelClock, hover: CalendarHoverTracker, pet: PetPanelModel?,
         onRefresh: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.hover = hover
        self.pet = pet
        self.onRefresh = onRefresh
    }

    func content(layout: NotchShellLayout) -> AnyView {
        AnyView(LimitsContent(store: store, clock: clock, hover: hover, pet: pet, scrolls: true))
    }

    func footerStatus() -> AnyView { AnyView(LimitsFooterStatus(store: store, clock: clock)) }
    func footerAccessory() -> AnyView { AnyView(LimitsShareButton(store: store, clock: clock)) }
    func refreshButton() -> AnyView { AnyView(LimitsRefreshButton(store: store, action: onRefresh)) }
    func refresh() {
        // The same gate as the button: one forced fetch at a time.
        guard !store.isForcing, store.pendingRetryAt == nil else { return }
        onRefresh()
    }

    /// The section as laid out unscrolled at `width`: what sizes the panel.
    func measuringView(width: CGFloat) -> some View {
        // The pet's words size its row, but this copy must not tell the pet where the "5h"
        // figure is: its frames are in the sizing view's space, not the panel's.
        LimitsContent(store: store, clock: clock, hover: CalendarHoverTracker(), pet: pet, scrolls: false,
                      reportsPetFrame: false)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark)
    }
}

/// The Limits section's content: `LimitsHeader` over `LimitsBody`. `scrolls`: the body
/// scrolls under the header (the notch); false lays everything out unscrolled (the
/// measurement, `PanelView`).
struct LimitsContent: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var clock: PanelClock
    @ObservedObject var hover: CalendarHoverTracker
    let pet: PetPanelModel?
    let scrolls: Bool
    /// Tells the pet where the Overall line's "5h" figure is (`PetFiveHourFrame`). False for a
    /// copy laid out anywhere but the panel itself.
    var reportsPetFrame = true
    /// Offscreen renders of a scrolled panel: how far the body is scrolled.
    var renderOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitsHeader(store: store, pet: pet, reportsPetFrame: reportsPetFrame)
            if scrolls {
                FadingScrollView(renderOffset: renderOffset) {
                    LimitsBody(store: store, clock: clock, hover: hover)
                        .padding(.vertical, 10)
                }
            } else {
                LimitsBody(store: store, clock: clock, hover: hover)
                    .padding(.vertical, 10)
            }
        }
        .foregroundStyle(.white)
    }
}

/// The pet's row, while the pet is on, then the Overall line and a hairline.
struct LimitsHeader: View {
    @ObservedObject var store: LimitsStore
    let pet: PetPanelModel?
    var reportsPetFrame = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Its own view, so the words re-render it alone.
            if let pet, store.settings.showPet {
                PetHeaderRow(model: pet)
            }
            overall
            Divider().overlay(Color.white.opacity(0.15))
        }
        .onPreferenceChange(PetFiveHourFrame.self) { [pet, reportsPetFrame] rect in
            guard reportsPetFrame, let rect else { return }
            MainActor.assumeIsolated { pet?.fiveHourFrameChanged(rect) }
        }
    }

    private var overall: some View {
        HStack(spacing: 14) {
            Text("Overall").font(.system(size: 12, weight: .semibold))
            Spacer()
            // Greyed out when the aggregate is stale: a three-day-old 32 % must not
            // render as confident green (spec, Staleness).
            stat("5h", store.aggregate.fiveHour, reportsFrame: pet != nil && reportsPetFrame)
            stat("Weekly", store.aggregate.weekly)
            if let s = store.aggregate.weeklyScoped { stat(s.model, s.percentage) }
        }
        .frame(height: 20)
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
}

/// Every visible account, then the month.
struct LimitsBody: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var clock: PanelClock
    @ObservedObject var hover: CalendarHoverTracker
    /// At most this many account cards beside the month: a day on which every account
    /// resets cannot make the month taller than its grid (`CalendarView`).
    static let maxDayCards = 3

    var body: some View {
        let showsCalendar = store.settings.showCalendar && !store.rows.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            if store.rows.isEmpty {
                Text("No Claude accounts found").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                AccountBlockView(row: row, now: clock.now,
                                 claudePath: store.settings.claudePath ?? store.claudeDetected ?? "claude",
                                 onGrant: { [store] in Task { await store.grantKeychainAccess(row.account) } })
                if index < store.rows.count - 1 || showsCalendar {
                    Divider().overlay(Color.white.opacity(0.15))
                }
            }
            if showsCalendar {
                CalendarView(rows: store.rows, now: clock.now, hover: hover, maxDayCards: Self.maxDayCards)
            }
        }
    }
}

/// The footer's line on Limits: the age of the numbers first, and an error only after it.
struct LimitsFooterStatus: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var clock: PanelClock

    var body: some View {
        // One line, the age first and an error only after it (spec, What the user sees). The
        // error used to take the whole line, which hid the one fact that decides whether the
        // numbers above it can be trusted. `panelError` is the configuration error while it is
        // live, the fetch error otherwise.
        HStack(spacing: 4) {
            if store.panelError != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(PanelText.footer(dataAsOf: store.dataAsOf, error: store.panelError,
                                  retryAt: store.pendingRetryAt, now: clock.now))
                .font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
                .foregroundStyle(store.panelError == nil ? NotchTheme.secondary() : Color.orange)
        }
    }
}

/// Copies "my week" as an image. The clipboard needs no activation, so this works from the
/// non-activating panel; saving a file lives in Settings.
struct LimitsShareButton: View {
    @ObservedObject var store: LimitsStore
    @ObservedObject var clock: PanelClock
    /// A checkmark for a moment, like the copy button's in `AccountBlockView`.
    @State private var copied = false

    var body: some View {
        Button {
            guard let png = WeekCardExport.png(store: store, now: clock.now) else { return }
            WeekCardExport.copy(png)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            NotchIconLabel(symbol: copied ? "checkmark" : "square.and.arrow.up",
                           color: copied ? Color.green : Color.white.opacity(0.78))
        }
        .buttonStyle(.plain)
        .disabled(!store.aggregate.hasData)
        .help("Copy my week as an image")
        .accessibilityLabel("Copy my week as an image")
    }
}

/// ⟳ on Limits. The button STAYS: the 30 s background poll must not take the only manual
/// refresh off the screen. `isForcing` is the ONLY gate (spec, The cycle §7): `isRefreshing`
/// is true for every background cycle and must never reach `.disabled`. A refresh queued
/// behind the rate limit (`pendingRetryAt`) is a forced refresh that has not finished: same
/// spinner, same gate. Pinned by PanelRefreshGateTests.
struct LimitsRefreshButton: View {
    @ObservedObject var store: LimitsStore
    let action: () -> Void

    var body: some View {
        let busy = store.isForcing || store.pendingRetryAt != nil
        Button(action: action) {
            ZStack {
                NotchIconLabel(symbol: "arrow.clockwise").opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.mini) }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Refresh now (⌘R)")
        .accessibilityLabel("Refresh now")
    }
}
