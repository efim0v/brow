// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveAppKit
import GroveCore
@testable import BrowKit

/// README screenshots for Brow, rendered from FICTIONAL accounts. Nothing real is read:
/// the accounts are handed to the store as a scan would find them, in a home folder that
/// does not exist, the "Keychain" is a canned reader, the app-support directory is a
/// temp dir, and no refresh cycle ever runs (no network, no `claude`).
///
/// Skipped unless `DEMO_SCREENSHOTS_DIR` is set:
///
///     DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests
///
/// With `BROW_REVIEW_DIR` set as well, Settings' General and About tabs go there, for
/// review only: outside an app bundle General says the browser router is missing and
/// About shows a generic icon, neither of which the app does.
///
/// The notch and the panel are the real `EarsView` / `PanelView` through ImageRenderer;
/// the strip of "desktop" behind them is a stand-in. Settings is the real `SettingsView`
/// in an offscreen window (its `TabView`/`Form` are AppKit-backed and do not survive
/// ImageRenderer), one image per tab, with Workspaces hosted on a fixture state.
final class DemoScreenshotTests: XCTestCase {

    func testRenderBrowDemoScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_SCREENSHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("set DEMO_SCREENSHOTS_DIR to render the README screenshots")
        }
        try await renderAll(into: URL(fileURLWithPath: dir, isDirectory: true))
    }

    // MARK: - Fixture

    /// Settings prints each account's folder and launch command, so the demo accounts
    /// live in a home that reads like one. Nothing exists there, and nothing is read
    /// from it or written to it.
    private static let demoHome = "/Users/demo"

    private struct DemoAccount {
        let folder: String, org: String, email: String, tier: String, name: String
        let five: Double, fiveResetHours: Double
        let week: Double, weekResetDays: Double
        let scoped: Double?
        let tokenHours: Double
        /// Days until the (estimated) renewal; nil = no subscription facts.
        let renewsInDays: Int?
    }

    private static let accounts: [DemoAccount] = [
        DemoAccount(folder: ".claude-accounts/personal", org: "org-demo-personal", email: "alex@example.com",
                    tier: "default_claude_max_5x", name: "Personal",
                    five: 12, fiveResetHours: 3.7, week: 34, weekResetDays: 4.3, scoped: nil,
                    tokenHours: 6.4, renewsInDays: 9),
        DemoAccount(folder: ".claude-accounts/work", org: "org-demo-work", email: "alex.morgan@example.com",
                    tier: "default_claude_max_20x", name: "Work",
                    five: 78, fiveResetHours: 1.2, week: 61, weekResetDays: 2.1, scoped: 45,
                    tokenHours: 3.1, renewsInDays: 20),
        DemoAccount(folder: ".claude-accounts/team", org: "org-demo-team", email: "platform-team@example.com",
                    tier: "default_claude_max_20x", name: "Team",
                    five: 41, fiveResetHours: 4.4, week: 93, weekResetDays: 0.9, scoped: nil,
                    tokenHours: 7.8, renewsInDays: nil),
    ]

    private final class DemoCredentials: CredentialsReading, @unchecked Sendable {
        let expiries: [String: Date]
        init(_ expiries: [String: Date]) { self.expiries = expiries }
        func token(configDir: String) -> ClaudeToken? {
            expiries[configDir].map { ClaudeToken(value: "demo", expiresAt: $0) }
        }
        func invalidate(configDir: String) {}
        func grant(configDir: String) -> CredentialsAccess { access(configDir: configDir) }
    }

    /// Never called: no refresh cycle runs. Fails loudly if one ever does.
    private struct NoNetwork: UsageFetching {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
    }
    private struct NoCommands: CommandRunning {
        func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                 timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, stdout: "", stderr: "demo: commands are not run")
        }
    }

    @MainActor
    private func makeStore(now: Date, appDir: String) throws -> LimitsStore {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var discovered: [DiscoveredAccount] = []
        var expiries: [String: Date] = [:]
        var snapshots: [String: LimitSnapshot] = [:]
        var subscriptions: [String: SubscriptionInfo] = [:]
        var settings = BrowSettings()
        for account in Self.accounts {
            let dir = Self.demoHome + "/" + account.folder
            let expiry = now.addingTimeInterval(account.tokenHours * 3600)
            expiries[dir] = expiry
            discovered.append(DiscoveredAccount(organizationUuid: account.org, email: account.email,
                                                tier: account.tier, configDir: dir, aliasDirs: [],
                                                tokenExpiresAt: expiry))

            func window(_ used: Double, in seconds: Double) -> CapturedWindow {
                // Resets land on the hour, as the real ones do.
                let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
                return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
            }
            snapshots[account.org] = LimitSnapshot(
                organizationUuid: account.org, fetchedAt: now.addingTimeInterval(-25),
                fiveHour: window(account.five, in: account.fiveResetHours * 3600),
                sevenDay: window(account.week, in: account.weekResetDays * 86_400),
                weeklyScoped: account.scoped.map { window($0, in: account.weekResetDays * 86_400) },
                weeklyScopedModel: account.scoped == nil ? nil : "Opus")
            if let days = account.renewsInDays {
                // Started 3 months minus N days ago, so the next monthly anniversary is in N days.
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let renewal = utc.date(byAdding: .day, value: days, to: now)!
                subscriptions[account.org] = SubscriptionInfo(
                    organizationUuid: account.org, status: "active", billingType: "stripe_subscription",
                    createdAt: utc.date(byAdding: .month, value: -3, to: renewal), fetchedAt: now)
            }
            settings.accounts[account.org] = AccountOverride(name: account.name, hidden: false)
        }
        try LimitSnapshotStore(directory: appDir)
            .saveFile(LimitsFile(snapshots: snapshots, accounts: [], subscriptions: subscriptions))
        try BrowSettingsStore(directory: appDir).save(settings)

        let credentials = DemoCredentials(expiries)
        let client = OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: credentials)
        let keeper = TokenKeeper(runner: NoCommands(), credentials: credentials, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { now })
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: Self.demoHome, credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir),
                                            now: { now }))
        // The accounts as a scan would hand them over, without one. `refresh` is never called.
        store.preview(accounts: discovered)
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        XCTAssertEqual(store.rows.map(\.name).sorted(), Self.accounts.map(\.name).sorted())
        return store
    }

    /// Workspaces on a fixture: two projects, the three demo accounts (two of them sharing
    /// sessions, two capturing their status line), each account's Claude Code retention.
    /// A temp config file, so every folder the state could write is beside it.
    @MainActor
    private func makeWorkspaces(store: LimitsStore, appDir: String) -> WorkspacesHost {
        let config = URL(fileURLWithPath: appDir).appendingPathComponent("grove/config.json")
        let state = AppState(configStore: ConfigStore(url: config))
        let home = Self.demoHome
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [ProjectConfig(name: "acme-shop", path: "/Users/demo/Code/acme-shop", defaultAccount: "work"),
                       ProjectConfig(name: "field-notes", path: "/Users/demo/Code/field-notes")],
            accounts: [
                AccountConfig(name: "alex@example.com", configDir: home + "/.claude-accounts/personal",
                              monitoring: true, defaultModel: "sonnet"),
                AccountConfig(name: "alex.morgan@example.com", configDir: home + "/.claude-accounts/work",
                              sharedStore: true, monitoring: true, defaultModel: "opus", defaultEffort: "high"),
                AccountConfig(name: "platform-team@example.com", configDir: home + "/.claude-accounts/team",
                              sharedStore: true),
            ],
            transcriptMirror: TranscriptMirrorSettings(enabled: true, maxDays: 30, maxMB: 500))
        state.transcriptRetention = [
            "alex@example.com": .init(days: 30, source: .claudeDefault),
            "alex.morgan@example.com": .init(days: 14, source: .managedFile),
            "platform-team@example.com": .init(days: 7, source: .accountSettings),
        ]
        // Two transcripts gone from Claude Code's folders that the safety net can put back.
        let mirror = home + "/.claude/grove/transcripts"
        state.restorableTranscripts = [
            ("alex.morgan@example.com", "/Users/demo/Workspaces/acme-shop/checkout-redesign", 2.2, "2f6a9c41"),
            ("alex@example.com", "/Users/demo/Code/field-notes", 9.6, "8d03b7e2"),
        ].map { account, cwd, daysAgo, id in
            let folder = ClaudeService.mangle(cwd)
            return RestorableTranscript(
                entry: VanishedTranscript(mirrorPath: "\(mirror)/demo/\(folder)/\(id).jsonl",
                                          livePath: "\(home)/.claude/projects/\(folder)/\(id).jsonl",
                                          accountKey: "demo", lastActivity: Date().addingTimeInterval(-daysAgo * 86_400)),
                accountName: account, cwd: cwd)
        }
        state.limitsProvider = store
        let host = WorkspacesHost(store: store, folders: state.folders,
                                  groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                  groveConfigExists: { false }, groveDefaults: { nil })
        host.preview(state: state, activation: .on)
        return host
    }

    // MARK: - Scenes

    @MainActor
    private func renderAll(into out: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let appDir = fm.temporaryDirectory.appendingPathComponent("brow-demo-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: appDir) }
        let now = Date()
        let store = try makeStore(now: now, appDir: appDir)
        let clock = PanelClock(now: { now })

        // A 14" MacBook Pro: 1512 x 982 pt, a 185 pt notch, 32 pt tall.
        let screen = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                   topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                   menuBarHeight: 33, notchHeight: 32)

        // (1) Collapsed: the two readouts beside the notch, and the alternative placement.
        for placement in [EarsPlacement.beside, .below] {
            let frames = NotchGeometry.frames(for: screen, expandedHeight: 200, placement: placement)
            let ears = EarsView(aggregate: store.aggregate, frames: frames)
                .frame(width: frames.collapsed.width, height: frames.collapsed.height)
            try renderOnDesktop(ears, canvas: CGSize(width: 640, height: 120),
                                to: out.appendingPathComponent(placement == .beside
                                                               ? "brow-notch-collapsed.png"
                                                               : "brow-notch-collapsed-below.png"))
        }

        // (2) + (3) Expanded: without the calendar, then the default panel with it. The
        // footer carries the Workspaces button, as it does in the app.
        let frames = NotchGeometry.frames(for: screen, expandedHeight: 200, placement: .beside)
        func panel() -> some View {
            PanelView(store: store, clock: clock, topInset: frames.contentTopInset, flare: frames.flare,
                      onSettings: {}, onRefresh: {}, onWorkspaces: {})
                .frame(width: frames.expanded.width)
                .fixedSize(horizontal: false, vertical: true)
        }
        store.settings.showCalendar = false
        try renderOnDesktop(panel(), canvas: CGSize(width: 640, height: 0),
                            to: out.appendingPathComponent("brow-panel.png"))
        store.settings.showCalendar = true
        try renderOnDesktop(panel(), canvas: CGSize(width: 640, height: 0),
                            to: out.appendingPathComponent("brow-panel-reset-calendar.png"))

        // (4) The Workspaces item in the menu bar: Brow's mark, as a template image tinted
        // by the bar.
        try renderOnDesktop(menuBarItem(), canvas: CGSize(width: 320, height: 60),
                            to: out.appendingPathComponent("brow-menu-bar-item.png"))

        // (5) Settings: Accounts, where each card carries its Workspaces section, and
        // Workspaces. General and About only for review (see the type's comment).
        let flow = AddAccountFlow(store: store, home: Self.demoHome)
        let workspaces = makeWorkspaces(store: store, appDir: appDir)
        let navigation = SettingsNavigation()
        var panes: [(SettingsPane, URL)] = [(.accounts, out.appendingPathComponent("brow-settings-accounts.png")),
                                            (.workspaces, out.appendingPathComponent("brow-settings-workspaces.png"))]
        if let review = ProcessInfo.processInfo.environment["BROW_REVIEW_DIR"], !review.isEmpty {
            let reviewDir = URL(fileURLWithPath: review, isDirectory: true)
            try fm.createDirectory(at: reviewDir, withIntermediateDirectories: true)
            panes += [(.general, reviewDir.appendingPathComponent("brow-settings-general.png")),
                      (.about, reviewDir.appendingPathComponent("brow-settings-about.png"))]
        }
        for (pane, url) in panes {
            navigation.pane = pane
            try renderInWindow(SettingsView(store: store, addFlow: flow, drafts: SettingsDrafts(),
                                            workspaces: workspaces, navigation: navigation),
                               title: "Brow Settings", to: url)
        }
        // For review: Workspaces turned off, two status lines it captured still running
        // the wrapper — the switches that give them back stay in Accounts and Workspaces.
        if let review = ProcessInfo.processInfo.environment["BROW_REVIEW_DIR"], !review.isEmpty {
            let off = WorkspacesHost(store: store, folders: workspaces.folders,
                                     groveGuard: GroveAppGuard(runningBundleIdentifiers: { [] }),
                                     groveConfigExists: { false }, groveDefaults: { nil })
            off.preview(state: nil, activation: .off,
                        dormant: (workspaces.state?.config.accounts ?? []).filter(\.monitoring))
            for (pane, name) in [(SettingsPane.accounts, "brow-settings-accounts-off.png"),
                                 (.workspaces, "brow-settings-workspaces-off.png")] {
                navigation.pane = pane
                try renderInWindow(SettingsView(store: store, addFlow: flow, drafts: SettingsDrafts(),
                                                workspaces: off, navigation: navigation),
                                   title: "Brow Settings",
                                   to: URL(fileURLWithPath: review, isDirectory: true).appendingPathComponent(name))
            }
        }

        // (6) What the Workspaces panel says when it is not running its projects.
        try renderWindowContent(WorkspacesNoticeView(notice: workspaces.groveRunningNotice),
                                to: out.appendingPathComponent("workspaces-paused.png"))
        try renderWindowContent(WorkspacesNoticeView(notice: workspaces.introductionNotice),
                                to: out.appendingPathComponent("workspaces-introduction.png"))
    }

    /// A strip of menu bar with Brow's item among two stand-ins, the way the bar tints a
    /// template image: white on a dark bar.
    @MainActor
    private func menuBarItem() -> some View {
        let mark = BrowMark.templateImage(width: 22)
        return HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").foregroundStyle(.white)
            Image(nsImage: mark).renderingMode(.template).foregroundStyle(.white)
            Image(systemName: "battery.75percent").foregroundStyle(.white)
            Text("Fri 17 Oct  09:41").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 33)
    }

    // MARK: - Rendering

    /// `content` hanging from the top edge of a stand-in desktop: a wallpaper gradient
    /// under a translucent menu-bar band. Height 0 = as tall as the content plus a margin.
    @MainActor
    private func renderOnDesktop<V: View>(_ content: V, canvas: CGSize, to url: URL) throws {
        let menuBar: CGFloat = 33
        let desktop = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.27, blue: 0.52),
                                    Color(red: 0.45, green: 0.33, blue: 0.62),
                                    Color(red: 0.86, green: 0.52, blue: 0.48)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.black.opacity(0.22)).frame(height: menuBar)
        }
        let body = VStack(spacing: 0) {
            content
            Spacer(minLength: canvas.height > 0 ? 0 : 28)
        }
        .frame(width: canvas.width, height: canvas.height > 0 ? canvas.height : nil, alignment: .top)
        .background(desktop)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: body)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "no image for \(url.lastPathComponent)")
        try write(NSBitmapImageRep(cgImage: image), to: url)
    }

    /// The view as the content of a real window (ordered in far off-screen, never
    /// activated), and its scrollable form drawn @2x. For AppKit-backed SwiftUI that
    /// ImageRenderer cannot draw.
    @MainActor
    private func renderInWindow<V: View>(_ view: V, title: String, to url: URL) throws {
        let (window, host) = offscreenWindow(view, title: title)
        // The form's own scroll document, at its FULL height: every account card in one
        // image, rather than the height the window shows at a time. The tab strip above
        // it is Liquid Glass, which `cacheDisplay` cannot draw, so it is left out.
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height },
                                   "no scroll view in the settings form")
        let target = try XCTUnwrap(scroll.documentView)
        try snapshot(target, in: window, to: url)
    }

    /// A plain view (no scroll view) in an offscreen window, drawn @2x on the window's
    /// background — real buttons and all.
    @MainActor
    private func renderWindowContent<V: View>(_ view: V, to url: URL) throws {
        let (window, host) = offscreenWindow(view.padding(10), title: "")
        try snapshot(host, in: window, to: url)
    }

    @MainActor
    private func offscreenWindow<V: View>(_ view: V, title: String) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = ActiveLookingWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        // Far off every screen and never activated: it only has to be in the window
        // server's list for AppKit-backed controls to draw themselves.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        // Let SwiftUI finish its first layout passes.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.displayIfNeeded()
        return (window, host)
    }

    @MainActor
    private func snapshot(_ target: NSView, in window: NSWindow, to url: URL) throws {
        let bounds = target.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        // The window's own background, which the views do not paint.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        target.cacheDisplay(in: bounds, to: rep)
        window.close()
        try write(rep, to: url)
    }

    /// Draws its controls as a key window would, without the test process ever taking
    /// focus from whatever the user is doing.
    private final class ActiveLookingWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("demo screenshot: \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
