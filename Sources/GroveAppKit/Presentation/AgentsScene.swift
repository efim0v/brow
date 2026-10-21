// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import Foundation
import GroveCore

// The Agents tab as data: who has talked in the last hour, which pairs are warm, what is in
// flight, what the RECENT list says — and where each pill goes. Pure, so the rules (what
// shows, what folds, what keeps its place) are tested without a view.

/// What the Agents tab draws at one moment.
public struct AgentsScene: Equatable {
    public struct Node: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let kind: AgentNode.Kind
        /// The session a subagent or a teammate belongs to.
        public let parent: String?
        /// The account it runs as (the observer's key), for its dot.
        public let account: String?
        /// A session's state while it runs; nil for an agent, a session elsewhere, one that
        /// has stopped.
        public let state: SessionState?
        /// What a subagent was asked to do; for a session, the project and the place in it.
        public let detail: String?
        /// When it last sent, received or was started.
        public let lastActive: Date?
        /// The node it is, as read: what "Go to session" needs.
        public let source: AgentNode
    }

    /// Two nodes that have talked in the last hour.
    public struct Edge: Equatable {
        public let a: String
        public let b: String
        /// Messages between them in the last ten minutes: the edge's width.
        public let count: Int
        /// 1 for a message just now, cooling to 0 over ten minutes.
        public let heat: Double
    }

    /// A message on its way: `progress` from its sender (0) to its receiver (1).
    public struct Pulse: Equatable {
        public let from: String
        public let to: String
        public let progress: Double
        /// Held for approval: it waits at the receiver's door, yellow.
        public let held: Bool
    }

    /// A line of RECENT: a message, or a spawn (dim).
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let from: String
        public let to: String
        public let text: String
        public let at: Date?
        public let delivery: AgentMessage.Delivery?
        public let kind: AgentMessage.Kind?
        public var isSpawn: Bool { kind == nil }
    }

    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var pulses: [Pulse] = []
    /// RECENT, newest first: the last ten minutes; while quiet, the last few of the hour.
    public var recent: [Row] = []
    /// Messages in the last ten minutes.
    public var messageCount = 0
    /// Messages in the last ten minutes each node sent or received.
    public var messagesByNode: [String: Int] = [:]
    /// No message for five minutes, but something in the hour: since when it has been quiet.
    public var quietFor: TimeInterval?
    /// A message moved in the last minute: the switch's dot, "● Live".
    public var isLive = false
    /// Nothing in the last hour.
    public var isEmpty: Bool { nodes.isEmpty }

    /// How long the picture remembers: an hour.
    public static let memory: TimeInterval = 3_600
    /// RECENT, the counts and the edges' heat: ten minutes.
    public static let window: TimeInterval = 600
    /// Without a message this long, the tab is quiet.
    public static let quietAfter: TimeInterval = 300
    /// "● Live": a message in the last minute.
    public static let liveFor: TimeInterval = 60
    /// How long a message takes to cross its edge.
    public static let travel: TimeInterval = 1
    /// How long its receiver rings once it has landed.
    public static let ring: TimeInterval = 0.6
    /// RECENT while quiet: the last few messages of the hour.
    public static let quietRows = 4
    /// What never left: no light travels for it, and RECENT says "not sent".
    public static let notSent: Set<AgentMessage.Delivery> = [.failed, .refused, .denied, .expired]

    public init() {}

    /// The scene for `graph` at `now`. `place` names the project and the place in it a
    /// folder is ("acme-shop › checkout-redesign"), where the host knows.
    public static func make(graph: AgentGraph, now: Date, place: ((String) -> String?)? = nil) -> AgentsScene {
        var scene = AgentsScene()
        func age(_ date: Date?) -> TimeInterval { date.map { now.timeIntervalSince($0) } ?? .infinity }
        let shown = graph.messages.filter { $0.kind != .teammateProtocol && age($0.at) <= memory }
        // A peer the reader could not name yet has no place in the picture, only in RECENT.
        let drawn = shown.filter { !$0.from.hasPrefix("name:") && !$0.to.hasPrefix("name:") }
        let spawns = graph.spawns.filter { age($0.at) <= memory }

        // Who took part: the ends of the messages and spawns of the hour, the parents of the
        // agents among them, and the agents still at work under a session that shows.
        var lastActive: [String: Date] = [:]
        func touch(_ id: String, _ date: Date?) {
            lastActive[id] = max(lastActive[id] ?? .distantPast, date ?? .distantPast)
        }
        for message in drawn { touch(message.from, message.at); touch(message.to, message.at) }
        for spawn in spawns { touch(spawn.parent, spawn.at); touch(spawn.child, spawn.at) }
        var included = Set(lastActive.keys)
        for id in included { if let parent = graph.nodes[id]?.parent { included.insert(parent) } }
        for node in graph.nodes.values where !node.finished {
            if let parent = node.parent, included.contains(parent) { included.insert(node.id) }
        }
        scene.nodes = included.compactMap { id -> Node? in
            guard let node = graph.nodes[id] else { return nil }
            var detail = node.detail
            if node.kind == .session, let cwd = node.cwd {
                detail = place?(cwd) ?? (cwd as NSString).lastPathComponent
            }
            return Node(id: id, name: node.name, kind: node.kind, parent: node.parent, account: node.account,
                        state: node.live.map { SessionState.of($0) }, detail: detail,
                        lastActive: lastActive[id].flatMap { $0 == .distantPast ? nil : $0 }, source: node)
        }.sorted { $0.id < $1.id }

        // The pairs, warm while they talk.
        struct Pair { let a: String; let b: String; var count = 0; var newest: Date? }
        var pairs: [String: Pair] = [:]
        func pairKey(_ x: String, _ y: String) -> (String, String, String) {
            let (a, b) = x < y ? (x, y) : (y, x)
            return (a, b, a + "\u{0}" + b)
        }
        for message in drawn {
            let (a, b, key) = pairKey(message.from, message.to)
            var pair = pairs[key] ?? Pair(a: a, b: b)
            if age(message.at) <= window { pair.count += 1 }
            if let at = message.at { pair.newest = max(pair.newest ?? at, at) }
            pairs[key] = pair
        }
        for spawn in spawns {
            let (a, b, key) = pairKey(spawn.parent, spawn.child)
            if pairs[key] == nil { pairs[key] = Pair(a: a, b: b, newest: spawn.at) }
        }
        scene.edges = pairs.values.map { pair in
            Edge(a: pair.a, b: pair.b, count: pair.count, heat: max(0, 1 - age(pair.newest) / window))
        }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }

        // In flight: a message within its second of travel, then landed (1) while its
        // receiver rings; held: waiting at the door.
        scene.pulses = drawn.compactMap { message in
            if message.delivery == .held, age(message.at) <= window {
                return Pulse(from: message.from, to: message.to, progress: 0.97, held: true)
            }
            let elapsed = age(message.at)
            guard elapsed >= 0, elapsed <= travel + ring, !Self.notSent.contains(message.delivery) else { return nil }
            return Pulse(from: message.from, to: message.to, progress: min(1, elapsed / travel), held: false)
        }

        let newest = shown.compactMap(\.at).max()
        let newestAny = ([newest] + spawns.map(\.at)).compactMap { $0 }.max()
        scene.isLive = age(newest) <= liveFor
        let quiet = !scene.nodes.isEmpty && age(newest) > quietAfter
        if quiet { scene.quietFor = newestAny.map { max(0, now.timeIntervalSince($0)) } }

        func row(_ message: AgentMessage) -> Row {
            Row(id: message.id, from: message.from, to: message.to,
                text: message.text.isEmpty ? (message.summary ?? "") : message.text,
                at: message.at, delivery: message.delivery, kind: message.kind)
        }
        func row(_ spawn: AgentSpawn) -> Row {
            Row(id: "spawn:" + spawn.parent + ">" + spawn.child, from: spawn.parent, to: spawn.child,
                text: spawn.description ?? "", at: spawn.at, delivery: nil, kind: nil)
        }
        let recentMessages = shown.filter { age($0.at) <= window }
        scene.messageCount = recentMessages.count
        for message in recentMessages {
            scene.messagesByNode[message.from, default: 0] += 1
            if message.to != message.from { scene.messagesByNode[message.to, default: 0] += 1 }
        }
        let rows: [Row]
        if quiet {
            rows = Array((shown.map(row) + spawns.map(row))
                .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }.prefix(quietRows))
        } else {
            rows = (recentMessages.map(row) + spawns.filter { age($0.at) <= window }.map(row))
                .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        }
        scene.recent = rows
        return scene
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// Something moves: a light on its way or a receiver ringing. A held light waits still.
    public var isMoving: Bool { pulses.contains { !$0.held } }

    /// Edges that touch `id`: the selection's "N links".
    public func links(of id: String) -> Int { edges.filter { $0.a == id || $0.b == id }.count }

    /// "6 min", "1 h": how long it has been quiet.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
}

