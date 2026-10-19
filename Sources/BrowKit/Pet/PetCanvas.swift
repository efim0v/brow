// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

extension PetPalette {
    /// The look the pet ships with: cream, with its arms and feet as they are. `original` stays a case, so
    /// going back to the honey light is this one line.
    public static let standard: PetPalette = .cream
}

/// Draws one `PetFrame`. It holds no state and reads no clock: the same frame and palette always give the
/// same picture, and the palette changes colours only.
///
/// The view is the pet's own small canvas, `frame.canvas` in window coordinates: the layer places it
/// there (`.offset(x: canvas.minX, y: canvas.minY)` in a top-leading stack) and it draws everything
/// else in window coordinates too. Soft light is gradients only: no blur, no shadow, no offscreen pass
/// per frame.
public struct PetCanvas: View {
    public let frame: PetFrame
    public let palette: PetPalette
    /// `-petPerfLog`: told how long each drawing took, on the main thread where the canvas draws.
    var measure: ((Duration) -> Void)?

    public init(frame: PetFrame, palette: PetPalette = .standard) {
        self.frame = frame
        self.palette = palette
    }

    init(frame: PetFrame, palette: PetPalette, measure: ((Duration) -> Void)?) {
        self.frame = frame
        self.palette = palette
        self.measure = measure
    }

    public var body: some View {
        Canvas { context, _ in
            let start = measure == nil ? nil : ContinuousClock.now
            context.translateBy(x: -frame.canvas.minX, y: -frame.canvas.minY)
            Self.draw(frame, palette: palette.colors, in: &context)
            if let start, let measure { measure(ContinuousClock.now - start) }
        }
        .frame(width: max(frame.canvas.width, 1), height: max(frame.canvas.height, 1))
        .allowsHitTesting(false)
    }

    /// Draws `frame` into `context`, whose coordinates are the window's.
    public static func draw(_ frame: PetFrame, palette: PetPalette.Colors, in context: inout GraphicsContext) {
        guard !frame.isEmpty else { return }
        var ctx = context
        // The camera has no pixels: whatever passes the notch's edge is simply not there.
        if let notch = frame.notch {
            ctx.clip(to: Path(notch), options: .inverse)
        }
        let look = Look(palette: palette, motion: frame.motion, guardMinX: frame.guardMinX,
                        guardMaxX: frame.guardMaxX, foodSource: frame.foodSource, foodDot: frame.foodDot)
        if let door = frame.doorLight { drawDoorLight(door, look, in: &ctx) }
        if let echo = frame.echo, echo.opacity > 0.001 { drawPet(echo, frame: frame, look, in: &ctx) }
        if frame.pet.opacity > 0.001 { drawPet(frame.pet, frame: frame, look, in: &ctx) }
        drawParticles(frame.particles, opacity: frame.pet.opacity, look, in: &ctx)
        if let bead = frame.bead { drawBead(bead, look, in: &ctx) }
        if let glint = frame.glint { drawGlint(glint, look, in: &ctx) }
    }

    /// What every part of the drawing reads besides the pose.
    struct Look {
        let palette: PetPalette.Colors
        let motion: PetMotion
        let guardMinX: CGFloat?
        let guardMaxX: CGFloat?
        let foodSource: CGPoint?
        let foodDot: Severity?
    }

    // MARK: - The pet

