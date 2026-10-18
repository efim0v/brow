// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

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

/// Everything `NotchRootView` draws, as ONE observable object that lives as long as
/// the hosting view. The root view is installed once and reads this; expanding is a
/// `withAnimation` change to `expanded`. Replacing the hosting view's `rootView` with
/// a fresh value on every hover was the reason nothing ever animated: the change
/// arrived as a new root, outside any SwiftUI transaction, and every "spring" landed
/// as a single frame.
@MainActor
final class NotchPanelModel: ObservableObject {
    @Published var expanded = false
    @Published var frames: NotchFrames
    /// False: collapsed, the outline shrinks to the physical notch (invisible under
    /// it) and nothing is drawn — the panel is all there is, on hover.
    @Published var showEars = true
    @Published var ears = AnyView(EmptyView())
    @Published var panel = AnyView(EmptyView())
    /// The pet's layer, the third one, above the strip and the panel. Set once, so its identity is stable:
    /// `render()` replacing `ears` and `panel` on every store publish never resets it.
    let pet: PetLayer?

    init(frames: NotchFrames, pet: PetLayer? = nil) {
        self.frames = frames
        self.pet = pet
    }
}

/// What the hosting view shows, hung from the top edge of a window that never moves:
/// ONE black notch outline that grows out of the notch on hover — from the strip's
/// size and 14 pt corners to the panel's size and 18 pt corners, on a spring — with
/// the strip fading out and the panel fading in inside it, clipped to the outline
/// as it grows. The window's frame is never touched, so the black can never be seen
/// detaching from the notch, dropping down, or sliding sideways, which is exactly
/// what animating the window from the strip's rect to the panel's rect used to do.
struct NotchRootView: View {
    @ObservedObject var model: NotchPanelModel
    /// Offscreen renders only: the outline caught part-way through its spring, 0 the strip and 1 the
    /// panel, drawn the way SwiftUI interpolates a change of `expanded` (the size and the corner radius
    /// along the spring, the strip fading out as the panel fades in). `ImageRenderer` cannot run a
    /// spring. The app always passes nil and animates `model.expanded`.
    var outlineProgress: CGFloat?

    private var frames: NotchFrames { model.frames }

    private var shapeSize: CGSize {
        if let p = outlineProgress {
            let collapsed = Self.outlineSize(frames: frames, expanded: false, showEars: model.showEars)
            return CGSize(width: collapsed.width + (frames.expanded.width - collapsed.width) * p,
                          height: collapsed.height + (frames.expanded.height - collapsed.height) * p)
        }
        return Self.outlineSize(frames: frames, expanded: model.expanded, showEars: model.showEars)
    }

    /// The black outline's size. Expanded, the panel's. Collapsed with the readouts on,
    /// the strip's. With them off, the physical notch, which the black then hides in — and
    /// on a display without a notch, nothing at all: the pill's width at no height, so
    /// nothing is drawn until the pointer reaches the top centre, and the panel unrolls
    /// from the top edge.
    static func outlineSize(frames: NotchFrames, expanded: Bool, showEars: Bool) -> CGSize {
        if expanded { return frames.expanded.size }
        guard !showEars else { return frames.collapsed.size }
        guard let notch = frames.notch else { return CGSize(width: frames.collapsed.width, height: 0) }
        return CGSize(width: notch.width + 2 * frames.flare, height: notch.height)
    }

    private var outline: AnyShape {
        if frames.hasNotch {
            let radius: CGFloat
            if let p = outlineProgress {
                radius = NotchGeometry.collapsedBottomRadius
                    + (NotchGeometry.expandedBottomRadius - NotchGeometry.collapsedBottomRadius) * p
            } else {
                radius = model.expanded ? NotchGeometry.expandedBottomRadius : NotchGeometry.collapsedBottomRadius
            }
            return AnyShape(NotchShape(topFlare: frames.flare, bottomRadius: radius))
        }
        return AnyShape(RoundedRectangle(cornerRadius: NotchGeometry.collapsedBottomRadius, style: .continuous))
    }