extension AgentNode {
    /// A session's id, from its node id (`session:<account>:<id>`).
    public var sessionId: String? {
        guard kind == .session else { return nil }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "session" else { return nil }
        return String(parts[2])
    }
}

/// Where the pills go: sessions on one row, each with its subagents and teammates in a short
/// tree under it; sessions that talk joined by arcs above the row. Each family gets the width
/// its names need, up to `maxHeadWidth` and `maxChildWidth` (a longer name ends in "…"; the
/// pill's help and the picked session's strip say it whole), and never more than the row
/// has: nothing is drawn past its edge. The order is chosen when a session first shows —
/// from the busiest, adding at either end of the row the session most connected to that end,
/// so arcs rarely cross — and then kept (`order`): nothing moves while you watch; a session
/// that shows later takes its place beside the one it talks to most. When the row is full,
/// quiet sessions fold into "+N quiet" first, then the gaps close, then the least recently
/// active fold ("+N more"); never one a message is on its way to or held for, nor the
/// selected one — those few share the row's width instead.
public struct AgentsLayout {
    public struct Placed: Equatable {
        public let node: AgentsScene.Node
        public let rect: CGRect
    }

    public struct More: Equatable {
        public let rect: CGRect
        public let count: Int
    }

    public let placed: [String: Placed]
    /// The sessions on the row, left to right.
    public let heads: [String]
    /// The order to keep: every session the scene has, folded ones included.
    public let order: [String]
    public let size: CGSize
    /// Where the row of sessions starts: under the room the arcs need while two sessions or
    /// more are on it (an arc may join them any time); a lone session with its agents needs
    /// none, only the chip's room when sessions folded beside it.
    public let rowTop: CGFloat
    /// Sessions folded into the chip at the top right.
    public let folded: Int
    /// Whether every folded session was quiet: the chip says "+N quiet"; else "+N more".
    public let foldedAreQuiet: Bool
    public let quietChip: CGRect?
    /// "+N more" under a session whose agents do not all fit.
    public let more: [More]

