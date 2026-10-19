// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import GroveAppKit
import GroveCore

/// Made-up agents: names, folders and lines are invented; times count back from `now`.
enum MadeUpAgents {
    static let now = Date(timeIntervalSince1970: 1_792_400_000)

    static func session(_ name: String, account: String = "acct-work", status: String? = "busy",
                        waitingFor: String? = nil) -> AgentNode {
        let cwd = "/Users/demo/Code/" + name
        return AgentNode(id: "session:\(account):s-\(name)", name: name, kind: .session, account: account,
                         live: status.map { LiveProcess(pid: 0, sessionId: "s-" + name, cwd: cwd, status: $0,
                                                        accountName: account, waitingFor: waitingFor) },
                         cwd: cwd)
    }

    static func agent(_ name: String, of parent: AgentNode, kind: AgentNode.Kind = .subagent,
                      finished: Bool = false) -> AgentNode {
        AgentNode(id: "agent:\(parent.account ?? ""):\(parent.sessionId ?? ""):\(name)", name: name, kind: kind,
                  parent: parent.id, account: parent.account, detail: "a made-up task", finished: finished)
    }

    static func message(_ from: AgentNode, _ to: AgentNode, ago: TimeInterval, _ text: String = "a made-up line",
                        delivery: AgentMessage.Delivery = .delivered, kind: AgentMessage.Kind = .crossSession) -> AgentMessage {
        AgentMessage(id: UUID().uuidString, from: from.id, to: to.id, kind: kind, delivery: delivery,
                     at: now.addingTimeInterval(-ago), text: text)
    }

    static func graph(_ nodes: [AgentNode], _ messages: [AgentMessage], spawns: [AgentSpawn] = []) -> AgentGraph {
        var byId: [String: AgentNode] = [:]
        for node in nodes { byId[node.id] = node }
        return AgentGraph(nodes: byId, messages: messages.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) },
                          spawns: spawns)
    }

    static func scene(_ nodes: [AgentNode], _ messages: [AgentMessage], spawns: [AgentSpawn] = [],
                      at offset: TimeInterval = 0) -> AgentsScene {
        AgentsScene.make(graph: graph(nodes, messages, spawns: spawns), now: now.addingTimeInterval(offset))
    }
}

/// What the Agents tab shows of what was read: who took part, how warm each pair is, what is
/// in flight, RECENT, and when it is quiet.
final class AgentsSceneTests: XCTestCase {
    private let atlas = MadeUpAgents.session("atlas")
    private let harbor = MadeUpAgents.session("harbor", account: "acct-team", status: "waiting",
                                              waitingFor: "permission prompt")
    private let quill = MadeUpAgents.session("quill", status: "idle")
    private let tide = MadeUpAgents.session("tide", status: nil)

    /// The ends of the hour's messages and spawns, with the parents of the agents among them
    /// and the agents still at work under them; not a session that only talked earlier.
    func testWhoTookPartInTheLastHour() {
        let lumen = MadeUpAgents.agent("lumen", of: atlas)
        let idle = MadeUpAgents.agent("idle", of: atlas)
        let done = MadeUpAgents.agent("done", of: atlas, finished: true)
        let scene = MadeUpAgents.scene([atlas, harbor, quill, tide, lumen, idle, done], [
            MadeUpAgents.message(lumen, atlas, ago: 30),
            MadeUpAgents.message(atlas, harbor, ago: 120),
            MadeUpAgents.message(quill, tide, ago: 2 * 3_600),
        ])
        XCTAssertEqual(Set(scene.nodes.map(\.name)), ["atlas", "harbor", "lumen", "idle"],
                       "an agent at work shows under its session; one that finished, and an earlier pair, do not")
        XCTAssertEqual(scene.node(harbor.id)?.state, .needsPermission)
        XCTAssertEqual(scene.node(atlas.id)?.state, .working)
        XCTAssertNil(scene.node(lumen.id)?.state)
    }

