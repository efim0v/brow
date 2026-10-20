// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import GroveAppKit

/// A session card in a host that follows the pointer itself (Brow's notch, where SwiftUI's
/// `onHover` does not fire): the card says where it is, and draws its Go or Resume and its
/// menu when the host says the pointer is over it.
@MainActor
final class SessionCardHoverTests: XCTestCase {
    private func card(_ state: AppState) -> SessionPreviewCard {
        let row = ProjectSessionRow(sessionId: "s-checkout", title: "checkout redesign", cwd: "/Users/demo/Code/acme-shop",
                                    location: "checkout", accountName: "work",
                                    lastActivity: Date().addingTimeInterval(-600), state: .yourTurn,
                                    cmuxWorkspaceId: nil,
                                    preview: SessionPreview(prompt: "make the address step validate inline",
                                                            reply: "The address step validates inline now.",
                                                            tool: nil, title: "checkout redesign", turn: .answered,
                                                            at: nil))
        return SessionPreviewCard(state: state, row: row)
    }

    /// The card's picture: its second one, since the first picture of a view can differ in a
    /// few pixels from every later one.
    private func png<V: View>(_ view: V) throws -> Data {
        var data = Data()
        for _ in 0..<2 {
            let renderer = ImageRenderer(content: view.frame(width: 432).environment(\.colorScheme, .dark))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        return data
    }

    func testACardSaysWhereItIsAndShowsItsActionsWhenTheHostSaysThePointerIsOverIt() throws {
        let url = try FixtureLite.tempDir("card-hover").appendingPathComponent("config.json")
        let state = AppState(configStore: ConfigStore(url: url))
        final class Seen: @unchecked Sendable { var frames: [String: CGRect] = [:] }
        let seen = Seen()
        _ = try png(card(state).onPreferenceChange(SessionCardFrames.self) { seen.frames = $0 })
        let frame = try XCTUnwrap(seen.frames["s-checkout"], "the card reports its frame by its session")
        XCTAssertEqual(frame.width, 432, accuracy: 0.5)
        XCTAssertGreaterThan(frame.height, 30)

        let resting = try png(card(state))
        XCTAssertEqual(resting, try png(card(state)), "the same card draws the same")
        let underThePointer = try png(card(state).environment(\.hostHoveredSession, "s-checkout"))
        let another = try png(card(state).environment(\.hostHoveredSession, "s-other"))
        XCTAssertNotEqual(underThePointer, resting, "Resume and the menu in place of the age")
        XCTAssertEqual(another, resting, "another card under the pointer changes nothing here")
    }
}
