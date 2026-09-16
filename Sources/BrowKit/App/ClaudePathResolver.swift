import Foundation
import GroveCore

/// GUI apps launch with a stripped PATH; ask the user's login shell where
/// `claude` lives, once, at launch. Settings can override the result.
public enum ClaudePathResolver {
    /// Shown verbatim in Settings › General when detection came back empty, so
    /// the user can see what was tried.
    public static let detectionCommand = "/bin/zsh -lic 'command -v claude'"

    public static func resolve(runner: CommandRunning) async -> String? {
        guard let result = try? await runner.run("/bin/zsh", ["-lic", "command -v claude"], cwd: nil, env: nil, timeout: 10),
              result.exitCode == 0 else { return nil }
        // An interactive login shell may print its own noise first; the path is
        // the last line `command -v` wrote.
        let path = result.stdout.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.hasPrefix("/") ? path : nil
    }
}
