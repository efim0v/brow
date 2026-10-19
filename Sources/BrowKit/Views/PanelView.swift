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

/// The Limits section drawn on its own, unscrolled: the header (the pet's row and the
/// Overall line), every account and the month, and the footer. What the notch shows on
/// Limits, for the places that draw the panel without the notch around it: the tests and
/// the offscreen renders. The notch itself draws the same parts through `NotchShellView`.
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
    /// the un-widened 460 pt and `frames.flare` is 0.
    let flare: CGFloat
    /// False when something around this panel draws the black and the outline; true when
    /// the panel is on its own, e.g. in tests.
    let drawsBackground: Bool
    let onSettings: () -> Void
    let onRefresh: () -> Void
    /// The calendar's hovered day, driven by the controller's mouse monitor.
    @ObservedObject var hover: CalendarHoverTracker
    /// The pet's words and meter for the header row; nil where the panel is drawn without a pet.
    let pet: PetPanelModel?

    /// The panel's own padding, and the floor under the top inset on a screen with no notch
    /// to clear (inset 8).
    static let padding: CGFloat = NotchShellLayout.side

    public init(store: LimitsStore, clock: PanelClock, topInset: CGFloat, flare: CGFloat,
                drawsBackground: Bool = true, hover: CalendarHoverTracker = CalendarHoverTracker(),
                pet: PetPanelModel? = nil, onSettings: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.topInset = topInset
        self.flare = flare
        self.drawsBackground = drawsBackground
        self.hover = hover
        self.pet = pet
        self.onSettings = onSettings
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitsContent(store: store, clock: clock, hover: hover, pet: pet, scrolls: false)
            Color.clear.frame(height: NotchShellLayout.contentBottomGap)
            NotchFooter(status: AnyView(LimitsFooterStatus(store: store, clock: clock)),
                        accessory: AnyView(LimitsShareButton(store: store, clock: clock)),
                        refresh: AnyView(LimitsRefreshButton(store: store, action: onRefresh)),
                        pinned: false, showsKeys: false,
                        onPin: {}, onSettings: onSettings, onQuit: {})
        }
        // The inset REPLACES the top padding rather than stacking on it: `contentTopInset`
        // is already "notch + 8 pt of breathing room". 14 pt from the frame's own edges, where
        // the pet's default stage is (`PetLayout.panelZone`); the notch insets its sections
        // from the black instead (`NotchShellLayout.contentInsetX`).
        .padding(EdgeInsets(top: max(topInset, Self.padding), leading: Self.padding,
                            bottom: 0, trailing: Self.padding))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .background { if drawsBackground { Color.black } }
        // Same outline as the open notch; inside `NotchRootView` the animated outline does
        // the clipping instead.
        .clipShape(drawsBackground ? outline : AnyShape(Rectangle()))
    }

    /// The notch outline where there is a notch; on a display without one, square at the
    /// top (it hangs from the screen's edge) and continuous at the bottom.
    private var outline: AnyShape {
        flare > 0
            ? AnyShape(NotchShape(topFlare: flare, bottomRadius: NotchGeometry.expandedBottomRadius))
            : AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: NotchGeometry.expandedBottomRadius,
                                              bottomTrailingRadius: NotchGeometry.expandedBottomRadius,
                                              topTrailingRadius: 0, style: .continuous))
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
