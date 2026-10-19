// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// The panel's navigation state machine: at any moment the panel shows ONE
/// scope (general -> specific), never an overlay. RootView switches over this
/// and animates transitions; AppState.open/goBack mutate it.
public enum Route: Hashable {
    case projects
    case project(UUID)
    case projectSettings(UUID)
    case createWorkspace(UUID)
    /// The Stats-tab settings page (directory+file exclusion tree). Reached from a
    /// gear affordance on the Stats tab; backs out to its project (the Stats tab).
    case statsSettings(UUID)
    /// Sessions discovered disk-wide that don't match any configured project.
    /// Shown as a sibling entry in the projects navigation (footer or cards area).
    case otherSessions
    /// New session / Resume with options: `AppState.launchRequest`, pushed over the screen
    /// it was asked from (`AppState.launchOrigin`), which it goes back to.
    case launch

    /// Scope depth, used to classify a route change as push (deeper or equal)
    /// or pop (shallower) for the transition direction.
    public var depth: Int {
        switch self {
        case .projects: return 0
        case .project, .otherSessions: return 1
        case .projectSettings, .createWorkspace, .statsSettings: return 2
        case .launch: return 3
        }
    }

    /// Explicit back-map: createWorkspace/projectSettings/statsSettings -> their
    /// project; project/otherSessions -> projects; projects -> itself (root). The launch
    /// form goes back to the screen it was opened from (`AppState.cancelLaunch`).
    public var backRoute: Route {
        switch self {
        case .projects: return .projects
        case .project, .otherSessions, .launch: return .projects
        case .projectSettings(let id), .createWorkspace(let id), .statsSettings(let id):
            return .project(id)
        }
    }
}

/// What the panel can ask the host's Settings window to show.
public enum WorkspacesSettingsLink: Sendable, Equatable {
    /// Workspaces' own settings: projects, folders, the safety net, the material.
    case workspaces
    /// The accounts, with their sharing, capture and default model.
    case accounts
}
