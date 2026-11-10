import XCTest
@testable import RowsterCore

final class RowsterCoreTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(String(describing: RowsterCore.self), "RowsterCore")
    }
}
