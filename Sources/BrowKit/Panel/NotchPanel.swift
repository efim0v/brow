// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that sits over the menu bar / notch.
///
/// It may become key (and main) only while the panel is pinned (`acceptsKey`): a
/// non-activating panel can be key without activating Brow, so the fields in it get the
/// keyboard while the app the user was in stays the active one. Hovering never makes it key.
final class BrowPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { acceptsKey }
}

/// The panel is not key while it is only hovered, so every click in it is a "first mouse" —
/// which a plain `NSHostingView` declines, leaving the ⟳ and ⚙ buttons dead.
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
    /// The open panel: `NotchShellView`, installed once.
    @Published var panel = AnyView(EmptyView())
    /// The section in front.
    @Published var tab: NotchTab = .limits
    /// The panel stays open until Esc, a click outside, the pin again or a hand-off.
    @Published var pinned = false
    /// ⌘ is held while pinned: the switch and the footer show their keys.
    @Published var showsKeys = false
    /// The pet's layer, the third one, above the strip and the panel. Set once, so its identity is stable.
    let pet: PetLayer?
    /// Limits, and what Workspaces registers.
    let sections = NotchSections()
    let badges = NotchBadges()
    /// The session card under the pointer, from the controller's mouse monitors.
    let cardHover = NotchCardHover()

    init(frames: NotchFrames, pet: PetLayer? = nil) {
        self.frames = frames
        self.pet = pet
    }
}

/// What the hosting view shows, hung from the top edge of a window that never moves:
/// ONE black notch outline that grows out of the notch on hover — from the strip's
/// size and 14 pt corners to the panel's size and 24 pt continuous corners, on a spring —
/// with the strip fading out and the panel fading in inside it, clipped to the outline
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

    /// How open the outline is: 0 the strip, 1 the panel.
    private var progress: CGFloat {
        if let p = outlineProgress { return min(max(p, 0), 1) }
        return model.expanded ? 1 : 0
    }

    private var outline: AnyShape {
        Self.outline(frames: frames, progress: progress)
    }

    /// With a notch: `NotchShape`, its continuous bottom corners growing from the strip's 14 pt
    /// to the panel's 24. Without one: the pill's rounded corners opening into a panel whose
    /// top is square (it hangs from the screen's edge) and whose bottom is continuous.
    static func outline(frames: NotchFrames, progress p: CGFloat) -> AnyShape {
        let bottom = NotchGeometry.collapsedBottomRadius
            + (NotchGeometry.expandedBottomRadius - NotchGeometry.collapsedBottomRadius) * p
        if frames.hasNotch {
            return AnyShape(NotchShape(topFlare: frames.flare, bottomRadius: bottom))
        }
        let pill = NotchGeometry.pillHeight / 2
        let top = pill * (1 - p)
        let lower = pill + (NotchGeometry.expandedBottomRadius - pill) * p
        return AnyShape(UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: lower,
                                               bottomTrailingRadius: lower, topTrailingRadius: top,
                                               style: .continuous))
    }

    var body: some View {
        ZStack(alignment: .top) {
            outline.fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
            ZStack(alignment: .top) {
                if let p = outlineProgress {
                    if model.showEars { model.ears.opacity(Double(1 - min(max(p, 0), 1))) }
                    model.panel.opacity(Double(min(max(p, 0), 1)))
                } else {
                    if model.showEars, !model.expanded {
                        model.ears.transition(.opacity)
                    }
                    // The shell stays in the tree while the panel is closed, invisible and out of
                    // the pointer's way, so what a section holds — a scroll position, a workspace
                    // opened, a form half filled, a creation running — is there when it opens again.
                    model.panel
                        .opacity(model.expanded ? 1 : 0)
                        .allowsHitTesting(model.expanded)
                        .accessibilityHidden(!model.expanded)
                }
                // The pet, inside the clip: cut by the same shape as it grows, never over the menu bar.
                if let pet = model.pet {
                    PetLayerView(layer: pet, size: frames.expanded.size,
                                 expanded: model.expanded && model.tab == .limits)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .clipShape(outline)
        }
        .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .top)
    }
}

