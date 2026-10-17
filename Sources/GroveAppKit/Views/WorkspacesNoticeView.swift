// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// What the Workspaces panel shows INSTEAD of the projects when the engine is not
/// running: an introduction while Workspaces is off, or the reason it is paused. The
/// host writes the words and the actions; the panel only lays them out. No engine
/// state is read or refreshed behind a notice.
public struct WorkspacesNotice {
    public struct Action {
        public let title: String
        public let perform: @MainActor () -> Void
        public init(_ title: String, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    public let symbol: String
    public let title: String
    public let message: String
    public let primary: Action?
    public let secondary: Action?

    public init(symbol: String, title: String, message: String, primary: Action? = nil, secondary: Action? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primary = primary
        self.secondary = secondary
    }
}

/// The notice, laid out at the projects screen's width on the panel's glass.
public struct WorkspacesNoticeView: View {
    let notice: WorkspacesNotice
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    public init(notice: WorkspacesNotice) { self.notice = notice }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .font(.title2)
                    .foregroundStyle(Palette.primary)
                Text(notice.title).font(.title3.weight(.semibold))
            }
            Text(notice.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let primary = notice.primary { button(primary, prominent: true) }
                if let secondary = notice.secondary { button(secondary, prominent: false) }
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .tint(Palette.primary)
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        )
    }

    @ViewBuilder
    private func button(_ action: WorkspacesNotice.Action, prominent: Bool) -> some View {
        if isSnapshotRender {
            // A real Button is AppKit-backed and draws as a placeholder offscreen.
            Text(action.title)
                .font(.callout.weight(prominent ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(prominent ? AnyShapeStyle(Palette.primary) : AnyShapeStyle(.white.opacity(0.10)),
                            in: Capsule())
        } else if prominent {
            Button(action.title) { action.perform() }.buttonStyle(.borderedProminent)
        } else {
            Button(action.title) { action.perform() }
        }
    }
}
