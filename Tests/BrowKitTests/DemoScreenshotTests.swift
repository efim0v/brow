import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// README screenshots for Brow, rendered from FICTIONAL accounts. Nothing real is read:
/// the accounts live in a throw-away `$HOME` stand-in, the "Keychain" is a canned
/// reader, the app-support directory is a temp dir, and no refresh cycle ever runs
/// (no network, no `claude`).
///
/// Skipped unless `DEMO_SCREENSHOTS_DIR` is set:
///
///     DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests
///
/// The notch and the panel are the real `EarsView` / `PanelView` through ImageRenderer;
/// the strip of "desktop" behind them is a stand-in. Settings is the real `SettingsView`
/// in an offscreen window (its `TabView`/`Form` are AppKit-backed and do not survive
/// ImageRenderer).
final class DemoScreenshotTests: XCTestCase {

    func testRenderBrowDemoScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_SCREENSHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("set DEMO_SCREENSHOTS_DIR to render the README screenshots")
        }
        try await renderAll(into: URL(fileURLWithPath: dir, isDirectory: true))
    }

    // MARK: - Fixture

    /// Short and absolute on purpose: Settings prints each account's folder and launch
    /// command, and a real one reads `/Users/<you>/.claude-accounts/<name>`.
    private static let demoHome = "/tmp/brow-demo-home"

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
    private func makeStore(now: Date, appDir: String) async throws -> LimitsStore {
        let fm = FileManager.default
        let home = Self.demoHome
        try? fm.removeItem(atPath: home)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var expiries: [String: Date] = [:]
        var snapshots: [String: LimitSnapshot] = [:]
        var subscriptions: [String: SubscriptionInfo] = [:]
        var settings = BrowSettings()
        for account in Self.accounts {
            let dir = home + "/" + account.folder
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // The default account keeps `.claude.json` in $HOME, the others in their dir.
            let json = try JSONSerialization.data(withJSONObject: ["oauthAccount": [
                "organizationUuid": account.org, "emailAddress": account.email,
                "organizationRateLimitTier": account.tier]])
            let identity = account.folder == ".claude" ? home + "/.claude.json" : dir + "/.claude.json"
            try json.write(to: URL(fileURLWithPath: identity))
            expiries[dir] = now.addingTimeInterval(account.tokenHours * 3600)

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
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: home, credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir),
                                            now: { now }))
        // Account discovery only (fake home, canned credentials). `refresh` is never called.
        await store.bootstrap()
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        XCTAssertEqual(store.rows.map(\.name).sorted(), Self.accounts.map(\.name).sorted())
        return store
    }

    // MARK: - Scenes

    @MainActor
    private func renderAll(into out: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let appDir = fm.temporaryDirectory.appendingPathComponent("brow-demo-\(UUID().uuidString)").path
        defer {
            try? fm.removeItem(atPath: appDir)
            try? fm.removeItem(atPath: Self.demoHome)
        }
        let now = Date()
        let store = try await makeStore(now: now, appDir: appDir)
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

        // (2) + (3) Expanded: without the calendar, then the default panel with it.
        let frames = NotchGeometry.frames(for: screen, expandedHeight: 200, placement: .beside)
        func panel() -> some View {
            PanelView(store: store, clock: clock, topInset: frames.contentTopInset, flare: frames.flare,
                      onSettings: {}, onRefresh: {})
                .frame(width: frames.expanded.width)
                .fixedSize(horizontal: false, vertical: true)
        }
        store.settings.showCalendar = false
        try renderOnDesktop(panel(), canvas: CGSize(width: 640, height: 0),
                            to: out.appendingPathComponent("brow-panel.png"))
        store.settings.showCalendar = true
        try renderOnDesktop(panel(), canvas: CGSize(width: 640, height: 0),
                            to: out.appendingPathComponent("brow-panel-reset-calendar.png"))

        // (4) Settings › Accounts: the add-account row and every account card.
        let flow = AddAccountFlow(store: store, home: Self.demoHome)
        try renderInWindow(SettingsView(store: store, addFlow: flow, drafts: SettingsDrafts()),
                           title: "Brow Settings",
                           to: out.appendingPathComponent("brow-settings-accounts.png"))
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

        // The form's own scroll document, at its FULL height: every account card in one
        // image, rather than the 420 pt the window shows at a time. The tab strip above
        // it is Liquid Glass, which `cacheDisplay` cannot draw, so it is left out.
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height },
                                   "no scroll view in the settings form")
        let target = try XCTUnwrap(scroll.documentView)
        let bounds = target.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        // The window's own background, which the document view does not paint.
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
