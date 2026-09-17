import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that sits over the menu bar / notch.
final class BrowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel never becomes key, so every click in it is a "first mouse" — which a
/// plain `NSHostingView` declines, leaving the ⟳ and ⚙ buttons (the only route to
/// Settings, and through `NSApp.activate` the only route to the Quit menu item) dead.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel, swaps collapsed ↔ expanded content on hover, and keeps its
/// frame in sync with the main screen. All state changes go through `expanded`.
@MainActor
public final class NotchPanelController {
    public static let collapseDelay: TimeInterval = 0.5
    public static let animation: TimeInterval = 0.18

    private let store: LimitsStore
    private let clock: PanelClock
    private let onExpandedChange: (Bool) -> Void
    private let onSettings: () -> Void
    private let panel: BrowPanel
    private let host: FirstMouseHostingView<AnyView>
    private var frames: NotchFrames
    private var expanded = false
    private var collapseWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    public init(store: LimitsStore, clock: PanelClock, onExpandedChange: @escaping (Bool) -> Void,
                onSettings: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.onExpandedChange = onExpandedChange
        self.onSettings = onSettings
        // The placement from the first frame on: the panel's contentRect is built from
        // this, and a `below` user would otherwise see one beside-shaped strip flash
        // before the first render().
        self.frames = NotchGeometry.frames(for: Self.metrics(), expandedHeight: 200,
                                           placement: store.settings.earsPlacement)
        panel = BrowPanel(contentRect: frames.collapsed,
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Collapsed, the panel is an opaque strip lying over the menu bar (the notch
        // ± 96 pt, or a 180 pt pill) at `.statusBar + 1`, and it can never become key:
        // any click it receives does nothing AND never reaches the menu bar under it.
        // Spec: "ignoring mouse events except on its own content". Hover detection is
        // a global monitor reading `NSEvent.mouseLocation`, so expansion still works
        // with hit-testing off; `setExpanded` turns it back on for the real content.
        panel.ignoresMouseEvents = true
        // The ears and the panel are drawn on black; `.secondary` text only reads
        // as light grey in a dark appearance, so the host never inherits a light one.
        panel.appearance = NSAppearance(named: .darkAqua)
        host = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.render() }
        }.store(in: &cancellables)
    }

