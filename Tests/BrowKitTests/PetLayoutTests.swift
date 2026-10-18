// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
@testable import BrowKit

/// The pet's places: zones worked out from Brow's own frames and metrics, hop anchors and flight times,
/// and hops that keep clear of the screen's edge, the notch, and the outline that opens and closes around
/// them.
final class PetLayoutTests: XCTestCase {
    /// The 14"'s window starts at screen x 520: window x = screen x − 520, and the numbers beside and below
    /// the notch are screen coordinates; the 2560 pt display's pill starts at window x 140, and its numbers
    /// are pill-local.
    private let besideOffset: CGFloat = 520
    private let pillOffset: CGFloat = 140

    private func zone(_ placement: EarsPlacement, notch: Bool = true, left: PetReadoutWidth,
                      right: PetReadoutWidth = .twoDigits, initial: Bool = false) -> PetZone {
        let frames = PetStage.frames(placement, notch: notch)
        let zones = PetLayout.zones(frames: frames, leftWidth: left, rightWidth: right, rightInitial: initial, showEars: true,
                                    panelTop: max(frames.contentTopInset, 14), fiveHour: nil, dot: .ok)
        return zones.strip!
    }

    // MARK: - Zones

    /// Beside the notch, for each width of the left readout: the zone starts 4 pt after its text and ends
    /// at the notch.
    func testBesideZonesRunFromTheReadoutToTheNotch() {
        let cases: [(PetReadoutWidth, CGFloat, CGFloat)] = [
            (.dash, 604.125, 59.375), (.oneDigit, 610.375, 53.125), (.twoDigits, 618.5, 45.0), (.threeDigits, 626.625, 36.875),
        ]
        for (width, minX, w) in cases {
            let z = zone(.beside, left: width)
            XCTAssertEqual(z.kind, .beside)
            XCTAssertEqual(z.bounds.minX + besideOffset, minX, accuracy: 1e-9, "\(width)")
            XCTAssertEqual(z.bounds.width, w, accuracy: 1e-9, "\(width)")
            XCTAssertEqual(z.bounds.maxX + besideOffset, 663.5, accuracy: 1e-9)
            XCTAssertEqual(z.bounds.minY, 1)
            XCTAssertEqual(z.bounds.maxY, 31)
            XCTAssertEqual(z.anchor.x + besideOffset, 643.5)
            XCTAssertEqual(z.anchor.y, 28.5)
            XCTAssertEqual(z.scale, 1.0)
            XCTAssertEqual(z.maxStretch, 1.20)
            XCTAssertEqual(z.den, .side(edgeX: 663.5 - besideOffset))
        }
        // The crumbs come from the readout's text centre: x ≈ 601, y 16 for `41%`.
        let z = zone(.beside, left: .twoDigits)
        XCTAssertEqual(z.foodSource.x + besideOffset, 601, accuracy: 0.01)
        XCTAssertEqual(z.foodSource.y, 16)
    }

    /// Below the notch, for each width of the left readout: the zone runs from 668.5 to 4 pt before its
    /// dot.
    func testBelowZonesRunFromTheNotchsEdgeToTheReadout() {
        let cases: [(PetReadoutWidth, CGFloat, CGFloat)] = [
            (.dash, 719.375, 50.875), (.oneDigit, 713.125, 44.625), (.twoDigits, 705.0, 36.5), (.threeDigits, 696.875, 28.375),
        ]
        for (width, maxX, w) in cases {
            let z = zone(.below, left: width)
            XCTAssertEqual(z.kind, .below)
            XCTAssertEqual(z.bounds.minX + besideOffset, 668.5, accuracy: 1e-9)
            XCTAssertEqual(z.bounds.maxX + besideOffset, maxX, accuracy: 1e-9, "\(width)")
            XCTAssertEqual(z.bounds.width, w, accuracy: 1e-9, "\(width)")
            XCTAssertEqual(z.bounds.minY, 33)
            XCTAssertEqual(z.bounds.maxY, 53)
            XCTAssertEqual(z.anchor.x + besideOffset, 684.0)
            XCTAssertEqual(z.anchor.y, 51.5)
            XCTAssertEqual(z.scale, 0.80)
            XCTAssertEqual(z.maxStretch, 1.10)
        }
    }

