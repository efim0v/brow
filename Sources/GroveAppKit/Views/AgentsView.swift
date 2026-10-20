// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// The Agents tab: who talks to whom among the Claude Code agents on this Mac, live.
///
/// Sessions are pills on one row, joined by arcs above it when they message each other;
/// each session's subagents and teammates hang under it in a short tree. A message is a
/// small cream light that runs along its edge from sender to receiver in about a second,
/// rings the receiver as it lands and leaves the edge warm; edges cool to grey over ten
/// minutes. One held for approval waits at the receiver's door, yellow. With Reduce Motion
/// nothing travels: the edge glows, then cools. Under it, RECENT: the last ten minutes,
/// newest first. A click on a pill picks it: the others dim, RECENT narrows to it, and the
/// way to the session shows.
public struct AgentsView: View {
    @ObservedObject var observer: AgentsObserver
    let width: CGFloat
    /// Go to a session: the host's (its cmux workspace or terminal).
    var goToSession: (AgentNode) -> Void = { _ in }
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderReduceMotion) private var renderReduceMotion
    @Environment(\.groveAccent) private var accent

    public init(observer: AgentsObserver, width: CGFloat, goToSession: @escaping (AgentNode) -> Void = { _ in }) {
        _observer = ObservedObject(wrappedValue: observer)
        self.width = width
        self.goToSession = goToSession
    }

    public var body: some View {
        if isSnapshotRender {
            content(now: observer.now())
        } else {
            // 30 frames a second while a light moves; else a still picture, its ages kept
            // current every few seconds. The time is the observer's: what it reads by.
            TimelineView(.animation(minimumInterval: animates ? 1.0 / 30 : 5)) { _ in
                content(now: observer.now())
            }
        }
    }

    /// A light on its way, or a receiver ringing; else the picture is still, redrawn when
    /// the reader has something new. With Reduce Motion nothing travels.
    private var animates: Bool { observer.scene.isMoving && !reduceMotion && !renderReduceMotion }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let scene = observer.scene(at: now)
        if scene.isEmpty {
            AgentsEmptyView()
        } else {
            let layout = AgentsLayout(scene: scene, width: width, order: observer.order, selected: observer.selected)
            FadingScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AgentsDiagram(observer: observer, scene: scene, layout: layout,
                                  reduceMotion: reduceMotion || renderReduceMotion)
                    if let selected = observer.selected, let node = scene.node(selected) {
                        selectionStrip(node)
                    }
                    AgentsRecent(observer: observer, scene: scene, now: now)
                }
                .padding(.bottom, 10)
            }
            .onChange(of: layout.order) { _, order in
                if observer.order != order { observer.order = order }
            }
            .onAppear { if observer.order != layout.order { observer.order = layout.order } }
        }
    }

    /// The picked node: where it runs, as whom, and the way to it.
    private func selectionStrip(_ node: AgentsScene.Node) -> some View {
        let account = observer.account(key: node.account)
        return HStack(spacing: 8) {
            if let state = node.state { SessionStatusGlyph(status: state, size: 12) }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let state = node.state {
                        Text(state.word).foregroundStyle(state.needsYou ? SessionColors.needsYou : Color.white.opacity(0.7))
                    } else if node.kind == .remote {
                        Text("on another Mac")
                    }
                    if let detail = node.detail { Text("· " + detail).lineLimit(1) }
                    if let account {
                        Text("·")
                        if let dot = account.dot { Circle().fill(dot).frame(width: 5, height: 5) }
                        Text(account.name).lineLimit(1)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer(minLength: 6)
            if node.kind == .session, node.state?.isLive == true {
                Button { goToSession(node.source) } label: {
                    Text("Go to session")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(SessionColors.ink)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
    }
}

/// The diagram: arcs and trees on a Canvas, the pills over them.
struct AgentsDiagram: View {
    @ObservedObject var observer: AgentsObserver
    let scene: AgentsScene
    let layout: AgentsLayout
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    @Environment(\.groveAccent) private var accent

    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }

    private func dimmed(_ id: String) -> Bool {
        guard let selected = observer.selected, id != selected else { return false }
        return !scene.edges.contains { ($0.a == selected && $0.b == id) || ($0.b == selected && $0.a == id) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawTrees(context)
                drawEdges(context)
                drawPulses(context)
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .accessibilityHidden(true)
            ForEach(Array(layout.placed.values).sorted { $0.node.id < $1.node.id }, id: \.node.id) { placed in
                pill(placed)
                    .frame(width: placed.rect.width, height: placed.rect.height)
                    .offset(x: placed.rect.minX, y: placed.rect.minY)
                    .opacity(dimmed(placed.node.id) ? 0.32 : 1)
            }
            ForEach(Array(layout.more.enumerated()), id: \.offset) { _, item in
                Text("+\(item.count) more")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.36))
                    .frame(height: item.rect.height)
                    .offset(x: item.rect.minX + 8, y: item.rect.minY)
            }
            if let chip = layout.quietChip {
                Text("+\(layout.folded) \(layout.foldedAreQuiet ? "quiet" : "more")")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.36))
                    .frame(width: chip.width, height: chip.height)
                    .background(Capsule().strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                    .offset(x: chip.minX, y: chip.minY)
                    .help(layout.foldedAreQuiet ? "Sessions with nothing to say, folded to make room"
                          : "Sessions folded to make room: the ones quiet the longest. RECENT lists what they said.")
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents: who talks to whom")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Each session's family tree, quiet grey: there whether they talk or not.
    private func drawTrees(_ context: GraphicsContext) {
        for headID in layout.heads {
            guard let head = layout.placed[headID] else { continue }
            let children = layout.placed.values.filter { $0.node.parent == headID && !layout.heads.contains($0.node.id) }
            guard let last = children.max(by: { $0.rect.midY < $1.rect.midY }) else { continue }
            let x = head.rect.minX + 13
            var trunk = Path()
            trunk.move(to: CGPoint(x: x, y: head.rect.maxY))
            trunk.addLine(to: CGPoint(x: x, y: last.rect.midY - 6))
            trunk.addQuadCurve(to: CGPoint(x: x + 6, y: last.rect.midY), control: CGPoint(x: x, y: last.rect.midY))
            trunk.addLine(to: CGPoint(x: last.rect.minX, y: last.rect.midY))
            for child in children where child.node.id != last.node.id {
                trunk.move(to: CGPoint(x: x, y: child.rect.midY - 6))
                trunk.addQuadCurve(to: CGPoint(x: x + 6, y: child.rect.midY), control: CGPoint(x: x, y: child.rect.midY))
                trunk.addLine(to: CGPoint(x: child.rect.minX, y: child.rect.midY))
            }
            let dim = observer.selected != nil && dimmed(headID)
            context.stroke(trunk, with: .color(Color.white.opacity(dim ? 0.06 : (increased ? 0.35 : 0.16))), lineWidth: 1.2)
        }
    }

    /// The pairs that talked: cream while warm, grey once cool; wider the more they said.
    private func drawEdges(_ context: GraphicsContext) {
        for edge in scene.edges {
            guard let cgPath = layout.path(from: edge.a, to: edge.b) else { continue }
            let path = Path(cgPath)
            let involves = observer.selected.map { edge.a == $0 || edge.b == $0 } ?? true
            let width = 1.1 + min(2.2, log2(Double(max(1, edge.count))) * 0.7)
            let base = increased ? 0.4 : 0.18
            let opacity = involves ? base + (0.75 - base) * edge.heat : 0.06
            let color = edge.heat > 0.05 ? accent : Color.white
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if reduceMotion, edge.heat > 0.8, involves {
                // Reduce Motion: a message shows as its edge brightening, then cooling.
                var glow = context
                glow.addFilter(.blur(radius: 3))
                glow.stroke(path, with: .color(accent.opacity(0.55)),
                            style: StrokeStyle(lineWidth: width + 3, lineCap: .round))
            }
        }
    }

    /// The lights in flight: a short tail, then the light with its glow; a held one yellow,
    /// waiting at the door.
    private func drawPulses(_ context: GraphicsContext) {
        // With Reduce Motion no light travels; a held one, which waits still, stays.
        for pulse in scene.pulses where pulse.held || (pulse.progress < 1 && !reduceMotion) {
            guard let cgPath = layout.path(from: pulse.from, to: pulse.to) else { continue }
            let path = Path(cgPath)
            let progress = CGFloat(max(0.001, pulse.progress))
            let point = path.trimmedPath(from: 0, to: progress).currentPoint ?? .zero
            let tailStart = max(0, progress - 0.16)
            let tail = path.trimmedPath(from: tailStart, to: progress)
            let origin = path.trimmedPath(from: 0, to: max(0.001, tailStart)).currentPoint ?? point
            let light = pulse.held ? SessionColors.needsYou : accent
            context.stroke(tail, with: .linearGradient(Gradient(colors: [light.opacity(0), light.opacity(0.9)]),
                                                       startPoint: origin, endPoint: point),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            var glow = context
            glow.addFilter(.blur(radius: 5))
            glow.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)),
                      with: .color(light.opacity(0.85)))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)),
                         with: .color(pulse.held ? SessionColors.needsYou : Color.white))
        }
    }

    @ViewBuilder
    private func pill(_ placed: AgentsLayout.Placed) -> some View {
        let node = placed.node
        let selected = observer.selected == node.id
        // A message landing rings its receiver; one held for approval does not, it waits.
        let receiving = scene.pulses.contains { $0.to == node.id && $0.progress > 0.9 && !$0.held }
        let account = observer.account(key: node.account)
        let isHead = layout.heads.contains(node.id)
        Button { observer.selected = selected ? nil : node.id } label: {
            Group {
                if isHead {
                    HStack(spacing: 6) {
                        if node.kind == .remote {
                            Image(systemName: "globe").font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.7))
                        } else if let state = node.state {
                            SessionStatusGlyph(status: state, size: 11)
                        } else {
                            SessionStatusGlyph(status: .closed, size: 11)
                        }
                        Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let dot = account?.dot {
                            Circle().fill(dot).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : 0.09)))
                    .overlay {
                        if node.kind == .remote {
                            Capsule().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                        } else {
                            Capsule().strokeBorder(selected || receiving ? accent.opacity(0.9)
                                                   : Color.white.opacity(increased ? 0.4 : 0.14),
                                                   lineWidth: selected ? 1.5 : 1)
                        }
                    }
                    .shadow(color: receiving ? accent.opacity(0.55) : .clear, radius: 8)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: node.kind == .teammate ? "person.fill" : "sparkle")
                            .font(.system(size: 8.5)).foregroundStyle(Color.white.opacity(0.6))
                        Text(node.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(receiving ? accent.opacity(0.85) : Color.white.opacity(increased ? 0.35 : 0.10),
                                      lineWidth: 1))
                    .shadow(color: receiving ? accent.opacity(0.5) : .clear, radius: 6)
                }
            }
            .foregroundStyle(Color.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(node.detail.map { node.name + " · " + $0 } ?? node.name)
        .accessibilityLabel(accessibilityText(node, account: account))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func accessibilityText(_ node: AgentsScene.Node, account: AgentsAccount?) -> String {
        var parts = [node.name]
        switch node.kind {
        case .session: if let state = node.state { parts.append(state.word) }
        case .subagent: parts.append("subagent")
        case .teammate: parts.append("teammate")
        case .remote: parts.append("a session on another Mac")
        }
        if let account { parts.append(account.name) }
        return parts.joined(separator: ", ")
    }
}

