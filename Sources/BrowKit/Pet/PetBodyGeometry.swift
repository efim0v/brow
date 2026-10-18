// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI

/// Glim's body in one frame: its size after squash, girth, curl and breath, and the one mapping every
/// part is placed with, so the face, the arms and the light deform with the body. `PetCanvas` draws
/// from it and `PetRig` measures with it, so the box the zone clamp keeps inside the zone is the box
/// that is drawn.
struct PetBodyGeometry {
    let body: PetBody
    /// The scale.
    let s: Double
    /// The body's height and half width, in points.
    let height: Double
    let halfWidth: Double
    /// The parts of the height above and below the body's centre line.
    let top: Double
    let bottom: Double
    /// The body's bottom above the contact point: the feet's height.
    let feet: Double
    /// Superellipse exponents of the dome and of the bottom.
    let nTop: Double
    let nBottom: Double
    /// The contact point in window coordinates.
    let base: CGPoint
    /// The speed stretch about the body's centre: the matrix and the centre it turns about.
    private let smear: (a: Double, b: Double, c: Double, d: Double)?
    private let smearCentre: CGPoint

    /// Glim at scale 1 at rest: a 23 × 20 pt gumdrop on 1.5 pt feet, inside 24 × 22 pt: the room a resting
    /// body has beside the notch.
    static let restHeight = 20.0
    static let restHalfWidth = 11.5
    static let restFeet = 1.5

    init(_ p: PetBody) {
        body = p
        s = p.size
        let sq = max(0.45, p.squash)
        let curl = PetEase.clamp01(p.curl)
        // Curled up asleep the dome flattens and spreads into a low loaf; squash keeps the area on its
        // own, so the loaf's extra width is the posture, not the squash.
        height = Self.restHeight * s * sq * pow(p.girth, 0.35) * (1 - 0.40 * curl)
        halfWidth = Self.restHalfWidth * s * pow(sq, -0.5) * p.girth * (1 + 0.20 * curl)
        bottom = height * 0.42
        top = height * 0.58
        // Lying down, the feet tuck under the body.
        feet = Self.restFeet * s * (1 - 0.8 * curl)
        nTop = 2.15 + 0.5 * curl
        // Squashed against the floor the bottom flattens; in the air it rounds off.
        let airborne = PetCurve.clamp(p.lift / (3 * s), 0, 1)
        nBottom = 2.9 + max(0, 1 - sq) * 7 - 0.5 * airborne + 1.2 * curl
        base = CGPoint(x: p.x, y: p.floorY - p.lift)
        if abs(p.smear - 1) > 1e-9 {
            // R(θ) · diag(k, 1/k) · R(−θ): longer along the travel, thinner across it, area kept.
            let k = p.smear, c = cos(p.smearAngle), sn = sin(p.smearAngle)
            smear = (a: c * c * k + sn * sn / k, b: c * sn * (k - 1 / k),
                     c: c * sn * (k - 1 / k), d: sn * sn * k + c * c / k)
        } else {
            smear = nil
        }
        // The stretch turns about the body's middle, placed without the stretch.
        smearCentre = Self.leanAndTilt(p, base: base, feet: feet, 0, feet + bottom)
    }

    /// Local coordinates (x right, y up from the contact point) to the window, with the lean (a shear
    /// above the feet) and the tilt (about the contact point), before the speed stretch.
    @inline(__always)
    private static func leanAndTilt(_ p: PetBody, base: CGPoint, feet: Double, _ x: Double, _ y: Double) -> CGPoint {
        let xs = x + p.lean * (y - feet)
        let c = cos(p.tilt), sn = sin(p.tilt)
        return CGPoint(x: base.x + xs * c + y * sn, y: base.y - (-xs * sn + y * c))
    }

    /// Local coordinates to the window: the lean, the tilt, then the speed stretch.
    @inline(__always)
    func scene(_ x: Double, _ y: Double) -> CGPoint {
        let p = Self.leanAndTilt(body, base: base, feet: feet, x, y)
        guard let m = smear else { return p }
        let o = smearCentre
        let dx = p.x - o.x, dy = p.y - o.y
        return CGPoint(x: o.x + m.a * dx + m.b * dy, y: o.y + m.c * dx + m.d * dy)
    }

    /// Body-normalised coordinates (u, v in -1 ... 1, v up from the centre line) to local.
    @inline(__always)
    func local(u: Double, v: Double) -> (x: Double, y: Double) {
        (halfWidth * u, feet + bottom + (v >= 0 ? top : bottom) * v)
    }

