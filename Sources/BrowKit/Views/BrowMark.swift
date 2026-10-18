// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit

/// Brow's mark — the notch, with its two readout dots — drawn in code, for the
/// Workspaces menu-bar item. The silhouette is the app icon's (`site/favicon.svg`): a
/// 50 × 28 shape whose bottom corners are rounded by 11, with dots of radius 5.5 at
/// 12.5 and 37.5 across, 14 down. As a template image the dots are knocked out, so the
/// menu bar's own tint draws the shape and the bar shows through the dots.
public enum BrowMark {
    /// The silhouette's own size, in the icon's units.
    static let artwork = CGSize(width: 50, height: 28)

    /// A template image `width` points wide, as tall as the menu bar's other glyphs.
    public static func templateImage(width: CGFloat = 22) -> NSImage {
        let scale = width / artwork.width
        let size = NSSize(width: width, height: max(16, (artwork.height * scale).rounded(.up)))
        let image = NSImage(size: size, flipped: true) { rect in
            let height = artwork.height * scale
            let origin = CGPoint(x: 0, y: (rect.height - height) / 2)
            path(origin: origin, scale: scale).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Brow Workspaces"
        return image
    }

    /// The notch with two holes, in a flipped (y down) space, filled even-odd.
    static func path(origin: CGPoint, scale: CGFloat) -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        let r = 11 * scale
        let shape = NSBezierPath()
        shape.move(to: p(0, 0))
        shape.line(to: p(50, 0))
        shape.line(to: p(50, 17))
        shape.appendArc(withCenter: p(39, 17), radius: r, startAngle: 0, endAngle: 90)
        shape.line(to: p(11, 28))
        shape.appendArc(withCenter: p(11, 17), radius: r, startAngle: 90, endAngle: 180)
        shape.close()
        for cx: CGFloat in [12.5, 37.5] {
            let d = 11 * scale
            let center = p(cx, 14)
            shape.appendOval(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
        }
        shape.windingRule = .evenOdd
        return shape
    }
}
