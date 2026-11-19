import XCTest
@testable import MistMailCore

final class StoreTests: XCTestCase {
    func testEngineSummaryExcludesHiddenMessages() async throws {
        let fixture = EngineFixture()
        let account = MailAccount(config: testConfig())
        let box = Mailbox(accountID: account.id, name: "INBOX")
        var message = StoredMessage(id: UUID(), accountID: account.id, mailboxID: box.id, remote: .init(uid: 1))
        let store = try MailStore(base: fixture.base)
        try store.save(account); try store.save(box); try store.save(message)
        let engine = try fixture.engine()
        let result = try await engine.summary(message.id)
        XCTAssertEqual(result, message.summary)
        message.hidden = true; try store.save(message)
        do { _ = try await engine.summary(message.id); XCTFail("Expected notFound") }
        catch { XCTAssertEqual(error as? MailError, .notFound) }
    }
    func testSummaryRecipientsSurviveStoredMessageReload() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let account = MailAccount(config: testConfig()), box = Mailbox(accountID: UUID(), name: "Sent")
        let sent = Mailbox(id: box.id, accountID: account.id, name: "Sent", role: .sent)
        let recipients = [MailAddress("ada@example.com", name: "Ada")]
        let message = StoredMessage(id: UUID(), accountID: account.id, mailboxID: sent.id, remote: .init(uid: 1, to: recipients))
        do {
            let store = try MailStore(base: base)
            try store.save(account); try store.save(sent); try store.save(message)
        }
        let reopened = try MailStore(base: base)
        XCTAssertEqual(try reopened.list(scope: .mailbox(sent.id), before: nil, limit: 200).first?.recipients, recipients)
    }
    func testMigrationFromVersionOneBackfillsAttachmentIndex() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let account = MailAccount(config: testConfig()), boxID = UUID(), messageID = UUID()
        let part = MailPart(section: "2", mimeType: "application/pdf", filename: "file.pdf", isAttachment: true)
        let attachment = MailAttachment(id: UUID(), messageID: messageID, part: part)
        do {
            let store = try MailStore(base: base)
            try store.save(account); try store.save(Mailbox(id: boxID, accountID: account.id, name: "INBOX"))
            try store.save(StoredMessage(id: messageID, accountID: account.id, mailboxID: boxID, remote: .init(uid: 1, parts: [part]), attachments: [attachment]))
            try store.db.execute("DROP TABLE attachments"); try store.db.execute("PRAGMA user_version=1")
        }
        let migrated = try MailStore(base: base)
        XCTAssertEqual(try migrated.db.rows("PRAGMA user_version").first?["user_version"]?.int, 2)
        XCTAssertEqual(try migrated.db.rows("SELECT id FROM attachments").first?["id"]?.string, attachment.id.uuidString)
    }
    func testPersistenceSearchIndexAndCascade() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let config = MailAccountConfig(displayName: "Test", senderName: "Me", email: "me@example.com", username: "me", imap: .init(host: "localhost", port: 143, security: .plaintext), smtp: .init(host: "localhost", port: 25, security: .plaintext))
        let account = MailAccount(config: config)
        let box = Mailbox(accountID: account.id, name: "INBOX", role: .inbox)
        let message = StoredMessage(id: UUID(), accountID: account.id, mailboxID: box.id, remote: .init(uid: 1, subject: "Searchable subject"))
        do {
            let store = try MailStore(base: base)
            try store.save(account); try store.save(box); try store.save(message)
            XCTAssertEqual(try store.unreadCounts().unifiedInbox, 1)
            XCTAssertEqual(try store.db.rows("SELECT * FROM message_search WHERE message_search MATCH 'Search*'").count, 1)
            XCTAssertThrowsError(try store.db.execute("INSERT INTO mailboxes VALUES ('bad','missing','bad',X'00')"))
        }
        let store = try MailStore(base: base)
        XCTAssertEqual(try store.accounts(), [account])
        XCTAssertEqual(try store.message(message.id).summary, message.summary)
        try store.deleteAccount(account.id)
        XCTAssertTrue(try store.mailboxes().isEmpty)
        XCTAssertTrue(try store.db.rows("SELECT * FROM message_search").isEmpty)
    }
    func testPlaintextAndRoleRules() throws {
        XCTAssertThrowsError(try MailServer(host: "example.com", port: 143, security: .plaintext).validate())
        for host in ["localhost", "127.0.0.1", "::1"] { try MailServer(host: host, port: 143, security: .plaintext).validate() }
        XCTAssertEqual(Mailbox.detectRole(name: "Sent Items", attributes: [], gmail: false), .sent)
        XCTAssertEqual(Mailbox.detectRole(name: "Special", attributes: ["\\Trash"], gmail: false), .trash)
        XCTAssertEqual(Mailbox.detectRole(name: "All Mail", attributes: ["\\All"], gmail: true), .all)
        XCTAssertFalse(Mailbox(accountID: UUID(), name: "All Mail", role: .all).autoSync)
    }
    func testCredentialsAreIsolated() throws {
        let store = InMemoryMailCredentialStore(), a = UUID(), b = UUID()
        try store.save("a", accountID: a); try store.save("b", accountID: b)
        try store.delete(accountID: a)
        XCTAssertNil(try store.load(accountID: a)); XCTAssertEqual(try store.load(accountID: b), "b")
        XCTAssertEqual(KeychainMailCredentialStore.service(bundleID: "com.bulldf.mist.dev"), "Mist Mail (com.bulldf.mist.dev)")
    }
}
