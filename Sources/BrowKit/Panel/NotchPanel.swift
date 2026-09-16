import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that sits over the menu bar / notch.
final class BrowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
    private let host: NSHostingView<AnyView>
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
        self.frames = NotchGeometry.frames(for: Self.metrics(), expandedHeight: 200)
        panel = BrowPanel(contentRect: frames.collapsed,
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // The ears and the panel are drawn on black; `.secondary` text only reads
        // as light grey in a dark appearance, so the host never inherits a light one.
        panel.appearance = NSAppearance(named: .darkAqua)
        host = NSHostingView(rootView: AnyView(EmptyView()))
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

    public func relayout() {
        frames = NotchGeometry.frames(for: Self.metrics(), expandedHeight: expandedHeight())
        applyFrame(animated: false)
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
        if value { clock.start() } else { clock.stop() }
        onExpandedChange(value)
        render()
        BrowLog.panel.debug("expanded=\(value)")
    }

    private func render() {
        if expanded {
            host.rootView = AnyView(PanelView(store: store, clock: clock, onSettings: onSettings,
                                              onRefresh: { [store] in Task { await store.refresh(force: true) } })
                .frame(width: NotchGeometry.expandedWidth))
        } else {
            host.rootView = AnyView(EarsView(aggregate: store.aggregate, earWidth: frames.earWidth, hasNotch: frames.hasNotch)
                .frame(width: frames.collapsed.width, height: frames.collapsed.height))
        }
        frames = NotchGeometry.frames(for: Self.metrics(), expandedHeight: expandedHeight())
        applyFrame(animated: true)
    }

    private func expandedHeight() -> CGFloat {
        guard expanded else { return 200 }
        let size = host.fittingSize
        return max(120, size.height)
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
        return ScreenMetrics(frame: screen.frame,
                             topLeftArea: screen.auxiliaryTopLeftArea,
                             topRightArea: screen.auxiliaryTopRightArea,
                             menuBarHeight: menuBar > 0 ? menuBar : 24)
    }
}
