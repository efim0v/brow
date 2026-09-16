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

    public func begin(folderName: String, claudePath: String) {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { status = "Folder name must be a single path component"; return }
        let dir = home + "/.claude-accounts/" + name
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch {
            status = "Could not create \(dir): \(error.localizedDescription)"
            BrowLog.tokens.error("create account dir failed at \(dir, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        Self.openInTerminal(dir: dir, claudePath: claudePath, subcommand: "auth login")
        status = "Waiting for sign-in in Terminal…"
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.pollLimit)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                // A cancelled sleep throws into `try?`; returning here keeps a
                // superseded run from refreshing, and from writing its timeout
                // line over the status the run that replaced it just set.
                if Task.isCancelled { return }
                guard let self else { return }
                // `allRows`, not `rows`: a re-signed-in account that the user has
                // hidden is still "already known", and must not read as a timeout.
                let known = self.store.allRows.map(\.id)
                await self.store.refresh(force: false)
                let found = self.store.allRows.first { $0.account.configDir == dir || $0.account.aliasDirs.contains(dir) }
                if let found {
                    self.status = known.contains(found.id)
                        ? "Same account as \(found.name) — folder recorded as an alias"
                        : "Added \(found.name)"
                    return
                }
            }
            self?.status = "No sign-in detected in 10 minutes. Run `claude auth login` in that folder and refresh."
        }
    }

    /// `CLAUDE_CONFIG_DIR=<dir> <claude> <subcommand>` via Terminal.app.
    public static func terminalCommand(dir: String, claudePath: String, subcommand: String = "") -> String {
        "CLAUDE_CONFIG_DIR=\(shellQuote(dir)) \(shellQuote(claudePath)) \(subcommand)".trimmingCharacters(in: .whitespaces)
    }

    public static func openInTerminal(dir: String, claudePath: String, subcommand: String = "") {
        let command = terminalCommand(dir: dir, claudePath: claudePath, subcommand: subcommand)
        let script = "tell application \"Terminal\"\nactivate\ndo script \(appleScriptQuote(command))\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { BrowLog.tokens.error("open Terminal failed: \(error, privacy: .public)") }
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
