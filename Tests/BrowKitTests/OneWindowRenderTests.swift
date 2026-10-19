// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import DemoFixture
@testable import GroveAppKit
import GroveCore
@testable import BrowKit

/// Renders of the one window, for review: the notch panel with Limits and Projects, the screens
/// Workspaces pushes in it, its menus, notices and corners, and the Settings panes whose words
/// changed. Every picture is the real view — `NotchPanelController`'s own model, shell and
/// outline at the frames it computes — drawn from FICTIONAL data: the made-up accounts of
/// `MadeUpLimits`/`DemoAccounts` and the snapshot fixture's project, renamed "acme-shop". The
/// panel is never ordered in, no refresh runs, nothing is read from the Mac.
///
/// Skipped unless `ONE_WINDOW_RENDERS_DIR` is set:
///
///     ONE_WINDOW_RENDERS_DIR=/path/to/build-A Scripts/test-in-empty-home.sh --filter OneWindowRenderTests
///
/// `ONE_WINDOW_BEFORE_PNG` may name today's render of the clipped panel (four accounts resetting
/// on one day, drawn by 0.4.0) for the before/after picture.
@MainActor
final class OneWindowRenderTests: XCTestCase {
    private let now = MadeUpLimits.morning()
    /// What the renders hold on to: the hosts keep a weak reference to their notch.
    private var kept: [AnyObject] = []

    func testRenderTheOneWindow() async throws {
        guard let path = ProcessInfo.processInfo.environment["ONE_WINDOW_RENDERS_DIR"], !path.isEmpty else {
            throw XCTSkip("set ONE_WINDOW_RENDERS_DIR to render the one window for review")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await renderAll(into: out)
    }

    // MARK: - The pictures

    private func renderAll(into out: URL) async throws {
        func file(_ name: String) -> URL { out.appendingPathComponent(name) }

        // a-01: Limits under the switch, on a light and a dark desktop.
        for dark in [false, true] {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .limits)
            try write(scene([panel(notch)], dark: dark,
                            caption: "Limits with Workspaces on: the switch over today's panel, one footer with pin, ⟳ and ⚙"),
                      to: file("a-01-limits-3acc-\(dark ? "dark" : "light").png"))
        }

        // a-02: Workspaces off — no switch, today's panel with the new sizing, corners and footer.
        do {
            let world = try makeWorld(workspaces: false)
            let notch = try makeNotch(world, tab: .limits)
            try write(scene([panel(notch)], caption: "Workspaces off: no switch row; the Limits panel with the measured height and the new footer"),
                      to: file("a-02-limits-workspaces-off.png"))
        }

        // a-03: four accounts resetting on one day, today and now.
        do {
            let world = try makeWorld(accounts: 4, sameDay: true, workspaces: false)
            let notch = try makeNotch(world, tab: .limits)
            var panels: [AnyView] = []
            if let before = ProcessInfo.processInfo.environment["ONE_WINDOW_BEFORE_PNG"],
               let image = NSImage(contentsOfFile: before) {
                panels.append(AnyView(labelled("0.4.0", Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 472, height: 472 * image.size.height / max(1, image.size.width)))))
            }
            panels.append(AnyView(labelled("now", panel(notch))))
            try write(scene(panels, caption: "Four accounts resetting on one day: the footer cut off before; measured, three day cards and \"+1 more\" now"),
                      to: file("a-03-limits-4acc-sameday-before-after.png"))
        }

        // a-04: eight accounts — the panel stops above the Dock and the accounts scroll.
        do {
            let world = try makeWorld(accounts: 8, sameDay: true)
            let notch = try makeNotch(world, tab: .limits)
            try write(scene([labelled("top", panel(notch)),
                             labelled("scrolled to the end", AnyView(panel(notch).environment(\.renderScrollOffset, 10_000)))],
                            caption: "Eight accounts on a 14\" screen: 900 pt, 12 pt above the Dock; the Overall line stays, the accounts scroll"),
                      to: file("a-04-limits-8acc-capped.png"))
        }

