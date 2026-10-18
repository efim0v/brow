// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// Brow's window with the panel opening around the pet, for the panel reel: the real outline on Brow's
/// springs, the real `EarsView`, the real `PanelView` with the pet's header row above "Overall", and the
/// pet layer clipped to the outline. The header's words are set by hand (`words`). The account is
/// fictional and nothing is read or fetched, as in `DemoScreenshotTests`.
@MainActor
enum PetPanelStage {
    private static let demoHome = "/tmp/brow-pet-panel-home"

    private final class Credentials: CredentialsReading, @unchecked Sendable {
        let expiry: Date
        init(_ expiry: Date) { self.expiry = expiry }
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "demo", expiresAt: expiry) }
        func invalidate(configDir: String) {}
        func grant(configDir: String) -> CredentialsAccess { access(configDir: configDir) }
    }

    private struct NoNetwork: UsageFetching {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
    }

    private struct NoCommands: CommandRunning {
        func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                 timeout: TimeInterval) async throws -> ProcessResult {
            ProcessResult(exitCode: 1, stdout: "", stderr: "demo: commands are not run")
        }
    }

    /// One fictional account at 41 % of its 5-hour window and 63 % of its week.
    static func store(now: Date) async throws -> (LimitsStore, () -> Void) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: demoHome)
        let appDir = fm.temporaryDirectory.appendingPathComponent("brow-pet-panel-\(UUID().uuidString)").path
        let dir = demoHome + "/.claude-accounts/personal"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: ["oauthAccount": [
            "organizationUuid": "org-demo", "emailAddress": "alex@example.com",
            "organizationRateLimitTier": "default_claude_max_5x"]])
        try json.write(to: URL(fileURLWithPath: dir + "/.claude.json"))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func window(_ used: Double, in seconds: Double) -> CapturedWindow {
            let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
            return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
        }
        let snapshot = LimitSnapshot(organizationUuid: "org-demo", fetchedAt: now.addingTimeInterval(-25),
                                     fiveHour: window(41, in: 3.2 * 3600), sevenDay: window(63, in: 2.5 * 86_400),
                                     weeklyScoped: nil, weeklyScopedModel: nil)
        var settings = BrowSettings()
        settings.accounts["org-demo"] = AccountOverride(name: "Personal", hidden: false)
        settings.showCalendar = false
        try LimitSnapshotStore(directory: appDir).saveFile(LimitsFile(snapshots: ["org-demo": snapshot], accounts: [],
                                                                      subscriptions: [:]))
        try BrowSettingsStore(directory: appDir).save(settings)
        let credentials = Credentials(now.addingTimeInterval(6 * 3600))
        let client = OAuthUsageClient(fetcher: NoNetwork(), userAgent: nil, credentials: credentials)
        let keeper = TokenKeeper(runner: NoCommands(), credentials: credentials, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { now })
        let store = LimitsStore(deps: .init(directory: AccountDirectory(home: demoHome, credentials: credentials),
                                            keeper: keeper, client: client,
                                            snapshotStore: LimitSnapshotStore(directory: appDir),
                                            settingsStore: BrowSettingsStore(directory: appDir), now: { now }))
        await store.bootstrap()
        store.setClaudeDetection(.found("/opt/homebrew/bin/claude"))
        return (store, {
            try? fm.removeItem(atPath: appDir)
            try? fm.removeItem(atPath: demoHome)
        })
    }

    /// What the header row says, set by hand as `DemoScreenshotTests` sets it: content after a small meal,
    /// the meter at `meter` of 100.
    static func words(meter: Double = 22) -> PetPanelModel {
        let words = PetPanelModel()
        words.header = PetText.Header(word: "Content", detail: "Ate 3 % · 2 min ago", moment: nil)
        words.meter = meter
        return words
    }

    /// The window at one instant: `progress` is the outline's spring, 0 the strip and 1 the panel.
    struct Scene: View {
        let frames: NotchFrames
        let store: LimitsStore
        let clock: PanelClock
        let pet: PetFrame
        /// The header row's words and meter.
        let words: PetPanelModel
        let progress: Double
        let crop: CGRect
        var pointer: CGPoint?

        var body: some View {
            let collapsed = frames.collapsed.size, expanded = frames.expanded.size
            let w = PetCurve.mix(collapsed.width, expanded.width, progress)
            let h = PetCurve.mix(collapsed.height, expanded.height, progress)
            let outline = NotchShape(topFlare: frames.flare,
                                     bottomRadius: PetCurve.mix(NotchGeometry.collapsedBottomRadius,
                                                                NotchGeometry.expandedBottomRadius, progress))
            let content = PetCurve.clamp(progress, 0, 1)
            let top = max(frames.contentTopInset, 14)
            ZStack(alignment: .topLeading) {
                PetStage.Desktop().frame(width: crop.width, height: crop.height)
                ZStack(alignment: .top) {
                    outline.fill(Color.black).frame(width: w, height: h)
                    ZStack(alignment: .top) {
                        EarsView(aggregate: store.aggregate, frames: frames, drawsBackground: false)
                            .frame(width: collapsed.width, height: collapsed.height)
                            .opacity(1 - content)
                        PanelView(store: store, clock: clock, topInset: top, flare: frames.flare, drawsBackground: false,
                                  pet: words, onSettings: {}, onRefresh: {})
                            .frame(width: expanded.width, height: expanded.height, alignment: .top)
                            .opacity(content)
                    }
                    .frame(width: w, height: h, alignment: .top)
                    .clipShape(outline)
                    PetStage.PetLayer(frame: pet, palette: .standard)
                        .frame(width: expanded.width, height: expanded.height, alignment: .topLeading)
                        .mask(alignment: .top) { outline.frame(width: w, height: h) }
                }
                .frame(width: expanded.width, height: expanded.height, alignment: .top)
                .offset(x: -crop.minX, y: -crop.minY)
                if let pointer { PetStage.Pointer().offset(x: pointer.x - crop.minX, y: pointer.y - crop.minY) }
            }
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .dark)
        }
    }
}