    @inline(__always)
    func point(u: Double, v: Double) -> CGPoint {
        let l = local(u: u, v: v)
        return scene(l.x, l.y)
    }

    /// The face's height on the body: it slides down a little as the body curls up.
    var faceV: Double { 0.10 + body.nod * 0.16 - 0.10 * PetEase.clamp01(body.curl) }

    /// Features squash with the body, but less, so the face stays readable.
    var featureScaleX: Double { pow(halfWidth / (Self.restHalfWidth * s), 0.55) }
    var featureScaleY: Double { pow(height / (Self.restHeight * s), 0.55) }

    /// A point on the face, painted on the dome: `dTheta` is the angle about the vertical axis from the
    /// face's centre, `dv` the height from it. Returns the point and the horizontal foreshortening there.
    func facePoint(dTheta: Double, dv: Double) -> (p: CGPoint, fx: Double) {
        let theta = body.turn * 0.62 + body.spin + dTheta
        let v = faceV + dv
        let u = sin(theta) * max(0, 1 - 0.55 * v * v).squareRoot()
        return (point(u: u, v: v), cos(theta))
    }

    /// How much of the face is on the visible side: a twirl takes it round the back.
    var faceVisibility: Double { PetCurve.ramp(cos(body.turn * 0.62 + body.spin), -0.4, -0.1) }

    // MARK: - The outline

