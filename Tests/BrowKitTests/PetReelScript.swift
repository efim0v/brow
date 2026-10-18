// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import CoreGraphics
import Foundation
@testable import BrowKit

/// A hand-written timeline for the rig, a segment script: behaviours with their starts, cues, meter keys,
/// the pointer's path and the dock's changes. It plays the way the brain's output plays: a meal followed by
/// `satisfied` (or by `fallAsleep` for the meal that fills the window), moods as new `idle` segments, peeks
/// between `denWait`s.
struct PetReelScript {
    var timeline = PetTimeline()
    var pointer: [PetPointerSample] = []
    var dock: [PetDockChange] = []

    init(_ segments: [(Double, PetBehaviour)] = [], hunger: Double = PetTuning.Hunger.newPet) {
        timeline.segments = segments.map { PetSegment(start: $0.0, behaviour: $0.1) }
        timeline.meter = [PetMeterKey(t: 0, value: hunger, rate: 0)]
    }

    mutating func add(_ start: Double, _ behaviour: PetBehaviour) {
        timeline.segments.append(PetSegment(start: start, behaviour: behaviour))
        timeline.segments.sort { $0.start < $1.start }
    }

    mutating func cue(_ t: Double, _ kind: PetCue.Kind) {
        timeline.cues.append(PetCue(t: t, kind: kind))
        timeline.cues.sort { $0.t < $1.t }
    }

    mutating func meter(_ t: Double, _ value: Double, rate: Double = 0) {
        timeline.meter.append(PetMeterKey(t: t, value: value, rate: rate))
        timeline.meter.sort { $0.t < $1.t }
    }

    /// The pointer's path as the panel controller's monitors would see it: a sample every 1/120 s along a
    /// smooth curve through `keys` (time, x, y in window coordinates).
    mutating func pointerPath(_ keys: [(Double, Double, Double)]) {
        guard let first = keys.first, let last = keys.last else { return }
        var t = first.0
        while t <= last.0 {
            var i = 0
            while i + 1 < keys.count - 1 && keys[i + 1].0 <= t { i += 1 }
            let p0 = keys[max(i - 1, 0)], p1 = keys[i], p2 = keys[min(i + 1, keys.count - 1)], p3 = keys[min(i + 2, keys.count - 1)]
            let span = max(p2.0 - p1.0, 1e-6)
            let u = PetCurve.clamp((t - p1.0) / span, 0, 1)
            func tangent(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double) {
                let dt = max(b.0 - a.0, 1e-6)
                return ((b.1 - a.1) / dt, (b.2 - a.2) / dt)
            }
            let m1 = tangent(p0, p2), m2 = tangent(p1, p3)
            let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u
            let h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u
            let x = h00 * p1.1 + h10 * span * m1.0 + h01 * p2.1 + h11 * span * m2.0
            let y = h00 * p1.2 + h10 * span * m1.1 + h01 * p2.2 + h11 * span * m2.1
            pointer.append(PetPointerSample(t: t, location: CGPoint(x: x, y: y)))
            t += 1.0 / 120
        }
    }

    /// What the controller hands the rig at `t`: the samples of the last 2 s and the one before them.
    func pointerTrack(at t: Double) -> PetPointerTrack {
        let past = pointer.filter { $0.t <= t }
        let recent = past.filter { $0.t > t - PetPointerTrack.history }
        var samples = recent
        if let before = past.last(where: { $0.t <= t - PetPointerTrack.history }) { samples.insert(before, at: 0) }
        return PetPointerTrack(samples: samples)
    }

    /// The last expand or collapse however old, and every change of the last 2 s.
    func dockTrack(at t: Double) -> PetDockTrack {
        let past = dock.filter { $0.t <= t }
        var keep = past.filter { $0.t > t - PetDockTrack.history }
        if let last = past.last(where: { $0.kind == .expand || $0.kind == .collapse }), !keep.contains(last) {
            keep.insert(last, at: 0)
        }
        return PetDockTrack(changes: keep)
    }

    func pose(_ rig: PetRig, at t: Double, zones: PetZones, seed: UInt64 = 7, motion: PetMotion = PetMotion()) -> PetFrame {
        rig.pose(timeline, at: t, pointer: pointerTrack(at: t), dock: dockTrack(at: t), zones: zones, seed: seed, motion: motion)
    }

    static func meal(_ size: PetMeal.Size, chews: Int, feast: Bool = false, points: Double = 3,
                     reduceMotion: Bool = false) -> PetMeal {
        PetMeal(size: size, chews: chews, feast: feast, points: points, reduceMotion: reduceMotion)
    }
}
