// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// Workspaces in the notch panel: the Projects section is there exactly while Workspaces is
/// wanted, every way in opens the panel pinned on it, and a hand-off closes it. The notch is a stand-in that records what it is asked; no window,
/// no menu-bar item and no folder picker ever appears.
@MainActor
final class WorkspacesNotchTests: XCTestCase {
    private var appDir: String!
    private var folders: WorkspacesFolders!
    private let now = MadeUpLimits.morning()

    override func setUpWithError() throws {
        appDir = try Fixture.tempDir("notch-host-app").path
        folders = .beside(configFile: try Fixture.tempDir("notch-host-grove").appendingPathComponent("config.json"))
    }

    /// The made-up accounts as the notch shows them, Workspaces' menu-bar item off.
    private func makeStore(count: Int = 3, enabled: Bool? = nil) throws -> LimitsStore {
        try MadeUpLimits.store(count: count, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = enabled
            settings.workspaces.showInMenuBar = false
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

    /// The menu-bar item opens Projects, and closes the panel when it already shows them.
    func testTheStatusItemTogglesProjects() throws {
        let notch = FakeNotch()
        let host = makeHost(try makeStore(), notch: notch)
        host.start()
        host.statusItemClicked()
        XCTAssertEqual(notch.opened, [.projects])
        host.statusItemClicked()
        XCTAssertEqual(notch.dismissals, [.escape])
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
