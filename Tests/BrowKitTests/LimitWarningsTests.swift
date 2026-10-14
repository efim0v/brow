import XCTest
import GroveCore
@testable import BrowKit

final class LimitWarningsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_065_600)   // 2026-10-15 12:00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!
    /// The 5-hour window's reset in every test that does not move it: 18:40 the same day.
    private var fiveReset: String { "2026-10-15T18:40:00Z" }
    private var weekReset: String { "2026-10-22T02:00:00Z" }
    /// Every notice any test in this file produced, for the wording guard.
    private static var produced: [LimitNotice] = []

    // MARK: - Fixtures

    private func row(_ org: String = "org-a", name: String = "Work",
                     five: Double? = nil, fiveResets: String? = nil,
                     week: Double? = nil, weekResets: String? = nil,
                     scoped: Double? = nil, scopedResets: String? = nil, model: String? = "Fable",
                     fetchedAt: Date? = nil, scopedFetchedAt: Date? = nil) -> AccountRow {
        let account = DiscoveredAccount(organizationUuid: org, email: "\(org)@example.com", tier: nil,
                                        configDir: "/tmp/brow-tests/.claude-accounts/\(org)", aliasDirs: [],
                                        tokenExpiresAt: nil)
        let snapshot = LimitSnapshot(organizationUuid: org, fetchedAt: fetchedAt ?? t0.addingTimeInterval(-10),
                                     fiveHour: five.map { CapturedWindow(usedPercentage: $0, resetsAt: fiveResets ?? self.fiveReset) },
                                     sevenDay: week.map { CapturedWindow(usedPercentage: $0, resetsAt: weekResets ?? self.weekReset) },
                                     weeklyScoped: scoped.map { CapturedWindow(usedPercentage: $0, resetsAt: scopedResets ?? self.weekReset) },
                                     weeklyScopedModel: scoped == nil ? nil : model,
                                     scopedFetchedAt: scopedFetchedAt)
        return AccountRow(account: account, name: name, snapshot: snapshot, status: .ok, tokenStatus: "valid")
    }

    private func on(_ levels: [Int] = [80, 95], resets: Bool = false) -> BrowSettings {
        var s = BrowSettings()
        s.notifyLimits = true
        s.notifyThresholds = levels
        s.notifyResets = resets
        return s
    }

    private func eval(_ w: inout LimitWarnings, _ rows: [AccountRow], _ settings: BrowSettings? = nil,
                      now: Date? = nil) -> [LimitNotice] {
        let notices = w.evaluate(rows: rows, settings: settings ?? on(), now: now ?? t0, timeZone: utc)
        Self.produced += notices
        return notices
    }

    private func kinds(_ notices: [LimitNotice]) -> [LimitNotice.Kind] { notices.map(\.kind) }

    // MARK: - 1. Baseline

    func testTheFirstFreshReadingIsASilentBaseline() {
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [row(five: 85)]), [], "85 is past 80, but it was past 80 before Brow looked")
        XCTAssertEqual(eval(&w, [row(five: 86)]), [])
        let notices = eval(&w, [row(five: 96)])
        XCTAssertEqual(kinds(notices), [.warning(level: 95)])
    }

    // MARK: - 2. Each level once

    func testEachLevelOncePerPeriodUnderOneId() throws {
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [row(five: 70)]), [])
        let at80 = eval(&w, [row(five: 82)])
        XCTAssertEqual(kinds(at80), [.warning(level: 80)])
        XCTAssertEqual(eval(&w, [row(five: 83)]), [])
        let at95 = eval(&w, [row(five: 96)])
        XCTAssertEqual(kinds(at95), [.warning(level: 95)])
        XCTAssertEqual(try XCTUnwrap(at80.first).id, try XCTUnwrap(at95.first).id,
                       "the 95 replaces the 80 in Notification Center")
        XCTAssertEqual(at80.first?.title, "Work")
        XCTAssertNil(at80.first?.deliverAt)
    }

    /// The panel shows the rounded figure, so the comparison does too — and a reading
    /// that rounds up to a level does not announce it again when it inches on.
    func testLevelsAreComparedAsThePanelShowsThem() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)])
        XCTAssertEqual(kinds(eval(&w, [row(five: 79.6)])), [.warning(level: 80)], "the panel says 80%")
        XCTAssertEqual(eval(&w, [row(five: 79.7)]), [])
        XCTAssertEqual(eval(&w, [row(five: 80.2)]), [])
        XCTAssertEqual(eval(&w, [row(five: 94.4)]), [], "94% on screen")
    }

    // MARK: - 3. A jump

    func testAJumpPastSeveralLevelsAnnouncesOnlyTheHighest() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)])
        let notices = eval(&w, [row(five: 97)])
        XCTAssertEqual(kinds(notices), [.warning(level: 95)])
        XCTAssertTrue(notices[0].body.contains("97%"), notices[0].body)
    }

    // MARK: - 4. A new period

    func testANewPeriodCountsFromZero() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)])
        _ = eval(&w, [row(five: 82)])
        let next = "2026-10-15T23:40:00Z"
        let later = t0.addingTimeInterval(7 * 3600), later2 = t0.addingTimeInterval(8 * 3600)
        XCTAssertEqual(eval(&w, [row(five: 0, fiveResets: next, fetchedAt: later)], now: later), [])
        let again = eval(&w, [row(five: 81, fiveResets: next, fetchedAt: later2)], now: later2)
        XCTAssertEqual(kinds(again), [.warning(level: 80)])
        XCTAssertTrue((again.first?.id ?? "").hasSuffix(".\(Int(Formatting.resetInstant(next)!.timeIntervalSince1970))"), again.first?.id ?? "-")
    }

    func testTheFirstReadingOfANewPeriodIsNotABaseline() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)])
        let later = t0.addingTimeInterval(7 * 3600)
        let notices = eval(&w, [row(five: 85, fiveResets: "2026-10-15T23:40:00Z", fetchedAt: later)], now: later)
        XCTAssertEqual(kinds(notices), [.warning(level: 80)])
    }

    // MARK: - 5. Jitter

    func testResetJitterIsTheSamePeriod() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70, fiveResets: "2026-10-15T18:59:59.641Z")])
        let first = eval(&w, [row(five: 82, fiveResets: "2026-10-15T18:59:59.641Z")])
        XCTAssertEqual(kinds(first), [.warning(level: 80)])
        XCTAssertEqual(eval(&w, [row(five: 83, fiveResets: "2026-10-15T19:00:00Z")]), [])
        XCTAssertEqual(eval(&w, [row(five: 84, fiveResets: "2026-10-15T19:03:00Z")]), [],
                       "within 10 min is still the same period")
    }

    // MARK: - 6. Readings that never count

    func testAStaleSnapshotNeitherFiresNorSetsABaseline() {
        let old = t0.addingTimeInterval(-3 * 86_400)   // a persisted limits.json at launch
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [row(five: 50, fetchedAt: old)]), [])
        XCTAssertEqual(eval(&w, [row(five: 96)]), [], "the first FRESH reading is the baseline")

        var v = LimitWarnings()
        _ = eval(&v, [row(five: 70)])
        XCTAssertEqual(eval(&v, [row(five: 96, fetchedAt: old)]), [])
        XCTAssertEqual(kinds(eval(&v, [row(five: 96)])), [.warning(level: 95)],
                       "and it moved nothing: the fresh 96 still crosses")
    }

    func testAWindowWhoseResetHasPassedNeverCounts() {
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [row(five: 50, fiveResets: "2026-10-15T11:00:00Z")]), [])
        XCTAssertEqual(eval(&w, [row(five: 96)]), [], "still the baseline")
        XCTAssertEqual(eval(&w, [row(five: 99, fiveResets: "2026-10-15T11:00:00Z")]), [])
    }

    func testAWindowThatHasNotStartedNeverCounts() {
        let account = DiscoveredAccount(organizationUuid: "org-a", email: nil, tier: nil, configDir: "/tmp/a",
                                        aliasDirs: [], tokenExpiresAt: nil)
        let unstarted = AccountRow(account: account, name: "Work",
                                   snapshot: LimitSnapshot(organizationUuid: "org-a", fetchedAt: t0,
                                                           fiveHour: CapturedWindow(usedPercentage: 50, resetsAt: nil),
                                                           sevenDay: nil, weeklyScoped: nil, weeklyScopedModel: nil),
                                   status: .ok, tokenStatus: "valid")
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [unstarted]), [])
        XCTAssertEqual(eval(&w, [row(five: 96)]), [], "still the baseline")
    }

    /// A statusline capture refreshes the snapshot but not the model window, which
    /// keeps its own, older, age.
    func testAStaleScopedWindowUnderAFreshSnapshotNeverCounts() {
        var w = LimitWarnings()
        let old = t0.addingTimeInterval(-3600)
        XCTAssertEqual(eval(&w, [row(scoped: 50, scopedFetchedAt: old)]), [])
        XCTAssertEqual(eval(&w, [row(scoped: 96)]), [], "the first fresh scoped reading is the baseline")
        XCTAssertEqual(eval(&w, [row(scoped: 99, scopedFetchedAt: old)]), [])
    }

    func testNoSnapshotNeverCounts() {
        let account = DiscoveredAccount(organizationUuid: "org-a", email: nil, tier: nil, configDir: "/tmp/a",
                                        aliasDirs: [], tokenExpiresAt: nil)
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [AccountRow(account: account, name: "Work", snapshot: nil, status: .stale, tokenStatus: "")]), [])
        XCTAssertEqual(eval(&w, [row(five: 96)]), [])
    }

    // MARK: - 7. Independence and pruning

    func testAccountsAndWindowsAreIndependent() {
        var w = LimitWarnings()
        let a = { (five: Double, week: Double) in self.row("org-a", name: "Personal", five: five, week: week) }
        let b = { (five: Double, week: Double) in self.row("org-b", name: "Work", five: five, week: week) }
        XCTAssertEqual(eval(&w, [a(70, 70), b(70, 70)]), [])
        let fiveA = eval(&w, [a(82, 70), b(70, 70)])
        XCTAssertEqual(fiveA.map(\.title), ["Personal"])
        XCTAssertTrue(fiveA[0].id.hasPrefix("limit.org-a.fiveHour."), fiveA[0].id)
        let weekB = eval(&w, [a(82, 70), b(70, 81)])
        XCTAssertEqual(weekB.map(\.title), ["Work"])
        XCTAssertTrue(weekB[0].id.hasPrefix("limit.org-b.weekly."), weekB[0].id)
        XCTAssertNotEqual(fiveA[0].id, weekB[0].id)
    }

    func testARemovedAccountStartsOverWithABaseline() {
        var w = LimitWarnings()
        let a = row("org-a", name: "Personal", five: 70)
        _ = eval(&w, [a, row("org-b", five: 70)])
        _ = eval(&w, [a])                                  // org-b hidden: pruned
        XCTAssertEqual(eval(&w, [a, row("org-b", five: 96)]), [], "back: its first reading is a baseline")
        XCTAssertEqual(eval(&w, [a, row("org-b", five: 97)]), [])
    }

    // MARK: - 8. Settings

    func testOffProducesNothingAndTurningOnIsABaseline() {
        var w = LimitWarnings()
        let off = BrowSettings()
        XCTAssertEqual(eval(&w, [row(five: 70)], off), [])
        XCTAssertEqual(eval(&w, [row(five: 96)], off), [])
        XCTAssertEqual(eval(&w, [row(five: 97)], on()), [], "on: a baseline, not a burst")
        _ = eval(&w, [row(five: 70)], off)
        XCTAssertEqual(eval(&w, [row(five: 85)], on()), [], "off and on again: a baseline again")
    }

    func testChangingTheLevelsClearsTheState() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)], on([80, 95]))
        XCTAssertEqual(eval(&w, [row(five: 76)], on([70, 75])), [], "new levels: a baseline")
        XCTAssertEqual(kinds(eval(&w, [row(five: 81)], on([70, 75, 80]))), [], "and again")
    }

    func testChangingResetNoticesClearsTheState() {
        var w = LimitWarnings()
        _ = eval(&w, [row(five: 70)], on())
        XCTAssertEqual(kinds(eval(&w, [row(five: 82)], on(resets: true))), [.reset],
                       "a baseline at 82 — no warning, only the reset notice it is owed")
    }

    // MARK: - 9. Reset notices

    func testCrossingTheLowestLevelSchedulesOneResetNotice() throws {
        var w = LimitWarnings()
        let settings = on(resets: true)
        XCTAssertEqual(eval(&w, [row(five: 70)], settings), [], "a baseline below the lowest level")
        let crossed = eval(&w, [row(five: 82)], settings)
        XCTAssertEqual(kinds(crossed), [.warning(level: 80), .reset])
        let reset = try XCTUnwrap(crossed.last)
        XCTAssertEqual(reset.deliverAt, Formatting.resetInstant(fiveReset))
        XCTAssertEqual(reset.id, "reset.org-a.fiveHour.\(Int(Formatting.resetInstant(fiveReset)!.timeIntervalSince1970))")
        XCTAssertEqual(reset.title, "Work")
        XCTAssertEqual(kinds(eval(&w, [row(five: 96)], settings)), [.warning(level: 95)], "one per period")
    }

    func testABaselineAtOrAboveTheLowestLevelSchedulesOne() {
        var w = LimitWarnings()
        XCTAssertEqual(kinds(eval(&w, [row(five: 80)], on(resets: true))), [.reset])
        var v = LimitWarnings()
        XCTAssertEqual(eval(&v, [row(five: 79)], on(resets: true)), [])
    }

    func testNoResetNoticesWhileTheyAreOff() {
        var w = LimitWarnings()
        XCTAssertEqual(eval(&w, [row(five: 85)]), [])
        let later = t0.addingTimeInterval(7 * 3600)
        _ = eval(&w, [row(five: 70, fiveResets: "2026-10-15T23:40:00Z", fetchedAt: later)], now: later)
        XCTAssertEqual(kinds(eval(&w, [row(five: 82, fiveResets: "2026-10-15T23:40:00Z", fetchedAt: later)], now: later)),
                       [.warning(level: 80)])
    }

    // MARK: - 10. Levels

    func testSanitizedLevels() {
        XCTAssertEqual(LimitWarnings.sanitized([95, 80, 80, 0, 150]), [80, 95])
        XCTAssertEqual(LimitWarnings.sanitized([]), [80, 95])
        XCTAssertEqual(LimitWarnings.sanitized([-5, 101]), [80, 95])
        XCTAssertEqual(LimitWarnings.sanitized([100, 1]), [1, 100])
    }

    // MARK: - 11. Copy

    func testWarningCopy() {
        let reset = Formatting.resetInstant(fiveReset)!
        XCTAssertEqual(NoticeText.warningBody(used: 82, kind: .fiveHour, model: nil, reset: reset, now: t0, timeZone: utc),
                       "82% of the 5-hour limit used. Resets at 18:40.")
        let week = Formatting.resetInstant(weekReset)!
        XCTAssertEqual(NoticeText.warningBody(used: 96, kind: .weekly, model: nil, reset: week, now: t0, timeZone: utc),
                       "96% of the weekly limit used. Resets 22 Oct 02:00.")
        XCTAssertEqual(NoticeText.warningBody(used: 91, kind: .weeklyScoped, model: "Fable", reset: week, now: t0, timeZone: utc),
                       "91% of the Fable weekly limit used. Resets 22 Oct 02:00.")
    }

    /// "The same day" is the reader's day, not UTC's.
    func testSameDayIsJudgedInTheGivenTimeZone() {
        let reset = Formatting.resetInstant("2026-10-15T23:30:00Z")!
        XCTAssertEqual(NoticeText.warningBody(used: 82, kind: .fiveHour, model: nil, reset: reset, now: t0, timeZone: utc),
                       "82% of the 5-hour limit used. Resets at 23:30.")
        XCTAssertEqual(NoticeText.warningBody(used: 82, kind: .fiveHour, model: nil, reset: reset, now: t0,
                                              timeZone: TimeZone(identifier: "Asia/Tokyo")!),
                       "82% of the 5-hour limit used. Resets 16 Oct 08:30.")
    }

    func testTheEvaluatorNamesTheModelOrSaysModel() {
        var w = LimitWarnings()
        _ = eval(&w, [row(scoped: 70)])
        XCTAssertEqual(eval(&w, [row(scoped: 91)]).first?.body, "91% of the Fable weekly limit used. Resets 22 Oct 02:00.")
        var v = LimitWarnings()
        _ = eval(&v, [row(scoped: 70, model: nil)])
        XCTAssertEqual(eval(&v, [row(scoped: 91, model: nil)]).first?.body, "91% of the Model weekly limit used. Resets 22 Oct 02:00.")
    }

    func testResetAndLevelCopy() {
        XCTAssertEqual(NoticeText.resetBody(kind: .fiveHour, model: nil), "5-hour limit has reset.")
        XCTAssertEqual(NoticeText.resetBody(kind: .weekly, model: nil), "Weekly limit has reset.")
        XCTAssertEqual(NoticeText.resetBody(kind: .weeklyScoped, model: "Fable"), "Fable weekly limit has reset.")
        XCTAssertEqual(NoticeText.levels([80, 95]), "80% and 95%")
        XCTAssertEqual(NoticeText.levels([90]), "90%")
        XCTAssertEqual(NoticeText.levels([70, 80, 90]), "70%, 80% and 90%")
        XCTAssertEqual(NoticeText.testBody(levels: [80, 95]), "Test: limit warnings are on. Brow warns at 80% and 95%.")
    }

    // MARK: - 12. Wording

    /// Warnings say where an account stands and when it resets. Nothing else.
    func testNoWordingSuggestsWorkingAroundALimit() throws {
        // The scenarios that produce notices, once more, so the guard does not depend
        // on the order XCTest runs this file in.
        let scenarios: [() throws -> Void] = [
            testTheFirstFreshReadingIsASilentBaseline, testEachLevelOncePerPeriodUnderOneId,
            testLevelsAreComparedAsThePanelShowsThem, testAJumpPastSeveralLevelsAnnouncesOnlyTheHighest,
            testANewPeriodCountsFromZero, testTheFirstReadingOfANewPeriodIsNotABaseline,
            testResetJitterIsTheSamePeriod, testAStaleSnapshotNeitherFiresNorSetsABaseline,
            testAccountsAndWindowsAreIndependent, testChangingResetNoticesClearsTheState,
            testCrossingTheLowestLevelSchedulesOneResetNotice, testABaselineAtOrAboveTheLowestLevelSchedulesOne,
            testNoResetNoticesWhileTheyAreOff, testTheEvaluatorNamesTheModelOrSaysModel,
        ]
        for scenario in scenarios { try scenario() }
        let reset = Formatting.resetInstant(weekReset)!
        var texts = Self.produced.flatMap { [$0.title, $0.body] }
        for kind in LimitWindowKind.allCases {
            texts.append(NoticeText.windowName(kind, model: "Opus"))
            texts.append(NoticeText.resetBody(kind: kind, model: "Opus"))
            for now in [t0, reset.addingTimeInterval(-60)] {
                texts.append(NoticeText.warningBody(used: 95, kind: kind, model: "Opus", reset: reset, now: now, timeZone: utc))
            }
        }
        for levels in LimitWarnings.presets { texts.append(NoticeText.testBody(levels: levels)) }
        XCTAssertGreaterThan(Self.produced.count, 10, "the guard has something to read")
        for text in texts {
            let lower = text.lowercased()
            for word in ["switch", "another account", "bypass", "avoid", "keep going"] {
                XCTAssertFalse(lower.contains(word), "\"\(text)\" says \"\(word)\"")
            }
        }
    }

    // MARK: - 13. Settings file

    func testNotificationSettingsDefaults() {
        let s = BrowSettings()
        XCTAssertFalse(s.notifyLimits)
        XCTAssertEqual(s.notifyThresholds, [80, 95])
        XCTAssertFalse(s.notifyResets)
    }

    func testAnOlderConfigDecodesToTheDefaults() throws {
        let dir = try Fixture.tempDir("settings-notify-old").path
        try #"{"accounts":{},"allowPromptFallback":false,"showCalendar":false}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = BrowSettingsStore(directory: dir).load()
        XCTAssertFalse(loaded.notifyLimits)
        XCTAssertEqual(loaded.notifyThresholds, [80, 95])
        XCTAssertFalse(loaded.notifyResets)
        XCTAssertFalse(loaded.allowPromptFallback, "the rest of the file still decodes")
        XCTAssertFalse(loaded.showCalendar)
    }

    func testUnusableLevelsFallBackAndKeepTheRestOfTheFile() throws {
        let dir = try Fixture.tempDir("settings-notify-bad").path
        let store = BrowSettingsStore(directory: dir)
        try #"{"claudePath":"/opt/claude","notifyLimits":true,"notifyThresholds":"x","notifyResets":true}"#
            .write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        let loaded = store.load()
        XCTAssertEqual(loaded.notifyThresholds, [80, 95])
        XCTAssertTrue(loaded.notifyLimits)
        XCTAssertTrue(loaded.notifyResets)
        XCTAssertEqual(loaded.claudePath, "/opt/claude")

        try #"{"notifyThresholds":[95,80,80,0,150]}"#.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load().notifyThresholds, [80, 95], "decoded through sanitized")
    }

    func testNotificationSettingsRoundTrip() throws {
        let dir = try Fixture.tempDir("settings-notify-trip").path
        let store = BrowSettingsStore(directory: dir)
        var s = BrowSettings()
        s.notifyLimits = true
        s.notifyThresholds = [70, 90]
        s.notifyResets = true
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
}
