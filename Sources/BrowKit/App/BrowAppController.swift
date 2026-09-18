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
    /// Names typed into Settings but not committed yet. Owned here, not by the
    /// window's SwiftUI tree, because that tree is destroyed when the window closes.
    private let drafts = SettingsDrafts()
    private var screenObserver: (any NSObjectProtocol)?
    private let promptFallback = SendableFlag(true)
    /// Reachability, mirrored out of `RefreshTriggers`' path monitor. Same reason as
    /// `promptFallback`: the keeper runs on its own executor and cannot read the
    /// main-actor triggers, and an offline attempt must not spend its attempt floor.
    private let online = SendableFlag(true)
    private let claudePathBox = SendableText("claude")
    private var cancellables: Set<AnyCancellable> = []

    /// Order matters. The panel goes up FIRST, from the persisted snapshot alone: the
    /// account scan reads one Keychain item per config dir and a new bundle id means
    /// macOS puts a modal prompt in front of each, so doing that first parked the main
    /// thread before anything was drawn or logged — no ears, no footer error slot, and
    /// Cmd-Q inert, indistinguishable from a crash.
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowLog.panel.info("Brow launching")
        // No Keychain dialog Brow did not ask for. An ungranted item answers `.locked`
        // and the row grows a key; a background read that blocked on the dialog parked
        // the whole cycle until the watchdog threw it — readings and all — away (115
        // times in one night), which is what "updated 9 h ago" was.
        KeychainCredentialsReader.setUserInteractionAllowed(false)
        let runner = ProcessRunner()
        let settingsStore = BrowSettingsStore()
        let settings = settingsStore.load()
        let credentials = CachingCredentialsReader()
        promptFallback.set(settings.allowPromptFallback)
        claudePathBox.set(settings.claudePath ?? "claude")
        let keeper = TokenKeeper(runner: runner, credentials: credentials,
                                 claudePath: { [claudePathBox] in claudePathBox.current },
                                 allowPromptFallback: { [promptFallback] in promptFallback.current },
                                 isOnline: { [online] in online.current },
                                 stateDirectory: BrowSettingsStore.defaultDirectory)
        // `userAgent: nil` — Brow sends no `claude-code/…` User-Agent (spec, Risks).
        // Pacing measured against the live endpoint (OAuthUsageClient, `minInterval`):
        // one reading per ~100 s per account, a burst of five for the refresh button.
        let client = OAuthUsageClient(fetcher: URLSessionUsageFetcher(), userAgent: nil,
                                      cacheSeconds: 30, backoffCap: 300, minInterval: 100, burstCapacity: 5,
                                      // Shared with Grove: whichever app fetched last, the other
                                      // sees the reading and the bucket it left behind.
                                      ledger: FileUsagePacingLedger(),
                                      credentials: credentials)
        let store = LimitsStore(deps: .init(directory: AccountDirectory(credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(), settingsStore: settingsStore,
                                            now: { Date() },
                                            profileClient: OAuthProfileClient(fetcher: URLSessionUsageFetcher(),
                                                                              userAgent: nil, credentials: credentials)))
        self.store = store
        // Settings can change either of these at any time; keep the boxes the keeper
        // reads — and the "`claude` not found" banner — in step with the live values.
        // `@Published` fires in `willSet`, so `store.settings` is still the OLD value
        // inside this closure: the new one arrives as the argument.
        store.$settings
            .sink { [weak self] updated in self?.applyClaudeSettings(updated) }
            .store(in: &cancellables)
        self.addFlow = AddAccountFlow(store: store)
        let triggers = RefreshTriggers(store: store)
        self.triggers = triggers
        // The keeper reads reachability off a lock-guarded box; the path monitor is
        // the only thing that knows the answer.
        triggers.$isOnline
            .sink { [online] reachable in online.set(reachable) }
            .store(in: &cancellables)
        self.panel = NotchPanelController(store: store, clock: clock,
                                          onExpandedChange: { [weak self] in self?.triggers.setExpanded($0) },
                                          onSettings: { [weak self] in self?.showSettings() })
        self.panel.show()
        BrowLog.panel.info("panel shown")
        // Before detection and before `bootstrap()` (spec, The cycle §8): both of
        // those can sit for minutes behind a login shell or a Keychain prompt, and a
        // hover, a wake or the network returning in that window has to be live. The
        // triggers touch neither the Keychain nor the CLI to install themselves.
        triggers.start()
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.panel.relayout() }
            }
        // Everything past here can block on the Keychain or on a login shell.
        Task { @MainActor [self] in
            let detected = await ClaudePathResolver.resolve(runner: runner)
            if detected == nil {
                BrowLog.tokens.error("claude not found via \(ClaudePathResolver.detectionCommand, privacy: .public)")
            }
            // Published on the store, NOT captured by the settings window: Settings can
            // be opened (⚙, or Cmd-, — live from the first frame) while this login
            // shell is still running, and the window is built once and cached.
            store.setClaudeDetection(detected.map(ClaudeDetection.found) ?? .notFound)
            applyClaudeSettings(store.settings)
            await store.bootstrap()
        }
    }

    /// The one place that turns "what the user typed" plus "what detection found" into
    /// the path the keeper runs and the banner the footer shows. Called from the
    /// settings sink AND when detection lands, so a path typed into Settings clears a
    /// banner detection raised, and a detection that finishes after the banner went up
    /// clears it too. It used to be a one-shot at launch with no path back off the
    /// screen — and since the footer preferred it, one "`claude` not found" suppressed
    /// every fetch error for the life of the process.
    private func applyClaudeSettings(_ settings: BrowSettings) {
        guard let store else { return }
        promptFallback.set(settings.allowPromptFallback)
        claudePathBox.set(settings.claudePath ?? store.claudeDetected ?? "claude")
        // Spec, Error handling: `claude` not found belongs in BOTH slots.
        store.setConfigError(Self.configError(override: settings.claudePath, detection: store.claudeDetection))
    }

    /// Pure: what the "`claude` not found" slot should say. Nothing while detection is
    /// still running (the panel and Cmd-, are live long before a `/bin/zsh -lic` login
    /// shell answers), and nothing once a path exists — detected or typed.
    static func configError(override: String?, detection: ClaudeDetection) -> String? {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        switch detection {
        case .found, .pending: return nil
        case .notFound: return "`claude` not found — set the path in Settings › General"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q with the settings window still open never reaches `windowWillClose`.
        if let store { drafts.flush(into: store) }
        triggers?.stop()
        panel?.hide()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        cancellables.removeAll()
    }

    /// The settings window is `isReleasedWhenClosed = false` so it can be reopened;
    /// without this it would keep its SwiftUI tree rendering after every close.
    ///
    /// That teardown takes the name field's `@State` with it, and SwiftUI does not
    /// promise to deliver the focus-loss commit first — so a name typed and then
    /// "finished" by closing the window is written HERE, before anything is released.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        if let store { drafts.flush(into: store) }
        settingsWindow = nil
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
            // The detected path is NOT passed in: the window is built once and cached,
            // and detection can still be running. `SettingsView` reads it live off the
            // store instead (`store.claudeDetection`).
            let view = SettingsView(store: store, addFlow: addFlow, drafts: drafts)
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
