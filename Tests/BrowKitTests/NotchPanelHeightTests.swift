// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import BrowKit

/// The open panel is as tall as its Limits section laid out, at least 480 pt while it has
/// sections and at most what the screen has above the Dock — and its footer is always inside
/// the outline.
///
/// The old window height came from `host.fittingSize`, read through the root view's fixed
/// frame: it reported the previous frame back, so the panel's height came only from a
/// hard-coded estimate that left out the calendar's day column. With every account's weekly
/// reset on one day the content was 14 pt taller than the estimate at 3 accounts, 77 at 4 and
/// 139 at 5, and from 4 accounts the footer ("Updated…" and its buttons) was cut off entirely.
@MainActor
final class NotchPanelHeightTests: XCTestCase {
    private var appDir: String!
    private let now = MadeUpLimits.morning()

    override func setUpWithError() throws {
        appDir = try Fixture.tempDir("notch-height").path
    }

    /// A panel on the made-up 14" screen; `sections` adds a Projects section, as Workspaces does.
    private func controller(_ store: LimitsStore, sections: Bool = false,
                            screen: ScreenMetrics = MadeUpLimits.screen14) -> NotchPanelController {
        let controller = NotchPanelController(store: store, clock: PanelClock(now: { [now] in now }),
                                              onExpandedChange: { _ in }, onSettings: {})
        controller.screen = { screen }
        controller.now = { [now] in now }
        if sections { controller.sections.register(.projects, StubSection()) }
        controller.render()
        return controller
    }

    // MARK: - The height

    /// Every account count from one to eight, resets spread or all on one day: the panel is
    /// the section's laid-out height plus its chrome, or the screen's cap, and the footer the
    /// shell draws lies inside the outline.
    func testThePanelIsAsTallAsItsContentAndTheFooterIsAlwaysInside() throws {
        let cap = NotchGeometry.heightCap(for: MadeUpLimits.screen14)
        for count in 1...8 {
            for sameDay in [false, true] {
                let store = try MadeUpLimits.store(count: count, sameDay: sameDay, now: now, appDir: newAppDir())
                let panel = controller(store)
                let frames = panel.model.frames
                let layout = NotchShellLayout(frames: frames, showsSwitch: false, showEars: true)
                let content = panel.measuredLimitsHeight(width: layout.contentWidth)
                XCTAssertGreaterThan(content, 100, "\(count) accounts: the section was laid out")
                let natural = layout.naturalHeight(content: content)
                XCTAssertEqual(frames.expanded.height, min(natural.rounded(.up), cap), accuracy: 0.5,
                               "\(count) accounts, same day \(sameDay)")
                // The footer view is the hairline, the row and the 8 pt of black under it.
                let footer = try XCTUnwrap(footerFrame(panel), "\(count) accounts: the footer was drawn")
                XCTAssertLessThanOrEqual(footer.maxY, frames.expanded.height + 0.5,
                                         "\(count) accounts, same day \(sameDay): the footer is inside the outline")
                XCTAssertEqual(footer.height, NotchShellLayout.footerHeight, accuracy: 0.5)
            }
        }
    }

    /// The render that showed the bug: four accounts resetting on one day. The whole section fits
    /// now, footer included, without a scroll.
    func testFourAccountsResettingOnOneDayFit() throws {
        let store = try MadeUpLimits.store(count: 4, sameDay: true, now: now, appDir: appDir)
        let panel = controller(store)
        let layout = NotchShellLayout(frames: panel.model.frames, showsSwitch: false, showEars: true)
        let content = panel.measuredLimitsHeight(width: layout.contentWidth)
        XCTAssertLessThanOrEqual(content, layout.contentRoom(height: panel.model.frames.expanded.height) + 0.5)
        let footer = try XCTUnwrap(footerFrame(panel))
        XCTAssertLessThanOrEqual(footer.maxY, panel.model.frames.expanded.height)
    }

    /// Eight accounts on the 14": the panel stops 12 pt above the Dock (982 − 70 − 12 = 900),
    /// and the accounts scroll inside it.
    func testTheCapHoldsOnAFourteenInchScreen() throws {
        let store = try MadeUpLimits.store(count: 8, sameDay: true, now: now, appDir: appDir)
        let panel = controller(store)
        XCTAssertEqual(NotchGeometry.heightCap(for: MadeUpLimits.screen14), 900)
        XCTAssertEqual(panel.model.frames.expanded.height, 900)
        let layout = NotchShellLayout(frames: panel.model.frames, showsSwitch: false, showEars: true)
        XCTAssertGreaterThan(panel.measuredLimitsHeight(width: layout.contentWidth), layout.contentRoom(height: 900),
                             "fixture check: eight accounts are taller than the room, so they scroll")
    }