    /// In the pill, pill-local, for each pair of readout widths: the zone between the two readouts; a model
    /// initial narrows it.
    func testPillZonesSitBetweenTheReadouts() {
        let cases: [(PetReadoutWidth, PetReadoutWidth, Bool, CGFloat, CGFloat)] = [
            (.dash, .dash, false, 46.625, 133.375),
            (.twoDigits, .twoDigits, false, 61.0, 119.0),
            (.twoDigits, .twoDigits, true, 61.0, 109.875),
            (.threeDigits, .threeDigits, false, 69.125, 110.875),
            (.threeDigits, .threeDigits, true, 69.125, 101.75),
        ]
        for (left, right, initial, minX, maxX) in cases {
            let z = zone(.beside, notch: false, left: left, right: right, initial: initial)
            XCTAssertEqual(z.kind, .pill)
            XCTAssertEqual(z.bounds.minX - pillOffset, minX, accuracy: 1e-9, "\(left) \(right) \(initial)")
            XCTAssertEqual(z.bounds.maxX - pillOffset, maxX, accuracy: 1e-9, "\(left) \(right) \(initial)")
            XCTAssertEqual(z.bounds.minY, 1)
            XCTAssertEqual(z.bounds.maxY, 23)
            XCTAssertEqual(z.anchor.x - pillOffset, 90)
            XCTAssertEqual(z.anchor.y, 21)
            XCTAssertEqual(z.scale, 0.82)
            XCTAssertEqual(z.maxStretch, 1.15)
            XCTAssertEqual(z.den, .none)
        }
    }

    /// The panel header's stage at x 14 to 78, the anchor at (46, top + 48), scale 2.
    func testPanelZoneIsTheHeadersStage() {
        for (notch, top, anchorY) in [(true, CGFloat(40), CGFloat(88)), (false, CGFloat(14), CGFloat(62))] {
            let frames = PetStage.frames(.beside, notch: notch)
            let zones = PetLayout.zones(frames: frames, aggregate: PetStage.aggregate(left: 41), showEars: true, fiveHour: nil)
            XCTAssertEqual(max(frames.contentTopInset, 14), top)
            XCTAssertEqual(zones.panel.kind, .panel)
            XCTAssertEqual(zones.panel.anchor, CGPoint(x: 46, y: anchorY))
            XCTAssertEqual(zones.panel.scale, 2.0)
            XCTAssertEqual(zones.panel.bounds.minX, 14)
            XCTAssertEqual(zones.panel.bounds.maxX, 78)
            XCTAssertEqual(zones.panel.bounds.maxY, top + 52)
        }
    }

    /// The notch is masked in every dock state; without a notch there is nothing to mask; readouts hidden,
    /// there is no strip zone at all.
    func testNotchAndHiddenReadouts() {
        let frames = PetStage.frames(.beside)
        let zones = PetLayout.zones(frames: frames, aggregate: PetStage.aggregate(left: 41), showEars: false, fiveHour: nil)
        XCTAssertNil(zones.strip)
        XCTAssertEqual(zones.notch, CGRect(x: 143.5, y: 0, width: 185, height: 32))
        let pill = PetLayout.zones(frames: PetStage.frames(.beside, notch: false), aggregate: PetStage.aggregate(left: 41),
                                   showEars: true, fiveHour: nil)
        XCTAssertNil(pill.notch)
    }