/// Why the open panel closes.
public enum NotchDismissal: Equatable, Sendable {
    /// Esc at a section's root, or ⌘W.
    case escape
    /// A click outside the outline: another app, the desktop, Settings.
    case outsideClick
    /// The panel handed the user to something else: Go, Resume, Start session, Show in Finder.
    case handOff
    /// Settings opened from the panel.
    case settings
    /// A system panel (Add a folder…) needs the screen the notch covers.
    case systemPanel
}

/// How the notch is reached from the rest of Brow: the status item, the main menu, reopening
/// the app, Workspaces' hand-offs and its folder picker.
@MainActor
public protocol NotchPresenting: AnyObject {
    var sections: NotchSections { get }
    var badges: NotchBadges { get }
    /// Opens the panel pinned on `tab` — with "Show Brow in the notch" off too, at the top
    /// centre of the screen.
    func openPinned(on tab: NotchTab)
    /// Whether the panel is open on `tab`.
    func isShowing(_ tab: NotchTab) -> Bool
    /// Closes the open panel, the pointer latched out of reopening it.
    func dismiss(_ reason: NotchDismissal)
    /// Gets the notch out of the way (it sits above every panel the system shows), activates
    /// Brow, runs `work` — an `NSOpenPanel` — and opens the panel pinned on `tab` again.
    func runOutsideNotch(reopeningOn tab: NotchTab, _ work: @escaping @MainActor () -> Void)
}

/// Owns the panel, swaps collapsed ↔ expanded content on hover, and keeps its
/// frame in sync with the main screen. All state changes go through `expanded`.
///
/// The window is ALWAYS the expanded frame — as tall as the panel, hung from the
/// screen's top edge, centred on the notch — and it is put into a SkyLight space of
/// its own so it stays welded to the notch across Spaces switches. Collapsed, the
/// window is transparent below the strip and ignores mouse events, so the menu bar
/// and whatever is under the invisible part get every click.
///
/// Hovered, the panel opens and closes with the pointer. Any click inside pins it: it then
/// becomes key (without activating Brow), ignores the pointer leaving, and closes on Esc, a
/// click outside, the pin again or a hand-off. Every close latches the hover
/// (`NotchHoverLatch`), so the panel cannot open again under a pointer that has not left.
@MainActor
public final class NotchPanelController: NotchPresenting {
    public static let collapseDelay: TimeInterval = 0.5
    public static let animation: TimeInterval = 0.18
    /// A section closed less than this long ago is the one the panel opens on again.
    public static let tabMemory: TimeInterval = 15 * 60
    /// Opening springs a little; closing is quicker and settles without a bounce —
    /// a strip that overshoots into the notch reads as a glitch. Built from the numbers the
    /// pet's hop is timed against, so the two cannot drift apart.
    static let openAnimation: Animation = .spring(response: PetTuning.Hop.openResponse,
                                                  dampingFraction: PetTuning.Hop.openDamping)
    static let closeAnimation: Animation = .spring(response: PetTuning.Hop.closeResponse,
                                                   dampingFraction: PetTuning.Hop.closeDamping)
    /// Long enough for the closing spring to settle: what waits for it (giving the keyboard
    /// back, a smaller window) waits this long.
    static let closeSettle: TimeInterval = 0.6

    private let store: LimitsStore
    private let clock: PanelClock
    /// The pet; nil only where a panel is built without one.
    private let pet: PetController?
    private let onExpandedChange: (Bool) -> Void
    private let onSettings: () -> Void
    /// Holds the notch shut after a close until the pointer has left the panel's area.
    private var latch = NotchHoverLatch()
    private let panel: BrowPanel
    private let host: FirstMouseHostingView<NotchRootView>
    let model: NotchPanelModel
    private let hover = CalendarHoverTracker()
    private let limits: LimitsSection
    /// Lays the Limits section out offscreen, unscrolled, to size the panel by it.
    private let sizer = NSHostingController(rootView: AnyView(EmptyView()))
    /// The space above every user Space that keeps the panel out of the Spaces
    /// transition; nil when the private API is unavailable (logged once).
    private let space: SkyLightSpace?
    private var frames: NotchFrames
    private var expanded = false
    private var collapseWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var clickMonitor: Any?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []
    /// The section the panel last closed on, and when.
    private var lastClosed: (tab: NotchTab, at: Date)?
    /// Whether the panel was pinned when the current click went down: the pin button
    /// toggles from that, since the click itself pins.
    private var pinnedAtMouseDown = false
    /// The panel is up although the notch is off (`isShown` false): opened from the status
    /// item, the menu or a reopen, and ordered out again when it closes.
    private var presentedWithoutNotch = false
    /// After a close: give the keyboard back, then the smaller window.
    private var settleWork: DispatchWorkItem?
    private var collapsedAt: Date?
    /// Time, for tests.
    var now: () -> Date = { Date() }
    /// The screen the panel hangs from; a test's made-up one.
    var screen: () -> ScreenMetrics = { NotchPanelController.metrics() }
    /// False in tests: the window is never ordered in, made key or put in its space, so a
    /// test that opens and pins the panel draws nothing on the screen.
    var drivesWindow = true

