import Foundation

/// The subset of NSScreen the geometry needs, so the math is testable without a display.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    public let topLeftArea: CGRect?
    public let topRightArea: CGRect?
    public let menuBarHeight: CGFloat
    /// `NSScreen.safeAreaInsets.top`. 0 when the OS reports none, in which case the
    /// geometry falls back to the auxiliary area's height. Never the menu-bar height:
    /// on the 14" the notch is 32 pt where the menu bar is 33, and that one point is
    /// what made the collapsed strip stand proud of the notch.
    public let notchHeight: CGFloat

    public init(frame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?,
                menuBarHeight: CGFloat, notchHeight: CGFloat = 0) {
        self.frame = frame
        self.topLeftArea = topLeftArea
        self.topRightArea = topRightArea
        self.menuBarHeight = menuBarHeight
        self.notchHeight = notchHeight
    }
}

public struct NotchFrames: Sendable, Equatable {
    public let collapsed: CGRect
    public let expanded: CGRect
    public let hasNotch: Bool
    public let earWidth: CGFloat
    /// Where the ears sit. Always `.beside` when there is no notch to sit below.
    public let placement: EarsPlacement
    /// The resolved notch height, 0 without a notch.
    public let notchHeight: CGFloat
    /// How far the expanded panel's content starts below the frame's top edge, so
    /// nothing is hidden under the notch.
    public let contentTopInset: CGFloat
    /// How much of each side of the frame `NotchShape`'s concave flares occupy; 0 for
    /// the pill, which is drawn square.
    public let flare: CGFloat
}

/// Pure frame math (Cocoa coordinates: origin bottom-left, y grows upward).
public enum NotchGeometry {
    public static let expandedWidth: CGFloat = 460
    public static let pillWidth: CGFloat = 180
    public static let pillHeight: CGFloat = 24
    /// Each of the two wings the `beside` ears sit in.
    public static let wingWidth: CGFloat = 96
    /// The strip under the notch the `below` ears sit in.
    public static let belowStripHeight: CGFloat = 22
    /// `NotchShape`'s tuning knobs, in one place. Every notched frame is widened by
    /// `flare` on each side so the concave flares have room to be drawn; the visible
    /// black still starts at the notch/wing edge.
    public static let flare: CGFloat = 6
    public static let collapsedBottomRadius: CGFloat = 12
    public static let expandedBottomRadius: CGFloat = 18
    /// `EarsView` insets the pill by this much on each side (there is no notch to
    /// fill), so the two ears have `pillWidth - 2 * pillPadding` between them. Taking
    /// `pillWidth / 2` per ear asked for 200 pt inside a 180 pt window and clipped
    /// ~10 pt off each edge — exactly where the two status dots sit.
    public static let pillPadding: CGFloat = 10
    /// Last-resort notch height, for a screen that reports auxiliary areas but neither a
    /// safe-area inset, nor an area height, nor a menu bar. Same number `NotchPanel`
    /// floors the menu bar at.
    public static let fallbackNotchHeight: CGFloat = 24
    /// Breathing room between the notch and the first row of the expanded panel.
    private static let contentGap: CGFloat = 8
    /// One log line per process for the degenerate-screen fallback: `frames(for:)` runs
    /// on every render (every hover), and an error repeated at that rate is noise, not a
    /// signal.
    private static let degenerateReport = OneShot()

    public static func frames(for screen: ScreenMetrics, expandedHeight: CGFloat,
                              placement: EarsPlacement = .beside) -> NotchFrames {
        let top = screen.frame.maxY
        if let left = screen.topLeftArea, let right = screen.topRightArea {
            let notchMinX = left.maxX, notchMaxX = right.minX
            let notchWidth = notchMaxX - notchMinX
            // Floored, like `NotchPanel.metrics()` floors the menu bar: the `beside`
            // collapsed height IS the notch height, so a screen that reports auxiliary
            // areas of height 0 (and no safe-area inset) gave a zero-height — invisible —
            // collapsed window. "The app did not launch" with nothing in the log to say
            // why is a far worse answer than a height that is wrong by a point.
            let reported = screen.notchHeight > 0 ? screen.notchHeight : max(left.height, right.height)
            let notchHeight = reported > 0
                ? reported
                : (screen.menuBarHeight > 0 ? screen.menuBarHeight : fallbackNotchHeight)
            if reported <= 0, Self.degenerateReport.fire() {
                BrowLog.panel.error("""
                    screen reports no notch height and auxiliary areas of height \
                    \(max(left.height, right.height), privacy: .public); \
                    falling back to \(notchHeight, privacy: .public) pt
                    """)
            }
            let collapsed: CGRect
            let earWidth: CGFloat
            switch placement {
            case .beside:
                // The notch plus a 96 pt wing on each side; the middle is left empty.
                collapsed = CGRect(x: notchMinX - wingWidth - flare, y: top - notchHeight,
                                   width: notchWidth + 2 * wingWidth + 2 * flare, height: notchHeight)
                earWidth = wingWidth
            case .below:
                // Exactly the notch's width, carrying the ear strip under it.
                collapsed = CGRect(x: notchMinX - flare, y: top - notchHeight - belowStripHeight,
                                   width: notchWidth + 2 * flare, height: notchHeight + belowStripHeight)
                earWidth = notchWidth / 2
            }
            let width = expandedWidth + 2 * flare
            let expanded = clamp(CGRect(x: (notchMinX + notchMaxX) / 2 - width / 2, y: top - expandedHeight,
                                        width: width, height: expandedHeight), in: screen.frame)
            return NotchFrames(collapsed: collapsed, expanded: expanded, hasNotch: true, earWidth: earWidth,
                               placement: placement, notchHeight: notchHeight,
                               contentTopInset: notchHeight + contentGap, flare: flare)
        }
        // No notch: the pill, unchanged and square — `below` has nothing to sit below.
        let midX = screen.frame.midX
        let collapsed = CGRect(x: midX - pillWidth / 2, y: top - pillHeight, width: pillWidth, height: pillHeight)
        let expanded = clamp(CGRect(x: midX - expandedWidth / 2, y: top - expandedHeight,
                                    width: expandedWidth, height: expandedHeight), in: screen.frame)
        return NotchFrames(collapsed: collapsed, expanded: expanded, hasNotch: false,
                           earWidth: (pillWidth - 2 * pillPadding) / 2,
                           placement: .beside, notchHeight: 0, contentTopInset: contentGap, flare: 0)
    }

    private static func clamp(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        return r
    }
}
