// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveCore

/// Made-up agents for the Agents tab's offscreen renders: sessions of three accounts talking,
/// a session's subagents and a teammate, an agent team, a session on another Mac. Every name,
/// folder and line is invented; the times count back from `now`.
public enum AgentsSnapshot {
    /// The accounts' keys as the observer names them (`AgentsAccount.key`).
    public struct Accounts: Sendable {
        public let work: String
        public let team: String
        public let personal: String

        public init(work: String, team: String, personal: String) {
            self.work = work
            self.team = team
            self.personal = personal
        }
    }

    static let workspaces = "/Users/demo/Workspaces/acme.shop"
    static let notes = "/Users/demo/Code/field-notes"

    static func session(_ name: String, _ account: String, status: String?, waitingFor: String? = nil,
                        cwd: String) -> AgentNode {
        let id = "s-" + name
        return AgentNode(id: "session:\(account):\(id)", name: name, kind: .session, account: account,
                         live: status.map { LiveProcess(pid: 0, sessionId: id, cwd: cwd, status: $0, accountName: account,
                                                        waitingFor: waitingFor) },
                         cwd: cwd)
    }

    static func agent(_ name: String, of parent: AgentNode, kind: AgentNode.Kind = .subagent,
                      detail: String? = nil) -> AgentNode {
        let prefix = kind == .teammate ? "teammate" : "agent"
        return AgentNode(id: "\(prefix):\(parent.account ?? ""):\(parent.sessionId ?? ""):\(name)", name: name, kind: kind,
                         parent: parent.id, account: parent.account, detail: detail)
    }

    struct Line {
        let from: AgentNode
        let to: AgentNode
        let ago: TimeInterval
        let text: String
        var kind: AgentMessage.Kind = .crossSession
        var delivery: AgentMessage.Delivery = .delivered
    }

    static func graph(nodes: [AgentNode], lines: [Line], spawns: [(AgentNode, AgentNode, TimeInterval, String)],
                      now: Date) -> AgentGraph {
        var byId: [String: AgentNode] = [:]
        for node in nodes { byId[node.id] = node }
        let messages = lines.enumerated().map { index, line in
            AgentMessage(id: "m\(index + 1)", from: line.from.id, to: line.to.id, kind: line.kind, delivery: line.delivery,
                         at: now.addingTimeInterval(-line.ago), text: line.text)
        }.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        let made = spawns.map { parent, child, ago, what in
            AgentSpawn(parent: parent.id, child: child.id, kind: child.kind, at: now.addingTimeInterval(-ago), description: what)
        }
        return AgentGraph(nodes: byId, messages: messages, spawns: made)
    }

    /// Three sessions: atlas works with two subagents and a reviewer, and talks to harbor, which
    /// waits on a permission and has a subagent of its own; quill, whose turn it is, last spoke
    /// to atlas 40 minutes ago. `flight`: how long ago atlas's newest message left (in flight for
    /// its first second); lumen's report is in flight too when `lumenFlight` is set. `quiet`
    /// moves everything 11 minutes back, every session waiting on its user.
    public static func live(_ accounts: Accounts, now: Date, flight: TimeInterval = 0.58,
                            lumenFlight: TimeInterval? = 0.4, quiet: Bool = false) -> AgentGraph {
        let shift: TimeInterval = quiet ? 11 * 60 : 0
        let atlas = session("atlas", accounts.work, status: quiet ? "idle" : "busy",
                            cwd: workspaces + "/checkout-redesign")
        let harbor = session("harbor", accounts.team, status: quiet ? "idle" : "waiting",
                             waitingFor: quiet ? nil : "permission prompt", cwd: workspaces + "/fix-payment-webhooks")
        let quill = session("quill", accounts.personal, status: "idle", cwd: notes)
        let lumen = agent("lumen", of: atlas, detail: "test runner")
        let scout = agent("scout", of: atlas, detail: "explorer")
        let reviewer = agent("reviewer", of: atlas, kind: .teammate, detail: "code reviewer")
        let probe = agent("probe", of: harbor, detail: "log reader")
        let lines = [
            Line(from: atlas, to: harbor, ago: flight + shift,
                 text: "Orders now post idempotently — can you rerun the webhook suite against them?",
                 delivery: quiet ? .delivered : .sending),
            Line(from: lumen, to: atlas, ago: (lumenFlight ?? 8) + shift,
                 text: "9 of 12 pass. Failing: ZIP+4, PO boxes, empty unit.", kind: .subagent),
            Line(from: harbor, to: atlas, ago: 40 + shift,
                 text: "Rerun done: 41 passed, 1 flaky (clock skew on the signature)."),
            Line(from: harbor, to: probe, ago: 120 + shift,
                 text: "Find the deliveries that failed twice in the last day.", kind: .subagent),
            Line(from: atlas, to: scout, ago: 240 + shift, text: "Find every place we format postal codes.",
                 kind: .subagent),
            Line(from: reviewer, to: atlas, ago: 360 + shift, text: "Plan approved, two notes on the error copy.",
                 kind: .teammate),
            Line(from: atlas, to: harbor, ago: 420 + shift,
                 text: "Schema change is in: orders carry an idempotency key now."),
            Line(from: quill, to: atlas, ago: 2_400, text: "Can I reuse your address fixtures for the sync tests?"),
        ]
        return graph(nodes: [atlas, harbor, quill, lumen, scout, reviewer, probe], lines: lines,
                     spawns: [(harbor, probe, 180 + shift, "Read the webhook logs"),
                              (atlas, lumen, 720 + shift, "Run the checkout tests"),
                              (atlas, scout, 840 + shift, "Map the postal code helpers"),
                              (atlas, reviewer, 1_200 + shift, "Review the plan")],
                     now: now)
    }

