// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import Foundation
import GroveAppKit
import SwiftUI

/// Which session card the pointer is over, decided from the controller's own mouse monitors,
/// as the calendar's day is (`CalendarHoverTracker`): SwiftUI's `onHover` does not fire in
/// this non-activating panel, and a card shows its Go or Resume and its menu only under the
/// pointer. The cards report their frames (`SessionCardFrames`, the hosting view's space);
/// `update(pointer:)` hit-tests and publishes only when the card under the pointer changes.
@MainActor
final class NotchCardHover: ObservableObject {
    @Published private(set) var session: String?
    /// Session → its card's frame. Not published: a layout pass must not redraw the cards.
    private(set) var frames: [String: CGRect] = [:]
    /// Where the pointer was last, for frames that move under a still pointer (a scroll).
    private var pointer: CGPoint?

    /// `pointer` in the hosting view's space (origin top-left), nil when it left the panel.
    func update(pointer: CGPoint?) {
        self.pointer = pointer
        let hit = pointer.flatMap { point in frames.first { $0.value.contains(point) }?.key }
        if hit != session { session = hit }
    }

    /// The cards' frames as last laid out; the card under a pointer that has not moved is
    /// looked for again, after the layout pass that reported them.
    func setFrames(_ frames: [String: CGRect]) {
        guard frames != self.frames else { return }
        self.frames = frames
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.update(pointer: self.pointer)
        }
    }
}

/// The section's content with the card under the pointer in its environment: only this scope
/// is drawn again when it changes, not the shell around it.
struct CardHoverScope: View {
    @ObservedObject var hover: NotchCardHover
    let content: AnyView

    var body: some View {
        content
            .environment(\.hostHoveredSession, hover.session)
            .onPreferenceChange(SessionCardFrames.self) { frames in hover.setFrames(frames) }
    }
}