    /// An edge counts the pair's last ten minutes and cools from 1 to 0 over them; a spawn
    /// alone draws a cold edge.
    func testEdgesCountTheLastTenMinutesAndCool() throws {
        let scout = MadeUpAgents.agent("scout", of: atlas)
        let scene = MadeUpAgents.scene([atlas, harbor, quill, scout], [
            MadeUpAgents.message(atlas, harbor, ago: 0),
            MadeUpAgents.message(harbor, atlas, ago: 300),
            MadeUpAgents.message(atlas, harbor, ago: 900),
            MadeUpAgents.message(quill, atlas, ago: 2_400),
        ], spawns: [AgentSpawn(parent: atlas.id, child: scout.id, kind: .subagent,
                               at: MadeUpAgents.now.addingTimeInterval(-60), description: "Map the helpers")])
        func edge(_ a: AgentNode, _ b: AgentNode) throws -> AgentsScene.Edge {
            try XCTUnwrap(scene.edges.first { Set([$0.a, $0.b]) == Set([a.id, b.id]) })
        }
        XCTAssertEqual(try edge(atlas, harbor).count, 2)
        XCTAssertEqual(try edge(atlas, harbor).heat, 1, accuracy: 0.001)
        XCTAssertEqual(try edge(quill, atlas).count, 0)
        XCTAssertEqual(try edge(quill, atlas).heat, 0, "cold after ten minutes")
        XCTAssertEqual(try edge(atlas, scout).count, 0)
        XCTAssertEqual(try edge(atlas, scout).heat, 0.9, accuracy: 0.001)
        XCTAssertEqual(scene.links(of: atlas.id), 3)
        XCTAssertEqual(scene.messageCount, 2)
        XCTAssertEqual(scene.messagesByNode[atlas.id], 2)
        XCTAssertEqual(scene.messagesByNode[quill.id], nil)
    }

    /// A light crosses its edge in a second, its receiver rings a little longer; a held
    /// message waits at the door; one that was not sent draws nothing.
    func testALightTravelsForASecondAndAHeldOneWaits() {
        let messages = [
            MadeUpAgents.message(atlas, harbor, ago: 0.5),
            MadeUpAgents.message(harbor, atlas, ago: 1.3),
            MadeUpAgents.message(atlas, quill, ago: 3, delivery: .held),
            MadeUpAgents.message(quill, atlas, ago: 0.2, delivery: .failed),
            MadeUpAgents.message(atlas, quill, ago: 5),
        ]
        let scene = MadeUpAgents.scene([atlas, harbor, quill], messages)
        XCTAssertEqual(scene.pulses.count, 3)
        let travelling = scene.pulses.first { $0.from == atlas.id && $0.to == harbor.id }
        XCTAssertEqual(travelling?.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(scene.pulses.first { $0.from == harbor.id }?.progress, 1, "landed: its receiver rings")
        let held = scene.pulses.first { $0.held }
        XCTAssertEqual(held?.to, quill.id)
        XCTAssertTrue(scene.isMoving)
        XCTAssertFalse(MadeUpAgents.scene([atlas, harbor, quill], messages, at: 2).isMoving,
                       "two seconds on, only the held light is left, and it does not move")
    }

    /// Live for a minute after a message; quiet after five, with the last few of the hour
    /// listed; RECENT is otherwise the last ten minutes, spawns among them.
    func testLiveThenQuiet() {
        let lumen = MadeUpAgents.agent("lumen", of: atlas)
        let messages = [
            MadeUpAgents.message(atlas, harbor, ago: 30, "newest"),
            MadeUpAgents.message(harbor, atlas, ago: 200),
            MadeUpAgents.message(atlas, harbor, ago: 500),
            MadeUpAgents.message(harbor, atlas, ago: 700),
            MadeUpAgents.message(atlas, harbor, ago: 1_500),
            MadeUpAgents.message(harbor, atlas, ago: 2_000),
        ]
        let spawns = [AgentSpawn(parent: atlas.id, child: lumen.id, kind: .subagent,
                                 at: MadeUpAgents.now.addingTimeInterval(-100), description: "Run the tests")]
        let live = MadeUpAgents.scene([atlas, harbor, lumen], messages, spawns: spawns)
        XCTAssertTrue(live.isLive)
        XCTAssertNil(live.quietFor)
        XCTAssertEqual(live.recent.map(\.isSpawn), [false, true, false, false])
        XCTAssertEqual(live.recent.first?.text, "newest")

        let later = MadeUpAgents.scene([atlas, harbor, lumen], messages, spawns: spawns, at: 6 * 60)
        XCTAssertFalse(later.isLive)
        XCTAssertEqual(later.quietFor ?? 0, 6 * 60 + 30, accuracy: 0.001)
        XCTAssertEqual(later.recent.count, AgentsScene.quietRows)
        XCTAssertEqual(later.recent.first?.text, "newest")
        XCTAssertEqual(AgentsScene.duration(later.quietFor ?? 0), "6 min")

        XCTAssertTrue(MadeUpAgents.scene([atlas, harbor], messages, at: 2 * 3_600).isEmpty,
                      "nothing in the last hour: the empty state")
    }

    /// A message to a name the reader could not place is listed, not drawn.
    func testAPeerKnownOnlyByNameIsListedNotDrawn() {
        var message = MadeUpAgents.message(atlas, harbor, ago: 10, "anyone there?")
        message = AgentMessage(id: message.id, from: atlas.id, to: "name:nobody-here", kind: .crossSession,
                               delivery: .failed, at: message.at, text: message.text)
        let scene = MadeUpAgents.scene([atlas, harbor], [message, MadeUpAgents.message(atlas, harbor, ago: 20)])
        XCTAssertNil(scene.node("name:nobody-here"))
        XCTAssertFalse(scene.edges.contains { $0.b == "name:nobody-here" || $0.a == "name:nobody-here" })
        XCTAssertEqual(scene.recent.first?.to, "name:nobody-here")
        XCTAssertEqual(scene.recent.first?.delivery, .failed)
    }

    func testASessionsIdComesFromItsNodeId() {
        XCTAssertEqual(atlas.sessionId, "s-atlas")
        XCTAssertNil(MadeUpAgents.agent("lumen", of: atlas).sessionId)
    }

    /// A session's line under its name: the project and the place in it, where the host
    /// knows one; else its folder's name.
    func testASessionsPlace() {
        let scene = AgentsScene.make(graph: MadeUpAgents.graph([atlas, harbor], [MadeUpAgents.message(atlas, harbor, ago: 5)]),
                                     now: MadeUpAgents.now,
                                     place: { $0.hasSuffix("/atlas") ? "acme-shop › checkout-redesign" : nil })
        XCTAssertEqual(scene.node(atlas.id)?.detail, "acme-shop › checkout-redesign")
        XCTAssertEqual(scene.node(harbor.id)?.detail, "harbor")
    }
}

/// Where the pills go: the order chosen once and kept, what folds when the row is full and
/// what never does, the five agents a session shows at most, and what the footer counts.
final class AgentsLayoutTests: XCTestCase {
    private func sessions(_ names: [String]) -> [AgentNode] { names.map { MadeUpAgents.session($0) } }

