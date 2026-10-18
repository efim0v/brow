// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import DemoFixture
import GroveAppKit
import GroveCore
@testable import BrowKit

/// README screenshots for Brow, rendered from FICTIONAL accounts — `DemoAccounts`, the
/// ones Workspaces' screenshots show too, so the pictures agree. Nothing real is read:
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
/// the strip of "desktop" behind them is a stand-in. The pet is the real layer posed from a
/// scripted state at a fixed instant (`demoPet`), so the images are reproducible. Settings is
/// the real `SettingsView` in an offscreen window (its `TabView`/`Form` are AppKit-backed
/// and do not survive ImageRenderer), one image per tab, with Workspaces hosted on a fixture
/// state.
final class DemoScreenshotTests: XCTestCase {

    func testRenderBrowDemoScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_SCREENSHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("set DEMO_SCREENSHOTS_DIR to render the README screenshots")
        }
        try await renderAll(into: URL(fileURLWithPath: dir, isDirectory: true))
    }

    /// The weekday on the menu bar's clock is the date's own: 17 October 2026 was a
    /// Saturday, which an earlier render printed as a Friday.
    func testTheMenuBarClockNamesTheRightWeekday() throws {
        var components = DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 41)
        components.calendar = Calendar(identifier: .gregorian)
        let date = try XCTUnwrap(components.date)
        XCTAssertEqual(Self.menuBarClock(date), "Sat 17 Oct  09:41")
    }

    /// The plans in Settings are the ones Workspaces' screenshots print.
    func testTheDemoPlansAreThePanelsOwn() {
        for account in DemoAccounts.all {
            XCTAssertEqual(PanelText.tierLabel(account.tier), account.plan)
        }
    }

    /// Settings › Workspaces in the README draws a setup Grove made — the safety net on,
    /// accounts capturing — so it says what a Grove setup is told, not that the safety
    /// net "starts off for a new setup" right above a safety net that is on.
    @MainActor
    func testTheWorkspacesRenderIsWordedForTheSetupItDraws() throws {
        let appDir = FileManager.default.temporaryDirectory.appendingPathComponent("brow-demo-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: appDir) }
        let host = makeWorkspaces(store: try makeStore(now: Self.demoNow(), appDir: appDir), appDir: appDir)
        let config = try XCTUnwrap(host.state?.config)
        XCTAssertTrue(config.transcriptMirror.enabled)
        XCTAssertTrue(config.accounts.contains(where: \.monitoring))
        XCTAssertTrue(host.isGroveSetup)
    }

    // MARK: - Fixture

    /// The demo's clock: today at 09:41, in the time zone the render runs in. The menu
    /// bar's clock and the panel's calendar are both drawn from it, so they agree on the
    /// date and its weekday.
    private static func demoNow() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
    }

    /// "Sat 17 Oct  09:41", the menu bar's date and time.
    static func menuBarClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM  HH:mm"
        return formatter.string(from: date)
    }

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
        for account in DemoAccounts.all {
            let dir = DemoAccounts.home + "/" + account.folder
            let expiry = now.addingTimeInterval(account.tokenHours * 3600)
            expiries[dir] = expiry
            discovered.append(DiscoveredAccount(organizationUuid: account.organizationUUID, email: account.email,
                                                tier: account.tier, configDir: dir, aliasDirs: [],
                                                tokenExpiresAt: expiry))

            func window(_ used: Double, in seconds: Double) -> CapturedWindow {
                // Resets land on the hour, as the real ones do.
                let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
                return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
            }
            snapshots[account.organizationUUID] = LimitSnapshot(
                organizationUuid: account.organizationUUID, fetchedAt: now.addingTimeInterval(-25),
                fiveHour: window(account.fiveHour, in: account.fiveHourResetHours * 3600),
                sevenDay: window(account.weekly, in: account.weeklyResetDays * 86_400),
                weeklyScoped: account.opusWeekly.map { window($0, in: account.weeklyResetDays * 86_400) },
                weeklyScopedModel: account.opusWeekly == nil ? nil : "Opus")
            if let days = account.renewsInDays {
                // Started 3 months minus N days ago, so the next monthly anniversary is in N days.
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC")!
                let renewal = utc.date(byAdding: .day, value: days, to: now)!
                subscriptions[account.organizationUUID] = SubscriptionInfo(
                    organizationUuid: account.organizationUUID, status: "active", billingType: "stripe_subscription",
                    createdAt: utc.date(byAdding: .month, value: -3, to: renewal), fetchedAt: now)
            }
            settings.accounts[account.organizationUUID] = AccountOverride(name: account.name, hidden: false)
        }
        // Workspaces' renders draw a setup Grove made — status lines captured, the safety net
        // on — so Settings › Workspaces is worded for one (`WorkspacesHost.isGroveSetup`).
        settings.workspaces.groveSetup = true
        try LimitSnapshotStore(directory: appDir)
            .saveFile(LimitsFile(snapshots: snapshots, accounts: [], subscriptions: subscriptions))
        try BrowSettingsStore(directory: appDir).save(settings)

        let credentials = DemoCredentials(expiries)
        let client = OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: credentials)
        let keeper = TokenKeeper(runner: NoCommands(), credentials: credentials, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { now })
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: DemoAccounts.home, credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir),
                                            now: { now }))
        // The accounts as a scan would hand them over, without one. `refresh` is never called.
        store.preview(accounts: discovered)
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        XCTAssertEqual(store.rows.map(\.name), DemoAccounts.all.map(\.name))
        return store
    }

    /// Workspaces on a fixture: two projects and the three demo accounts — Personal the
    /// default account, the other two sharing sessions into it, two capturing their status
    /// line — with each account's Claude Code retention. A temp config file, so every
    /// folder the state could write is beside it; the default account is the demo home's
    /// `.claude`, as the cards have it.
    @MainActor
    private func makeWorkspaces(store: LimitsStore, appDir: String) -> WorkspacesHost {
        let config = URL(fileURLWithPath: appDir).appendingPathComponent("grove/config.json")
        let home = DemoAccounts.home
        var folders = WorkspacesFolders.beside(configFile: config)
        folders.canonicalDir = home + "/" + DemoAccounts.personal.folder
        let state = AppState(configStore: ConfigStore(url: config), folders: folders)
        // A render writes nothing: the safety net's pass, which the tab starts, stops at once.
        state.mayWrite = { false }
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [ProjectConfig(name: "acme-shop", path: DemoAccounts.shopPath,
                                     defaultAccount: DemoAccounts.work.configName),
                       ProjectConfig(name: "field-notes", path: DemoAccounts.notesPath)],
            accounts: DemoAccounts.all.map { $0.accountConfig(root: home) },
            transcriptMirror: TranscriptMirrorSettings(enabled: true, maxDays: 30, maxMB: 500))
        state.transcriptRetention = [
            DemoAccounts.personal.configName: .init(days: 30, source: .claudeDefault),
            DemoAccounts.work.configName: .init(days: 14, source: .managedFile),
            DemoAccounts.team.configName: .init(days: 7, source: .accountSettings),
        ]
        // Two transcripts gone from Claude Code's folders that the safety net can put back.
        let mirror = home + "/.claude/grove/transcripts"
        state.restorableTranscripts = [
            (DemoAccounts.work.configName, home + "/Workspaces/acme-shop/checkout-redesign", 2.2, "2f6a9c41"),
            (DemoAccounts.personal.configName, DemoAccounts.notesPath, 9.6, "8d03b7e2"),
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
        let now = Self.demoNow()
        let store = try makeStore(now: now, appDir: appDir)
        let clock = PanelClock(now: { now })

        // A 14" MacBook Pro: 1512 x 982 pt, a 185 pt notch, 32 pt tall.
        let screen = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                   topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                   menuBarHeight: 33, notchHeight: 32)

        // (1) Collapsed: the two readouts beside the notch, and the alternative placement, with
        // the pet at rest in its black. Drawn as the app draws it: the one outline, the strip
        // inside it, the pet's layer above.
        for placement in [EarsPlacement.beside, .below] {
            let frames = NotchGeometry.frames(for: screen, expandedHeight: 120, placement: placement)
            let model = NotchPanelModel(frames: frames, pet: Self.demoPet(frames: frames, aggregate: store.aggregate,
                                                                           expanded: false))
            model.ears = AnyView(EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
                .frame(width: frames.collapsed.width, height: frames.collapsed.height))
            try renderOnDesktop(NotchRootView(model: model), canvas: CGSize(width: 640, height: 120),
                                to: out.appendingPathComponent(placement == .beside
                                                               ? "brow-notch-collapsed.png"
                                                               : "brow-notch-collapsed-below.png"))
        }

        // (2) + (3) Expanded: without the calendar, then the default panel with it, the pet in
        // its header. The footer carries the Workspaces button, as it does in the app.
        let frames = NotchGeometry.frames(for: screen, expandedHeight: 200, placement: .beside)
        let words = PetPanelModel()
        words.header = PetText.Header(word: "Content", detail: "Ate 3 % · 2 min ago", moment: nil)
        words.meter = 22
        func panel() -> some View {
            ZStack(alignment: .topLeading) {
                PanelView(store: store, clock: clock, topInset: frames.contentTopInset, flare: frames.flare,
                          pet: words, onSettings: {}, onRefresh: {}, onWorkspaces: {})
                    .frame(width: frames.expanded.width)
                PetLayerView(layer: Self.demoPet(frames: frames, aggregate: store.aggregate, expanded: true),
                             size: CGSize(width: frames.expanded.width, height: 200), expanded: true)
            }
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
        try renderOnDesktop(menuBarItem(now: now), canvas: CGSize(width: 320, height: 60),
                            to: out.appendingPathComponent("brow-menu-bar-item.png"))

        // (5) Settings: Accounts, where each card carries its Workspaces section, and
        // Workspaces. General and About only for review (see the type's comment).
        let flow = AddAccountFlow(store: store, home: DemoAccounts.home)
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
    /// template image: dark on a light bar, in the ink drawn on cream, and the clock at the
    /// demo's time.
    @MainActor
    private func menuBarItem(now: Date) -> some View {
        let mark = BrowMark.templateImage(width: 22)
        let ink = Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255)
        return HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").foregroundStyle(ink)
            Image(nsImage: mark).renderingMode(.template).foregroundStyle(ink)
            Image(systemName: "battery.75percent").foregroundStyle(ink)
            Text(Self.menuBarClock(now)).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 33)
    }

    /// The pet at rest, content, at a fixed instant of a scripted timeline: the same picture on every
    /// run. In the panel it has landed in the header's stage.
    @MainActor
    static func demoPet(frames: NotchFrames, aggregate: LimitsAggregate, expanded: Bool) -> PetLayer {
        let layer = PetLayer()
        layer.zones = PetLayout.zones(frames: frames, aggregate: aggregate, showEars: true, fiveHour: nil)
        layer.timeline.segments = [PetSegment(start: 0, behaviour: .idle(.content))]
        layer.timeline.meter = [PetMeterKey(t: 0, value: 22, rate: 0)]
        layer.seed = 7
        if expanded { layer.dock.changes = [PetDockChange(t: 1, kind: .expand)] }
        // An instant with the eyes open: never mid-blink in a README.
        var t = 9.0
        while PetRigIdle.blinkOpen(at: t, seed: layer.seed) < 0.999 || PetRigIdle.blinkOpen(at: t - 0.2, seed: layer.seed) < 0.999 {
            t += 0.05
        }
        layer.now = { t }
        return layer
    }

    // MARK: - Rendering

    /// `content` hanging from the top edge of a stand-in desktop: plain cream under a lighter
    /// menu-bar band, both flat, the desktop of the animations and the website. Height 0 =
    /// as tall as the content plus a margin.
    @MainActor
    private func renderOnDesktop<V: View>(_ content: V, canvas: CGSize, to url: URL) throws {
        let menuBar: CGFloat = 33
        let desktop = ZStack(alignment: .top) {
            Color(red: 0xF3 / 255, green: 0xE8 / 255, blue: 0xD2 / 255)
            Rectangle().fill(Color(red: 0xFA / 255, green: 0xF4 / 255, blue: 0xE7 / 255)).frame(height: menuBar)
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
        try write(NSBitmapImageRep(cgImage: eightBit(image)), to: url)
    }

    /// `image` at 8 bits a channel, as the PNG stores it. With Brow's mark in it (an `NSImage`)
    /// ImageRenderer hands back half floats, which are dithered on the way into the PNG: the flat
    /// desktop comes out speckled a level or two off its colour. Drawn into an 8-bit context they
    /// are rounded instead.
    private func eightBit(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent != 8 else { return image }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage(), "no 8-bit image")
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
