import XCTest
@testable import MistMailCore

final class MailTextTests: XCTestCase {
    func testReadablePreservesStructureAndLinks() {
        let html = "<head><title>Hidden</title></head><style>hidden</style><!-- hidden --><p>Hello &amp; &#39;world&#x21;</p><ul><li>One</li><li>Two<br>again</li></ul><p><a href='https://example.com'>Site</a> <a href='mailto:a@b'>mailto:a@b</a></p>"
        XCTAssertEqual(MailText.readable(html), "Hello & 'world!\n\n• One\n\n• Two\nagain\n\nSite (https://example.com) mailto:a@b")
        XCTAssertEqual(MailText.readable("<a href=https://example.com>Site</a>"), "Site (https://example.com)")
    }
    func testPlainTextSkipsStylesScriptsHeadAndComments() {
        let html = """
        <html><head><title>Offer</title><style type="text/css">@font-face { font-family:"Scotia"; }
        p { color: red; }</style></head><body><!--[if mso]><style>td{}</style><![endif]-->
        <script>var x = 1;</script><p>Ada, get rewarded &amp; save</p></body></html>
        """
        XCTAssertEqual(MailText.plain(html), "Ada, get rewarded & save")
    }

    func testHTMLSourceInThePlainPartIsReadAsHTML() {
        let source = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\">\n<html><head><title>Booking</title></head><body><p>Your booking is confirmed</p></body></html>"
        var message = StoredMessage(id: UUID(), accountID: UUID(), mailboxID: UUID(), remote: .init(uid: 1))
        message.plainText = source; message.html = "<html><body><p>Your booking is confirmed</p></body></html>"
        XCTAssertEqual(message.summary.snippet, "Your booking is confirmed")
        XCTAssertNil(message.detail.plainText)
        message.html = nil
        XCTAssertEqual(message.summary.snippet, "Your booking is confirmed")
        XCTAssertEqual(message.detail.plainText, source)
        message.plainText = "Hello,\n\n<b> stays text"
        XCTAssertEqual(message.summary.snippet, "Hello, <b> stays text")
    }
}
