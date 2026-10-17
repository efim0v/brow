// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Combine
import GroveAppKit
import GroveCore

/// Brow's side of Workspaces: whether the engine runs (`WorkspacesActivation`), the
/// Grove-running guard, the lock that keeps the engine to one copy of Brow
/// (`WorkspacesEngineLock`), the menu-bar item and the panel. GroveAppKit never imports
/// BrowKit; this is where the two meet.
///
/// Nothing of the engine exists until Workspaces is wanted: no `AppState`, so no
/// read of Grove's config, no account adoption, no status-line reconcile, no timer.
/// The one exception is the introduction the notch's Workspaces button shows while it
/// is off — and even that reads nothing until the user adds a project.
@MainActor
public final class WorkspacesHost: ObservableObject {
    @Published public private(set) var activation: WorkspacesActivation = .off
    /// What Workspaces waits for while it is paused; nil otherwise.
    @Published public private(set) var pause: WorkspacesPause?
    /// The engine's state while Workspaces is wanted; nil while it is off.
    @Published public private(set) var state: AppState?
    /// Grove's accounts as its config has them, read without the engine while Workspaces
    /// is not on: an account whose status line it captured keeps running the wrapper
    /// under Claude Code whatever Workspaces does, so Settings keeps the switch that gives
    /// it back. Empty while Workspaces is on — the engine's state has them then.
    @Published public private(set) var dormantAccounts: [AccountConfig] = []
    /// What went wrong changing Grove's config while Workspaces is not on — giving a
    /// status line back, taking out an account whose folder is gone — for Settings.
    @Published public private(set) var captureError: String?
    /// Folders picked as projects in the introduction while Workspaces could not take
    /// them — paused, with Grove.app or another copy of Brow writing the same config —
    /// added once it runs. Not kept past a quit of Brow.
    @Published public private(set) var pendingProjects: [String] = []
    /// Told when the panel is ordered in or out (the notch latches its hover meanwhile).
    public var onPanelVisibilityChange: ((Bool) -> Void)?
    /// Opens Brow's Settings window where the panel asks for it: the footer's gear
    /// (Workspaces), the Accounts screen's link (Accounts).
    public var openSettings: ((WorkspacesSettingsLink) -> Void)?

    public let folders: WorkspacesFolders
    private let store: LimitsStore
    private let groveGuard: GroveAppGuard
    private let groveConfigExists: () -> Bool
    private let groveDefaults: () -> UserDefaults?
    private let watchRunningApps: RunningAppsWatch
    /// Held while this copy of Brow runs the engine; another copy that runs it first
    /// keeps this one paused.
    private let engineLock: WorkspacesEngineLock
    private var controller: WorkspacesMenuBarController?
    /// Keeps the running-apps watch alive while started.
    private var runningAppsWatch: AnyObject?
    /// Grove.app instances `quitGrove()` asked to quit, watched until they have.
    private var quitting: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// Keeps the notch's scan in step with the folders Workspaces knows.
    private var accountsWatch: AnyCancellable?
    private var started = false