    public init(store: LimitsStore, clock: PanelClock, pet: PetController? = nil,
                onExpandedChange: @escaping (Bool) -> Void, onSettings: @escaping () -> Void) {
        self.store = store
        self.clock = clock
        self.pet = pet
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
        panel.becomesKeyOnlyIfNeeded = false
        // Collapsed, everything under the strip is transparent and must let the menu
        // bar have its clicks; the strip itself has nothing to click. Hover detection
        // is a global monitor reading `NSEvent.mouseLocation`, so expansion still
        // works with hit-testing off; `setExpanded` turns it back on for the panel.
        panel.ignoresMouseEvents = true
        // The ears and the panel are drawn on black; `.secondary` text only reads
        // as light grey in a dark appearance, so the host never inherits a light one.
        panel.appearance = NSAppearance(named: .darkAqua)
        model = NotchPanelModel(frames: frames, pet: pet?.layer)
        limits = LimitsSection(store: store, clock: clock, hover: hover, pet: pet?.panel, badges: model.badges,
                               onRefresh: { [store] in Task { await store.refresh(force: true) } })
        host = FirstMouseHostingView(rootView: NotchRootView(model: model))
        panel.contentView = host
        space = SkyLightSpace()
        if space == nil {
            BrowLog.panel.error("SkyLight space unavailable; the strip will move with Spaces transitions")
        }
        model.sections.register(.limits, limits)
        // ONE shell, for the life of the panel: a store publish changes what it reads, never
        // the view itself, so a section's own state (Workspaces' tasks, a field's focus, a
        // scroll position) survives every publish.
        model.panel = AnyView(NotchShellView(
            model: model, sections: model.sections, badges: model.badges, store: store,
            actions: NotchShellActions(select: { [weak self] in self?.select($0) },
                                       togglePin: { [weak self] in self?.pinButton() },
                                       openSettings: { [weak self] in self?.openSettings() },
                                       quit: { NSApp.terminate(nil) })))
        sizer.sizingOptions = []
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.render() }
        }.store(in: &cancellables)
        // A section registered or gone changes the switch row, and with it the height.
        model.sections.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.sectionsChanged() }
        }.store(in: &cancellables)
    }

    public var sections: NotchSections { model.sections }
    public var badges: NotchBadges { model.badges }

    /// Whether the panel is up, its pointer monitors with it.
    public private(set) var isShown = false

    public func show() {
        guard !isShown else { return }
        isShown = true
        presentedWithoutNotch = false
        render()
        orderIn()
        // A test moves the pointer itself (`pointerMoved(to:)`), never the Mac's.
        guard drivesWindow else { return }
        installPointerMonitors()
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
    }

    /// Tears down the global monitors and any pending collapse. Without this the two
    /// `NSEvent` monitors installed by `show()` outlive the controller.
    public func hide() {
        guard isShown else { return }
        isShown = false
        if expanded { setExpanded(false) }
        unpin()
        collapseWork?.cancel(); collapseWork = nil
        removePointerMonitors()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver); self.occlusionObserver = nil }
        orderOut()
    }

    /// The pointer, wherever it is on the screen: the hover that opens the strip, the pet's
    /// eyes, and — the panel never being the active app's, where SwiftUI's hover does not
    /// fire — the calendar's day and the session card under it. Also while the panel is up
    /// without the notch, for the last two.
    private func installPointerMonitors() {
        guard drivesWindow, mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.pointerMoved(to: NSEvent.mouseLocation) }
            return event
        }
    }

    private func removePointerMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

    /// The display changed: re-render, don't just move the window. The hosted view
    /// carries the previous screen's `earWidth`/`hasNotch` until it is rebuilt.
    public func relayout() {
        render()
    }

    private func orderIn() {
        guard drivesWindow, !panel.isVisible else { return }
        panel.orderFrontRegardless()
        // Only once the window is ordered in does it have a window number to add.
        space?.add(panel)
        installClickMonitor()
    }

    private func orderOut() {
        removeClickMonitor()
        guard drivesWindow else { return }
        space?.remove(panel)
        panel.orderOut(nil)
    }

    // MARK: - Hover

    /// The pointer at `point`, in screen coordinates: `NSEvent.mouseLocation` from the monitors.
    func pointerMoved(to point: NSPoint) {
        // Wherever it is on the screen: the pet notices it from 160 pt and watches it.
        // Ahead of the latch, which holds the notch shut, not the pet's eyes.
        if isShown { pet?.pointerMoved(to: hostPoint(fromScreen: point)) }
        // After a close the notch stays shut until the pointer has left its area once.
        guard latch.allowsHover(pointerInExpandedArea: frames.expanded.contains(point)) else { return }
        // With the readouts hidden there is nothing beside the notch to hover: the
        // pointer has to reach the notch itself.
        let collapsedHot = store.settings.showEars ? frames.collapsed : (frames.notch ?? frames.collapsed)
        let hot = expanded ? frames.expanded : collapsedHot
        if expanded {
            let inside = hot.contains(point) ? hostPoint(fromScreen: point) : nil
            hover.update(pointer: inside)
            model.cardHover.update(pointer: inside)
        }
        // Pinned, the pointer leaving does not close it; with the notch off nothing opens it.
        guard !model.pinned, isShown else { return }
        if hot.contains(point) {
            collapseWork?.cancel(); collapseWork = nil
            if !expanded { open(on: remembered) }
        } else if expanded, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.setExpanded(false) } }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
        }
    }

    /// The section a hover opens on: the one the panel closed on, if that was less than
    /// `tabMemory` ago and it is still there; Limits otherwise.
    var remembered: NotchTab {
        guard let lastClosed, now().timeIntervalSince(lastClosed.at) < Self.tabMemory,
              sections.section(lastClosed.tab) != nil else { return .limits }
        return lastClosed.tab
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

    // MARK: - Open and close

    /// Opens on `tab` (Limits when it is not registered).
    private func open(on tab: NotchTab) {
        let target = sections.section(tab) == nil ? NotchTab.limits : tab
        if model.tab != target { model.tab = target }
        setExpanded(true)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        collapseWork?.cancel(); collapseWork = nil
        settleWork?.cancel(); settleWork = nil
        if !value {
            hover.update(pointer: nil)
            model.cardHover.update(pointer: nil)
            lastClosed = (model.tab, now())
            collapsedAt = now()
            unpin()
        }
        // Expanded, the panel owns its clicks; collapsed, it must let the menu bar underneath
        // have them.
        panel.ignoresMouseEvents = !value
        if value { clock.start() } else { clock.stop() }
        onExpandedChange(value)
        render()
        // The same instant as the outline's spring: the hop is timed against it. The pet hops
        // into the header only on Limits; elsewhere it stays on its ledge beside the camera.
        pet?.dockChanged(expanded: value && model.tab == .limits)
        for tab in sections.tabs { sections.section(tab)?.panelOpenChanged(value) }
        sections.section(model.tab)?.visibilityChanged(value)
        withAnimation(value ? Self.openAnimation : Self.closeAnimation) { model.expanded = value }
        BrowLog.panel.debug("expanded=\(value) tab=\(self.model.tab.rawValue, privacy: .public)")
        if !value { scheduleSettle() }
    }

    /// Once the closing spring has settled: the panel opened without the notch leaves the
    /// screen, a panel that had the keyboard gives it back, and a smaller window is applied.
    private func scheduleSettle() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.expanded else { return }
                if self.presentedWithoutNotch {
                    self.presentedWithoutNotch = false
                    if !self.isShown { self.removePointerMonitors() }
                    self.orderOut()
                } else if self.drivesWindow, self.panel.isKeyWindow {
                    // Ordered out and in again: the window server hands the keyboard back
                    // to the app that is active, the one the user was typing in.
                    self.space?.remove(self.panel)
                    self.panel.orderOut(nil)
                    self.panel.orderFrontRegardless()
                    self.space?.add(self.panel)
                }
                self.render()
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSettle, execute: work)
    }

    /// The switch moved to `tab`.
    func select(_ tab: NotchTab) {
        guard sections.section(tab) != nil, tab != model.tab else { return }
        let old = model.tab
        model.tab = tab
        guard expanded else { return }
        // Between the header row and the ledge, with today's hop.
        pet?.dockChanged(expanded: tab == .limits)
        sections.section(old)?.visibilityChanged(false)
        sections.section(tab)?.visibilityChanged(true)
    }

    /// ⌃Tab: the next section, round.
    private func cycle(backwards: Bool) {
        let tabs = sections.tabs
        guard let index = tabs.firstIndex(of: model.tab), tabs.count > 1 else { return }
        let next = (index + (backwards ? tabs.count - 1 : 1)) % tabs.count
        select(tabs[next])
    }

    public func openPinned(on tab: NotchTab) {
        if !isShown {
            // No strip and no hover: the panel alone, at the top centre, for as long as it is open.
            presentedWithoutNotch = true
            render()
            orderIn()
            installPointerMonitors()
        }
        settleWork?.cancel(); settleWork = nil
        if expanded {
            select(sections.section(tab) == nil ? .limits : tab)
        } else {
            open(on: tab)
        }
        pin()
    }

    public func isShowing(_ tab: NotchTab) -> Bool { expanded && model.tab == tab }

    /// Whether the window may take the keyboard now: only while pinned.
    var canBecomeKey: Bool { panel.canBecomeKey }

    public func dismiss(_ reason: NotchDismissal) {
        BrowLog.panel.debug("dismiss: \(String(describing: reason), privacy: .public)")
        latch.engage()
        collapseWork?.cancel(); collapseWork = nil
        unpin()
        setExpanded(false)
    }

    public func runOutsideNotch(reopeningOn tab: NotchTab, _ work: @escaping @MainActor () -> Void) {
        dismiss(.systemPanel)
        // The system's panel opens under the notch's level: the notch closes first, and Brow
        // becomes the active app so the panel takes the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                work()
                self?.openPinned(on: tab)
            }
        }
    }

    private func openSettings() {
        dismiss(.settings)
        onSettings()
    }

    // MARK: - Pinning

    /// Keeps the panel open and gives it the keyboard.
    func pin() {
        guard expanded else { return }
        if !model.pinned { model.pinned = true }
        collapseWork?.cancel(); collapseWork = nil
        panel.acceptsKey = true
        if drivesWindow { panel.makeKey() }
        installOutsideMonitor()
        installKeyMonitor()
    }

    /// Back to hover: the pointer leaving closes the panel again.
    func unpin() {
        if model.pinned { model.pinned = false }
        if model.showsKeys { model.showsKeys = false }
        panel.acceptsKey = false
        panel.makeFirstResponder(nil)
        removeOutsideMonitor()
        removeKeyMonitor()
    }

    /// The pin in the footer. The click that pressed it already pinned the panel; pressed
    /// on a pinned panel it unpins, and the panel closes when the pointer leaves.
    private func pinButton() {
        if pinnedAtMouseDown { unpin() } else { pin() }
    }

    /// Clicks in the panel: the pet's boop, and the pin that every click inside sets.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.expanded else { return }
                if event.window === self.panel {
                    self.pinnedAtMouseDown = self.model.pinned
                    if event.type == .leftMouseDown {
                        // A click on the pet in the open panel boops it. The click still goes on to the
                        // panel: under the pet there is only the header's empty stage.
                        self.pet?.click(at: self.hostPoint(fromWindow: event.locationInWindow))
                    }
                    self.pin()
                } else if self.model.pinned, !Self.isMenuWindow(event.window) {
                    // Another of Brow's windows: Settings. Outside the outline.
                    self.dismiss(.outsideClick)
                }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
    }

    /// A menu the panel opened lives in a window of its own: a click in it is not outside.
    static func isMenuWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
            || String(describing: type(of: window)).contains("Menu")
    }

    /// Clicks in other apps, the desktop and the menu bar close a pinned panel. Not in a test,
    /// where a click the user makes anywhere on the Mac would close the test's panel.
    private func installOutsideMonitor() {
        guard drivesWindow, outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.pinned else { return }
                // A global monitor never sees clicks in Brow's own windows; this one was
                // outside the outline.
                self.dismiss(.outsideClick)
            }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.pinned else { return false }
                if event.type == .flagsChanged {
                    let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                    if held != self.model.showsKeys { self.model.showsKeys = held }
                    return false
                }
                guard event.window === self.panel || event.window == nil else { return false }
                return self.handle(NotchKeyPress(event: event, editingText: self.panel.firstResponder is NSText))
            }
            return used ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    /// A key while pinned; true when the panel used it.
    func handle(_ press: NotchKeyPress) -> Bool {
        let section = sections.section(model.tab)
        switch press.command {
        case .escape:
            if section?.escape() == true { return true }
            dismiss(.escape)
            return true
        case .close:
            dismiss(.escape)
            return true
        case .tab(let tab):
            select(tab)
            return true
        case .cycle(let backwards):
            cycle(backwards: backwards)
            return true
        case .refresh:
            section?.refresh()
            return true
        case .settings:
            openSettings()
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .section(let key):
            return section?.handleKey(key) ?? false
        case nil:
            return false
        }
    }

    // MARK: - Layout

    private func sectionsChanged() {
        // A section that went away cannot stay in front.
        if sections.section(model.tab) == nil {
            model.tab = .limits
            if expanded { pet?.dockChanged(expanded: true) }
        }
        render()
    }

    func render() {
        let metrics = screen()
        // Read LIVE, every render: the store publishes on every settings write, and this
        // is what turns the Ears picker into a reshaped strip without a relaunch.
        let placement = store.settings.earsPlacement
        frames = NotchGeometry.frames(for: metrics, expandedHeight: frames.expanded.height, placement: placement)
        let showEars = store.settings.showEars && !presentedWithoutNotch
        let layout = NotchShellLayout(frames: frames, showsSwitch: sections.showsSwitch, showEars: showEars)
        // Size the window to the panel it would show expanded — whether or not it is
        // expanded right now — so the frame never has to change on hover.
        let height = expandedHeight(layout: layout, screen: metrics)
        frames = NotchGeometry.frames(for: metrics, expandedHeight: height, placement: placement)
        let final = NotchShellLayout(frames: frames, showsSwitch: sections.showsSwitch, showEars: showEars)
        // The strip draws NO background of its own: `NotchRootView` owns the one animated
        // outline it lives in. The panel is the shell, installed once in `init`.
        let ears = EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
            .frame(width: frames.collapsed.width, height: frames.collapsed.height)
        if model.frames != frames { model.frames = frames }
        if model.showEars != showEars { model.showEars = showEars }
        model.ears = AnyView(ears)
        // The pet's zones come from the very frames and readouts just drawn, so they match the screen;
        // its stage is the Limits header's first row.
        pet?.layout(frames: frames, aggregate: store.aggregate, showEars: showEars,
                    panelStage: CGPoint(x: final.contentInsetX, y: final.contentTop))
        applyFrame()
    }

    /// The height the open panel was last given. While it is open, or still closing, the
    /// window only grows: shrinking it there re-lays the whole tree out mid-animation. It
    /// shrinks once the panel has closed and its spring settled (`scheduleSettle`).
    private var appliedHeight: CGFloat = 0

    /// The open panel's height: the Limits section laid out (unscrolled, at the content's
    /// width) plus the switch row and the footer, at least the sections' floor while there
    /// are sections, and at most what the screen has. Every section shares it.
    private func expandedHeight(layout: NotchShellLayout, screen: ScreenMetrics) -> CGFloat {
        let content = measuredLimitsHeight(width: layout.contentWidth)
        let natural = content > 0
            ? layout.naturalHeight(content: content)
            : Self.estimatedExpandedHeight(barCounts: store.rows.map(Self.barCount), layout: layout,
                                           calendar: store.settings.showCalendar && !store.rows.isEmpty,
                                           pet: pet != nil && store.settings.showPet)
        let target = NotchGeometry.panelHeight(natural: natural,
                                               floor: layout.showsSwitch ? NotchGeometry.sectionsFloor : nil,
                                               screen: screen)
        let settled = !expanded && collapsedAt.map { now().timeIntervalSince($0) >= Self.closeSettle } ?? !expanded
        appliedHeight = settled ? target : max(appliedHeight, target)
        return appliedHeight
    }

    /// The Limits section's own height at `width`, laid out offscreen; 0 before it can be.
    func measuredLimitsHeight(width: CGFloat) -> CGFloat {
        sizer.rootView = AnyView(limits.measuringView(width: width))
        let size = sizer.sizeThatFits(in: CGSize(width: width, height: 100_000))
        return size.height.isFinite && size.height > 0 && size.height < 100_000 ? size.height : 0
    }

    /// A layout-independent estimate of the panel's height, from the model the Limits section
    /// draws, for the one moment nothing has been laid out: the chrome (`NotchShellLayout`),
    /// the pet's header row when the pet is on, the Overall line and its hairline, one block
    /// per account (header + bars) each with a divider, and the month.
    static func estimatedExpandedHeight(barCounts: [Int], layout: NotchShellLayout, calendar: Bool = false,
                                        pet: Bool = false) -> CGFloat {
        layout.naturalHeight(content: estimatedContentHeight(barCounts: barCounts, calendar: calendar, pet: pet))
    }

    /// The same for a panel without sections whose content starts `topInset` below its top edge.
    static func estimatedExpandedHeight(barCounts: [Int], topInset: CGFloat, calendar: Bool = false,
                                        pet: Bool = false) -> CGFloat {
        topInset + estimatedContentHeight(barCounts: barCounts, calendar: calendar, pet: pet)
            + NotchShellLayout.contentBottomGap + NotchShellLayout.footerHeight
    }

    /// The Limits section's content, estimated: the header (the pet's row and its spacing, the
    /// Overall line, its hairline), then the body with its 10 pt above and below.
    static func estimatedContentHeight(barCounts: [Int], calendar: Bool, pet: Bool) -> CGFloat {
        let spacing: CGFloat = 10, divider: CGFloat = 1, overall: CGFloat = 20
        let header = (pet ? CGFloat(PetTuning.Panel.rowHeight) + spacing : 0) + overall + spacing + divider
        let blocks = barCounts.reduce(CGFloat(0)) { $0 + 18 + CGFloat($1) * 19 + spacing + divider + spacing }
        let month = calendar ? CalendarView.estimatedHeight : 0
        return header + 10 + blocks + month + 10
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
                             notchHeight: screen.safeAreaInsets.top,
                             visibleFrame: screen.visibleFrame)
    }
}

