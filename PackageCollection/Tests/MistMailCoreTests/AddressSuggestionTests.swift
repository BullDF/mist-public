import XCTest
@testable import MistMailCore

final class AddressSuggestionTests: XCTestCase {
    func testCaseMergeNewestNameRankingAndLimit() async throws {
        let fixture = EngineFixture(), store = try MailStore(base: fixture.base)
        let account = MailAccount(config: testConfig()), box = Mailbox(accountID: UUID(), name: "INBOX")
        try store.save(account)
        try store.save(Mailbox(id: box.id, accountID: account.id, name: box.name))
        let rows: [MailRemoteMessage] = [
            .init(uid: 1, from: [.init("Ada@example.com", name: "Old")], to: [.init("frequent@example.com")], date: Date(timeIntervalSince1970: 1)),
            .init(uid: 2, from: [.init("ada@EXAMPLE.com", name: "Newest")], cc: [.init("frequent@example.com")], date: Date(timeIntervalSince1970: 2)),
            .init(uid: 3, from: [.init("ADA@example.com")], replyTo: [.init("recent@example.com")], date: Date(timeIntervalSince1970: 3))]
        for row in rows { try store.save(StoredMessage(id: UUID(), accountID: account.id, mailboxID: box.id, remote: row)) }
        var hidden = StoredMessage(id: UUID(), accountID: account.id, mailboxID: box.id, remote: .init(uid: 4, from: [.init("hidden@example.com")]))
        hidden.hidden = true; try store.save(hidden)
        let engine = try fixture.engine(), suggestions = try await engine.addressSuggestions()
        XCTAssertEqual(suggestions.map { $0.address.email.lowercased() }, ["ada@example.com", "frequent@example.com", "recent@example.com"])
        XCTAssertEqual(suggestions[0].address.name, "Newest")
        XCTAssertEqual(suggestions[0].count, 3)
        let limited = try await engine.addressSuggestions(limit: 1)
        XCTAssertEqual(limited, Array(suggestions.prefix(1)))
        let empty = try await engine.addressSuggestions(limit: 0)
        XCTAssertTrue(empty.isEmpty)
        await engine.stop()
    }
    func testRecencyBreaksFrequencyTie() async throws {
        let fixture = EngineFixture(), store = try MailStore(base: fixture.base)
        let account = MailAccount(config: testConfig()), box = Mailbox(accountID: UUID(), name: "INBOX")
        try store.save(account); try store.save(Mailbox(id: box.id, accountID: account.id, name: box.name))
        for uid in 1...2 {
            try store.save(StoredMessage(id: UUID(), accountID: account.id, mailboxID: box.id,
                                         remote: .init(uid: UInt32(uid), from: [.init("\(uid)@example.com")], date: Date(timeIntervalSince1970: Double(uid)))))
        }
        let engine = try fixture.engine(), values = try await engine.addressSuggestions()
        XCTAssertEqual(values.map(\.address.email), ["2@example.com", "1@example.com"])
        await engine.stop()
    }
}