    var body: some View {
        ZStack(alignment: .top) {
            outline.fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
            ZStack(alignment: .top) {
                if let p = outlineProgress {
                    if model.showEars { model.ears.opacity(Double(1 - min(max(p, 0), 1))) }
                    model.panel.opacity(Double(min(max(p, 0), 1)))
                } else if model.expanded {
                    model.panel.transition(.opacity)
                } else if model.showEars {
                    model.ears.transition(.opacity)
                }
                // The pet, inside the clip: cut by the same shape as it grows, never over the menu bar.
                if let pet = model.pet {
                    PetLayerView(layer: pet, size: frames.expanded.size, expanded: model.expanded)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .clipShape(outline)
        }
        .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .top)
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
    /// Opening springs a little; closing is quicker and settles without a bounce —
    /// a strip that overshoots into the notch reads as a glitch. Built from the numbers the
    /// pet's hop is timed against, so the two cannot drift apart.
    static let openAnimation: Animation = .spring(response: PetTuning.Hop.openResponse,
                                                  dampingFraction: PetTuning.Hop.openDamping)
    static let closeAnimation: Animation = .spring(response: PetTuning.Hop.closeResponse,
                                                   dampingFraction: PetTuning.Hop.closeDamping)

    private let store: LimitsStore
    private let clock: PanelClock
    /// The pet; nil only where a panel is built without one.
    private let pet: PetController?
    private let onExpandedChange: (Bool) -> Void
    private let onSettings: () -> Void
    private let onWorkspaces: (() -> Void)?
    /// Holds the notch shut after the Workspaces button (see `NotchHoverLatch`).
    private var latch = NotchHoverLatch()
    private let panel: BrowPanel
    private let host: FirstMouseHostingView<NotchRootView>
    private let model: NotchPanelModel
    private let hover = CalendarHoverTracker()
    /// The space above every user Space that keeps the panel out of the Spaces
    /// transition; nil when the private API is unavailable (logged once).
    private let space: SkyLightSpace?
    private var frames: NotchFrames
    private var expanded = false
    private var collapseWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var clickMonitor: Any?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    public init(store: LimitsStore, clock: PanelClock, pet: PetController? = nil,
                onExpandedChange: @escaping (Bool) -> Void, onSettings: @escaping () -> Void,
                onWorkspaces: (() -> Void)? = nil) {
        self.store = store
        self.clock = clock
        self.pet = pet
        self.onExpandedChange = onExpandedChange
        self.onSettings = onSettings
        self.onWorkspaces = onWorkspaces
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
        model = NotchPanelModel(frames: frames, pet: pet?.layer)
        host = FirstMouseHostingView(rootView: NotchRootView(model: model))
        panel.contentView = host
        space = SkyLightSpace()
        if space == nil {
            BrowLog.panel.error("SkyLight space unavailable; the strip will move with Spaces transitions")
        }
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.render() }
        }.store(in: &cancellables)
    }

    /// Whether the panel is up, its pointer monitors with it.
    public private(set) var isShown = false

