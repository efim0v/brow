// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import GroveCore
@testable import GroveAppKit

/// One project per folder and one project per session: a folder that overlaps a project is not
/// added next to it, and a session two projects' folders hold shows under the closer one only.
@MainActor
final class ProjectOverlapTests: XCTestCase {
    private let shop = ProjectConfig(name: "shop", path: "/Users/demo/Code/shop")

    private func workspaces(_ project: ProjectConfig) -> String { "/Users/demo/Workspaces/" + project.name }

    private func overlap(_ path: String) -> String? {
        AppState.overlap(adding: path, to: [shop], workspacesRoot: workspaces)
    }

    func testAFolderThatOverlapsAProjectIsNotAdded() {
        XCTAssertNil(overlap("/Users/demo/Code/notes"))
        XCTAssertNil(overlap("/Users/demo/Code/shopfront"), "a name that starts like the folder's is another folder")
        XCTAssertEqual(overlap("/Users/demo/Code/shop"), "shop is a project already.")
        XCTAssertEqual(overlap("/Users/demo/Code/shop/api"), "This folder is part of the project shop.")
        XCTAssertEqual(overlap("/Users/demo/Code"), "This folder holds the project shop: add the folders beside it one by one.")
        XCTAssertEqual(overlap("/Users/demo/Workspaces/shop/feature-x"), "This folder holds shop's workspaces.")
        XCTAssertEqual(overlap("/Users/demo/Elsewhere/shop"), "There is a project named shop already.",
                       "one name, one workspaces folder")
    }

    func testASessionShowsUnderTheProjectThatHoldsItMostClosely() {
        let outer = UUID(), inner = UUID(), twin = UUID()
        let owner = AppState.sessionOwner(projectRoots: [
            (outer, ["/Users/demo/Code", "/Users/demo/Workspaces/Code"]),
            (inner, ["/Users/demo/Code/shop", "/Users/demo/Workspaces/shop"]),
            (twin, ["/Users/demo/Elsewhere/shop", "/Users/demo/Workspaces/shop"]),
        ])
        XCTAssertEqual(owner("/Users/demo/Code/shop/api"), inner, "the project inside wins")
        XCTAssertEqual(owner("/Users/demo/Code/notes"), outer)
        XCTAssertEqual(owner("/Users/demo/Workspaces/shop/feature-x/api"), inner,
                       "two of one name share a workspaces folder: the first in the list")
        XCTAssertEqual(owner("/Users/demo/Elsewhere/shop"), twin)
        XCTAssertNil(owner("/Users/demo/Notes"))
    }
}
