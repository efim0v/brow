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
public struct NotchShape: Shape {
    public var topFlare: CGFloat
    public var bottomRadius: CGFloat

    public init(topFlare: CGFloat = NotchGeometry.flare,
                bottomRadius: CGFloat = NotchGeometry.collapsedBottomRadius) {
        self.topFlare = topFlare
        self.bottomRadius = bottomRadius
    }

    public func path(in rect: CGRect) -> Path {
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
