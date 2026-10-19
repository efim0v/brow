// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// What Projects shows INSTEAD of the projects while the engine waits: the reason it
/// is paused (Grove.app, or another copy of Brow). The host writes the words and the
/// actions; the screen only lays them out. No engine
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

/// The notice, laid out across the room it is given: the Projects section, while it
/// replaces the projects.
public struct WorkspacesNoticeView: View {
    let notice: WorkspacesNotice
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.groveAccent) private var accent

    public init(notice: WorkspacesNotice) { self.notice = notice }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(accent)
                Text(notice.title).font(.system(size: 15, weight: .semibold))
            }
            Text(notice.message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let primary = notice.primary { button(primary, prominent: true) }
                if let secondary = notice.secondary { button(secondary, prominent: false) }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(accent)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07))
        )
    }

    /// A capsule: the primary in the accent with ink on it, the other quiet. Pure SwiftUI,
    /// so it draws the same offscreen.
    private func button(_ action: WorkspacesNotice.Action, prominent: Bool) -> some View {
        Button { action.perform() } label: {
            Text(action.title)
                .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color(red: 0x2A / 255, green: 0x22 / 255, blue: 0x18 / 255) : .white)
                .padding(.horizontal, 14).frame(height: 26)
                .background(Capsule().fill(prominent ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.10))))
        }
        .buttonStyle(.plain)
    }
}
