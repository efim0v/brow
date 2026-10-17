import AppKit
import SwiftUI
import GroveCore

/// Where the Workspaces panel hangs from: its top-right corner, in screen coordinates.
/// The panel keeps that corner pinned through every resize and grows left and down.
public struct PanelAnchor: Equatable, Sendable {
    public var rightX: CGFloat
    public var topY: CGFloat

    public init(rightX: CGFloat, topY: CGFloat) {
        self.rightX = rightX
        self.topY = topY
    }

    /// Under the status item when it sits in the menu bar of the screen whose visible
    /// frame is `visibleFrame`; that screen's top-right corner, just under the menu bar,
    /// otherwise. An item macOS could not place — behind the notch on a full menu bar, or
    /// parked at the origin by the 26.4 layout cache — has nowhere sensible to hang from,
    /// and no item at all (`iconRect == nil`) is the same case.
    public static func resolve(iconRect: CGRect?, visibleFrame: CGRect) -> PanelAnchor {
        guard let icon = iconRect,
              icon.maxY >= visibleFrame.maxY - 6,
              icon.midX >= visibleFrame.minX, icon.midX <= visibleFrame.maxX
        else { return topRight(of: visibleFrame) }
        return PanelAnchor(rightX: icon.maxX, topY: icon.minY - 6)   // a small gap under the bar
    }

    /// The screen's top-right corner, just under the menu bar.
    public static func topRight(of visibleFrame: CGRect) -> PanelAnchor {
        PanelAnchor(rightX: visibleFrame.maxX - 8, topY: visibleFrame.maxY - 4)
    }
}

/// Borderless panel that can still become key, so the panel's search field and
/// other controls receive keyboard input (a plain borderless window cannot).
final class GrovePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Workspaces panel and its menu-bar item, for whichever app hosts the engine.
///
/// A plain AppKit `NSStatusItem` + a borderless `NSPanel` hosting the SwiftUI
/// `MergedRootView` — NOT SwiftUI's `MenuBarExtra` and NOT an `NSPopover`.
///
/// Why not `MenuBarExtra`: on macOS 26.4 its scene machinery sends `terminate:`
/// to the app moments after the status item appears, so the process quits at
/// launch. (Its repeated visibility toggling also corrupted the WindowServer
/// menu-bar layout cache for the old `dev.artem.grove` identity.)
///
/// Why not `NSPopover`: a popover re-positions itself relative to the status
/// button on EVERY content-size change, re-centering under the icon. The panel
/// changes size when the route changes, so the popover visibly jumped on each
/// switch. A panel positioned here keeps its TOP-RIGHT corner pinned to the icon
/// and grows inward.
///
/// Two phases, so a host can show the item before it lets the engine run:
/// `start()` puts up the item; `startEngine()` does the launch work — adopting
/// signed-in folders, the status-line reconcile, the first capture read, the 90 s
/// background cadence and the offscreen pre-render.
@MainActor
public final class WorkspacesMenuBarController: NSObject, NSWindowDelegate {
    /// Single shared state for the lifetime of the controller.
    public let state: AppState
    /// Told whenever the panel is ordered in or out.
    public var onVisibilityChange: ((Bool) -> Void)?
    public private(set) var isEngineRunning = false

