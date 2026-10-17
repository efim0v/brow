import Foundation

/// Every folder Workspaces reads or writes outside a project, as ONE value.
///
/// `AppState` takes it at construction instead of asking `NSHomeDirectory()` and
/// `FileManager` in a dozen places, so a test — or the app hosting the engine — decides
/// where the files go, and nothing reaches the real home folder by accident. A test
/// suite that wrote into `~/Library/Application Support/Grove/stats` (it did) is a test
/// suite every contributor runs against their own data.
public struct WorkspacesFolders: Sendable, Equatable {
    /// `…/Grove/config.json`: projects, accounts, the safety-net settings.
    public var configFile: URL
    /// `…/Grove/bin`: the status-line wrappers. Every monitored account's
    /// `settings.json` names a script here by its absolute path, so this folder never moves.
    public var bin: String
    /// `…/Grove/stats`: one code-statistics history file per project.
    public var stats: String
    /// `~/.claude-accounts`: where signed-in account folders are adopted from and new
    /// ones are made.
    public var accountsRoot: String
    /// `~/.claude`: the default account, and the root of the shared session store and
    /// of the transcript mirror.
    public var canonicalDir: String
    /// The home folder whose `.claude.json` belongs to the default account
    /// (`<home>/.claude` keeps its `.claude.json` one level up, in the home itself).
    public var home: String

    public init(configFile: URL, bin: String, stats: String, accountsRoot: String,
                canonicalDir: String, home: String) {
        self.configFile = configFile
        self.bin = bin
        self.stats = stats
        self.accountsRoot = accountsRoot
        self.canonicalDir = canonicalDir
        self.home = home
    }

    /// The real folders: Grove's under `~/Library/Application Support/Grove`, Claude
    /// Code's under the home folder.
    public static func live(home: String = NSHomeDirectory()) -> WorkspacesFolders {
        let appFolder = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Grove", isDirectory: true)
        return WorkspacesFolders(configFile: appFolder.appendingPathComponent("config.json"),
                                 bin: appFolder.appendingPathComponent("bin").path,
                                 stats: appFolder.appendingPathComponent("stats").path,
                                 accountsRoot: home + "/.claude-accounts",
                                 canonicalDir: home + "/.claude",
                                 home: home)
    }

    /// Everything next to `configFile`: `bin/` and `stats/` beside it, and a stand-in
    /// home folder (`home/`, with `home/.claude` and `home/.claude-accounts`) under it.
    /// What a config file that is not the real one gets by default — a test's, a
    /// snapshot render's — so nothing it does can land in the user's own folders.
    public static func beside(configFile: URL) -> WorkspacesFolders {
        let folder = configFile.deletingLastPathComponent()
        let home = folder.appendingPathComponent("home", isDirectory: true).path
        return WorkspacesFolders(configFile: configFile,
                                 bin: folder.appendingPathComponent("bin").path,
                                 stats: folder.appendingPathComponent("stats").path,
                                 accountsRoot: home + "/.claude-accounts",
                                 canonicalDir: home + "/.claude",
                                 home: home)
    }

    /// The default account's folder: `<home>/.claude`.
    public var defaultClaudeDir: String { home + "/.claude" }

    /// Where `configDir`'s `.claude.json` lives: the default account keeps it in the
    /// home folder, every other folder keeps it inside itself.
    public func claudeJSONPath(configDir: String) -> String {
        let dir = Self.normalized(expandTilde(configDir))
        return dir == defaultClaudeDir ? home + "/.claude.json" : dir + "/.claude.json"
    }

    /// How a folder under `accountsRoot` is written into `config.json`: `~/…` when the
    /// root is the real `~/.claude-accounts` (the form Grove has always stored, so a
    /// config moved to another Mac or user still reads), the absolute path otherwise.
    public func storedAccountDir(_ folder: String) -> String {
        if accountsRoot == NSHomeDirectory() + "/.claude-accounts" {
            return "~/.claude-accounts/" + folder
        }
        return accountsRoot + "/" + folder
    }

    static func normalized(_ path: String) -> String {
        var path = path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
