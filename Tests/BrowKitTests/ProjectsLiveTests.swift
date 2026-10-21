// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import GroveAppKit
import GroveCore
@testable import BrowKit

/// What the notch shows of the sessions that run, whichever section is in front: the yellow
/// count on Projects, each account's "N live" chip on Limits and what it opens, the keyboard
/// on a suggestion, and the previews setting. Made-up accounts and records; the processes
/// are the test's own `/bin/sleep`.
@MainActor
final class ProjectsLiveTests: XCTestCase {
    private var appDir: String!
    private var folders: WorkspacesFolders!
    private let now = MadeUpLimits.morning()

    override func setUpWithError() throws {
        appDir = try Fixture.tempDir("projects-live-app").path
        folders = .beside(configFile: try Fixture.tempDir("projects-live-grove").appendingPathComponent("config.json"))
    }

    private func makeHost(_ notch: FakeNotch) throws -> (WorkspacesHost, LimitsStore) {
        let store = try MadeUpLimits.store(count: 3, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = true
        }
        let host = WorkspacesHost(store: store, folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
        host.notch = notch
        addTeardownBlock { @MainActor in host.stop() }
        host.start()
        return (host, store)
    }

    /// The Grove account the made-up Work account was adopted as.
    private func workAccount(_ state: AppState) throws -> AccountConfig {
        try XCTUnwrap(state.workspacesAccount(named: try XCTUnwrap(state.accounts.first { $0.name == "Work" }).config.name)?.config)
    }

    /// The switch's yellow count is every session stopped on the user; each account's chip
    /// counts the sessions running as it, by the folder Limits lists it by.
    func testTheCountAndTheChipsFollowWhatRuns() throws {
        let notch = FakeNotch()
        let (host, store) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        let work = try workAccount(state)
        let live = [
            LiveProcess(pid: 1, sessionId: "a", cwd: "/w", status: "waiting", accountName: work.name, waitingFor: "permission prompt"),
            LiveProcess(pid: 2, sessionId: "b", cwd: "/w", status: "busy", accountName: work.name),
            LiveProcess(pid: 3, sessionId: "c", cwd: "/w", status: "waiting", accountName: work.name,
                        waitingFor: "input needed", entrypoint: "sdk-ts"),
        ]
        host.syncBadges(live: live, state: state)
        XCTAssertEqual(notch.badges.projectsNeedYou, 1, "an SDK's run waiting on input is no one's question")
        let workRow = try XCTUnwrap(store.rows.first { $0.name == "Work" })
        XCTAssertEqual(notch.badges.live(configDir: workRow.account.configDir), 2)
        XCTAssertEqual(notch.badges.live(configDir: workRow.account.configDir + "/"), 2, "however the folder is spelled")
        XCTAssertEqual(notch.badges.liveByConfigDir.count, 1)
    }

    /// An account's chip opens Projects pinned, narrowed to the account; ✕ on the filter
    /// chip shows every account again.
    func testAnAccountsChipOpensItsSessions() throws {
        let notch = FakeNotch()
        let (host, store) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        let workRow = try XCTUnwrap(store.rows.first { $0.name == "Work" })
        let open = try XCTUnwrap(notch.badges.openAccount, "set while Workspaces is wanted")
        state.searchQuery = "webhook"
        open(workRow.account.configDir)
        XCTAssertEqual(state.accountFilter, try workAccount(state).name)
        XCTAssertEqual(state.searchQuery, "", "the search gives way to the filter")
        XCTAssertEqual(notch.opened, [.projects])
        state.filter(account: nil)
        XCTAssertNil(state.accountFilter)

        host.setEnabled(false)
        XCTAssertNil(notch.badges.openAccount, "no chips while Workspaces is off")
    }

    /// The panel opening on any section reads what runs again, for the count: here a record
    /// of the test's own process, waiting on a permission prompt.
    func testOpeningThePanelReadsWhatRuns() async throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        let cfg = try Fixture.tempDir("projects-live-cfg").path
        try FileManager.default.createDirectory(atPath: cfg + "/sessions", withIntermediateDirectories: true)
        state.config.accounts.append(AccountConfig(name: "made-up", configDir: cfg))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        addTeardownBlock { sleeper.terminate(); sleeper.waitUntilExit() }
        let started = try XCTUnwrap(SessionRegistry.startTime(of: sleeper.processIdentifier))
        let record = #"{"pid":\#(sleeper.processIdentifier),"sessionId":"s-ask","cwd":"/tmp","status":"waiting","waitingFor":"permission prompt","procStart":"\#(started)"}"#
        try Data(record.utf8).write(to: URL(fileURLWithPath: cfg + "/sessions/\(sleeper.processIdentifier).json"))

        let section = try XCTUnwrap(notch.sections.section(.projects))
        section.panelOpenChanged(true)
        let deadline = Date().addingTimeInterval(4)
        while notch.badges.projectsNeedYou == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(notch.badges.projectsNeedYou, 1)
        XCTAssertEqual(state.liveSessions.map(\.sessionId), ["s-ask"])
    }