    public func show() {
        render()
        panel.orderFrontRegardless()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.mouseMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.mouseMoved() }
            return event
        }
    }

    /// Tears down the global monitors and any pending collapse. Without this the two
    /// `NSEvent` monitors installed by `show()` outlive the controller.
    public func hide() {
        collapseWork?.cancel(); collapseWork = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        panel.orderOut(nil)
    }

    /// The display changed: re-render, don't just move the window. The hosted view
    /// carries the previous screen's `earWidth`/`hasNotch` until it is rebuilt.
    public func relayout() {
        render()
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        let hot = expanded ? frames.expanded : frames.collapsed
        if hot.contains(point) {
            collapseWork?.cancel(); collapseWork = nil
            if !expanded { setExpanded(true) }
        } else if expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.setExpanded(false) } }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        collapseWork = nil
        // Expanded, the panel owns its clicks (⟳ and ⚙); collapsed, it must let the
        // menu bar underneath have them.
        panel.ignoresMouseEvents = !value
        if value { clock.start() } else { clock.stop() }
        onExpandedChange(value)
        render()
        BrowLog.panel.debug("expanded=\(value)")
    }

    private func render() {
        // Geometry FIRST: the content is built from `frames`, so recomputing after
        // the fact left the hosted view carrying the previous screen's earWidth and
        // hasNotch until a later publish — two store publishes (~240 s) behind.
        let metrics = Self.metrics()
        // Read LIVE, every render: the store publishes on every settings write, and this
        // is what turns the Ears picker into a reshaped strip without a relaunch.
        let placement = store.settings.earsPlacement
        frames = NotchGeometry.frames(for: metrics, expandedHeight: frames.expanded.height, placement: placement)
        if expanded {
            host.rootView = AnyView(PanelView(store: store, clock: clock, topInset: frames.contentTopInset,
                                              // The frame's OWN flare, not the constant: an
                                              // external display's frame carries none.
                                              flare: frames.flare,
                                              onSettings: onSettings,
                                              onRefresh: { [store] in Task { await store.refresh(force: true) } })
                // The flare-widened frame, not `expandedWidth`: `NotchShape` draws its
                // concave corners in those 6 pt, and the visible black still starts at
                // the notch edge.
                .frame(width: frames.expanded.width))
        } else {
            host.rootView = AnyView(EarsView(aggregate: store.aggregate, frames: frames)
                .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        }
        // …then size the window to the tree that was just installed.
        frames = NotchGeometry.frames(for: metrics, expandedHeight: expandedHeight(), placement: placement)
        applyFrame(animated: true)
    }

    private func expandedHeight() -> CGFloat {
        guard expanded else { return frames.expanded.height }
        // `fittingSize` read in the same turn `rootView` was assigned reports the OLD
        // tree, which opened the first hover at the 120 pt floor and cut off the
        // footer — the only ⟳ and ⚙ buttons there are.
        host.layoutSubtreeIfNeeded()
        let modelled = Self.estimatedExpandedHeight(barCounts: store.rows.map(Self.barCount),
                                                    topInset: frames.contentTopInset)
        return max(120, max(modelled, host.fittingSize.height))
    }

    /// A layout-independent floor for the expanded panel, from the model PanelView
    /// draws: the top inset that keeps the content clear of the notch, 14 pt of bottom
    /// padding, the Overall line, one block per account (header + bars) each followed
    /// by a divider, and the footer, with 10 pt stack spacing. The inset is PanelView's
    /// whole top padding, so it is added, not stacked on a second 14.
    ///
    /// Deliberately WITHOUT `PanelView`'s `max(topInset, 14)` floor: this is a floor,
    /// and `expandedHeight()` takes `max(modelled, fittingSize)`, so the laid-out tree —
    /// which does carry the floor — wins on the only path where the two differ (a screen
    /// with no notch, inset 8).
    static func estimatedExpandedHeight(barCounts: [Int], topInset: CGFloat) -> CGFloat {
        let bottomPadding: CGFloat = 14, overall: CGFloat = 20, footer: CGFloat = 20
        let spacing: CGFloat = 10, divider: CGFloat = 1
        let blocks = barCounts.reduce(CGFloat(0)) { $0 + 18 + CGFloat($1) * 19 + spacing + divider + spacing }
        return topInset + bottomPadding + overall + spacing + divider + spacing + blocks + footer
    }

    /// 5h and Weekly always; the model-scoped weekly only when the snapshot has one.
    static func barCount(_ row: AccountRow) -> Int {
        row.snapshot?.weeklyScoped == nil ? 2 : 3
    }

    private func applyFrame(animated: Bool) {
        let target = expanded ? frames.expanded : frames.collapsed
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animation
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// The screen that carries the menu bar is `NSScreen.screens[0]`.
    static func metrics() -> ScreenMetrics {
        guard let screen = NSScreen.screens.first else {
            return ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), topLeftArea: nil, topRightArea: nil, menuBarHeight: 24)
        }
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        // `safeAreaInsets.top` is the notch itself — 32 pt on the 14", where the menu
        // bar is 33. That one point is what made the collapsed strip stand proud of the
        // notch, so the menu-bar height must never stand in for it; 0 here (no notch, or
        // an OS that reports none) makes the geometry fall back to the auxiliary areas.
        return ScreenMetrics(frame: screen.frame,
                             topLeftArea: screen.auxiliaryTopLeftArea,
                             topRightArea: screen.auxiliaryTopRightArea,
                             menuBarHeight: menuBar > 0 ? menuBar : 24,
                             notchHeight: screen.safeAreaInsets.top)
    }
}
