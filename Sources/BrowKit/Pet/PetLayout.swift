// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// Where the pet may be: its zones, worked out from the same frames and metrics the strip and the panel
/// are drawn with, so a zone cannot drift from what is on screen; and the paths between the strip and the
/// panel. Pure: the controller calls it on every render.
///
/// Window coordinates throughout: points from the top-left corner of `frames.expanded`, y down.
/// `NotchFrames` are Cocoa screen coordinates (y up), converted here.
public enum PetLayout {
    // MARK: - Zones

    /// The zones for one render. `leftWidth` and `rightWidth` are the readouts' width classes,
    /// `rightInitial` whether the right one shows a model initial (it narrows the pill's zone),
    /// `panelTop` is `PanelView`'s top padding (`max(contentTopInset, 14)`), `fiveHour` the frame of the
    /// panel's Overall "5h" figure in window coordinates (nil until reported), `dot` the 5-hour status
    /// dot's severity (nil: grey).
    public static func zones(frames: NotchFrames, leftWidth: PetReadoutWidth, rightWidth: PetReadoutWidth,
                             rightInitial: Bool, showEars: Bool, panelTop: CGFloat, fiveHour: CGRect?,
                             dot: Severity?) -> PetZones {
        let strip = showEars ? stripZone(frames: frames, left: leftWidth, right: rightWidth,
                                         rightInitial: rightInitial, dot: dot) : nil
        return PetZones(strip: strip, panel: panelZone(frames: frames, panelTop: panelTop, fiveHour: fiveHour, dot: dot),
                        notch: frames.notch.map { window($0, in: frames) })
    }

    /// The same from what `NotchPanelController.render()` has at hand: the aggregate behind the readouts.
    public static func zones(frames: NotchFrames, aggregate: LimitsAggregate, showEars: Bool, fiveHour: CGRect?) -> PetZones {
        zones(frames: frames,
              leftWidth: readoutWidth(aggregate.leftEar, hasData: aggregate.hasData),
              rightWidth: readoutWidth(aggregate.rightEar, hasData: aggregate.hasData),
              rightInitial: aggregate.hasData && aggregate.rightEar.modelInitial != nil,
              showEars: showEars, panelTop: max(frames.contentTopInset, PanelView.padding), fiveHour: fiveHour,
              dot: dotSeverity(aggregate.leftEar, hasData: aggregate.hasData))
    }

    /// The width class of what `EarsView` prints for a readout (`PanelText.earsText`).
    public static func readoutWidth(_ ear: EarReadout, hasData: Bool) -> PetReadoutWidth {
        let text = PanelText.earsText(ear, hasData: hasData)
        if text == "—" { return .dash }
        switch text.filter(\.isNumber).count {
        case ...1: return .oneDigit
        case 2: return .twoDigits
        default: return .threeDigits
        }
    }

    /// The colour of the readout's dot: nil for `EarsView`'s grey (stale, or no data).
    public static func dotSeverity(_ ear: EarReadout, hasData: Bool) -> Severity? {
        guard hasData, !ear.stale else { return nil }
        return ear.severity
    }

    static func textWidth(_ w: PetReadoutWidth) -> CGFloat {
        typealias R = PetTuning.Readout
        switch w {
        case .dash: return R.dashWidth
        case .oneDigit: return R.oneDigitWidth
        case .twoDigits: return R.twoDigitWidth
        case .threeDigits: return R.threeDigitWidth
        }
    }

