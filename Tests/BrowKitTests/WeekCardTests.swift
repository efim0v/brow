import XCTest
import GroveCore
@testable import BrowKit

/// The demo accounts of the README screenshots, as rows: nothing here is real.
enum WeekCardFixture {
    struct Demo {
        let name: String, five: Double, fiveResetHours: Double, week: Double, weekResetDays: Double
        let scoped: Double?
        let tier: String
        var org: String { "org-demo-\(name.lowercased())" }
        var email: String { "\(name.lowercased())@example.com" }
        var configDir: String { "/tmp/brow-card-home/.claude-accounts/\(name.lowercased())" }
    }

    static let personal = Demo(name: "Personal", five: 12, fiveResetHours: 3.7, week: 34, weekResetDays: 4.3,
                               scoped: nil, tier: "default_claude_max_5x")
    static let work = Demo(name: "Work", five: 78, fiveResetHours: 1.2, week: 61, weekResetDays: 2.1,
                           scoped: 45, tier: "default_claude_max_20x")
    static let team = Demo(name: "Team", five: 41, fiveResetHours: 4.4, week: 93, weekResetDays: 0.9,
                           scoped: nil, tier: "default_claude_max_20x")
    static let three = [personal, work, team]
    /// Three more, for the "+N more" footer.
    static let six = three + [
        Demo(name: "Side", five: 5, fiveResetHours: 2, week: 18, weekResetDays: 5, scoped: nil, tier: "default_claude_pro"),
        Demo(name: "Lab", five: 64, fiveResetHours: 0.5, week: 72, weekResetDays: 3, scoped: nil, tier: "default_claude_max_5x"),
        Demo(name: "Client", five: 22, fiveResetHours: 3, week: 40, weekResetDays: 6, scoped: nil, tier: "default_claude_pro"),
    ]

    /// `fetchedAgo` past 180 s makes the whole snapshot stale; `scopedAgo` ages only the
    /// model window, the way a statusline merge leaves it; `snapshot: false` is an
    /// account with no reading at all.
    static func row(_ d: Demo, now: Date, fetchedAgo: TimeInterval = 25, scopedAgo: TimeInterval? = nil,
                    snapshot: Bool = true) -> AccountRow {
        let iso = ISO8601DateFormatter()
        func window(_ used: Double, in seconds: Double) -> CapturedWindow {
            // On the hour, as real resets are.
            let at = (now.addingTimeInterval(seconds).timeIntervalSince1970 / 3600).rounded() * 3600
            return CapturedWindow(usedPercentage: used, resetsAt: iso.string(from: Date(timeIntervalSince1970: at)))
        }
        let account = DiscoveredAccount(organizationUuid: d.org, email: d.email, tier: d.tier, configDir: d.configDir,
                                        aliasDirs: [], tokenExpiresAt: now.addingTimeInterval(3600))
        let snap = snapshot ? LimitSnapshot(
            organizationUuid: d.org, fetchedAt: now.addingTimeInterval(-fetchedAgo),
            fiveHour: window(d.five, in: d.fiveResetHours * 3600),
            sevenDay: window(d.week, in: d.weekResetDays * 86_400),
            weeklyScoped: d.scoped.map { window($0, in: d.weekResetDays * 86_400) },
            weeklyScopedModel: d.scoped == nil ? nil : "Opus",
            scopedFetchedAt: scopedAgo.map { now.addingTimeInterval(-$0) }) : nil
        return AccountRow(account: account, name: d.email, snapshot: snap,
                          status: snap.map { $0.isStale(now: now) ? .stale : .ok } ?? .stale, tokenStatus: "fresh")
    }

    /// Every demo account named as in the README screenshots.
    static func settings(names: Bool, _ demos: [Demo] = six) -> BrowSettings {
        var s = BrowSettings()
        for d in demos { s.accounts[d.org] = AccountOverride(name: d.name, hidden: false) }
        s.cardShowNames = names
        return s
    }

    static func model(_ rows: [AccountRow], settings: BrowSettings, shape: CardShape = .wide, now: Date,
                      timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> WeekCardModel {
        let snapshots = Dictionary(uniqueKeysWithValues: rows.compactMap { r in r.snapshot.map { (r.id, $0) } })
        let aggregate = LimitsAggregate.compute(accounts: rows.map(\.account), snapshots: snapshots, now: now)
        return WeekCardModel.make(rows: rows, aggregate: aggregate, settings: settings, shape: shape,
                                  now: now, timeZone: timeZone)
    }
}

final class WeekCardTests: XCTestCase {
    private typealias F = WeekCardFixture
    /// 15 Oct 2026, 12:20 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_066_800)

    private func rows(_ demos: [F.Demo] = F.three) -> [AccountRow] { demos.map { F.row($0, now: now) } }