/// RECENT: the last ten minutes, newest first — who to whom, where it got to, its first line;
/// spawns dim.
struct AgentsRecent: View {
    @ObservedObject var observer: AgentsObserver
    let scene: AgentsScene
    let now: Date
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    @Environment(\.groveAccent) private var accent

    private var increased: Bool { (renderContrast ?? systemContrast) == .increased }

    private var rows: [AgentsScene.Row] {
        guard let selected = observer.selected else { return scene.recent }
        return scene.recent.filter { $0.from == selected || $0.to == selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionCaption(title: observer.selected.flatMap { scene.node($0) }.map { "RECENT · " + $0.name.uppercased() } ?? "RECENT")
                Spacer()
                Text(header).font(.system(size: 10)).foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.36))
            }
            .padding(.horizontal, 2)
            if rows.isEmpty {
                Text(scene.quietFor != nil ? "Nothing in the last ten minutes." : "Nothing yet.")
                    .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 2).padding(.vertical, 6)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if row.isSpawn { spawnRow(row) } else { messageRow(row) }
                    if index < rows.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.leading, 2)
                    }
                }
            }
        }
    }

    private var header: String {
        if let quiet = scene.quietFor { return "Quiet for " + AgentsScene.duration(quiet) }
        let count = observer.selected.map { scene.messagesByNode[$0] ?? 0 } ?? scene.messageCount
        return "\(count) in the last 10 min"
    }

    private func name(_ id: String) -> String {
        if let node = scene.node(id) { return node.name }
        // A peer not placed in the picture: by the name it was sent to.
        if id.hasPrefix("name:") { return String(id.dropFirst(5)) }
        return "a session"
    }

    private func dot(_ id: String) -> Color? {
        guard let node = scene.node(id) else { return nil }
        let key = node.account ?? node.parent.flatMap { scene.node($0)?.account }
        return observer.account(key: key)?.dot
    }

    private func endpoint(_ id: String) -> some View {
        HStack(spacing: 4) {
            if let dot = dot(id) { Circle().fill(dot).frame(width: 5, height: 5) }
            Text(name(id)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.9)).lineLimit(1)
        }
    }

    private func age(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        return relativeAge(date, now: now)
    }

    private func messageRow(_ row: AgentsScene.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                endpoint(row.from)
                Image(systemName: "arrow.right").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.36))
                endpoint(row.to)
                switch row.delivery {
                case .held?:
                    Text("held for approval").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(SessionColors.ink)
                        .padding(.horizontal, 5).frame(height: 14).background(Capsule().fill(SessionColors.needsYou))
                case let delivery? where AgentsScene.notSent.contains(delivery):
                    Text("not sent").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.orange)
                        .help(row.delivery == .expired ? "Not approved in time" : row.delivery == .failed
                              ? "Nobody by that name could take it" : "Turned down")
                case .sending?:
                    Text("sending…").font(.system(size: 9.5)).foregroundStyle(accent.opacity(0.8))
                default:
                    EmptyView()
                }
                Spacer(minLength: 6)
                let fresh = row.at.map { now.timeIntervalSince($0) < 60 } ?? false
                Text(age(row.at)).font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(fresh ? accent.opacity(0.8) : Color.white.opacity(increased ? 0.6 : 0.36))
            }
            Text(row.text).font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(increased ? 0.85 : (scene.quietFor == nil ? 0.66 : 0.45)))
                .lineLimit(1)
        }
        .padding(.horizontal, 2).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func spawnRow(_ row: AgentsScene.Row) -> some View {
        HStack(spacing: 4) {
            Text(name(row.from)).fontWeight(.semibold)
            Text("started")
            Text(name(row.to)).fontWeight(.semibold)
            if !row.text.isEmpty { Text("· " + row.text).lineLimit(1) }
            Spacer(minLength: 6)
            Text(age(row.at)).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.4))
        .padding(.horizontal, 2).padding(.vertical, 5)
    }
}

