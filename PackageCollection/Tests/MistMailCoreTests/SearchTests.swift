import XCTest
@testable import MistMailCore

final class SearchTests: XCTestCase {
    func testPrefixBodyAddressScopesAndDeduplication() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, from: [.init("alice@example.com", name: "Alice")], subject: "Meeting", messageID: "<same@example.com>"), body: .init(plainText: "Zebra planning"))
        await fixture.server.put(.init(uid: 4, from: [.init("alice@example.com")], subject: "Meeting", messageID: "<same@example.com>"), in: "Projects")
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let project = try await engine.mailboxes().first { $0.name == "Projects" }!
        try await engine.open(project.id)
        let prefix = try await engine.search("Mee"), body = try await engine.search("Zeb"), sender = try await engine.search("Ali")
        XCTAssertEqual(prefix.count, 1); XCTAssertEqual(body.count, 1); XCTAssertEqual(sender.count, 1)
        let scoped = try await engine.search("Mee", scope: .mailbox(project.id))
        XCTAssertEqual(scoped[0].mailboxID, project.id)
        let inbox = try await engine.mailboxes().first { $0.role == .inbox }!
        await fixture.server.put(.init(uid: 1, subject: "Meeting sent"), in: "Sent")
        try await engine.refresh(accountID: account.id)
        let scopedBoxes = try await engine.search("Mee", scope: .mailboxes([inbox.id, project.id]))
        XCTAssertEqual(scopedBoxes.count, 1) // Duplicate copies still collapse within the scope.
        XCTAssertTrue(scopedBoxes.allSatisfy { [inbox.id, project.id].contains($0.mailboxID) })
        let noBoxes = try await engine.search("Mee", scope: .mailboxes([]))
        XCTAssertTrue(noBoxes.isEmpty)
        let empty = try await engine.search("\" OR **"), wrongAccount = try await engine.search("Mee", scope: .account(UUID()))
        XCTAssertTrue(empty.isEmpty); XCTAssertTrue(wrongAccount.isEmpty)
        await fixture.server.put(.init(uid: 5, subject: "关于明天的会议安排"), body: .init(plainText: "请准时参加"))
        try await engine.refresh(accountID: account.id)
        let chinese = try await engine.search("会议"), mixed = try await engine.search("准时 Mee"), chineseBody = try await engine.search("准时")
        XCTAssertEqual(chinese.map(\.uid), [5]); XCTAssertTrue(mixed.isEmpty); XCTAssertEqual(chineseBody.map(\.uid), [5])
        await fixture.server.put(.init(uid: 8, subject: "Remote result"), in: "Projects")
        let remote = try await engine.searchServer("Remote", mailbox: project.id)
        XCTAssertEqual(remote.map(\.uid), [8])
        await engine.stop()
    }
}
