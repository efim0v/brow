import XCTest
@testable import GroveCore

/// The tool answers to `brow` and, for Grove's scripts, to `grove`.
final class ToolNameTests: XCTestCase {
    func testTheNameItWasRunAsDecides() {
        XCTAssertEqual(ToolName.resolve(argv0: "/opt/homebrew/bin/grove"), "grove")
        XCTAssertEqual(ToolName.resolve(argv0: "grove"), "grove")
        XCTAssertEqual(ToolName.resolve(argv0: "/usr/local/bin/brow"), "brow")
        XCTAssertEqual(ToolName.resolve(argv0: ".build/release/brow"), "brow")
        XCTAssertEqual(ToolName.resolve(argv0: "grove-cli"), "brow", "only the exact old name is the old name")
        XCTAssertEqual(ToolName.resolve(argv0: ""), "brow")
    }

    /// Run as `grove`, the help text is Grove's tool's, byte for byte.
    func testUnderTheOldNameTheHelpTextIsUnchanged() {
        let grove022 = """
        grove — git-worktree / Claude Code orchestration

        usage:
          grove scan <path> [--json]
          grove workspaces <path> [--json]
          grove sessions <cwd> [--json]
          grove create <path> <name> [--repos a,b] [--branch x] [--from workspace] [--from-branch <repoDir>=<branch>] [--json]
          grove graph <repoPath> [--limit N] [--json]
          grove doctor [--json]
          grove --version

        create flags:
          --from-branch <repoDir>=<branch>   Fork a specific repo from <branch> instead of the default
                                             start point. Repeatable; takes precedence over --from.

        doctor:
          Exits 1 when it can't run git or claude. cmux is optional.
        """
        XCTAssertEqual(ToolName.usage("grove"), grove022)
    }

    func testUnderItsOwnNameEveryLineSaysBrow() {
        let text = ToolName.usage("brow")
        XCTAssertTrue(text.hasPrefix("brow — "))
        XCTAssertFalse(text.contains("grove"))
        XCTAssertTrue(text.contains("  brow doctor [--json]"))
    }
}
