import XCTest
@testable import MistMailCore

final class SyncTests: XCTestCase {
    func testRefusedQueuedTogglesRebaseTheirRollbackSnapshots() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        await engine.networkBecameUnavailable()
        try await engine.setSeen(message.id, true); try await engine.setSeen(message.id, false)
        await fixture.server.setActionFailure(.serverRejected("Read only"))
        await engine.networkBecameAvailable()
        let result = try await engine.messages(in: .unifiedInbox)
        XCTAssertFalse(result[0].flags.contains(MailFlags.seen))
        await engine.stop()
    }
    func testEmptyWindowDoesNotFetchOldMessagesOnNextSync() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 42, date: Date().addingTimeInterval(-100 * 86400)))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id); try await engine.refresh(accountID: account.id)
        let messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertTrue(messages.isEmpty)
        let box = try await engine.mailboxes().first { $0.role == .inbox }!
        try await engine.loadOlder(box.id)
        let older = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(older.map(\.uid), [42])
        await engine.stop()
    }
    func testStoredSearchHitDoesNotSkipEarlierNewMail() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, subject: "First"))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let box = try await engine.mailboxes().first { $0.role == .inbox }!
        await fixture.server.put(.init(uid: 2, subject: "Arrived meanwhile")); await fixture.server.put(.init(uid: 3, subject: "Remote hit"))
        _ = try await engine.searchServer("Remote", mailbox: box.id)
        try await engine.refresh(accountID: account.id)
        let messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(Set(messages.map(\.uid)), [1, 2, 3])
        await engine.stop()
    }
    func testRefusedDraftFlushDoesNotReconnect() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let draft = try await engine.saveDraft(MailDraft(accountID: account.id, to: [.init("bob")], subject: "Half-typed"))
        let before = await fixture.server.connectCount
        do { try await engine.flushDraft(draft.id); XCTFail("Invalid recipient flushed") } catch { XCTAssertEqual(error as? MailError, .invalidConfiguration) }
        let status = await engine.accountStatuses()[account.id], after = await fixture.server.connectCount
        XCTAssertEqual(status, .connected); XCTAssertEqual(after, before)
        await engine.stop()
    }
    func testLoadOlderFillsHolesAboveTheOldestStoredMessage() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let old = Date().addingTimeInterval(-400 * 86400)
        await fixture.server.put(.init(uid: 3, subject: "Recent"))
        // Moved here today, so a high UID with an old arrival date: the first sync's date search skips it.
        await fixture.server.put(.init(uid: 9, subject: "Old, moved", date: old, internalDate: old))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let box = try await engine.mailboxes().first { $0.role == .inbox }!
        var messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(messages.map(\.uid), [3])
        try await engine.loadOlder(box.id)
        messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(Set(messages.map(\.uid)), [3, 9])
        await engine.stop()
    }
    func testOfflineArchiveCreatesDestinationAndAccountRemovalCleansState() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, parts: [.init(section: "2", mimeType: "application/pdf", filename: "test.pdf", isAttachment: true)]))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        let detail = try await engine.messageDetail(message.id)
        let file = try await engine.attachmentFile(detail.attachments[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await engine.networkBecameUnavailable(); try await engine.archive(message.id)
        await engine.networkBecameAvailable()
        let archive = try await engine.mailboxes().first { $0.role == .archive }!
        let archived = try await engine.messages(in: .mailbox(archive.id))
        XCTAssertEqual(archived.count, 1)
        try await engine.removeAccount(account.id)
        XCTAssertNil(try fixture.credentials.load(accountID: account.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let boxes = try await engine.mailboxes(), accounts = try await engine.accounts()
        XCTAssertTrue(boxes.isEmpty); XCTAssertTrue(accounts.isEmpty)
        await engine.stop()
    }
    func testWindowIncrementalFlagsDeletionOlderAndValidity() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, date: Date().addingTimeInterval(-100 * 86400)))
        await fixture.server.put(.init(uid: 2, subject: "Recent"))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let box = try await engine.mailboxes().first { $0.role == .inbox }!
        var messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(messages.map(\.uid), [2])
        try await engine.loadOlder(box.id)
        messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(Set(messages.map(\.uid)), [1, 2])
        await fixture.server.remove(1)
        try await fixture.server.setFlag(MailFlags.seen, value: true, uids: [2], in: "INBOX")
        await fixture.server.put(.init(uid: 3))
        try await engine.refresh(accountID: account.id)
        messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(Set(messages.map(\.uid)), [2, 3])
        XCTAssertTrue(messages.first { $0.uid == 2 }!.flags.contains(MailFlags.seen))
        await fixture.server.reset("INBOX"); await fixture.server.put(.init(uid: 1, subject: "New validity"))
        try await engine.refresh(accountID: account.id)
        messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(messages.map(\.subject), ["New validity"])
        await engine.stop()
    }
    func testOptimisticReplayRelaunchRollbackAndMoveUID() async throws {
        let fixture = EngineFixture()
        var engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        await engine.networkBecameUnavailable()
        try await engine.setSeen(message.id, true)
        var messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertTrue(messages[0].flags.contains(MailFlags.seen))
        await engine.stop()
        engine = try fixture.engine()
        try await engine.flushPending(accountID: account.id)
        let flags = try await fixture.server.flags(1...1, in: "INBOX")
        XCTAssertTrue(flags[1]!.contains(MailFlags.seen))
        await fixture.server.setFailure(.serverRejected("Read only"))
        try await engine.setFlagged(message.id, true)
        try await engine.flushPending(accountID: account.id)
        messages = try await engine.messages(in: .unifiedInbox)
        XCTAssertFalse(messages[0].flags.contains(MailFlags.flagged))
        await fixture.server.setFailure(nil)
        let trash = try await engine.mailboxes().first { $0.role == .trash }!
        try await engine.move(message.id, to: trash.id)
        try await engine.flushPending(accountID: account.id)
        messages = try await engine.messages(in: .mailbox(trash.id))
        XCTAssertEqual(messages.count, 1)
        let source = try await engine.messages(in: .unifiedInbox)
        XCTAssertTrue(source.isEmpty)
        await engine.stop()
    }
    func testGmailRolesDuplicatesAndLazyMailboxes() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.setGmail()
        await fixture.server.put(.init(uid: 1, gmailMessageID: "123"))
        await fixture.server.put(.init(uid: 7, gmailMessageID: "123"), in: "Projects")
        let account = try await engine.addAccount(testConfig(), password: "test")
        XCTAssertTrue(account.isGmail)
        try await engine.refresh(accountID: account.id)
        let fetched = await fixture.server.fetched
        XCTAssertNil(fetched["All Mail"]); XCTAssertNil(fetched["Starred"]); XCTAssertNil(fetched["Projects"])
        let project = try await engine.mailboxes().first { $0.name == "Projects" }!
        try await engine.open(project.id)
        let message = try await engine.messages(in: .unifiedInbox).first!
        await engine.networkBecameUnavailable()
        try await engine.setSeen(message.id, true)
        let duplicates = try await engine.messages(in: .mailbox(project.id))
        XCTAssertTrue(duplicates[0].flags.contains(MailFlags.seen))
        let projectMessage = duplicates[0]
        do { _ = try await engine.archive(projectMessage.id); XCTFail("Gmail archive outside inbox") } catch { XCTAssertEqual(error as? MailError, .unsupported) }
        await engine.stop()
    }
    func testIdleCoalescesAndEmitsOnlyNewInboxMail() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.start(); try await engine.refresh(accountID: account.id)
        let stream = await engine.events()
        let expectation = expectation(description: "New mail event")
        let reader = Task {
            for await event in stream { if case .newMessages(let values) = event, values.contains(where: { $0.subject == "Arrived" }) { expectation.fulfill(); break } }
        }
        await fixture.server.put(.init(uid: 1, subject: "Arrived"))
        await fulfillment(of: [expectation], timeout: 3)
        reader.cancel(); await engine.stop()
    }
    func testAuthenticationFailureWaitsForCredentialChange() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        await fixture.server.setFailure(.authenticationFailed)
        do { try await engine.refresh(accountID: account.id); XCTFail() } catch {}
        let status = await engine.accountStatuses()
        XCTAssertEqual(status[account.id], .authFailed)
        let count = await fixture.server.connectCount
        await engine.networkBecameAvailable()
        let after = await fixture.server.connectCount
        XCTAssertEqual(count, after)
        await fixture.server.setFailure(nil)
        try await engine.updateAccount(account.id, config: testConfig(), password: "new")
        try await engine.refresh(accountID: account.id)
        await engine.stop()
    }
    func testReconnectRecoversFromFailedSignIn() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        await fixture.server.setFailure(.authenticationFailed)
        do { try await engine.refresh(accountID: account.id); XCTFail() } catch {}
        var status = await engine.accountStatuses()
        XCTAssertEqual(status[account.id], .authFailed)
        await fixture.server.setFailure(nil)
        await engine.reconnect(accountID: account.id)
        status = await engine.accountStatuses()
        XCTAssertEqual(status[account.id], .connected)
        await engine.stop()
    }
    /// Wi-Fi link quality changes send path updates that keep the interfaces: only a real change reconnects.
    func testOnlyRealNetworkChangesReconnect() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        func connects() async -> Int { await fixture.server.connectCount }
        let initial = await connects()
        await engine.networkPathChanged(satisfied: true, interfaces: ["en0"])
        await engine.networkPathChanged(satisfied: true, interfaces: ["en0"])
        var count = await connects()
        XCTAssertEqual(count, initial)
        await engine.networkPathChanged(satisfied: true, interfaces: ["en0", "utun4"])
        count = await connects()
        XCTAssertEqual(count, initial + 1)
        await engine.networkPathChanged(satisfied: false, interfaces: [])
        var status = await engine.accountStatuses()
        XCTAssertEqual(status[account.id], .disconnected)
        await engine.networkPathChanged(satisfied: true, interfaces: ["en0"])
        count = await connects(); status = await engine.accountStatuses()
        XCTAssertEqual(count, initial + 2); XCTAssertEqual(status[account.id], .connected)
        await engine.stop()
    }
}
