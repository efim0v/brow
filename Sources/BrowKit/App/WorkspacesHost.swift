import AppKit
import Combine
import GroveAppKit
import GroveCore

/// Brow's side of Workspaces: whether the engine runs (`WorkspacesActivation`), the
/// Grove-running guard, the menu-bar item and the panel. GroveAppKit never imports
/// BrowKit; this is where the two meet.
///
/// Nothing of the engine exists until Workspaces is wanted: no `AppState`, so no
/// read of Grove's config, no account adoption, no status-line reconcile, no timer.
/// The one exception is the introduction the notch's Workspaces button shows while it
/// is off — and even that reads nothing until the user adds a project.
@MainActor
public final class WorkspacesHost: ObservableObject {
    @Published public private(set) var activation: WorkspacesActivation = .off
    /// The engine's state while Workspaces is wanted; nil while it is off.
    @Published public private(set) var state: AppState?
    /// Told when the panel is ordered in or out (the notch latches its hover meanwhile).
    public var onPanelVisibilityChange: ((Bool) -> Void)?

    public let folders: WorkspacesFolders
    private let store: LimitsStore
    private let groveGuard: GroveAppGuard
    private let groveConfigExists: () -> Bool
    private let groveDefaults: () -> UserDefaults?
    private var controller: WorkspacesMenuBarController?
    private var observers: [any NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    public init(store: LimitsStore,
                folders: WorkspacesFolders = .live(),
                groveGuard: GroveAppGuard = GroveAppGuard(runningBundleIdentifiers: {
                    NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                }),
                groveConfigExists: (() -> Bool)? = nil,
                groveDefaults: @escaping () -> UserDefaults? = { UserDefaults(suiteName: GroveAppGuard.bundleIdentifiers[0]) }) {
        self.store = store
        self.folders = folders
        self.groveGuard = groveGuard
        let configPath = folders.configFile.path
        self.groveConfigExists = groveConfigExists ?? { FileManager.default.fileExists(atPath: configPath) }
        self.groveDefaults = groveDefaults
    }

    /// Decides once, then again whenever Grove.app launches or quits, or the settings
    /// that decide change.
    public func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard GroveAppGuard.isGrove(app?.bundleIdentifier) else { return }
                Task { @MainActor in self?.refresh() }
            })
        }
        // `@Published` fires in willSet: the new value is the argument, not the store's.
        store.$settings
            .map(\.workspaces)
            .removeDuplicates()
            .sink { [weak self] workspaces in
                Task { @MainActor in self?.apply(workspaces: workspaces) }
            }
            .store(in: &cancellables)
        refresh()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        cancellables.removeAll()
        controller?.stop()
        controller = nil
        started = false
    }

    /// Re-decides from the current settings, the Grove config and Grove.app.
    public func refresh() {
        apply(workspaces: store.settings.workspaces)
    }

    private func apply(workspaces settings: WorkspacesSettings) {
        let next = WorkspacesActivation.decide(setting: settings.enabled,
                                               groveConfigExists: groveConfigExists(),
                                               groveRunning: groveGuard.isGroveRunning)
        let previous = activation
        if next != previous {
            BrowLog.workspaces.info("workspaces: \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)")
        }
        activation = next
        switch next {
        case .off:
            controller?.stop()
            controller = nil
            state = nil
        case .paused:
            let controller = ensureController()
            controller.stopEngine()
            controller.notice = groveRunningNotice
            controller.showsStatusItem = settings.showInMenuBar
            controller.start()
        case .on:
            importGroveMaterialOnce()
            // Coming from paused or off, read Grove's config afresh: Grove.app may have
            // written it while Workspaces waited, and a state loaded before that would
            // save its old copy over it.
            if previous != .on, let stale = controller {
                stale.stop()
                controller = nil
                state = nil
            }
            let controller = ensureController()
            controller.notice = nil
            controller.showsStatusItem = settings.showInMenuBar
            controller.start()
            controller.startEngine()
        }
        // The store's, not the argument's: importing Grove's material just changed it.
        WindowSubstrateStyle.current = WindowSubstrateStyle(stored: store.settings.workspaces.panelMaterial)
    }

    private func ensureController() -> WorkspacesMenuBarController {
        if let controller { return controller }
        let state = AppState(folders: folders)
        // Brow asks before it edits an account's settings.json: capture is turned on
        // per account, in Settings › Accounts, or kept where Grove had it on.
        state.capturesByDefault = false
        state.onPanelMaterialChange = { [weak self] style in self?.setPanelMaterial(style) }
        self.state = state
        let controller = WorkspacesMenuBarController(
            state: state, icon: BrowMark.templateImage(), fallbackTitle: "Brow",
            accessibilityLabel: "Brow Workspaces", showsStatusItem: store.settings.workspaces.showInMenuBar)
        controller.onVisibilityChange = { [weak self] visible in self?.onPanelVisibilityChange?(visible) }
        self.controller = controller
        return controller
    }

    // MARK: - What the user can do

    /// Turns Workspaces on or off in Brow's own settings.
    public func setEnabled(_ on: Bool) {
        store.settings.workspaces.enabled = on
        refresh()
    }

    /// Asks Grove.app to quit; Workspaces starts when it has.
    public func quitGrove() {
        for app in NSWorkspace.shared.runningApplications where GroveAppGuard.isGrove(app.bundleIdentifier) {
            app.terminate()
        }
    }

    public var isPanelVisible: Bool { controller?.isPanelVisible == true }

    /// Whether the engine's launch work and background cadence are running.
    var isEngineRunning: Bool { controller?.isEngineRunning == true }

    /// The panel: Workspaces when it runs, the reason it is paused, or — while it is
    /// off — the introduction, from which a project can be added.
    public func showPanel() {
        switch activation {
        case .on, .paused:
            ensureController().show()
        case .off:
            let controller = ensureController()
            controller.showsStatusItem = false
            controller.notice = introductionNotice
            controller.start()
            controller.show()
        }
    }

    public func togglePanel() {
        if isPanelVisible { controller?.hide() } else { showPanel() }
    }

    public func hidePanel() { controller?.hide() }

    // MARK: - Notices

    private var groveRunningNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "pause.circle",
            title: "Grove is still running",
            message: "Grove is now part of Brow, and Workspaces runs your Grove projects. It stays paused while Grove.app is open, so the two never edit the same files at once.",
            primary: .init("Quit Grove") { [weak self] in self?.quitGrove() })
    }

    private var introductionNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "square.stack.3d.up",
            title: "Workspaces",
            message: "Give each feature of a multi-repo project its own folder of git worktrees, and run parallel Claude Code sessions in them. Move a session to the account that still has room.",
            primary: .init("Add project…") { [weak self] in self?.addProjectFromIntroduction() },
            secondary: .init("Learn more") {
                if let url = URL(string: "https://github.com/efim0v/brow/blob/main/docs/workspaces.md") {
                    NSWorkspace.shared.open(url)
                }
            })
    }

    private func addProjectFromIntroduction() {
        hidePanel()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder that contains your repositories."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setEnabled(true)
        state?.addProject(at: url.path)
        showPanel()
    }

    // MARK: - Panel material

    /// Grove.app kept its panel material in its own defaults; the first time
    /// Workspaces runs in Brow, that choice comes along. Once: the flag is set whether or
    /// not Grove had one.
    private func importGroveMaterialOnce() {
        guard !store.settings.workspaces.importedGroveMaterial else { return }
        var settings = store.settings
        if settings.workspaces.panelMaterial == nil,
           let raw = groveDefaults()?.string(forKey: WindowSubstrateStyle.groveDefaultsKey),
           WindowSubstrateStyle(rawValue: raw) != nil {
            settings.workspaces.panelMaterial = raw
        }
        settings.workspaces.importedGroveMaterial = true
        store.settings = settings
    }

    /// Settings › Workspaces writes the material here.
    public func setPanelMaterial(_ style: WindowSubstrateStyle) {
        store.settings.workspaces.panelMaterial = style.rawValue
    }
}
