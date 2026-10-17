import XCTest
import GroveCore

/// `accountKey` is implemented twice: in Swift (`GroveCore/Model/Paths.swift`), where it
/// names the Keychain item and the safety net's folders, and in shell
/// (`Resources/brow-browser.sh`), where it names the account's browser profile. The two
/// used to be kept identical by a comment; this runs the script and holds them to it.
final class BrowserRouterContractTests: XCTestCase {
    private var script: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/brow-browser.sh").path
    }

    private func routerKey(configDir: String?, home: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script, "--print-key"]
        var env = ["HOME": home, "PATH": "/usr/bin:/bin"]
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheRouterKeysAnAccountExactlyAsTheAppDoes() throws {
        let home = try Fixture.tempDir("router-home").path
        for dir in [home + "/.claude-accounts/work", home + "/with space/claude", home + "/trailing/"] {
            XCTAssertEqual(try routerKey(configDir: dir, home: home), accountKey(dir), dir)
        }
        // No CLAUDE_CONFIG_DIR is the default account, and a leading ~ is the home.
        XCTAssertEqual(try routerKey(configDir: nil, home: home), accountKey(home + "/.claude"))
        XCTAssertEqual(try routerKey(configDir: "~/.claude-accounts/x", home: home),
                       accountKey(home + "/.claude-accounts/x"))
    }

    /// `--print-key` reads nothing and makes nothing: no profile folder appears.
    func testPrintingTheKeyTouchesNothing() throws {
        let home = try Fixture.tempDir("router-quiet").path
        _ = try routerKey(configDir: home + "/acct", home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library"))
    }
}