    /// The busiest session starts the row; the others join at the end they talk to most;
    /// sessions with nothing to say come last.
    func testTheBusiestStartsTheRowAndItsPartnersSitBeside() {
        let s = sessions(["a", "b", "c", "d"])
        var messages: [AgentMessage] = []
        for _ in 0..<5 { messages.append(MadeUpAgents.message(s[0], s[1], ago: 30)) }
        for _ in 0..<3 { messages.append(MadeUpAgents.message(s[1], s[2], ago: 60)) }
        messages.append(MadeUpAgents.message(s[3], s[0], ago: 1_800))   // an hour's, cold: d is quiet
        let layout = AgentsLayout(scene: MadeUpAgents.scene(s, messages), width: 432)
        XCTAssertEqual(layout.order.map { String($0.suffix(1)) }, ["c", "b", "a", "d"])
        XCTAssertEqual(layout.heads, layout.order)
        XCTAssertEqual(layout.folded, 0)
    }

    /// What was placed stays where it is; a session that shows later sits beside the one it
    /// talks to most.
    func testTheOrderIsKept() {
        let s = sessions(["a", "b", "c", "e"])
        let kept = [s[2].id, s[0].id, s[1].id]
        let messages = [MadeUpAgents.message(s[0], s[1], ago: 30), MadeUpAgents.message(s[1], s[2], ago: 30),
                        MadeUpAgents.message(s[3], s[2], ago: 10), MadeUpAgents.message(s[3], s[2], ago: 12)]
        let layout = AgentsLayout(scene: MadeUpAgents.scene(s, messages), width: 432, order: kept)
        XCTAssertEqual(layout.order, [s[3].id, s[2].id, s[0].id, s[1].id], "beside c, on the outer side")
        let again = AgentsLayout(scene: MadeUpAgents.scene(s, messages + [MadeUpAgents.message(s[0], s[3], ago: 1)]),
                                 width: 432, order: layout.order)
        XCTAssertEqual(again.order, layout.order, "nothing moves while you watch")
    }

