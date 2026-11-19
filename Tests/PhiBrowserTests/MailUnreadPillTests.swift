import XCTest
@testable import Phi

final class MailUnreadPillTests: XCTestCase {
    func testCountFormattingHidesZeroAndCapsAtNinetyNine() {
        XCTAssertNil(MailUnreadPill.text(for: 0))
        XCTAssertEqual(MailUnreadPill.text(for: 7), "7")
        XCTAssertEqual(MailUnreadPill.text(for: 99), "99")
        XCTAssertEqual(MailUnreadPill.text(for: 100), "99+")
    }
}
