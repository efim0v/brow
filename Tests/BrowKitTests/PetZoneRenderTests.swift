// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import SwiftUI
import XCTest
@testable import BrowKit

/// The pet never covers Brow's numbers and never draws where the camera is. Rendered with the real
/// `EarsView` at scale 2 and read back, the way `EarsViewFillTests` reads its pixels: geometry alone
/// cannot see a glow or an arm.
@MainActor
final class PetZoneRenderTests: XCTestCase {
    /// An image as premultiplied RGBA bytes.
    struct Pixels {
        let width: Int, height: Int
        let bytes: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
        func value(_ x: Int, _ y: Int) -> UInt8 {
            let i = (y * width + x) * 4
            return max(bytes[i], bytes[i + 1], bytes[i + 2])
        }
        /// How white: the least of the three channels, so a coloured pixel is not.
        func white(_ x: Int, _ y: Int) -> UInt8 {
            let i = (y * width + x) * 4
            return min(bytes[i], bytes[i + 1], bytes[i + 2])
        }
    }

    static func pixels<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.scale = scale
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    /// The strip's readouts alone, in window coordinates cropped to the strip.
    func readoutInk(_ frames: NotchFrames, _ aggregate: LimitsAggregate) throws -> (Pixels, CGRect) {
        let strip = PetLayout.window(frames.collapsed, in: frames)
        let ears = EarsView(aggregate: aggregate, frames: frames, drawsBackground: false)
            .frame(width: strip.width, height: strip.height)
        return (try Self.pixels(ears, size: strip.size), strip)
    }

    /// The pet layer alone over nothing, cropped to the same rect; the food's light left out.
    func petInk(_ frame: PetFrame, crop: CGRect, food: Bool = false) throws -> Pixels {
        var f = frame
        if !food {
            f.bead = nil
            f.glint = nil
            f.particles = f.particles.filter { $0.kind != .crumb }
        }
        let layer = PetStage.PetLayer(frame: f, palette: .standard).offset(x: -crop.minX, y: -crop.minY)
        return try Self.pixels(layer, size: crop.size)
    }

