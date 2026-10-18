// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
@testable import BrowKit

/// The panel header's words, through the real `PetHeaderRow`. Each line is one line, so one too long for
/// its column loses its end to an ellipsis: the hibernating detail its wake time, the good week its number.
/// A line is whole when the row draws it as a row with all the room it wants does: the words start at the
/// same x in both, so the two images agree left of the meter unless the line was cut. Nothing here measures
/// a font.
@MainActor
final class PetHeaderRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)       // 2026-10-15 12:00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let calendar = Calendar(identifier: .gregorian)

    /// The panel's content width, with a notch (472 pt) and without one (460 pt).
    private let panels: [(name: String, width: Double)] = [
        ("notched", Double(NotchGeometry.expandedWidth + 2 * NotchGeometry.flare - 2 * PanelView.padding)),
        ("no notch", Double(NotchGeometry.expandedWidth - 2 * PanelView.padding)),
    ]

    /// The longest form of each line the header can show: the widest wake date of the year, a reset not
    /// known yet, a meal 59 min ago in a well-fed week, a streak of 100 days, and a good week at 100 %
    /// for one account and for one of several.
    private func longest() -> [PetText.Header] {
        let widestDate = Date(timeIntervalSince1970: 1_811_652_240)    // 2027-05-30 04:44:00 UTC
        let meal = now.addingTimeInterval(-(59 * 60 + 30))
        func header(_ situation: PetStatus.Situation, moments: [PetMomentLine] = [],
                    names: [String: String] = [:]) -> PetText.Header {
            PetText.header(PetStatus(situation: situation, meter: 40, lastMeal: meal, lastMealPoints: 3, pace: 0.5,
                                     moments: moments),
                           now: now, timeZone: utc, calendar: calendar, names: names)
        }
        return [
            header(.hibernating(wakesAt: widestDate)),
            header(.hibernating(wakesAt: nil)),
            header(.asleep(wakesAt: widestDate)),
            header(.asleep(wakesAt: nil)),
            header(.noAccounts),
            header(.awake(mood: .peckish), moments: [.streak(days: 100)]),
            header(.awake(mood: .content), moments: [.goodWeek(account: "o1", used: 100)], names: ["o1": "Personal"]),
            header(.awake(mood: .content), moments: [.goodWeek(account: "o1", used: 100)],
                   names: ["o1": "Personal", "o2": "Work"]),
        ]
    }

    func testEveryLineTheHeaderCanShowFitsWholeOnBothPanels() throws {
        let lines = longest()
        XCTAssertEqual(lines[0].detail, "Weekly limit used up · wakes 30 May 04:44")
        XCTAssertEqual(lines[7].moment, "Good week: 100 % used · Personal")
        for panel in panels {
            let meter = Int(PetTuning.Panel.meterWidth * 2)
            for header in lines {
                let row = try render(header, width: panel.width)
                let roomy = try render(header, width: panel.width + 400)
                XCTAssertEqual(row.height, roomy.height)
                let cut = differingPixels(row, roomy, columns: row.width - meter)
                XCTAssertEqual(cut, 0, "\(panel.name): '\(header.detail)' / '\(header.moment ?? "")' is cut")
            }
        }
    }

    // MARK: Rendering

    private struct Pixels {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    /// The row `PanelView` lays out at `width`, at 2x, as straight RGBA bytes.
    private func render(_ header: PetText.Header, width: Double) throws -> Pixels {
        let model = PetPanelModel()
        model.header = header
        model.meter = 40
        let renderer = ImageRenderer(content: PetHeaderRow(model: model)
            .frame(width: width)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "the row rendered nothing")
        var pixels = Pixels(bytes: [UInt8](repeating: 0, count: image.width * image.height * 4),
                            width: image.width, height: image.height)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// How many of the first `columns` pixels of each row differ between `a` and `b`.
    private func differingPixels(_ a: Pixels, _ b: Pixels, columns: Int) -> Int {
        var count = 0
        for y in 0..<min(a.height, b.height) {
            for x in 0..<columns {
                let i = (y * a.width + x) * 4, j = (y * b.width + x) * 4
                if a.bytes[i..<i + 4] != b.bytes[j..<j + 4] { count += 1 }
            }
        }
        return count
    }
}