    private let icon: NSImage?
    private let fallbackTitle: String
    private let accessibilityLabel: String
    private var statusItem: NSStatusItem?
    private var isStarted = false
    private var panel: GrovePanel?
    private var host: NSHostingController<AnyView>?
    /// KVO token: the panel must resize when SwiftUI's preferredContentSize changes
    /// (a route switch) — an NSWindow does not do this on its own reliably.
    private var sizeObservation: NSKeyValueObservation?
    /// Observes `.groveSubstrateStyleChanged` so the panel live-swaps its substrate
    /// (Liquid Glass ⇄ Visual Effect) without a relaunch when the setting flips.
    private var substrateObserver: (any NSObjectProtocol)?
    /// Background cadence for the captures and the transcript safety net while the
    /// panel is closed.
    private var backgroundTimer: Timer?
    /// Global mouse monitor installed while the panel is open so a click anywhere
    /// OUTSIDE the app (desktop, another app, the menu bar) dismisses it. A global
    /// monitor never fires for clicks inside the app's own windows — including a child
    /// NSOpenPanel — so the "+ Add project" flow is not torn down.
    private var outsideClickMonitor: Any?
    /// Captured when the panel opens: its top-right corner and the screen it is on.
    private var anchor = PanelAnchor(rightX: 0, topY: 0)
    private var anchorScreen: NSScreen?

    /// Shown instead of the projects while set — the engine is off or paused — and then
    /// the panel reads and refreshes nothing behind it.
    public var notice: WorkspacesNotice? {
        didSet { host?.rootView = rootContent() }
    }

    /// Whether the menu-bar item exists. Turning it off removes the item; the panel can
    /// still be shown with `show(at:)`.
    public var showsStatusItem: Bool {
        didSet { if isStarted { updateStatusItem() } }
    }

    /// `icon` is a template image (it follows the menu bar's tint); when it is nil the
    /// item shows `fallbackTitle` instead, so there is always something to click.
    public init(state: AppState, icon: NSImage?, fallbackTitle: String, accessibilityLabel: String,
                showsStatusItem: Bool = true) {
        self.state = state
        self.icon = icon
        self.fallbackTitle = fallbackTitle
        self.accessibilityLabel = accessibilityLabel
        self.showsStatusItem = showsStatusItem
        super.init()
    }

    // MARK: - Lifecycle

