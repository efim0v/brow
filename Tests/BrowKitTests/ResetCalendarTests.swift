import XCTest
import GroveCore
@testable import BrowKit

final class ResetCalendarTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2                                    // Monday, as the owner's locale has it
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
    private func date(_ iso: String) -> Date { parseISODate(iso)! }
    private let now = Date(timeIntervalSince1970: 1_789_689_600)   // 2026-09-18T00:00:00Z (Friday)

    private func row(_ id: String, name: String, weekly: String?, fable: String?, renews: Date? = nil) -> AccountRow {
        let account = DiscoveredAccount(organizationUuid: id, email: name, tier: "default_claude_max_20x",
                                        configDir: "/x/\(id)", aliasDirs: [], tokenExpiresAt: nil)
        let snapshot = LimitSnapshot(organizationUuid: id, fetchedAt: now,
                                     fiveHour: CapturedWindow(usedPercentage: 1, resetsAt: nil),
                                     sevenDay: weekly.map { CapturedWindow(usedPercentage: 50, resetsAt: $0) },
                                     weeklyScoped: fable.map { CapturedWindow(usedPercentage: 20, resetsAt: $0) },
                                     weeklyScopedModel: fable == nil ? nil : "Fable")
        return AccountRow(account: account, name: name, snapshot: snapshot, status: .ok, tokenStatus: "fresh", renewsAt: renews)
    }

    func testSeptember2026LaysOutAsFiveMondayFirstWeeks() {
        let weeks = ResetCalendar.weeks(inMonthOf: date("2026-09-18T12:00:00Z"), calendar: utc)
        XCTAssertEqual(weeks.count, 5)
        XCTAssertNil(weeks[0][0], "September 2026 starts on a Tuesday: Monday is blank")
        XCTAssertEqual(weeks[0][1].map { utc.component(.day, from: $0) }, 1)
        XCTAssertEqual(weeks[4][2].map { utc.component(.day, from: $0) }, 30)
        XCTAssertNil(weeks[4][3])
        XCTAssertEqual(ResetCalendar.weekdaySymbols(calendar: utc).first, "M")
    }

    func testMarksCarryEveryWeeklyWindowAndTheRenewalInRowOrder() {
        let rows = [row("a", name: "gmail", weekly: "2026-09-22T02:00:00Z", fable: "2026-09-22T02:00:00Z",
                        renews: date("2026-10-10T14:31:29Z")),
                    row("b", name: "icloud", weekly: "2026-09-23T00:00:00Z", fable: nil)]
        let marks = ResetCalendar.marks(rows: rows)
        XCTAssertEqual(marks.map(\.kind), [.weekly("Weekly"), .weekly("Fable"), .renewal, .weekly("Weekly")])
        XCTAssertEqual(marks.map(\.colorIndex), [0, 0, 0, 1])
        XCTAssertEqual(ResetCalendar.nextMarkedDay(marks, now: now, calendar: utc), date("2026-09-22T02:00:00Z"))
    }

    func testDayDetailIsOneCardPerAccountWithARowPerWindow() {
        let rows = [row("a", name: "gmail", weekly: "2026-09-22T02:00:00Z", fable: "2026-09-22T02:00:00Z"),
                    row("b", name: "icloud", weekly: "2026-09-22T05:30:00Z", fable: "2026-09-22T07:00:00Z")]
        let marks = ResetCalendar.marks(rows: rows)
        let day = ResetCalendar.dayDetail(for: date("2026-09-22T00:00:00Z"), marks: marks, now: now, calendar: utc)
        XCTAssertEqual(day.title, "Tuesday 22 September")
        XCTAssertEqual(day.accounts.map(\.name), ["gmail", "icloud"])
        XCTAssertEqual(day.accounts[0].rows, [
            .init(label: "Weekly", time: "02:00", remaining: "in 4 d 2 h", estimated: false),
            .init(label: "Fable", time: "02:00", remaining: "in 4 d 2 h", estimated: false)])
        XCTAssertEqual(day.accounts[1].rows.map(\.time), ["05:30", "07:00"])
        let empty = ResetCalendar.dayDetail(for: date("2026-09-25T00:00:00Z"), marks: marks, now: now, calendar: utc)
        XCTAssertEqual(empty.title, "Friday 25 September")
        XCTAssertTrue(empty.accounts.isEmpty)
    }

    /// Two windows of one account resetting the same day are ONE dot; the renewal is
    /// its own diamond.
    func testOneDotPerAccountPerDay() {
        let rows = [row("a", name: "gmail", weekly: "2026-09-22T02:00:00Z", fable: "2026-09-22T02:00:00Z",
                        renews: date("2026-09-22T14:31:29Z")),
                    row("b", name: "icloud", weekly: "2026-09-22T05:30:00Z", fable: nil)]
        let dots = ResetCalendar.dots(on: date("2026-09-22T00:00:00Z"), marks: ResetCalendar.marks(rows: rows), calendar: utc)
        XCTAssertEqual(dots, [.init(colorIndex: 0, renewal: false), .init(colorIndex: 0, renewal: true),
                              .init(colorIndex: 1, renewal: false)])
    }

    func testDayDetailReadsARenewalAsAnEstimate() {
        let rows = [row("a", name: "gmail", weekly: nil, fable: nil, renews: date("2026-10-10T14:31:29Z"))]
        let day = ResetCalendar.dayDetail(for: date("2026-10-10T00:00:00Z"), marks: ResetCalendar.marks(rows: rows),
                                          now: now, calendar: utc)
        XCTAssertEqual(day.title, "Saturday 10 October")
        XCTAssertEqual(day.accounts[0].rows, [.init(label: "Renewal", time: "~14:31", remaining: "in 22 d 14 h", estimated: true)])
    }

    func testNextRenewalIsTheFirstMonthlyAnniversaryAfterNow() {
        let info = SubscriptionInfo(organizationUuid: "a", status: "active", billingType: "stripe_subscription",
                                    createdAt: date("2026-09-10T14:31:29Z"), fetchedAt: now)
        XCTAssertEqual(info.nextRenewal(after: now), date("2026-10-10T14:31:29Z"))
        XCTAssertEqual(info.nextRenewal(after: date("2026-10-10T14:31:30Z")), date("2026-11-10T14:31:29Z"))
        let endOfMonth = SubscriptionInfo(organizationUuid: "a", status: "active", billingType: "stripe_subscription",
                                          createdAt: date("2026-01-31T10:00:00Z"), fetchedAt: now)
        XCTAssertEqual(endOfMonth.nextRenewal(after: date("2026-02-15T00:00:00Z")), date("2026-02-28T10:00:00Z"))
        let cancelled = SubscriptionInfo(organizationUuid: "a", status: "cancelled", billingType: "stripe_subscription",
                                         createdAt: date("2026-09-10T14:31:29Z"), fetchedAt: now)
        XCTAssertNil(cancelled.nextRenewal(after: now))
    }

    func testLimitsFileWithoutSubscriptionsStillLoads() throws {
        let json = #"{"snapshots":{},"accounts":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(LimitsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.subscriptions, [:])
    }

    func testTierTagCarriesTheRenewalEstimate() {
        XCTAssertEqual(PanelText.accountTag(tier: "default_claude_max_20x", snapshot: nil, status: .ok,
                                            renewsAt: date("2026-10-10T14:31:29Z"), now: now),
                       "Max 20x · renews ~10 Oct")
    }
}
