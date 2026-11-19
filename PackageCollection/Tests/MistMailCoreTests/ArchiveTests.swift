import XCTest
@testable import MistMailCore

final class ArchiveTests: XCTestCase {
    func testTrashNeverPermanentlyDeletes() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        let trash = try await engine.mailboxes().first { $0.role == .trash }!
        try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        let trashed = try await engine.messages(in: .mailbox(trash.id)).first!
        await engine.networkBecameUnavailable()
        do { try await engine.trash(trashed.id); XCTFail("Trashed twice") }
        catch { XCTAssertEqual(error as? MailError, .unsupported) }
        try await engine.store.deleteMailbox(trash.id)
        await fixture.server.put(.init(uid: 2))
        await engine.networkBecameAvailable()
        try await engine.refresh(accountID: account.id)
        let second = try await engine.messages(in: .unifiedInbox).first!
        let restoredTrash = try await engine.mailboxes().first { $0.role == .trash }!
        try await engine.store.deleteMailbox(restoredTrash.id)
        await engine.networkBecameUnavailable()
        do { try await engine.trash(second.id); XCTFail("Trashed without a destination") }
        catch { XCTAssertEqual(error as? MailError, .unsupported) }
        let pending: [PendingMailOperation] = try await engine.store.pending(accountID: account.id)
        XCTAssertTrue(pending.isEmpty)
        await engine.stop()
    }
    func testEligibilityMatchesArchiveWithoutCreatingDestination() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        let allowed = try await engine.canArchive(message.id)
        XCTAssertTrue(allowed)
        let before = try await engine.mailboxes()
        XCTAssertFalse(before.contains { $0.role == .archive })
        await engine.networkBecameUnavailable()
        try await engine.archive(message.id)
        await engine.networkBecameAvailable()
        let archive = try await engine.mailboxes().first { $0.role == .archive }!
        let archived = try await engine.messages(in: .mailbox(archive.id)).first!
        let again = try await engine.canArchive(archived.id)
        XCTAssertFalse(again)
        do { try await engine.archive(archived.id); XCTFail("Archive allowed its own destination") }
        catch { XCTAssertEqual(error as? MailError, .unsupported) }
        await engine.stop()
    }
    func testGmailNeedsInboxAndAllMail() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.setGmail(); await fixture.server.put(.init(uid: 1))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        let allowed = try await engine.canArchive(message.id)
        XCTAssertTrue(allowed)
        let all = try await engine.mailboxes().first { $0.role == .all }!
        try await engine.store.deleteMailbox(all.id)
        let missing = try await engine.canArchive(message.id)
        XCTAssertFalse(missing)
        await engine.stop()
    }
}