    /// The width class follows what `EarsView` prints, `—` included.
    func testReadoutWidthClasses() {
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 41).leftEar, hasData: false), .dash)
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 0).leftEar, hasData: true), .oneDigit)
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 9.4).leftEar, hasData: true), .oneDigit)
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 41).leftEar, hasData: true), .twoDigits)
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 99.6).leftEar, hasData: true), .threeDigits)
        XCTAssertEqual(PetLayout.readoutWidth(PetStage.aggregate(left: 100).leftEar, hasData: true), .threeDigits)
    }

    // MARK: - Hops

    /// In each layout: the hop's two anchors, the distance between them and the flight time.
    func testHopAnchorsAndFlightTimes() {
        let cases: [(EarsPlacement, Bool, CGPoint, CGPoint, Double, Double)] = [
            (.beside, true, CGPoint(x: 123.5, y: 28.5), CGPoint(x: 46, y: 88), 97.7, 0.279),
            (.below, true, CGPoint(x: 164.0, y: 51.5), CGPoint(x: 46, y: 88), 123.5, 0.294),
            (.beside, false, CGPoint(x: 230, y: 21), CGPoint(x: 46, y: 62), 188.5, 0.333),
        ]
        for (placement, notch, a, b, distance, time) in cases {
            let zones = PetStage.zones(PetStage.frames(placement, notch: notch), PetStage.aggregate(left: 41))
            XCTAssertEqual(zones.strip!.anchor, a)
            XCTAssertEqual(zones.panel.anchor, b)
            XCTAssertEqual(Double(hypot(b.x - a.x, b.y - a.y)), distance, accuracy: 0.05)
            XCTAssertEqual(PetLayout.flightTime(from: a, to: b), time, accuracy: 0.0005)
        }
    }

    struct Layout {
        var name: String
        var frames: NotchFrames
    }

    private var layouts: [Layout] {
        [Layout(name: "beside", frames: PetStage.frames(.beside)),
         Layout(name: "below", frames: PetStage.frames(.below)),
         Layout(name: "pill", frames: PetStage.frames(.beside, notch: false))]
    }

    /// Samples a dock change at 240 Hz for as long as it plays: the body's box at each step.
    private func hop(_ layout: Layout, expand: Bool, behaviour: PetBehaviour = .idle(.content),
                     motion: PetMotion = PetMotion()) -> [(tau: Double, box: CGRect, frame: PetFrame)] {
        var script = PetReelScript([(0, behaviour)])
        let t0 = 10.0
        if expand {
            script.dock = [PetDockChange(t: t0, kind: .expand)]
        } else {
            script.dock = [PetDockChange(t: t0 - 5, kind: .expand), PetDockChange(t: t0, kind: .collapse)]
        }
        let zones = PetStage.zones(layout.frames, PetStage.aggregate(left: 41))
        let rig = PetRig()
        var out: [(Double, CGRect, PetFrame)] = []
        for k in 0...Int(0.9 * 240) {
            let tau = Double(k) / 240
            let frame = script.pose(rig, at: t0 + tau, zones: zones, motion: motion)
            out.append((tau, frame.bodyBox, frame))
        }
        return out
    }

    /// The head, with the scale and stretch of that instant, never goes above the screen's top edge (y 0.5)
    /// nor into the notch. The clearances it keeps are printed.
    func testHopsKeepClearOfTheTopEdgeAndTheNotch() {
        for layout in layouts {
            let notch = layout.frames.notch.map { PetLayout.window($0, in: layout.frames) }
            for expand in [true, false] {
                for behaviour in [PetBehaviour.idle(.content), .asleep] {
                    var clearance = Double.infinity
                    for s in hop(layout, expand: expand, behaviour: behaviour) where !s.box.isNull {
                        clearance = min(clearance, Double(s.box.minY) - PetTuning.Hop.topClearance)
                        if let notch, s.box.intersects(notch) {
                            XCTFail("\(layout.name) \(expand ? "expand" : "collapse") \(behaviour): in the notch at \(s.tau) s, \(s.box)")
                        }
                        if let notch, s.box.maxX > notch.minX, s.box.minX < notch.maxX {
                            clearance = min(clearance, Double(s.box.minY - notch.maxY))
                        }
                    }
                    XCTAssertGreaterThanOrEqual(clearance, 0, "\(layout.name) \(expand ? "expand" : "collapse") \(behaviour)")
                    print(String(format: "hop clearance %@ %@ %@: %.2f pt", layout.name, expand ? "expand" : "collapse",
                                 "\(behaviour)", clearance))
                }
            }
        }
    }

    /// Brow's outline opens on spring(0.32, 0.86) and closes on spring(0.26, 1.0); the hop rides inside it,
    /// its box at least 1 pt in at every 1/240 s step, every layout. The panel is the 14"'s smallest, one
    /// account: 120 pt tall.
    func testHopsStayInsideTheAnimatedOutline() {
        for layout in layouts {
            for height in [CGFloat(120), 300] {
                let frames = NotchGeometry.frames(for: layout.frames.hasNotch ? PetStage.notched : PetStage.plain,
                                                  expandedHeight: height, placement: layout.frames.placement)
                let l = Layout(name: layout.name, frames: frames)
                for expand in [true, false] {
                    var worst = Double.infinity
                    for s in hop(l, expand: expand) where !s.box.isNull {
                        let p = expand
                            ? PetLayout.springProgress(s.tau, response: PetTuning.Hop.openResponse, damping: PetTuning.Hop.openDamping)
                            : 1 - PetLayout.springProgress(s.tau, response: PetTuning.Hop.closeResponse, damping: PetTuning.Hop.closeDamping)
                        let outline = PetLayout.outline(frames: frames, progress: p)
                        let inside = min(Double(s.box.minX - outline.minX), Double(outline.maxX - s.box.maxX),
                                         Double(outline.maxY - s.box.maxY))
                        worst = min(worst, inside)
                    }
                    XCTAssertGreaterThanOrEqual(worst, 1, "\(layout.name) \(height) pt \(expand ? "expand" : "collapse")")
                    print(String(format: "inside the outline %@ %.0f pt %@: %.2f pt", layout.name, Double(height),
                                 expand ? "expand" : "collapse", worst))
                }
            }
        }
    }

    /// On a display without a notch with the readouts off, Brow draws nothing until the pointer reaches the
    /// top centre: collapsed, the outline the hops are held to has the pill's width and no height, and it
    /// unrolls from the top edge into the panel.
    func testWithoutANotchAndTheReadoutsOffTheOutlineHasNoHeight() {
        let pill = PetStage.frames(.beside, notch: false)
        let pillWidth = NotchGeometry.pillWidth
        XCTAssertEqual(PetLayout.outline(frames: pill, progress: 0, showEars: false),
                       CGRect(x: (pill.expanded.width - pillWidth) / 2, y: 0, width: pillWidth, height: 0))
        XCTAssertEqual(PetLayout.outline(frames: pill, progress: 0.5, showEars: false).height,
                       pill.expanded.height / 2, accuracy: 1e-9)
        XCTAssertEqual(PetLayout.outline(frames: pill, progress: 1, showEars: false).size, pill.expanded.size)
        // With the readouts on, the pill itself.
        XCTAssertEqual(PetLayout.outline(frames: pill, progress: 0).size,
                       CGSize(width: pillWidth, height: NotchGeometry.pillHeight))
    }

    /// The outline the hops are held to is the one the app draws: `NotchRootView.outlineSize` collapsed,
    /// grown toward the panel, inside the flares, in every layout with the readouts on or off.
    func testTheOutlineIsTheOneTheAppDraws() {
        for layout in layouts {
            let frames = layout.frames
            for showEars in [true, false] {
                let collapsed = NotchRootView.outlineSize(frames: frames, expanded: false, showEars: showEars)
                for p in [0.0, 0.3, 1.0] {
                    let outline = PetLayout.outline(frames: frames, progress: p, showEars: showEars)
                    let name = "\(layout.name), readouts \(showEars ? "on" : "off"), progress \(p)"
                    XCTAssertEqual(Double(outline.width + 2 * frames.flare),
                                   Double(collapsed.width) + Double(frames.expanded.width - collapsed.width) * p,
                                   accuracy: 1e-9, name)
                    XCTAssertEqual(Double(outline.height),
                                   Double(collapsed.height) + Double(frames.expanded.height - collapsed.height) * p,
                                   accuracy: 1e-9, name)
                    XCTAssertEqual(outline.minY, 0, name)
                    XCTAssertEqual(Double(outline.midX), Double(frames.expanded.width) / 2, accuracy: 1e-9, name)
                }
            }
        }
    }

    /// A layout change (the Ears picker, another display): out at the old place over 0.15 s, in at the new
    /// one over 0.20 s.
    func testALayoutChangeFadesOutAndIn() {
        let old = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41))
        let new = PetStage.zones(PetStage.frames(.below), PetStage.aggregate(left: 41))
        var script = PetReelScript([(0, .idle(.content))])
        script.dock = [PetDockChange(t: 10, kind: .relayout(from: old))]
        let rig = PetRig()
        func frame(_ t: Double) -> PetFrame { script.pose(rig, at: t, zones: new) }
        XCTAssertEqual(frame(10.0).pet.x, Double(old.strip!.anchor.x), accuracy: 1.5, "still at the old place")
        XCTAssertEqual(frame(10.0).pet.opacity, 1, accuracy: 1e-9)
        XCTAssertLessThan(frame(10.12).pet.opacity, 0.2)
        XCTAssertEqual(frame(10.16).pet.x, Double(new.strip!.anchor.x), accuracy: 1.5, "then at the new one")
        XCTAssertLessThan(frame(10.16).pet.opacity, 0.1)
        XCTAssertEqual(frame(10.36).pet.opacity, 1, accuracy: 1e-9)
    }

    /// Readouts hidden: nothing is drawn collapsed; the pet appears only in the panel, fading in with it
    /// over 0.2 s and out with it.
    func testWithTheReadoutsHiddenThePetLivesInThePanel() {
        let zones = PetStage.zones(PetStage.frames(.beside), PetStage.aggregate(left: 41), showEars: false)
        var script = PetReelScript([(0, .idle(.content))])
        script.dock = [PetDockChange(t: 10, kind: .expand), PetDockChange(t: 20, kind: .collapse)]
        let rig = PetRig()
        XCTAssertTrue(script.pose(rig, at: 5, zones: zones).isEmpty)
        XCTAssertEqual(script.pose(rig, at: 10.1, zones: zones).pet.opacity, 0.5, accuracy: 0.01)
        let open = script.pose(rig, at: 12, zones: zones)
        XCTAssertEqual(open.pet.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(open.pet.x, Double(zones.panel.anchor.x), accuracy: 1.5)
        XCTAssertLessThan(script.pose(rig, at: 20.15, zones: zones).pet.opacity, 0.2)
        XCTAssertTrue(script.pose(rig, at: 21, zones: zones).isEmpty)
    }

    /// Reduce Motion: no hop, no glide; the strip's pet fades out while the header's fades in, overlapping
    /// for 0.05 s.
    func testReduceMotionCrossfades() {
        let layout = layouts[0]
        let samples = hop(layout, expand: true, motion: PetMotion(reduceMotion: true))
        let zones = PetStage.zones(layout.frames, PetStage.aggregate(left: 41))
        for s in samples {
            XCTAssertEqual(s.frame.pet.x, Double(zones.panel.anchor.x), accuracy: 2.5, "at \(s.tau): it does not fly")
            if let echo = s.frame.echo { XCTAssertEqual(echo.x, Double(zones.strip!.anchor.x), accuracy: 2.5) }
        }
        let both = samples.filter { ($0.frame.echo?.opacity ?? 0) > 0.001 && $0.frame.pet.opacity > 0.001 }
        XCTAssertGreaterThan(both.count, 0)
        XCTAssertLessThanOrEqual(Double(both.count) / 240, 0.05 + 2.0 / 240)
    }
}

