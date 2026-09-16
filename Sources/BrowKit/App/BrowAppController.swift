import AppKit
import Combine
import SwiftUI
import GroveCore

/// `TokenKeeper` is an actor: it calls `allowPromptFallback` on its OWN executor,
/// never on the main actor, so the setting cannot be read straight out of the
/// main-actor-isolated `LimitsStore` from that closure. The live value is
/// mirrored into this lock-guarded box instead, and the box is what the keeper
/// reads.
private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var current: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Process entry: wires the stores, the notch panel, the triggers and the
/// settings window. Mirrors GroveMenuBarApp: plain AppKit, `.accessory`
/// activation policy, no MenuBarExtra.
public enum BrowApp {
    @MainActor private static var controller: BrowAppController?

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let controller = BrowAppController()
        Self.controller = controller
        app.delegate = controller
        app.mainMenu = controller.makeMainMenu()
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class BrowAppController: NSObject, NSApplicationDelegate {
    private var store: LimitsStore!
    private var triggers: RefreshTriggers!
    private var panel: NotchPanelController!
    private var addFlow: AddAccountFlow!
    private let clock = PanelClock()
    private var settingsWindow: NSWindow?
    private var claudePath: String?
    private var screenObserver: (any NSObjectProtocol)?
    private let promptFallback = SendableFlag(true)
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runner = ProcessRunner()
        let settingsStore = BrowSettingsStore()
        let settings = settingsStore.load()
        let credentials = CachingCredentialsReader()
        promptFallback.set(settings.allowPromptFallback)
        // `[self]` is explicit only to silence ImplicitStrongCapture: the wiring
        // below installs long-lived `[weak self]` closures, and the compiler
        // flags a weak inner capture under an implicitly-strong outer one. This
        // Task is short-lived, so the strong hold ends when launch wiring does.
        Task { @MainActor [self] in
            let detected = await ClaudePathResolver.resolve(runner: runner)
            self.claudePath = settings.claudePath ?? detected
            if self.claudePath == nil { BrowLog.tokens.error("claude not found via \(ClaudePathResolver.detectionCommand, privacy: .public)") }
            let keeper = TokenKeeper(runner: runner, credentials: credentials,
                                     claudePath: self.claudePath ?? "claude",
                                     allowPromptFallback: { [promptFallback] in promptFallback.current })
            let client = OAuthUsageClient(fetcher: URLSessionUsageFetcher(), appVersion: GroveVersion.current,
                                          cacheSeconds: 30, backoffCap: 300, credentials: credentials)
            self.store = LimitsStore(deps: .init(directory: AccountDirectory(credentials: credentials),
                                                 keeper: keeper, client: client,
                                                 snapshotStore: LimitSnapshotStore(), settingsStore: settingsStore,
                                                 now: { Date() }))
            // Settings › General can flip the fallback at any time; keep the box
            // the keeper reads in step with the store's live value.
            self.store.$settings
                .sink { [promptFallback] in promptFallback.set($0.allowPromptFallback) }
                .store(in: &self.cancellables)
            self.addFlow = AddAccountFlow(store: self.store)
            self.triggers = RefreshTriggers(store: self.store)
            self.panel = NotchPanelController(store: self.store, clock: self.clock,
                                              onExpandedChange: { [weak self] in self?.triggers.setExpanded($0) },
                                              onSettings: { [weak self] in self?.showSettings() })
            self.panel.show()
            self.triggers.start()
            self.screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.panel.relayout() }
                }
        }
    }

    /// A non-nib app gets NO main menu of its own, and Brow has no Dock icon
    /// (`LSUIElement` + `.accessory`), no status item and no window at launch —
    /// so without this menu `Cmd-Q` is inert and the only way out of a running
    /// Brow is `pkill`. Grove reaches `NSApp.terminate` from its panel footer
    /// (`ProjectsFooter.swift`); Brow's panel is a hover strip with no room for
    /// a Quit button, so the menu carries it — and hands the settings window
    /// back its standard `Cmd-,` and `Cmd-W`.
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // The first submenu is the application menu; macOS titles it from
        // CFBundleName ("Brow") whatever this menu's own title says.
        let appMenu = NSMenu(title: "Brow")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenuItem(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        // nil target: the action walks the responder chain up to NSApp, which
        // implements `terminate:` — the same exit Grove's footer button takes.
        appMenu.addItem(NSMenuItem(title: "Quit Brow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    @objc private func openSettingsMenuItem(_ sender: Any?) { showSettings() }

    func showSettings() {
        // `Cmd-,` is live from the moment the menu is installed, which is before
        // the launch Task has built the store — and both are implicitly
        // unwrapped, so an early hit would trap instead of doing nothing.
        guard let store, let addFlow else {
            BrowLog.panel.error("settings opened before the accounts finished loading; ignoring")
            return
        }
        if settingsWindow == nil {
            let view = SettingsView(store: store, addFlow: addFlow, claudeDetected: claudePath)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Brow Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