    /// Busy: atlas leads a team of six, harbor talks to a session on another Mac, a message
    /// for quill waits for approval, and tide, quiet for most of an hour, folds away.
    public static func busy(_ accounts: Accounts, now: Date) -> AgentGraph {
        let atlas = session("atlas", accounts.work, status: "busy", cwd: workspaces + "/checkout-redesign")
        let team = ["designer", "backend", "frontend", "qa", "docs", "release"].map { agent($0, of: atlas, kind: .teammate) }
        let harbor = session("harbor", accounts.team, status: "busy", cwd: workspaces + "/fix-payment-webhooks")
        let probe = agent("probe", of: harbor, detail: "log reader")
        let quill = session("quill", accounts.personal, status: "waiting", waitingFor: "input needed", cwd: notes)
        let remote = AgentNode(id: "remote:ci-7f3a", name: "ci-runner", kind: .remote)
        let tide = session("tide", accounts.personal, status: nil, cwd: "/Users/demo/Code/tide-mobile")
        func member(_ name: String) -> AgentNode { team.first { $0.name == name }! }
        let lines = [
            Line(from: atlas, to: quill, ago: 2, text: "Can I borrow your sync fixtures for the checkout tests?",
                 delivery: .held),
            Line(from: remote, to: harbor, ago: 0.35, text: "Nightly: webhook suite green on staging."),
            Line(from: atlas, to: member("backend"), ago: 0.7, text: "Take task 4: idempotency keys on POST /orders.",
                 kind: .teammate),
            Line(from: member("frontend"), to: atlas, ago: 22, text: "Address step done; waiting on the ZIP+4 rule.",
                 kind: .teammate),
            Line(from: harbor, to: atlas, ago: 60, text: "Rerun done: 41 passed, 1 flaky."),
            Line(from: harbor, to: probe, ago: 130, text: "Pull the failed deliveries since Monday.", kind: .subagent),
            Line(from: member("designer"), to: atlas, ago: 180, text: "Error states drafted for the address step.",
                 kind: .teammate),
            Line(from: member("qa"), to: atlas, ago: 250, text: "Two flaky tests quarantined, tickets filed.",
                 kind: .teammate),
            Line(from: member("docs"), to: atlas, ago: 480, text: "Changelog entry drafted for the new checkout.",
                 kind: .teammate),
            Line(from: tide, to: quill, ago: 3_000, text: "Pushed the offline fixtures."),
        ]
        return graph(nodes: [atlas] + team + [harbor, probe, quill, remote, tide], lines: lines,
                     spawns: [(atlas, member("release"), 540, "Prepare the release notes")],
                     now: now)
    }
}
