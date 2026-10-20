// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Combine
import SwiftUI

/// The open panel's sections, in the switch's order.
public enum NotchTab: String, CaseIterable, Sendable {
    case limits, projects, agents

    public var title: String {
        switch self {
        case .limits: return "Limits"
        case .projects: return "Projects"
        case .agents: return "Agents"
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    public var shortcut: Character {
        switch self {
        case .limits: return "1"
        case .projects: return "2"
        case .agents: return "3"
        }
    }
}

/// A key the panel hands to the section in front, while the panel is pinned.
public enum NotchKey: Equatable, Sendable {
    case up, down
    /// ↩: Go, Resume, or the form's own action.
    case open
    /// ⌘↩: Resume with options.
    case openWithOptions
    /// ⌫: dismiss what has the focus (a suggestion).
    case delete
    /// ⌘F
    case find
    /// Tab inside a form.
    case tab
}

/// What one section of the panel draws and does. The panel draws Limits itself;
/// Workspaces registers Projects (and Agents) while it runs. Every view returned observes
/// its own state: the panel installs them once and never rebuilds them on a publish.
@MainActor
public protocol NotchSection: AnyObject {
    /// The section's content: under the switch row, above the footer, `layout.contentWidth`
    /// wide. Scrolls on its own where it is taller than its room.
    func content(layout: NotchShellLayout) -> AnyView
    /// The switch row's trailing side: the section's own actions, 24 × 24 each.
    func switchAccessory() -> AnyView
    /// The footer's status line, 10.5 pt.
    func footerStatus() -> AnyView
    /// What the footer shows before the pin: Limits' share button. Empty elsewhere.
    func footerAccessory() -> AnyView
    /// The footer's ⟳, with its own busy state.
    func refreshButton() -> AnyView
    /// ⌘R and the ⟳.
    func refresh()
    /// Esc: true when the section went back a screen or closed something of its own; false
    /// at its root, where Esc closes the panel.
    func escape() -> Bool
    /// A key the panel did not use: true when the section used it.
    func handleKey(_ key: NotchKey) -> Bool
    /// The section came into view (true) or left it (false): the panel opened on it, the
    /// switch moved to it or away, the panel closed.
    func visibilityChanged(_ visible: Bool)
    /// The panel opened (true) or closed (false), whichever section is in front: what keeps
    /// the switch's marks current on every section.
    func panelOpenChanged(_ open: Bool)
    /// True while the section holds something that rebuilding its view would lose — a form
    /// half filled, a creation's log: the closed panel then keeps the shell in the tree.
    var keepsAliveWhileClosed: Bool { get }
}

public extension NotchSection {
    func switchAccessory() -> AnyView { AnyView(EmptyView()) }
    func footerAccessory() -> AnyView { AnyView(EmptyView()) }
    func escape() -> Bool { false }
    func handleKey(_ key: NotchKey) -> Bool { false }
    func visibilityChanged(_ visible: Bool) {}
    func panelOpenChanged(_ open: Bool) {}
    var keepsAliveWhileClosed: Bool { false }
}

/// Which sections the panel has. Limits is always there; the others while whoever provides
/// them registers them.
@MainActor
public final class NotchSections: ObservableObject {
    @Published public private(set) var registered: [NotchTab: any NotchSection] = [:]

    public init() {}

    public func register(_ tab: NotchTab, _ section: any NotchSection) {
        if let current = registered[tab], current === section { return }
        registered[tab] = section
    }

    public func unregister(_ tab: NotchTab) {
        guard registered[tab] != nil else { return }
        registered[tab] = nil
    }

    public func section(_ tab: NotchTab) -> (any NotchSection)? { registered[tab] }

    /// The registered sections, in the switch's order.
    public var tabs: [NotchTab] { NotchTab.allCases.filter { registered[$0] != nil } }

    /// More than one: the panel draws the switch row.
    public var showsSwitch: Bool { tabs.count > 1 }
}

/// The small marks the switch carries: sessions waiting for the user (a count on Projects)
/// and agents that talked in the last minute (a dot on Agents). Their providers set them.
@MainActor
public final class NotchBadges: ObservableObject {
    @Published public var projectsNeedYou = 0
    @Published public var agentsActive = false
    /// The sessions running as each account, by the account's config folder (as Limits
    /// lists it): the "N live" chip after its name.
    @Published public var liveByConfigDir: [String: Int] = [:]
    /// Opens Projects narrowed to the account in a config folder: what the chip does.
    public var openAccount: ((String) -> Void)?

    public init() {}

    /// The live count for an account by its config folder, however the folder is spelled.
    public func live(configDir: String) -> Int {
        liveByConfigDir[Self.key(configDir)] ?? 0
    }

    /// One spelling of a config folder: `~` expanded, no trailing slash.
    public static func key(_ dir: String) -> String {
        var path = (dir as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