    /// Starts telling `onChange` about every app that launches or quits, for as long as
    /// the returned object is kept.
    public typealias RunningAppsWatch = @MainActor (_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyObject

    /// NSWorkspace's list of running apps, observed. Not its launch and quit
    /// notifications: those leave out apps that run as agents (`LSUIElement`), which
    /// Grove.app is, as Brow is. The list is complete, and documented as observable.
    public static let watchWorkspaceApps: RunningAppsWatch = { onChange in
        NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { _, _ in
            Task { @MainActor in onChange() }
        }
    }

    public init(store: LimitsStore,
                folders: WorkspacesFolders = .live(),
                groveGuard: GroveAppGuard = GroveAppGuard(runningBundleIdentifiers: {
                    NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                }),
                groveConfigExists: (() -> Bool)? = nil,
                groveDefaults: @escaping () -> UserDefaults? = { UserDefaults(suiteName: GroveAppGuard.bundleIdentifiers[0]) },
                watchRunningApps: RunningAppsWatch? = nil) {
        self.store = store
        self.folders = folders
        self.groveGuard = groveGuard
        let configPath = folders.configFile.path
        self.groveConfigExists = groveConfigExists ?? { FileManager.default.fileExists(atPath: configPath) }
        self.groveDefaults = groveDefaults
        self.watchRunningApps = watchRunningApps ?? Self.watchWorkspaceApps
        self.engineLock = WorkspacesEngineLock(folders: folders)
    }

    /// Decides once, then again whenever Grove.app launches or quits, or the settings
    /// that decide change — and at every background tick of the engine, in case a
    /// launch or a quit went unreported.
    public func start() {
        guard !started else { return }
        started = true
        runningAppsWatch = watchRunningApps { [weak self] in self?.refreshIfChanged() }
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
        runningAppsWatch = nil
        quitting.removeAll()
        cancellables.removeAll()
        controller?.stop()
        controller = nil
        engineLock.release()
        started = false
    }

    /// Re-decides from the current settings, the Grove config and Grove.app.
    public func refresh() {
        apply(workspaces: store.settings.workspaces)
    }

    /// What `decide` says now, from the current settings, the Grove config and Grove.app.
    private var decision: WorkspacesActivation {
        WorkspacesActivation.decide(setting: store.settings.workspaces.enabled,
                                    groveConfigExists: groveConfigExists(),
                                    groveRunning: groveGuard.isGroveRunning)
    }

    /// An app launched or quit: re-decides only if that changes the answer, since most
    /// of them are not Grove.
    func refreshIfChanged() {
        if decision != activation { refresh() }
    }

    private func apply(workspaces settings: WorkspacesSettings) {
        var next = WorkspacesActivation.decide(setting: settings.enabled,
                                               groveConfigExists: groveConfigExists(),
                                               groveRunning: groveGuard.isGroveRunning)
        var waitsFor: WorkspacesPause? = next == .paused ? .groveRunning : nil
        // On in one copy of Brow at a time: the one holding the engine's lock.
        if next == .on, !engineLock.acquire() {
            next = .paused
            waitsFor = .anotherBrow
        }
        if next != .on { engineLock.release() }
        let previous = activation
        if next != previous || waitsFor != pause {
            BrowLog.workspaces.info("workspaces: \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)\(waitsFor.map { " (\($0))" } ?? "", privacy: .public)")
        }
        activation = next
        pause = waitsFor
        switch next {
        case .off:
            controller?.stop()
            controller = nil
            state = nil
            accountsWatch = nil
            store.runtimeExtraDirs = []
            pendingProjects = []
        case .paused:
            let controller = ensureController()
            controller.stopEngine()
            controller.notice = waitsFor == .anotherBrow ? anotherBrowNotice : groveRunningNotice
            controller.showsStatusItem = settings.showInMenuBar
            controller.start()
        case .on:
            recordFirstRunOnce()
            // Coming from paused or off, read Grove's config afresh: Grove.app may have
            // written it while Workspaces waited, and a state loaded before that would
            // save its old copy over it.
            if previous != .on, let stale = controller {
                stale.stop()
                controller = nil
                state = nil
                accountsWatch = nil
            }
            let controller = ensureController()
            controller.notice = nil
            controller.showsStatusItem = settings.showInMenuBar
            controller.start()
            controller.startEngine()
            // The projects picked while it waited, now that nothing else writes the config.
            if let state, !pendingProjects.isEmpty {
                let paths = pendingProjects
                pendingProjects = []
                for path in paths { state.addProject(at: path) }
            }
            // Accounts Workspaces knows outside ~/.claude and ~/.claude-accounts join the
            // notch's scan, so their limits show in the pickers too.
            if accountsWatch == nil, let state {
                accountsWatch = state.$config
                    .map { WorkspacesAccountJoin.extraDirs(for: $0.accounts) }
                    .removeDuplicates()
                    .sink { [weak store = self.store] dirs in store?.runtimeExtraDirs = dirs }
            }
        }
        // The store's, not the argument's: importing Grove's material just changed it.
        WindowSubstrateStyle.current = WindowSubstrateStyle(stored: store.settings.workspaces.panelMaterial)
        reloadDormantAccounts()
    }

    // MARK: - Status lines captured while Workspaces is not on

    /// The accounts whose status line runs Workspaces' wrapper while Workspaces is not on.
    public var dormantCaptures: [AccountConfig] { dormantAccounts.filter(\.monitoring) }

    /// What `account` is called where the notch shows it, with or without the engine: the
    /// name from Settings › Accounts, else Grove's own.
    public func displayName(for account: AccountConfig) -> String {
        store.label(forConfigDirs: account.allConfigDirs.map(expandTilde))?.name ?? account.name
    }

    /// Re-reads `dormantAccounts` from Grove's config. Reads only: no engine starts, and
    /// nothing is written.
    public func reloadDormantAccounts() {
        guard !isPreview else { return }
        let accounts = activation == .on || !FileManager.default.fileExists(atPath: folders.configFile.path)
            ? [] : ConfigStore(url: folders.configFile).load().config.accounts
        if accounts != dormantAccounts { dormantAccounts = accounts }
    }

    /// Gives `account`'s status line back while Workspaces is off: the command it had in
    /// place of the wrapper, in every folder of the login, and capture marked off in
    /// Grove's config so nothing turns it on again. Grove's config is read for just this,
    /// with no engine. Not while Grove.app runs (paused): it writes the same files.
    /// While Workspaces is on, the engine's own switch does this.
    public func releaseStatusLine(_ account: AccountConfig) {
        captureError = nil
        switch activation {
        case .on:
            if let state, let current = state.config.accounts.first(where: { $0.name == account.name }) {
                state.disableMonitoring(current)
            }
        case .paused:
            captureError = Self.pausedChangeNote(pause)
        case .off:
            captureError = withoutEngine { engine in
                if let current = engine.config.accounts.first(where: { $0.name == account.name }), current.monitoring {
                    engine.disableMonitoring(current)
                }
            }
        }
    }

    /// Takes `account` out of Workspaces' config, folder untouched: what Settings offers
    /// for an account whose folder is gone, which nothing else can change any more.
    public func removeAccount(_ account: AccountConfig) {
        captureError = nil
        switch activation {
        case .on:
            captureError = state.flatMap { state in state.attempt { state.removeAccount(name: account.name) } }
        case .paused:
            captureError = Self.pausedChangeNote(pause)
        case .off:
            captureError = withoutEngine { $0.removeAccount(name: account.name) }
        }
    }

    /// Makes one change to Grove's config while Workspaces is off: a state read for just
    /// this, no engine started, and the dormant list read again after. Not under the feet
    /// of another copy of Brow whose engine runs on this config. Returns what went wrong.
    private func withoutEngine(_ change: (AppState) -> Void) -> String? {
        guard engineLock.acquire() else { return Self.pausedChangeNote(.anotherBrow) }
        defer { engineLock.release() }
        let engine = AppState(folders: folders)
        engine.capturesByDefault = false
        engine.mayWrite = { [groveGuard] in !groveGuard.isGroveRunning }
        let failure = engine.attempt { change(engine) }
        reloadDormantAccounts()
        return failure
    }

    /// Why Grove's config can't be changed from here while Workspaces is paused.
    static func pausedChangeNote(_ pause: WorkspacesPause?) -> String {
        pause == .anotherBrow
            ? "Another copy of Brow runs Workspaces: make the change there, or quit it first."
            : "Quit Grove first: it writes the same settings."
    }

    /// Every captured status line back, as `releaseStatusLine` does one.
    public func releaseAllStatusLines() {
        for account in dormantCaptures { releaseStatusLine(account) }
    }

    private func ensureController() -> WorkspacesMenuBarController {
        if let controller { return controller }
        let state = AppState(folders: folders)
        // Brow asks before it edits an account's settings.json: capture is turned on
        // per account, in Settings › Accounts, or kept where Grove had it on.
        state.capturesByDefault = false
        // Never two engines writing one config.json: a Grove.app that started since the
        // last decision stops every write until Workspaces has paused.
        state.mayWrite = { [groveGuard] in !groveGuard.isGroveRunning }
        // The pickers show each account's limits, from the notch's own readings.
        state.limitsProvider = store
        state.onPanelMaterialChange = { [weak self] style in self?.setPanelMaterial(style) }
        // Sessions launch with Brow's own router and Brow's Path to claude, like every
        // sign-in Brow starts.
        state.browserRouter = AddAccountFlow.browserHelperPath ?? state.browserRouter
        state.claudePath = { [weak store = self.store] in store.flatMap { $0.settings.claudePath ?? $0.claudeDetected } }
        state.openSettings = { [weak self] link in
            self?.hidePanel()
            self?.openSettings?(link)
        }
        self.state = state
        let controller = WorkspacesMenuBarController(
            state: state, icon: BrowMark.templateImage(), fallbackTitle: "Brow",
            accessibilityLabel: "Brow Workspaces", showsStatusItem: store.settings.workspaces.showInMenuBar)
        controller.onVisibilityChange = { [weak self] visible in self?.onPanelVisibilityChange?(visible) }
        // Every background tick re-checks for Grove.app first: a tick that finds it pauses
        // Workspaces instead of running.
        controller.tickGate = { [weak self] in
            guard let self else { return false }
            self.refreshIfChanged()
            return self.activation == .on
        }
        self.controller = controller
        return controller
    }

    // MARK: - What the user can do

    /// Turns Workspaces on or off in Brow's own settings.
    public func setEnabled(_ on: Bool) {
        store.settings.workspaces.enabled = on
        refresh()
    }

    /// Asks Grove.app to quit; Workspaces starts when it has — told by the app itself,
    /// as well as by the running-apps watch.
    public func quitGrove() {
        for app in NSWorkspace.shared.runningApplications where GroveAppGuard.isGrove(app.bundleIdentifier) {
            let id = ObjectIdentifier(app)
            if quitting[id] == nil {
                quitting[id] = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
                    guard app.isTerminated else { return }
                    Task { @MainActor in
                        self?.quitting[id] = nil
                        self?.refresh()
                    }
                }
            }
            app.terminate()
        }
    }

