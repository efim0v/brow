// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Artem Efimov

import XCTest
import SwiftUI
import AppKit
@testable import GroveAppKit

@MainActor
final class WindowSubstrateTests: XCTestCase {

    private func makePanelAndHost() -> (NSPanel, NSHostingController<AnyView>) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        let h = NSHostingController(rootView: AnyView(Color.clear))
        return (p, h)
    }

    /// The host keeps the choice in its own settings; a stored value reads back as a
    /// style, and anything else is the default.
    func testAStoredStyleReadsBackAndAnythingElseIsLiquidGlass() {
        XCTAssertEqual(WindowSubstrateStyle(stored: nil), .liquidGlass)
        XCTAssertEqual(WindowSubstrateStyle(stored: "visualEffect"), .visualEffect)
        XCTAssertEqual(WindowSubstrateStyle(stored: "garbage"), .liquidGlass)
        XCTAssertEqual(WindowSubstrateStyle.groveDefaultsKey, "GroveWindowSubstrateStyle",
                       "the key Grove.app wrote, which Brow copies once")
    }

    /// A change of the current style is what makes an open panel swap its substrate.
    func testChangingTheCurrentStylePostsTheSwap() {
        let saved = WindowSubstrateStyle.current
        defer { WindowSubstrateStyle.current = saved }
        WindowSubstrateStyle.current = .liquidGlass
        let posted = expectation(forNotification: .groveSubstrateStyleChanged, object: nil)
        WindowSubstrateStyle.current = .visualEffect
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(WindowSubstrateStyle.current, .visualEffect)
    }

    func testInstallVisualEffectIsConstantBehindWindowSubstrate() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .visualEffect, in: p)
        guard let effect = p.contentView as? NSVisualEffectView else {
            return XCTFail("expected an NSVisualEffectView substrate")
        }
        // The M1 recipe: always-active (never dims on key change), behind-window,
        // very transparent material, clipped to the panel radius, host embedded.
        XCTAssertEqual(effect.state, .active)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.layer?.cornerRadius, 12)
        XCTAssertTrue(effect.subviews.contains(h.view))
    }

    func testInstallLiquidGlassUsesGlassSubstrate() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .liquidGlass, in: p)
        XCTAssertTrue(p.contentView is NSGlassEffectView)
    }

    func testReinstallLiveSwapsSubstrateReparentingTheSameHost() {
        let (p, h) = makePanelAndHost()
        WindowSubstrate.install(h, radius: 12, style: .liquidGlass, in: p)
        XCTAssertTrue(p.contentView is NSGlassEffectView)

        WindowSubstrate.install(h, radius: 12, style: .visualEffect, in: p)
        guard let effect = p.contentView as? NSVisualEffectView else {
            return XCTFail("expected the substrate to swap to NSVisualEffectView")
        }
        // The SAME hosting view is re-parented into the new backing (live swap, no loss).
        XCTAssertTrue(effect.subviews.contains(h.view))
        XCTAssertFalse(h.view.superview is NSGlassEffectView)
    }
}
