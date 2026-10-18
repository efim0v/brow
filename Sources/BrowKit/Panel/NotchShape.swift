// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// The notch outline: concave where the black meets the screen edge (the physical
/// notch flares out there, and a square top corner is what made the old strip read as
/// a bar stuck on the screen), convex at the bottom.
///
/// Drawn in the shape's own coordinates — origin top-left, `W` includes both flares,
/// `H` is the whole frame — so the caller only has to hand it the frame `NotchGeometry`
/// computed. Both radii live in `NotchGeometry` (`flare`, `collapsedBottomRadius`,
/// `expandedBottomRadius`) and are meant to be tuned by eye against the physical bezel;
/// no screenshot can show it.
///
/// The bottom corners are Apple's continuous corners, the squircle every window and
/// icon on the Mac is cut with: the curvature grows from zero where the side leaves
/// the straight, so the corner has no visible "start". The quadratic corner it replaces
/// turned at once, which is what read as a plain radius.
public struct NotchShape: Shape {
    public var topFlare: CGFloat
    public var bottomRadius: CGFloat
    /// False draws the old quadratic corners, for side-by-side comparisons only.
    public var continuousCorners: Bool

    public init(topFlare: CGFloat = NotchGeometry.flare,
                bottomRadius: CGFloat = NotchGeometry.collapsedBottomRadius,
                continuousCorners: Bool = true) {
        self.topFlare = topFlare
        self.bottomRadius = bottomRadius
        self.continuousCorners = continuousCorners
    }

    /// Both radii interpolate, so the strip's corners can grow into the panel's as the
    /// shape itself grows on hover.
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlare, bottomRadius) }
        set { topFlare = newValue.first; bottomRadius = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        continuousCorners ? continuousPath(in: rect) : quadraticPath(in: rect)
    }

    /// The body between the flares with continuous bottom corners, and each flare as a
    /// subpath of its own beside the body's square top corner. The flares share the
    /// body's edge without overlapping it, so the union has no seam and no winding to
    /// get wrong.
    private func continuousPath(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX + topFlare, y: rect.minY,
                          width: max(0, rect.width - 2 * topFlare), height: rect.height)
        let radius = max(0, min(bottomRadius, body.width / 2, body.height))
        var path = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                          bottomTrailingRadius: radius, topTrailingRadius: 0,
                                          style: .continuous).path(in: body)
        guard topFlare > 0 else { return path }
        // Concave top-left: the bezel's own curve into the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: rect.minY + topFlare),
                          control: CGPoint(x: body.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.minX, y: rect.minY))
        path.closeSubpath()
        // Concave top-right.
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: rect.minY + topFlare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: body.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private func quadraticPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Concave top-left.
        path.addQuadCurve(to: CGPoint(x: rect.minX + topFlare, y: rect.minY + topFlare),
                          control: CGPoint(x: rect.minX + topFlare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topFlare, y: rect.maxY - bottomRadius))
        // Convex bottom-left.
        path.addQuadCurve(to: CGPoint(x: rect.minX + topFlare + bottomRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topFlare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topFlare - bottomRadius, y: rect.maxY))
        // Convex bottom-right.
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topFlare, y: rect.maxY - bottomRadius),
                          control: CGPoint(x: rect.maxX - topFlare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topFlare, y: rect.minY + topFlare))
        // Concave top-right.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topFlare, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
