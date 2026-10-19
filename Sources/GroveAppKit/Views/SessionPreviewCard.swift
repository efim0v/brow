// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// One session, told apart from its siblings by how its conversation ends rather than by
/// a folder name they share:
///
///     ◌ Working · Bash · npm test · checkout-redesign · ● Work           2m
///       you     make the address step validate inline
///       claude  9 of 12 checkout tests pass. Fixing the ZIP+4 rule next.
///
/// The state in its colour and what it is doing or waits on, where it runs and as whom;
/// the newest prompt (labelled with the session that sent it, when another did); Claude's
/// newest line — or, stopped at a permission prompt, "Wants to run" and the command, or
/// the question it asks. On hover or focus the age gives way to Go (it runs) or Resume (it
/// does not) and the menu. With previews off, the title stands in for the two lines.
struct SessionPreviewCard: View {
    enum Density {
        /// Lists: Claude's line on one line.
        case card
        /// A project's own screen: up to two.
        case full
    }

    @ObservedObject var state: AppState
    let ref: SessionRef
    let sessionState: SessionState
    let preview: SessionPreview?
    /// The workspace, loose worktree or branch; nil where the card sits in its place already.
    let place: String?
    var density: Density = .card
    var focused = false
    /// Offscreen renders: drawn hovered.
    var hoveredInRender = false
    /// The search's words, marked where they show.
    var highlight: String = ""
    @State private var hovered = false
    @Environment(\.groveAccent) private var accent
    @Environment(\.colorSchemeContrast) private var systemContrast
    @Environment(\.renderContrast) private var renderContrast
    private var contrast: ColorSchemeContrast { renderContrast ?? systemContrast }
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.renderHoveredSession) private var renderHovered

    /// The label column of the prompt and Claude's lines.
    static let labelWidth: CGFloat = 44

    private var increased: Bool { contrast == .increased }
    private var askingDelete: Bool { state.confirmingDelete == ref.sessionId }
    private var hoveredNow: Bool { hovered || hoveredInRender || renderHovered == ref.sessionId }
    private var showsActions: Bool { (hoveredNow || focused) && !askingDelete }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionStatusGlyph(status: sessionState, size: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                firstLine
                if askingDelete {
                    DeleteTranscriptConfirm(onDelete: {
                        state.confirmingDelete = nil
                        SessionMenu.delete(ref, state: state)
                    }, onCancel: { state.confirmingDelete = nil })
                } else if let title = content.title {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    promptLine
                    claudeLine
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SessionCardBackground(focused: focused, hovered: hoveredNow))
        .opacity(sessionState == .closed ? 0.7 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            SessionMenuContent(items: SessionMenu.items(for: ref, state: state, onAskDelete: askDelete))
        }
        .help(ref.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: Text(ref.isLive ? "Go" : "Resume")) { SessionMenu.primary(ref, state: state) }
    }

    private func askDelete() { state.confirmingDelete = ref.sessionId }

    /// What the card says, as data.
    private var content: SessionCardContent {
        SessionCardContent.make(state: sessionState, preview: preview, title: ref.title,
                                showsPreviews: state.showsMessagePreviews)
    }

    // MARK: - Line 1: state, place, account

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            meta
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if showsActions {
                actions
            } else {
                Text(Self.age(ref.lastActivity, now: Date()))
                    .font(.system(size: 10.5)).monospacedDigit()
                    .foregroundStyle(ref.lastActivity.timeIntervalSinceNow > -60 && sessionState.isLive
                                     ? accent.opacity(0.85) : Color.white.opacity(increased ? 0.6 : 0.36))
            }
        }
        .frame(minHeight: 18)
    }

    /// "Working · Bash · npm test · checkout-redesign · ● Work · ↔ harbor".
    private var meta: Text {
        let quiet = Color.white.opacity(increased ? 0.6 : 0.36)
        var parts = [Text(sessionState.word).foregroundStyle(stateColor).fontWeight(.medium)]
        if let step = content.step {
            parts.append(Text(" · " + step).foregroundStyle(Color.white.opacity(increased ? 0.8 : 0.58)))
        }
        if let place, !place.isEmpty {
            parts += [Text(" · ").foregroundStyle(quiet), marked(place, color: quiet)]
        }
        if let account = state.workspacesAccount(named: ref.accountName), let dot = account.dot {
            parts += [Text(" · ").foregroundStyle(quiet), Text("●").foregroundStyle(dot).font(.system(size: 7)),
                      Text(" " + account.name).foregroundStyle(quiet)]
        } else {
            parts.append(Text(" · " + state.displayName(forAccountNamed: ref.accountName)).foregroundStyle(quiet))
        }
        if case .peer(let name)? = preview?.sender {
            parts.append(Text(" · ↔ " + name).foregroundStyle(quiet))
        }
        return Text.joined(parts).font(.system(size: 10.5))
    }

    private var stateColor: Color {
        switch sessionState {
        case .working: return accent
        case .needsPermission, .asksYou: return SessionColors.needsYou
        case .yourTurn: return Color.white.opacity(0.86)
        case .closed: return Color.white.opacity(increased ? 0.6 : 0.36)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button { SessionMenu.primary(ref, state: state) } label: {
                Text(ref.isLive ? "Go" : "Resume")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ref.isLive ? SessionColors.ink : Color.white)
                    .padding(.horizontal, 10).frame(height: 20)
                    .background(Capsule().fill(ref.isLive ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.12))))
            }
            .buttonStyle(.plain)
            .help(ref.isLive ? "Go to this running session (↩)" : "Resume: a new Claude process with --resume (↩)")
            SessionActionsMenu(state: state, ref: ref, onAskDelete: askDelete)
                .frame(height: 18)
        }
        .fixedSize()
        .padding(.vertical, -2)
    }

    // MARK: - Lines 2 and 3: the prompt, Claude's line

    private var promptLine: some View {
        labelled(content.speaker) {
            marked(content.prompt ?? ref.title, color: Color.white.opacity(increased ? 0.85 : 0.7))
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var claudeLine: some View {
        if let line = claudeText {
            labelled("claude") {
                line
                    .lineLimit(density == .full ? 2 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Claude's newest line, drawn.
    private var claudeText: Text? {
        let primary = Color.white.opacity(0.94)
        switch content.claude {
        case .wants(let verb, let input)?:
            return Text.joined([
                Text(verb + " ").foregroundStyle(SessionColors.needsYou).font(.system(size: 12, weight: .medium)),
                Text(input).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(primary),
            ])
        case .question(let question)?:
            return marked(question, color: primary).font(.system(size: 12.5))
        case .step(let step)?:
            return Text(step).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.45))
        case .reply(let reply)?:
            return marked(reply, color: primary).font(.system(size: 12.5))
        case nil:
            return nil
        }
    }


    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(increased ? 0.6 : 0.36))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Text

    /// `text` with the search's words on a cream wash.
    private func marked(_ text: String, color: Color) -> Text {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color
        let needle = highlight.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            let lower = text.lowercased()
            var from = lower.startIndex
            while from < lower.endIndex, let range = lower.range(of: needle, range: from..<lower.endIndex) {
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let length = lower.distance(from: range.lowerBound, to: range.upperBound)
                if start + length <= text.count {
                    let a = attributed.index(attributed.startIndex, offsetByCharacters: start)
                    let b = attributed.index(a, offsetByCharacters: length)
                    attributed[a..<b].backgroundColor = accent.opacity(0.28)
                    attributed[a..<b].foregroundColor = .white
                }
                from = range.upperBound
            }
        }
        return Text(attributed)
    }

    /// "now" under a minute, then "5m", "2h", "3d", "1w".
    static func age(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "now" : relativeAge(date, now: now)
    }

    private var accessibilityText: String {
        var parts = [sessionState.word]
        let content = content
        if let title = content.title {
            parts.append(title)
        } else {
            if let prompt = content.prompt {
                parts.append("\(content.speaker == "you" ? "You" : content.speaker): \(prompt)")
            }
            switch content.claude {
            case .wants(let verb, let input)?: parts.append("Claude \(verb.lowercased()) \(input)")
            case .question(let question)?: parts.append("Claude asks: \(question)")
            case .reply(let reply)?: parts.append("Claude: \(reply)")
            case .step(let step)?: parts.append(step)
            case nil: break
            }
        }
        if let place { parts.append(place) }
        parts.append(state.displayName(forAccountNamed: ref.accountName))
        return parts.joined(separator: ". ")
    }
}

extension SessionPreviewCard {
    /// A row of a project's list.
    init(state: AppState, row: ProjectSessionRow, place: String? = nil, density: Density = .card,
         focused: Bool = false, hoveredInRender: Bool = false, highlight: String = "") {
        self.init(state: state, ref: SessionRef(row: row), sessionState: row.state, preview: row.preview,
                  place: place ?? row.location, density: density, focused: focused, hoveredInRender: hoveredInRender,
                  highlight: highlight)
    }

    /// A session from the disk-wide pass or a workspace's scan: its state from what runs now.
    init(state: AppState, session: ClaudeSession, place: String?, cmuxWorkspaceId: String? = nil,
         density: Density = .card, highlight: String = "") {
        let sessionState = state.state(of: session)
        self.init(state: state,
                  ref: SessionRef(session: session, isLive: sessionState.isLive, cmuxWorkspaceId: cmuxWorkspaceId),
                  sessionState: sessionState, preview: session.preview, place: place, density: density,
                  highlight: highlight)
    }
}

extension Text {
    /// Pieces of text, each in its own style, as one: what `+` on `Text` did.
    static func joined(_ parts: [Text]) -> Text {
        parts.dropFirst().reduce(parts.first ?? Text("")) { Text("\($0)\($1)") }
    }
}

/// What a session card says, as data: the step after its state word, who asked last and
/// what, and Claude's newest line — or the title alone with previews off. Pure, so the
/// rules are tested without a view.
struct SessionCardContent: Equatable {
    enum Claude: Equatable {
        /// Stopped at a permission prompt: "Wants to run" and the command.
        case wants(verb: String, input: String)
        /// Asking the user.
        case question(String)
        /// Working with no text for the newest prompt yet: the step it is on, dimmed.
        case step(String)
        /// Its reply.
        case reply(String)
    }

    /// After the state word: the tool and what it works on ("Bash · npm test").
    var step: String?
    /// "you", or the session that sent the newest prompt.
    var speaker = "you"
    var prompt: String?
    var claude: Claude?
    /// With previews off: the title, in place of the prompt and Claude's line.
    var title: String?

    static func make(state: SessionState, preview: SessionPreview?, title: String, showsPreviews: Bool) -> SessionCardContent {
        var content = SessionCardContent()
        if let preview, preview.turn == .tool, let tool = preview.tool {
            if state == .needsPermission {
                content.step = tool
            } else if state == .working {
                content.step = [tool, preview.pendingInput].compactMap { $0 }.joined(separator: " · ")
            }
        }
        guard showsPreviews else {
            content.title = title
            return content
        }
        guard let preview else {
            content.prompt = title
            return content
        }
        if case .peer(let name) = preview.sender { content.speaker = name }
        content.prompt = preview.prompt ?? title
        if state == .needsPermission, let input = preview.pendingInput {
            content.claude = .wants(verb: wants(preview.tool), input: input)
        } else if state == .asksYou, let question = preview.question {
            content.claude = .question(question)
        } else if state == .working, !preview.replyIsCurrent || preview.reply == nil {
            let doing = preview.turn == .tool
                ? [preview.tool, preview.pendingInput].compactMap { $0 }.joined(separator: " · ") : "Thinking…"
            content.claude = .step(doing.isEmpty ? "Working…" : doing)
        } else if let reply = preview.reply {
            content.claude = .reply(reply)
        }
        return content
    }

    /// "Wants to run", "Wants to edit", … by the tool that asks.
    static func wants(_ tool: String?) -> String {
        switch tool {
        case "Bash": return "Wants to run"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Wants to edit"
        case "Read": return "Wants to read"
        case "WebFetch": return "Wants to fetch"
        case "WebSearch": return "Wants to search"
        case let tool?: return "Wants to use \(tool)"
        case nil: return "Wants to run"
        }
    }
}

private struct RenderHoveredSessionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Offscreen renders: the session whose card is drawn as under the pointer.
    public var renderHoveredSession: String? {
        get { self[RenderHoveredSessionKey.self] }
        set { self[RenderHoveredSessionKey.self] = newValue }
    }
}
