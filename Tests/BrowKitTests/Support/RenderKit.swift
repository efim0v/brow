// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import GroveAppKit
@testable import BrowKit

/// What the renders of the one window are composed and written with: a stand-in desktop with
/// a caption, labels, stills, PNGs at 2×, AppKit views in an offscreen window, a menu drawn
/// in SwiftUI.
@MainActor
enum RenderKit {
    // MARK: - Composition

    /// `views` hanging from the top edge of a stand-in desktop — cream under a lighter menu bar,
    /// or a dark one — side by side (or stacked), with a one-line caption under them.
    static func scene(_ views: [AnyView], axis: Axis = .horizontal, dark: Bool = false, caption: String) -> some View {
        let desktop = dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0xF3 / 255, green: 0xE8 / 255, blue: 0xD2 / 255)
        let menuBar = dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0xFA / 255, green: 0xF4 / 255, blue: 0xE7 / 255)
        let ink = dark ? Color.white.opacity(0.62) : Color(red: 0x5A / 255, green: 0x50 / 255, blue: 0x42 / 255)
        let stack = Group {
            if axis == .horizontal {
                HStack(alignment: .top, spacing: 36) { ForEach(views.indices, id: \.self) { views[$0] } }
            } else {
                VStack(alignment: .leading, spacing: 36) { ForEach(views.indices, id: \.self) { views[$0] } }
            }
        }
        return VStack(alignment: .leading, spacing: 18) {
            stack.padding(.horizontal, 64)
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 20)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                desktop
                menuBar.frame(height: 33)
            }
        }
        .fixedSize()
    }

    /// A small label under a panel in a side-by-side picture.
    static func labelled<V: View>(_ label: String, _ view: V) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 8) {
            view
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(red: 0x5A / 255, green: 0x50 / 255, blue: 0x42 / 255))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.7)))
        })
    }

    // MARK: - Writing

    /// `view` drawn now, @2x, as an image to place in a bigger picture.
    static func still<V: View>(_ view: V) throws -> AnyView {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return AnyView(Image(decorative: try eightBit(image), scale: 2))
    }

    static func write<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "no image for \(url.lastPathComponent)")
        let rep = NSBitmapImageRep(cgImage: try eightBit(image))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("one-window render: \(url.path) \(image.width)x\(image.height)")
    }

    /// 8 bits a channel: ImageRenderer hands back half floats with an `NSImage` in the tree, which
    /// come out dithered in a PNG.
    static func eightBit(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent != 8 else { return image }
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    /// Settings in a real window far off every screen, never activated — its `Form` and `TabView`
    /// are AppKit-backed and draw only there — its scrolling form at its full height, @2x.
    static func renderInWindow<V: View>(_ view: V, appearance: NSAppearance.Name = .darkAqua, to url: URL) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.displayIfNeeded()
        defer { window.close() }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let target = scrollViews(in: host).max { $0.frame.height < $1.frame.height }?.documentView ?? host
        let bounds = target.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        target.cacheDisplay(in: bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("one-window render: \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}

/// A macOS menu drawn in SwiftUI, for renders: a real `NSMenu` draws only on screen. Its lines come
/// from the same data the live menus are built from (`SessionMenu.items`, `NotchGearMenu.items`).
struct MenuLook: View {
    struct Line {
        var title: String
        var detail: String? = nil
        var shortcut: String? = nil
        var dot: Color? = nil
        var submenu = false
        var separator = false
        var destructive = false
        var disabled = false
        var highlighted = false
    }

    let lines: [Line]
    var width: CGFloat = 250

    static func lines(_ items: [SessionMenuItem], open: String?) -> [Line] {
        items.map { item in
            if case .separator = item.kind { return Line(title: "", separator: true) }
            var submenu = false
            if case .submenu = item.kind { submenu = true }
            return Line(title: item.title, detail: item.detail, shortcut: item.shortcut, dot: item.dot, submenu: submenu,
                        destructive: item.destructive, disabled: !item.enabled, highlighted: item.id == open)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if line.separator {
                    Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                } else {
                    row(line)
                }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 7) {
            if let dot = line.dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(line.title)
                .foregroundStyle(line.disabled ? Color.white.opacity(0.35)
                                 : line.destructive ? Color(red: 1, green: 0.42, blue: 0.40) : Color.white)
            if let detail = line.detail {
                Text(detail).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let shortcut = line.shortcut {
                Text(shortcut).foregroundStyle(Color.white.opacity(line.disabled ? 0.25 : 0.5))
            }
            if line.submenu {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            if line.highlighted {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(red: 0.16, green: 0.42, blue: 0.86))
            }
        }
    }
}
