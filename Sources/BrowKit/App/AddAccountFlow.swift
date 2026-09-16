import AppKit
import Foundation
import GroveCore

/// "Add account…": create a config dir, hand the user to the REAL `claude auth
/// login` in Terminal (sign-in must go through Anthropic's own flow), then watch
/// the dir until Claude Code has written an `organizationUuid` into it.
@MainActor
public final class AddAccountFlow: ObservableObject {
    public static let pollInterval: TimeInterval = 5
    public static let pollLimit: TimeInterval = 600

    @Published public private(set) var status: String?
    private let store: LimitsStore
    private let home: String
    private var pollTask: Task<Void, Never>?

    public init(store: LimitsStore, home: String = NSHomeDirectory()) {
        self.store = store
        self.home = home
    }

    /// Rejects anything that is not a plain new folder under `~/.claude-accounts`.
    /// `.` and `..` are single path components and used to pass: `..` resolved the dir
    /// to `$HOME`, `createDirectory` succeeded on it, and Terminal was handed
    /// `CLAUDE_CONFIG_DIR=$HOME claude auth login` — Claude Code's config root pointed
    /// at the home directory. A leading dot is refused for a second reason too:
    /// `AccountDirectory.candidateDirs` skips dot-names, so a successful sign-in in
    /// `.work` could never be discovered and would read as a 10-minute timeout.
    static func accountDir(forName folderName: String, home: String) -> String? {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = home + "/.claude-accounts/"
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), name != ".", name != ".." else { return nil }
        let dir = root + name
        guard URL(fileURLWithPath: dir).standardized.path.hasPrefix(root) else { return nil }
        return dir
    }

    public func begin(folderName: String, claudePath: String) {
        guard let dir = Self.accountDir(forName: folderName, home: home) else {
            status = "Folder name must be a single path component and must not start with a dot"
            return
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch {
            status = "Could not create \(dir): \(error.localizedDescription)"
            BrowLog.tokens.error("create account dir failed at \(dir, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        // A Terminal that never opened (TCC automation consent denied on first run is
        // the likely case) must say so NOW, not surface as a bogus timeout ten minutes
        // later from a poll that was watching a folder nobody was signing in to.
        if let reason = Self.openInTerminal(dir: dir, claudePath: claudePath, subcommand: "auth login") {
            status = "Could not open Terminal: \(reason)"
            return
        }
        status = "Waiting for sign-in in Terminal…"
        pollTask?.cancel()
        pollTask = Task { [weak self, home] in
            let deadline = Date().addingTimeInterval(Self.pollLimit)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                // A cancelled sleep throws into `try?`; returning here keeps a
                // superseded run from refreshing, and from writing its timeout
                // line over the status the run that replaced it just set.
                if Task.isCancelled { return }
                // The spec's poll is a DIR poll: one `.claude.json` read, off the main
                // actor. It used to be a full `store.refresh` — 120 token-upkeep plus
                // usage-fetch cycles over ten minutes, flipping isRefreshing every 5 s
                // and overlapping the background cycle — for something one
                // FileManager.contents call away.
                let signedIn = await Task.detached {
                    AccountDirectory.identity(configDir: dir, home: home) != nil
                }.value
                guard signedIn else { continue }
                guard let self else { return }
                // `allRows`, not `rows`: a re-signed-in account that the user has
                // hidden is still "already known", and must not read as a timeout.
                let known = self.store.allRows.map(\.id)
                await self.store.refresh(force: true)
                // The refresh is the loop's other suspension point: cancellation
                // can land here too, and a superseded run must not report its own
                // dir's outcome over the status the run that replaced it just set.
                if Task.isCancelled { return }
                let found = self.store.allRows.first { $0.account.configDir == dir || $0.account.aliasDirs.contains(dir) }
                if let found {
                    self.status = known.contains(found.id)
                        ? "Same account as \(found.name) — folder recorded as an alias"
                        : "Added \(found.name)"
                    return
                }
                // The dir carries an organizationUuid but the scan did not surface it:
                // report it instead of forcing a fetch every 5 s for ten minutes.
                BrowLog.tokens.error("signed-in dir \(dir, privacy: .public) did not resolve to an account")
                self.status = "Signed in, but \(dir) did not resolve to an account. Open Settings › Accounts."
                return
            }
            // Only a real 10-minute timeout writes the failure line; a loop that
            // exited because it was cancelled leaves the live run's status alone.
            if !Task.isCancelled {
                self?.status = "No sign-in detected in 10 minutes. Run `claude auth login` in that folder and refresh."
            }
        }
    }

    /// `CLAUDE_CONFIG_DIR=<dir> <claude> <subcommand>` via Terminal.app.
    public static func terminalCommand(dir: String, claudePath: String, subcommand: String = "") -> String {
        "CLAUDE_CONFIG_DIR=\(shellQuote(dir)) \(shellQuote(claudePath)) \(subcommand)".trimmingCharacters(in: .whitespaces)
    }

    /// nil when Terminal really was asked to run the command; otherwise the reason,
    /// for the UI slot the caller owns. Nothing is swallowed: the nil-initialiser
    /// branch (which left `error` nil, so the old code logged nothing at all) is
    /// logged too.
    @discardableResult
    public static func openInTerminal(dir: String, claudePath: String, subcommand: String = "") -> String? {
        let command = terminalCommand(dir: dir, claudePath: claudePath, subcommand: subcommand)
        let source = "tell application \"Terminal\"\nactivate\ndo script \(appleScriptQuote(command))\nend tell"
        guard let script = NSAppleScript(source: source) else {
            BrowLog.tokens.error("could not compile the Terminal script for \(dir, privacy: .public)")
            return "the Terminal script could not be compiled"
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        BrowLog.tokens.error("open Terminal failed: \(error, privacy: .public)")
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
        let number = (error[NSAppleScript.errorNumber] as? Int).map { " (\($0))" } ?? ""
        return message + number
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
