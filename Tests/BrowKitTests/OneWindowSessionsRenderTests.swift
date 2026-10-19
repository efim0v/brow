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
                                                caption: "“3 live” on Work opens Projects narrowed to Work's sessions; ✕ on the chip shows every account"),
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
            show(world) { AgentsSnapshot.live($0, now: now) }
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
                show(world) { AgentsSnapshot.live($0, now: now, flight: elapsed, lumenFlight: nil) }
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
            show(world) { AgentsSnapshot.busy($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Busy: a team of six (+1 more), a session on another Mac, a message held for approval, one quiet session folded"),
                                to: file("b-12-agents-busy.png"))
        }

        // b-13: quiet.
        do {
            let world = try makeWorld()
            show(world) { AgentsSnapshot.live($0, now: now, quiet: true) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Quiet: nothing moves, the edges have cooled to grey, the last messages stay listed"),
                                to: file("b-13-agents-quiet.png"))
        }

        // b-14: nothing in the last hour.
        do {
            let world = try makeWorld()
            show(world) { _ in AgentGraph() }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "Empty: what the tab will show, and what Brow does and does not do to see it"),
                                to: file("b-14-agents-empty.png"))
        }

        // b-15: a session picked.
        do {
            let world = try makeWorld()
            show(world) { AgentsSnapshot.live($0, now: now, flight: 0.82, lumenFlight: nil) }
            world.host.agents.selected = world.host.agents.graph.nodes.values.first { $0.name == "harbor" }?.id
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([panel(notch)],
                                                caption: "A session picked: its links stay lit, the rest dims; its messages listed, and Go to session"),
                                to: file("b-15-agents-selected.png"))
        }

        // b-16: Reduce Motion.
        do {
            let world = try makeWorld()
            show(world) { AgentsSnapshot.live($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderReduceMotion, true))],
                                                caption: "Reduce Motion: no light runs; the edge that just carried a message glows, then cools"),
                                to: file("b-16-agents-reduce-motion.png"))
        }

        // b-17 (Agents half): Increase Contrast.
        do {
            let world = try makeWorld()
            show(world) { AgentsSnapshot.live($0, now: now) }
            let notch = try makeNotch(world, tab: .agents)
            try RenderKit.write(RenderKit.scene([AnyView(panel(notch).environment(\.renderContrast, .increased))],
                                                caption: "Increase Contrast: grey edges, trunks and pill outlines drawn stronger"),
                                to: file("b-17-increase-contrast-agents.png"))
        }
    }

    /// The made-up agents in `world`'s Agents tab, keyed by its accounts as the notch has them.
    private func show(_ world: World, _ graph: (AgentsSnapshot.Accounts) -> AgentGraph) {
        let accounts = world.host.agentsAccounts()
        func key(_ name: String) -> String { accounts.first { $0.name == name }?.key ?? name }
        let keys = AgentsSnapshot.Accounts(work: key("Work"), team: key("Team"), personal: key("Personal"))
        world.host.agents.setAccounts(accounts)
        world.host.agents.order = []
        world.host.agents.preview(graph: graph(keys), now: now)
    }

    // MARK: - The world

    struct World {
        let store: LimitsStore
        let host: WorkspacesHost
        let state: AppState
        let shopID: UUID
    }

    /// The made-up accounts as the notch shows them, and Workspaces with the snapshot
    /// fixture's project as "acme-shop", sessions in it at every state, a second project
    /// waiting on a question, quiet ones, a suggested folder and two other folders.
    private func makeWorld(projects: Bool = true, many: Bool = false) throws -> World {
        let appDir = try Fixture.tempDir("one-window-b-render").path
        let store = try MadeUpLimits.store(count: 3, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = true
            settings.workspaces.showInMenuBar = false
        }
        let state = SnapshotMode.fixtureState()
        state.mayWrite = { false }
        let home = DemoAccounts.home
        // Paths are written from the made-up home, as `~/…`.
        state.folders.home = home
        var config = state.config
        let shopID = config.projects[0].id
        config.projects[0].name = "acme-shop"
        config.projects[0].defaultAccount = "work"
        let notes = ProjectConfig(name: "field-notes", path: home + "/Code/field-notes")
        let quiet = [("orbit-design-system", "Code/orbit"), ("lighthouse-docs", "Sites/lighthouse-docs"),
                     ("tide-mobile", "Code/tide-mobile")]
            + (many ? [("northwind-internal-tools-platform-monorepo-2026", "Clients/northwind/tools"),
                       ("sparrow-cli", "Code/sparrow-cli"), ("ledger-sync", "Code/ledger-sync"),
                       ("kiln-build-farm", "Code/kiln")] : [])
        let quietProjects = quiet.map { ProjectConfig(name: $0.0, path: home + "/" + $0.1) }
        config.projects += [notes] + quietProjects
        if !projects { config.projects = [] }
        config.accounts = zip(["default", "work", "team"], DemoAccounts.all).map { name, account in
            AccountConfig(name: name, configDir: home + "/" + account.folder, sharedStore: name != "default")
        }
        state.config = config
        state.limitsProvider = store

        let now = Date()
        let shop = home + "/Desktop/acme.shop"
        let root = "/Users/demo/Workspaces/acme.shop"
        func preview(_ prompt: String, reply: String? = nil, tool: (String, String)? = nil, question: String? = nil,
                     current: Bool = true, peer: String? = nil, branch: String? = nil) -> SessionPreview {
            SessionPreview(prompt: prompt, reply: reply, tool: question != nil ? "AskUserQuestion" : tool?.0, title: nil,
                           turn: tool != nil || question != nil ? .tool : .answered, at: nil, pendingInput: tool?.1,
                           question: question, sender: peer.map { .peer($0) } ?? .you, gitBranch: branch,
                           replyIsCurrent: current)
        }
        func row(_ id: String, _ title: String, _ cwd: String, _ place: String, _ account: String, _ ago: TimeInterval,
                 _ state: SessionState, _ preview: SessionPreview) -> ProjectSessionRow {
            ProjectSessionRow(sessionId: id, title: title, cwd: cwd, location: place, accountName: account,
                              lastActivity: now.addingTimeInterval(-ago), state: state,
                              cmuxWorkspaceId: state.isLive ? "ws-" + id : nil, preview: preview)
        }
        var rows: [UUID: [ProjectSessionRow]] = [
            shopID: [
                row("s-webhooks", "Retry failed webhook deliveries", root + "/fix-payment-webhooks", "fix-payment-webhooks",
                    "team", 120, .needsPermission,
                    preview("retry failed webhook deliveries with backoff, cap at 5 attempts",
                            reply: "Backoff is in: 1 s, 2 s, 4 s, 8 s, 16 s. Running the suite.",
                            tool: ("Bash", "npm run test:webhooks -- --retries=5"))),
                row("s-checkout", "Checkout: address step validation", root + "/checkout-redesign", "checkout-redesign",
                    "work", 20, .working,
                    preview("make the address step validate inline, with errors under each field",
                            reply: "9 of 12 checkout tests pass. Fixing the ZIP+4 rule next.",
                            tool: ("Bash", "npm test -- checkout"), peer: nil)),
                row("s-readme", "README: seed script", shop, "main", "default", 18 * 60, .yourTurn,
                    preview("update the README for the new seed script",
                            reply: "Done — Local setup now covers seeding, and the old make target is gone.")),
                // The snapshot fixture's two workspaces' sessions, as its project screen shows them.
                row("s-mu-1", "Multipart upload endpoint", root + "/media-upload", "media-upload", "work", 120, .asksYou,
                    preview("accept multipart on /media and stream it to disk",
                            question: "Keep the 25 MB limit, or raise it for video?")),
                row("s-mp-1", "Implement media pipeline", root + "/media-pipeline", "media-pipeline", "default", 900,
                    .working,
                    preview("wire the upload progress events into the pipeline",
                            tool: ("Bash", "swift test --filter Pipeline"))),
                row("s-search", "Verify webhook signatures", root + "/fix-payment-webhooks", "fix-payment-webhooks", "team",
                    2 * 86_400, .closed,
                    preview("verify the webhook signature before parsing the body",
                            reply: "Signature checked first; bad payloads get 401 and are not logged.")),
                row("s-promo", "Promo code endpoint and tests", root + "/checkout-promo-codes", "checkout-promo-codes", "work",
                    6 * 3_600, .closed,
                    preview("add POST /cart/promo with tests", reply: "Endpoint and 14 tests added; expired codes return 410.")),
            ],
            notes.id: [
                row("s-offline", "Offline sync conflict resolution", notes.path + "/offline-sync", "offline-sync", "default",
                    3_600, .asksYou,
                    preview("resolve offline sync conflicts without losing edits",
                            question: "Two edits hit the same note. Keep both as versions, or last write wins?")),
                row("s-share", "Share sheet freeze", notes.path, "main", "default", 5 * 86_400, .closed,
                    preview("why does the share sheet freeze on large notes?",
                            reply: "It rendered every image at full size; thumbnails now load lazily.")),
            ],
        ]
        let quietPrompts = ["tokens for the dark palette, with contrast checks", "rewrite the quick start for v3",
                            "fix the crash when the tide table is empty", "migrate the billing exporter to the new queue API",
                            "add a --json flag to every list command", "reconcile ledger entries after a partial sync",
                            "cache the toolchain between runs"]
        for (index, project) in quietProjects.enumerated() {
            rows[project.id] = [row("s-q\(index)", project.name, project.path, "main", index % 2 == 0 ? "work" : "default",
                                    Double(index + 2) * 86_400, .closed, preview(quietPrompts[index % quietPrompts.count]))]
        }
        state.recentSessionsByProject = projects ? rows : [:]
        state.sessionCountByProject = [shopID: 9, notes.id: 3]
        func session(_ id: String, _ cwd: String, _ account: String, _ ago: TimeInterval, _ preview: SessionPreview,
                     branch: String? = nil) -> ClaudeSession {
            ClaudeSession(id: id, cwd: cwd, title: nil, lastActivity: now.addingTimeInterval(-ago), accountName: account,
                          gitBranch: branch, preview: preview)
        }
        state.externalSessionsByProject = [shopID: [
            session("s-readme", shop, "default", 18 * 60, preview("update the README for the new seed script",
                    reply: "Done — Local setup now covers seeding, and the old make target is gone."), branch: "main"),
            session("s-sdk", shop, "work", 2 * 86_400, preview("bump the payments SDK and fix the deprecations",
                    reply: "SDK 7.2 in; two deprecated calls replaced, all 212 tests pass."), branch: "deps/payments-sdk"),
        ]]
        let dotfiles = [session("s-zsh", home + "/dotfiles", "default", 2 * 86_400,
                                preview("show the git branch only inside repositories",
                                        reply: "The zsh prompt now shows the git branch only inside repositories.")),
                        session("s-alias", home + "/dotfiles", "default", 6 * 86_400,
                                preview("add an alias for the staging tunnel", reply: "Added tunnel-staging; it opens the tunnel and prints its port."))]
        let scratch = [session("s-csv", home + "/Desktop/scratch", "work", 4 * 86_400,
                               preview("how many rows have a missing date?",
                                       reply: "The CSV has 1,204 rows; 17 have a missing date, listed in missing.txt."))]
        state.otherSessions = dotfiles + scratch
        state.otherFolders = [OtherFolder(path: home + "/dotfiles", sessions: dotfiles),
                              OtherFolder(path: home + "/Desktop/scratch", sessions: scratch)]
        state.suggestions = [ProjectSuggestion(path: home + "/Code/harbor-api", pids: [41001, 41002],
                                               cwds: [home + "/Code/harbor-api"],
                                               configDirs: [home + "/" + DemoAccounts.work.folder]),
                             ProjectSuggestion(path: home + "/Code/fleet", pids: [41003], cwds: [home + "/Code/fleet"],
                                               configDirs: [home + "/" + DemoAccounts.personal.folder])]
        if !projects {
            state.suggestions.append(ProjectSuggestion(path: home + "/Sites/lighthouse-docs", pids: [41004],
                                                       cwds: [home + "/Sites/lighthouse-docs"],
                                                       configDirs: [home + "/" + DemoAccounts.all[2].folder]))
        }
        state.liveSessions = [
            LiveProcess(pid: 41010, sessionId: "s-webhooks", cwd: root, status: "waiting", accountName: "team",
                        waitingFor: "permission prompt"),
            LiveProcess(pid: 41011, sessionId: "s-checkout", cwd: root, status: "busy", accountName: "work"),
            LiveProcess(pid: 41012, sessionId: "s-readme", cwd: shop, status: "idle", accountName: "default"),
            LiveProcess(pid: 41013, sessionId: "s-offline", cwd: notes.path, status: "waiting", accountName: "default",
                        waitingFor: "input needed"),
            LiveProcess(pid: 41014, sessionId: "s-harbor", cwd: home + "/Code/harbor-api", status: "idle", accountName: "work"),
            // The snapshot fixture's own: media-pipeline working, media-upload asking.
            LiveProcess(pid: 4242, sessionId: "s-mp-1", cwd: root + "/media-pipeline", status: "busy", accountName: "default"),
            LiveProcess(pid: 4343, sessionId: "s-mu-1", cwd: root + "/media-upload", status: "waiting", accountName: "work",
                        waitingFor: "input needed"),
        ]
        state.lastRefreshAt = Date().addingTimeInterval(-12)

        let host = WorkspacesHost(store: store, folders: state.folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
        host.preview(state: state, activation: .on)
        kept.append(host)
        return World(store: store, host: host, state: state, shopID: shopID)
    }

    // MARK: - The notch

    private func makeNotch(_ world: World, tab: NotchTab, pinned: Bool = false, keys: Bool = false) throws -> NotchRender {
        let render = try NotchRender.open(store: world.store, clock: PanelClock(now: { [now] in now }), tab: tab,
                                          screen: MadeUpLimits.screen14, host: world.host, pinned: pinned, keys: keys)
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
