import AppKit
import SwiftUI

/// Grove.app's entry point: the Workspaces panel and its menu-bar item
/// (`WorkspacesMenuBarController`) as an app of their own, with the tree icon.
///
/// `run()` is called from main.swift AFTER SnapshotMode/CmuxProbe (which must
/// run and exit BEFORE any NSApplication machinery starts).
public enum GroveMenuBarApp {
    /// Strong reference to the delegate (NSApplication only holds it weakly).
    @MainActor private static var delegate: GroveAppDelegate?

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = GroveAppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar resident, no Dock tile
        app.run()
    }
}

@MainActor
private final class GroveAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WorkspacesMenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu-bar item is a tree — the same `tree.fill` symbol as the app icon, as
        // a template image so it follows the bar's light/dark tint; a plain glyph when
        // the symbol can't be loaded, so there is always something to click.
        let controller = WorkspacesMenuBarController(
            state: AppState(),
            icon: NSImage(systemSymbolName: "tree.fill", accessibilityDescription: "Grove"),
            fallbackTitle: "🌳", accessibilityLabel: "Grove")
        self.controller = controller
        controller.start()
        controller.startEngine()

        // Smoke-test seam: GROVE_SMOKE_OPEN_PROJECT=<substr> shows the panel, opens the
        // first matching project (exercising the live glass route change that can't be
        // reproduced in a test process), then self-quits — so a real .app-bundle launch
        // can verify "open a project doesn't crash" headlessly. No-op without the env var.
        if let needle = ProcessInfo.processInfo.environment["GROVE_SMOKE_OPEN_PROJECT"] {
            func smoke(_ s: String) { FileHandle.standardError.write(Data("SMOKE: \(s)\n".utf8)) }
            smoke("hook armed (needle=\(needle))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                controller.show()
                smoke("panel shown; isVisible=\(controller.isPanelVisible)")
                let projects = controller.state.config.projects
                if let p = projects.first(where: { $0.name.contains(needle) }) ?? projects.first {
                    smoke("opening project \(p.name)")
                    controller.state.open(.project(p.id))
                    smoke("opened project; route=\(controller.state.route)")
                } else { smoke("NO matching project") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.state.selectedTab = .stats
                smoke("switched to Stats tab; route=\(controller.state.route)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                smoke("SURVIVED — quitting")
                NSApp.terminate(nil)
            }
        }

        // Recovery seam: if the menu-bar slot is corrupted (icon hidden behind Control
        // Center — clears only on relogin), there's no icon to click. GroveShowOnLaunch
        // (a) shows a DOCK icon so the panel is reachable — clicking it reopens via
        // applicationShouldHandleReopen — and (b) pops the panel on launch. Cleared once
        // the menu-bar icon is restored (relogin).
        if UserDefaults.standard.bool(forKey: "GroveShowOnLaunch") {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.show() }
        }
    }

    /// Re-opening Grove (Finder / Spotlight / Dock, or `open -a Grove`) reopens the
    /// panel instead of being a no-op — a reliable way back in when the menu-bar icon
    /// is hidden by the macOS 26.4 layout-cache bug and there's nothing to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.handleReopen()
        return true
    }
}