    /// Poses that reach furthest toward the readouts or are on screen longest, per layout.
    func poses() -> [(String, PetReelScript, Double)] {
        let full = PetReelScript.meal(.full, chews: 3)
        let last = PetReelScript.meal(.nibble, chews: 1)
        var out: [(String, PetReelScript, Double)] = []
        func add(_ name: String, _ script: PetReelScript, _ times: [Double]) { for t in times { out.append(("\(name) \(t)", script, t)) } }
        var meal = PetReelScript([(0, .idle(.content)), (5, .eat(full)), (5 + full.duration, .satisfied(.meal))])
        meal.meter(5 + full.swallowStart, 12)
        add("meal", meal, stride(from: 5.0, to: 9.0, by: 1.0 / 20).map { $0 })
        var nibble = PetReelScript([(0, .idle(.hungry)), (5, .eat(last)), (5 + last.duration, .fallAsleep)], hunger: 80)
        nibble.meter(5 + last.swallowStart, 62)
        add("last bite", nibble, stride(from: 5.0, to: 8.5, by: 1.0 / 20).map { $0 })
        add("hungry", PetReelScript([(0, .idle(.hungry))], hunger: 85), stride(from: 2.0, to: 62, by: 0.5).map { $0 })
        add("eager", PetReelScript([(0, .eager)]), stride(from: 1.0, to: 12, by: 0.25).map { $0 })
        add("asleep", PetReelScript([(0, .asleep)], hunger: 0), stride(from: 1.0, to: 12, by: 0.5).map { $0 })
        add("drowsy", PetReelScript([(0, .asleep), (5, .drowsy)], hunger: 0), stride(from: 5.0, to: 12, by: 0.5).map { $0 })
        add("wake", PetReelScript([(0, .asleep), (5, .wake)]), stride(from: 5.0, to: 7.8, by: 1.0 / 15).map { $0 })
        add("celebrate", PetReelScript([(0, .idle(.content)), (5, .celebrate(.streak(days: 7)))]),
            stride(from: 5.0, to: 7.5, by: 1.0 / 15).map { $0 })
        add("idle", PetReelScript([(0, .idle(.content))]), stride(from: 1.0, to: 240, by: 0.5).map { $0 })
        // The ends of the meter: stuffed round-bellied, famished leaning in with its near nub reaching, and
        // each gesture of theirs frame by frame.
        for (mood, hunger) in [(PetMood.stuffed, -46.0), (.famished, 96)] {
            let script = PetReelScript([(0, .idle(mood))], hunger: hunger)
            add("\(mood)", script, stride(from: 2.0, to: 30, by: 0.5).map { $0 })
            let gestures = PetRigMoodBeats.gestures(in: PetSegment(start: 0, behaviour: .idle(mood)), previous: nil, at: 900,
                                                    lookBack: 900, seed: 7, reduceMotion: false)
            var seen: [String: Int] = [:]
            for g in gestures {
                guard case .beat(let b) = g.item, seen["\(b)", default: 0] < 2 else { continue }
                seen["\(b)", default: 0] += 1
                add("\(mood) \(b)", script, stride(from: g.at, to: g.end, by: 0.1).map { $0 })
            }
        }
        let more = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .stuffed)
        var stuffedMeal = PetReelScript([(0, .idle(.stuffed)), (5, .eat(more)), (5 + more.duration, .satisfied(.brim))], hunger: -40)
        stuffedMeal.meter(5 + more.swallowStart, -50)
        add("stuffed meal", stuffedMeal, stride(from: 5.0, to: 10.0, by: 1.0 / 20).map { $0 })
        let keen = PetMeal(size: .full, chews: 3, feast: false, points: 3, reduceMotion: false, mood: .famished)
        var gratefulMeal = PetReelScript([(0, .idle(.famished)), (5, .eat(keen)), (5 + keen.duration, .satisfied(.grateful))],
                                         hunger: 96)
        gratefulMeal.meter(5 + keen.swallowStart, 78)
        add("grateful meal", gratefulMeal, stride(from: 5.0, to: 10.0, by: 1.0 / 20).map { $0 })
        return out
    }

    /// The strip at `41%` and `100%`, beside, below and on the pill: no pet pixel within 4 pt of a
    /// readout's pixel, and where the pet's light reaches a readout it stays under 3 %.
    func testThePetNeverCoversAReadout() throws {
        let layouts: [(String, NotchFrames)] = [("beside", PetStage.frames(.beside)), ("below", PetStage.frames(.below)),
                                                ("pill", PetStage.frames(.beside, notch: false))]
        var failures: [String] = []
        for (layout, frames) in layouts {
            for left in [41.0, 100.0] {
                let aggregate = PetStage.aggregate(left: left)
                let (ink, strip) = try readoutInk(frames, aggregate)
                // The readouts' pixels, and every pixel within 4 pt (8 px) of one.
                var near = [Bool](repeating: false, count: ink.width * ink.height)
                var readout = [Bool](repeating: false, count: ink.width * ink.height)
                let r = 8
                for y in 0..<ink.height {
                    for x in 0..<ink.width where ink.alpha(x, y) > 128 && ink.value(x, y) > 100 {
                        readout[y * ink.width + x] = true
                        for yy in max(0, y - r)...min(ink.height - 1, y + r) {
                            for xx in max(0, x - r)...min(ink.width - 1, x + r) { near[yy * ink.width + xx] = true }
                        }
                    }
                }
                // Only the band round the readouts is read back; a pose whose canvas cannot reach it is
                // not rendered at all.
                var band = CGRect.null
                for y in 0..<ink.height { for x in 0..<ink.width where near[y * ink.width + x] {
                    band = band.union(CGRect(x: x, y: y, width: 1, height: 1))
                } }
                let bandWindow = CGRect(x: strip.minX + band.minX / 2, y: strip.minY + band.minY / 2,
                                        width: band.width / 2, height: band.height / 2)
                let zones = PetStage.zones(frames, aggregate)
                for (k, (name, script, t)) in poses().enumerated() {
                    let rig = PetRig()
                    let frame = script.pose(rig, at: t, zones: zones)
                    // Render whatever comes within 8 pt of the band: the body, its light's reach, a particle.
                    // The first pose is always rendered, for the light at rest.
                    let reach = frame.bodyBox.insetBy(dx: -8, dy: -8)
                    let close = reach.intersects(bandWindow) || frame.particles.contains { p in
                        bandWindow.insetBy(dx: -8, dy: -8).contains(p.position)
                    }
                    guard k == 0 || close else { continue }
                    let pet = try petInk(frame, crop: strip)
                    var body = 0
                    var light: UInt8 = 0
                    for y in Int(band.minY)..<Int(band.maxY) {
                        for x in Int(band.minX)..<Int(band.maxX) {
                            let i = y * pet.width + x
                            if near[i] && pet.alpha(x, y) > 40 { body += 1 }
                            if readout[i] { light = max(light, pet.value(x, y)) }
                        }
                    }
                    if body > 0 { failures.append("\(layout) \(Int(left))% \(name): \(body) pet pixels within 4 pt of a readout") }
                    if Double(light) / 255 > PetTuning.Light.glowAtReadout {
                        failures.append("\(layout) \(Int(left))% \(name): light \(Double(light) / 255) on a readout")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.prefix(30).joined(separator: "\n"))
    }

    /// The food is light out of the number and a glint on its ripe digit, added over the readout: no
    /// readout pixel is ever darker with them than without (never a moved or hidden glyph),
    /// and the black the glyphs close round, the counters of the 4s and the %, stays black, under a
    /// quarter of white, so the glint never fills a 0, a 4 or an 8 and changes what the number reads.
    func testTheFoodOnlyAddsLight() throws {
        let frames = PetStage.frames(.beside)
        let aggregate = PetStage.aggregate(left: 44)
        let strip = PetLayout.window(frames.collapsed, in: frames)
        let zones = PetStage.zones(frames, aggregate)
        let full = PetReelScript.meal(.full, chews: 3)
        let script = PetReelScript([(0, .idle(.content)), (5, .eat(full))])
        let ears = PetStage.StripScene(frames: frames, aggregate: aggregate, pet: nil, crop: strip, desktop: false)
        let without = try Self.pixels(ears, size: strip.size)
        // The left readout's text: its white pixels (the dot is green), and the black in their box.
        var text = (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
        for y in 0..<without.height {
            for x in 0..<(without.width / 2) where without.alpha(x, y) > 128 && without.white(x, y) > 150 {
                text = (min(text.minX, x), min(text.minY, y), max(text.maxX, x), max(text.maxY, y))
            }
        }
        XCTAssertLessThan(text.minX, text.maxX, "the readout's text was found")
        // The counters: the dark pixels in the text's box that no path of dark pixels joins to its edge.
        let w = text.maxX - text.minX + 1, h = text.maxY - text.minY + 1
        var open = [Bool](repeating: false, count: w * h)
        var queue: [(Int, Int)] = []
        func dark(_ x: Int, _ y: Int) -> Bool { without.value(text.minX + x, text.minY + y) < 40 }
        for x in 0..<w { for y in [0, h - 1] where dark(x, y) { queue.append((x, y)) } }
        for y in 0..<h { for x in [0, w - 1] where dark(x, y) { queue.append((x, y)) } }
        while let (x, y) = queue.popLast() {
            guard !open[y * w + x] else { continue }
            open[y * w + x] = true
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h && !open[ny * w + nx] && dark(nx, ny) {
                queue.append((nx, ny))
            }
        }
        var counters: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where dark(x, y) && !open[y * w + x] { counters.append((text.minX + x, text.minY + y)) } }
        XCTAssertGreaterThan(counters.count, 20, "the 4s and the % close round some black")
        for n in 0..<Int(0.5 * 60) {
            let t = 5 + Double(n) / 60
            let frame = script.pose(PetRig(), at: t, zones: zones)
            let with = try Self.pixels(PetStage.StripScene(frames: frames, aggregate: aggregate, pet: frame, crop: strip,
                                                           desktop: false), size: strip.size)
            for y in 0..<with.height {
                for x in 0..<with.width where without.alpha(x, y) > 128 && without.value(x, y) > 100 {
                    XCTAssertGreaterThanOrEqual(Int(with.value(x, y)) + 2, Int(without.value(x, y)), "darker at \(x),\(y), t = \(t)")
                }
            }
            for (x, y) in counters {
                XCTAssertLessThan(with.value(x, y), 64, "a counter lit at \(x),\(y), t = \(t)")
            }
        }
    }

    /// The satisfied flare is soft. Measured as the mean linear luminance of a 50 × 32 pt region round
    /// the pet, it rises over at least six frames at 60 fps, never by more than 2 % of the region's light
    /// in one frame, and brightens the region by at most 15 %, the fuller light it keeps included: a
    /// flare that brightens by a third within three frames flashes in the corner of the eye at every
    /// meal.
    func testTheFlareIsSoft() throws {
        let reel = PetReels.tour
        let rig = PetRig()
        let anchor = reel.zones(at: 6).strip!.anchor
        let region = CGRect(x: Double(anchor.x) - 25, y: 0, width: 50, height: 32)
        func luminance(_ t: Double) throws -> Double {
            let px = try Self.pixels(PetStage.PetLayer(frame: reel.pet(rig, at: t), palette: .standard)
                .offset(x: -region.minX, y: -region.minY), size: region.size)
            func linear(_ v: UInt8) -> Double {
                let c = Double(v) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            var sum = 0.0
            for i in stride(from: 0, to: px.bytes.count, by: 4) {
                sum += 0.2126 * linear(px.bytes[i]) + 0.7152 * linear(px.bytes[i + 1]) + 0.0722 * linear(px.bytes[i + 2])
            }
            return sum / Double(px.width * px.height)
        }
        let m = PetRigActions.timing(PetReelScript.meal(.full, chews: 3))
        let splash = 5.0 + m.splash
        let before = try luminance(splash - 1.0 / 60)
        let after = try (0..<60).map { try luminance(splash + Double($0) / 60) }
        let peak = after.indices.max { after[$0] < after[$1] }!
        XCTAssertLessThanOrEqual(after[peak] / before, 1.15)
        let half = after.firstIndex { $0 - before >= 0.5 * (after[peak] - before) }!
        XCTAssertGreaterThanOrEqual(peak, 6, "it eases in")
        XCTAssertGreaterThanOrEqual(half, 2, "no jump in the first frames")
        // Every frame from the swallow on: the light dropping through the body, the splash, the flare.
        let frames = try (0..<Int((m.splash - m.swallowStart + 1) * 60)).map { try luminance(5.0 + m.swallowStart + Double($0) / 60) }
        for (n, (a, b)) in zip(frames, frames.dropFirst()).enumerated() {
            XCTAssertLessThanOrEqual(b - a, 0.02 * before,
                                     String(format: "frame %d after the swallow brightens by %.1f %%", n + 1, (b - a) / before * 100))
        }
    }

    /// `EarsView` draws as before: Brow's window with the pet's layer in it, empty or turned off, is the
    /// window without one, byte for byte, beside and below. Drawn by CoreGraphics (`PetStage.bitmap`), which
    /// gives the same bytes for the same view from the first render on.
    func testTheStripDrawsAsBeforeWithThePetsLayerInIt() throws {
        for placement in [EarsPlacement.beside, .below] {
            let frames = PetStage.frames(placement)
            let aggregate = PetStage.aggregate(left: 41)
            func window(_ layer: PetLayer?) throws -> Data {
                let model = NotchPanelModel(frames: frames, pet: layer)
                model.ears = AnyView(EarsView(aggregate: aggregate, frames: frames, drawsBackground: false)
                    .frame(width: frames.collapsed.width, height: frames.collapsed.height))
                let view = NotchRootView(model: model).environment(\.colorScheme, .dark)
                    .frame(width: frames.expanded.width, height: frames.expanded.height, alignment: .topLeading)
                return try PetStage.bytes(PetStage.bitmap(view, scale: 2))
            }
            let without = try window(nil)
            XCTAssertEqual(try window(PetLayer()), without, "\(placement): an empty layer")
            let off = PetLayer()
            off.timeline = PetReelScript([(0, .idle(.content)), (1, .off)]).timeline
            off.zones = PetStage.zones(frames, aggregate)
            off.isOn = false
            off.now = { 5 }
            XCTAssertEqual(try window(off), without, "\(placement): the pet turned off")
        }
    }

    /// Nothing of the pet, its light, its particles or its food is ever drawn in the notch, where a
    /// MacBook has no pixels. Rendered without the outline's clip, every third frame of the 16 s tour and
    /// of the den reels.
    func testNothingIsDrawnInTheNotch() throws {
        var reels: [(String, PetReel)] = [("tour", PetReels.tour)]
        reels += [("den beside", PetReels.den(.beside)), ("den below", PetReels.den(.below))]
        for (name, reel) in reels {
            let notch = try XCTUnwrap(reel.zones(at: 0).notch)
            // The notch and a margin left of it, so the mask's edge is checked too.
            let crop = CGRect(x: notch.minX - 4, y: 0, width: 60, height: notch.height + 24)
            let rig = PetRig()
            for n in stride(from: 0, to: Int(reel.duration * 60), by: 3) {
                let t = Double(n) / 60
                let pet = try petInk(reel.pet(rig, at: t), crop: crop, food: true)
                var worst: UInt8 = 0
                for y in 0..<Int(notch.height * 2) {
                    for x in 8..<pet.width { worst = max(worst, pet.alpha(x, y)) }
                }
                XCTAssertLessThanOrEqual(worst, 8, "\(name): ink in the notch at t = \(t)")
            }
        }
    }
}
