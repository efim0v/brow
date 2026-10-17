import XCTest
import GroveCore
@testable import GroveAppKit

/// The account pickers show each account's limits, by its config folders.
@MainActor
final class AccountLimitsTests: XCTestCase {
    private final class Provider: AccountLimitsProviding {
        var byDir: [String: AccountLimits] = [:]
        private(set) var asked: [[String]] = []
        func limits(forConfigDirs dirs: [String]) -> AccountLimits? {
            asked.append(dirs)
            return dirs.lazy.compactMap { self.byDir[$0] }.first
        }
    }

    func testTheLabelRoundsAndSaysWhenItIsOld() {
        XCTAssertEqual(AccountLimits(fiveHour: 41.6, weekly: 61.2, stale: false).label, "5h 42% · week 61%")
        XCTAssertEqual(AccountLimits(fiveHour: nil, weekly: 100.4, stale: true).label, "week 100% · old")
        XCTAssertNil(AccountLimits(fiveHour: nil, weekly: nil, stale: false).label)
    }

    func testMenusCarryTheLimitsOfTheAccountsFolder() throws {
        let url = try FixtureLite.tempDir("limits").appendingPathComponent("config.json")
        let state = AppState(configStore: ConfigStore(url: url))
        let provider = Provider()
        provider.byDir["/x/work"] = AccountLimits(fiveHour: 12, weekly: 34, stale: false)
        let work = AccountConfig(name: "work", configDir: "/x/main", aliasDirs: ["/x/work"])
        let personal = AccountConfig(name: "personal", configDir: "/x/personal")

        XCTAssertEqual(state.menuTitle("Resume as", work), "Resume as work", "no provider: just the name")
        state.limitsProvider = provider
        XCTAssertEqual(state.menuTitle("Resume as", work), "Resume as work — 5h 12% · week 34%",
                       "an alias folder is the same account")
        XCTAssertEqual(state.menuTitle("Migrate to", personal), "Migrate to personal", "no reading: just the name")
        XCTAssertEqual(provider.asked.last, ["/x/personal"], "asked by the account's folders")
        XCTAssertEqual(state.menuTitle("", work), "work — 5h 12% · week 34%", "the launch sheet's form")
    }
}
