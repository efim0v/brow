import XCTest
@testable import GroveCore

final class WorkspacesFoldersTests: XCTestCase {
    func testLiveFoldersAreGrovesAndClaudeCodesUnderTheHome() {
        let folders = WorkspacesFolders.live(home: "/Users/u")
        XCTAssertEqual(folders.configFile.path, "/Users/u/Library/Application Support/Grove/config.json")
        XCTAssertEqual(folders.bin, "/Users/u/Library/Application Support/Grove/bin")
        XCTAssertEqual(folders.stats, "/Users/u/Library/Application Support/Grove/stats")
        XCTAssertEqual(folders.accountsRoot, "/Users/u/.claude-accounts")
        XCTAssertEqual(folders.canonicalDir, "/Users/u/.claude")
        XCTAssertEqual(folders.defaultClaudeDir, "/Users/u/.claude")
    }

    /// A config file that is not the real one gets EVERYTHING next to it, the stand-in
    /// home included, so nothing reaches the user's folders.
    func testBesideKeepsEveryFolderNextToTheConfigFile() {
        let folders = WorkspacesFolders.beside(configFile: URL(fileURLWithPath: "/tmp/t/config.json"))
        XCTAssertEqual(folders.bin, "/tmp/t/bin")
        XCTAssertEqual(folders.stats, "/tmp/t/stats")
        XCTAssertEqual(folders.home, "/tmp/t/home")
        XCTAssertEqual(folders.canonicalDir, "/tmp/t/home/.claude")
        XCTAssertEqual(folders.accountsRoot, "/tmp/t/home/.claude-accounts")
        for path in [folders.bin, folders.stats, folders.canonicalDir, folders.accountsRoot] {
            XCTAssertTrue(path.hasPrefix("/tmp/t/"), path)
        }
    }

    func testTheDefaultAccountKeepsItsClaudeJSONInTheHome() {
        let folders = WorkspacesFolders.live(home: "/Users/u")
        XCTAssertEqual(folders.claudeJSONPath(configDir: "/Users/u/.claude"), "/Users/u/.claude.json")
        XCTAssertEqual(folders.claudeJSONPath(configDir: "/Users/u/.claude/"), "/Users/u/.claude.json")
        XCTAssertEqual(folders.claudeJSONPath(configDir: "/Users/u/.claude-accounts/work"),
                       "/Users/u/.claude-accounts/work/.claude.json")
    }

    /// `~/.claude-accounts/<name>` is what Grove has always written for the real root;
    /// any other root is written out in full.
    func testAccountFoldersAreStoredWithATildeOnlyForTheRealRoot() {
        XCTAssertEqual(WorkspacesFolders.live().storedAccountDir("work"), "~/.claude-accounts/work")
        let other = WorkspacesFolders.beside(configFile: URL(fileURLWithPath: "/tmp/t/config.json"))
        XCTAssertEqual(other.storedAccountDir("work"), "/tmp/t/home/.claude-accounts/work")
    }
}