    /// Four sessions on the row at most: quiet ones fold into "+N quiet" first, then the
    /// least recently active — never one a message is on its way to, nor the selected one.
    func testWhatFoldsAndWhatNeverDoes() {
        let s = sessions(["a", "b", "c", "d", "e", "f"])
        var messages = [MadeUpAgents.message(s[0], s[1], ago: 10), MadeUpAgents.message(s[1], s[2], ago: 100),
                        MadeUpAgents.message(s[2], s[3], ago: 200), MadeUpAgents.message(s[3], s[4], ago: 400)]
        messages.append(MadeUpAgents.message(s[5], s[0], ago: 3_000))   // f: quiet
        let layout = AgentsLayout(scene: MadeUpAgents.scene(s, messages), width: 432)
        XCTAssertEqual(layout.heads.count, AgentsLayout.maxHeads)
        XCTAssertEqual(layout.folded, 2)
        XCTAssertFalse(layout.heads.contains(s[5].id), "the quiet one folds first")
        XCTAssertFalse(layout.heads.contains(s[4].id), "then the least recently active")
        XCTAssertNotNil(layout.quietChip)

        // A message on its way to e keeps it, and its sender; d folds instead.
        let inFlight = messages + [MadeUpAgents.message(s[4], s[3], ago: 0.3)]
        let protected = AgentsLayout(scene: MadeUpAgents.scene(s, inFlight), width: 432)
        XCTAssertTrue(protected.heads.contains(s[4].id))
        XCTAssertTrue(protected.heads.contains(s[3].id))

        let selected = AgentsLayout(scene: MadeUpAgents.scene(s, messages), width: 432, selected: s[5].id)
        XCTAssertTrue(selected.heads.contains(s[5].id), "the picked one stays")
    }

    /// A session shows five of its agents, the most recently active, and "+N more".
    func testFiveAgentsAtMostUnderASession() throws {
        let lead = MadeUpAgents.session("lead")
        let team = (1...7).map { MadeUpAgents.agent("member\($0)", of: lead, kind: .teammate) }
        let messages = team.enumerated().map { index, member in
            MadeUpAgents.message(member, lead, ago: TimeInterval(10 + index * 10), kind: .teammate)
        }
        let layout = AgentsLayout(scene: MadeUpAgents.scene([lead] + team, messages), width: 432)
        XCTAssertEqual(layout.drawnSessions, 1)
        XCTAssertEqual(layout.drawnAgents, AgentsLayout.maxChildren)
        XCTAssertEqual(layout.more.map(\.count), [2])
        XCTAssertNotNil(layout.placed[team[0].id])
        XCTAssertNil(layout.placed[team[6].id], "the longest quiet is the one left out")
        let first = try XCTUnwrap(layout.placed[team[0].id]?.rect)
        let second = try XCTUnwrap(layout.placed[team[1].id]?.rect)
        XCTAssertEqual(second.minY - first.minY, AgentsLayout.childHeight + AgentsLayout.childGap)
    }

    /// Nothing is drawn past the row's width while it fits, and the paths join what they say.
    func testTheRowFitsAndThePathsJoinTheirEnds() throws {
        let s = sessions(["atlas", "harbor", "quill"])
        let lumen = MadeUpAgents.agent("lumen", of: s[0])
        let scene = MadeUpAgents.scene(s + [lumen], [MadeUpAgents.message(s[0], s[1], ago: 3),
                                                     MadeUpAgents.message(s[2], s[0], ago: 9),
                                                     MadeUpAgents.message(lumen, s[0], ago: 4)])
        let layout = AgentsLayout(scene: scene, width: 432)
        for placed in layout.placed.values {
            XCTAssertGreaterThanOrEqual(placed.rect.minX, 0)
            XCTAssertLessThanOrEqual(placed.rect.maxX, 432)
        }
        XCTAssertNotNil(layout.path(from: s[0].id, to: s[1].id), "an arc between two sessions")
        XCTAssertNotNil(layout.path(from: lumen.id, to: s[0].id), "the trunk between a session and its agent")
        XCTAssertNil(layout.path(from: lumen.id, to: s[1].id), "no way from an agent to another session")
        let arc = try XCTUnwrap(layout.path(from: s[0].id, to: s[1].id))
        XCTAssertLessThan(arc.boundingBox.minY, AgentsLayout.arcZone, "the arcs run above the row")
    }
}