/// Every behaviour in every layout and width class: the body's box stays inside the zone, nothing passes
/// the notch's edge but the den's own poses, and the squash, stretch and lean stay within their limits.
/// By default each behaviour is sampled at 30 Hz for its length, or 8 s when it is open;
/// `PET_SWEEP=1` runs the full sweep, 240 Hz for 60 s.
final class PetZoneSweepTests: XCTestCase {
    static let full = ProcessInfo.processInfo.environment["PET_SWEEP"] != nil

    static var behaviours: [PetBehaviour] {
        let meals: [PetMeal] = [
            PetReelScript.meal(.full, chews: 3), PetReelScript.meal(.full, chews: 1), PetReelScript.meal(.nibble, chews: 2),
            PetReelScript.meal(.full, chews: 3, feast: true, points: 9), PetReelScript.meal(.full, chews: 2, reduceMotion: true),
        ]
        var out: [PetBehaviour] = [.intro(noAccounts: false), .intro(noAccounts: true)]
        for mood in PetMood.allCases { out += [.idle(mood), .settled(mood), .unsureIdle(mood)] }
        out += [.perk(.prompt), .perk(.freshData), .eager]
        out += meals.map { .eat($0) }
        out += [.satisfied(.meal), .satisfied(.feast), .satisfied(.lick), .boop(giggle: false), .boop(giggle: true),
                .celebrate(.streak(days: 7)), .celebrate(.goodWeek), .freshWindow, .fallAsleep, .asleep, .drowsy, .wake,
                .rollOver, .enterDen(retreat: false), .enterDen(retreat: true), .hibernating, .stirring, .leaveDen(stretch: true),
                .leaveDen(stretch: false), .denWait, .peek, .dozeIn, .doze, .welcomeBack]
        return out
    }

