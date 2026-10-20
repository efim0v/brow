// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
import GroveCore
@testable import GroveAppKit

/// What Workspaces needs from the app that shows its screens in a panel: the host's accounts
/// in every picker, the launch form as a screen of its own, the session menu that took over
/// the Claude tab, the keyboard on the Projects list, and the refresh that waits for a panel
/// actually looked at. Everything lives beside a temporary config file.
@MainActor
final class AppStateHostTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureLite.tempDir("host-state")
    }

    private func dir(_ name: String) -> String { root.appendingPathComponent(name).path }

    private func makeState(accounts: [AccountConfig] = [], projects: [ProjectConfig] = []) throws -> AppState {
        let url = root.appendingPathComponent("config.json")
        try ConfigStore(url: url).save(GroveConfig(version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
                                                   projects: projects, accounts: accounts))
        var folders = WorkspacesFolders.beside(configFile: url)
        folders.canonicalDir = dir("personal")
        let state = AppState(configStore: ConfigStore(url: url), folders: folders)
        state.cmuxOverride = stubbedCmux()   // never the real cmux
        return state
    }

    private func host(_ name: String, _ folder: String, email: String? = nil, aliases: [String] = []) -> HostAccount {
        HostAccount(name: name, plan: "Max 5x", email: email, configDirs: [dir(folder)] + aliases.map(dir),
                    dot: .orange)
    }

    // MARK: - Accounts

    /// Without a host the pickers list Grove's own accounts; with one, the host's, in the host's
    /// order and by its names — joined to Grove's entries by folder, alias folders included.
    func testThePickersListTheHostsAccountsJoinedByFolder() throws {
        let state = try makeState(accounts: [
            AccountConfig(name: "work@example.com", configDir: dir("work")),
            AccountConfig(name: "me@example.com", configDir: dir("personal"), aliasDirs: [dir("personal-2")]),
            AccountConfig(name: "old@example.com", configDir: dir("old")),
        ])
        XCTAssertEqual(state.accounts.map(\.config.name), ["work@example.com", "me@example.com", "old@example.com"])

        state.hostAccounts = [host("Personal", "personal-2"), host("Work", "work")]
        XCTAssertEqual(state.accounts.map(\.name), ["Personal", "Work"], "the host's order and names")
        XCTAssertEqual(state.accounts.map(\.config.name), ["me@example.com", "work@example.com"])
        XCTAssertEqual(state.accounts.map(\.plan), ["Max 5x", "Max 5x"])
        XCTAssertEqual(state.dot(forAccountNamed: "work@example.com"), .orange)
        XCTAssertNil(state.workspacesAccount(named: "old@example.com"), "only Grove knows it: never offered")
        XCTAssertTrue(state.config.accounts.contains { $0.name == "old@example.com" }, "but kept for its sessions")
    }

    /// A host account Grove has no entry for is adopted under its email, its other folders as
    /// aliases, once; an account Grove knows by any of its folders is left as it is.
    func testHostAccountsGroveDoesNotKnowAreAdoptedOnce() throws {
        let state = try makeState(accounts: [AccountConfig(name: "work@example.com", configDir: dir("work"))])
        state.hostAccounts = [host("Work", "work-b", email: "work@example.com", aliases: ["work"]),
                              host("Side", "side", email: "side@example.com", aliases: ["side-2"])]
        XCTAssertTrue(state.adoptHostAccounts())
        XCTAssertEqual(state.config.accounts.map(\.name), ["work@example.com", "side@example.com"])
        let side = try XCTUnwrap(state.config.accounts.last)
        XCTAssertEqual(expandTilde(side.configDir), dir("side"))
        XCTAssertEqual(side.aliasDirs.map(expandTilde), [dir("side-2")])
        XCTAssertFalse(state.adoptHostAccounts(), "nothing new the second time")
        let saved = ConfigStore(url: root.appendingPathComponent("config.json")).load().config
        XCTAssertEqual(saved.accounts.map(\.name), ["work@example.com", "side@example.com"], "written to the config")
        XCTAssertEqual(state.accounts.map(\.name), ["Work", "Side"])
    }

    /// A single click launches as the project's default when a picker offers it, otherwise as
    /// the first account offered.
    func testTheDefaultLaunchAccountIsOneThePickersOffer() throws {
        let project = ProjectConfig(name: "acme-shop", path: dir("acme-shop"), defaultAccount: "old@example.com")
        let state = try makeState(accounts: [AccountConfig(name: "old@example.com", configDir: dir("old")),
                                             AccountConfig(name: "work@example.com", configDir: dir("work"))],
                                  projects: [project])
        state.selectedProjectID = project.id
        XCTAssertEqual(state.defaultLaunchAccount?.name, "old@example.com", "no host: Grove's own")
        state.hostAccounts = [host("Work", "work")]
        XCTAssertEqual(state.defaultLaunchAccount?.name, "work@example.com",
                       "a default no picker offers falls back to the first one offered")
    }

    // MARK: - The launch form

    /// New session and Resume with options push the form over the screen they were asked from;
    /// Cancel, Esc and ‹ go back to it, and nothing launches.
    func testTheLaunchFormIsPushedOverTheScreenItWasAskedFrom() throws {
        let project = ProjectConfig(name: "acme-shop", path: dir("acme-shop"))
        let state = try makeState(accounts: [AccountConfig(name: "work@example.com", configDir: dir("work"))],
                                  projects: [project])
        state.route = .project(project.id)
        state.beginNew(cwd: dir("acme-shop"), title: "acme-shop", account: state.config.accounts[0])
        XCTAssertEqual(state.route, .launch)
        XCTAssertEqual(state.launchRequest?.account, "work@example.com")
        state.cancelLaunch()
        XCTAssertEqual(state.route, .project(project.id))
        XCTAssertNil(state.launchRequest)

        state.route = .otherSessions
        state.beginConfigure(session: ClaudeSession(id: "s1", cwd: dir("elsewhere"), title: "Fix the webhook",
                                                    lastActivity: Date(), accountName: "work@example.com",
                                                    gitBranch: nil))
        XCTAssertEqual(state.route, .launch)
        XCTAssertTrue(state.launchRequest?.isResume == true)
        state.goBack()
        XCTAssertEqual(state.route, .otherSessions, "back is the screen it came from")
    }

    // MARK: - Going back

    /// Esc cancels a delete being asked, goes back a screen — not while a workspace is being
    /// created — and is nobody's at the root.
    func testGoingBackForTheKeyboard() throws {
        let project = ProjectConfig(name: "acme-shop", path: dir("acme-shop"))
        let state = try makeState(projects: [project])
        XCTAssertFalse(state.goBackForKey(), "the list: nothing to go back to")
        state.confirmingDelete = "s1"
        XCTAssertTrue(state.goBackForKey(), "Esc answers Cancel to Delete this transcript?")
        XCTAssertNil(state.confirmingDelete)
        XCTAssertEqual(state.route, .projects)
        state.route = .createWorkspace(project.id)
        state.blocksBack = true
        XCTAssertTrue(state.goBackForKey())
        XCTAssertEqual(state.route, .createWorkspace(project.id))
        state.blocksBack = false
        XCTAssertTrue(state.goBackForKey())
        XCTAssertEqual(state.route, .project(project.id))
    }

    /// The notch opens on every pass of the pointer: a refresh that finished less than 10 s ago
    /// is not repeated.
    func testOpeningRefreshesOnlyWhenTheLastRefreshIsTenSecondsOld() throws {
        let state = try makeState()
        let t = Date()
        XCTAssertTrue(state.needsRefreshOnOpen(now: t), "never refreshed")
        state.lastRefreshAt = t
        XCTAssertFalse(state.needsRefreshOnOpen(now: t.addingTimeInterval(9)))
        XCTAssertTrue(state.needsRefreshOnOpen(now: t.addingTimeInterval(10)))
    }

    // MARK: - The Claude tab is gone, its actions are on each session

    func testAProjectHasThreeViews() {
        XCTAssertEqual(MainTab.allCases, [.workspaces, .graph, .stats])
        XCTAssertEqual(MainTab.allCases.map(\.label), ["Workspaces", "Graph", "Stats"])
    }

    /// Everything the Claude tab could do to a session is on the session's own menu: Go or
    /// Resume, Resume with options, Resume as and Copy to another account with its limits,
    /// sharing, the id, the transcript in Finder, and Delete — not under a running session.
    func testTheSessionMenuHasWhatTheClaudeTabHad() throws {
        let state = try makeState(accounts: [AccountConfig(name: "me@example.com", configDir: dir("personal")),
                                             AccountConfig(name: "work@example.com", configDir: dir("work")),
                                             AccountConfig(name: "team@example.com", configDir: dir("team"))])
        state.hostAccounts = [host("Personal", "personal"), host("Work", "work"), host("Team", "team")]
        let closed = SessionRef(sessionId: "s1", cwd: dir("acme-shop"), accountName: "work@example.com",
                                title: "Fix the webhook", isLive: false, lastActivity: Date())
        let items = SessionMenu.items(for: closed, state: state, onAskDelete: {})
        XCTAssertEqual(items.map(\.title), ["Resume", "Resume with options…", "Resume as", "Share with all accounts",
                                            "Copy to account", "Copy session ID", "Show transcript in Finder", "",
                                            "Delete transcript…"])
        XCTAssertEqual(items.first?.shortcut, "↩")
        XCTAssertEqual(items[1].shortcut, "⌘↩")
        guard case .submenu(let resumeAs) = items[2].kind else { return XCTFail("Resume as is a submenu") }
        XCTAssertEqual(resumeAs.map(\.title), ["Personal", "Team"], "Brow's other accounts, in Brow's order")
        XCTAssertTrue(items.last?.destructive == true)
        XCTAssertTrue(items.allSatisfy(\.enabled))

        let live = SessionRef(sessionId: "s2", cwd: dir("acme-shop"), accountName: "me@example.com",
                              title: "Release notes", isLive: true, lastActivity: Date())
        let liveItems = SessionMenu.items(for: live, state: state, onAskDelete: {})
        XCTAssertEqual(liveItems.first?.title, "Go")
        XCTAssertFalse(liveItems.contains { $0.id == "resume-as" }, "a running session is not resumed elsewhere")
        XCTAssertFalse(liveItems.contains { $0.id == "share" }, "the canonical account has nothing to share")
        XCTAssertEqual(liveItems.first { $0.id == "options" }?.enabled, false)
        XCTAssertEqual(liveItems.first { $0.id == "delete" }?.enabled, false, "its process still writes the file")
    }

    /// Delete, confirmed in the row, removes the transcript.
    func testDeletingATranscriptRemovesItsFile() throws {
        let state = try makeState(accounts: [AccountConfig(name: "me@example.com", configDir: dir("personal"))])
        let cwd = dir("acme-shop")
        let folder = dir("personal") + "/projects/" + ClaudeService.mangle(cwd)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = folder + "/s1.jsonl"
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: file))
        let ref = SessionRef(sessionId: "s1", cwd: cwd, accountName: "me@example.com", title: "Fix the webhook",
                             isLive: false, lastActivity: Date())
        XCTAssertEqual(state.transcriptPath(sessionId: "s1", cwd: cwd, accountName: "me@example.com"), file)
        SessionMenu.delete(ref, state: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertNil(state.actionError)
        XCTAssertNil(state.transcriptPath(sessionId: "s1", cwd: cwd, accountName: "me@example.com"))
    }

    /// Delete works for accounts that are all outside `~/.claude` too: it used to do nothing,
    /// without a word, when no account was the canonical one.
    func testDeletingWorksWithoutAnAccountInTheCanonicalFolder() throws {
        let state = try makeState(accounts: [AccountConfig(name: "work@example.com", configDir: dir("work"))])
        let cwd = dir("acme-shop")
        let folder = dir("work") + "/projects/" + ClaudeService.mangle(cwd)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = folder + "/s1.jsonl"
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: file))
        state.purgeTranscript(id: "s1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertNil(state.actionError)
    }

    /// A session that started running since Delete was asked keeps its transcript: its process
    /// would go on writing a file that is gone.
    func testARunningSessionsTranscriptIsNotDeleted() throws {
        let state = try makeState(accounts: [AccountConfig(name: "me@example.com", configDir: dir("personal"))])
        let cwd = dir("acme-shop")
        let folder = dir("personal") + "/projects/" + ClaudeService.mangle(cwd)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = folder + "/s1.jsonl"
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: file))
        state.allLiveProcessesOverride = [LiveProcess(pid: 4242, sessionId: "s1", cwd: cwd, status: "busy",
                                                      accountName: "me@example.com")]
        state.purgeTranscript(id: "s1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        XCTAssertEqual(state.actionError, "This session is running — close it, then delete its transcript.")
    }

    // MARK: - The Projects list and the keyboard

    private func listState() throws -> (AppState, ProjectConfig, ProjectConfig) {
        let shop = ProjectConfig(name: "acme-shop", path: dir("acme-shop"))
        let notes = ProjectConfig(name: "field-notes", path: dir("field-notes"))
        let state = try makeState(accounts: [AccountConfig(name: "me@example.com", configDir: dir("personal"))],
                                  projects: [shop, notes])
        func row(_ id: String, _ title: String, _ project: ProjectConfig, _ state: SessionState,
                 ago: TimeInterval) -> ProjectSessionRow {
            ProjectSessionRow(sessionId: id, title: title, cwd: project.path, location: project.name,
                              accountName: "me@example.com", lastActivity: Date().addingTimeInterval(-ago), state: state,
                              cmuxWorkspaceId: nil)
        }
        state.recentSessionsByProject = [
            shop.id: [row("a", "Fix the checkout webhook", shop, .working, ago: 10),
                      row("b", "Release notes", shop, .yourTurn, ago: 60)],
            notes.id: [row("c", "Index the archive", notes, .yourTurn, ago: 120)],
        ]
        return (state, shop, notes)
    }

    /// ↓ and ↑ walk the listed sessions top to bottom; the first press puts the ring on the
    /// first (↓) or the last (↑), and it stops at the ends.
    func testTheKeyboardWalksTheListedSessions() throws {
        let (state, _, _) = try listState()
        XCTAssertNil(state.focusedSessionRow, "no ring until the keyboard drives")
        state.moveKeyboardFocus(by: 1)
        XCTAssertEqual(state.focusedSessionRow?.sessionId, "a")
        state.moveKeyboardFocus(by: 1)
        state.moveKeyboardFocus(by: 1)
        XCTAssertEqual(state.focusedSessionRow?.sessionId, "c")
        state.moveKeyboardFocus(by: 1)
        XCTAssertEqual(state.focusedSessionRow?.sessionId, "c", "the end")
        state.keyboardFocus = nil
        state.moveKeyboardFocus(by: -1)
        XCTAssertEqual(state.focusedSessionRow?.sessionId, "c")
    }

    /// The search narrows the projects and their sessions; a project found by its own name keeps
    /// all of its sessions.
    func testTheSearchNarrowsTheList() throws {
        let (state, _, _) = try listState()
        state.searchQuery = "webhook"
        XCTAssertEqual(state.projectsList.live.map(\.project.name), ["acme-shop"])
        XCTAssertEqual(state.listedSessionOrder.map(\.sessionId), ["a"])
        state.searchQuery = "field"
        XCTAssertEqual(state.projectsList.live.map(\.project.name), ["field-notes"])
        XCTAssertEqual(state.listedSessionOrder.map(\.sessionId), ["c"])
        state.searchQuery = "  "
        XCTAssertEqual(state.projectsList.live.count, 2, "blank is no search")
    }

    // MARK: - The notch's host

    /// Offscreen renders of the screens as the notch hosts them: the public switch tests and
    /// render tools set.
    func testTheHostAndTheRenderSwitchAreThereForTheHost() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.groveHost, .window)
        environment.groveHost = .notch(width: 432)
        XCTAssertTrue(environment.groveHost.isNotch)
        XCTAssertFalse(environment.isSnapshotRender)
    }
}