        // a-05: Projects — the band keeps the strip's readouts, Glim on its ledge.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .projects)
            try write(scene([panel(notch)], caption: "Projects: the readouts and Glim stay in the band; sessions by title with their state, place and account"),
                      to: file("a-05-projects-tab.png"))
        }

        // a-06: a project, pushed: no Claude tab, the project's own folder first.
        do {
            let world = try makeWorld()
            world.state.route = .project(world.shopID)
            world.state.selectedTab = .workspaces
            let notch = try makeNotch(world, tab: .projects)
            try write(scene([AnyView(panel(notch).environment(\.snapshotExpandedWorkspaces, ["media-pipeline"]))],
                            caption: "A project: Workspaces · Graph · Stats (no Claude tab); PROJECT FOLDER first, then WORKSPACES"),
                      to: file("a-06-project-screen.png"))
        }

        // a-07: a session's menu, with Resume as open.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .projects)
            let row = try XCTUnwrap(world.state.recentSessionsByProject[world.shopID]?.last)
            let items = SessionMenu.items(for: SessionRef(row: row), state: world.state, onAskDelete: {})
            let menu = HStack(alignment: .top, spacing: -6) {
                MenuLook(lines: MenuLook.lines(items, open: "resume-as"))
                if case .submenu(let accounts)? = items.first(where: { $0.id == "resume-as" })?.kind {
                    MenuLook(lines: MenuLook.lines(accounts, open: nil), width: 290).padding(.top, 52)
                }
            }
            try write(scene([AnyView(panel(notch).overlay(alignment: .topTrailing) {
                                menu.offset(x: 250, y: 236)
                            }.padding(.trailing, 290))],
                            caption: "A session's ••• menu (and right-click): everything the Claude tab did, Resume as with each account's limits"),
                      to: file("a-07-session-menu.png"))
        }

        // a-08: Delete asks in the row.
        do {
            let world = try makeWorld()
            world.state.confirmingDelete = world.state.recentSessionsByProject[world.shopID]?.last?.sessionId
            let notch = try makeNotch(world, tab: .projects)
            try write(scene([panel(notch)], caption: "Delete transcript… asks in the row itself — no dialog over the panel; Esc answers Cancel"),
                      to: file("a-08-delete-confirm-inline.png"))
        }

        // a-09: New session, a screen of its own.
        do {
            let world = try makeWorld()
            world.state.route = .project(world.shopID)
            let work = try XCTUnwrap(world.state.workspacesAccount(named: "work")?.config)
            world.state.beginNew(cwd: "/Users/demo/Workspaces/acme.shop/media-pipeline", title: "media-pipeline", account: work)
            let notch = try makeNotch(world, tab: .projects, pinned: true)
            try write(scene([panel(notch)], caption: "New session, pushed over the project: Brow's accounts with their limits, where it opens, model and effort"),
                      to: file("a-09-launch-form.png"))
        }

        // a-10, a-11: the project's graph and stats in the notch's width.
        for (tab, name, caption) in [(MainTab.graph, "a-10-graph.png", "Graph: the repositories in one row that scrolls sideways, the commits under it"),
                                     (.stats, "a-11-stats.png", "Stats at 432 pt in cream; the repositories keep their own chart colours")] {
            let world = try makeWorld()
            world.state.route = .project(world.shopID)
            world.state.selectedTab = tab
            let notch = try makeNotch(world, tab: .projects)
            let view = panel(notch)
            if tab == .stats { try await settleStats(world, rendering: view) }
            try write(scene([view], caption: caption), to: file(name))
        }

        // a-12: pinned, ⌘ held, the keyboard on a session.
        do {
            let world = try makeWorld()
            world.state.keyboardFocus = world.state.recentSessionsByProject[world.shopID]?.dropFirst().first?.id
            let notch = try makeNotch(world, tab: .projects, pinned: true, keys: true)
            try write(scene([panel(notch)], caption: "Pinned (cream pin), ⌘ held: the keys on the switch and the footer; ↑↓ put a cream ring on a session"),
                      to: file("a-12-pinned-keyboard.png"))
        }

        // a-13: what went wrong, and Grove still running.
        do {
            let error = try makeWorld()
            error.state.actionError = "cmux isn't running, so Go can't switch to the session."
            let errorNotch = try makeNotch(error, tab: .projects)
            let paused = try makeWorld(activation: .paused)
            let pausedNotch = try makeNotch(paused, tab: .projects)
            try write(scene([labelled("an error, with its fix", panel(errorNotch)),
                             labelled("Grove.app running", panel(pausedNotch))],
                            caption: "Notices in Projects: an error with its fix over the list; Grove still running in place of it"),
                      to: file("a-13-notices.png"))
        }

        // a-14: a display without a notch.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .limits, screen: MadeUpLimits.externalScreen)
            try write(scene([panel(notch)], caption: "A display without a notch: square at the top edge, continuous 24 pt corners at the bottom"),
                      to: file("a-14-no-notch.png"))
        }

        // a-15: the corners.
        try write(cornersScene(), to: file("a-15-corners.png"))

        // a-16: from the strip to the open panel, on Limits and on Projects.
        do {
            var rows: [AnyView] = []
            for tab in [NotchTab.limits, .projects] {
                let world = try makeWorld()
                let notch = try makeNotch(world, tab: tab)
                var frames: [AnyView] = []
                for progress in [0.0, 0.35, 0.7, 1.0] {
                    // Drawn at once: the pet's pose is the layer's, which the next frame changes.
                    notch.pose(expanded: tab == .limits, at: CGFloat(progress))
                    frames.append(try still(notch.view(outlineProgress: CGFloat(progress))))
                }
                rows.append(AnyView(labelled(tab == .limits ? "to Limits: Glim hops into the header" : "to Projects: Glim stays on its ledge",
                                             HStack(alignment: .top, spacing: 16) { ForEach(frames.indices, id: \.self) { frames[$0] } })))
            }
            try write(scene(rows, axis: .vertical, caption: "Strip to panel at 0, 35, 70 and 100 %: one outline growing out of the notch"),
                      to: file("a-16-collapsed-to-open.png"))
        }

        // a-17: the ⚙ menu.
        do {
            let world = try makeWorld()
            let notch = try makeNotch(world, tab: .limits)
            let gear = MenuLook(lines: NotchGearMenu.items.map { item in
                MenuLook.Line(title: item.title, shortcut: item.shortcut, separator: item.kind == .separator,
                              disabled: item.kind == .version)
            }, width: 210)
            try write(scene([AnyView(panel(notch).overlay(alignment: .bottomTrailing) {
                                gear.offset(x: 150, y: -46)
                            }.padding(.trailing, 160))],
                            caption: "⚙ in the footer: the version, Settings… ⌘, and Quit Brow ⌘Q — the Quit Grove's footer used to hold"),
                      to: file("a-17-gear-menu.png"))
        }

        // a-18 – a-21: the other screens Workspaces pushes, in the notch.
        let pushed: [(String, String, (World) -> Void)] = [
            ("a-18-create-workspace.png", "New workspace in the notch: the form scrolls in the panel's room, Esc waits while it creates",
             { $0.state.createPrefill = CreatePrefill(name: "loyalty-points"); $0.state.route = .createWorkspace($0.shopID) }),
            ("a-19-project-settings.png", "Project settings: the default account lists Brow's accounts, by Brow's names",
             { $0.state.route = .projectSettings($0.shopID) }),
            ("a-20-stats-settings.png", "Stats settings: the folders and files, in cream",
             { $0.state.route = .statsSettings($0.shopID) }),
            ("a-21-other-sessions.png", "Other sessions: outside every project, each with Resume and the same menu",
             { $0.state.route = .otherSessions }),
        ]
        for (name, caption, configure) in pushed {
            let world = try makeWorld()
            configure(world)
            let notch = try makeNotch(world, tab: .projects, pinned: true)
            try write(scene([panel(notch)], caption: caption), to: file(name))
        }

        // a-22, a-23: Settings, whose words changed.
        let world = try makeWorld()
        let navigation = SettingsNavigation()
        for (pane, name) in [(SettingsPane.general, "a-22-settings-general.png"), (.workspaces, "a-23-settings-workspaces.png")] {
            navigation.pane = pane
            try renderInWindow(SettingsView(store: world.store, addFlow: AddAccountFlow(store: world.store, home: DemoAccounts.home),
                                            drafts: SettingsDrafts(), workspaces: world.host, navigation: navigation),
                               to: file(name))
        }
    }

    // MARK: - The world

    private struct World {
        let store: LimitsStore
        let host: WorkspacesHost
        let state: AppState
        let shopID: UUID
    }

    /// The made-up accounts as the notch shows them and, while Workspaces is on, the snapshot
    /// fixture's project as "acme-shop" with a second one, sessions in both, two sessions in the
    /// project's own folder and four outside every project — all on Brow's three accounts.
    private func makeWorld(accounts: Int = 3, sameDay: Bool = false, workspaces: Bool = true,
                           activation: WorkspacesActivation = .on) throws -> World {
        let appDir = try Fixture.tempDir("one-window-render").path
        let store = try MadeUpLimits.store(count: accounts, sameDay: sameDay, now: now, appDir: appDir) { settings in
            settings.workspaces.enabled = workspaces
            settings.workspaces.showInMenuBar = false
        }
        let state = SnapshotMode.fixtureState()
        state.mayWrite = { false }
        let home = DemoAccounts.home
        var config = state.config
        let shopID = config.projects[0].id
        config.projects[0].name = "acme-shop"
        config.projects[0].defaultAccount = "work"
        let notes = ProjectConfig(name: "field-notes", path: DemoAccounts.notesPath)
        config.projects.append(notes)
        // Under the names the snapshot fixture's sessions carry, in the made-up accounts' folders:
        // the pickers show Brow's names for them, joined by folder.
        config.accounts = zip(["default", "work", "team"], DemoAccounts.all).map { name, account in
            AccountConfig(name: name, configDir: home + "/" + account.folder, sharedStore: name != "default")
        }
        state.config = config
        state.limitsProvider = store

        // Ages count back from the moment of the render, as Workspaces' own renders do.
        let now = Date()
        let personal = "default", work = "work", team = "team"
        let shop = config.projects[0].path
        let root = "/Users/demo/Workspaces/acme.shop"
        func row(_ id: String, _ title: String, _ cwd: String, _ account: String, _ ago: TimeInterval,
                 _ status: ProjectSessionRow.Status, at place: String? = nil) -> ProjectSessionRow {
            ProjectSessionRow(sessionId: id, title: title, cwd: cwd, location: place ?? (cwd as NSString).lastPathComponent,
                              accountName: account, lastActivity: now.addingTimeInterval(-ago), status: status,
                              cmuxWorkspaceId: status == .closed ? nil : "ws-" + id)
        }
        state.recentSessionsByProject = [
            shopID: [row("s-shop-1", "Retry failed webhook deliveries with backoff", root + "/media-pipeline", team, 120, .running),
                     row("s-shop-2", "Make the address step validate inline", root + "/media-upload", work, 4 * 60, .waiting),
                     row("s-shop-3", "Update the README for the new seed script", shop, personal, 18 * 60, .closed,
                         at: "acme-shop")],
            notes.id: [row("s-notes-1", "Resolve offline sync conflicts without losing edits", DemoAccounts.notesPath,
                           personal, 3600, .waiting)],
        ]
        func session(_ id: String, _ title: String, _ cwd: String, _ account: String, _ ago: TimeInterval,
                     branch: String? = nil) -> ClaudeSession {
            ClaudeSession(id: id, cwd: cwd, title: title, lastActivity: now.addingTimeInterval(-ago),
                          accountName: account, gitBranch: branch)
        }
        state.externalSessionsByProject = [shopID: [
            session("s-shop-3", "Update the README for the new seed script", shop, personal, 18 * 60, branch: "main"),
            session("s-shop-4", "Bump the payments SDK and fix the deprecations", shop, work, 2 * 86_400, branch: "deps/payments-sdk"),
        ]]
        state.otherSessions = [
            session("s-o-1", "Sketch the rate limiter for the public API", home + "/Code/harbor-api", work, 3 * 3600),
            session("s-o-2", "Why does the nightly export time out?", home + "/Code/data-jobs", team, 26 * 3600),
            session("s-o-3", "Plan the talk on worktrees", home + "/Documents/talks", personal, 4 * 86_400),
            session("s-o-4", "Try the new Swift Testing traits", home + "/Code/scratch", personal, 9 * 86_400),
        ]
        state.lastRefreshAt = Date().addingTimeInterval(-12)

        let host = WorkspacesHost(store: store, folders: state.folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { true }, watchRunningApps: { _ in NSObject() })
        if workspaces { host.preview(state: state, activation: activation) }
        kept.append(host)
        return World(store: store, host: host, state: state, shopID: shopID)
    }

    // MARK: - The notch

    /// The panel as the app builds it — its controller, shell and outline, Glim in it — open on
    /// `tab`, Projects registered while the world has Workspaces on.
    private func makeNotch(_ world: World, tab: NotchTab, screen: ScreenMetrics = MadeUpLimits.screen14,
                           pinned: Bool = false, keys: Bool = false) throws -> NotchRender {
        let render = try NotchRender.open(store: world.store, clock: PanelClock(now: { [now] in now }), tab: tab,
                                          screen: screen, host: world.host, pinned: pinned, keys: keys)
        kept.append(render.controller)
        return render
    }

    private func panel(_ notch: NotchRender) -> AnyView {
        AnyView(notch.view())
    }

    /// The stats screen's `.task` starts a scan of the fixture's made-up path when it is first
    /// drawn: render once, let it finish, and put the fixture's numbers back.
    private func settleStats<V: View>(_ world: World, rendering view: V) async throws {
        let renderer = ImageRenderer(content: view)
        _ = renderer.cgImage
        let deadline = Date().addingTimeInterval(10)
        while world.state.isStatsScanning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        world.state.codeStats = [world.shopID: SnapshotMode.fixtureCodeStats(now: now)]
        world.state.codeStatsHistory = [world.shopID: SnapshotMode.fixtureCodeStatsHistory(now: now)]
        world.state.repoStats = [world.shopID: SnapshotMode.fixtureRepoStats(now: now)]
    }

    // MARK: - Composition

    /// `views` hanging from the top edge of a stand-in desktop — cream under a lighter menu bar,
    /// or a dark one — side by side (or stacked), with a one-line caption under them.
    private func scene(_ views: [AnyView], axis: Axis = .horizontal, dark: Bool = false, caption: String) -> some View {
        let desktop = dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0xF3 / 255, green: 0xE8 / 255, blue: 0xD2 / 255)
        let menuBar = dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0xFA / 255, green: 0xF4 / 255, blue: 0xE7 / 255)
        let ink = dark ? Color.white.opacity(0.62) : Color(red: 0x5A / 255, green: 0x50 / 255, blue: 0x42 / 255)
        let stack = Group {
            if axis == .horizontal {
                HStack(alignment: .top, spacing: 36) { ForEach(views.indices, id: \.self) { views[$0] } }
            } else {
                VStack(alignment: .leading, spacing: 36) { ForEach(views.indices, id: \.self) { views[$0] } }
            }
        }
        return VStack(alignment: .leading, spacing: 18) {
            stack.padding(.horizontal, 64)
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 20)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                desktop
                menuBar.frame(height: 33)
            }
        }
        .fixedSize()
    }

    /// A small label under a panel in a side-by-side picture.
    private func labelled<V: View>(_ label: String, _ view: V) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 8) {
            view
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(red: 0x5A / 255, green: 0x50 / 255, blue: 0x42 / 255))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.7)))
        })
    }

    /// Today's quadratic 18 pt corner, the continuous 24 pt one and the two over each other, at
    /// 1× and at 2.4×; and the strip's 14 pt corner, quadratic and continuous.
    private func cornersScene() -> some View {
        let panel = CGSize(width: 472, height: 150)
        let strip = CGSize(width: 389, height: 32)
        let quadratic = NotchShape(bottomRadius: 18, continuousCorners: false)
        let continuous = NotchShape(bottomRadius: NotchGeometry.expandedBottomRadius)
        func filled<S: Shape>(_ shape: S, _ size: CGSize) -> some View {
            shape.fill(Color.black).frame(width: size.width, height: size.height)
        }
        func overlaid(_ size: CGSize) -> some View {
            ZStack {
                quadratic.stroke(Color(red: 0.85, green: 0.27, blue: 0.24), lineWidth: 1)
                continuous.stroke(Color(red: 0.13, green: 0.45, blue: 0.85), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
        }
        func zoomed<V: View>(_ view: V, _ size: CGSize) -> some View {
            view.frame(width: size.width, height: size.height)
                .scaleEffect(2.4, anchor: .bottomLeading)
                .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                .frame(width: 150, height: 120, alignment: .bottomLeading)
                .clipped()
        }
        let columns: [(String, AnyView)] = [
            ("0.4.0: quadratic, 18 pt", AnyView(filled(quadratic, panel))),
            ("now: continuous, 24 pt", AnyView(filled(continuous, panel))),
            ("over each other (red 0.4.0, blue now)", AnyView(overlaid(panel))),
        ]
        let content = VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        columns[index].1
                        HStack(spacing: 14) {
                            zoomed(columns[index].1, panel)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.15)))
                            Text("2.4×").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(columns[index].0).font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    filled(NotchShape(bottomRadius: 14, continuousCorners: false), strip)
                    Text("the strip, 0.4.0: quadratic, 14 pt").font(.system(size: 12, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 8) {
                    filled(NotchShape(bottomRadius: NotchGeometry.collapsedBottomRadius), strip)
                    Text("the strip, now: continuous, 14 pt").font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .foregroundStyle(Color(red: 0x3A / 255, green: 0x32 / 255, blue: 0x28 / 255))
        .padding(.top, 50)
        return scene([AnyView(content)], caption: "Corners: Apple's continuous corner at 24 pt on the panel and 14 pt on the strip; the flares unchanged")
    }

    // MARK: - Writing

    /// `view` drawn now, @2x, as an image to place in a bigger picture.
    private func still<V: View>(_ view: V) throws -> AnyView {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return AnyView(Image(decorative: try eightBit(image), scale: 2))
    }

    private func write<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "no image for \(url.lastPathComponent)")
        let rep = NSBitmapImageRep(cgImage: try eightBit(image))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("one-window render: \(url.path) \(image.width)x\(image.height)")
    }

    /// 8 bits a channel: ImageRenderer hands back half floats with an `NSImage` in the tree, which
    /// come out dithered in a PNG.
    private func eightBit(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent != 8 else { return image }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    /// Settings in a real window far off every screen, never activated — its `Form` and `TabView`
    /// are AppKit-backed and draw only there — its scrolling form at its full height, @2x.
    private func renderInWindow<V: View>(_ view: V, to url: URL) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.displayIfNeeded()
        defer { window.close() }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let target = scrollViews(in: host).max { $0.frame.height < $1.frame.height }?.documentView ?? host
        let bounds = target.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        target.cacheDisplay(in: bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("one-window render: \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}

/// A macOS menu drawn in SwiftUI, for renders: a real `NSMenu` draws only on screen. Its lines come
/// from the same data the live menus are built from (`SessionMenu.items`, `NotchGearMenu.items`).
private struct MenuLook: View {
    struct Line {
        var title: String
        var detail: String? = nil
        var shortcut: String? = nil
        var dot: Color? = nil
        var submenu = false
        var separator = false
        var destructive = false
        var disabled = false
        var highlighted = false
    }

    let lines: [Line]
    var width: CGFloat = 250

    static func lines(_ items: [SessionMenuItem], open: String?) -> [Line] {
        items.map { item in
            if case .separator = item.kind { return Line(title: "", separator: true) }
            var submenu = false
            if case .submenu = item.kind { submenu = true }
            return Line(title: item.title, detail: item.detail, shortcut: item.shortcut, dot: item.dot, submenu: submenu,
                        destructive: item.destructive, disabled: !item.enabled, highlighted: item.id == open)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if line.separator {
                    Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                } else {
                    row(line)
                }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 7) {
            if let dot = line.dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(line.title)
                .foregroundStyle(line.disabled ? Color.white.opacity(0.35)
                                 : line.destructive ? Color(red: 1, green: 0.42, blue: 0.40) : Color.white)
            if let detail = line.detail {
                Text(detail).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let shortcut = line.shortcut {
                Text(shortcut).foregroundStyle(Color.white.opacity(line.disabled ? 0.25 : 0.5))
            }
            if line.submenu {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            if line.highlighted {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(red: 0.16, green: 0.42, blue: 0.86))
            }
        }
    }
}