    /// ↓ reaches a suggestion before the sessions; ↩ adds it, ⌫ turns it down.
    func testTheKeyboardOnASuggestion() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        let first = ProjectSuggestion(path: "/Users/demo/Code/harbor-api", pids: [7], cwds: ["/Users/demo/Code/harbor-api"])
        let second = ProjectSuggestion(path: "/Users/demo/Code/fleet", pids: [8], cwds: ["/Users/demo/Code/fleet"])
        state.mayWrite = { false }    // nothing saved beside the test's config
        let section = try XCTUnwrap(notch.sections.section(.projects))
        setSuggestions(state, [first, second])
        XCTAssertTrue(section.handleKey(.down))
        XCTAssertEqual(state.focusedSuggestion, first)
        XCTAssertTrue(section.handleKey(.delete))
        XCTAssertEqual(state.suggestions, [second])
        XCTAssertTrue(state.config.dismissedSuggestions.contains(first.path))
        XCTAssertTrue(section.handleKey(.down))
        XCTAssertEqual(state.focusedSuggestion, second)
        XCTAssertTrue(section.handleKey(.open))
        XCTAssertTrue(state.config.projects.contains { $0.path == second.path })
    }

    private func setSuggestions(_ state: AppState, _ suggestions: [ProjectSuggestion]) {
        state.suggestions = suggestions
    }

    /// Settings › Workspaces › Show message previews reaches the rows at once.
    func testThePreviewsSwitchReachesTheRows() throws {
        let notch = FakeNotch()
        let (host, store) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        XCTAssertTrue(state.showsMessagePreviews)
        host.showsMessagePreviews = false
        XCTAssertFalse(store.settings.workspaces.showMessagePreviews)
        XCTAssertFalse(state.showsMessagePreviews)
        host.showsMessagePreviews = true
        XCTAssertTrue(state.showsMessagePreviews)
    }

    /// The footer's line is drawn again the moment what it counts changes — a letter typed in
    /// the search, a scan — not at its next tick, five seconds on.
    func testTheFooterLineFollowsTheEngineAtOnce() async throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        // Closed, so no tick of its own draws it again: only what it watches does.
        let view = NSHostingView(rootView: ProjectsFooterStatus(host: host).fixedSize()
            .environment(\.groveIsShowing, false))
        // The host settles first (the engine's start publishes), so nothing else draws it again.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        view.layoutSubtreeIfNeeded()
        let before = view.fittingSize.width
        state.searchQuery = "webhook"
        try? await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, before + 60,
                             "“0 matches for “webhook” · closed sessions included” at once")
    }

    /// Before the first scan the footer counts the projects, in words that agree with the count.
    func testTheFooterCountsTheProjectsBeforeTheFirstScan() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        state.mayWrite = { false }
        state.config.projects = [ProjectConfig(name: "acme-shop", path: "/Users/demo/Code/acme-shop")]
        XCTAssertEqual(ProjectsFooterStatus.line(host: host, state: state, now: now), "1 project")
        state.config.projects.append(ProjectConfig(name: "field-notes", path: "/Users/demo/Code/field-notes"))
        XCTAssertEqual(ProjectsFooterStatus.line(host: host, state: state, now: now), "2 projects")
    }
}
