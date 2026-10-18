// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// Review material for limit warnings, made without a click: the exact notices the real
/// evaluator sends over a scripted afternoon, and the Settings section in each of its
/// states. Fictional accounts; nothing is posted, nothing is read from this Mac.
///
/// Skipped unless `BROW_REVIEW_DIR` is set:
///
///     BROW_REVIEW_DIR="$PWD/review" swift test --filter LimitWarningsPreviewTests
@MainActor
final class LimitWarningsPreviewTests: XCTestCase {
    private func reviewDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["BROW_REVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("set BROW_REVIEW_DIR to write the limit-warning review files")
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Notices

    /// 15 Oct 2026 in this Mac's time zone, at `hour:minute`.
    private func local(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `name`: the name set in Settings, nil for none.
    private struct Account {
        let org: String, name: String?, email: String, folder: String
    }
    private let personal = Account(org: "org-demo-personal", name: "Personal", email: "alex@example.com", folder: "personal")
    private let work = Account(org: "org-demo-work", name: "Work", email: "alex.morgan@example.com", folder: "work")
    /// No name set: the panel shows its email, a notice "Account 3" (third in the panel).
    private let team = Account(org: "org-demo-team", name: nil, email: "platform-team@example.com", folder: "team")

    private func row(_ a: Account, fetchedAt: Date, five: (Double, Date)?, week: (Double, Date)?,
                     scoped: (Double, Date)? = nil) -> AccountRow {
        let account = DiscoveredAccount(organizationUuid: a.org, email: a.email, tier: "default_claude_max_20x",
                                        configDir: "/tmp/brow-demo-home/.claude-accounts/\(a.folder)",
                                        aliasDirs: [], tokenExpiresAt: nil)
        let window = { (w: (Double, Date)?) in w.map { CapturedWindow(usedPercentage: $0.0, resetsAt: self.iso($0.1)) } }
        return AccountRow(account: account, name: a.name ?? a.email,      // `displayName`
                          snapshot: LimitSnapshot(organizationUuid: a.org, fetchedAt: fetchedAt,
                                                  fiveHour: window(five), sevenDay: window(week),
                                                  weeklyScoped: window(scoped),
                                                  weeklyScopedModel: scoped == nil ? nil : "Opus"),
                          status: .ok, tokenStatus: "valid")
    }

    func testWriteSampleNotices() async throws {
        let out = try reviewDir()
        let workFive = local(15, 18, 40), workFiveNext = local(15, 23, 40)
        let personalWeek = local(19, 2, 0), workWeek = local(21, 2, 0), teamWeek = local(17, 9, 0)

        var settings = BrowSettings()
        settings.notifyLimits = true
        settings.notifyResets = true
        var accounts: [String: AccountOverride] = [:]
        for a in [personal, work, team] { accounts[a.org] = AccountOverride(name: a.name, hidden: false) }
        settings.accounts = accounts

        /// Every account at `t`, read 10 s earlier (or `persisted` days earlier).
        func rows(at t: Date, workFive five: (Double, Date), personalWeek pw: Double, teamOpus opus: Double,
                  persisted: Bool = false) -> [AccountRow] {
            let at = persisted ? t.addingTimeInterval(-3 * 86_400) : t.addingTimeInterval(-10)
            return [
                row(personal, fetchedAt: at, five: (20, local(15, 17, 0)), week: (pw, personalWeek)),
                row(work, fetchedAt: at, five: five, week: (40, workWeek)),
                row(team, fetchedAt: at, five: (41, local(15, 19, 0)), week: (55, teamWeek), scoped: (opus, teamWeek)),
            ]
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM HH:mm"
        let steps: [(String, Date, [AccountRow])] = [
            ("Launch: limits.json from 3 days ago, Work 5-hour at 84%", local(15, 14, 20),
             rows(at: local(15, 14, 20), workFive: (84, workFive), personalWeek: 62, teamOpus: 70, persisted: true)),
            ("First fresh readings: Work 5-hour 84%, Personal weekly 62%, Account 3 Opus 70%", local(15, 14, 21),
             rows(at: local(15, 14, 21), workFive: (84, workFive), personalWeek: 62, teamOpus: 70)),
            ("Work 5-hour goes to 96%", local(15, 15, 5),
             rows(at: local(15, 15, 5), workFive: (96, workFive), personalWeek: 62, teamOpus: 70)),
            ("Personal weekly goes from 62% to 81%", local(15, 15, 30),
             rows(at: local(15, 15, 30), workFive: (96, workFive), personalWeek: 81, teamOpus: 70)),
            ("Account 3 (no name set) Opus jumps from 70% to 93%", local(15, 16, 0),
             rows(at: local(15, 16, 0), workFive: (96, workFive), personalWeek: 81, teamOpus: 93)),
            ("Work's 5-hour window has reset: 5% in the new period", local(15, 18, 50),
             rows(at: local(15, 18, 50), workFive: (5, workFiveNext), personalWeek: 81, teamOpus: 93)),
            ("…and reads 82%", local(15, 19, 30),
             rows(at: local(15, 19, 30), workFive: (82, workFiveNext), personalWeek: 81, teamOpus: 93)),
        ]

        var lines = [
            "Limit warnings: what Brow would post, from the real evaluator (LimitWarnings + NoticeText).",
            "Levels 80% and 95% (the default), reset notices ON, time zone \(TimeZone.current.identifier).",
            "Accounts, in panel order: Personal and Work (names set in Settings), then one with no name set,",
            "shown as Account 3 (its email, platform-team@example.com, is never in a notice).",
            "Fictional, example.com. Title — body.",
            "",
        ]
        var warnings = LimitWarnings()
        var scheduled: [(step: Int, notice: LimitNotice)] = []
        var all: [LimitNotice] = []
        for (index, (label, now, stepRows)) in steps.enumerated() {
            let step = index + 1
            lines.append("[step \(step)] \(f.string(from: now)) — \(label)")
            let notices = warnings.evaluate(rows: stepRows, settings: settings, now: now)
            all += notices
            let posted = notices.filter { $0.kind != .reset }
            scheduled += notices.filter { $0.kind == .reset }.map { (step, $0) }
            if posted.isEmpty {
                let why = step == 1 ? "stale reading, ignored" : step == 2 ? "baseline" : "no level crossed"
                lines.append("[step \(step)] — (\(why), nothing sent)")
            }
            for notice in posted {
                lines.append("[step \(step)] \(notice.title) — \(notice.body)  (id \(notice.id))")
            }
            for notice in notices where notice.kind == .reset {
                lines.append("[step \(step)]   scheduled for \(f.string(from: notice.deliverAt!)): \(notice.title) — \(notice.body)")
            }
            lines.append("")
        }
        lines.append("[step 8] The reset notices scheduled along the way, as they arrive (no sound):")
        for (step, notice) in scheduled.sorted(by: { $0.notice.deliverAt! < $1.notice.deliverAt! }) {
            lines.append("[step 8] \(f.string(from: notice.deliverAt!)) \(notice.title) — \(notice.body)  (id \(notice.id), scheduled in step \(step))")
        }
        lines.append("")

        // Step 9 goes through `LimitNotifier`, which keeps the reset notices handed to macOS.
        let hiddenAt = local(15, 19, 40)
        lines.append("[step 9] \(f.string(from: hiddenAt)) — Personal is hidden. Work keeps its name; the account with no name")
        lines.append("[step 9] set is second in the panel now, so Account 2, on the week card and in its waiting reset notice:")
        let recorder = RecordingPoster()
        var clock = steps[0].1
        let notifier = LimitNotifier(poster: recorder, now: { clock })
        for (_, now, stepRows) in steps {
            clock = now
            notifier.evaluate(rows: stepRows, settings: settings)
        }
        await notifier.delivery?.value
        recorder.posted = []
        clock = hiddenAt
        notifier.evaluate(rows: rows(at: hiddenAt, workFive: (82, workFiveNext), personalWeek: 81, teamOpus: 93)
                            .filter { $0.id != personal.org }, settings: settings)
        await notifier.delivery?.value
        for id in recorder.withdrawn.joined() {
            lines.append("[step 9]   taken back: \(id)")
        }
        for notice in recorder.posted {
            lines.append("[step 9]   replaced, still for \(f.string(from: notice.deliverAt!)): \(notice.title) — \(notice.body)  (id \(notice.id))")
        }
        all += recorder.posted
        lines.append("")
        lines.append("Settings › General › Notifications › Send a test notification:")
        for levels in LimitWarnings.presets + [[85]] {
            lines.append("  Brow — \(NoticeText.testBody(levels: levels))")
        }
        lines.append("")
        lines.append("Every window's wording (same day / another day / reset):")
        let sameDay = local(15, 18, 40), otherDay = local(22, 2, 0), now = local(15, 14, 0)
        for kind in LimitWindowKind.allCases {
            let model = kind == .weeklyScoped ? "Fable" : nil
            lines.append("  " + NoticeText.warningBody(used: 82, kind: kind, model: model, reset: sameDay, now: now, timeZone: .current))
            lines.append("  " + NoticeText.warningBody(used: 96, kind: kind, model: model, reset: otherDay, now: now, timeZone: .current))
            lines.append("  " + NoticeText.resetBody(kind: kind, model: model))
        }

        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        try text.write(to: out.appendingPathComponent("notices.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(scheduled.count, 4)
        XCTAssertTrue(all.contains { $0.title == "Account 3" })
        XCTAssertEqual(recorder.posted.map(\.title), ["Account 2"])
        XCTAssertEqual(recorder.withdrawn.joined().filter { $0.hasPrefix("reset.\(personal.org).") }.count, 1)
        XCTAssertFalse(all.contains { ($0.title + $0.body).contains("@") }, "no email in any notice")
    }

    /// Posts nothing; keeps what it was handed.
    private final class RecordingPoster: NotificationPosting {
        var posted: [LimitNotice] = []
        var withdrawn: [[String]] = []
        func authorization() async -> NotificationAuthorization { .allowed }
        func requestAuthorization() async -> NotificationAuthorization { .allowed }
        func post(_ notice: LimitNotice) async { posted.append(notice) }
        func removePending() {}
        func removePending(ids: [String]) { withdrawn.append(ids) }
    }

    // MARK: - Settings section

    private final class StaticPoster: NotificationPosting {
        let status: NotificationAuthorization
        init(_ status: NotificationAuthorization) { self.status = status }
        func authorization() async -> NotificationAuthorization { status }
        func requestAuthorization() async -> NotificationAuthorization { status }
        func post(_ notice: LimitNotice) async {}
        func removePending() {}
        func removePending(ids: [String]) {}
    }

    /// The real section between stand-ins for its neighbours in the General tab.
    func testRenderTheNotificationsSection() async throws {
        let out = try reviewDir()
        let states: [(String, Bool, [Int], Bool, NotificationAuthorization)] = [
            ("off", false, [80, 95], false, .notDetermined),
            ("on-not-asked-yet", true, [80, 95], false, .notDetermined),
            ("on-allowed", true, [80, 95], true, .allowed),
            ("on-denied", true, [70, 90], false, .denied),
            ("on-no-app-bundle", true, [90], false, .unavailable),
            ("on-hand-edited-levels", true, [85], false, .allowed),
        ]
        for (name, on, levels, resets, status) in states {
            var settings = BrowSettings()
            settings.notifyLimits = on
            settings.notifyThresholds = levels
            settings.notifyResets = resets
            let notifier = LimitNotifier(poster: StaticPoster(status))
            await notifier.refreshAuthorization()
            let view = Form {
                Toggle("Launch at login", isOn: .constant(true))
                NotificationSettings(settings: .constant(settings), notifier: notifier)
                Section {
                    Toggle("Show the reset calendar in the panel", isOn: .constant(true))
                }
            }
            .formStyle(.grouped)
            .frame(width: 560, height: 420)
            try renderInWindow(view, to: out.appendingPathComponent("settings-notifications-\(name).png"))
        }
    }

    /// As `DemoScreenshotTests.renderInWindow`: a `Form` is AppKit-backed and does not
    /// survive ImageRenderer, so it is drawn by a real window far off every screen.
    private func renderInWindow<V: View>(_ view: V, to url: URL) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = ActiveLookingWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.displayIfNeeded()

        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height }, "no form scroll view")
        let target = try XCTUnwrap(scroll.documentView)
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
        window.close()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("review render: \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    private final class ActiveLookingWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
}
