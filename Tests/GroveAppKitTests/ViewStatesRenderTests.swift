// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Renders RootView in states the fixed 11 snapshot scenes don't cover (search
/// active, empty/scanning, non-cmux error banner, charts with no accounts), so
/// the per-screen branch bodies execute. Forcing cgImage evaluates each body.
@MainActor
final class ViewStatesRenderTests: XCTestCase {
    private func render(_ state: AppState, _ size: CGSize) {
        let view = RootView(state: state)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }

    private let projectSize = CGSize(width: 600, height: 540)

    func testProjectSearchNoMatchAndEmptyScanning() {
        let s = SnapshotMode.fixtureState()
        s.route = .project(s.selectedProjectID!)
        s.searchQuery = "zzz-no-match"
        render(s, projectSize)

        let s2 = SnapshotMode.fixtureState()
        s2.route = .project(s2.selectedProjectID!)
        s2.snapshots = [:]              // no snapshot -> "scan this project" empty state
        s2.isScanning = true
        render(s2, projectSize)
    }

    func testWorkspacesSearchAndGraphTab() {
        let s = SnapshotMode.fixtureState()
        s.route = .project(s.selectedProjectID!)
        s.selectedTab = .workspaces
        s.searchQuery = "media"
        render(s, projectSize)

        s.selectedTab = .graph
        render(s, projectSize)
    }

    /// Every route as the notch hosts it: 432 pt wide inside the panel's black, no title of
    /// its own on the list. Forcing cgImage catches a crashing or blank body.
    func testEveryRouteRendersInTheNotch() {
        let id = SnapshotMode.fixtureState().selectedProjectID!
        let routes: [Route] = [.projects, .project(id), .projectSettings(id), .createWorkspace(id),
                               .statsSettings(id), .otherSessions]
        for route in routes {
            let state = SnapshotMode.fixtureState()
            state.route = route
            let view = RootView(state: state)
                .environment(\.groveHost, .notch(width: 432))
                .frame(width: 432, height: 540)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .snapshotRender()
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            XCTAssertNotNil(renderer.cgImage, "\(route) did not render in the notch")
        }
    }

    func testNonCmuxErrorBannerBranch() {
        let s = SnapshotMode.fixtureState()
        s.actionError = "config.json is unreadable"   // no "cmux" -> no Launch cmux button
        render(s, CGSize(width: 460, height: 584))
    }

    func testProjectsTabWhileScanning() {
        let s = SnapshotMode.fixtureState()
        s.isScanning = true
        render(s, CGSize(width: 460, height: 520))
    }
}
