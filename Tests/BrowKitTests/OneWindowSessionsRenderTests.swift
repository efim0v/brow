// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import DemoFixture
@testable import GroveAppKit
import GroveCore
@testable import BrowKit

/// Renders of the sessions, the suggestions and the agents in the one window, for review.
/// Every picture is the real view — `NotchPanelController`'s own model, shell and outline at
/// the frames it computes — drawn from FICTIONAL data: the made-up accounts of
/// `MadeUpLimits`/`DemoAccounts`, invented projects, sessions, prompts and replies, and an
/// invented config folder of agents talking. The panel is never ordered in, no refresh runs,
/// nothing is read from the Mac.
///
/// Skipped unless `ONE_WINDOW_RENDERS_DIR` is set:
///
///     ONE_WINDOW_RENDERS_DIR=/path/to/build-B Scripts/test-in-empty-home.sh --filter OneWindowSessionsRenderTests
@MainActor
final class OneWindowSessionsRenderTests: XCTestCase {
    private let now = MadeUpLimits.morning()
    /// What the renders hold on to: the hosts keep a weak reference to their notch.
    private var kept: [AnyObject] = []

    func testRenderTheSessionsAndTheAgents() async throws {
        guard let path = ProcessInfo.processInfo.environment["ONE_WINDOW_RENDERS_DIR"], !path.isEmpty else {
            throw XCTSkip("set ONE_WINDOW_RENDERS_DIR to render the sessions and the agents for review")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try renderProjects(into: out)
        try renderAgents(into: out)
    }

    // MARK: - Projects

    private func renderProjects(into out: URL) throws {
        func file(_ name: String) -> URL { out.appendingPathComponent(name) }

        // b-01: today's three rows named after the project, next to three previews.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .projects)
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("0.4.0: three sessions, one name", AnyView(TodaysRows())),
                                                 RenderKit.labelled("now: what was said last", panel(notch))],
                                                caption: "Sessions told apart by their last exchange: the state, your newest prompt and Claude's newest line"),
                                to: file("b-01-sessions-before-after.png"))
        }

        // b-02: the list with everything in it, on a light and a dark desktop.
        for dark in [false, true] {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .projects)
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderHoveredSession, "s-checkout"))], dark: dark,
                                                caption: "Projects: a suggested folder, then each project's sessions — what needs you first, then what works; quiet projects one line each"),
                                to: file("b-02-projects-live-\(dark ? "dark" : "light").png"))
        }

        // b-03: a project pushed, its sessions with two lines of Claude's.
        do {
            let world = try makeWorld()
            world.state.route = .project(world.shopID)
            world.state.selectedTab = .workspaces
            let notch = try makeNotch(world, tab: .projects)
            let expanded = panel(notch).environment(\.snapshotExpandedWorkspaces, ["media-upload"])
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("top", AnyView(expanded)),
                                                 RenderKit.labelled("a workspace opened", AnyView(expanded.environment(\.renderScrollOffset, 560)))],
                                                caption: "A project: PROJECT FOLDER first, every session as a preview with two lines of Claude's"),
                                to: file("b-03-project-screen.png"))
        }

        // b-04: many projects, scrolled to the end.
        do {
            let world = try makeWorld(many: true)
            let notch = try makeNotch(world, tab: .projects)
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("top", panel(notch)),
                                                 RenderKit.labelled("scrolled to the end", AnyView(panel(notch).environment(\.renderScrollOffset, 10_000)))],
                                                caption: "Many projects: the ones with nothing running are one line each under NOTHING RUNNING"),
                                to: file("b-04-projects-many-scrolled.png"))
        }

        // b-05: no project yet.
        do {
            let world = try makeWorld(projects: false)
            let notch = try makeNotch(world, tab: .projects)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "No projects yet: what a project is, Add a folder, and every folder Claude is running in"),
                                to: file("b-05-projects-first-run.png"))
        }

        // b-06: an account's "N live" chip on Limits, and Projects narrowed to it.
        do {
            let world = try makeWorld()
            let limits = try makeNotch(world, tab: .limits)
            let filtered = try makeWorld()
            filtered.state.filter(account: "work")
            let projects = try makeNotch(filtered, tab: .projects)
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("Limits: “N live” after each account", panel(limits)),
                                                 RenderKit.labelled("its chip: Projects, Work only", panel(projects))],
                                                caption: "“4 live” on Work opens Projects narrowed to Work's sessions; ✕ on the chip shows every account"),
                                to: file("b-06-filtered-by-account.png"))
        }

        // b-07: the search.
        do {
            let world = try makeWorld()
            world.state.searchQuery = "webhook"
            let notch = try makeNotch(world, tab: .projects, pinned: true)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "⌘F: prompts, replies, titles and folders match, closed sessions included; matches marked in cream"),
                                to: file("b-07-search.png"))
        }

        // b-08: previews off.
        do {
            let world = try makeWorld()
            world.state.showsMessagePreviews = false
            let notch = try makeNotch(world, tab: .projects)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Show message previews off (Settings › Workspaces): titles only, for sharing the screen"),
                                to: file("b-08-previews-off.png"))
        }

        // b-09: the other folders.
        do {
            let world = try makeWorld()
            world.state.route = .otherSessions
            let notch = try makeNotch(world, tab: .projects, pinned: true)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Other folders: where Claude runs outside your projects, then the sessions by folder, each with Add as project"),
                                to: file("b-09-other-folders.png"))
        }

        // b-17 (Projects half): Increase Contrast.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .projects)
            // A render cannot turn the Mac's Increase Contrast on: the views take it from
            // `renderContrast` here.
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderContrast, .increased))],
                                                caption: "Increase Contrast: the quiet whites and the card edges stronger; states keep their words and shapes"),
                                to: file("b-17-increase-contrast-projects.png"))
        }
    }

    // MARK: - Agents

    private func renderAgents(into out: URL) throws {
        func file(_ name: String) -> URL { out.appendingPathComponent(name) }
        let liveCaption = "Agents: who talks to whom, live — sessions joined by arcs, their agents below, a message on its way"

        // b-10: live, on a light and a dark desktop.
        for dark in [false, true] {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.live($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)], dark: dark, caption: liveCaption),
                                to: file("b-10-agents-live-\(dark ? "dark" : "light").png"))
        }

        // b-11: one message at 0, 0.5 and 1 s: sent, on its way, arriving (the receiver rings).
        do {
            let world = try makeWorld()
            let frames: [(TimeInterval, String)] = [(0.04, "0.0 s — atlas sends"), (0.5, "0.5 s — on its way"),
                                                    (0.995, "1.0 s — harbor receives")]
            var views: [AnyView] = []
            for (elapsed, label) in frames {
                world.showAgents(now: now) { AgentsSnapshot.live($0, now: now, flight: elapsed, lumenFlight: nil) }
                let observer = world.host.agents
                let scene = observer.scene
                let layout = AgentsLayout(scene: scene, width: 432)
                let diagram = AgentsDiagram(observer: observer, scene: scene, layout: layout, reduceMotion: false)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black))
                    .environment(\.groveAccent, NotchTheme.cream)
                    .foregroundStyle(.white)
                    .snapshotRender()
                    .environment(\.colorScheme, .dark)
                views.append(RenderKit.labelled(label, try RenderKit.still(diagram)))
            }
            try RenderKit.write(RenderKit.scene(views, caption: "A message in flight: a cream light runs its edge in about a second; the receiver rings as it lands"),
                                to: file("b-11-agents-in-flight.png"))
        }

        // b-12: busy.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.busy($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Busy: a team of six (+1 more), a session on another Mac, a message held for approval, one quiet session folded"),
                                to: file("b-12-agents-busy.png"))
        }

        // b-13: quiet.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.live($0, now: now, quiet: true) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Quiet: nothing moves, the edges have cooled to grey, the last messages stay listed"),
                                to: file("b-13-agents-quiet.png"))
        }

        // b-14: nothing in the last hour.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { _ in AgentGraph() }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Empty: what the tab will show, and what Brow does and does not do to see it"),
                                to: file("b-14-agents-empty.png"))
        }

        // b-15: a session picked.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.live($0, now: now, flight: 0.82, lumenFlight: nil) }
            world.host.agents.selected = world.host.agents.graph.nodes.values.first { $0.name == "harbor" }?.id
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "A session picked: its links stay lit, the rest dims; its messages listed, and Go to session"),
                                to: file("b-15-agents-selected.png"))
        }

        // b-16: Reduce Motion.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.live($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderReduceMotion, true))],
                                                caption: "Reduce Motion: no light runs; the edge that just carried a message glows, then cools"),
                                to: file("b-16-agents-reduce-motion.png"))
        }

        // b-17 (Agents half): Increase Contrast.
        do {
            let world = try makeWorld()
            world.showAgents(now: now) { AgentsSnapshot.live($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderContrast, .increased))],
                                                caption: "Increase Contrast: grey edges, trunks and pill outlines drawn stronger"),
                                to: file("b-17-increase-contrast-agents.png"))
        }
    }

    // MARK: - Review: every height, long names, no notch

    /// The states a review walks through besides the set above: the panel on a display without
    /// a notch, with one account and with eight, with the readouts below the notch or off, with
    /// long names everywhere, and Limits at every height on three MacBook sizes.
    ///
    ///     ONE_WINDOW_REVIEW_DIR=/path/to/review Scripts/test-in-empty-home.sh --filter OneWindowSessionsRenderTests
    func testRenderTheReviewStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["ONE_WINDOW_REVIEW_DIR"], !path.isEmpty else {
            throw XCTSkip("set ONE_WINDOW_REVIEW_DIR to render the review states")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func file(_ name: String) -> URL { out.appendingPathComponent(name) }

        // No notch: Limits, Projects and Agents under the pill.
        do {
            let limits = try makeWorld()
            let projects = try makeWorld()
            let agents = try makeWorld()
            agents.showAgents(now: now) { AgentsSnapshot.live($0, now: now) }
            let screen = MadeUpLimits.externalScreen
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("Limits", panel(try makeNotch(limits, tab: .limits, screen: screen))),
                                                 RenderKit.labelled("Projects", panel(try makeNotch(projects, tab: .projects, screen: screen))),
                                                 RenderKit.labelled("Agents", panel(try makeNotch(agents, tab: .agents, screen: screen)))],
                                                caption: "A display without a notch: the pill's readouts in the band, square at the top, continuous at the bottom"),
                                to: file("r-01-no-notch.png"))
        }

        // One account (the 480 pt floor) and eight (the cap): Projects at the panel's two extremes.
        do {
            var one = SessionsWorld.Options()
            one.accounts = 1
            var eight = SessionsWorld.Options()
            eight.accounts = 8
            let small = try makeWorld(one)
            let tall = try makeWorld(eight)
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("one account", panel(try makeNotch(small, tab: .projects))),
                                                 RenderKit.labelled("one account, Limits", panel(try makeNotch(small, tab: .limits))),
                                                 RenderKit.labelled("eight accounts", panel(try makeNotch(tall, tab: .projects)))],
                                                caption: "One account: Projects at the 480 pt floor; eight: the panel as tall as the screen allows"),
                                to: file("r-02-few-and-many-accounts.png"))
        }

        // The readouts below the notch, and off.
        do {
            var below = SessionsWorld.Options()
            below.settings = { $0.earsPlacement = .below }
            var off = SessionsWorld.Options()
            off.settings = { $0.showEars = false }
            let a = try makeWorld(below)
            let b = try makeWorld(off)
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("readouts below the notch", panel(try makeNotch(a, tab: .projects))),
                                                 RenderKit.labelled("readouts off", panel(try makeNotch(b, tab: .projects)))],
                                                caption: "The band follows the strip: below the notch it is 22 pt taller; with the readouts off it is the notch alone"),
                                to: file("r-03-readouts-below-and-off.png"))
        }

        // Long names everywhere.
        do {
            var options = SessionsWorld.Options()
            options.longNames = true
            let list = try makeWorld(options)
            let project = try makeWorld(options)
            project.state.route = .project(project.shopID)
            project.state.selectedTab = .workspaces
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("the list", AnyView(panel(try makeNotch(list, tab: .projects))
                                                                                            .environment(\.renderHoveredSession, "s-checkout"))),
                                                 RenderKit.labelled("a project", panel(try makeNotch(project, tab: .projects)))],
                                                caption: "Long names: projects, workspaces, accounts, folders, prompts and commands"),
                                to: file("r-04-long-names-projects.png"))
            let agents = try makeWorld(options)
            agents.showAgents(now: now) { Self.longNamedAgents($0, now: now) }
            let busy = try makeWorld(options)
            busy.showAgents(now: now) { Self.manySessions($0, now: now) }
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("long names", panel(try makeNotch(agents, tab: .agents))),
                                                 RenderKit.labelled("seven sessions", panel(try makeNotch(busy, tab: .agents)))],
                                                caption: "Agents with long names, and with more sessions than the row holds"),
                                to: file("r-05-long-names-agents.png"))
        }

        // What the project's Claude tab did, on the cards: a closed session's menu with Resume as
        // and each account's limits, and Delete transcript… asking in the card itself.
        do {
            let menu = try makeWorld()
            menu.state.route = .project(menu.shopID)
            menu.state.selectedTab = .workspaces
            let closed = try XCTUnwrap(menu.state.externalSessionsByProject[menu.shopID]?.first { $0.id == "s-sdk" })
            let items = SessionMenu.items(for: SessionRef(session: closed, isLive: false), state: menu.state, onAskDelete: {})
            let look = HStack(alignment: .top, spacing: -6) {
                MenuLook(lines: MenuLook.lines(items, open: "resume-as"))
                if case .submenu(let accounts)? = items.first(where: { $0.id == "resume-as" })?.kind {
                    MenuLook(lines: MenuLook.lines(accounts, open: nil), width: 290).padding(.top, 52)
                }
            }
            let withMenu = AnyView(panel(try makeNotch(menu, tab: .projects, pinned: true))
                .environment(\.renderHoveredSession, "s-sdk")
                .overlay(alignment: .topLeading) { look.offset(x: 424, y: 252) }
                .padding(.trailing, 500))
            let confirm = try makeWorld()
            confirm.state.route = .project(confirm.shopID)
            confirm.state.selectedTab = .workspaces
            confirm.state.confirmingDelete = "s-sdk"
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("a closed session's ••• menu", withMenu),
                                                 RenderKit.labelled("Delete transcript…, asked in the card",
                                                                    panel(try makeNotch(confirm, tab: .projects, pinned: true)))],
                                                caption: "The Claude tab's actions, on every session: Resume as with each account's limits, Copy to account, Delete in the card"),
                                to: file("r-06-menu-and-delete.png"))
        }

        // Resume with options…: Brow's accounts with their limits, where it opens, model, effort.
        do {
            let world = try makeWorld()
            world.state.route = .project(world.shopID)
            let row = try XCTUnwrap(world.state.recentSessionsByProject[world.shopID]?.first { $0.sessionId == "s-promo" })
            world.state.beginResume(row)
            try RenderKit.write(RenderKit.scene([panel(try makeNotch(world, tab: .projects, pinned: true))],
                                                caption: "Resume with options…, pushed in the panel: Brow's accounts in Brow's order, each with its limits"),
                                to: file("r-08-resume-with-options.png"))
        }

        // Pinned, ⌘ held, the keyboard on a session.
        do {
            let world = try makeWorld()
            world.state.keyboardFocus = world.state.recentSessionsByProject[world.shopID]?.first { $0.sessionId == "s-mu-1" }?.id
            try RenderKit.write(RenderKit.scene([panel(try makeNotch(world, tab: .projects, pinned: true, keys: true))],
                                                caption: "Pinned (the cream pin), ⌘ held: the keys on the switch and the footer; ↑↓ ring a session, ↩ goes to it"),
                                to: file("r-09-keyboard.png"))
        }

        // From the strip to the open panel: on Limits Glim hops into the header, on Projects and
        // Agents it stays on its ledge beside the camera.
        do {
            var rows: [AnyView] = []
            for tab in [NotchTab.limits, .projects, .agents] {
                let world = try makeWorld()
                world.showAgents(now: now) { AgentsSnapshot.live($0, now: now, flight: 4, lumenFlight: nil) }
                let notch = try makeNotch(world, tab: tab)
                var frames: [AnyView] = []
                for progress in [0.0, 0.35, 0.7, 1.0] {
                    notch.pose(expanded: tab == .limits, at: CGFloat(progress))
                    frames.append(try RenderKit.still(notch.view(outlineProgress: CGFloat(progress))))
                }
                let label = tab == .limits ? "to Limits: Glim hops into the header" : "to \(tab.title): Glim stays on its ledge"
                rows.append(AnyView(RenderKit.labelled(label, HStack(alignment: .top, spacing: 16) {
                    ForEach(frames.indices, id: \.self) { frames[$0] }
                })))
            }
            try RenderKit.write(RenderKit.scene(rows, axis: .vertical,
                                                caption: "Strip to panel at 0, 35, 70 and 100 %: one outline growing out of the notch, the same size on every section"),
                                to: file("r-10-strip-to-panel.png"))
        }

        // Agents quiet, and with nothing in the last hour.
        do {
            let quiet = try makeWorld()
            quiet.showAgents(now: now) { AgentsSnapshot.live($0, now: now, quiet: true) }
            let empty = try makeWorld()
            empty.showAgents(now: now) { _ in AgentGraph() }
            try RenderKit.write(RenderKit.scene([RenderKit.labelled("quiet", panel(try makeNotch(quiet, tab: .agents))),
                                                 RenderKit.labelled("nothing in the last hour", panel(try makeNotch(empty, tab: .agents)))],
                                                caption: "Quiet: nothing moves, the edges cool to grey; empty: what will show, and that Brow only reads"),
                                to: file("r-11-agents-quiet-and-empty.png"))
        }

        // Limits at every height: one to eight accounts, resets spread or on one day, on a 13",
        // a 14" and a 16" MacBook. The footer must sit inside the outline in every one.
        let screens: [(String, ScreenMetrics)] = [("13-inch", Self.screen13), ("14-inch", MadeUpLimits.screen14),
                                                  ("16-inch", Self.screen16)]
        for (label, screen) in screens {
            var stills: [AnyView] = []
            for sameDay in [false, true] {
                for count in 1...8 {
                    let appDir = try Fixture.tempDir("one-window-heights").path
                    let store = try MadeUpLimits.store(count: count, sameDay: sameDay, now: now, appDir: appDir) { settings in
                        settings.workspaces.enabled = true
                        settings.workspaces.showInMenuBar = false
                    }
                    let state = SnapshotMode.fixtureState()
                    state.mayWrite = { false }
                    state.limitsProvider = store
                    let host = WorkspacesHost(store: store, folders: state.folders,
                                              groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                              groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
                    host.preview(state: state, activation: .on)
                    kept.append(host)
                    let render = try NotchRender.open(store: store, clock: PanelClock(now: { [now] in now }), tab: .limits,
                                                      screen: screen, host: host)
                    kept.append(render.controller)
                    let frames = render.controller.model.frames
                    let image = try RenderKit.still(render.view())
                    stills.append(AnyView(VStack(alignment: .leading, spacing: 4) {
                        image.scaleEffect(0.5, anchor: .topLeading)
                            .frame(width: frames.expanded.width / 2, height: frames.expanded.height / 2, alignment: .topLeading)
                        Text("\(count) · \(sameDay ? "one day" : "spread") · \(Int(frames.expanded.height)) pt")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0x5A / 255, green: 0x50 / 255, blue: 0x42 / 255))
                    }))
                }
            }
            let grid = VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) { ForEach(0..<8, id: \.self) { stills[$0] } }
                HStack(alignment: .top, spacing: 14) { ForEach(8..<16, id: \.self) { stills[$0] } }
            }
            try RenderKit.write(RenderKit.scene([AnyView(grid)],
                                                caption: "Limits on a \(label) screen, one to eight accounts, resets spread and on one day: the footer always inside"),
                                to: file("r-07-heights-\(label).png"))
        }
    }

    /// A 13" MacBook Air: 1470 × 956 pt, the Dock at the bottom.
    nonisolated static let screen13 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                                    topLeftArea: CGRect(x: 0, y: 924, width: 642.5, height: 32),
                                                    topRightArea: CGRect(x: 827.5, y: 924, width: 642.5, height: 32),
                                                    menuBarHeight: 33, notchHeight: 32,
                                                    visibleFrame: CGRect(x: 0, y: 70, width: 1470, height: 853))
    /// A 16" MacBook Pro: 1728 × 1117 pt, the Dock at the bottom.
    nonisolated static let screen16 = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                                    topLeftArea: CGRect(x: 0, y: 1085, width: 764, height: 32),
                                                    topRightArea: CGRect(x: 964, y: 1085, width: 764, height: 32),
                                                    menuBarHeight: 33, notchHeight: 32,
                                                    visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1014))

    /// Sessions and agents whose names are long, as Claude Code derives them from a first prompt.
    static func longNamedAgents(_ accounts: AgentsSnapshot.Accounts, now: Date) -> AgentGraph {
        let ws = "/Users/demo/Workspaces/acme.shop"
        let checkout = AgentsSnapshot.session("checkout-address-step-inline-validation", accounts.work, status: "busy",
                                              cwd: ws + "/checkout-redesign")
        let webhooks = AgentsSnapshot.session("payment-webhooks-retry-with-backoff", accounts.team, status: "waiting",
                                              waitingFor: "permission prompt", cwd: ws + "/fix-payment-webhooks")
        let sync = AgentsSnapshot.session("offline-sync-conflict-resolution", accounts.personal, status: "idle",
                                          cwd: "/Users/demo/Code/field-notes")
        let explorer = AgentsSnapshot.agent("postal-code-formatting-explorer", of: checkout, detail: "explorer")
        let runner = AgentsSnapshot.agent("checkout-integration-test-runner", of: checkout, detail: "test runner")
        let reviewer = AgentsSnapshot.agent("security-reviewer", of: webhooks, kind: .teammate, detail: "reviewer")
        typealias Line = AgentsSnapshot.Line
        let lines = [
            Line(from: checkout, to: webhooks, ago: 0.55, text: "Orders now post idempotently — can you rerun the webhook suite against them?",
                 delivery: .sending),
            Line(from: runner, to: checkout, ago: 30, text: "9 of 12 pass. Failing: ZIP+4, PO boxes, empty unit.", kind: .subagent),
            Line(from: webhooks, to: checkout, ago: 50, text: "Rerun done: 41 passed, 1 flaky (clock skew on the signature)."),
            Line(from: checkout, to: explorer, ago: 200, text: "Find every place we format postal codes.", kind: .subagent),
            Line(from: reviewer, to: webhooks, ago: 260, text: "The signature check must run before the body is parsed.",
                 kind: .teammate),
            Line(from: sync, to: checkout, ago: 420, text: "Can I reuse your address fixtures for the sync tests?"),
        ]
        return AgentsSnapshot.graph(nodes: [checkout, webhooks, sync, explorer, runner, reviewer], lines: lines,
                                    spawns: [(checkout, runner, 700, "Run the checkout tests")], now: now)
    }

    /// Seven sessions on three accounts, most of them talking: more than the row holds.
    static func manySessions(_ accounts: AgentsSnapshot.Accounts, now: Date) -> AgentGraph {
        let ws = "/Users/demo/Workspaces/acme.shop"
        let names = [("atlas", accounts.work, "busy"), ("harbor", accounts.team, "busy"), ("quill", accounts.personal, "idle"),
                     ("lumen", accounts.work, "waiting"), ("tide", accounts.personal, "idle"), ("orbit", accounts.work, "busy"),
                     ("kiln", accounts.team, "idle")]
        let sessions = names.map { AgentsSnapshot.session($0.0, $0.1, status: $0.2,
                                                          waitingFor: $0.2 == "waiting" ? "input needed" : nil,
                                                          cwd: ws + "/" + $0.0) }
        typealias Line = AgentsSnapshot.Line
        var lines: [Line] = []
        let pairs = [(0, 1, 0.5), (1, 2, 40.0), (0, 3, 90.0), (3, 4, 150.0), (5, 0, 210.0), (6, 1, 280.0), (2, 5, 330.0)]
        for (index, pair) in pairs.enumerated() {
            lines.append(Line(from: sessions[pair.0], to: sessions[pair.1], ago: pair.2,
                              text: ["Schema change is in.", "Rerun done: all green.", "Can you take the address step?",
                                     "Fixtures pushed.", "Release notes drafted.", "Nightly is green.",
                                     "Tokens updated for dark mode."][index]))
        }
        return AgentsSnapshot.graph(nodes: sessions, lines: lines, spawns: [], now: now)
    }

    // MARK: - The world

    /// The made-up world (`SessionsWorld`), kept alive for the render: its host holds its
    /// notch weakly.
    private func makeWorld(_ options: SessionsWorld.Options) throws -> SessionsWorld {
        let world = try SessionsWorld.make(now: now, options)
        kept.append(world.host)
        return world
    }

    private func makeWorld(projects: Bool = true, many: Bool = false) throws -> SessionsWorld {
        var options = SessionsWorld.Options()
        options.projects = projects
        options.many = many
        return try makeWorld(options)
    }

    // MARK: - The notch

    private func makeNotch(_ world: SessionsWorld, tab: NotchTab, screen: ScreenMetrics = MadeUpLimits.screen14,
                           pinned: Bool = false, keys: Bool = false) throws -> NotchRender {
        let render = try NotchRender.open(store: world.store, clock: PanelClock(now: { [now] in now }), tab: tab,
                                          screen: screen, host: world.host, pinned: pinned, keys: keys)
        world.host.syncBadges(live: world.state.liveSessions, state: world.state)
        kept.append(render.controller)
        return render
    }

    private func panel(_ notch: NotchRender) -> AnyView {
        AnyView(notch.view())
    }
}

/// 0.4.0's Workspaces window, as its rows were: every session of a project titled with the
/// project's name, a status and an age, Go or Resume. Drawn from the same made-up sessions.
private struct TodaysRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("acme-shop").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            ForEach([("waiting · 1h", "Go"), ("running · 1h", "Go"), ("closed · 5d", "Resume")], id: \.0) { status, action in
                HStack(spacing: 10) {
                    Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("acme-shop").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(status).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer()
                    Text(action).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(Color(red: 0.2, green: 0.47, blue: 0.96)))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color(white: 0.13)))
        .padding(.top, 60)
    }
}
