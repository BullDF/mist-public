import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MistMailNotifierTests: XCTestCase {
    private func account(_ name: String) -> MailAccount {
        .init(config: .init(displayName: name, senderName: "Me", email: "me@example.com", username: "me",
                            imap: .init(host: "localhost", port: 143, security: .plaintext), smtp: .init(host: "localhost", port: 25, security: .plaintext)))
    }
    private func message(_ account: MailAccount, seen: Bool = false, subject: String = "Hello") -> MailMessageSummary {
        .init(id: UUID(), accountID: account.id, mailboxID: UUID(), sender: [.init("ada@example.com", name: "Ada")],
              subject: subject, snippet: "A preview", date: Date(), flags: seen ? [MailFlags.seen] : [], hasAttachments: false, uid: 1)
    }
    func testUpToThreeMessagesHaveSenderSubjectSnippetAndMessageID() {
        let account = account("Personal"), messages = (0..<3).map { _ in message(account) }
        let requests = MailNotificationContent.requests(for: messages, accounts: [account])
        XCTAssertEqual(requests.count, 3)
        for (request, message) in zip(requests, messages) {
            XCTAssertTrue(request.identifier.hasPrefix("mist.mail."))
            XCTAssertEqual(request.title, "Ada"); XCTAssertEqual(request.subtitle, "Hello"); XCTAssertEqual(request.body, "A preview")
            XCTAssertEqual(request.threadIdentifier, account.id.uuidString)
            XCTAssertEqual(request.userInfo, ["messageID": message.id.uuidString])
        }
        let missingSubject = MailNotificationContent.requests(for: [message(account, subject: "")], accounts: [account])
        XCTAssertEqual(missingSubject[0].subtitle, MailStrings.noSubject)
    }
    func testLargerBatchesSummarizeEachAccountWithoutMessageIDs() {
        let first = account("Personal"), second = account("School")
        let messages = [message(first), message(second), message(first), message(second)]
        let requests = MailNotificationContent.requests(for: messages, accounts: [first, second])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.subtitle)), ["Personal", "School"])
        XCTAssertEqual(Set(requests.map(\.threadIdentifier)), [first.id.uuidString, second.id.uuidString])
        XCTAssertTrue(requests.allSatisfy { $0.userInfo.isEmpty && $0.identifier.hasPrefix("mist.mail.summary.") })
        XCTAssertTrue(requests.allSatisfy { $0.title == String.localizedStringWithFormat(MailStrings.newMessages, 2) })
    }
    func testSeenMailIsSkippedBeforeThresholdAndDoesNotNotifyAlone() {
        let account = account("Personal")
        let messages = [message(account), message(account), message(account), message(account, seen: true)]
        XCTAssertEqual(MailNotificationContent.requests(for: messages, accounts: [account]).count, 3)
        XCTAssertTrue(MailNotificationContent.requests(for: [message(account, seen: true)], accounts: [account]).isEmpty)
    }
    func testDelegateRoutingAndDefaultEnabledSettingGate() {
        XCTAssertTrue(MailNotificationPolicy.handles("mist.mail.message.123"))
        XCTAssertTrue(MailNotificationPolicy.handles("mist.mail.summary.123"))
        XCTAssertFalse(MailNotificationPolicy.handles("web.notification.123"))
        XCTAssertFalse(MailNotificationPolicy.handles("mist.mailbox.123"))
        let defaults = makeTestDefaults().defaults
        XCTAssertTrue(MailNotificationPolicy.isEnabled(in: defaults))
        defaults.set(false, forKey: MailNotificationPolicy.settingKey)
        XCTAssertFalse(MailNotificationPolicy.isEnabled(in: defaults))
        defaults.set(true, forKey: MailNotificationPolicy.settingKey)
        XCTAssertTrue(MailNotificationPolicy.isEnabled(in: defaults))
    }
}