    public func show() {
        guard !isShown else { return }
        isShown = true
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
        guard let pet else { return }
        // A window macOS reports as occluded (covered, or on a display that is off) shows nobody the
        // pet: it stops drawing.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pet?.windowVisibility(self.panel.occlusionState.contains(.visible))
                }
            }
        pet.windowVisibility(panel.occlusionState.contains(.visible))
        // A click on the pet in the open panel boops it. The click still goes on to the panel:
        // under the pet there is only the header's empty stage.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.expanded, event.window === self.panel else { return }
                self.pet?.click(at: self.hostPoint(fromWindow: event.locationInWindow))
            }
            return event
        }
    }

    /// Tears down the global monitors and any pending collapse. Without this the two
    /// `NSEvent` monitors installed by `show()` outlive the controller.
    public func hide() {
        guard isShown else { return }
        isShown = false
        if expanded { setExpanded(false) }
        collapseWork?.cancel(); collapseWork = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver); self.occlusionObserver = nil }
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
        // Wherever it is on the screen: the pet notices it from 160 pt and watches it.
        // Ahead of the latch, which holds the notch shut, not the pet's eyes: the Workspaces
        // panel the latch makes room for opens right under the strip the pet sits in.
        pet?.pointerMoved(to: hostPoint(fromScreen: point))
        // After the Workspaces button the notch stays shut until the pointer has left
        // the expanded panel's area once: the Workspaces panel opens right under it.
        guard latch.allowsHover(pointerInExpandedArea: frames.expanded.contains(point)) else { return }
        // With the readouts hidden there is nothing beside the notch to hover: the
        // pointer has to reach the notch itself.
        let collapsedHot = store.settings.showEars ? frames.collapsed : (frames.notch ?? frames.collapsed)
        let hot = expanded ? frames.expanded : collapsedHot
        if expanded { hover.update(pointer: hot.contains(point) ? hostPoint(fromScreen: point) : nil) }
        if hot.contains(point) {
            collapseWork?.cancel(); collapseWork = nil
            if !expanded { setExpanded(true) }
        } else if expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.setExpanded(false) } }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
        }
    }

    /// The notch panel's Workspaces button: the notch closes at once and stays closed
    /// until the pointer has left it (the latch), and the Workspaces panel opens.
    private func openWorkspaces() {
        latch.engage()
        collapseWork?.cancel(); collapseWork = nil
        setExpanded(false)
        onWorkspaces?()
    }

    /// A screen point in the hosting view's space — the `.global` space SwiftUI's
    /// `GeometryReader` reports in: origin top-left, whatever the view's flip.
    private func hostPoint(fromScreen point: NSPoint) -> CGPoint {
        hostPoint(fromWindow: panel.convertPoint(fromScreen: point))
    }

    private func hostPoint(fromWindow point: NSPoint) -> CGPoint {
        let inHost = host.convert(point, from: nil)
        return CGPoint(x: inHost.x, y: host.isFlipped ? inHost.y : host.bounds.height - inHost.y)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        collapseWork = nil
        if !value { hover.update(pointer: nil) }
        // Expanded, the panel owns its clicks (⟳ and ⚙); collapsed, it must let the
        // menu bar underneath have them.
        panel.ignoresMouseEvents = !value
        if value { clock.start() } else { clock.stop() }
        onExpandedChange(value)
        render()
        // The same instant as the outline's spring: the hop is timed against it.
        pet?.dockChanged(expanded: value)
        withAnimation(value ? Self.openAnimation : Self.closeAnimation) { model.expanded = value }
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
                                  flare: frames.flare, drawsBackground: false, hover: hover,
                                  pet: pet?.panel, onSettings: onSettings,
                                  onRefresh: { [store] in Task { await store.refresh(force: true) } },
                                  onWorkspaces: onWorkspaces == nil ? nil : { [weak self] in self?.openWorkspaces() })
            // The flare-widened frame, not `expandedWidth`: `NotchShape` draws its
            // concave corners in those 6 pt, and the visible black still starts at
            // the notch edge.
            .frame(width: frames.expanded.width)
        // Content and geometry are plain updates; `expanded` alone is animated, by
        // `setExpanded`, so a store publish mid-spring cannot restart or cut it.
        model.frames = frames
        model.showEars = store.settings.showEars
        model.ears = AnyView(ears)
        model.panel = AnyView(panelView)
        // The pet's zones come from the very frames and readouts just drawn, so they match the screen.
        pet?.layout(frames: frames, aggregate: store.aggregate, showEars: store.settings.showEars)
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
                                                    topInset: frames.contentTopInset,
                                                    calendar: store.settings.showCalendar && !store.rows.isEmpty,
                                                    pet: pet != nil && store.settings.showPet)
        guard expanded else { return max(120, modelled, measuredHeight) }
        host.layoutSubtreeIfNeeded()
        measuredHeight = max(modelled, host.fittingSize.height)
        return max(120, measuredHeight)
    }

    /// A layout-independent floor for the expanded panel, from the model PanelView
    /// draws: the top inset that keeps the content clear of the notch, 14 pt of bottom
    /// padding, the pet's header row when the pet is on, the Overall line, one block per
    /// account (header + bars) each followed by a divider, and the footer, with 10 pt
    /// stack spacing. The inset is PanelView's whole top padding, so it is added, not
    /// stacked on a second 14.
    ///
    /// Deliberately WITHOUT `PanelView`'s `max(topInset, 14)` floor: this is a floor,
    /// and `expandedHeight()` takes `max(modelled, fittingSize)`, so the laid-out tree —
    /// which does carry the floor — wins on the only path where the two differ (a screen
    /// with no notch, inset 8).
    static func estimatedExpandedHeight(barCounts: [Int], topInset: CGFloat, calendar: Bool = false,
                                        pet: Bool = false) -> CGFloat {
        let bottomPadding: CGFloat = 14, overall: CGFloat = 20, footer: CGFloat = 20
        let spacing: CGFloat = 10, divider: CGFloat = 1
        let blocks = barCounts.reduce(CGFloat(0)) { $0 + 18 + CGFloat($1) * 19 + spacing + divider + spacing }
        let month = calendar ? CalendarView.estimatedHeight + spacing + divider + spacing : 0
        // The pet's header row and the stack spacing under it.
        let header = pet ? CGFloat(PetTuning.Panel.addedHeight) : 0
        return topInset + bottomPadding + header + overall + spacing + divider + spacing + blocks + month + footer
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
