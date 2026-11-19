import XCTest
@testable import MistMailCore

final class MailboxNameTests: XCTestCase {
    func testDecodesModifiedUTF7Names() {
        XCTAssertEqual(Mailbox.decodeModifiedUTF7("[Gmail]/Messages envoy&AOk-s"), "[Gmail]/Messages envoyés")
        XCTAssertEqual(Mailbox.decodeModifiedUTF7("~peter/mail/&U,BTFw-/&ZeVnLIqe-"), "~peter/mail/台北/日本語")
        XCTAssertEqual(Mailbox.decodeModifiedUTF7("Tom &- Jerry"), "Tom & Jerry")
        XCTAssertEqual(Mailbox.decodeModifiedUTF7("INBOX"), "INBOX")
        XCTAssertEqual(Mailbox.decodeModifiedUTF7("Broken &AOk"), "Broken &AOk")
    }
}
