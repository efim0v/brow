// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import GroveCore

/// Workspaces' root: a state machine of full screens switched over `AppState.route` (one
/// scope per screen, never an overlay), under a notice line for what went wrong. In the
/// notch (`groveHost`) the screens fill the section's room and push and pop with a short
/// slide; in a window of their own (the offscreen renders) each route has its own size.
///
/// A refresh loop runs while the screens are visible (`AppState.isPanelOpen`): one pass on
/// opening — unless one finished less than 10 s ago — then one every 15 s.
public struct RootView: View {
    @ObservedObject private var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.groveHost) private var host
    @Environment(\.groveAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(spacing: 0) {
            NoticeLine(state: state)
            routedScreen
        }
        // One accent for every system-styled control (default-action buttons, links,
        // toggles): the host's in the notch, Grove's blue in a window of its own.
        .tint(accent)
        // Keyed on isPanelOpen: the panel hides without tearing this view down, so the loop
        // must stop itself when it closes. In a render or a test isPanelOpen is false, so the
        // loop never starts — no refresh against the real ~/.claude.
        .task(id: state.isPanelOpen) {
            guard !isSnapshotRender, state.isPanelOpen else { return }
            // Nothing here talks to the network: per-account limits are Brow's job.
            if state.needsRefreshOnOpen() { await state.refresh() }
            while !Task.isCancelled && state.isPanelOpen {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled || !state.isPanelOpen { break }
                await state.refresh()
            }
        }
    }

    // MARK: - Routes

    @ViewBuilder private var routedScreen: some View {
        if host.isNotch {
            ZStack(alignment: .top) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(state.route)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.22), value: state.route)
            .clipped()
        } else {
            screen
                .modifier(RouteFrame(size: Self.panelSize(for: state.route)))
        }
    }

    /// Push and pop: the new screen slides 16 pt in from its side with a fade. A fade only
    /// under Reduce Motion.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edge: CGFloat = state.routeIsForward ? 16 : -16
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: edge)),
                           removal: .opacity.combined(with: .offset(x: -edge)))
    }

    @ViewBuilder private var screen: some View {
        switch state.route {
        case .projects:
            RootShell(state: state)
        case .project:
            ProjectScreen(state: state)
        case .createWorkspace:
            CreateWorkspaceScreen(state: state,
                                  prefill: state.createPrefill ?? CreatePrefill(),
                                  onClose: { state.goBack() })
        case .projectSettings(let id):
            ProjectSettingsScreen(state: state, projectID: id)
        case .statsSettings(let id):
            StatsSettingsScreen(state: state, projectID: id)
        case .otherSessions:
            OtherSessionsScreen(state: state)
        case .launch:
            LaunchFormScreen(state: state)
        }
    }

    /// A route's size in a window of its own (the offscreen renders); nil height: as tall as
    /// its content, up to 560.
    static func panelSize(for route: Route) -> (width: CGFloat, height: CGFloat?) {
        switch route {
        case .projects: return (460, 520)
        case .project: return (600, 540)
        case .createWorkspace: return (540, nil)
        case .projectSettings: return (560, 560)
        case .statsSettings: return (560, 560)
        case .otherSessions: return (600, 540)
        case .launch: return (460, 520)
        }
    }

    private struct RouteFrame: ViewModifier {
        let size: (width: CGFloat, height: CGFloat?)

        func body(content: Content) -> some View {
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .frame(maxHeight: 560)
        }
    }
}

/// What went wrong, where it happens: one line over the screen with its fix, and a way to
/// dismiss it. Grove's own config problem too, which no button fixes.
struct NoticeLine: View {
    @ObservedObject var state: AppState
    @Environment(\.groveAccent) private var accent

    var body: some View {
        if state.actionError != nil || state.configIssue != nil {
            VStack(spacing: 6) {
                if let error = state.actionError {
                    notice(error, fix: error.localizedCaseInsensitiveContains("cmux") ? "Launch cmux" : nil,
                           onFix: { Task { await state.launchCmuxApp() } },
                           onDismiss: { state.actionError = nil })
                }
                if let issue = state.configIssue {
                    notice(issue, fix: nil, onFix: {}, onDismiss: nil)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func notice(_ text: String, fix: String?, onFix: @escaping () -> Void,
                        onDismiss: (() -> Void)?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
            Spacer(minLength: 4)
            if let fix {
                Button(action: onFix) {
                    Text(fix).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(Color.orange.opacity(0.10)))
        .overlay(shape.strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }
}
