// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics

/// Where the open panel's rows sit, top to bottom, in window coordinates (points from the
/// top-left corner of `frames.expanded`, y down). Pure, so the panel, the pet and the
/// height model agree on one set of numbers.
///
/// - The band: the strip's own rect at the top. On every section but Limits it keeps the
///   strip's two readouts, with the pet on its ledge beside the camera.
/// - The switch row (only while the panel has sections, that is while Workspaces is on):
///   28 pt, 8 pt under the band, at the same place on every section.
/// - The content: the section's own, scrolling where it is taller than its room.
/// - The footer: a hairline, one 33 pt row, 8 pt of black under it. Never scrolled.
public struct NotchShellLayout: Equatable, Sendable {
    /// Content is inset this far from the visible black's left and right edges.
    public static let side: CGFloat = 14
    public static let switchHeight: CGFloat = 28
    /// From the band to the switch row.
    public static let switchGap: CGFloat = 8
    /// From the switch row to the content.
    public static let contentGap: CGFloat = 10
    /// Between the content and the footer's hairline.
    public static let contentBottomGap: CGFloat = 8
    public static let footerRow: CGFloat = 33
    public static let footerBottom: CGFloat = 8
    /// Hairline, row and the black under it.
    public static let footerHeight: CGFloat = 1 + footerRow + footerBottom

    public let frames: NotchFrames
    /// The switch row is drawn: the panel has more than one section.
    public let showsSwitch: Bool
    /// The strip's readouts are on (Settings › General).
    public let showEars: Bool

    public init(frames: NotchFrames, showsSwitch: Bool, showEars: Bool) {
        self.frames = frames
        self.showsSwitch = showsSwitch
        self.showEars = showEars
    }

    /// The band's height: the strip's own. With a notch, the notch (and the strip under it
    /// for the readouts below); on a display without one, the pill, or nothing while the
    /// readouts are off.
    public var band: CGFloat {
        if frames.hasNotch {
            return frames.placement == .below && showEars
                ? frames.notchHeight + NotchGeometry.belowStripHeight
                : frames.notchHeight
        }
        return showEars ? NotchGeometry.pillHeight : 0
    }

    /// The switch row's top edge.
    public var switchTop: CGFloat { band + Self.switchGap }

    /// Where the section's content starts. Without sections, where today's panel started:
    /// the notch's clearance, and never less than the panel's own 14 pt padding.
    public var contentTop: CGFloat {
        showsSwitch
            ? switchTop + Self.switchHeight + Self.contentGap
            : max(frames.contentTopInset, Self.side)
    }

    /// Content's left (and right) inset from the window's edge: the flare, then `side`.
    public var contentInsetX: CGFloat { frames.flare + Self.side }

    /// 432 pt on a 460 pt panel.
    public var contentWidth: CGFloat { frames.expanded.width - 2 * contentInsetX }

    /// Everything that is not the content: what a section's own height is added to.
    public var chrome: CGFloat { contentTop + Self.contentBottomGap + Self.footerHeight }

    /// The panel's height for a section whose content is `content` tall, unscrolled.
    public func naturalHeight(content: CGFloat) -> CGFloat { chrome + content }

    /// The room the content has in a panel `height` tall.
    public func contentRoom(height: CGFloat) -> CGFloat { max(0, height - chrome) }
}
