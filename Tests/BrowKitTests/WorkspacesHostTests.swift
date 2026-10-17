// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// Brow hosting Workspaces: nothing of the engine exists until it is wanted, it pauses
/// while Grove.app runs, and Grove's panel material comes along once. No menu-bar item is
/// ever put up here (the settings keep it off), so a test run never touches the bar.
@MainActor
final class WorkspacesHostTests: XCTestCase {
    private var home: URL!
    private var appDir: String!
    private var folders: WorkspacesFolders!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("host-home")
        appDir = try Fixture.tempDir("host-app").path
        folders = .beside(configFile: try Fixture.tempDir("host-grove").appendingPathComponent("config.json"))
        defaultsSuite = "brow-tests-grove-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeStore(enabled: Bool? = nil) throws -> LimitsStore {
        var settings = BrowSettings()
        settings.workspaces.enabled = enabled
        settings.workspaces.showInMenuBar = false
        try BrowSettingsStore(directory: appDir).save(settings)
        let creds = SilentCreds()
        return LimitsStore(deps: .init(
            directory: AccountDirectory(home: home.path, credentials: creds),
            keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                claudePath: "/x/claude", allowPromptFallback: { false }),
            client: OAuthUsageClient(fetcher: UnusedFetcher(), appVersion: "t",
                                     cacheSeconds: 30, backoffCap: 300, credentials: creds),
            snapshotStore: LimitSnapshotStore(directory: appDir),
            settingsStore: BrowSettingsStore(directory: appDir),
            now: { Date() }))
    }

    private func makeHost(_ store: LimitsStore, groveConfig: Bool, groveRunning: Bool,
                          groveMaterial: String? = nil) -> WorkspacesHost {
        let suite = defaultsSuite!
        if let groveMaterial { UserDefaults(suiteName: suite)?.set(groveMaterial, forKey: WindowSubstrateStyle.groveDefaultsKey) }
        let host = WorkspacesHost(store: store, folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: {
                                      groveRunning ? ["dev.artemefimov.grove3"] : ["dev.artemefimov.brow"]
                                  }),
                                  groveConfigExists: { groveConfig },
                                  groveDefaults: { UserDefaults(suiteName: suite) })
        addTeardownBlock { @MainActor in host.stop() }
        return host
    }

    /// A Brow-only Mac: off, and no engine state at all — so Grove's config is not even read.
    func testABrowOnlyMacRunsNothingOfTheEngine() throws {
        let host = makeHost(try makeStore(), groveConfig: false, groveRunning: false)
        host.start()
        XCTAssertEqual(host.activation, .off)
        XCTAssertNil(host.state)
        XCTAssertFalse(host.isEngineRunning)
    }

    /// Someone who used Grove: on by itself, the engine running, and editing nobody's
    /// settings.json unasked.
    func testAGroveConfigTurnsItOnWithCaptureOffByDefault() throws {
        let host = makeHost(try makeStore(), groveConfig: true, groveRunning: false)
        host.start()
        XCTAssertEqual(host.activation, .on)
        XCTAssertTrue(host.isEngineRunning)
        XCTAssertEqual(host.state?.capturesByDefault, false)
        XCTAssertEqual(host.state?.folders, folders)
    }

    func testWhileGroveAppRunsItIsPausedWithNoEngine() throws {
        let host = makeHost(try makeStore(), groveConfig: true, groveRunning: true)
        host.start()
        XCTAssertEqual(host.activation, .paused)
        XCTAssertFalse(host.isEngineRunning)
    }

    /// When Grove.app quits, Workspaces starts on a fresh read of Grove's config: the
    /// copy read while paused may be older than what Grove saved on its way out.
    func testGroveQuittingStartsTheEngineOnAFreshState() throws {
        final class Running: @unchecked Sendable { var grove = true }
        let running = Running()
        let host = WorkspacesHost(store: try makeStore(), folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: {
                                      running.grove ? ["dev.artemefimov.grove3"] : []
                                  }),
                                  groveConfigExists: { true }, groveDefaults: { nil })
        addTeardownBlock { @MainActor in host.stop() }
        host.start()
        XCTAssertEqual(host.activation, .paused)
        let whilePaused = try XCTUnwrap(host.state)
        running.grove = false
        host.refresh()
        XCTAssertEqual(host.activation, .on)
        XCTAssertTrue(host.isEngineRunning)
        XCTAssertFalse(host.state === whilePaused, "a new state, read after Grove quit")
    }

    // MARK: - Grove.app launching or quitting while Brow runs

    /// Running apps as a test drives them: Grove's flag, and the running-apps watch the
    /// host installs, which the test fires the way NSWorkspace's list would.
    private final class RunningApps: @unchecked Sendable {
        var grove = false
        var onChange: (@MainActor @Sendable () -> Void)?
        weak var token: NSObject?
    }

    private func makeWatchedHost(_ apps: RunningApps, store: LimitsStore) -> WorkspacesHost {
        let host = WorkspacesHost(store: store, folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: {
                                      apps.grove ? ["dev.artemefimov.grove3"] : ["dev.artemefimov.brow"]
                                  }),
                                  groveConfigExists: { true }, groveDefaults: { nil },
                                  watchRunningApps: { onChange in
                                      apps.onChange = onChange
                                      let token = NSObject()
                                      apps.token = token
                                      return token
                                  })
        addTeardownBlock { @MainActor in host.stop() }
        return host
    }

    /// Grove.app started after Brow (both login items, say): the running-apps list
    /// changes, and Workspaces pauses at once; when Grove quits, it runs again. No one
    /// calls `refresh()`.
    func testGroveStartingOrQuittingIsNoticedWithoutARefresh() throws {
        let apps = RunningApps()
        let host = makeWatchedHost(apps, store: try makeStore())
        host.start()
        XCTAssertEqual(host.activation, .on)
        XCTAssertNotNil(apps.onChange, "the host watches the running apps")

        apps.grove = true
        apps.onChange?()
        XCTAssertEqual(host.activation, .paused)
        XCTAssertFalse(host.isEngineRunning)

        apps.grove = false
        apps.onChange?()
        XCTAssertEqual(host.activation, .on)
        XCTAssertTrue(host.isEngineRunning)
    }

    /// Some other app launching changes nothing: the engine is not restarted.
    func testAnotherAppLaunchingLeavesTheEngineAlone() throws {
        let apps = RunningApps()
        let host = makeWatchedHost(apps, store: try makeStore())
        host.start()
        let state = try XCTUnwrap(host.state)
        apps.onChange?()
        XCTAssertTrue(host.state === state)
        XCTAssertTrue(host.isEngineRunning)
    }

    /// A launch nothing reported is caught at the next background tick, which then
    /// pauses Workspaces instead of running.
    func testABackgroundTickChecksForGroveFirst() async throws {
        let apps = RunningApps()
        let host = makeWatchedHost(apps, store: try makeStore())
        host.start()
        XCTAssertTrue(host.isEngineRunning)
        apps.grove = true
        await host.backgroundTick()
        XCTAssertEqual(host.activation, .paused)
        XCTAssertFalse(host.isEngineRunning)
    }

    /// And until then, nothing is written to Grove's config: Grove.app writes it too.
    func testNoConfigWriteWhileGroveRuns() throws {
        let apps = RunningApps()
        let host = makeWatchedHost(apps, store: try makeStore())
        host.start()
        let state = try XCTUnwrap(host.state)
        apps.grove = true
        state.addProject(at: "/Users/demo/Code/shop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folders.configFile.path), "nothing saved")
        XCTAssertTrue(state.actionError?.contains("Grove.app is running") == true, state.actionError ?? "")
        apps.grove = false
        state.addProject(at: "/Users/demo/Code/notes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders.configFile.path))
    }

    func testStoppingReleasesTheWatch() throws {
        let apps = RunningApps()
        let host = makeWatchedHost(apps, store: try makeStore())
        host.start()
        XCTAssertNotNil(apps.token)
        host.stop()
        XCTAssertNil(apps.token)
    }

    // MARK: - Status lines captured while Workspaces is off

    /// An account Grove captured, its settings.json pointing at the wrapper. Returns the
    /// account folder.
    private func capturedAccount(original: String) throws -> URL {
        let dir = try Fixture.tempDir("host-captured")
        try #"{"statusLine":{"type":"command","command":"\#(original)"},"model":"opus"}"#
            .write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let saved = try StatuslineInstaller(scriptDir: folders.bin).install(configDir: dir.path)
        try ConfigStore(url: folders.configFile).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "work", configDir: dir.path, monitoring: true, savedStatusline: saved)]))
        return dir
    }

    private func statusLine(_ dir: URL) throws -> String? {
        let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Workspaces turned off: the wrapper keeps running under Claude Code, so Settings
    /// still lists the account, and giving its status line back works with no engine.
    func testAStatusLineCapturedBeforeCanBeGivenBackWithWorkspacesOff() throws {
        let dir = try capturedAccount(original: "/bin/echo mine")
        let host = makeHost(try makeStore(enabled: false), groveConfig: true, groveRunning: false)
        host.start()
        XCTAssertEqual(host.activation, .off)
        XCTAssertEqual(host.dormantCaptures.map(\.name), ["work"], "read without the engine")
        XCTAssertNil(host.state)
        XCTAssertNotEqual(try statusLine(dir), "/bin/echo mine", "fixture: the wrapper is in place")

        host.releaseStatusLine(host.dormantCaptures[0])

        XCTAssertNil(host.captureError)
        XCTAssertEqual(try statusLine(dir), "/bin/echo mine")
        XCTAssertTrue(host.dormantCaptures.isEmpty)
        let account = try XCTUnwrap(ConfigStore(url: folders.configFile).load().config.accounts.first)
        XCTAssertFalse(account.monitoring)
        XCTAssertTrue(account.monitoringDisabledByUser, "so nothing turns it on again")
        XCTAssertNil(host.state, "still no engine")
        XCTAssertFalse(host.isEngineRunning)
    }

    /// Not while Grove.app runs: it writes the same config.
    func testNotWhileGroveRuns() throws {
        let dir = try capturedAccount(original: "/bin/echo mine")
        let before = try statusLine(dir)
        let host = makeHost(try makeStore(), groveConfig: true, groveRunning: true)
        host.start()
        XCTAssertEqual(host.activation, .paused)
        XCTAssertEqual(host.dormantCaptures.map(\.name), ["work"])
        host.releaseStatusLine(host.dormantCaptures[0])
        XCTAssertEqual(try statusLine(dir), before, "left as it was")
        XCTAssertEqual(host.captureError, "Quit Grove first: it writes the same settings.")
    }

    /// Settings no longer says that, off, nothing of Workspaces runs: a captured status
    /// line does, and the text says so.
    func testTheOffTextNamesTheCapturedStatusLines() {
        XCTAssertFalse(WorkspacesSettingsTab.explanation.contains("nothing is read or written"))
        XCTAssertTrue(WorkspacesSettingsTab.explanation.contains("until you turn capture off"))
        XCTAssertTrue(DormantCaptureSwitch.explanation(paused: true).contains("Quit Grove"))
    }

    /// While Workspaces is on, the engine's state has the accounts.
    func testOnTheDormantListIsEmpty() throws {
        _ = try capturedAccount(original: "/bin/echo mine")
        let host = makeHost(try makeStore(), groveConfig: true, groveRunning: false)
        host.start()
        XCTAssertEqual(host.activation, .on)
        XCTAssertTrue(host.dormantAccounts.isEmpty)
    }

    /// Workspaces' accounts outside the usual folders join the notch's scan, and the
    /// pickers read the notch's numbers.
    func testWorkspacesAccountsJoinTheScanAndThePickersReadTheStore() throws {
        try ConfigStore(url: folders.configFile).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "old", configDir: "/Volumes/ext/claude-old")]))
        let store = try makeStore()
        let host = makeHost(store, groveConfig: true, groveRunning: false)
        host.start()
        XCTAssertEqual(store.runtimeExtraDirs, ["/Volumes/ext/claude-old"])
        XCTAssertTrue(host.state?.limitsProvider === store)
        host.setEnabled(false)
        XCTAssertEqual(store.runtimeExtraDirs, [], "off, the scan is the notch's own again")
    }

    func testTurningItOffTearsTheEngineDown() throws {
        let store = try makeStore()
        let host = makeHost(store, groveConfig: true, groveRunning: false)
        host.start()
        XCTAssertTrue(host.isEngineRunning)
        host.setEnabled(false)
        XCTAssertEqual(host.activation, .off)
        XCTAssertNil(host.state)
        XCTAssertEqual(store.settings.workspaces.enabled, false, "the choice is Brow's own setting")
        host.setEnabled(true)
        XCTAssertEqual(host.activation, .on)
    }

    /// Grove.app's panel material comes along the first time Workspaces runs, once.
    func testGrovesPanelMaterialIsCopiedOnce() throws {
        let store = try makeStore()
        let host = makeHost(store, groveConfig: true, groveRunning: false, groveMaterial: "visualEffect")
        host.start()
        XCTAssertEqual(store.settings.workspaces.panelMaterial, "visualEffect")
        XCTAssertTrue(store.settings.workspaces.importedGroveMaterial)
        XCTAssertEqual(WindowSubstrateStyle.current, .visualEffect)

        // A later choice in Brow is not overwritten by Grove's.
        host.setPanelMaterial(.liquidGlass)
        host.refresh()
        XCTAssertEqual(store.settings.workspaces.panelMaterial, "liquidGlass")
        WindowSubstrateStyle.current = .liquidGlass
    }

    /// Off, nothing is copied either: a Brow-only user's config.json is not written.
    func testOffCopiesNothing() throws {
        let store = try makeStore()
        let host = makeHost(store, groveConfig: false, groveRunning: false, groveMaterial: "visualEffect")
        host.start()
        XCTAssertNil(store.settings.workspaces.panelMaterial)
        XCTAssertFalse(store.settings.workspaces.importedGroveMaterial)
    }

    // MARK: - fixture

    private final class SilentCreds: CredentialsReading, @unchecked Sendable {
        func token(configDir: String) -> ClaudeToken? { nil }
        func invalidate(configDir: String) {}
    }

    private final class UnusedFetcher: UsageFetching, @unchecked Sendable {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            XCTFail("hosting Workspaces fetches nothing")
            return (Data(), 500)
        }
    }
}
