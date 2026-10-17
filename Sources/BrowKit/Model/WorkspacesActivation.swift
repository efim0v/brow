import Foundation

/// The Workspaces part of Brow's own `config.json`: whether it runs, whether its
/// menu-bar item shows, and the panel's material. Grove's own `config.json` is not
/// touched by any of these.
public struct WorkspacesSettings: Codable, Sendable, Equatable {
    /// The user's choice; nil until they make one, and Workspaces then follows whether
    /// a Grove config exists (`WorkspacesActivation`).
    public var enabled: Bool?
    /// Settings › General › Show Workspaces in the menu bar.
    public var showInMenuBar: Bool = true
    /// `liquidGlass` or `visualEffect`; nil means Liquid Glass.
    public var panelMaterial: String?
    /// Grove's own material setting has been looked at, and copied if there was one.
    /// Once only: a later change in Grove.app is not Brow's.
    public var importedGroveMaterial: Bool = false

    public init(enabled: Bool? = nil, showInMenuBar: Bool = true, panelMaterial: String? = nil,
                importedGroveMaterial: Bool = false) {
        self.enabled = enabled
        self.showInMenuBar = showInMenuBar
        self.panelMaterial = panelMaterial
        self.importedGroveMaterial = importedGroveMaterial
    }

    enum CodingKeys: String, CodingKey { case enabled, showInMenuBar, panelMaterial, importedGroveMaterial }

    /// Field by field: one bad value costs that field, never the others (brow#7).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issues = decoder.userInfo[.browSettingsIssues] as? SettingsIssues
        func field<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) } catch {
                issues?.record("workspaces.\(key.stringValue)")
                return nil
            }
        }
        enabled = field(.enabled, Bool.self)
        showInMenuBar = field(.showInMenuBar, Bool.self) ?? true
        panelMaterial = field(.panelMaterial, String.self)
        importedGroveMaterial = field(.importedGroveMaterial, Bool.self) ?? false
    }
}

/// Whether Workspaces runs. Pure: the three facts it depends on are passed in.
///
/// - Someone who used Grove has `~/Library/Application Support/Grove/config.json`, and
///   Workspaces turns itself on for them, projects, accounts and all. The folder alone
///   says nothing: a Brow-only Mac has a `Grove` folder too, holding Brow's own request
///   pacing file.
/// - Everyone else has it off until they turn it on in Settings, or add a project.
/// - While Grove.app runs, nothing runs: two engines would race on Grove's
///   `config.json` (an atomic replace, the last writer wins) and run two mirrors and two
///   status-line reconcilers. The user is offered "Quit Grove".
/// - Off means none of the engine's launch work at all: no account adoption, no
///   status-line install, no 90 s capture and mirror timer, no pre-render.
public enum WorkspacesActivation: Equatable, Sendable {
    case off
    /// Wanted, but Grove.app is running.
    case paused
    case on

    public static func decide(setting: Bool?, groveConfigExists: Bool, groveRunning: Bool) -> WorkspacesActivation {
        guard setting ?? groveConfigExists else { return .off }
        return groveRunning ? .paused : .on
    }

    /// Wanted at all: on, or waiting for Grove.app to quit.
    public var isWanted: Bool { self != .off }
}

/// Grove.app, the app Brow 0.4 replaces, as far as Brow needs to know about it.
public struct GroveAppGuard: Sendable {
    /// `grove3` since the 26.4 menu-bar cache broke the slot of the older id.
    public static let bundleIdentifiers = ["dev.artemefimov.grove3", "dev.artemefimov.grove"]

    private let runningBundleIdentifiers: @Sendable () -> [String]

    /// `runningBundleIdentifiers`: the bundle ids of the running apps; injectable so
    /// tests never look at the real ones.
    public init(runningBundleIdentifiers: @escaping @Sendable () -> [String]) {
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }

    public var isGroveRunning: Bool {
        let running = Set(runningBundleIdentifiers())
        return Self.bundleIdentifiers.contains(where: running.contains)
    }

    /// Whether an app with `bundleIdentifier` is a Grove: what a launch or quit
    /// notification is checked against.
    public static func isGrove(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }
}