    /// The outline's sample points, before smoothing. `inflate` grows it.
    func outlinePoints(inflate: Double = 0, samples: Int = 44) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(samples)
        let cheekY = local(u: 0, v: faceV - 0.26).y
        let mouthY = local(u: 0, v: faceV - 0.36).y
        let bellyY = feet + height * 0.22
        // A round belly bulges lowest a third of the way up: the gumdrop sits like a full sack on its feet
        // rather than growing all over.
        let bulgeY = feet + height * 0.3
        let p = body
        for i in 0..<samples {
            let phi = 2 * Double.pi * Double(i) / Double(samples)
            let c = cos(phi), sn = sin(phi)
            let n = sn >= 0 ? nTop : nBottom
            let u = copysign(pow(abs(c), 2 / n), c)
            let v = copysign(pow(abs(sn), 2 / n), sn)
            var (x, y) = local(u: u, v: v)
            let side = x >= 0 ? 1.0 : -1.0
            let edge = u * u
            if p.cheekPuff > 0.001 {
                let amount = p.cheekPuff * (1.7 + 0.9 * p.cheekBias * side) * s
                let g = exp(-pow((y - cheekY) / (0.21 * height), 2))
                x += side * amount * g * edge
            }
            if p.belly > 0.001 {
                let g = exp(-pow((y - bulgeY) / (0.30 * height), 2))
                x += side * 2.3 * s * p.belly * g * (0.3 + 0.7 * edge)
            }
            if p.lump >= 0 && p.lump <= 1 {
                let yl = PetCurve.mix(mouthY, bellyY, PetEase.inQuad(p.lump))
                let g = exp(-pow((y - yl) / (0.12 * height), 2))
                x += side * 1.2 * s * g * edge * sin(.pi * p.lump)
            }
            if abs(p.tremor) > 0.0001 {
                let r = p.tremor * 0.32 * s * cos(3 * phi + 0.6)
                x += r * c
                y += r * sn
            }
            if inflate != 0 {
                x += inflate * c
                y += inflate * sn
            }
            points.append(scene(x, y))
        }
        return points
    }

    /// The outline, smoothed with a closed Catmull-Rom through the samples.
    func outline(inflate: Double = 0, samples: Int = 44) -> Path {
        Self.smoothClosed(outlinePoints(inflate: inflate, samples: samples))
    }

    static func smoothClosed(_ p: [CGPoint]) -> Path {
        var path = Path()
        let n = p.count
        guard n > 3 else { return path }
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Limbs

    /// One arm: an ellipse `length` × `thickness` centred at `centre`, turned by `angle` (clockwise from
    /// +x, y down). `front`: drawn over the body; a twirl carries an arm round the back.
    struct Arm {
        var centre: CGPoint
        var angle: Double
        var length: Double
        var thickness: Double
        var front: Bool
    }

    func arm(_ side: Double) -> Arm {
        let p = body
        let az = side * 1.42 + p.spin
        let u = sin(az)
        let screenSide: Double = u >= 0 ? 1 : -1
        let raise = side < 0 ? p.armL : p.armR
        // Curled up asleep, the arms fold in along the loaf's sides.
        let curl = PetEase.clamp01(p.curl)
        let attach = point(u: u * PetCurve.mix(0.91, 0.78, curl), v: PetCurve.mix(-0.2, -0.35, curl))
        let rest = 0.95 + (1 - abs(u)) * 0.5 + 0.35 * curl
        let theta = screenSide > 0 ? (rest - raise + p.tilt) : (.pi - rest + raise + p.tilt)
        // Raised arms reach: a stretch reads as arms up even at 20 pt.
        let reach = 1 + 0.32 * PetCurve.clamp((raise - 0.4) / 1.3, 0, 1)
        let length = 4.6 * s * reach * (1 - 0.25 * curl)
        let thickness = 2.7 * s
        let centre = CGPoint(x: attach.x + cos(theta) * length * 0.34, y: attach.y + sin(theta) * length * 0.34)
        return Arm(centre: centre, angle: theta, length: length, thickness: thickness, front: cos(az) >= 0)
    }

    /// One foot: an ellipse `width` × `height` (axis-aligned) centred at `centre`.
    func foot(_ side: Double) -> (centre: CGPoint, width: Double, height: Double) {
        let p = body
        let lift = side < 0 ? p.footL : p.footR
        // A round belly sets the feet wider apart.
        let cx = 6.8 * s * p.girth * (1 + 0.16 * p.belly) * sin(side * 0.75 + p.spin) * (1 - 0.15 * PetEase.clamp01(p.curl))
        let cy = 1.45 * s + lift
        let c = scene(cx, cy)
        return (c, 5.6 * s, 3.0 * s * (1 - 0.6 * PetEase.clamp01(p.curl)))
    }

    /// A thumbs-up's thumb on the arm on `side`: a capsule `width` × `height` standing up off the end of the
    /// nub, leaning a hair toward the face, grown in with `amount`. nil while there is none.
    func thumb(_ side: Double) -> (centre: CGPoint, width: Double, height: Double, angle: Double, amount: Double)? {
        let amount = PetEase.clamp01(side < 0 ? body.thumbL : body.thumbR)
        guard amount > 0.01 else { return nil }
        let a = arm(side)
        let tip = CGPoint(x: a.centre.x + cos(a.angle) * a.length * 0.36, y: a.centre.y + sin(a.angle) * a.length * 0.36)
        let width = 0.58 * a.thickness * (0.6 + 0.4 * amount), height = 1.25 * a.thickness * amount
        let inward = a.centre.x > tip.x ? 1.0 : -1.0
        let centre = CGPoint(x: tip.x + inward * 0.1 * a.thickness, y: tip.y - 0.3 * a.thickness - height / 2)
        return (centre, width, height, -0.18 * inward, amount)
    }

    // MARK: - The box

    /// The box of everything the body draws (outline, arms, feet), without the glow or particles. The
    /// zone clamp keeps it inside the zone; the hit test and the zone tests read it. It is measured on the
    /// points the drawn outline goes through, so a bulge between them (a round belly, full cheeks) is not
    /// missed; the arms and the thumb count their soft stroked edge; and it is a little larger still, for
    /// the smoothed curve bowing past its points and the anti-aliased edge of any shape.
    func box() -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        @inline(__always) func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        for q in outlinePoints() { add(q.x, q.y) }
        // Half the arms' stroke lies outside them (`PetCanvas.limbEdge`).
        let edge = PetCanvas.limbEdge / 2 * s
        for side in [-1.0, 1.0] {
            let a = arm(side)
            let c = cos(a.angle), sn = sin(a.angle)
            let ex = abs(c) * a.length / 2 + abs(sn) * a.thickness / 2 + edge
            let ey = abs(sn) * a.length / 2 + abs(c) * a.thickness / 2 + edge
            add(a.centre.x - ex, a.centre.y - ey)
            add(a.centre.x + ex, a.centre.y + ey)
            let f = foot(side)
            add(f.centre.x - f.width / 2, f.centre.y - f.height / 2)
            add(f.centre.x + f.width / 2, f.centre.y + f.height / 2)
            if let t = thumb(side) {
                let ex = abs(cos(t.angle)) * t.width / 2 + abs(sin(t.angle)) * t.height / 2 + edge
                let ey = abs(sin(t.angle)) * t.width / 2 + abs(cos(t.angle)) * t.height / 2 + edge
                add(t.centre.x - ex, t.centre.y - ey)
                add(t.centre.x + ex, t.centre.y + ey)
            }
        }
        let margin = 0.45 * s
        return CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
    }
}
