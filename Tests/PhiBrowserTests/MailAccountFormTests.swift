import MistMailCore
import XCTest
@testable import Phi

final class MailAccountFormTests: XCTestCase {
    func testPresetServersAndUsernameDefaults() {
        var form = MailAccountForm(senderName: "Johnny")
        form.setEmail("johnny@gmail.com")
        XCTAssertEqual(form.senderName, "Johnny")
        XCTAssertEqual(form.username, "johnny@gmail.com")
        XCTAssertEqual(form.imapHost, "imap.gmail.com")
        XCTAssertEqual(form.smtpPort, "465")
        XCTAssertFalse(form.serverExpanded)
        form.selectPreset(1); form.setEmail("johnny@cs.toronto.edu")
        XCTAssertEqual(form.username, "johnny")
        XCTAssertEqual(form.imapHost, "imap.cs.toronto.edu")
        XCTAssertEqual(form.smtpHost, "smtp.cs.toronto.edu")
        XCTAssertEqual(form.smtpPort, "587")
        XCTAssertEqual(form.smtpSecurity, .startTLS)
        form.selectPreset(2)
        XCTAssertTrue(form.serverExpanded)
        XCTAssertTrue(form.imapHost.isEmpty)
        XCTAssertTrue(form.smtpHost.isEmpty)
    }
    func testCustomUsernameIsPreservedAndInvalidPortIsRejected() {
        var form = MailAccountForm(senderName: "Johnny"); form.username = "custom"
        form.setEmail("johnny@example.com"); XCTAssertEqual(form.username, "custom")
        form.imapPort = "oops"; XCTAssertThrowsError(try form.configuration())
    }
    func testEditingPreservesServersAndLeavesPasswordEmpty() {
        let config = MailAccountConfig(displayName: "School", senderName: "Johnny", email: "johnny@cs.toronto.edu", username: "johnny", imap: MailAccountPreset.uoftCS.imap!, smtp: MailAccountPreset.uoftCS.smtp!, sortOrder: 4)
        let form = MailAccountForm(account: .init(config: config))
        XCTAssertEqual(form.presetIndex, 1); XCTAssertEqual(form.sortOrder, 4); XCTAssertEqual(try form.configuration(), config); XCTAssertTrue(form.password.isEmpty)
    }
    func testEveryMailErrorHasAUserFacingMessage() {
        for error in [MailError.authenticationFailed, .cannotConnect, .tlsFailure, .timeout, .offline, .serverRejected("raw server text"), .invalidConfiguration, .unsupported, .notFound, .missingCredentials, .storage("raw database text")] {
            let text = MailPresentation.errorMessage(error)
            XCTAssertFalse(text.isEmpty); XCTAssertFalse(text.contains("raw "))
        }
    }
}