    /// With sections the panel is at least 480 pt, so Projects has room even under one account;
    /// without them it is the section's own height.
    func testTheSectionsFloorAppliesOnlyWithSections() throws {
        let store = try MadeUpLimits.store(count: 1, now: now, appDir: appDir) { $0.showCalendar = false }
        let alone = controller(store).model.frames.expanded.height
        XCTAssertLessThan(alone, NotchGeometry.sectionsFloor, "fixture check: one account is short")
        let withSections = controller(store, sections: true).model.frames.expanded.height
        XCTAssertEqual(withSections, NotchGeometry.sectionsFloor)
    }

    /// Switching sections never moves the outline: the height is the Limits section's.
    func testTheHeightIsTheSameOnEverySection() throws {
        let store = try MadeUpLimits.store(count: 3, now: now, appDir: appDir)
        let panel = controller(store, sections: true)
        let before = panel.model.frames
        panel.select(.projects)
        panel.render()
        XCTAssertEqual(panel.model.frames, before)
    }

    /// The panel sizes itself before anything is laid out, when the sizing view can answer;
    /// the estimate is only for the moment it cannot, and stays in the same range.
    func testTheEstimateIsCloseToTheMeasurement() throws {
        let store = try MadeUpLimits.store(count: 3, now: now, appDir: appDir) { $0.showPet = false }
        let panel = controller(store)
        let layout = NotchShellLayout(frames: panel.model.frames, showsSwitch: false, showEars: true)
        let measured = layout.naturalHeight(content: panel.measuredLimitsHeight(width: layout.contentWidth))
        let estimate = NotchPanelController.estimatedExpandedHeight(
            barCounts: store.rows.map(NotchPanelController.barCount), layout: layout, calendar: true, pet: false)
        XCTAssertEqual(estimate, measured, accuracy: 40)
    }

    /// The third bar exists only when the payload carried a model-scoped weekly window.
    func testBarCountFollowsTheSnapshot() {
        let account = DiscoveredAccount(organizationUuid: "org", email: nil, tier: nil,
                                        configDir: "/d", aliasDirs: [], tokenExpiresAt: nil)
        let base = LimitSnapshot(organizationUuid: "org", fetchedAt: Date(),
                                 fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: nil),
                                 sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil)
        let scoped = LimitSnapshot(organizationUuid: "org", fetchedAt: Date(),
                                   fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: nil),
                                   sevenDay: nil,
                                   weeklyScoped: CapturedWindow(usedPercentage: 9, resetsAt: nil),
                                   weeklyScopedModel: "Fable")
        func row(_ snapshot: LimitSnapshot?) -> AccountRow {
            AccountRow(account: account, name: "a", snapshot: snapshot, status: .ok, tokenStatus: "fresh · 1 h")
        }
        XCTAssertEqual(NotchPanelController.barCount(row(base)), 2)
        XCTAssertEqual(NotchPanelController.barCount(row(scoped)), 3)
        XCTAssertEqual(NotchPanelController.barCount(row(nil)), 2)
    }

    // MARK: - Helpers

    private func newAppDir() throws -> String { try Fixture.tempDir("notch-height").path }

    /// The footer's frame as the open panel lays it out, in the window's space.
    private func footerFrame(_ panel: NotchPanelController) throws -> CGRect? {
        let box = FrameBox()
        panel.model.expanded = true
        let view = NotchRootView(model: panel.model)
            .onPreferenceChange(NotchFooterFrame.self) { frame in box.frame = frame }
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
        panel.model.expanded = false
        return box.frame
    }

    private final class FrameBox: @unchecked Sendable { var frame: CGRect? }

}

/// A section that draws nothing: what makes the panel draw its switch row.
@MainActor
final class StubSection: NotchSection {
    var refreshes = 0
    var escapes: [Bool] = []
    var visible: [Bool] = []
    var keys: [NotchKey] = []
    var popsOnEscape = false
    var keepsAlive = false
    var keepsAliveWhileClosed: Bool { keepsAlive }

    func content(layout: NotchShellLayout) -> AnyView { AnyView(Color.clear) }
    func footerStatus() -> AnyView { AnyView(Text("stub")) }
    func refreshButton() -> AnyView { AnyView(Image(systemName: "arrow.clockwise")) }
    func refresh() { refreshes += 1 }
    func escape() -> Bool { escapes.append(popsOnEscape); return popsOnEscape }
    func handleKey(_ key: NotchKey) -> Bool { keys.append(key); return true }
    func visibilityChanged(_ visible: Bool) { self.visible.append(visible) }
}