    /// Puts up the menu-bar item and starts following the substrate setting. Touches
    /// no files and starts no engine work.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        updateStatusItem()
        // Live-swap the window substrate when the Settings toggle flips the style.
        substrateObserver = NotificationCenter.default.addObserver(
            forName: .groveSubstrateStyleChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reinstallSubstrate() }
        }
    }

    /// The launch work. Every configured account gets the status-line wrapper: it is
    /// what writes the per-session captures (model, context, cost) the session views
    /// show, and the rate-limit captures Brow reads. Signed-in folders under the
    /// accounts root join the list, then every account takes its email as its name
    /// once identities are read.
    public func startEngine() {
        guard !isEngineRunning else { return }
        isEngineRunning = true
        state.discoverAccountDirs()
        state.reconcileMonitoring()
        Task { @MainActor [state] in
            await state.refreshUsage(now: Date())
            if state.reconcileAccountNames() { await state.refreshUsage(now: Date()) }
        }
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            // The timer's closure is Sendable; the state is the main actor's, so the
            // check runs inside the main-actor task, not out here.
            Task { @MainActor in
                // Skip while the panel is open — RootView's 15s loop already refreshes,
                // so the two cadences never overlap (which could land out-of-order and
                // overwrite newer data).
                guard let self, self.isEngineRunning, !self.state.isPanelOpen else { return }
                await self.state.refreshUsage(now: Date())
                await self.state.reconcileTranscripts()
            }
        }
        // Warm the heavier screens offscreen shortly after launch so the first
        // navigation is snappy (deferred so the menu-bar icon appears instantly).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SnapshotMode.prewarm() }
    }

    /// Stops the background cadence and closes the panel (whose refresh loop is engine
    /// work too). The item stays.
    public func stopEngine() {
        guard isEngineRunning else { return }
        isEngineRunning = false
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        hide()
    }

    /// Everything off: engine, panel, item, observers.
    public func stop() {
        stopEngine()
        hide()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let substrateObserver { NotificationCenter.default.removeObserver(substrateObserver) }
        substrateObserver = nil
        isStarted = false
    }

    /// Re-opening the app (Finder / Spotlight / Dock, or `open -a`) shows the panel
    /// instead of being a no-op — a reliable way back in when the menu-bar item is
    /// hidden and there is nothing to click.
    public func handleReopen() {
        if panel?.isVisible != true { show() }
    }

    // MARK: - Menu-bar item

    private func updateStatusItem() {
        if showsStatusItem {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.action = #selector(statusItemClicked)
                button.target = self
                if let icon {
                    icon.isTemplate = true
                    button.image = icon
                    button.attributedTitle = NSAttributedString(string: "")
                } else {
                    button.image = nil
                    button.attributedTitle = NSAttributedString(
                        string: fallbackTitle, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
                }
                button.setAccessibilityLabel(accessibilityLabel)
                button.toolTip = accessibilityLabel
            }
            item.isVisible = true
            statusItem = item
            GroveLog.workspaces.info("status item up; isVisible=\(item.isVisible, privacy: .public)")
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func statusItemClicked() { toggle() }

    // MARK: - Panel

    public var isPanelVisible: Bool { panel?.isVisible == true }

    public func toggle() {
        if isPanelVisible { hide() } else { show() }
    }

    /// Shows the panel under the menu-bar item, or at the main screen's top-right
    /// corner when there is no item to hang it from.
    public func show() {
        if let button = statusItem?.button, let window = button.window {
            let iconRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            show(at: PanelAnchor.resolve(iconRect: iconRect, visibleFrame: visible), on: screen)
        } else {
            let screen = NSScreen.main
            show(at: .topRight(of: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)),
                 on: screen)
        }
    }

    /// Shows the panel with its top-right corner at `anchor` on `screen`.
    public func show(at anchor: PanelAnchor, on screen: NSScreen?) {
        let p = makePanel()
        self.anchor = anchor
        anchorScreen = screen
        // Starts RootView's refresh loop — never behind a notice.
        state.isPanelOpen = notice == nil
        // Size + place the panel BEFORE ordering in so it doesn't flash. The hosting
        // controller can still report 0x0 before its first layout pass, so with no
        // preferred size yet the panel's CURRENT frame is used — the top-right corner
        // must be pinned BEFORE makeKeyAndOrderFront, or the very first open flashes
        // at the window's default origin until the KVO repositions it.
        if let h = host, h.preferredContentSize.width > 1 {
            applyContentSize(h.preferredContentSize)
        } else {
            applyContentSize(p.frame.size)
        }
        NSApp.activate(ignoringOtherApps: true)   // key window + keyboard for an .accessory app
        p.makeKeyAndOrderFront(nil)               // key-capable: the search field gets focus
        installOutsideClickMonitor()
        onVisibilityChange?(true)
    }

    public func hide() {
        let wasVisible = isPanelVisible
        state.isPanelOpen = false                 // stops RootView's refresh loop
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
        if wasVisible { onVisibilityChange?(false) }
    }

    private func makePanel() -> GrovePanel {
        if let panel { return panel }
        // NOT .nonactivatingPanel: that flag blocks the panel from becoming key, so
        // the search field would never get the keyboard. Plain .borderless +
        // GrovePanel.canBecomeKey + NSApp.activate gives it focus. The initial rect is
        // sized for the projects route (460 wide) so the first frame doesn't flash at
        // a wrong width before KVO corrects it.
        let p = GrovePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                           styleMask: [.borderless],
                           backing: .buffered, defer: false)
        p.level = .floating                  // above normal windows, but NOT forced over fullscreen apps
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // Show on the current Space when summoned, but do NOT float over fullscreen
        // apps or ride along during a Space swipe — that re-samples a dense/blurry
        // backdrop and makes the constant glass suddenly intensify.
        p.collectionBehavior = [.moveToActiveSpace]
        // AppKit-level height cap from the start (refined per-screen in applyContentSize)
        // so the panel can never grow off-screen even before the first sizing pass.
        if let vis = NSScreen.main?.visibleFrame {
            p.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: max(200, vis.height - 8))
        }
        p.delegate = self
        // Clear, constant Liquid Glass via AppKit NSGlassEffectView — never frosted,
        // never dims on focus (see WindowSubstrate). The hairline border is drawn on
        // MergedRootView; the gray GlassCards provide content surfaces.
        let h = NSHostingController(rootView: rootContent())
        h.sizingOptions = [.preferredContentSize]
        WindowSubstrate.install(h, radius: DesignRadius.panel, style: WindowSubstrateStyle.current, in: p)
        host = h
        // Resize the panel to the SwiftUI content on every route change, then re-pin
        // the top-right corner so it grows inward instead of jumping.
        sizeObservation = h.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { self?.applyContentSize(size) }
        }
        panel = p
        return p
    }

    private func rootContent() -> AnyView {
        if let notice { return AnyView(WorkspacesNoticeView(notice: notice)) }
        return AnyView(MergedRootView(state: state))
    }

    /// Rebuilds the panel's substrate from the current `WindowSubstrateStyle`,
    /// re-parenting the SAME hosting view into the new backing so the swap is live and
    /// lossless — no relaunch, no lost state.
    private func reinstallSubstrate() {
        guard let p = panel, let h = host else { return }
        WindowSubstrate.install(h, radius: DesignRadius.panel, style: WindowSubstrateStyle.current, in: p)
        if h.preferredContentSize.width > 1 { applyContentSize(h.preferredContentSize) }
    }

    /// Resizes the panel to its SwiftUI content and re-pins its TOP-RIGHT corner to the
    /// anchor, so the window grows LEFTWARD and DOWNWARD as the route changes.
    private func applyContentSize(_ size: NSSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Cap the height to the visible screen so the window can always be fully
        // on-screen. AppKit-level cap (contentMaxSize): the window can NEVER exceed
        // this regardless of HOW it's resized. This REPLACES the synchronous cap
        // windowDidResize used to do (removed because re-entrant setContentSize
        // recursed Apple's Liquid Glass to a SIGSEGV): contentMaxSize is a passive
        // constraint, so it needs no setContentSize and can't enter that path.
        let maxH = max(200, visible.height - 8)
        p.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: maxH)
        let capped = NSSize(width: size.width, height: min(size.height, maxH))
        if p.frame.size != capped { p.setContentSize(capped) }
        repinTopRight()
    }

    /// Re-pins the panel's TOP-RIGHT corner to the anchor (grow LEFT + DOWN), clamped
    /// on-screen — WITHOUT resizing. windowDidResize calls THIS, never
    /// applyContentSize: calling setContentSize from inside a resize callback is a
    /// resize-within-a-resize that AppKit runs in an animation group, which recurses
    /// the Liquid-Glass material resolver (DesignLibrary / MaterialProviderBox) to a
    /// stack-overflow SIGSEGV — the "crash when opening a project". Origin-only
    /// repinning can't enter that path.
    private func repinTopRight() {
        guard let p = panel else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.rightX - p.frame.width
        x = max(visible.minX + 4, min(x, visible.maxX - p.frame.width - 4))
        var y = anchor.topY - p.frame.height
        y = max(visible.minY + 4, min(y, visible.maxY - p.frame.height - 4))
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.invalidateShadow()
    }

    /// A resize of the panel (a route change) re-pins its top-right corner to the
    /// anchor and refreshes the shadow.
    public func windowDidResize(_ notification: Notification) {
        let resized = notification.object as? NSWindow
        // A resize delivered while the window is hidden (a SwiftUI layout pass during
        // orderOut) must not reposition with stale anchors — show re-anchors.
        guard resized === panel, resized?.isVisible == true else { return }
        // Origin-only re-pin; the height cap is enforced PASSIVELY by contentMaxSize.
        repinTopRight()
    }

    // MARK: - Outside-click dismissal

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
