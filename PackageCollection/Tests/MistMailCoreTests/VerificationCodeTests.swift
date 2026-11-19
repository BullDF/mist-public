import XCTest
@testable import MistMailCore

final class VerificationCodeTests: XCTestCase {
    func testCommonCodes() {
        for (text, code) in [
            ("G-482913 is your Google verification code", "482913"),
            ("Your verification code is 482913", "482913"),
            ("Verification code: 48291367", "48291367"),
            ("Your confirmation code is TQX-4W8", "TQX4W8"),
            ("Your code: 123 456", "123456"),
            ("Votre code de vérification : 482913", "482913"),
            ("您的验证码是 482913", "482913"),
            ("Your passcode: AB12CD", "AB12CD")
        ] {
            XCTAssertEqual(MailVerificationCode.extract(subject: text, body: ""), code, text)
            // Google's subject places its keyword after the code; bodies require a preceding keyword.
            if !text.hasPrefix("G-") {
                XCTAssertEqual(MailVerificationCode.extract(subject: "", body: text), code, text)
            }
        }
    }

    func testHTMLAndSubjectPriority() {
        XCTAssertEqual(MailVerificationCode.extract(subject: "", body: MailText.readable("<p>Your verification code is <b>482913</b></p>")), "482913")
        XCTAssertEqual(MailVerificationCode.extract(subject: "Code 482913", body: "Code 123456"), "482913")
    }

    func testRejectsUnrelatedNumbers() {
        for text in ["Order #123456 costs $49.99", "Security newsletter 2026: call +1-416-555-1234",
                     "Your number is 482913", "Code: 2026", "Code: $123456", "Code: 123456%",
                     "Code: 1234.5678", "Code: 12/123456", "Code: https://example.com/482913",
                     "Code: user482913@example.com", "Code: ABCDEFGH",
                     "Code " + String(repeating: "x", count: 201) + " 482913"] {
            XCTAssertNil(MailVerificationCode.extract(subject: "", body: text), text)
        }
    }
}