    /// The room above the row for the arcs between sessions.
    public static let arcZone: CGFloat = 60
    public static let headHeight: CGFloat = 26
    public static let childHeight: CGFloat = 21
    public static let childGap: CGFloat = 6
    public static let maxChildren = 5
    /// Sessions on the row at most: more fold.
    public static let maxHeads = 4
    public static let gap: CGFloat = 12
    /// The widest a session's pill grows: about sixteen characters of its name.
    public static let maxHeadWidth: CGFloat = 168
    /// The widest an agent's pill grows.
    public static let maxChildWidth: CGFloat = 176

    static func textWidth(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    /// A session's pill: 10 pt each side, its 11 pt glyph and the name 6 pt apart, then its
    /// account's 6 pt dot; 2 pt to spare.
    static func headWidth(_ node: AgentsScene.Node) -> CGFloat {
        min(maxHeadWidth, textWidth(node.name, 12, .semibold) + 39 + (node.account != nil ? 12 : 0))
    }
    /// An agent's: 8 pt each side, its glyph and the name 5 pt apart.
    static func childWidth(_ node: AgentsScene.Node) -> CGFloat {
        min(maxChildWidth, textWidth(node.name, 11, .medium) + 33)
    }

    public init(scene: AgentsScene, width: CGFloat, order previous: [String] = [], selected: String? = nil) {
        let headList = scene.nodes.filter { node in node.parent.map { scene.node($0) == nil } ?? true }
        let ids = headList.map(\.id)
        let headSet = Set(ids)
        var heads: [String: AgentsScene.Node] = [:]
        for head in headList { heads[head.id] = head }
        var childrenOf: [String: [AgentsScene.Node]] = [:]
        for node in scene.nodes where !headSet.contains(node.id) {
            if let parent = node.parent { childrenOf[parent, default: []].append(node) }
        }
        for (key, list) in childrenOf {
            // The most recently active first: what folds into "+N more" has been quiet longest.
            childrenOf[key] = list.sorted {
                ($0.lastActive ?? .distantPast, $1.name) > ($1.lastActive ?? .distantPast, $0.name)
            }
        }
        func children(_ id: String) -> [AgentsScene.Node] { childrenOf[id] ?? [] }
        func weight(_ a: String, _ b: String) -> Int {
            scene.edges.filter { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }.map(\.count).reduce(0, +)
        }
        func degree(_ id: String) -> Int { ids.map { weight(id, $0) }.reduce(0, +) }
        func isQuiet(_ id: String) -> Bool { degree(id) == 0 && children(id).isEmpty }

        var order = previous.filter { headSet.contains($0) }
        let fresh = ids.filter { !order.contains($0) }
        if order.isEmpty {
            var remaining = fresh
            if var start = remaining.first {
                for id in remaining where degree(id) > degree(start) { start = id }
                order = [start]
                remaining.removeAll { $0 == start }
                while true {
                    var best: (id: String, left: Bool, w: Int)?
                    for id in remaining {
                        let left = weight(id, order.first!), right = weight(id, order.last!)
                        let w = max(left, right)
                        if w > 0, best == nil || w > best!.w { best = (id, left > right, w) }
                    }
                    guard let pick = best else { break }
                    if pick.left { order.insert(pick.id, at: 0) } else { order.append(pick.id) }
                    remaining.removeAll { $0 == pick.id }
                }
                order += remaining.filter { !isQuiet($0) } + remaining.filter(isQuiet)
            }
        } else {
            for id in fresh.sorted(by: { (degree($0), $1) > (degree($1), $0) }) {
                let partners = order.enumerated().map { (index: $0.offset, w: weight(id, $0.element)) }.filter { $0.w > 0 }
                if let best = partners.max(by: { $0.w < $1.w }) {
                    // Beside it, on its outer side.
                    let middle = Double(order.count - 1) / 2
                    order.insert(id, at: Double(best.index) < middle ? best.index : best.index + 1)
                } else {
                    order.append(id)
                }
            }
        }
        self.order = order

        func natural(_ id: String) -> CGFloat {
            guard let head = heads[id] else { return 0 }
            let kids = children(id)
            let shown = kids.prefix(Self.maxChildren)
            var kidWidth = shown.map(Self.childWidth).max() ?? 0
            if kids.count > shown.count {
                kidWidth = max(kidWidth, Self.textWidth("+\(kids.count - shown.count) more", 10.5, .medium) + 16)
            }
            return max(Self.headWidth(head), kids.isEmpty ? 0 : 25 + kidWidth)
        }
        // The most a family may take: set below when the sessions that cannot fold still
        // do not fit side by side.
        var room = CGFloat.infinity
        func need(_ id: String) -> CGFloat {
            min(room, natural(id))
        }
        func activity(_ id: String) -> Date {
            ([heads[id]?.lastActive] + children(id).map(\.lastActive)).compactMap { $0 }.max() ?? .distantPast
        }
        let ends = scene.pulses.flatMap { [$0.from, $0.to] } + [selected].compactMap { $0 }
        let protected = Set(ends + ends.compactMap { scene.node($0)?.parent })
        var shown = order
        var folded = 0
        var foldedAreQuiet = true
        var gap = Self.gap
        func total(_ list: [String]) -> CGFloat {
            list.map(need).reduce(0, +) + gap * CGFloat(max(0, list.count - 1))
        }
        while shown.count > 1, total(shown) > width || shown.count > Self.maxHeads,
              let quiet = shown.last(where: { isQuiet($0) && !protected.contains($0) }) {
            shown.removeAll { $0 == quiet }
            folded += 1
        }
        if total(shown) > width { gap = 8 }
        while shown.count > 1, total(shown) > width || shown.count > Self.maxHeads,
              let victim = shown.filter({ !protected.contains($0) }).min(by: { activity($0) < activity($1) }) {
            shown.removeAll { $0 == victim }
            folded += 1
            if !isQuiet(victim) { foldedAreQuiet = false }
        }
        // What cannot fold shares the row: each family gets an equal part, its names cut short.
        if total(shown) > width {
            let gaps = gap * CGFloat(max(0, shown.count - 1))
            room = max(40, (width - gaps) / CGFloat(max(1, shown.count)))
        }
        self.folded = folded
        self.foldedAreQuiet = foldedAreQuiet
        self.heads = shown
        let rowTop: CGFloat = shown.count > 1 ? Self.arcZone : (folded > 0 ? 26 : 6)
        self.rowTop = rowTop

        let used = total(shown)
        let extra = max(0, width - used) / CGFloat(max(1, shown.count))
        var placed: [String: Placed] = [:]
        var more: [More] = []
        var x: CGFloat = 0
        var bottom = rowTop + Self.headHeight
        for id in shown {
            guard let head = heads[id] else { continue }
            let block = need(id)
            let slot = block + extra
            let minX = x + (slot - block) / 2
            let headRect = CGRect(x: minX, y: rowTop, width: min(block, Self.headWidth(head)),
                                  height: Self.headHeight)
            placed[id] = Placed(node: head, rect: headRect)
            let kids = children(id)
            var y = headRect.maxY + 10
            for child in kids.prefix(Self.maxChildren) {
                placed[child.id] = Placed(node: child, rect: CGRect(x: minX + 25, y: y,
                                                                    width: min(max(0, block - 25), Self.childWidth(child)),
                                                                    height: Self.childHeight))
                y += Self.childHeight + Self.childGap
            }
            if kids.count > Self.maxChildren {
                more.append(More(rect: CGRect(x: minX + 25, y: y - 2, width: 80, height: 16),
                                 count: kids.count - Self.maxChildren))
                y += 16
            }
            bottom = max(bottom, y)
            x += slot + gap
        }
        quietChip = folded > 0 ? CGRect(x: width - 76, y: 0, width: 70, height: 18) : nil
        self.placed = placed
        self.more = more
        size = CGSize(width: width, height: bottom + 4)
    }

    /// Sessions on the row, and agents drawn under them: what the footer counts.
    public var drawnSessions: Int { heads.count }
    public var drawnAgents: Int { placed.count - heads.count }

    /// Whether `id` is on the row.
    public func isHead(_ id: String) -> Bool { heads.contains(id) }

    /// The way a message travels between two placed nodes: an arc above the row between two
    /// sessions; the trunk and its elbow between a session and one of its agents.
    public func path(from a: String, to b: String) -> CGPath? {
        guard let pa = placed[a], let pb = placed[b] else { return nil }
        let path = CGMutablePath()
        let aIsHead = isHead(a), bIsHead = isHead(b)
        if aIsHead && bIsHead {
            let start = CGPoint(x: pa.rect.midX, y: pa.rect.minY)
            let end = CGPoint(x: pb.rect.midX, y: pb.rect.minY)
            let lift = min(Self.arcZone - 24, 14 + abs(end.x - start.x) * 0.12)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y - lift * 1.33),
                          control2: CGPoint(x: end.x, y: end.y - lift * 1.33))
            return path
        }
        guard aIsHead != bIsHead else { return nil }
        let (parent, child, down) = aIsHead ? (pa, pb, true) : (pb, pa, false)
        guard child.node.parent == parent.node.id else { return nil }
        let trunkX = parent.rect.minX + 13
        let cornerY = child.rect.midY
        let end = CGPoint(x: child.rect.minX, y: child.rect.midY)
        if down {
            path.move(to: CGPoint(x: trunkX, y: parent.rect.maxY))
            path.addLine(to: CGPoint(x: trunkX, y: cornerY - 6))
            path.addQuadCurve(to: CGPoint(x: trunkX + 6, y: cornerY), control: CGPoint(x: trunkX, y: cornerY))
            path.addLine(to: end)
        } else {
            path.move(to: end)
            path.addLine(to: CGPoint(x: trunkX + 6, y: cornerY))
            path.addQuadCurve(to: CGPoint(x: trunkX, y: cornerY - 6), control: CGPoint(x: trunkX, y: cornerY))
            path.addLine(to: CGPoint(x: trunkX, y: parent.rect.maxY))
        }
        return path
    }
}
