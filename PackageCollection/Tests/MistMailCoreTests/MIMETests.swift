import XCTest
import SwiftMail
@testable import MistMailCore

final class MIMETests: XCTestCase {
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures")!) }
    func testTransferEncodingsHeadersFilenamesAndLegacyCharsets() throws {
        let bytes = try fixture("charsets"), decoded = try MailMIME.decode(bytes), parsed = try EMLParser.parse(bytes)
        XCTAssertEqual(decoded.0.subject, "Café 中文")
        XCTAssertEqual(decoded.0.from.first?.name, "Jérôme")
        XCTAssertEqual(decoded.1.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "café")
        XCTAssertEqual(parsed.parts[1].textContent?.trimmingCharacters(in: .whitespacesAndNewlines), "“Hello” €")
        XCTAssertEqual(parsed.parts[2].textContent?.trimmingCharacters(in: .whitespacesAndNewlines), "中文")
        XCTAssertEqual(decoded.0.parts.last?.filename, "café.txt")
        XCTAssertEqual(decoded.2[decoded.0.parts.last!.section], Data([0, 1, 2, 3, 4]))
    }
    func testAlternativeRelatedAndCID() throws {
        let decoded = try MailMIME.decode(fixture("related"))
        XCTAssertEqual(decoded.1.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Plain body")
        XCTAssertTrue(decoded.1.html!.contains("cid:logo@example.com"))
        XCTAssertEqual(decoded.1.inlineParts.count, 1)
        XCTAssertEqual(decoded.1.inlineParts.values.first, Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertEqual(decoded.0.parts.last?.contentID, "logo@example.com")
    }
    func testBodyIsTheMessagesOwnFirstTextNotAnAttachedMessageOrFooter() throws {
        let raw = ["From: a@example.com", "To: b@example.com", "Subject: Fwd", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"outer\"", "",
                   "--outer", "Content-Type: text/plain; charset=utf-8", "", "My note",
                   "--outer", "Content-Type: message/rfc822", "", "From: c@example.com", "Subject: Inner", "MIME-Version: 1.0",
                   "Content-Type: multipart/alternative; boundary=\"inner\"", "",
                   "--inner", "Content-Type: text/plain; charset=utf-8", "", "Inner text",
                   "--inner", "Content-Type: text/html; charset=utf-8", "", "<p>Inner html</p>", "--inner--",
                   "--outer", "Content-Type: text/plain; charset=utf-8", "", "List footer", "--outer--", ""].joined(separator: "\r\n")
        let decoded = try MailMIME.decode(Data(raw.utf8))
        XCTAssertEqual(decoded.1.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "My note")
        XCTAssertNil(decoded.1.html)
        let parts = [MailPart(section: "1", mimeType: "text/plain", size: 1, isAttachment: false), MailPart(section: "2", mimeType: "message/rfc822", size: 1, isAttachment: true),
                     MailPart(section: "2.1", mimeType: "text/plain", size: 1, isAttachment: false), MailPart(section: "2.2", mimeType: "text/html", size: 1, isAttachment: false),
                     MailPart(section: "3", mimeType: "text/plain", size: 1, isAttachment: false)]
        XCTAssertEqual(MailMIME.ownBodySections(parts), ["1"])
    }
    func testErrorClassification() {
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("rejected")), .authenticationFailed)
        XCTAssertEqual(SwiftMailTransport.classify(SMTPError.tlsFailed("certificate")), .tlsFailure)
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.timeout), .timeout)
        XCTAssertEqual(SwiftMailTransport.classify(URLError(.notConnectedToInternet)), .offline)
    }
    /// Gmail's LOGIN refusals, as SwiftMail words them: only wrong credentials stop retrying.
    func testTemporarySignInRefusalsRetry() {
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("no([AUTHENTICATIONFAILED] Invalid credentials (Failure))")), .authenticationFailed)
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("no([ALERT] Application-specific password required (Failure))")), .authenticationFailed)
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("no([ALERT] Too many simultaneous connections. (Failure))")), .cannotConnect)
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("no([ALERT] Account exceeded command or bandwidth limits. (Failure))")), .cannotConnect)
        XCTAssertEqual(SwiftMailTransport.classify(IMAPError.loginFailed("no([UNAVAILABLE] Temporary System Error)")), .cannotConnect)
        XCTAssertEqual(SwiftMailTransport.classify(SMTPError.authenticationFailed("LOGIN: 454 4.7.0 Too many login attempts, please try again later.")), .cannotConnect)
        XCTAssertEqual(SwiftMailTransport.classify(SMTPError.authenticationFailed("PLAIN: 535 5.7.8 Username and Password not accepted.")), .authenticationFailed)
    }
}
