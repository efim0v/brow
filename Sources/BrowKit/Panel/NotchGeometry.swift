import Foundation

/// The subset of NSScreen the geometry needs, so the math is testable without a display.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    public let topLeftArea: CGRect?
    public let topRightArea: CGRect?
    public let menuBarHeight: CGFloat
    public init(frame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?, menuBarHeight: CGFloat) {
        self.frame = frame
        self.topLeftArea = topLeftArea
        self.topRightArea = topRightArea
        self.menuBarHeight = menuBarHeight
    }
}

public struct NotchFrames: Sendable, Equatable {
    public let collapsed: CGRect
    public let expanded: CGRect
    public let hasNotch: Bool
    public let earWidth: CGFloat
}

/// Pure frame math (Cocoa coordinates: origin bottom-left, y grows upward).
public enum NotchGeometry {
    public static let expandedWidth: CGFloat = 460
    public static let pillWidth: CGFloat = 180
    public static let pillHeight: CGFloat = 24
    public static let earWidth: CGFloat = 96
    /// `EarsView` insets the pill by this much on each side (there is no notch to
    /// fill), so the two ears have `pillWidth - 2 * pillPadding` between them. Taking
    /// `pillWidth / 2` per ear asked for 200 pt inside a 180 pt window and clipped
    /// ~10 pt off each edge — exactly where the two status dots sit.
    public static let pillPadding: CGFloat = 10

    public static func frames(for screen: ScreenMetrics, expandedHeight: CGFloat) -> NotchFrames {
        let top = screen.frame.maxY
        if let left = screen.topLeftArea, let right = screen.topRightArea {
            let notchMinX = left.maxX, notchMaxX = right.minX
            let collapsed = CGRect(x: notchMinX - earWidth, y: top - screen.menuBarHeight,
                                   width: (notchMaxX - notchMinX) + 2 * earWidth, height: screen.menuBarHeight)
            let expanded = clamp(CGRect(x: (notchMinX + notchMaxX) / 2 - expandedWidth / 2, y: top - expandedHeight,
                                        width: expandedWidth, height: expandedHeight), in: screen.frame)
            return NotchFrames(collapsed: collapsed, expanded: expanded, hasNotch: true, earWidth: earWidth)
        }
        let midX = screen.frame.midX
        let collapsed = CGRect(x: midX - pillWidth / 2, y: top - pillHeight, width: pillWidth, height: pillHeight)
        let expanded = clamp(CGRect(x: midX - expandedWidth / 2, y: top - expandedHeight,
                                    width: expandedWidth, height: expandedHeight), in: screen.frame)
        return NotchFrames(collapsed: collapsed, expanded: expanded, hasNotch: false,
                           earWidth: (pillWidth - 2 * pillPadding) / 2)
    }

    private static func clamp(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        return r
    }
}
