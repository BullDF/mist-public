import XCTest
import MistMailCore
@testable import Phi

final class MailComposeFormattingTests: XCTestCase {
    func testAddressListsKeepQuotedNamesAndInvalidTokens() {
        let values = MailComposeFormatting.addresses("a@b.c; Name <name@example.com>\n\"Last, First\" <first@example.com>, invalid")
        XCTAssertEqual(values, [.init("a@b.c"), .init("name@example.com", name: "Name"), .init("first@example.com", name: "Last, First"), .init("invalid")])
        XCTAssertEqual(MailComposeFormatting.addresses(MailComposeFormatting.display(values[2])), [values[2]])
        XCTAssertTrue(MailComposeFormatting.addresses(" ,;\n").isEmpty)
    }
    func testValidityChecksEveryPartAndHeaderInjection() {
        for email in ["a@b.c", "first+tag@sub.example.com"] { XCTAssertTrue(MailComposeFormatting.isValid(.init(email))) }
        for email in ["", "a@@b.c", "@b.c", "a@localhost", "a@.com", "a@example.", "a @b.c", "a@b.c\r\nBcc: victim@example.com"] {
            XCTAssertFalse(MailComposeFormatting.isValid(.init(email)), email)
        }
        XCTAssertFalse(MailComposeFormatting.isValid(.init("a@b.c", name: "A\nB")))
    }
    func testMailtoDecodesPathAndAllSupportedFieldsWithoutChangingPlus() throws {
        let account = UUID(), url = try XCTUnwrap(URL(string: "mailto:one@example.com,two%2Btag@example.com?to=three%40example.com&cc=copy%40example.com&bcc=secret%40example.com&subject=Caf%C3%A9%20%26%20notes&body=Hello%0D%0AWorld%0A%3E%20Quote&ignored=x"))
        let value = try XCTUnwrap(MailComposeFormatting.mailto(url, accountID: account))
        XCTAssertEqual(value.accountID, account)
        XCTAssertEqual(value.to.map(\.email), ["one@example.com", "two+tag@example.com", "three@example.com"])
        XCTAssertEqual(value.cc.map(\.email), ["copy@example.com"]); XCTAssertEqual(value.bcc.map(\.email), ["secret@example.com"])
        XCTAssertEqual(value.subject, "Café & notes"); XCTAssertEqual(value.body, "Hello\nWorld\n> Quote")
        XCTAssertNil(MailComposeFormatting.mailto(URL(string: "https://example.com")!))
    }
    func testPlainTextQuotesAndWrapperPreserveLineBreaks() {
        let html = MailComposeFormatting.plainHTML("Hello <&>\n\n> First\n>> Nested\n> Back\nDone")
        XCTAssertTrue(html.contains("Hello &lt;&amp;&gt;")); XCTAssertTrue(html.contains("<div><br></div>"))
        XCTAssertTrue(html.contains("<blockquote type=\"cite\"><div>First</div><blockquote type=\"cite\"><div>Nested</div></blockquote><div>Back</div></blockquote><div>Done</div>"))
        let wrapped = MailComposeFormatting.document(html: "<p>Test</p>")
        XCTAssertTrue(wrapped.hasPrefix("<!doctype html>")); XCTAssertTrue(wrapped.contains("font-size:13px"))
        XCTAssertTrue(MailComposeFormatting.document(html: nil).contains("<div><br></div>"))
        let full = "<!doctype html><html><head><title>Original</title></head><BODY class=\"original\">Hi</BODY></html>"
        XCTAssertEqual(MailComposeFormatting.document(html: full), full)
    }
    func testSuggestionsMatchNameWordsDiacriticsAndEmailPrefixes() {
        let values = (0..<12).map { MailAddressSuggestion(address: .init("person\($0)@example.com", name: "Élodie García \($0)"), count: 12 - $0, lastUsed: Date()) }
        XCTAssertEqual(MailComposeFormatting.suggestions(values, matching: "gar", excluding: []).count, 8)
        XCTAssertEqual(MailComposeFormatting.suggestions(values, matching: "elodie", excluding: [values[0].address]).first, values[1].address)
        XCTAssertEqual(MailComposeFormatting.suggestions(values, matching: "PERSON2", excluding: []), [values[2].address])
        XCTAssertTrue(MailComposeFormatting.suggestions(values, matching: "lod", excluding: []).isEmpty)
    }
}
