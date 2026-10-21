// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation

/// Where a Claude Code session stands, as every screen names it. ONE mapping, read from
/// the session's own record while it runs (`<config dir>/sessions/<pid>.json`, kept by
/// Claude Code itself), and from its transcript's last turn when the record does not say:
///
/// | The record says                                                       | State            |
/// |-----------------------------------------------------------------------|------------------|
/// | `busy`                                                                | working          |
/// | `waiting` for a permission prompt, a sandbox, a worker or a goal      | needs permission |
/// | `waiting` for input, or a dialog open                                 | asks you         |
/// | `idle` or `shell`                                                     | your turn        |
/// | no live record and no live process                                    | closed           |
/// | a live record without a status, or a live process without a record   | the transcript's turn: working or a tool call → working, otherwise your turn |
public enum SessionState: String, Sendable, Equatable, Hashable, CaseIterable {
    case needsPermission
    case asksYou
    case working
    case yourTurn
    case closed

    /// What `waitingFor` holds while a session waits on a permission of some kind.
    public static let permissionReasons: Set<String> = ["permission prompt", "sandbox request", "worker request",
                                                        "goal proposal"]
    /// … and while it waits on an answer.
    public static let inputReasons: Set<String> = ["input needed", "dialog open"]

    /// The state of a session whose live process is `live` (nil: none runs), its
    /// transcript ending at `turn`.
    public static func of(_ live: LiveProcess?, turn: SessionPreview.Turn? = nil) -> SessionState {
        guard let live else { return .closed }
        switch live.status {
        case "busy":
            return .working
        case "waiting":
            if let reason = live.waitingFor, permissionReasons.contains(reason) { return .needsPermission }
            // Input, a dialog, or a reason this version does not know: it stopped on the user.
            return .asksYou
        case "idle", "shell":
            return .yourTurn
        default:
            switch turn {
            case .working?, .tool?: return .working
            default: return .yourTurn
            }
        }
    }

    public var isLive: Bool { self != .closed }

    /// Stopped on the user: a permission to give, or a question to answer.
    public var needsYou: Bool { self == .needsPermission || self == .asksYou }

    /// The order lists show sessions in: what needs the user first, then what works, then
    /// what waits for the next prompt, then what is closed.
    public var rank: Int {
        switch self {
        case .needsPermission, .asksYou: return 0
        case .working: return 1
        case .yourTurn: return 2
        case .closed: return 3
        }
    }

    /// The state in words, as a row writes it.
    public var word: String {
        switch self {
        case .needsPermission: return "Needs permission"
        case .asksYou: return "Asks you"
        case .working: return "Working"
        case .yourTurn: return "Your turn"
        case .closed: return "Closed"
        }
    }
}
