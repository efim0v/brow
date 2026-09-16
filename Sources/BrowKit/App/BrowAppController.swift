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

/// Same idea for the `claude` path. "Path to claude" meant two different things to
/// two consumers: `TokenKeeper` captured the string once at launch while Settings
/// and "Open in Terminal" read it live, so after correcting a wrong path Terminal
/// used the new binary and `claude doctor` / `-p` silently kept the old one until
/// the next relaunch.
private final class SendableText: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var current: String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: String) { lock.lock(); value = newValue; lock.unlock() }
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
final class BrowAppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: LimitsStore!
    private var triggers: RefreshTriggers!
    private var panel: NotchPanelController!
    private var addFlow: AddAccountFlow!
    private let clock = PanelClock()
    private var settingsWindow: NSWindow?
    /// The path everything actually runs: the user's override, else what detection
    /// found. NOT what Settings shows as "Detected".
    private var claudePath: String?
    /// The raw auto-detection result — the only honest input for Settings' "Detected:"
    /// vs "Not found. Ran: …" line.
    private var detectedPath: String?
    private var screenObserver: (any NSObjectProtocol)?
    private let promptFallback = SendableFlag(true)
    private let claudePathBox = SendableText("claude")
    private var cancellables: Set<AnyCancellable> = []

    /// Order matters. The panel goes up FIRST, from the persisted snapshot alone: the
    /// account scan reads one Keychain item per config dir and a new bundle id means
    /// macOS puts a modal prompt in front of each, so doing that first parked the main
    /// thread before anything was drawn or logged — no ears, no footer error slot, and
    /// Cmd-Q inert, indistinguishable from a crash.
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowLog.panel.info("Brow launching")
        let runner = ProcessRunner()
        let settingsStore = BrowSettingsStore()
        let settings = settingsStore.load()
        let credentials = CachingCredentialsReader()
        promptFallback.set(settings.allowPromptFallback)
        claudePathBox.set(settings.claudePath ?? "claude")
        let keeper = TokenKeeper(runner: runner, credentials: credentials,
                                 claudePath: { [claudePathBox] in claudePathBox.current },
                                 allowPromptFallback: { [promptFallback] in promptFallback.current },
                                 stateDirectory: BrowSettingsStore.defaultDirectory)
        // `userAgent: nil` — Brow sends no `claude-code/…` User-Agent (spec, Risks).
        let client = OAuthUsageClient(fetcher: URLSessionUsageFetcher(), userAgent: nil,
                                      cacheSeconds: 30, backoffCap: 300, credentials: credentials)
        let store = LimitsStore(deps: .init(directory: AccountDirectory(credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(), settingsStore: settingsStore,
                                            now: { Date() }))
        self.store = store
        // Settings can change either of these at any time; keep the boxes the keeper
        // reads in step with the store's live values.
        store.$settings
            .sink { [weak self, promptFallback, claudePathBox] updated in
                promptFallback.set(updated.allowPromptFallback)
                let effective = updated.claudePath ?? self?.detectedPath
                self?.claudePath = effective
                claudePathBox.set(effective ?? "claude")
            }
            .store(in: &cancellables)
        self.addFlow = AddAccountFlow(store: store)
        self.triggers = RefreshTriggers(store: store)
        self.panel = NotchPanelController(store: store, clock: clock,
                                          onExpandedChange: { [weak self] in self?.triggers.setExpanded($0) },
                                          onSettings: { [weak self] in self?.showSettings() })
        self.panel.show()
        BrowLog.panel.info("panel shown")
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.panel.relayout() }
            }
        // Everything past here can block on the Keychain or on a login shell.
        Task { @MainActor [self] in
            let detected = await ClaudePathResolver.resolve(runner: runner)
            self.detectedPath = detected
            let effective = store.settings.claudePath ?? detected
            self.claudePath = effective
            self.claudePathBox.set(effective ?? "claude")
            if effective == nil {
                BrowLog.tokens.error("claude not found via \(ClaudePathResolver.detectionCommand, privacy: .public)")
                // Spec, Error handling: `claude` not found belongs in BOTH slots.
                store.setConfigError("`claude` not found — set the path in Settings › General")
            }
            await store.bootstrap()
            self.triggers.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        triggers?.stop()
        panel?.hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        cancellables.removeAll()
    }

    /// The settings window is `isReleasedWhenClosed = false` so it can be reopened;
    /// without this it would keep its SwiftUI tree rendering after every close.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { settingsWindow = nil }
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

        // Without an Edit menu Cmd-C/V/A are dead in the settings text fields — in the
        // window whose main job is pasting a path. nil targets so each action walks
        // the responder chain to the field that has focus.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)

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
            // `detectedPath`, NOT the effective path: with an override set, passing the
            // effective value hid a failed detection and claimed the override had been
            // auto-detected.
            let view = SettingsView(store: store, addFlow: addFlow, claudeDetected: detectedPath)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Brow Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
