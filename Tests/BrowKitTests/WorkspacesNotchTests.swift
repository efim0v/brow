// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// Workspaces in the notch panel: the Projects section is there exactly while Workspaces is
/// wanted, every way in opens the panel pinned on it, a hand-off closes it, and the pickers
/// list Brow's accounts. The notch is a stand-in that records what it is asked; no window
/// and no folder picker ever appears.
@MainActor
final class WorkspacesNotchTests: XCTestCase {
    private var appDir: String!
    private var folders: WorkspacesFolders!
    private let now = MadeUpLimits.morning()

    override func setUpWithError() throws {
        appDir = try Fixture.tempDir("notch-host-app").path
        folders = .beside(configFile: try Fixture.tempDir("notch-host-grove").appendingPathComponent("config.json"))
    }

    /// The made-up accounts as the notch shows them.
    private func makeStore(count: Int = 3, hidden: [String] = [], enabled: Bool? = nil) throws -> LimitsStore {
        try MadeUpLimits.store(count: count, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = enabled
            for account in MadeUpLimits.all where hidden.contains(account.name) {
                settings.accounts[account.organization]?.hidden = true
            }
        }
    }

    private func makeHost(_ store: LimitsStore, groveConfig: Bool = true, groveRunning: Bool = false,
                          notch: FakeNotch) -> WorkspacesHost {
        let host = WorkspacesHost(store: store, folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: {
                                      groveRunning ? ["dev.artemefimov.grove3"] : ["dev.artemefimov.brow"]
                                  }),
                                  groveConfigExists: { groveConfig },
                                  watchRunningApps: { _ in NSObject() })
        host.notch = notch
        addTeardownBlock { @MainActor in host.stop() }
        return host
    }

    // MARK: - The section

    /// On and paused, the notch has Projects (paused, it says why); off, it has none.
    func testTheProjectsSectionIsThereExactlyWhileWorkspacesIsWanted() throws {
        let notch = FakeNotch()
        let host = makeHost(try makeStore(), notch: notch)
        XCTAssertNil(notch.sections.section(.projects), "not before it starts")
        host.start()
        XCTAssertEqual(host.activation, .on)
        XCTAssertNotNil(notch.sections.section(.projects))
        host.setEnabled(false)
        XCTAssertNil(notch.sections.section(.projects))

        let pausedNotch = FakeNotch()
        appDir = try Fixture.tempDir("notch-host-app-paused").path
        let paused = makeHost(try makeStore(), groveRunning: true, notch: pausedNotch)
        paused.start()
        XCTAssertEqual(paused.activation, .paused)
        XCTAssertNotNil(pausedNotch.sections.section(.projects), "paused, Projects says why")
        XCTAssertEqual(paused.pausedNotice.title, "Grove is still running")
    }

    /// The Brow menu's Show Projects and a reopen: the panel pinned on Projects while Workspaces
    /// is wanted, Settings › Workspaces while it is off.
    func testShowPanelOpensProjectsPinnedOrSettings() throws {
        let notch = FakeNotch()
        let host = makeHost(try makeStore(enabled: false), notch: notch)
        var settings: [WorkspacesSettingsLink] = []
        host.openSettings = { settings.append($0) }
        host.start()
        host.showPanel()
        XCTAssertEqual(settings, [.workspaces])
        XCTAssertEqual(notch.opened, [])

        host.setEnabled(true)
        host.showPanel()
        XCTAssertEqual(notch.opened, [.projects])
    }

    /// Go, Resume, Start session and Show in Finder hand the user to something else: the panel
    /// closes. An error the engine reports right after brings it back, where the error is shown.
    func testAHandOffClosesThePanelAndAnErrorRightAfterBringsItBack() async throws {
        let notch = FakeNotch()
        let host = makeHost(try makeStore(), notch: notch)
        host.start()
        let state = try XCTUnwrap(host.state)
        state.onHandOff?()
        XCTAssertEqual(notch.dismissals, [.handOff])
        state.actionError = "cmux isn't running, so Go can't switch to the session."
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(notch.opened, [.projects])

        // Settings from a project's gear closes the panel too.
        state.openSettings?(.workspaces)
        XCTAssertEqual(notch.dismissals, [.handOff, .settings])
    }

    /// "Add a folder…": the notch makes way for the system's folder picker and opens on Projects
    /// again. The stand-in never runs the picker.
    func testAddingAFolderMakesWayForTheSystemPanel() throws {
        let notch = FakeNotch()
        let host = makeHost(try makeStore(), notch: notch)
        host.start()
        host.addFolder()
        XCTAssertEqual(notch.outside, [.projects])
        XCTAssertNotNil(host.state?.addFolder, "the screens' own Add buttons use it")
    }

    /// The section's refresh waits a quarter of a second in view: a pointer that only passes
    /// over the notch starts no scan. Leaving the view stops it at once.
    func testProjectsRefreshOnlyOnceInViewForAQuarterSecond() async throws {
        let host = makeHost(try makeStore(), notch: FakeNotch())
        host.start()
        let state = try XCTUnwrap(host.state)
        let section = ProjectsSection(host: host)
        section.visibilityChanged(true)
        XCTAssertFalse(state.isPanelOpen)
        try await Task.sleep(nanoseconds: 120_000_000)
        section.visibilityChanged(false)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(state.isPanelOpen, "passed over: never open")
        section.visibilityChanged(true)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(state.isPanelOpen)
        section.visibilityChanged(false)
        XCTAssertFalse(state.isPanelOpen)
    }

    /// Esc on Projects: the search first, then a screen back — never out of a workspace being
    /// created — and at the list it is the panel's, which closes.
    func testEscapeOnProjects() throws {
        let host = makeHost(try makeStore(), notch: FakeNotch())
        host.start()
        let state = try XCTUnwrap(host.state)
        let section = ProjectsSection(host: host)
        XCTAssertFalse(section.escape(), "at the list: the panel closes")
        state.searchQuery = "checkout"
        XCTAssertTrue(section.escape())
        XCTAssertEqual(state.searchQuery, "")
        state.open(.otherSessions)
        state.blocksBack = true
        XCTAssertTrue(section.escape())
        XCTAssertEqual(state.route, .otherSessions, "a creation runs: Esc waits")
        state.blocksBack = false
        XCTAssertTrue(section.escape())
        XCTAssertEqual(state.route, .projects)
    }

    // MARK: - Brow's accounts

    /// Every picker lists Brow's visible accounts in Brow's order, by Brow's names, each in its
    /// calendar colour; Brow's accounts Grove did not know are adopted, named by their email.
    func testThePickersListBrowsAccounts() throws {
        let store = try makeStore(count: 4, hidden: ["Work"])
        let host = makeHost(store, notch: FakeNotch())
        host.start()
        let state = try XCTUnwrap(host.state)
        let visible = store.rows.map(\.name)
        XCTAssertFalse(visible.contains("Work"), "fixture check: Work is hidden in Brow")
        XCTAssertEqual(state.accounts.map(\.name), visible)
        XCTAssertEqual(state.accounts.map(\.dot), store.rows.indices.map { Optional(NotchTheme.account($0)) })
        XCTAssertEqual(state.accounts.map(\.config.name), store.rows.map { $0.account.email ?? "" },
                       "adopted under the name Grove gives accounts: the email")
        XCTAssertFalse(state.accounts.contains { $0.name == "Work" }, "hidden in Brow, offered nowhere")
    }

    /// An account only Grove's config knows stays in it, for its old sessions, but no picker
    /// offers it.
    func testAnAccountOnlyGroveKnowsIsNeverOffered() throws {
        try ConfigStore(url: folders.configFile).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "old@example.com", configDir: "/Volumes/ext/claude-old")]))
        let host = makeHost(try makeStore(count: 2), notch: FakeNotch())
        host.start()
        let state = try XCTUnwrap(host.state)
        XCTAssertTrue(state.config.accounts.contains { $0.name == "old@example.com" })
        XCTAssertFalse(state.accounts.contains { $0.config.name == "old@example.com" })
        XCTAssertEqual(state.accounts.count, 2)
    }

    /// A session launched here runs as the account it says, whatever the shell exports: the
    /// default account by removing `CLAUDE_CONFIG_DIR`, any other by setting it.
    func testLaunchesStartWithBrowsEnvironment() throws {
        let host = makeHost(try makeStore(), notch: FakeNotch())
        host.start()
        let state = try XCTUnwrap(host.state)
        let launch = try XCTUnwrap(state.launchEnvironment)
        let home = NSHomeDirectory()
        XCTAssertTrue(launch(home + "/.claude").hasPrefix("env -u CLAUDE_CONFIG_DIR"))
        XCTAssertTrue(launch(home + "/.claude-accounts/work").hasPrefix("CLAUDE_CONFIG_DIR='\(home)/.claude-accounts/work'"))
        let command = ClaudeService.launchCommand(account: AccountConfig(name: "me", configDir: "~/.claude"),
                                                  claude: "/opt/homebrew/bin/claude",
                                                  environment: launch(home + "/.claude"))
        XCTAssertTrue(command.hasPrefix("env -u CLAUDE_CONFIG_DIR"), command)
        XCTAssertFalse(command.contains("CLAUDE_CONFIG_DIR="), command)
    }
}

/// The notch as Workspaces sees it, recording what it is asked.
@MainActor
final class FakeNotch: NotchPresenting {
    let sections = NotchSections()
    let badges = NotchBadges()
    private(set) var opened: [NotchTab] = []
    private(set) var dismissals: [NotchDismissal] = []
    private(set) var outside: [NotchTab] = []
    private var showing: NotchTab?

    func openPinned(on tab: NotchTab) {
        opened.append(tab)
        showing = tab
    }

    func isShowing(_ tab: NotchTab) -> Bool { showing == tab }

    func dismiss(_ reason: NotchDismissal) {
        dismissals.append(reason)
        showing = nil
    }

    func runOutsideNotch(reopeningOn tab: NotchTab, _ work: @escaping @MainActor () -> Void) {
        outside.append(tab)
    }
}
