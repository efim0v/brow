import XCTest
import SwiftUI
import GroveCore
@testable import BrowKit

/// The expanded panel, rendered.
///
/// `NotchGeometryTests` proves the FRAME is right and `NotchShapeTests` proves the path
/// fills whatever rect it is handed — and the panel still clipped itself to a notch it
/// did not have on every external display, because `PanelView` hard-coded
/// `NotchGeometry.flare` while the frame it was drawn into carried `frames.flare == 0`.
/// Only a render can see that. Same technique as `EarsViewFillTests`, one view down.
@MainActor
final class PanelViewShapeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var home: URL!
    private var appDir: String!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("panel-shape-home")
        appDir = try Fixture.tempDir("panel-shape-app").path
    }

    // MARK: the outline

    /// The notched panel: `NotchShape`'s vertical edges sit `flare` inside the frame,
    /// because the frame was widened by exactly that much so the concave corners have
    /// room. This is the half that was always right, pinned so the fix cannot flatten it.
    func testTheNotchedPanelKeepsItsFlaredEdges() throws {
        let rep = try render(topInset: 40, flare: NotchGeometry.flare,
                             width: NotchGeometry.expandedWidth + 2 * NotchGeometry.flare)
        let middle = rep.pixelsHigh / 2
        XCTAssertFalse(isOpaque(rep, x: 2, y: middle),
                       "the 6 pt the flare was given must stay outside the black")
        XCTAssertTrue(isOpaque(rep, x: 10, y: middle), "and the black starts just inside it")
    }

    /// The no-notch panel: the frame is the un-widened 460 pt and there is no notch to
    /// match, so clipping it with a 6 pt flare took ~6 pt of black off BOTH sides for the
    /// full height and put two concave corners above a collapsed pill whose own corners
    /// are square.
    func testThePanelWithoutANotchIsNotClippedToOne() throws {
        let rep = try render(topInset: 8, flare: 0, width: NotchGeometry.expandedWidth)
        let middle = rep.pixelsHigh / 2
        XCTAssertTrue(isOpaque(rep, x: 2, y: middle),
                      "no notch, no flare: the black reaches the edge of its own window")
        XCTAssertTrue(isOpaque(rep, x: rep.pixelsWide - 3, y: middle), "on both sides")
    }

    // MARK: the top padding

    /// `contentTopInset` REPLACES the top padding, and on a screen with no notch to clear
    /// it is 8 — against an unchanged 14 at the bottom. The floor is compared against a
    /// render that is already 14, so the assertion does not depend on font metrics.
    func testThePanelWithoutANotchStillHasFourteenPointsOfTopPadding() throws {
        let floored = try firstInkRow(try render(topInset: 8, flare: 0, width: NotchGeometry.expandedWidth))
        let explicit = try firstInkRow(try render(topInset: PanelView.padding, flare: 0,
                                                  width: NotchGeometry.expandedWidth))
        XCTAssertEqual(floored, explicit,
                       "an 8 pt top against a 14 pt bottom is an asymmetry no display should get")
    }

    // MARK: rendering

    private func render(topInset: CGFloat, flare: CGFloat, width: CGFloat) throws -> NSBitmapImageRep {
        let store = makeStore()
        let view = PanelView(store: store, clock: PanelClock(now: { [t0] in t0 }),
                             topInset: topInset, flare: flare,
                             onSettings: {}, onRefresh: {})
            .frame(width: width)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI rendered nothing")
        return NSBitmapImageRep(cgImage: image)
    }

    private func makeStore() -> LimitsStore {
        let creds = SilentCreds()
        return LimitsStore(deps: .init(
            directory: AccountDirectory(home: home.path, credentials: creds),
            keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                claudePath: "/x/claude", allowPromptFallback: { false }),
            client: OAuthUsageClient(fetcher: UnusedFetcher(), appVersion: "t",
                                     cacheSeconds: 30, backoffCap: 300, credentials: creds),
            snapshotStore: LimitSnapshotStore(directory: appDir),
            settingsStore: BrowSettingsStore(directory: appDir),
            now: { [t0] in t0 }))
    }

    private final class SilentCreds: CredentialsReading, @unchecked Sendable {
        func token(configDir: String) -> ClaudeToken? { nil }
        func invalidate(configDir: String) {}
    }

    private final class UnusedFetcher: UsageFetching, @unchecked Sendable {
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            XCTFail("the panel must not fetch anything to draw itself")
            return (Data(), 500)
        }
    }

    // MARK: pixels

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private func isOpaque(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        pixel(rep, x, y).a > 0.9
    }

    /// The first row carrying something that is not the black fill — i.e. where the
    /// "Overall" line starts.
    private func firstInkRow(_ rep: NSBitmapImageRep) throws -> Int {
        for y in 0..<rep.pixelsHigh {
            let inked = (0..<rep.pixelsWide).contains { x in
                let p = pixel(rep, x, y)
                return p.a > 0.5 && (p.r > 0.3 || p.g > 0.3 || p.b > 0.3)
            }
            if inked { return y }
        }
        throw XCTSkip("the panel drew no content at all")
    }
}