    /// A behaviour at t = 5 after what the brain plays before it, so it starts from the pose it really
    /// starts from: a wake from sleep, a peek from the den, a satisfied after a meal.
    static func script(for behaviour: PetBehaviour) -> PetReelScript {
        let meal = PetReelScript.meal(.full, chews: 3)
        let before: [(Double, PetBehaviour)]
        switch behaviour {
        case .intro: before = []
        case .satisfied(.meal): before = [(0, .idle(.content)), (5 - meal.duration, .eat(meal))]
        case .satisfied(.feast):
            let feast = PetReelScript.meal(.full, chews: 3, feast: true, points: 9)
            before = [(0, .idle(.content)), (5 - feast.duration, .eat(feast))]
        case .satisfied(.lick):
            let nibble = PetReelScript.meal(.nibble, chews: 1)
            before = [(0, .idle(.content)), (5 - nibble.duration, .eat(nibble))]
        case .fallAsleep: before = [(0, .idle(.full))]
        case .asleep: before = [(0, .idle(.full)), (5 - PetTuning.Behaviour.fallAsleep, .fallAsleep)]
        case .drowsy, .rollOver: before = [(0, .asleep)]
        case .wake: before = [(0, .asleep), (3, .drowsy)]
        case .enterDen: before = [(0, .idle(.content))]
        case .hibernating: before = [(0, .idle(.content)), (5 - PetTuning.Behaviour.enterDen, .enterDen(retreat: false))]
        case .stirring: before = [(0, .idle(.content)), (0.2, .enterDen(retreat: false)),
                                  (0.2 + PetTuning.Behaviour.enterDen, .hibernating)]
        case .leaveDen(true): before = [(0, .hibernating)]
        case .leaveDen(false), .peek: before = [(0, .denWait)]
        case .denWait: before = [(0, .idle(.content)), (5 - PetTuning.Behaviour.retreat, .enterDen(retreat: true))]
        case .doze: before = [(0, .idle(.content)), (5 - PetTuning.Behaviour.dozeIn, .dozeIn)]
        case .welcomeBack: before = [(0, .doze)]
        case .eager: before = [(0, .idle(.content)), (4.5, .perk(.prompt))]
        default: before = [(0, .idle(.content))]
        }
        var script = PetReelScript(before + [(5, behaviour)])
        if case .eat(let m) = behaviour { script.meter(5 + m.swallowStart, 12) }
        return script
    }

