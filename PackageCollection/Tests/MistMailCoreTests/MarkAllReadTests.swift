import XCTest
@testable import MistMailCore

final class MarkAllReadTests: XCTestCase {
    func testOptimisticRangeReplayLeavesLaterMailUnread() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        // UID 1 is outside the cached date window but must be included on the server.
        await fixture.server.put(.init(uid: 1, date: Date().addingTimeInterval(-100 * 86400)))
        await fixture.server.put(.init(uid: 2))
        await fixture.server.put(.init(uid: 3))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let inbox = try await engine.mailboxes().first { $0.role == .inbox }!
        await engine.networkBecameUnavailable()
        let operations = try await engine.markAllRead([inbox.id])
        XCTAssertEqual(operations.count, 1)
        let cached = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(cached.count, 2)
        XCTAssertTrue(cached.allSatisfy { $0.flags.contains(MailFlags.seen) })
        await fixture.server.put(.init(uid: 4))
        await engine.networkBecameAvailable()
        try await engine.flushPending(accountID: account.id)
        let flags = try await fixture.server.flags(1...4, in: "INBOX")
        for uid: UInt32 in 1...3 { XCTAssertTrue(flags[uid]!.contains(MailFlags.seen)) }
        XCTAssertFalse(flags[4]!.contains(MailFlags.seen))
        await engine.stop()
    }

    func testGmailCopiesAndRollbackPreserveLaterToggle() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.setGmail()
        await fixture.server.put(.init(uid: 1, gmailMessageID: "same"))
        await fixture.server.put(.init(uid: 7, gmailMessageID: "same"), in: "Projects")
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let boxes = try await engine.mailboxes(), inbox = boxes.first { $0.role == .inbox }!
        let projects = boxes.first { $0.name == "Projects" }!
        try await engine.open(projects.id)
        await engine.networkBecameUnavailable()
        try await engine.markAllRead([inbox.id])
        let copies = try await engine.messages(in: .mailbox(projects.id))
        XCTAssertTrue(copies[0].flags.contains(MailFlags.seen))
        try await engine.setSeen(copies[0].id, false)
        await fixture.server.setActionFailure(.serverRejected("Read only"))
        await engine.networkBecameAvailable()
        let result = try await engine.messages(in: .unifiedInbox)
        XCTAssertFalse(result[0].flags.contains(MailFlags.seen))
        await engine.stop()
    }
}