    func testAccountsAreNumberedWhileNamesAreOffEvenWhenTheyHaveNames() {
        let model = F.model(rows(), settings: F.settings(names: false), now: now)
        XCTAssertEqual(model.accounts.map(\.label), ["Account 1", "Account 2", "Account 3"])
    }

    /// Only a name typed in Settings — never `displayName`'s fallbacks, the email and
    /// the folder.
    func testNamesOnUseOnlyCustomNames() {
        var settings = F.settings(names: true)
        settings.accounts[F.work.org] = nil
        settings.accounts[F.team.org] = AccountOverride(name: "  \n", hidden: false)
        let model = F.model(rows(), settings: settings, now: now)
        XCTAssertEqual(model.accounts.map(\.label), ["Personal", "Account 2", "Account 3"])
    }

    /// "Account 2" on the card and in a limit warning is the same account: both count
    /// the panel's rows the same way. A notice uses a set name even with names off on
    /// the card, so only the numbered accounts have to agree.
    func testTheNumberingIsTheLimitWarnings() {
        var settings = F.settings(names: false)
        settings.accounts[F.work.org] = nil
        let rows = rows()
        let titles = rows.enumerated().map { LimitWarnings.title(for: $1, index: $0, settings: settings) }
        XCTAssertEqual(titles, ["Personal", "Account 2", "Team"])
        XCTAssertEqual(F.model(rows, settings: settings, now: now).accounts.map(\.label),
                       ["Account 1", "Account 2", "Account 3"])
        settings.cardShowNames = true
        XCTAssertEqual(F.model(rows, settings: settings, now: now).accounts.map(\.label), titles)
    }

    func testNothingIdentifiesAnAccount() {
        let identifying = F.six.flatMap { [$0.email, $0.org, $0.configDir] }
            + ["Max 20x", "Max 5x", "Pro", "example.com", ".claude-accounts"]
        for names in [false, true] {
            let dump = String(describing: F.model(rows(F.six), settings: F.settings(names: names), now: now))
            for text in identifying {
                XCTAssertFalse(dump.contains(text), "names \(names ? "on" : "off"): \(text) is on the card")
            }
            if names {
                XCTAssertTrue(dump.contains("Personal"), "fixture check: the dump carries the labels")
            } else {
                for d in F.six { XCTAssertFalse(dump.contains(d.name), "\(d.name) is on the card with names off") }
            }
        }
    }

    func testOneAccountHasNoLabelAndNoOverall() {
        let model = F.model(rows([F.work]), settings: F.settings(names: true), now: now)
        XCTAssertEqual(model.accounts.count, 1)
        XCTAssertNil(model.accounts[0].label)
        XCTAssertNil(model.overall)
        XCTAssertEqual(model.accounts[0].lines.map(\.title), ["5h", "Weekly", "Opus"])
        XCTAssertEqual(model.accounts[0].lines.map(\.used), [78, 61, 45])
    }