    /// One background tick of the engine, as its timer runs it; for tests.
    func backgroundTick() async {
        await controller?.runBackgroundTick()
    }

    /// Offscreen renders and tests: this state and activation, nothing started.
    func preview(state: AppState?, activation: WorkspacesActivation, dormant: [AccountConfig] = []) {
        self.state = state
        self.activation = activation
        self.dormantAccounts = dormant
        isPreview = true
    }

    /// A preview's accounts are its own: nothing is read from disk for it.
    private var isPreview = false

    public var isPanelVisible: Bool { controller?.isPanelVisible == true }

    /// Whether the engine's launch work and background cadence are running.
    var isEngineRunning: Bool { controller?.isEngineRunning == true }

    /// The panel: Workspaces when it runs, the reason it is paused, or — while it is
    /// off — the introduction, from which a project can be added.
    public func showPanel() {
        // What it waits for may have gone without a word: another copy of Brow turning
        // Workspaces off quits no app.
        refreshIfChanged()
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
    // Internal, not private: the README's screenshots render them.

    var groveRunningNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "pause.circle",
            title: "Grove is still running",
            message: "Grove is now part of Brow, and Workspaces runs your Grove projects. It stays paused while Grove.app is open, so the two never edit the same files at once." + pendingNote,
            primary: .init("Quit Grove") { [weak self] in self?.quitGrove() })
    }

    var anotherBrowNotice: WorkspacesNotice {
        WorkspacesNotice(
            symbol: "pause.circle",
            title: "Workspaces is open in another Brow",
            message: "Another copy of Brow, a second install or a development build, is running Workspaces on the same projects. Workspaces runs in one copy at a time, so the two never edit the same files at once; it starts here when that copy quits." + pendingNote,
            primary: .init("Try Again") { [weak self] in self?.refresh() })
    }

    var introductionNotice: WorkspacesNotice {
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
        addProject(fromIntroduction: url.path)
        showPanel()
    }

    /// Turns Workspaces on with `path` as its project. Added at once only while the
    /// engine runs: paused, the config is another app's to write, so the folder waits in
    /// `pendingProjects` — the paused notice names it — and is added when Workspaces starts.
    func addProject(fromIntroduction path: String) {
        setEnabled(true)
        if activation == .on, let state {
            state.addProject(at: path)
        } else if !pendingProjects.contains(path) {
            pendingProjects.append(path)
            refresh()   // the notice now names it
        }
    }

    /// " “shop” is added when Workspaces starts.", after a paused notice's message.
    private var pendingNote: String {
        guard !pendingProjects.isEmpty else { return "" }
        let names = pendingProjects.map { "“\(($0 as NSString).lastPathComponent)”" }
        // English, like the sentence it ends: not the Mac's list format.
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return " \(list) \(names.count == 1 ? "is" : "are") added when Workspaces starts."
    }

    // MARK: - The first run

    /// Whether Workspaces runs, or will run, a setup Grove made — for the words Settings
    /// uses. Recorded the first time it runs; before that, a Grove config can only be
    /// Grove's, since Brow writes one only once Workspaces runs.
    public var isGroveSetup: Bool {
        store.settings.workspaces.groveSetup ?? groveConfigExists()
    }

    /// The first time Workspaces runs in Brow, before the engine writes anything: whether
    /// the setup is Grove's, and Grove.app's panel material, which it kept in its own
    /// defaults. Once each: the material's flag is set whether or not Grove had one.
    private func recordFirstRunOnce() {
        var settings = store.settings
        if settings.workspaces.groveSetup == nil {
            settings.workspaces.groveSetup = groveConfigExists()
        }
        if !settings.workspaces.importedGroveMaterial {
            if settings.workspaces.panelMaterial == nil,
               let raw = groveDefaults()?.string(forKey: WindowSubstrateStyle.groveDefaultsKey),
               WindowSubstrateStyle(rawValue: raw) != nil {
                settings.workspaces.panelMaterial = raw
            }
            settings.workspaces.importedGroveMaterial = true
        }
        if settings != store.settings { store.settings = settings }
    }

    // MARK: - Panel material

    /// Settings › Workspaces writes the material here.
    public func setPanelMaterial(_ style: WindowSubstrateStyle) {
        store.settings.workspaces.panelMaterial = style.rawValue
    }
}
