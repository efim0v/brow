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

    /// The folder the "+" flow is waiting on, with the command the user runs to sign
    /// in there. Shown as a card in Settings until the account appears.
    @Published public private(set) var pendingDir: String?

    /// Brow's browser router, shipped inside the bundle (`Resources/brow-browser.sh`
    /// → `Contents/Resources/brow-browser`; a script in `MacOS/` would need its own
    /// code signature). Claude Code honours `BROWSER=` for the sign-in it opens, and
    /// the router sends that URL to a Chrome profile dedicated to
    /// `$CLAUDE_CONFIG_DIR` — one browser session per account, so signing one
    /// account in never signs another out. nil when not running from the bundle
    /// (tests), in which case the commands below fall back to the default browser.
    public static var browserHelperPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/Resources/brow-browser"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// `CLAUDE_CONFIG_DIR='…' BROWSER='…'` — the environment every command for
    /// `dir` starts with. The default `~/.claude` is the exception: it is selected by
    /// the variable being ABSENT (`isDefaultClaudeDir`), so its prefix removes it —
    /// the terminal the line is pasted into may well have another account exported.
    public static func environmentPrefix(dir: String) -> String {
        var prefix = isDefaultClaudeDir(dir) ? "env -u CLAUDE_CONFIG_DIR" : "CLAUDE_CONFIG_DIR=\(shellQuote(dir))"
        if let helper = browserHelperPath { prefix += " BROWSER=\(shellQuote(helper))" }
        return prefix
    }

    /// The one line a user pastes into any terminal to run Claude Code as this
    /// account. Plain `claude`, not the resolved binary path: this is what people
    /// type, and `claude` in a fresh config dir walks them through sign-in itself.
    public static func launchCommand(dir: String) -> String {
        "\(environmentPrefix(dir: dir)) claude"
    }

    /// The line for a shell profile (`~/.zshrc`): with it, a sign-in started from
    /// ANY terminal or from cmux goes to the account's own browser profile.
    public static var shellProfileLine: String? {
        browserHelperPath.map { "export BROWSER=\(shellQuote($0))" }
    }

    /// Open this account's browser profile on claude.ai without a sign-in in
    /// progress — to log the profile into Google/claude.ai once, so the next
    /// `claude auth login` is a single "Authorize" click. Goes through the router
    /// exactly like Claude Code does, so the profile is the same one.
    @discardableResult
    public static func openBrowserProfile(dir: String, url: String = "https://claude.ai/") -> String? {
        guard let helper = browserHelperPath else { return "the browser router is missing from this build" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [url]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = dir
        process.environment = env
        do { try process.run() } catch {
            BrowLog.tokens.error("open browser profile failed for \(dir, privacy: .public): \(String(describing: error), privacy: .public)")
            return error.localizedDescription
        }
        return nil
    }

    /// Sign this account in again, in its own browser profile: Terminal runs
    /// `claude auth login` for `dir`. The account keeps its folder and its row; only
    /// the token changes.
    @discardableResult
    public static func login(dir: String, claudePath: String) -> String? {
        openInTerminal(dir: dir, claudePath: claudePath, subcommand: "auth login")
    }

    public static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The one-click path: Brow picks the folder itself (`~/.claude-accounts/account-N`,
    /// the first N that is free), opens Terminal running Anthropic's own sign-in in it,
    /// and waits for the account to appear. The folder name is cosmetic — the row is
    /// labelled with the email once the sign-in lands — and it must never be renamed
    /// afterwards: Claude Code keys the account's Keychain item on the folder path.
    public func quickAdd(claudePath: String) {
        let dir = Self.freshAccountDir(home: home)
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch {
            status = "Could not create \(dir): \(error.localizedDescription)"
            BrowLog.tokens.error("create account dir failed at \(dir, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        pendingDir = dir
        if let reason = Self.openInTerminal(dir: dir, claudePath: claudePath, subcommand: "auth login") {
            // Terminal could not be driven (Automation consent denied is the usual
            // reason): the command card stays up so the user can run it by hand.
            status = "Could not open Terminal (\(reason)). Run the command below yourself and sign in."
        } else {
            status = "Sign in in the Terminal window that just opened; Brow picks the account up automatically."
        }
        startPolling(dir: dir)
    }

    /// `~/.claude-accounts/account-N` for the smallest N (from 1) that does not exist yet.
    static func freshAccountDir(home: String) -> String {
        let root = home + "/.claude-accounts"
        for n in 1...999 {
            let dir = "\(root)/account-\(n)"
            if !FileManager.default.fileExists(atPath: dir) { return dir }
        }
        return "\(root)/account-\(Int(Date().timeIntervalSince1970))"
    }

    /// "Existing folder…" in Settings: a standard folder picker rooted at
    /// `~/.claude-accounts` (created on demand). Returns the chosen folder, or nil if
    /// cancelled.
    public func chooseFolder() -> String? {
        let root = home + "/.claude-accounts"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true)
        panel.prompt = "Use This Folder"
        panel.message = "Choose (or create) a folder for the new account's Claude Code config."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Start waiting for a sign-in in `dir`: Brow shows the launch command (copy it or
    /// open it in Terminal), and polls the folder until Claude Code has written an
    /// organisation into it. Folders outside `~/.claude-accounts` are remembered in the
    /// settings so the account scan finds them.
    public func begin(dir: String) {
        let root = home + "/.claude-accounts/"
        if !dir.hasPrefix(root), !store.settings.extraDirs.contains(dir) {
            store.settings.extraDirs.append(dir)
        }
        pendingDir = dir
        status = "Run the command below in a terminal and sign in; Brow picks the account up automatically."
        startPolling(dir: dir)
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
        startPolling(dir: dir)
    }

    private func startPolling(dir: String) {
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
                // `claude auth login` leaves only `oauthAccount` behind; without this
                // the first `claude` in the folder runs the onboarding wizard as if
                // nobody were signed in.
                ClaudeService.ensureOnboarded(configDir: dir, home: home)
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
                    self.pendingDir = nil
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

    /// `CLAUDE_CONFIG_DIR=<dir> [BROWSER=<router>] <claude> <subcommand>` via Terminal.app.
    public static func terminalCommand(dir: String, claudePath: String, subcommand: String = "") -> String {
        "\(environmentPrefix(dir: dir)) \(shellQuote(claudePath)) \(subcommand)".trimmingCharacters(in: .whitespaces)
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