    func testOverallIsThePanelsAggregate() throws {
        let rows = rows()
        let model = F.model(rows, settings: F.settings(names: false), now: now)
        let overall = try XCTUnwrap(model.overall)
        let snapshots = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.snapshot!) })
        let aggregate = LimitsAggregate.compute(accounts: rows.map(\.account), snapshots: snapshots, now: now)
        XCTAssertEqual(overall.map(\.title), ["5h", "Weekly", "Opus"])
        XCTAssertEqual(overall.map(\.used), [aggregate.fiveHour, aggregate.weekly, aggregate.weeklyScoped?.percentage])
        XCTAssertEqual(overall.map(\.resets), ["", "", ""])
        XCTAssertEqual(model.stamp, "15 Oct 2026, 12:20")
    }

    func testAccountsPastCapacityAreCountedNotDrawn() {
        for shape in CardShape.allCases {
            let model = F.model(rows(F.six), settings: F.settings(names: true), shape: shape, now: now)
            XCTAssertEqual(model.accounts.count, 4, "\(shape)")
            XCTAssertEqual(model.more, 2, "\(shape)")
            XCTAssertEqual(model.accounts.map(\.label), ["Personal", "Work", "Team", "Side"])
        }
        XCTAssertEqual(F.model(rows(), settings: BrowSettings(), now: now).more, 0)
    }

    func testStalenessAndMissingWindows() {
        // The stamp is when the picture was made, so a stale reading carries its own age.
        let stale = F.model([F.row(F.work, now: now, fetchedAgo: 3 * 86_400)], settings: BrowSettings(), now: now)
        XCTAssertEqual(stale.accounts[0].lines.map(\.stale), [true, true, true])
        XCTAssertEqual(stale.accounts[0].age, "3 d ago")
        let twoStale = F.model([F.row(F.personal, now: now, fetchedAgo: 20 * 60), F.row(F.work, now: now)],
                               settings: BrowSettings(), now: now)
        XCTAssertEqual(twoStale.accounts.map(\.age), ["20 min ago", nil])

        // A statusline merge refreshes 5h and Weekly but not the model window.
        let scoped = F.model([F.row(F.work, now: now, scopedAgo: 600)], settings: BrowSettings(), now: now)
        XCTAssertEqual(scoped.accounts[0].lines.map(\.stale), [false, false, true])
        XCTAssertEqual(scoped.accounts[0].lines[0].resets, "resets in 1 h 40 min")
        XCTAssertNil(scoped.accounts[0].age, "the reading itself is fresh")

        let fresh = F.model([F.row(F.work, now: now)], settings: BrowSettings(), now: now)
        XCTAssertEqual(fresh.accounts[0].lines.map(\.stale), [false, false, false])
        XCTAssertNil(fresh.accounts[0].age)

        // No reading at all is "no data", never "not started": nothing says the
        // windows have not begun.
        let none = F.model([F.row(F.personal, now: now, snapshot: false), F.row(F.team, now: now)],
                           settings: BrowSettings(), now: now)
        XCTAssertEqual(none.accounts[0].lines, [
            .init(title: "5h", used: nil, resets: "no data", stale: true),
            .init(title: "Weekly", used: nil, resets: "no data", stale: true),
        ])
        XCTAssertNil(none.accounts[0].age)

        let started = LimitSnapshot(organizationUuid: F.personal.org, fetchedAt: now, fiveHour: nil,
                                    sevenDay: CapturedWindow(usedPercentage: 20, resetsAt: "2026-10-19T00:00:00Z"),
                                    weeklyScoped: nil, weeklyScopedModel: nil)
        let half = F.row(F.personal, now: now)
        let row = AccountRow(account: half.account, name: half.name, snapshot: started, status: .ok, tokenStatus: "fresh")
        let lines = F.model([row], settings: BrowSettings(), now: now).accounts[0].lines
        XCTAssertNil(lines[0].used)
        XCTAssertEqual(lines[0].resets, "not started")
        XCTAssertEqual(lines[1].used, 20)
    }

    /// No snapshot anywhere: the overall row says `—`, not a fabricated 0 %.
    func testOverallWithoutDataIsBlank() throws {
        let rows = [F.row(F.personal, now: now, snapshot: false), F.row(F.work, now: now, snapshot: false)]
        let overall = try XCTUnwrap(F.model(rows, settings: BrowSettings(), now: now).overall)
        XCTAssertEqual(overall.map(\.used), [nil, nil])
    }

    func testShapes() {
        XCTAssertEqual(CardShape.allCases, [.wide, .square])
        XCTAssertEqual(CardShape.wide.points, CGSize(width: 600, height: 315))
        XCTAssertEqual(CardShape.square.points, CGSize(width: 540, height: 540))
        XCTAssertEqual((1...4).map(CardShape.wide.columns), [1, 2, 3, 4])
        XCTAssertEqual((1...4).map(CardShape.square.columns), [1, 1, 2, 2])
        // Larger type only where it fits; the panel's own sizes are the last resort,
        // so a full card is drawn exactly as before.
        XCTAssertEqual(WeekCardView.scales.last, 1)
        XCTAssertEqual(WeekCardView.scales, WeekCardView.scales.sorted(by: >))
    }

    // MARK: settings

    func testCardSettingsDefaultsAndOlderFiles() throws {
        XCTAssertFalse(BrowSettings().cardShowNames)
        XCTAssertEqual(BrowSettings().cardShape, .wide)

        let dir = try Fixture.tempDir("settings-card").path
        let store = BrowSettingsStore(directory: dir)
        try #"{"accounts":{},"allowPromptFallback":false,"earsPlacement":"below"}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = store.load()
        XCTAssertFalse(loaded.cardShowNames)
        XCTAssertEqual(loaded.cardShape, .wide)
        XCTAssertEqual(loaded.earsPlacement, .below)

        var s = BrowSettings()
        s.cardShowNames = true
        s.cardShape = .square
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    /// An unknown or mistyped shape costs that one field, never the account names.
    func testAnUnknownCardShapeKeepsEveryOtherField() throws {
        let dir = try Fixture.tempDir("settings-bad-card").path
        let store = BrowSettingsStore(directory: dir)
        for value in [#""round""#, "3"] {
            try #"""
            {"accounts":{"org":{"name":"Work","hidden":false}},"claudePath":"/opt/claude",
             "cardShowNames":true,"cardShape":\#(value)}
            """#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
            let loaded = store.load()
            XCTAssertEqual(loaded.cardShape, .wide, value)
            XCTAssertTrue(loaded.cardShowNames, value)
            XCTAssertEqual(loaded.accounts["org"]?.name, "Work", value)
            XCTAssertEqual(loaded.claudePath, "/opt/claude", value)
        }
    }
}