    struct Place {
        var name: String
        var zones: PetZones
        var zone: PetZone
    }

    static var places: [Place] {
        var out: [Place] = []
        let readouts: [(String, Double, Bool)] = [("—", 41, false), ("1 digit", 6, true), ("2 digits", 41, true), ("100%", 100, true)]
        for (layout, frames) in [("beside", PetStage.frames(.beside)), ("below", PetStage.frames(.below)),
                                 ("pill", PetStage.frames(.beside, notch: false))] {
            for (name, left, data) in readouts {
                let zones = PetStage.zones(frames, PetStage.aggregate(left: left, right: left, hasData: data))
                out.append(Place(name: "\(layout) \(name)", zones: zones, zone: zones.strip!))
            }
        }
        let frames = PetStage.frames(.beside)
        var panel = PetStage.zones(frames, PetStage.aggregate(left: 41))
        panel.strip = nil
        out.append(Place(name: "panel", zones: panel, zone: panel.panel))
        return out
    }

    func testEveryBehaviourStaysInItsZone() {
        let rate = Self.full ? 240.0 : 30.0
        let open = Self.full ? 60.0 : 8.0
        var failures: [String] = []
        for place in Self.places {
            for behaviour in Self.behaviours {
                var script = Self.script(for: behaviour)
                if place.zone.kind == .panel { script.dock = [PetDockChange(t: 0, kind: .expand)] }
                let rig = PetRig()
                let length = behaviour.duration ?? open
                let den = PetRigActions.denPose(PetRigBeat(segments: script.timeline.segments,
                                                           index: script.timeline.segments.count - 1, t: 6))
                let bounds = place.zone.bounds
                var worst: (Double, String)? = nil
                for n in 0...Int(length * rate) {
                    let t = 5 + Double(n) / rate
                    let frame = script.pose(rig, at: t, zones: place.zones)
                    let p = frame.pet
                    guard p.opacity > 0.001, !frame.bodyBox.isNull else { continue }
                    let box = frame.bodyBox
                    var over = max(Double(bounds.minX - box.minX), Double(bounds.minY - box.minY), Double(box.maxY - bounds.maxY),
                                   Double(box.maxX - bounds.maxX))
                    // The den's own poses may pass the zone, and only on the den's side.
                    if den, case .side = place.zone.den {
                        over = max(Double(bounds.minX - box.minX), Double(bounds.minY - box.minY), Double(box.maxY - bounds.maxY))
                    } else if den, case .overhead = place.zone.den {
                        over = max(Double(bounds.minX - box.minX), Double(box.maxX - bounds.maxX), Double(box.maxY - bounds.maxY))
                    }
                    if over > 0.01, over > (worst?.0 ?? 0) { worst = (over, String(format: "%.3f s", t - 5)) }
                    // The extremes.
                    if p.curl < 0.01 {
                        if p.squash < PetTuning.Zone.minimumSquash - 1e-9 { failures.append("\(place.name) \(behaviour) squash \(p.squash) at \(t - 5)") }
                    }
                    if p.squash > Double(place.zone.maxStretch) + 1e-9 { failures.append("\(place.name) \(behaviour) stretch \(p.squash) at \(t - 5)") }
                    let lean = abs(atan(p.lean) + p.tilt) * 180 / .pi
                    if lean > PetTuning.Zone.maxLeanDegrees + 1e-6 { failures.append("\(place.name) \(behaviour) lean \(lean)° at \(t - 5)") }
                }
                if let worst { failures.append("\(place.name) \(behaviour): \(String(format: "%.2f", worst.0)) pt out at \(worst.1)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.prefix(40).joined(separator: "\n"))
    }

    /// Asleep in the open, the pet is at most 14 pt tall at the anchor beside the notch, and lies inside the
    /// narrow zone the `100%` leaves.
    func testAsleepIsLowAndInsideTheNarrowZone() {
        let frames = PetStage.frames(.beside)
        let zones = PetStage.zones(frames, PetStage.aggregate(left: 100))
        let script = PetReelScript([(0, .asleep)], hunger: 0)
        let rig = PetRig()
        for n in 0..<(30 * 20) {
            let frame = script.pose(rig, at: 2 + Double(n) / 30, zones: zones)
            XCTAssertLessThanOrEqual(frame.bodyBox.height, PetTuning.Zone.asleepMaxHeight, "at \(Double(n) / 30)")
            XCTAssertGreaterThanOrEqual(frame.bodyBox.minX, zones.strip!.bounds.minX)
        }
    }
}