/// Nothing in the last hour: a still picture, what this tab will show, and what Brow does
/// and does not do to see it.
struct AgentsEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                let points = [CGPoint(x: size.width / 2 - 46, y: 30), CGPoint(x: size.width / 2 + 46, y: 30),
                              CGPoint(x: size.width / 2, y: 62)]
                var lines = Path()
                lines.move(to: points[0])
                lines.addCurve(to: points[1], control1: CGPoint(x: points[0].x, y: 4), control2: CGPoint(x: points[1].x, y: 4))
                lines.move(to: points[0])
                lines.addLine(to: points[2])
                context.stroke(lines, with: .color(Color.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                for point in points {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                                 with: .color(Color.white.opacity(0.22)))
                }
            }
            .frame(height: 74)
            .accessibilityHidden(true)
            Text("No agents talking").font(.system(size: 14, weight: .semibold))
            Text("When your Claude Code sessions message each other — a session and its subagents, an agent team, or two sessions on this Mac — you'll see who talks to whom here, as it happens.")
                .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.58)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Text("\(Image(systemName: "lock"))  Brow reads what Claude Code writes to disk. It never joins a conversation or keeps a message.")
                .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.36))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }
}

private struct RenderReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Offscreen renders: draw as with Reduce Motion on, which a render cannot set.
    public var renderReduceMotion: Bool {
        get { self[RenderReduceMotionKey.self] }
        set { self[RenderReduceMotionKey.self] = newValue }
    }
}
