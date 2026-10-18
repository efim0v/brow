// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveCore

/// The folders running sessions work in, offered as projects: one per repository (or
/// folder of repositories), never one that a project already shows, never noise.
final class ProjectSuggestionsTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    /// A home folder of made-up work:
    ///
    ///     harbor/            a repository, with Sources/
    ///     harbor-link        a symlink to harbor
    ///     fleet/             not a repository: holds api/ and web/, which are
    ///     notes/             a plain folder
    ///     meta/              a repository with a submodule, vendor/lib
    ///     Workspaces/harbor/feature-x/harbor   a linked worktree of harbor
    ///     .config/tool/      a hidden folder
    override func setUpWithError() throws {
        home = try Fixture.tempDir("suggest-home")
        let code = home.appendingPathComponent("Code")
        let harbor = try Fixture.makeRepo(in: code, name: "harbor")
        try fm.createDirectory(at: harbor.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: code.appendingPathComponent("harbor-link"), withDestinationURL: harbor)
        let fleet = code.appendingPathComponent("fleet")
        _ = try Fixture.makeRepo(in: fleet, name: "api")
        _ = try Fixture.makeRepo(in: fleet, name: "web")
        try fm.createDirectory(at: code.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let lib = try Fixture.makeRepo(in: home.appendingPathComponent("sources"), name: "lib")
        let meta = try Fixture.makeRepo(in: code, name: "meta")
        try Fixture.sh("git -c protocol.file.allow=always submodule add -q \(lib.path) vendor/lib && git commit -qm sub", cwd: meta)
        let worktree = home.appendingPathComponent("Workspaces/harbor/feature-x/harbor")
        try fm.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.addWorktree(repo: harbor, branch: "feature-x", from: "main", at: worktree)
        try fm.createDirectory(at: home.appendingPathComponent(".config/tool"), withIntermediateDirectories: true)
    }

    private func path(_ relative: String) -> String {
        ProjectSuggestions.canonical(home.appendingPathComponent(relative).path)
    }

    private func suggest(_ cwds: [String], covered: [String] = [], dismissed: Set<String> = []) -> [ProjectSuggestion] {
        let live = cwds.enumerated().map { ProjectSuggestions.Live(pid: Int32(100 + $0.offset), cwd: home.appendingPathComponent($0.element).path) }
        return ProjectSuggestions.suggest(live: live, covered: covered.map(path), dismissed: Set(dismissed.map(path)),
                                          home: home.path, temporaryRoots: [])
    }

    func testEachSessionPointsAtTheRepositoryItWorksIn() {
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Code/harbor/Sources"), home: path("")), path("Code/harbor"))
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Code/harbor-link"), home: path("")), path("Code/harbor"), "the real path")
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Workspaces/harbor/feature-x/harbor"), home: path("")),
                       path("Code/harbor"), "a linked worktree is its repository")
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Code/meta/vendor/lib"), home: path("")), path("Code/meta"),
                       "a submodule is the repository around it")
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Code/fleet"), home: path("")), path("Code/fleet"),
                       "a folder of repositories is a project")
        XCTAssertEqual(ProjectSuggestions.folder(for: path("Code/fleet/web"), home: path("")), path("Code/fleet/web"))
        XCTAssertNil(ProjectSuggestions.folder(for: path("Code/notes"), home: path("")), "a plain folder is not")
        XCTAssertNil(ProjectSuggestions.folder(for: path(""), home: path("")), "nor is the home folder")
    }

    func testOneSuggestionPerFolderTheBusiestFirst() {
        let found = suggest(["Code/harbor/Sources", "Code/harbor-link", "Workspaces/harbor/feature-x/harbor",
                             "Code/fleet", "Code/notes", "", ".config/tool", "Code/meta/vendor/lib"])
        XCTAssertEqual(found.map(\.path), [path("Code/harbor"), path("Code/fleet"), path("Code/meta")])
        XCTAssertEqual(found.first?.pids, [100, 101, 102])
        XCTAssertEqual(found.first?.cwds.count, 3)
        XCTAssertEqual(found.first?.name, "harbor")
    }

    func testWhatAProjectAlreadyShowsIsNotSuggested() {
        XCTAssertEqual(suggest(["Code/harbor/Sources", "Code/fleet/api"], covered: ["Code/harbor", "Code/fleet"]).map(\.path), [])
        // The workspaces folder of a project counts as the project's.
        XCTAssertEqual(suggest(["Workspaces/harbor/feature-x/harbor"], covered: ["Workspaces/harbor"]).map(\.path), [])
        XCTAssertEqual(suggest(["Code/fleet/api"], dismissed: ["Code/fleet/api"]).map(\.path), [], "turned down once is enough")
    }

    func testNoiseIsNeverAProject() {
        let h = "/Users/demo"
        for noise in ["/", h, h + "/Library/Caches/x", h + "/.claude/projects", h + "/.cmux/worktrees/a", "/tmp/x",
                      "/private/var/folders/ab/T/x", "/Applications/Tool.app", "/usr/local/src", "/Volumes/Disk"] {
            XCTAssertTrue(ProjectSuggestions.isNoise(noise, home: h), noise)
        }
        for real in [h + "/Code/harbor", "/Volumes/Disk/Code/harbor", h + "/Desktop/thing"] {
            XCTAssertFalse(ProjectSuggestions.isNoise(real, home: h), real)
        }
    }
}
