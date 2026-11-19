import XCTest
@testable import Phi

final class MailBodyPreparationTests: XCTestCase {
    func testCIDReferencesAreMessageScopedAndEscaped() {
        let id = UUID()
        let value = MailBodyPreparation.prepare(html: "<img src='CID:photo%40example'><img src=\"cid:other\">", text: nil, messageID: id)
        XCTAssertTrue(value.html.contains("mist-mail-cid://\(id.uuidString.lowercased())/photo@example"))
        XCTAssertTrue(value.isHTML)
        XCTAssertTrue(value.html.contains("script-src 'none'"))
    }
    func testPlainTextEscapesBeforeLinkification() {
        let value = MailBodyPreparation.prepare(html: nil, text: "<script>&\nhttps://example.com/?a=1&b=2", messageID: UUID())
        XCTAssertTrue(value.html.contains("&lt;script&gt;&amp;\n"))
        XCTAssertTrue(value.html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        XCTAssertFalse(value.html.contains("<script>"))
        XCTAssertFalse(value.isHTML)
    }
}
