// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import GroveAppKit
import GroveCore
import SwiftUI

/// The Agents section: who talks to whom among the Claude Code agents on this Mac — sessions,
/// their subagents and teammates — drawn live from what Claude Code writes to disk.
/// Registered by `WorkspacesHost` while Workspaces is wanted, paused included: it only reads,
/// so Grove.app running changes nothing for it.
@MainActor
final class AgentsSection: NotchSection {
    let host: WorkspacesHost
    var observer: AgentsObserver { host.agents }
    /// The content's width as the panel last laid it out: what the footer counts by.
    private(set) var width: CGFloat = 432

    init(host: WorkspacesHost) {
        self.host = host
    }

    func content(layout: NotchShellLayout) -> AnyView {
        width = layout.contentWidth
        return AnyView(AgentsView(observer: observer, width: layout.contentWidth) { [weak host] node in
            host?.goToSession(node)
        })
    }

    func switchAccessory() -> AnyView { AnyView(AgentsLiveMark(observer: observer)) }

    func footerStatus() -> AnyView {
        AnyView(AgentsFooterStatus(observer: observer, width: { [weak self] in self?.width ?? 432 }))
    }

    func refreshButton() -> AnyView { AnyView(AgentsRefreshButton(observer: observer)) }

    func refresh() { observer.rescan() }

    /// Esc lets go of the picked node first.
    func escape() -> Bool {
        guard observer.selected != nil else { return false }
        observer.selected = nil
        return true
    }

    /// ↩ goes to the picked session.
    func handleKey(_ key: NotchKey) -> Bool {
        guard key == .open, let id = observer.selected, let node = observer.graph.nodes[id],
              node.kind == .session, node.live != nil else { return false }
        host.goToSession(node)
        return true
    }

    func visibilityChanged(_ visible: Bool) {
        if !visible, observer.selected != nil { observer.selected = nil }
    }

    /// The panel opened, on any section: the agents are watched while it is open, so the
    /// switch's dot is current wherever it is looked at; half a minute after it closes, not.
    func panelOpenChanged(_ open: Bool) {
        if open { observer.panelOpened() } else { observer.panelClosed() }
    }
}

/// The switch row's trailing side on Agents: "● Live" while a message moved in the last
/// minute, "● Quiet" otherwise.
struct AgentsLiveMark: View {
    @ObservedObject var observer: AgentsObserver

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(observer.isLive ? NotchTheme.cream : Color.white.opacity(0.3)).frame(width: 6, height: 6)
            Text(observer.isLive ? "Live" : "Quiet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(observer.isLive ? NotchTheme.cream : NotchTheme.tertiary())
        }
        .padding(.trailing, 6)
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(observer.isLive ? "Agents talked in the last minute" : "No agent talked in the last minute")
    }
}

/// The footer's line on Agents: what the picture shows, counted as drawn.
struct AgentsFooterStatus: View {
    @ObservedObject var observer: AgentsObserver
    let width: () -> CGFloat
    @Environment(\.groveIsShowing) private var isShowing

    var body: some View {
        // Kept current every few seconds while the panel is open; still while closed.
        TimelineView(.animation(minimumInterval: 5, paused: !isShowing)) { _ in
            Text(Self.line(observer: observer, width: width(), now: observer.now()))
                .font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
                .foregroundStyle(NotchTheme.secondary())
        }
    }

    /// "4 sessions · 3 agents · 6 messages in 10 min", "4 sessions · quiet for 6 min",
    /// "harbor · 3 links · 2 messages in 10 min", "Watching 3 accounts".
    static func line(observer: AgentsObserver, width: CGFloat, now: Date) -> String {
        let scene = observer.scene(at: now)
        if scene.isEmpty {
            let count = observer.accounts.count
            return "Watching \(count) \(plural(count, "account"))"
        }
        if let id = observer.selected, let node = scene.node(id) {
            let links = scene.links(of: id)
            let messages = scene.messagesByNode[id] ?? 0
            return "\(node.name) · \(links) \(plural(links, "link")) · \(messages) \(plural(messages, "message")) in 10 min"
        }
        let layout = AgentsLayout(scene: scene, width: width, order: observer.order, selected: observer.selected)
        var parts = ["\(layout.drawnSessions) \(plural(layout.drawnSessions, "session"))"]
        if let quiet = scene.quietFor {
            parts.append("quiet for " + AgentsScene.duration(quiet))
            return parts.joined(separator: " · ")
        }
        if layout.drawnAgents > 0 { parts.append("\(layout.drawnAgents) \(plural(layout.drawnAgents, "agent"))") }
        parts.append("\(scene.messageCount) \(plural(scene.messageCount, "message")) in 10 min")
        return parts.joined(separator: " · ")
    }

    private static func plural(_ count: Int, _ word: String) -> String { count == 1 ? word : word + "s" }
}

/// ⟳ on Agents: the records, teams and recent transcripts read again.
struct AgentsRefreshButton: View {
    let observer: AgentsObserver

    var body: some View {
        Button { observer.rescan() } label: { NotchIconLabel(symbol: "arrow.clockwise") }
            .buttonStyle(.plain)
            .help("Read the agents' files again (⌘R)")
            .accessibilityLabel("Read the agents' files again")
    }
}
