// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit
import GroveCore
@testable import BrowKit

/// The Agents tab in the notch: there while Workspaces is wanted, fed the notch's accounts,
/// its dot on the switch, what its footer says, Esc. Made-up accounts and agents; the host's
/// reader reads nothing in a test.
@MainActor
final class AgentsSectionTests: XCTestCase {
    private var appDir: String!
    private var folders: WorkspacesFolders!
    private let now = MadeUpLimits.morning()

    override func setUpWithError() throws {
        appDir = try Fixture.tempDir("agents-section-app").path
        folders = .beside(configFile: try Fixture.tempDir("agents-section-grove").appendingPathComponent("config.json"))
    }

    private func makeHost(_ notch: FakeNotch) throws -> (WorkspacesHost, LimitsStore) {
        let store = try MadeUpLimits.store(count: 3, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = true
            settings.workspaces.showInMenuBar = false
        }
        let host = WorkspacesHost(store: store, folders: folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
        host.notch = notch
        addTeardownBlock { @MainActor in host.stop() }
        host.start()
        return (host, store)
    }

    private func keys(_ host: WorkspacesHost) -> AgentsSnapshot.Accounts {
        let accounts = host.agentsAccounts()
        func key(_ name: String) -> String { accounts.first { $0.name == name }?.key ?? name }
        return AgentsSnapshot.Accounts(work: key("Work"), team: key("Team"), personal: key("Personal"))
    }

    /// Agents is a tab exactly while Workspaces is wanted; its reader watches the notch's
    /// accounts, alias folders included — and in a test, reads nothing.
    func testTheTabFollowsWorkspacesAndWatchesTheNotchsAccounts() throws {
        let notch = FakeNotch()
        let (host, store) = try makeHost(notch)
        XCTAssertNotNil(notch.sections.section(.agents))
        XCTAssertEqual(notch.sections.tabs, [.projects, .agents])
        XCTAssertEqual(host.agents.accounts.count, store.rows.count)
        XCTAssertEqual(host.agents.accounts.map(\.configDirs.first), store.rows.map(\.account.configDir))
        XCTAssertFalse(host.agents.reads)

        try XCTUnwrap(notch.sections.section(.agents)).panelOpenChanged(true)
        XCTAssertFalse(host.agents.isWatching, "a test's host reads no agents")

        host.setEnabled(false)
        XCTAssertNil(notch.sections.section(.agents))
    }

    /// The switch's dot: a message in the last minute.
    func testTheSwitchsDotFollowsTheLastMessage() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        host.agents.preview(graph: AgentsSnapshot.live(keys(host), now: now), now: now)
        XCTAssertTrue(notch.badges.agentsActive)
        host.agents.preview(graph: AgentsSnapshot.live(keys(host), now: now, quiet: true), now: now)
        XCTAssertFalse(notch.badges.agentsActive)
        host.agents.preview(graph: AgentsSnapshot.busy(keys(host), now: now), now: now)
        XCTAssertTrue(notch.badges.agentsActive)
        host.setEnabled(false)
        XCTAssertFalse(notch.badges.agentsActive, "no tab, no dot")
    }

    /// The footer counts what the picture draws.
    func testTheFooterSaysWhatIsDrawn() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let observer = host.agents
        func line() -> String { AgentsFooterStatus.line(observer: observer, width: 432, now: now) }

        observer.preview(graph: AgentGraph(), now: now)
        XCTAssertEqual(line(), "Watching 3 accounts")

        observer.preview(graph: AgentsSnapshot.live(keys(host), now: now), now: now)
        XCTAssertEqual(line(), "3 sessions · 4 agents · 7 messages in 10 min")

        observer.preview(graph: AgentsSnapshot.busy(keys(host), now: now), now: now)
        XCTAssertEqual(line(), "4 sessions · 6 agents · 9 messages in 10 min",
                       "the quiet session folded and the team member past five are not counted")

        observer.preview(graph: AgentsSnapshot.live(keys(host), now: now, quiet: true), now: now)
        XCTAssertEqual(line(), "3 sessions · quiet for 11 min")

        observer.preview(graph: AgentsSnapshot.live(keys(host), now: now), now: now)
        observer.selected = observer.graph.nodes.values.first { $0.name == "harbor" }?.id
        XCTAssertEqual(line(), "harbor · 2 links · 4 messages in 10 min")
    }

    /// Esc lets go of the picked node first, then closes the panel; leaving the tab lets go
    /// too.
    func testEscLetsGoOfThePickedNode() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let section = try XCTUnwrap(notch.sections.section(.agents))
        host.agents.preview(graph: AgentsSnapshot.live(keys(host), now: now), now: now)
        host.agents.selected = host.agents.graph.nodes.values.first { $0.name == "atlas" }?.id
        XCTAssertTrue(section.escape())
        XCTAssertNil(host.agents.selected)
        XCTAssertFalse(section.escape())

        host.agents.selected = host.agents.graph.nodes.values.first { $0.name == "quill" }?.id
        section.visibilityChanged(false)
        XCTAssertNil(host.agents.selected)
    }

    /// A session's line names its project and the place in it, from Workspaces' projects.
    func testASessionsPlaceComesFromTheProjects() throws {
        let notch = FakeNotch()
        let (host, _) = try makeHost(notch)
        let state = try XCTUnwrap(host.state)
        state.mayWrite = { false }
        state.config.projects = [ProjectConfig(name: "acme-shop", path: "/Users/demo/Desktop/acme.shop",
                                               workspacesRoot: "/Users/demo/Workspaces/acme.shop")]
        host.agents.preview(graph: AgentsSnapshot.live(keys(host), now: now), now: now)
        let scene = host.agents.scene
        let atlas = try XCTUnwrap(scene.nodes.first { $0.name == "atlas" })
        XCTAssertEqual(atlas.detail, "acme-shop › checkout-redesign")
        XCTAssertEqual(scene.nodes.first { $0.name == "quill" }?.detail, "field-notes", "outside every project: its folder")
    }
}