    /// A screen rect (Cocoa) in window coordinates.
    static func window(_ r: CGRect, in frames: NotchFrames) -> CGRect {
        CGRect(x: r.minX - frames.expanded.minX, y: frames.expanded.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The collapsed strip's zone: beside the notch, in the strip below it, or in the pill.
    static func stripZone(frames: NotchFrames, left: PetReadoutWidth, right: PetReadoutWidth, rightInitial: Bool,
                          dot: Severity?) -> PetZone {
        typealias Z = PetTuning.Zone
        typealias M = EarsMetrics
        let gap = PetTuning.Readout.gap
        let strip = window(frames.collapsed, in: frames)
        let leftText = textWidth(left)
        if frames.hasNotch, let notchScreen = frames.notch {
            let notch = window(notchScreen, in: frames)
            switch frames.placement {
            case .beside:
                // The left wing: padding, dot, spacing, then the text hugging the wing's outer edge.
                let wingMinX = notch.minX - frames.earWidth
                let textMinX = wingMinX + M.padding + M.dotSize + M.dotSpacing
                let bounds = CGRect(x: textMinX + leftText + gap, y: strip.minY + Z.edgeInset,
                                    width: notch.minX - (textMinX + leftText + gap), height: notch.height - 2 * Z.edgeInset)
                return PetZone(kind: .beside, bounds: bounds,
                               anchor: CGPoint(x: notch.minX - Z.besideAnchorFromNotch, y: notch.maxY - Z.besideFeetAboveBottom),
                               scale: Z.besideScale, maxStretch: Z.besideMaxStretch, den: .side(edgeX: notch.minX),
                               foodSource: CGPoint(x: textMinX + leftText / 2, y: notch.midY), foodDot: dot)
            case .below:
                // The strip under the notch; the left ear hugs the middle: spacer, dot, text, padding.
                let room = CGRect(x: notch.minX, y: notch.maxY, width: notch.width, height: NotchGeometry.belowStripHeight)
                let textMaxX = notch.midX - M.padding
                let dotMinX = textMaxX - leftText - M.dotSpacing - M.dotSize
                let minX = notch.minX + Z.belowLeftFromNotch
                let bounds = CGRect(x: minX, y: room.minY + Z.edgeInset, width: dotMinX - gap - minX,
                                    height: room.height - 2 * Z.edgeInset)
                return PetZone(kind: .below, bounds: bounds,
                               anchor: CGPoint(x: notch.minX + Z.belowAnchorFromNotch, y: room.maxY - Z.belowFeetAboveBottom),
                               scale: Z.belowScale, maxStretch: Z.belowMaxStretch, den: .overhead(notch),
                               foodSource: CGPoint(x: textMaxX - leftText / 2, y: room.midY), foodDot: dot)
            }
        }
        // The pill: two ears of (pill − 2 × padding) / 2, each readout hugging its outer edge.
        let earMinX = strip.minX + NotchGeometry.pillPadding
        let leftTextMinX = earMinX + M.padding + M.dotSize + M.dotSpacing
        let rightEarMaxX = strip.maxX - NotchGeometry.pillPadding
        let rightTextMaxX = rightEarMaxX - M.padding - M.dotSize - M.dotSpacing
        let rightInk = textWidth(right) + (rightInitial ? PetTuning.Readout.initialWidth + M.initialSpacing : 0)
        let minX = leftTextMinX + leftText + gap
        let maxX = rightTextMaxX - rightInk - gap
        let bounds = CGRect(x: minX, y: strip.minY + Z.edgeInset, width: maxX - minX, height: strip.height - 2 * Z.edgeInset)
        return PetZone(kind: .pill, bounds: bounds,
                       anchor: CGPoint(x: strip.midX, y: strip.maxY - Z.pillFeetAboveBottom),
                       scale: Z.pillScale, maxStretch: Z.pillMaxStretch, den: .none,
                       foodSource: CGPoint(x: leftTextMinX + leftText / 2, y: strip.midY), foodDot: dot)
    }

    /// The panel header's stage: x 14 to 78, the row's top to its bottom, and the black above it up to
    /// the particle ceiling.
    static func panelZone(frames: NotchFrames, panelTop: CGFloat, fiveHour: CGRect?, dot: Severity?) -> PetZone {
        typealias P = PetTuning.Panel
        let stage = CGRect(x: PanelView.padding, y: panelTop, width: P.stageWidth, height: P.stageHeight)
        let bounds = CGRect(x: stage.minX, y: P.particleCeiling, width: stage.width, height: stage.maxY - P.particleCeiling)
        let source = fiveHour.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: frames.expanded.width - 120, y: stage.maxY + 18)
        return PetZone(kind: .panel, bounds: bounds,
                       anchor: CGPoint(x: stage.minX + P.anchorFromStageLeft, y: stage.minY + P.anchorFromStageTop),
                       scale: P.scale, maxStretch: panelMaxStretch, den: .none, foodSource: source, foodDot: dot)
    }

    /// The panel has no stretch limit of its own: it takes the one beside the notch, and the black above
    /// the stage leaves room for it.
    static let panelMaxStretch: CGFloat = PetTuning.Zone.besideMaxStretch

    /// Past these the pet's light stays under 3 %, so a number or a word keeps its own colour: the
    /// readouts' near edges beside and below the zone, and in the panel the header's words.
    static func guards(_ zone: PetZone) -> (min: CGFloat?, max: CGFloat?) {
        let gap = PetTuning.Readout.gap
        switch zone.kind {
        case .beside: return (zone.bounds.minX - gap, nil)
        case .below: return (nil, zone.bounds.maxX + gap)
        case .pill: return (zone.bounds.minX - gap, zone.bounds.maxX + gap)
        case .panel: return (nil, zone.bounds.maxX + PetTuning.Panel.rowSpacing)
        }
    }

    // MARK: - Between the strip and the panel

    /// How long the flight from `a` to `b` takes.
    public static func flightTime(from a: CGPoint, to b: CGPoint) -> TimeInterval {
        typealias H = PetTuning.Hop
        let distance = hypot(b.x - a.x, b.y - a.y)
        return min(max(H.flightBase + H.flightPerPoint * distance, H.flightMinimum), H.flightMaximum)
    }

    /// Where the pet is during a hop or a glide: its feet, its scale, and the stretch of its body.
    struct Flight {
        /// The feet, window coordinates.
        var feet: CGPoint
        var scale: Double
        /// Vertical squash (< 1) or stretch (> 1) of the body, area kept.
        var squash: Double
        /// The speed stretch along the velocity.
        var smear: Double
        var smearAngle: Double
        /// 0 on the ground ... 1 in the air: how much the arms fly up and the feet dangle.
        var airborne: Double
        /// True once the pet stands at the far end and only the landing settles.
        var landed: Bool
    }

    /// The expand hop: a crouch, a ballistic flight from the strip anchor `a` to the header anchor `b`
    /// with the scale eased in, a landing squash and a spring to rest. `tau` is seconds since
    /// `setExpanded(true)`. `stepsOff`: below and on the pill the pet starts at the top of its room and
    /// steps off with no upward speed; beside it rises 3 pt first.
    static func expand(a: CGPoint, b: CGPoint, scaleA: Double, scaleB: Double, stepsOff: Bool, tau: Double) -> Flight {
        typealias H = PetTuning.Hop
        let T = flightTime(from: a, to: b)
        if tau < H.crouch {
            // The crouch: down to 0.88 and back up into the takeoff stretch of 1.06.
            let u = tau / H.crouch
            let down = PetEase.outQuad(min(1, u / 0.6))
            let up = PetEase.inOutSine(max(0, (u - 0.6) / 0.4))
            let squash = PetCurve.mix(PetCurve.mix(1, H.crouchSquash, down), H.takeoffStretch, up)
            return Flight(feet: a, scale: scaleA, squash: squash, smear: 1, smearAngle: 0, airborne: 0, landed: false)
        }
        let t = tau - H.crouch
        if t < T {
            let u = t / T
            let p = ballistic(a: a, b: b, T: T, apex: stepsOff ? nil : H.expandApexBeside, t: t)
            let scale = PetCurve.mix(scaleA, scaleB, PetEase.inCubic(u))
            // The takeoff stretch gives way to the speed stretch along the velocity, which in turn gives
            // way to the landing squash: each hands over smoothly, so nothing pops at either end.
            let takeoff = PetCurve.mix(H.takeoffStretch, 1, PetEase.outQuad(min(1, u / 0.35)))
            let speed = hypot(p.vx, p.vy)
            let smear = 1 + min(H.speedStretchMaximum, speed / H.speedStretchSpeed) * PetCurve.envelope(u, 0, 0.18, 0.8, 1)
            return Flight(feet: p.point, scale: scale, squash: takeoff, smear: smear, smearAngle: atan2(p.vy, p.vx),
                          airborne: PetCurve.envelope(u, 0, 0.25, 0.8, 1), landed: false)
        }
        return landing(at: b, scale: scaleB, squash: H.landingSquash, hold: H.landing, tau: t - T)
    }

    /// The collapse hop, no crouch: x eases out over `collapseX`, y flies over `collapseY` to an apex
    /// just above the strip anchor, the scale eases out so the pet is small before it reaches the strip.
    static func collapse(a: CGPoint, b: CGPoint, scaleA: Double, scaleB: Double, beside: Bool, tau: Double) -> Flight {
        typealias H = PetTuning.Hop
        // Here `b` is the header anchor the pet leaves and `a` the strip anchor it lands on.
        if tau < H.collapseY {
            let ux = min(1, tau / H.collapseX)
            let x = PetCurve.mix(b.x, a.x, PetEase.outCubic(ux))
            let apex = beside ? H.collapseApexBeside : H.collapseApexOther
            let p = ballistic(a: b, b: a, T: H.collapseY, apexAboveEnd: apex, t: tau)
            let scale = PetCurve.mix(scaleB, scaleA, PetEase.outCubic(tau / H.collapseY))
            let dx = ux < 1 ? (a.x - b.x) * 3 * (1 - ux) * (1 - ux) / H.collapseX : 0
            let speed = hypot(dx, p.vy)
            let smear = 1 + min(H.speedStretchMaximum, speed / H.speedStretchSpeed)
                * PetCurve.envelope(tau / H.collapseY, 0, 0.15, 0.8, 1)
            return Flight(feet: CGPoint(x: x, y: p.point.y), scale: scale, squash: 1, smear: smear,
                          smearAngle: atan2(p.vy, dx), airborne: PetCurve.envelope(tau / H.collapseY, 0, 0.2, 0.75, 1),
                          landed: false)
        }
        return landing(at: a, scale: scaleA, squash: H.landingSquash, hold: H.collapseLanding, tau: tau - H.collapseY)
    }

    /// A glide: asleep, drowsy or hibernating, the pet slides along the straight line, its pose kept.
    static func glide(from a: CGPoint, to b: CGPoint, scaleA: Double, scaleB: Double, tau: Double) -> Flight {
        let u = PetEase.inOutCubic(tau / PetTuning.Hop.glide)
        return Flight(feet: CGPoint(x: PetCurve.mix(a.x, b.x, u), y: PetCurve.mix(a.y, b.y, u)),
                      scale: PetCurve.mix(scaleA, scaleB, u), squash: 1, smear: 1, smearAngle: 0, airborne: 0,
                      landed: tau >= PetTuning.Hop.glide)
    }

    /// The landing: a squash held for `hold`, then a springy settle back to 1 (ω 28, ζ 0.45:
    /// `PetTuning.Hop.settleOmega` and `settleZeta`).
    static func landing(at p: CGPoint, scale: Double, squash: Double, hold: Double, tau: Double) -> Flight {
        typealias H = PetTuning.Hop
        let value: Double
        if tau < hold {
            value = PetCurve.mix(1, squash, PetEase.outQuad(tau / (hold * 0.4)))
        } else {
            let spring = PetSpring(omega: H.settleOmega, zeta: H.settleZeta)
            value = 1 - (1 - squash) * spring.stepRemainder(tau - hold)
        }
        return Flight(feet: p, scale: scale, squash: value, smear: 1, smearAngle: 0, airborne: 0, landed: true)
    }

    /// A ballistic arc from `a` to `b` in `T`: x linear, y under constant gravity. `apex`: how far above
    /// `a` it rises (nil: it steps off with no upward speed).
    static func ballistic(a: CGPoint, b: CGPoint, T: Double, apex: Double?, t: Double)
        -> (point: CGPoint, vx: Double, vy: Double) {
        let dy = b.y - a.y
        let v: Double, g: Double
        if let h = apex, h > 0 {
            // Rise h above a, then fall to b: v² = 2gh, and a + vT + gT²/2 = b. With s = vT:
            // s + s²/(4h) = dy, so s = 2h(−1 − √(1 + dy/h)).
            let s = 2 * h * (-1 - (1 + dy / h).squareRoot())
            v = s / T
            g = v * v / (2 * h)
        } else {
            v = 0
            g = 2 * dy / (T * T)
        }
        let vx = (b.x - a.x) / T
        return (CGPoint(x: a.x + vx * t, y: a.y + v * t + 0.5 * g * t * t), vx, v + g * t)
    }

    /// A ballistic arc from `a` (rising) to `b` in `T` whose apex is `apexAboveEnd` above `b`.
    static func ballistic(a: CGPoint, b: CGPoint, T: Double, apexAboveEnd h: Double, t: Double)
        -> (point: CGPoint, vx: Double, vy: Double) {
        // y(t) = a.y + v t + g t²/2, y(T) = b.y, and the lowest y is b.y − h: the same arc as a fall
        // from the apex to b, run backward. Solve for the time of the apex t₁ = T − √(2h/g).
        let dy = b.y - a.y      // negative: it rises
        // From the apex the pet falls h in T − t₁ and rose (b.y − h − a.y) = dy − h in t₁:
        // √(2(h − dy)/g) + √(2h/g) = T, so √(2/g) = T / (√(h − dy) + √h).
        let k = T / ((h - dy).squareRoot() + h.squareRoot())
        let g = 2 / (k * k)
        let t1 = k * (h - dy).squareRoot()
        let v = -g * t1
        let vx = (b.x - a.x) / T
        return (CGPoint(x: a.x + vx * t, y: a.y + v * t + 0.5 * g * t * t), vx, v + g * t)
    }

    // MARK: - The outline the pet flies inside

    /// SwiftUI's `spring(response:dampingFraction:)` stepping from 0 to 1, `tau` seconds after it starts:
    /// how far Brow's outline has opened (or closed) at that instant.
    public static func springProgress(_ tau: Double, response: Double, damping: Double) -> Double {
        guard tau > 0 else { return 0 }
        let spring = PetSpring(omega: 2 * .pi / response, zeta: damping)
        return 1 - spring.stepRemainder(tau)
    }

    /// The visible black of Brow's animated outline at progress `p` (0 collapsed, 1 the panel), window
    /// coordinates: centred in the window, hanging from its top, inside the flares. Collapsed it is what
    /// `NotchRootView.outlineSize` draws: the strip, or with the readouts off the physical notch, and on a
    /// display without a notch nothing at all (the pill's width at no height), so the panel unrolls from
    /// the top edge.
    public static func outline(frames: NotchFrames, progress p: Double, showEars: Bool = true) -> CGRect {
        let collapsed = NotchRootView.outlineSize(frames: frames, expanded: false, showEars: showEars)
        let w = PetCurve.mix(collapsed.width, frames.expanded.width, p)
        let h = PetCurve.mix(collapsed.height, frames.expanded.height, p)
        let minX = (frames.expanded.width - w) / 2
        return CGRect(x: minX + frames.flare, y: 0, width: w - 2 * frames.flare, height: h)
    }
}