    static func drawPet(_ pose: PetBody, frame: PetFrame, _ look: Look, in context: inout GraphicsContext) {
        let pal = look.palette
        let g = PetBodyGeometry(pose)
        let body = g.outline()
        var ctx = context
        ctx.opacity *= PetEase.clamp01(pose.opacity)
        let light = PetCurve.clamp(pose.fullness, 0, 1.25)
        let emissive = pose.glow * (0.22 + 0.78 * light)

        if !look.motion.reduceTransparency {
            drawGlow(g, emissive: emissive, look, in: &ctx)
        }
        drawFeet(g, pal, in: &ctx)
        drawArms(g, front: false, pal, in: &ctx)
        drawBodyFill(g, body: body, look, in: &ctx)
        let visibility = g.faceVisibility
        if visibility > 0.001 {
            var face = ctx
            face.opacity *= visibility
            face.clip(to: body)
            drawCheeks(g, pal, in: &face)
            drawEyes(g, pal, in: &face)
            drawBrows(g, pal, in: &face)
            drawMouth(g, pal, in: &face)
        }
        drawArms(g, front: true, pal, in: &ctx)
        if pose.flash > 0.001 {
            var flare = ctx
            flare.blendMode = .plusLighter
            flare.clip(to: body)
            flare.fill(body, with: .color(pal.flare.color(opacity: 0.42 * pose.flash)))
        }
        if look.motion.increaseContrast {
            ctx.stroke(body, with: .color(pal.rim.color(opacity: PetTuning.Light.contrastOutlineOpacity)),
                       lineWidth: PetTuning.Light.contrastOutlineWidth * g.s)
        }
        if let edge = frame.denEdge {
            // Going behind the camera: the side of the pet next to the notch falls into its shadow.
            var shade = ctx
            shade.clip(to: g.outline(inflate: 1.5 * g.s, samples: 28))
            let x0 = Double(edge) - 6 * g.s
            shade.fill(Path(CGRect(x: x0, y: g.base.y - 40 * g.s, width: 6 * g.s, height: 48 * g.s)),
                       with: .linearGradient(Gradient(colors: [.black.opacity(0), .black.opacity(0.6)]),
                                             startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: Double(edge), y: 0)))
        }
    }

    // MARK: Light around the pet

    /// The halo and the light on the floor. Both fade past the readouts' edges: whatever reaches a digit
    /// stays under `PetTuning.Light.glowAtReadout`, so the pet never washes out a number.
    static func drawGlow(_ g: PetBodyGeometry, emissive: Double, _ look: Look, in ctx: inout GraphicsContext) {
        let pal = look.palette
        let e = ellipse(g)
        let spread = 15.0 * g.s
        var halo = emissive * pal.glowGain
        // The floor light: a flat ellipse under the feet, fading as the feet leave the floor.
        let contact = exp(-g.body.lift / (5 * g.s))
        let floorWidth = g.halfWidth * 2.9, floorHeight = 7.0 * g.s
        let floorCentre = CGPoint(x: g.base.x + g.body.lean * g.height * 0.2, y: g.body.floorY + 0.6 * g.s)
        var floor = 0.30 * emissive * contact * pal.glowGain

        // What each would put on the nearest readout pixel, as a share of its own peak.
        var reach = 0.0
        for guardX in [look.guardMinX, look.guardMaxX].compactMap({ $0 }) {
            let gx = Double(guardX)
            reach = max(reach, halo * haloFalloff(abs(gx - e.c.x) / (e.rx + spread), k: e.rx / (e.rx + spread))
                        + floor * floorFalloff(abs(gx - floorCentre.x) / (floorWidth / 2)))
        }
        let limit = PetTuning.Light.glowAtReadout * 0.85
        if reach > limit {
            let cut = limit / reach
            halo *= cut
            floor *= cut
        }

        if floor > 0.004 {
            var l = ctx
            l.translateBy(x: floorCentre.x, y: floorCentre.y)
            l.scaleBy(x: 1, y: floorHeight / floorWidth)
            l.fill(Path(ellipseIn: CGRect(x: -floorWidth / 2, y: -floorWidth / 2, width: floorWidth, height: floorWidth)),
                   with: .radialGradient(Gradient(stops: [.init(color: pal.glow.color(opacity: floor), location: 0),
                                                          .init(color: pal.glow.color(opacity: floor * 0.35), location: 0.5),
                                                          .init(color: pal.glow.color(opacity: 0), location: 1)]),
                                         center: .zero, startRadius: 0, endRadius: floorWidth / 2))
        }
        if halo > 0.004 {
            let k = e.rx / (e.rx + spread)
            softEllipse(&ctx, centre: e.c, rx: e.rx + spread, ry: e.ry + spread * 0.85, angle: g.body.tilt,
                        color: pal.glow, stops: haloStops(k).map { ($0.0, $0.1 * halo) })
        }
    }

    /// Everything the body's light can touch: the halo's ellipse (turned with the body) and the floor light.
    static func lightBox(_ g: PetBodyGeometry) -> CGRect {
        let e = ellipse(g)
        let spread = 15.0 * g.s
        let rx = e.rx + spread, ry = e.ry + spread * 0.85
        let c = cos(g.body.tilt), sn = sin(g.body.tilt)
        let hx = (rx * rx * c * c + ry * ry * sn * sn).squareRoot(), hy = (rx * rx * sn * sn + ry * ry * c * c).squareRoot()
        let halo = CGRect(x: e.c.x - hx, y: e.c.y - hy, width: 2 * hx, height: 2 * hy)
        let floorWidth = g.halfWidth * 2.9, floorHeight = 7.0 * g.s
        let floor = CGRect(x: g.base.x + g.body.lean * g.height * 0.2 - floorWidth / 2,
                           y: g.body.floorY + 0.6 * g.s - floorHeight / 2, width: floorWidth, height: floorHeight)
        return halo.union(floor).insetBy(dx: -1, dy: -1)
    }

    /// The halo's opacity stops over its normalised radius, from the body's centre out. `k` is where the
    /// body's own edge falls.
    static func haloStops(_ k: Double) -> [(Double, Double)] {
        let r = 1 - k
        return [(0, 0.6), (k, 0.42), (k + r * 0.12, 0.24), (k + r * 0.3, 0.1), (k + r * 0.6, 0.035), (1, 0)]
    }

    /// The halo's opacity at normalised radius `u`, as a share of its peak: the stops, interpolated as
    /// the gradient interpolates them.
    static func haloFalloff(_ u: Double, k: Double) -> Double {
        piecewise(u, haloStops(k))
    }

    static func floorFalloff(_ u: Double) -> Double {
        piecewise(u, [(0, 1), (0.5, 0.35), (1, 0)])
    }

    static func piecewise(_ u: Double, _ stops: [(Double, Double)]) -> Double {
        guard u < 1 else { return 0 }
        guard u > 0 else { return stops[0].1 }
        for i in 1..<stops.count where u <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            return PetCurve.mix(a.1, b.1, (u - a.0) / max(b.0 - a.0, 1e-9))
        }
        return 0
    }

    /// An elliptical radial gradient: the cheap stand-in for a blurred shape. `region`, when given, is
    /// filled instead of the ellipse (the gradient pads past its last stop).
    static func softEllipse(_ ctx: inout GraphicsContext, centre c: CGPoint, rx: Double, ry: Double, angle: Double = 0,
                            color: PetRGB, stops: [(Double, Double)], region: Path? = nil) {
        guard rx > 0.01, ry > 0.01 else { return }
        var l = ctx
        l.translateBy(x: c.x, y: c.y)
        if angle != 0 { l.rotate(by: .radians(angle)) }
        l.scaleBy(x: 1, y: ry / rx)
        let shape: Path
        if let region {
            let local = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).scaledBy(x: 1, y: ry / rx)
            shape = region.applying(local.inverted())
        } else {
            shape = Path(ellipseIn: CGRect(x: -rx, y: -rx, width: 2 * rx, height: 2 * rx))
        }
        l.fill(shape, with: .radialGradient(Gradient(stops: stops.map { .init(color: color.color(opacity: $0.1), location: $0.0) }),
                                            center: .zero, startRadius: 0, endRadius: rx))
    }

    /// The body's centre and radii, for the gradient stand-ins.
    static func ellipse(_ g: PetBodyGeometry) -> (c: CGPoint, rx: Double, ry: Double) {
        let lo = g.point(u: 0, v: -1), hi = g.point(u: 0, v: 1)
        return (CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2), g.halfWidth, g.height / 2)
    }

    // MARK: Body

    static func drawFeet(_ g: PetBodyGeometry, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        for side in [-1.0, 1.0] {
            let f = g.foot(side)
            guard f.height > 0.2 else { continue }
            let rect = CGRect(x: f.centre.x - f.width / 2, y: f.centre.y - f.height / 2, width: f.width, height: f.height)
            ctx.fill(Path(ellipseIn: rect),
                     with: .linearGradient(Gradient(colors: [pal.limb.color(), pal.limbDark.color()]),
                                           startPoint: CGPoint(x: f.centre.x, y: rect.minY),
                                           endPoint: CGPoint(x: f.centre.x, y: rect.maxY)))
        }
    }

    static func drawBodyFill(_ g: PetBodyGeometry, body: Path, _ look: Look, in ctx: inout GraphicsContext) {
        let pal = look.palette
        let s = g.s, p = g.body
        let centre = g.point(u: -0.12, v: 0.05)
        // The empty shell.
        ctx.fill(body, with: .radialGradient(Gradient(colors: [pal.dimCore.color(), pal.dimEdge.color()]),
                                             center: centre, startRadius: 0, endRadius: g.halfWidth * 1.25))
        var inside = ctx
        inside.clip(to: body)

        // The light: a liquid level that stays level with the world and sloshes. 0 puts its surface at
        // the bottom, 1 just under the crown, above 1 overfull.
        let bottom = g.scene(0, g.feet).y
        let top = g.scene(0, g.feet + g.height).y
        let level = PetCurve.mix(bottom + 1.5 * s, top - 3.5 * s, PetCurve.clamp(p.fullness, 0, 1.25))
        let x0 = g.base.x - 3 * g.halfWidth, x1 = g.base.x + 3 * g.halfWidth
        var surface: [CGPoint] = []
        surface.reserveCapacity(25)
        for i in 0...24 {
            let x = PetCurve.mix(x0, x1, Double(i) / 24)
            let dx = x - g.base.x
            surface.append(CGPoint(x: x, y: level + tan(p.slosh) * dx + p.wave * s * sin(dx / g.halfWidth * 2.4 + p.wavePhase)))
        }
        let belly = g.point(u: -0.1, v: -0.35)
        inside.fill(body, with: .radialGradient(Gradient(colors: [pal.lightCore.color(), pal.lightMid.color(), pal.lightEdge.color()]),
                                                center: belly, startRadius: 0, endRadius: g.halfWidth * 1.35))
        // The empty shell laid back over the light above its surface, fading in over a few points, so
        // the edge is soft without a blur.
        var shell = Path()
        shell.move(to: CGPoint(x: x0, y: top - 30 * s))
        for q in surface { shell.addLine(to: q) }
        shell.addLine(to: CGPoint(x: x1, y: top - 30 * s))
        shell.closeSubpath()
        let n = CGPoint(x: sin(p.slosh), y: -cos(p.slosh))
        let from = CGPoint(x: g.base.x - n.x * 0.6 * s, y: level - n.y * 0.6 * s - 0.6 * s)
        let span = 4.2 * s * 2.6
        inside.fill(shell, with: .linearGradient(
            Gradient(stops: [.init(color: pal.dimCore.color(opacity: 0), location: 0),
                             .init(color: pal.dimCore.color(opacity: 0.8), location: 0.5),
                             .init(color: pal.dimCore.color(opacity: 1), location: 0.75),
                             .init(color: pal.dimEdge.color(opacity: 1), location: 1)]),
            startPoint: from, endPoint: CGPoint(x: from.x + n.x * span, y: from.y + n.y * span)))

        // The swallowed bite: the food's light, in its dot's colour, dropping through the body into the light.
        // It shows from the throat down, below the mouth, so the mouth never glows green or red; it leaves
        // at once and falls faster as it goes, a drop with a push behind it, and the tint stays faint: the
        // white core is what the eye follows.
        if p.lump >= 0 && p.lump <= 1 {
            let throat = g.facePoint(dTheta: 0, dv: -0.62).p
            let to = CGPoint(x: g.base.x, y: max(level + 1.5 * s, g.point(u: 0, v: -0.6).y))
            let k = 0.4 * p.lump + 0.6 * p.lump * p.lump
            let c = CGPoint(x: PetCurve.mix(throat.x, to.x, k), y: PetCurve.mix(throat.y, to.y, k))
            let r = 3.0 * s
            let o = PetCurve.ramp(p.lump, 0, 0.12) * (1 - PetCurve.ramp(p.lump, 0.85, 1))
            let tint = dotColor(look.foodDot)
            let tinted = o * PetEase.clamp01(p.lumpTint)
            if tinted > 0.001 {
                inside.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.85, width: 2 * r, height: 1.7 * r)),
                            with: .radialGradient(Gradient(stops: [.init(color: tint.opacity(0.38 * tinted), location: 0),
                                                                   .init(color: tint.opacity(0.2 * tinted), location: 0.45),
                                                                   .init(color: tint.opacity(0), location: 1)]),
                                                  center: c, startRadius: 0, endRadius: r))
            }
            var hot = inside
            hot.blendMode = .plusLighter
            let core = 1.1 * s
            hot.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.9 * o), .white.opacity(0)]),
                                           center: c, startRadius: 0, endRadius: core))
        }
        // Volume: the edge of a self-lit jelly is thinner, so darker.
        let e = ellipse(g)
        softEllipse(&inside, centre: e.c, rx: e.rx, ry: e.ry * 1.02, angle: p.tilt, color: pal.shade,
                    stops: [(0, 0), (0.64, 0), (0.83, 0.18), (0.94, 0.45), (1, 0.6)], region: body)
        // Rim light along the top, a soft specular on the dome and its hot spot.
        let rimTop = g.point(u: -0.2, v: 1.0), rimMid = g.point(u: 0, v: 0.1)
        let rimOpacity = look.motion.increaseContrast ? PetTuning.Light.contrastRimOpacity / 0.35 * 0.9 : 0.9
        inside.stroke(body, with: .linearGradient(Gradient(colors: [pal.rim.color(opacity: rimOpacity), pal.rim.color(opacity: 0)]),
                                                  startPoint: rimTop, endPoint: rimMid), lineWidth: 1.5 * s)
        if look.motion.increaseContrast {
            // Increase Contrast: the rim goes all the way round.
            inside.stroke(body, with: .color(pal.rim.color(opacity: PetTuning.Light.contrastRimOpacity)), lineWidth: 1.0 * s)
        }
        if let source = look.foodSource {
            // A trace of the food source's dot on the rim nearest it, as if the number lit the pet.
            let near = g.point(u: Double(source.x) < g.base.x ? -1 : 1, v: 0.1)
            let tint = dotColor(look.foodDot)
            inside.stroke(body, with: .radialGradient(Gradient(colors: [tint.opacity(PetTuning.Light.dotTint * 4), tint.opacity(0)]),
                                                      center: near, startRadius: 0, endRadius: g.halfWidth * 1.2),
                          lineWidth: 1.4 * s)
        }
        let sheen = g.point(u: -0.46, v: 0.62)
        softEllipse(&inside, centre: sheen, rx: 2.5 * s, ry: 1.45 * s, angle: -0.55 + p.tilt, color: PetRGB(red: 1, green: 1, blue: 1),
                    stops: [(0, 0.55), (0.5, 0.45), (0.8, 0.15), (1, 0)])
        let hotSpot = g.point(u: -0.54, v: 0.67)
        inside.fill(Path(ellipseIn: CGRect(x: hotSpot.x - 0.5 * s, y: hotSpot.y - 0.5 * s, width: s, height: s)),
                    with: .color(.white.opacity(0.75)))
    }

    /// `EarsView.color(for:)`'s colours: the status dot the food came from.
    static func dotColor(_ severity: Severity?) -> Color {
        switch severity {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        case nil: return .gray
        }
    }

    static func drawCheeks(_ g: PetBodyGeometry, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        let s = g.s, p = g.body
        let o = 0.5 * PetCurve.clamp(p.blush, 0, 1.2)
        guard o > 0.01 else { return }
        for side in [-1.0, 1.0] {
            let f = g.facePoint(dTheta: side * 0.76, dv: -0.21)
            let puff = 1 + 0.3 * p.cheekPuff * (1 + 0.5 * p.cheekBias * side)
            let w = 3.2 * s * f.fx * puff, h = 1.9 * s * puff
            let oo = o * max(0, f.fx) * PetCurve.ramp(f.fx, 0.04, 0.32)
            guard oo > 0.003 else { continue }
            softEllipse(&ctx, centre: f.p, rx: w * 0.62 + 0.6 * s, ry: h * 0.62 + 0.6 * s, color: pal.blush,
                        stops: [(0, oo), (0.45, 0.85 * oo), (0.75, 0.35 * oo), (1, 0)])
        }
    }

    // MARK: Face

    static func drawEyes(_ g: PetBodyGeometry, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        let s = g.s, p = g.body
        for side in [-1.0, 1.0] {
            let (c, fx) = g.eye(side)
            let w = 3.3 * s * p.eyeSize * g.featureScaleX * max(0.25, fx)
            let h = 4.5 * s * p.eyeSize * g.featureScaleY
            // A wink closes one eye alone into the happy arc: it holds open the lid the arc is drawn for.
            let wink = PetEase.clamp01(side < 0 ? p.winkL : p.winkR)
            let lid = max(PetEase.clamp01(side < 0 ? p.lidL : p.lidR), wink)
            // Each feature fades as it turns away round the dome.
            var e = ctx
            e.opacity *= PetCurve.ramp(fx, 0.04, 0.32)
            guard e.opacity > 0.001 else { continue }
            drawEye(centre: c, w: w, h: h, lid: lid, slant: p.lidSlant, happy: max(PetEase.clamp01(p.happy), wink),
                    squeeze: PetEase.clamp01(p.squeeze), side: side, tilt: p.tilt, s: s, shine: PetEase.clamp01(p.shine),
                    pal, in: &e)
        }
    }

    /// Between these values of `happy` the bean eye and the happy arc cross-fade: the rig takes `happy`
    /// across it in a frame or two, never holding it there.
    static let happyBand: ClosedRange<Double> = 0.5...0.72

    static func drawEye(centre c: CGPoint, w: Double, h: Double, lid: Double, slant: Double, happy: Double, squeeze: Double,
                        side: Double, tilt: Double, s: Double, shine: Double = 0, _ pal: PetPalette.Colors,
                        in ctx: inout GraphicsContext) {
        let ink = pal.ink.color()
        let lineWidth = 1.15 * s
        // Four drawings, cross-faded so nothing pops. The lid's edge reaches 0.3 h, where the shut line
        // is drawn, at lid 0.2: the cross-fade happens where the two drawings coincide.
        let wSqueeze = PetCurve.ramp(squeeze, 0.35, 0.6)
        let wClosed = (1 - wSqueeze) * (1 - PetCurve.ramp(lid, 0.1, 0.24))
        let wHappy = (1 - wSqueeze) * (1 - wClosed) * PetCurve.ramp(happy, happyBand.lowerBound, happyBand.upperBound)
        let wBean = max(0, 1 - wSqueeze - wClosed - wHappy)

        var e = ctx
        e.translateBy(x: c.x, y: c.y)
        e.rotate(by: .radians(tilt))

        if wBean > 0.001 {
            var b = e
            b.opacity *= wBean
            let eye = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            // The top lid comes down as a curve that follows the eyeball; `slant` drops its outer end.
            // For a happy squint the bottom lid rises instead.
            let lidY = -h / 2 + (1 - lid) * h
            let slope = 0.42 * slant * (1 - 0.4 * (1 - lid))
            let bow = 0.45 * s * (1 - lid) + 0.1 * s
            func lidEdge(_ x: Double) -> Double { lidY + slope * x * side }
            var visible = Path()
            visible.move(to: CGPoint(x: -w, y: lidEdge(-w)))
            visible.addQuadCurve(to: CGPoint(x: w, y: lidEdge(w)), control: CGPoint(x: 0, y: lidY + 2 * bow))
            visible.addLine(to: CGPoint(x: w, y: h))
            visible.addLine(to: CGPoint(x: -w, y: h))
            visible.closeSubpath()
            if lid < 0.995 || abs(slant) > 0.01 { b.clip(to: visible) }
            if happy > 0.001 {
                let rise = happy * h * 0.95
                let r = w * 1.05
                b.clip(to: Path(ellipseIn: CGRect(x: -r, y: h / 2 - rise, width: 2 * r, height: 2 * r)), options: .inverse)
            }
            b.fill(eye, with: .color(ink))
            // Catchlights: the big one up and toward the light, a small one opposite. Shining, both grow and a
            // third pin of light comes on, high on the far side, never at the lower rim where a spot of light
            // could read as a tear.
            let big = 0.62 * s * min(1, w / (3.3 * s) + 0.15) * (1 + 0.32 * shine)
            b.fill(Path(ellipseIn: CGRect(x: w * 0.12 - big, y: -h * 0.26 - big, width: 2 * big, height: 2 * big)),
                   with: .color(.white.opacity(0.95)))
            let small = 0.3 * s * (1 + 0.32 * shine)
            b.fill(Path(ellipseIn: CGRect(x: -w * 0.2 - small, y: h * 0.2 - small, width: 2 * small, height: 2 * small)),
                   with: .color(.white.opacity(0.7 + 0.2 * shine)))
            if shine > 0.01 {
                let pin = 0.2 * s * shine
                b.fill(Path(ellipseIn: CGRect(x: w * 0.26 - pin, y: h * 0.02 - pin, width: 2 * pin, height: 2 * pin)),
                       with: .color(.white.opacity(0.85 * shine)))
            }
            if lid < 0.97 {
                // The lid's edge, a little wider than the eye where it crosses it.
                let halfW = w / 2 * max(0, 1 - pow(2 * lidY / h, 2)).squareRoot() + 0.45 * s
                var lp = Path()
                lp.move(to: CGPoint(x: -halfW, y: lidEdge(-halfW) + bow * 0.25))
                lp.addQuadCurve(to: CGPoint(x: halfW, y: lidEdge(halfW) + bow * 0.25), control: CGPoint(x: 0, y: lidY + 1.6 * bow))
                var lc = e
                lc.opacity *= wBean * PetCurve.ramp(1 - lid, 0.03, 0.15)
                lc.stroke(lp, with: .color(ink), style: StrokeStyle(lineWidth: 1.0 * s, lineCap: .round))
            }
        }
        if wClosed > 0.001 {
            // Shut: a soft downward bow.
            var l = e
            l.opacity *= wClosed
            var path = Path()
            let y0 = h * 0.24 + 0.42 * slant * w * 0.3
            path.move(to: CGPoint(x: -w * 0.62, y: y0 + 0.42 * slant * (-w * 0.62) * side * 0.6))
            path.addQuadCurve(to: CGPoint(x: w * 0.62, y: y0 + 0.42 * slant * (w * 0.62) * side * 0.6),
                              control: CGPoint(x: 0, y: h * 0.5))
            l.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        if wHappy > 0.001 {
            // Happy: an upward arc.
            var l = e
            l.opacity *= wHappy
            var path = Path()
            path.move(to: CGPoint(x: -w * 0.62, y: h * 0.12))
            path.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.12), control: CGPoint(x: 0, y: -h * 0.42))
            l.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth * 1.05, lineCap: .round))
        }
        if wSqueeze > 0.001 {
            // Squeezed shut with effort: a chevron pointing at the nose.
            var l = e
            l.opacity *= wSqueeze
            let d = -side
            var path = Path()
            path.move(to: CGPoint(x: -d * w * 0.55, y: -h * 0.3))
            path.addLine(to: CGPoint(x: d * w * 0.45, y: 0))
            path.addLine(to: CGPoint(x: -d * w * 0.55, y: h * 0.3))
            l.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    static func drawBrows(_ g: PetBodyGeometry, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        let s = g.s, p = g.body
        // Below scale 1 the brows grow a little bolder: at 0.80 and 0.82 they carry the face, since at that
        // size the angle of the brows is what still shows the mood.
        let bold = 1 + 0.25 * PetCurve.clamp((1 - s) / 0.2, 0, 1)
        for side in [-1.0, 1.0] {
            let f = g.facePoint(dTheta: side * 0.40, dv: 0.40)
            let lift = (side < 0 ? p.browLiftL : p.browLiftR) * s
            let tiltIn = side < 0 ? p.browTiltL : p.browTiltR
            let length = 5.0 * s * max(0.3, f.fx) * g.featureScaleX
            let c = CGPoint(x: f.p.x, y: f.p.y - lift)
            let inward = -side
            let angle = tiltIn + p.tilt * inward
            let dx = cos(angle) * length / 2, dy = sin(angle) * length / 2
            let inner = CGPoint(x: c.x + inward * dx, y: c.y - dy)
            let outer = CGPoint(x: c.x - inward * dx, y: c.y + dy + 0.35 * s)
            let arch = (0.75 - 0.9 * max(0, tiltIn)) * s
            let control = CGPoint(x: (inner.x + outer.x) / 2, y: (inner.y + outer.y) / 2 - arch)
            // A brush stroke: thick at the inner end, tapering outward, round at both ends.
            let thick = g.featureScaleY * s * bold
            ctx.fill(taperedStroke(from: outer, control: control, to: inner, w0: 0.6 * thick, w1: 1.02 * thick),
                     with: .color(pal.ink.color(opacity: PetCurve.ramp(f.fx, 0.04, 0.32))))
        }
    }

    /// A quadratic curve outlined with a half-width going from `w0` to `w1`, with round caps.
    static func taperedStroke(from a: CGPoint, control c: CGPoint, to b: CGPoint, w0: Double, w1: Double) -> Path {
        let n = 12
        func q(_ u: Double) -> CGPoint {
            let v = 1 - u
            return CGPoint(x: v * v * a.x + 2 * v * u * c.x + u * u * b.x, y: v * v * a.y + 2 * v * u * c.y + u * u * b.y)
        }
        func d(_ u: Double) -> CGPoint {
            let x = 2 * (1 - u) * (c.x - a.x) + 2 * u * (b.x - c.x), y = 2 * (1 - u) * (c.y - a.y) + 2 * u * (b.y - c.y)
            let l = max(hypot(x, y), 1e-6)
            return CGPoint(x: x / l, y: y / l)
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...n {
            let u = Double(i) / Double(n)
            let p = q(u), t = d(u), normal = CGPoint(x: -t.y, y: t.x)
            let w = PetCurve.mix(w0, w1, u)
            left.append(CGPoint(x: p.x + normal.x * w, y: p.y + normal.y * w))
            right.append(CGPoint(x: p.x - normal.x * w, y: p.y - normal.y * w))
        }
        var path = Path()
        path.move(to: left[0])
        for pt in left.dropFirst() { path.addLine(to: pt) }
        let tb = d(1), nb = CGPoint(x: -tb.y, y: tb.x)
        for k in 1..<8 {
            let phi = Double.pi * Double(k) / 8
            path.addLine(to: CGPoint(x: b.x + w1 * (cos(phi) * nb.x + sin(phi) * tb.x), y: b.y + w1 * (cos(phi) * nb.y + sin(phi) * tb.y)))
        }
        for pt in right.reversed() { path.addLine(to: pt) }
        let ta = d(0), na = CGPoint(x: -ta.y, y: ta.x)
        for k in 1..<8 {
            let phi = Double.pi * Double(k) / 8
            path.addLine(to: CGPoint(x: a.x + w0 * (-cos(phi) * na.x - sin(phi) * ta.x), y: a.y + w0 * (-cos(phi) * na.y - sin(phi) * ta.y)))
        }
        path.closeSubpath()
        return path
    }

    static func drawMouth(_ g: PetBodyGeometry, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        let s = g.s, p = g.body
        let f = g.mouth
        let open = PetCurve.clamp(p.mouthOpen, 0, 1.2)
        let w = (3.4 + 6.2 * open) * s * p.mouthWide * max(0.35, f.fx) * g.featureScaleX
        let depth = 6.6 * open * s * g.featureScaleY
        let smileK = p.smile * 1.25 * s * (1 - 0.55 * min(1, open))
        var m = ctx
        m.opacity *= PetCurve.ramp(f.fx, 0.04, 0.32)
        m.translateBy(x: f.p.x, y: f.p.y)
        m.rotate(by: .radians(p.tilt))
        let left = CGPoint(x: -w / 2, y: -smileK), right = CGPoint(x: w / 2, y: -smileK)
        let lineWidth = 1.05 * s
        let ink = pal.ink.color()
        if open < 0.035 {
            var path = Path()
            if p.chew > 0.01 {
                // A working mouth: the line ripples.
                for i in 0...10 {
                    let u = Double(i) / 10
                    let x = PetCurve.mix(left.x, right.x, u)
                    let y = -smileK + 4 * smileK * u * (1 - u) + p.chew * 0.6 * s * sin(u * 2 * .pi + p.chewPhase)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            } else {
                path.move(to: left)
                path.addQuadCurve(to: right, control: CGPoint(x: 0, y: smileK))
            }
            m.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        } else {
            var path = Path()
            path.move(to: left)
            path.addQuadCurve(to: right, control: CGPoint(x: 0, y: -smileK * 0.35 - depth * 0.14))
            path.addCurve(to: left, control1: CGPoint(x: right.x - w * 0.06, y: right.y + depth * 1.33),
                          control2: CGPoint(x: left.x + w * 0.06, y: left.y + depth * 1.33))
            path.closeSubpath()
            m.fill(path, with: .color(pal.mouth.color()))
            var t = m
            t.clip(to: path)
            let ty = -smileK + depth * 0.95
            t.fill(Path(ellipseIn: CGRect(x: -w * 0.24, y: ty - depth * 0.32, width: w * 0.48, height: depth * 0.6)),
                   with: .color(pal.tongue.color()))
            m.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth * 0.85, lineJoin: .round))
        }
        if p.tongue > 0.01 {
            // A lick at the corner nearest the food.
            let corner = p.turn <= 0 ? left : right
            let dir = p.turn <= 0 ? -1.0 : 1.0
            let k = p.tongue
            let c = CGPoint(x: corner.x + dir * 0.7 * s * k, y: corner.y + 0.55 * s)
            let tw = 1.9 * s * k, th = 1.5 * s * k
            m.fill(Path(ellipseIn: CGRect(x: c.x - tw / 2, y: c.y - th / 2, width: tw, height: th)), with: .color(pal.tongue.color()))
        }
    }

    // MARK: Arms

    static func drawArms(_ g: PetBodyGeometry, front: Bool, _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        let s = g.s
        for side in [-1.0, 1.0] {
            let a = g.arm(side)
            guard a.front == front else { continue }
            var l = ctx
            l.translateBy(x: a.centre.x, y: a.centre.y)
            l.rotate(by: .radians(a.angle))
            let arm = Path(ellipseIn: CGRect(x: -a.length / 2, y: -a.thickness / 2, width: a.length, height: a.thickness))
            l.fill(arm, with: .linearGradient(Gradient(colors: [pal.lightMid.color(), pal.limb.color(), pal.limbDark.color()]),
                                              startPoint: CGPoint(x: 0, y: -a.thickness / 2), endPoint: CGPoint(x: 0, y: a.thickness / 2)))
            // A soft dark edge, so an arm reads against the bright body when it crosses it.
            l.stroke(arm, with: .color(pal.shade.color(opacity: 0.42)), lineWidth: limbEdge * s)
            if let thumb = g.thumb(side) { drawThumb(thumb, s: s, pal, in: &ctx) }
        }
    }

    /// A thumbs-up's thumb: a capsule standing up off the end of a raised nub, the way a nub would make
    /// the gesture, in the arm's own gradient and with its soft edge. It grows in with the gesture.
    static func drawThumb(_ t: (centre: CGPoint, width: Double, height: Double, angle: Double, amount: Double), s: Double,
                          _ pal: PetPalette.Colors, in ctx: inout GraphicsContext) {
        var l = ctx
        l.opacity *= PetCurve.ramp(t.amount, 0, 0.35)
        l.translateBy(x: t.centre.x, y: t.centre.y)
        l.rotate(by: .radians(t.angle))
        let shape = Path(roundedRect: CGRect(x: -t.width / 2, y: -t.height / 2, width: t.width, height: t.height),
                         cornerRadius: t.width / 2)
        l.fill(shape, with: .linearGradient(Gradient(colors: [pal.lightMid.color(), pal.limb.color(), pal.limbDark.color()]),
                                            startPoint: CGPoint(x: -t.width / 2, y: 0), endPoint: CGPoint(x: t.width / 2, y: 0)))
        l.stroke(shape, with: .color(pal.shade.color(opacity: 0.42)), lineWidth: limbEdge * s)
    }

    /// The width of the soft dark edge stroked round an arm and a thumb, at scale 1.
    static let limbEdge = 0.55

    // MARK: - Particles and the food

    static func tint(_ t: PetParticle.Tint, _ pal: PetPalette.Colors) -> Color {
        switch t {
        case .crumbLight: return pal.crumbLight.color()
        case .crumbWarm: return pal.crumbWarm.color()
        case .sparkle: return pal.sparkle.color()
        case .zzz: return pal.zzz.color()
        case .ring: return pal.ring.color()
        case .rumble: return pal.rumble.color()
        case .bubble: return pal.bubble.color()
        case .burst: return pal.burst.color()
        case .dot(let severity): return dotColor(severity)
        }
    }

    static func drawParticles(_ particles: [PetParticle], opacity: Double, _ look: Look, in ctx: inout GraphicsContext) {
        let pal = look.palette
        for q in particles where q.opacity > 0.003 {
            var c = ctx
            c.opacity *= PetEase.clamp01(opacity)
            let color = tint(q.tint, pal)
            let o = PetEase.clamp01(q.opacity)
            switch q.kind {
            case .crumb:
                c.blendMode = .plusLighter
                let r = q.size
                if abs(q.streak.dx) + abs(q.streak.dy) > 0.3 {
                    var p = Path()
                    p.move(to: CGPoint(x: q.position.x + q.streak.dx, y: q.position.y + q.streak.dy))
                    p.addLine(to: q.position)
                    c.stroke(p, with: .color(color.opacity(o * 0.55)), style: StrokeStyle(lineWidth: r * 1.5, lineCap: .round))
                }
                c.fill(Path(ellipseIn: CGRect(x: q.position.x - r, y: q.position.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color.opacity(o)))
            case .sparkle:
                c.blendMode = .plusLighter
                if !look.motion.reduceTransparency {
                    let halo = q.size * 1.7
                    c.fill(Path(ellipseIn: CGRect(x: q.position.x - halo, y: q.position.y - halo, width: 2 * halo, height: 2 * halo)),
                           with: .radialGradient(Gradient(colors: [color.opacity(0.35 * o), color.opacity(0)]),
                                                 center: q.position, startRadius: 0, endRadius: halo))
                }
                c.translateBy(x: q.position.x, y: q.position.y)
                c.rotate(by: .radians(q.angle))
                c.fill(star(q.size), with: .color(color.opacity(o)))
            case .zzz:
                c.translateBy(x: q.position.x, y: q.position.y)
                c.rotate(by: .radians(q.angle))
                let w = q.size, h = q.size
                var p = Path()
                p.move(to: CGPoint(x: -w / 2, y: -h / 2))
                p.addLine(to: CGPoint(x: w / 2, y: -h / 2))
                p.addLine(to: CGPoint(x: -w / 2, y: h / 2))
                p.addLine(to: CGPoint(x: w / 2, y: h / 2))
                if !look.motion.reduceTransparency {
                    c.stroke(p, with: .color(color.opacity(o * 0.22)),
                             style: StrokeStyle(lineWidth: max(0.8, q.size * 0.2) + 1.4, lineCap: .round, lineJoin: .round))
                }
                c.stroke(p, with: .color(color.opacity(o)),
                         style: StrokeStyle(lineWidth: max(0.8, q.size * 0.2), lineCap: .round, lineJoin: .round))
            case .ring:
                // A soft pulse of light: a radial gradient that is bright only in a band, not a drawn circle.
                c.blendMode = .plusLighter
                let r = q.size
                c.translateBy(x: q.position.x, y: q.position.y)
                c.scaleBy(x: 1, y: 0.82)
                c.fill(Path(ellipseIn: CGRect(x: -r - 1.5, y: -r - 1.5, width: 2 * r + 3, height: 2 * r + 3)),
                       with: .radialGradient(Gradient(stops: [.init(color: color.opacity(0), location: 0),
                                                              .init(color: color.opacity(0), location: 0.62),
                                                              .init(color: color.opacity(o), location: 0.86),
                                                              .init(color: color.opacity(0), location: 1)]),
                                             center: .zero, startRadius: 0, endRadius: r + 1.5))
            case .rumble:
                c.translateBy(x: q.position.x, y: q.position.y)
                c.rotate(by: .radians(q.angle))
                var p = Path()
                p.move(to: CGPoint(x: 0, y: -q.size))
                p.addQuadCurve(to: CGPoint(x: 0, y: q.size), control: CGPoint(x: q.size * 0.7, y: 0))
                c.stroke(p, with: .color(color.opacity(o)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            case .bubble:
                c.blendMode = .plusLighter
                let r = q.size
                c.stroke(Path(ellipseIn: CGRect(x: q.position.x - r, y: q.position.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color.opacity(o)), lineWidth: 0.6)
                c.fill(Path(ellipseIn: CGRect(x: q.position.x - r * 0.45, y: q.position.y - r * 0.6, width: r * 0.5, height: r * 0.5)),
                       with: .color(.white.opacity(o * 0.8)))
            case .mote:
                c.blendMode = .plusLighter
                let r = q.size
                c.fill(Path(ellipseIn: CGRect(x: q.position.x - 2 * r, y: q.position.y - 2 * r, width: 4 * r, height: 4 * r)),
                       with: .radialGradient(Gradient(colors: [color.opacity(o), color.opacity(0.3 * o), color.opacity(0)]),
                                             center: q.position, startRadius: 0, endRadius: 2 * r))
            case .puff:
                // Three soft lobes of breath, a little cloud: gradients only.
                c.blendMode = .plusLighter
                let r = q.size
                for (dx, dy, k) in [(-0.55, 0.18, 0.72), (0.52, 0.22, 0.66), (0.0, -0.22, 0.86)] {
                    let centre = CGPoint(x: q.position.x + dx * r, y: q.position.y + dy * r)
                    let rr = r * k
                    c.fill(Path(ellipseIn: CGRect(x: centre.x - rr, y: centre.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .radialGradient(Gradient(stops: [.init(color: color.opacity(0.8 * o), location: 0),
                                                                  .init(color: color.opacity(0.55 * o), location: 0.45),
                                                                  .init(color: color.opacity(0), location: 1)]),
                                                 center: centre, startRadius: 0, endRadius: rr))
                }
            }
        }
    }

    /// A four-point star of half-span `size`.
    static func star(_ size: Double) -> Path {
        let l = size, w = size * 0.22
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -l))
        p.addQuadCurve(to: CGPoint(x: l, y: 0), control: CGPoint(x: w, y: -w))
        p.addQuadCurve(to: CGPoint(x: 0, y: l), control: CGPoint(x: w, y: w))
        p.addQuadCurve(to: CGPoint(x: -l, y: 0), control: CGPoint(x: -w, y: w))
        p.addQuadCurve(to: CGPoint(x: 0, y: -l), control: CGPoint(x: -w, y: -w))
        return p
    }

    static func drawBead(_ b: PetBead, _ look: Look, in ctx: inout GraphicsContext) {
        let pal = look.palette
        guard b.opacity > 0.003 else { return }
        var g = ctx
        g.blendMode = .plusLighter
        let warm = pal.crumbWarm.color()
        let dot = dotColor(b.dot)
        // The streak: the bead's last few hundredths of a second, thinning and fading.
        var previous = b.position
        let n = Double(max(1, b.trail.count))
        for (k, q) in b.trail.enumerated() {
            let f = 1 - Double(k) / n
            var segment = Path()
            segment.move(to: previous)
            segment.addLine(to: q)
            g.stroke(segment, with: .color(warm.opacity(0.42 * f * f * b.opacity)),
                     style: StrokeStyle(lineWidth: 2 * b.radius * (0.25 + 0.75 * f), lineCap: .round))
            previous = q
        }
        if !look.motion.reduceTransparency {
            let gr = b.radius * 3.6
            g.fill(Path(ellipseIn: CGRect(x: b.position.x - gr, y: b.position.y - gr, width: 2 * gr, height: 2 * gr)),
                   with: .radialGradient(Gradient(colors: [dot.opacity(0.30 * b.opacity), warm.opacity(0.10 * b.opacity), warm.opacity(0)]),
                                         center: b.position, startRadius: 0, endRadius: gr))
        }
        var s = ctx
        s.translateBy(x: b.position.x, y: b.position.y)
        s.rotate(by: .radians(b.angle))
        s.scaleBy(x: b.stretch, y: 1 / b.stretch)
        let r = b.radius
        s.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
               with: .radialGradient(Gradient(colors: [.white.opacity(b.opacity), pal.crumbLight.color().opacity(b.opacity),
                                                       warm.opacity(b.opacity)]),
                                     center: CGPoint(x: -r * 0.25, y: -r * 0.3), startRadius: 0, endRadius: r * 1.1))
    }

    static func drawGlint(_ glint: PetGlint, _ look: Look, in ctx: inout GraphicsContext) {
        guard glint.opacity > 0.003 else { return }
        var c = ctx
        c.blendMode = .plusLighter
        let color = look.palette.sparkle.color()
        if !look.motion.reduceTransparency {
            // Faint: it lies over the digit, and a brighter one greys the black inside the glyph.
            let halo = glint.size * 1.4
            c.fill(Path(ellipseIn: CGRect(x: glint.position.x - halo, y: glint.position.y - halo, width: 2 * halo, height: 2 * halo)),
                   with: .radialGradient(Gradient(colors: [color.opacity(0.10 * glint.opacity), color.opacity(0)]),
                                         center: glint.position, startRadius: 0, endRadius: halo))
        }
        c.translateBy(x: glint.position.x, y: glint.position.y)
        c.rotate(by: .radians(glint.angle))
        c.fill(star(glint.size), with: .color(color.opacity(glint.opacity)))
    }

    static func drawDoorLight(_ door: PetDoorLight, _ look: Look, in ctx: inout GraphicsContext) {
        let pal = look.palette
        let o = door.opacity * pal.glowGain
        guard o > 0.003 else { return }
        let rect = CGRect(x: door.minX, y: door.y, width: door.maxX - door.minX, height: PetTuning.Den.doorLight)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(stops: [.init(color: pal.glow.color(opacity: 0), location: 0),
                                                                    .init(color: pal.glow.color(opacity: o), location: 0.3),
                                                                    .init(color: pal.glow.color(opacity: o), location: 0.7),
                                                                    .init(color: pal.glow.color(opacity: 0), location: 1)]),
                                                   startPoint: CGPoint(x: door.minX, y: door.y), endPoint: CGPoint(x: door.maxX, y: door.y)))
        if !look.motion.reduceTransparency {
            // A faint spill under the line.
            let spill = CGRect(x: door.minX, y: door.y, width: door.maxX - door.minX, height: 3)
            ctx.fill(Path(spill), with: .linearGradient(Gradient(colors: [pal.glow.color(opacity: 0.35 * o), pal.glow.color(opacity: 0)]),
                                                        startPoint: CGPoint(x: 0, y: door.y), endPoint: CGPoint(x: 0, y: door.y + 3)))
        }
    }
}
