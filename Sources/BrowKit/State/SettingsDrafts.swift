import Foundation

/// Edits typed into the Settings window that have not been written to
/// `BrowSettings` yet.
///
/// The account name field keeps its text in SwiftUI `@State` and commits on Return
/// or focus loss, because every write of `store.settings` is an atomic JSON write
/// plus a full recompute plus a panel re-render — one per keystroke is not an
/// option. But the Settings window's SwiftUI tree (and every `@State` in it) is
/// destroyed when the window closes, and SwiftUI does not promise to deliver the
/// focus-loss change before that teardown: a name typed and then "finished" by
/// closing the window was silently discarded.
///
/// So the drafts live OUT here, outside the view tree, where
/// `BrowAppController.windowWillClose` — and `applicationWillTerminate`, for a
/// Cmd-Q with the window still open — can flush them before anything is torn down.
@MainActor
public final class SettingsDrafts {
    private var names: [String: String] = [:]

    public init() {}

    /// Record a keystroke. Cheap: a dictionary write, no JSON, no recompute.
    public func record(_ name: String, for accountID: String) { names[accountID] = name }

    public var isEmpty: Bool { names.isEmpty }

    /// Write every pending edit through — ONE settings write for all of them, and
    /// none at all when nothing actually changed (the field also re-records the value
    /// it is handed when settings change underneath it). Returns whether it wrote.
    @discardableResult
    public func flush(into store: LimitsStore) -> Bool {
        guard !names.isEmpty else { return false }
        var settings = store.settings
        var changed = false
        for (accountID, typed) in names {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            let name: String? = trimmed.isEmpty ? nil : trimmed
            guard settings.accounts[accountID]?.name != name else { continue }
            settings.accounts[accountID, default: AccountOverride(name: nil, hidden: false)].name = name
            changed = true
        }
        names.removeAll()
        if changed { store.settings = settings }
        return changed
    }
}