/// One key press, as the pinned panel reads it. Pure, so the mapping is testable.
struct NotchKeyPress: Equatable {
    enum Command: Equatable {
        case escape, close, refresh, settings, quit
        case tab(NotchTab)
        case cycle(backwards: Bool)
        case section(NotchKey)
    }

    let command: Command?

    init(command: Command?) { self.command = command }

    /// `editingText`: a text field has the keyboard, so the keys that move or confirm in it
    /// (arrows, ↩, ⌫, Tab) are its own.
    init(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, editingText: Bool) {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let key = characters.lowercased()
        switch (keyCode, flags) {
        case (53, []):
            command = .escape
        case (48, [.control]), (48, [.control, .shift]):
            command = .cycle(backwards: flags.contains(.shift))
        case (_, [.command]) where ["1", "2", "3"].contains(key):
            command = .tab(NotchTab.allCases.first { String($0.shortcut) == key } ?? .limits)
        case (_, [.command]) where key == "r":
            command = .refresh
        case (_, [.command]) where key == ",":
            command = .settings
        case (_, [.command]) where key == "q":
            command = .quit
        case (_, [.command]) where key == "w":
            command = .close
        case (_, [.command]) where key == "f":
            command = .section(.find)
        case (36, [.command]), (76, [.command]):
            command = .section(.openWithOptions)
        case (36, []), (76, []):
            command = editingText ? nil : .section(.open)
        case (126, []):
            command = editingText ? nil : .section(.up)
        case (125, []):
            command = editingText ? nil : .section(.down)
        case (51, []), (117, []):
            command = editingText ? nil : .section(.delete)
        case (48, []):
            command = editingText ? nil : .section(.tab)
        default:
            command = nil
        }
    }

    init(event: NSEvent, editingText: Bool) {
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                  modifiers: event.modifierFlags, editingText: editingText)
    }
}
