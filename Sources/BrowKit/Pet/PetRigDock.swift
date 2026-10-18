// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation

/// Where the pet is between the strip and the panel: which zone it is posed in, and the hop, glide or
/// crossfade that is carrying it there.
struct PetRigPlacement {
    /// nil: nowhere to draw it (collapsed with the readouts hidden).
    var zone: PetZone?
    var opacity: Double = 1
    var flight: PetLayout.Flight?
    var source: PetRigSource?
    var lookAt: CGPoint?
    var expanded: Bool
    /// Reduce Motion's crossfade: the pet in the zone it is leaving, and how much of it is left.
    var echo: (zone: PetZone, opacity: Double)?
}

enum PetRigDock {
    /// The hop's crouch, flight, landing and settle all fit in this; the spring has settled by then.
    static let settle: Double = 0.45

    static func placement(at t: Double, timeline: PetTimeline, dock: PetDockTrack, zones: PetZones,
                          motion: PetMotion) -> PetRigPlacement {
        let last = dock.changes.last { $0.t <= t && ($0.kind == .expand || $0.kind == .collapse) }
        let expanded = last?.kind == .expand
        let home = expanded ? zones.panel : zones.strip

        // A layout change: out at the old zone, in at the new one.
        if let change = dock.changes.last(where: { $0.t <= t }), case .relayout(let old) = change.kind {
            let tau = t - change.t
            typealias H = PetTuning.Hop
            if tau < H.relayoutFadeOut {
                let zone = expanded ? old.panel : old.strip
                return PetRigPlacement(zone: zone, opacity: 1 - PetEase.smooth(tau / H.relayoutFadeOut), expanded: expanded)
            }
            if tau < H.relayoutFadeOut + H.relayoutFadeIn {
                return PetRigPlacement(zone: home, opacity: PetEase.smooth((tau - H.relayoutFadeOut) / H.relayoutFadeIn),
                                       expanded: expanded)
            }
        }

        guard let change = last else { return PetRigPlacement(zone: home, expanded: expanded) }
        let tau = t - change.t
        guard let strip = zones.strip else {
            // Readouts hidden: the pet lives in the panel only, fading in and out with it.
            let fade = PetTuning.Hop.panelOnlyFade
            if expanded { return PetRigPlacement(zone: zones.panel, opacity: PetEase.smooth(tau / fade), expanded: true) }
            guard tau < fade else { return PetRigPlacement(zone: nil, expanded: false) }
            return PetRigPlacement(zone: zones.panel, opacity: 1 - PetEase.smooth(tau / fade), expanded: false)
        }
        let panel = zones.panel

        if motion.reduceMotion {
            // No hop and no glide: the strip's pet fades out while the header's fades in, so nothing
            // travels across the screen.
            typealias H = PetTuning.Hop
            let leaving = expanded ? strip : panel
            let outOpacity = 1 - PetEase.smooth(tau / H.reducedFadeOut)
            let inStart = H.reducedFadeOut - H.reducedOverlap
            let inOpacity = PetEase.smooth((tau - inStart) / H.reducedFadeIn)
            var p = PetRigPlacement(zone: home, opacity: inOpacity, expanded: expanded)
            if outOpacity > 0.001 { p.echo = (leaving, outOpacity) }
            return p
        }

        let behaviour = PetRigBeat(segments: timeline.segments, index: PetRigTimeline.index(timeline.segments, at: change.t),
                                   t: change.t).behaviour
        // Where the pet stood in the strip when the hop began: the anchor, or its place in the den.
        let stripFeet = PetRigActions.restFeet(behaviour, zone: strip)
        let a = stripFeet, b = panel.anchor
        let sa = Double(strip.scale), sb = Double(panel.scale)
        if glides(behaviour) {
            guard tau < PetTuning.Hop.glide else { return PetRigPlacement(zone: home, expanded: expanded) }
            let flight = expanded ? PetLayout.glide(from: a, to: b, scaleA: sa, scaleB: sb, tau: tau)
                                  : PetLayout.glide(from: b, to: a, scaleA: sb, scaleB: sa, tau: tau)
            var p = PetRigPlacement(zone: home, expanded: expanded)
            p.flight = flight
            return p
        }
        let duration = hopDuration(expand: expanded, a: a, b: b)
        guard tau < duration else { return PetRigPlacement(zone: home, expanded: expanded) }
        let stepsOff = strip.kind != .beside
        let flight = expanded
            ? PetLayout.expand(a: a, b: b, scaleA: sa, scaleB: sb, stepsOff: stepsOff, tau: tau)
            : PetLayout.collapse(a: a, b: b, scaleA: sa, scaleB: sb, beside: strip.kind == .beside, tau: tau)
        var p = PetRigPlacement(zone: home, expanded: expanded)
        p.flight = flight
        p.lookAt = flight.landed ? nil : (expanded ? b : a)
        p.source = PetRigSource(kind: .dock(expand: expanded, ax: Double(a.x), ay: Double(a.y), bx: Double(b.x),
                                            by: Double(b.y), sa: sa, sb: sb, stepsOff: stepsOff),
                                start: change.t, scale: expanded ? sb : sa, foodSide: 0, jellyHz: 4.0, jellyZeta: 0.3)
        return p
    }

    /// Asleep, drowsy or hibernating, and in or near the den, the pet glides instead of hopping: it keeps
    /// its pose and slides along a straight line, so a sleeping pet is carried, never made to jump.
    static func glides(_ b: PetBehaviour) -> Bool {
        switch b {
        case .asleep, .drowsy, .hibernating, .stirring, .rollOver, .denWait, .doze, .peek, .enterDen, .leaveDen, .fallAsleep:
            return true
        default:
            return false
        }
    }

    /// From `setExpanded` to the landing spring settled.
    static func hopDuration(expand: Bool, a: CGPoint, b: CGPoint) -> Double {
        typealias H = PetTuning.Hop
        if expand { return H.crouch + PetLayout.flightTime(from: a, to: b) + H.landing + settle }
        return H.collapseY + H.collapseLanding + settle
    }
}
