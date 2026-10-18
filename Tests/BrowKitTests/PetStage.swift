// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// The pet on Brow's own views, for the render tests and the showreels: the real `EarsView` for the strip,
/// the real `NotchShape` outline, and the pet layer laid out as `NotchRootView` will lay it (its canvas
/// offset to `frame.canvas`, clipped to the outline). Only the desktop and the menu bar behind them are
/// stand-ins. Nothing here reads a clock or any real data.
enum PetStage {
    /// A MacBook Pro 14": 1512 × 982 pt, a 185 × 32 pt notch from x 663.5.
    static let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       topLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                       topRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                       menuBarHeight: 33, notchHeight: 32)
    /// A 2560 pt display with no notch: the pill.
    static let plain = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                     topLeftArea: nil, topRightArea: nil, menuBarHeight: 24, notchHeight: 0)

    static func frames(_ placement: EarsPlacement, notch: Bool = true, expandedHeight: CGFloat = 300) -> NotchFrames {
        NotchGeometry.frames(for: notch ? notched : plain, expandedHeight: expandedHeight, placement: placement)
    }

    /// A readout pair as the strip shows it.
    static func aggregate(left: Double, right: Double = 63, hasData: Bool = true, stale: Bool = false,
                          initial: String? = nil) -> LimitsAggregate {
        let l = EarReadout(usedPercentage: left, modelInitial: nil, severity: LimitsAggregate.severity(left), stale: stale)
        let r = EarReadout(usedPercentage: right, modelInitial: initial, severity: LimitsAggregate.severity(right), stale: stale)
        return LimitsAggregate(fiveHour: left, weekly: right, weeklyScoped: nil, stale: stale, hasData: hasData,
                               leftEar: l, rightEar: r)
    }

    static func zones(_ frames: NotchFrames, _ aggregate: LimitsAggregate, showEars: Bool = true) -> PetZones {
        PetLayout.zones(frames: frames, aggregate: aggregate, showEars: showEars, fiveHour: nil)
    }

    /// The strip with the pet, cropped to `crop` (window coordinates).
    struct StripScene: View {
        let frames: NotchFrames
        let aggregate: LimitsAggregate
        let pet: PetFrame?
        let crop: CGRect
        var palette: PetPalette = .standard
        var dim: Double = 0
        var pointer: CGPoint?
        var desktop = true

        var body: some View {
            let strip = PetLayout.window(frames.collapsed, in: frames)
            ZStack(alignment: .topLeading) {
                if desktop { Desktop(dim: dim).frame(width: crop.width, height: crop.height) }
                EarsView(aggregate: aggregate, frames: frames)
                    .frame(width: strip.width, height: strip.height)
                    .offset(x: strip.minX - crop.minX, y: strip.minY - crop.minY)
                if let pet {
                    PetLayer(frame: pet, palette: palette)
                        .offset(x: -crop.minX, y: -crop.minY)
                        .mask(alignment: .topLeading) {
                            Outline(frames: frames)
                                .frame(width: strip.width, height: strip.height)
                                .offset(x: strip.minX - crop.minX, y: strip.minY - crop.minY)
                        }
                }
                if let pointer { Pointer().offset(x: pointer.x - crop.minX, y: pointer.y - crop.minY) }
            }
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .dark)
        }
    }

    /// The pet's canvas placed in window coordinates, as the layer in `NotchRootView` places it.
    struct PetLayer: View {
        let frame: PetFrame
        let palette: PetPalette
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                PetCanvas(frame: frame, palette: palette)
                    .offset(x: frame.canvas.minX, y: frame.canvas.minY)
            }
            .frame(width: 2000, height: 600, alignment: .topLeading)
        }
    }

    /// Brow's outline for these frames: the notch shape, or the pill's rounded rectangle.
    struct Outline: View {
        let frames: NotchFrames
        var body: some View {
            if frames.hasNotch {
                NotchShape(topFlare: frames.flare, bottomRadius: NotchGeometry.collapsedBottomRadius).fill(Color.black)
            } else {
                RoundedRectangle(cornerRadius: NotchGeometry.collapsedBottomRadius, style: .continuous).fill(Color.black)
            }
        }
    }

    /// A dark wallpaper under a translucent menu bar: the stand-in desktop.
    struct Desktop: View {
        var dim: Double = 0
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.21), Color(red: 0.14, green: 0.12, blue: 0.22)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.13, green: 0.29, blue: 0.35).opacity(0.7), .clear],
                               center: UnitPoint(x: 0.2, y: 1.2), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [Color(red: 0.25, green: 0.16, blue: 0.31).opacity(0.7), .clear],
                               center: UnitPoint(x: 0.85, y: 1.4), startRadius: 0, endRadius: 360)
                Rectangle().fill(Color.black.opacity(0.24)).frame(height: 33)
                Color.black.opacity(0.35 * dim)
            }
        }
    }

    /// The arrow pointer, tip at the origin.
    struct Pointer: View {
        var body: some View {
            Canvas { ctx, _ in
                var arrow = Path()
                let pts: [(Double, Double)] = [(0, 0), (0, 15.6), (3.7, 12.2), (6.2, 17.7), (8.5, 16.7), (6.0, 11.4), (10.9, 11.1)]
                arrow.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
                for q in pts.dropFirst() { arrow.addLine(to: CGPoint(x: q.0, y: q.1)) }
                arrow.closeSubpath()
                ctx.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 2.0, lineJoin: .round))
                ctx.fill(arrow, with: .color(.black))
            }
            .frame(width: 14, height: 20)
        }
    }

    // MARK: Rendering

    /// The view as SwiftUI's own rasterizer draws it, for pictures and for measurements.
    @MainActor
    static func image<V: View>(_ view: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = true
        return try XCTUnwrap(renderer.cgImage, "nothing rendered")
    }

    /// The view drawn by CoreGraphics into a bitmap of its own (8-bit sRGB, premultiplied, `scale` pixels a
    /// point), for comparisons byte for byte: the same view gives the same bytes every time, from a
    /// process's first render on. Through `image(_:scale:)` it would not: early in a process SwiftUI's
    /// rasterizer switches how it draws gradients and antialiased edges, a level apart here and there, and
    /// when it switches varies from run to run.
    @MainActor
    static func bitmap<V: View>(_ view: V, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        // Lays the view out on the pixel grid of `scale`, as `image(_:scale:)` does; the context draws at
        // the same scale, so the two put every edge in the same pixel.
        renderer.scale = scale
        var image: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            image = context.makeImage()
        }
        return try XCTUnwrap(image, "nothing rendered")
    }

    /// The pixels of a `bitmap(_:scale:)`, four bytes each with no padding: two of one size are the same
    /// picture exactly when these are equal.
    static func bytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data as Data?, "no pixels")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// A labelled grid of rendered images, drawn 1:1.
    struct Sheet: View {
        let title: String
        let cells: [(image: CGImage, label: String)]
        let columns: Int
        var labelSize: CGFloat = 20

        var body: some View {
            let w = CGFloat(cells.map { $0.image.width }.max() ?? 0)
            VStack(alignment: .leading, spacing: 14) {
                if !title.isEmpty {
                    Text(title).font(.system(size: labelSize * 1.15, weight: .semibold)).foregroundStyle(.white)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(0..<((cells.count + columns - 1) / columns), id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { col in
                                let i = row * columns + col
                                if i < cells.count {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Image(decorative: cells[i].image, scale: 1)
                                            .overlay(Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                        Text(cells[i].label).font(.system(size: labelSize, weight: .medium))
                                            .foregroundStyle(Color(white: 0.85)).frame(width: w, alignment: .leading)
                                    }
                                } else {
                                    Color.clear.frame(width: w, height: 1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(white: 0.07))
        }
    }
}
