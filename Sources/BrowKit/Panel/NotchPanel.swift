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

/// What the hosting view shows, hung from the top edge of a window that never moves:
/// ONE black notch outline that grows out of the notch on hover — from the strip's
/// size and 14 pt corners to the panel's size and 18 pt corners, on a spring — with
/// the strip fading out and the panel fading in inside it, clipped to the outline
/// as it grows. The window's frame is never touched, so the black can never be seen
/// detaching from the notch, dropping down, or sliding sideways, which is exactly
/// what animating the window from the strip's rect to the panel's rect used to do.
struct NotchRootView: View {
    let expanded: Bool
    let frames: NotchFrames
    /// False: collapsed, the outline shrinks to the physical notch (invisible under
    /// it) and nothing is drawn — the panel is all there is, on hover.
    let showEars: Bool
    let ears: AnyView
    let panel: AnyView

    private var shapeSize: CGSize {
        if expanded { return frames.expanded.size }
        if !showEars, let notch = frames.notch {
            return CGSize(width: notch.width + 2 * frames.flare, height: notch.height)
        }
        return frames.collapsed.size
    }

    private var outline: AnyShape {
        if frames.hasNotch {
            return AnyShape(NotchShape(topFlare: frames.flare,
                                       bottomRadius: expanded ? NotchGeometry.expandedBottomRadius
                                                              : NotchGeometry.collapsedBottomRadius))
        }
        return AnyShape(RoundedRectangle(cornerRadius: NotchGeometry.collapsedBottomRadius, style: .continuous))
    }

    var body: some View {
        ZStack(alignment: .top) {
            outline.fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
            ZStack(alignment: .top) {
                if expanded {
                    panel.transition(.opacity)
                } else if showEars {
                    ears.transition(.opacity)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .clipShape(outline)
        }
        .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .top)
        // Opening springs a little; closing is quicker and settles without a bounce —
        // a strip that overshoots into the notch reads as a glitch.
        .animation(expanded ? .spring(response: 0.32, dampingFraction: 0.86)
                            : .spring(response: 0.26, dampingFraction: 1.0), value: expanded)
    }
}

/// Owns the panel, swaps collapsed ↔ expanded content on hover, and keeps its
/// frame in sync with the main screen. All state changes go through `expanded`.
///
/// The window is ALWAYS the expanded frame — as tall as the panel, hung from the
/// screen's top edge, centred on the notch — and it is put into a SkyLight space of
/// its own so it stays welded to the notch across Spaces switches. Collapsed, the
/// window is transparent below the strip and ignores mouse events, so the menu bar
/// and whatever is under the invisible part get every click.
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
    /// The space above every user Space that keeps the panel out of the Spaces
    /// transition; nil when the private API is unavailable (logged once).
    private let space: SkyLightSpace?
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
        self.frames = NotchGeometry.frames(for: Self.metrics(), expandedHeight: 200,
                                           placement: store.settings.earsPlacement)
        panel = BrowPanel(contentRect: frames.expanded,
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Collapsed, everything under the strip is transparent and must let the menu
        // bar have its clicks; the strip itself has nothing to click. Hover detection
        // is a global monitor reading `NSEvent.mouseLocation`, so expansion still
        // works with hit-testing off; `setExpanded` turns it back on for the panel.
        panel.ignoresMouseEvents = true
        // The ears and the panel are drawn on black; `.secondary` text only reads
        // as light grey in a dark appearance, so the host never inherits a light one.
        panel.appearance = NSAppearance(named: .darkAqua)
        host = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
        space = SkyLightSpace()
        if space == nil {
            BrowLog.panel.error("SkyLight space unavailable; the strip will move with Spaces transitions")
        }
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.render() }
        }.store(in: &cancellables)
    }

    public func show() {
        render()
        panel.orderFrontRegardless()
        // Only once the window is ordered in does it have a window number to add.
        space?.add(panel)
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
        space?.remove(panel)
        panel.orderOut(nil)
    }

    /// The display changed: re-render, don't just move the window. The hosted view
    /// carries the previous screen's `earWidth`/`hasNotch` until it is rebuilt.
    public func relayout() {
        render()
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        // With the readouts hidden there is nothing beside the notch to hover: the
        // pointer has to reach the notch itself.
        let collapsedHot = store.settings.showEars ? frames.collapsed : (frames.notch ?? frames.collapsed)
        let hot = expanded ? frames.expanded : collapsedHot
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
        let metrics = Self.metrics()
        // Read LIVE, every render: the store publishes on every settings write, and this
        // is what turns the Ears picker into a reshaped strip without a relaunch.
        let placement = store.settings.earsPlacement
        frames = NotchGeometry.frames(for: metrics, expandedHeight: frames.expanded.height, placement: placement)
        // Size the window to the panel it would show expanded — whether or not it is
        // expanded right now — so the frame never has to change on hover.
        let height = expandedHeight()
        frames = NotchGeometry.frames(for: metrics, expandedHeight: height, placement: placement)
        // Both views draw NO background of their own: `NotchRootView` owns the one
        // animated outline they live in.
        let ears = EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height)
        let panelView = PanelView(store: store, clock: clock, topInset: frames.contentTopInset,
                                  // The frame's OWN flare, not the constant: an
                                  // external display's frame carries none.
                                  flare: frames.flare, drawsBackground: false,
                                  onSettings: onSettings,
                                  onRefresh: { [store] in Task { await store.refresh(force: true) } })
            // The flare-widened frame, not `expandedWidth`: `NotchShape` draws its
            // concave corners in those 6 pt, and the visible black still starts at
            // the notch edge.
            .frame(width: frames.expanded.width)
        host.rootView = AnyView(NotchRootView(expanded: expanded, frames: frames, showEars: store.settings.showEars,
                                              ears: AnyView(ears), panel: AnyView(panelView)))
        applyFrame()
    }

    /// The height the laid-out panel last needed. Kept across a collapse: shrinking the
    /// window to the model's estimate the instant the panel closed re-laid the whole
    /// tree out mid-animation, which is why closing looked like a cut and opening like
    /// an animation. The window only ever grows on hover; it shrinks when the content
    /// itself does (an account gone), at the next render with the panel closed.
    private var measuredHeight: CGFloat = 0

    /// The height the expanded panel needs. The model floor is always available; the
    /// laid-out tree is consulted only while the panel is up, since a collapsed host
    /// holds the strip, not the panel.
    private func expandedHeight() -> CGFloat {
        let modelled = Self.estimatedExpandedHeight(barCounts: store.rows.map(Self.barCount),
                                                    topInset: frames.contentTopInset)
        guard expanded else { return max(120, modelled, measuredHeight) }
        host.layoutSubtreeIfNeeded()
        measuredHeight = max(modelled, host.fittingSize.height)
        return max(120, measuredHeight)
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

    /// The window frame is the expanded frame, always, and it is never animated: a
    /// change here is a screen or content-height change, not a hover.
    private func applyFrame() {
        let target = frames.expanded
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
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
