import XCTest
import GroveCore

final class ScaffoldTests: XCTestCase {
    func testVersionConstant() {
        XCTAssertEqual(BrowVersion.current, "0.3.1")
    }
}
