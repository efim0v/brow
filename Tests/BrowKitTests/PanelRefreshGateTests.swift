import XCTest
import SwiftUI
import GroveCore
@testable import BrowKit

/// The ⟳ button, as it is actually drawn.
///
/// Spec, The cycle §7, verbatim: "⟳ is disabled only while a *forced* fetch is running
/// (`isForcing`), never for a background cycle." `LimitsStoreTests.testIsForcingIsTheOnlyRefreshGate`
/// pins the STORE's two flags and passed all along — while the shipping view read
/// `.disabled(store.isRefreshing)` and greyed the button out for every background cycle:
/// up to 210 s of `doctor` + `-p`, and the whole watchdog window when a cycle hangs. That
/// is precisely the "⟳ is dead" symptom in the spec's own Problem statement, and no store
/// test can see it. This one renders the panel and reads the pixels back, like
/// `EarsViewFillTests`.
@MainActor
final class PanelRefreshGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }
    private let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    private var home: URL!
    private var appDir: String!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("gate-home")
        appDir = try Fixture.tempDir("gate-app").path
        clock.date = t0
    }

    func testTheRefreshButtonIsLiveDuringABackgroundCycleAndOnlyTheForcedOneGreysIt() async throws {
        let dir = try makeAccount()
        let creds = Creds(); creds.expiry[dir] = t0.addingTimeInterval(3600)
        let fetcher = Fetcher()
        let bearer = "Bearer tok-\(dir)"
        fetcher.responses[bearer] = (Self.body, 200)
        addTeardownBlock { fetcher.releaseAll() }
        let store = makeStore(fetcher: fetcher, creds: creds)

        // One complete cycle, so every later render draws the same rows and the same
        // footer and the ONLY thing that can differ is the button.
        await store.refresh(force: false)
        XCTAssertNotNil(store.rows.first?.snapshot, "fixture check: there are numbers on screen")

        clock.date = t0.addingTimeInterval(60)          // past the client's 30 s cache
        let idle = try button(of: render(store))
        XCTAssertGreaterThan(idle, 0, "fixture check: the ⟳ really is in the box being measured")

        // A background cycle is out: `isRefreshing` is true, `isForcing` is not.
        fetcher.holdNextCall(for: bearer)
        let background = Task { await store.refresh(force: false) }
        try await waitUntil("the background cycle to be out") { fetcher.parkedCalls == 1 }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertFalse(store.isForcing)
        let duringBackground = try button(of: render(store))
        XCTAssertEqual(duringBackground, idle, accuracy: 0.002,
                       "a background poll must leave the only manual refresh exactly as it was")
        fetcher.releaseAll()
        await background.value

        // …and the forced one does gate it, which is also what proves the measurement
        // above is sensitive to the button's state at all.
        clock.date = t0.addingTimeInterval(120)
        fetcher.holdNextCall(for: bearer)
        let forced = Task { await store.refresh(force: true) }
        try await waitUntil("the forced cycle to be out") { fetcher.parkedCalls == 1 }
        XCTAssertTrue(store.isForcing)
        let duringForced = try button(of: render(store))
        XCTAssertNotEqual(duringForced, idle, accuracy: 0.002,
                          "a forced fetch swaps the glyph for the spinner and disables the button")
        fetcher.releaseAll()
        await forced.value
    }

    // MARK: the button's own pixels

    /// Mean ink in the 20 × 20 pt box the ⟳ button occupies, measured from the panel's
    /// bottom-right corner: bottom padding 14, then the ⚙ (20 pt), then 8 pt of spacing.
    /// Reading a box rather than the whole image keeps the assertion clear of the footer
    /// text, which legitimately changes as the data ages.
    private func button(of rep: NSBitmapImageRep) throws -> Double {
        let x0 = rep.pixelsWide - 62, y0 = rep.pixelsHigh - 34
        try XCTSkipIf(x0 < 0 || y0 < 0, "the panel rendered smaller than its own footer")
        var total = 0.0
        for x in x0..<(x0 + 20) {
            for y in y0..<(y0 + 20) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += c.alphaComponent * (c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
        }
        return total / 400
    }

    private func render(_ store: LimitsStore) throws -> NSBitmapImageRep {
        let view = PanelView(store: store, clock: PanelClock(now: { [clock] in clock.date }),
                             topInset: 40, flare: NotchGeometry.flare,
                             onSettings: {}, onRefresh: {})
            .frame(width: NotchGeometry.expandedWidth + 2 * NotchGeometry.flare)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage, "SwiftUI rendered nothing"))
    }

    // MARK: fixture

    private static let body = Data(#"""
        {"five_hour":{"utilization":40,"resets_at":"2026-09-16T20:00:00Z"},
         "seven_day":{"utilization":60,"resets_at":"2026-09-22T00:00:00Z"}}
        """#.utf8)

    private func makeAccount() throws -> String {
        let dir = home.appendingPathComponent(".claude-accounts/a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["organizationUuid": "org-a", "emailAddress": "a@x",
                             "organizationRateLimitTier": "default_claude_max_20x"]])
        try json.write(to: dir.appendingPathComponent(".claude.json"))
        return dir.path
    }

    private func makeStore(fetcher: Fetcher, creds: Creds) -> LimitsStore {
        LimitsStore(deps: .init(
            directory: AccountDirectory(home: home.path, credentials: creds),
            keeper: TokenKeeper(runner: MockRunnerBK(results: []), credentials: creds,
                                claudePath: "/x/claude", allowPromptFallback: { false },
                                now: { [clock] in clock.date }),
            client: OAuthUsageClient(fetcher: fetcher, appVersion: "t",
                                     cacheSeconds: 30, backoffCap: 300, credentials: creds),
            snapshotStore: LimitSnapshotStore(directory: appDir),
            settingsStore: BrowSettingsStore(directory: appDir),
            now: { [clock] in clock.date }))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private final class Creds: CredentialsReading, @unchecked Sendable {
        private let lock = NSLock()
        private var expiries: [String: Date] = [:]
        var expiry: [String: Date] {
            get { lock.withLock { expiries } }
            set { lock.withLock { expiries = newValue } }
        }
        func token(configDir: String) -> ClaudeToken? {
            lock.withLock { expiries[configDir].map { ClaudeToken(value: "tok-\(configDir)", expiresAt: $0) } }
        }
        func invalidate(configDir: String) {}
    }

    /// Parks one request per armed bearer so a cycle can be held mid-flight.
    private final class Fetcher: UsageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [String: (Data, Int)] = [:]
        private var held: Set<String> = []
        private var parked: [CheckedContinuation<Void, Never>] = []
        var responses: [String: (Data, Int)] {
            get { lock.withLock { scripted } }
            set { lock.withLock { scripted = newValue } }
        }
        var parkedCalls: Int { lock.withLock { parked.count } }
        func holdNextCall(for bearer: String) { lock.withLock { _ = held.insert(bearer) } }
        func releaseAll() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                held.removeAll()
                let all = parked
                parked = []
                return all
            }
            waiting.forEach { $0.resume() }
        }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let (park, response) = lock.withLock { () -> (Bool, (Data, Int)) in
                (held.remove(bearer) != nil, scripted[bearer] ?? (Data("{}".utf8), 500))
            }
            if park {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { parked.append(continuation) }
                }
            }
            return response
        }
    }
}
