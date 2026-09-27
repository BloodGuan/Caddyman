import XCTest
@testable import Caddyman

final class CaddymanIdentityTests: XCTestCase {
    func testProductNameIsCaddyman() {
        XCTAssertEqual(CaddymanIdentity.name, "Caddyman")
    }
}
