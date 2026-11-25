import XCTest
@testable import MistMailCore

final class UndoTests: XCTestCase {
    private func setUpMailbox() async throws -> (EngineFixture, MailEngine, MailAccount, MailMessageSummary) {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, messageID: "<undo@example.com>"))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let messages = try await engine.messages(in: .unifiedInbox)
        return (fixture, engine, account, try XCTUnwrap(messages.first))
    }

    func testUndoOfflineTrashRestoresOriginalIDWithoutSending() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        await engine.networkBecameUnavailable()
        let operation = try await engine.trash(message.id)
        let hidden = try await engine.messages(in: .unifiedInbox)
        XCTAssertTrue(hidden.isEmpty)

        let result = try await engine.undo(operation)
        let restored = try await engine.messages(in: .unifiedInbox)
        let pending: [PendingMailOperation] = try await engine.store.pending(accountID: account.id)
        let moves = await fixture.server.moveCount
        XCTAssertEqual(restored.map(\.id), [message.id])
        XCTAssertEqual(result.messageIDs, [message.id])
        XCTAssertTrue(result.operationIDs.isEmpty)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(moves, 0)
        await engine.stop()
    }

    func testUndoReplayedTrashArchiveAndCustomMove() async throws {
        let (fixture, engine, account, original) = try await setUpMailbox()
        let mailboxes = try await engine.mailboxes()
        let projects = try XCTUnwrap(mailboxes.first { $0.name == "Projects" })
        var message = original.id
        for destination in ["Trash", "Archive", "Projects"] {
            let operation: UUID
            switch destination {
            case "Trash": operation = try await engine.trash(message)
            case "Archive": operation = try await engine.archive(message)
            default: operation = try await engine.move(message, to: projects.id)
            }
            try await engine.flushPending(accountID: account.id)
            let result = try await engine.undo(operation)
            try await assertRestored(result, from: destination, engine: engine, server: fixture.server)
            message = try XCTUnwrap(result.messageIDs.first)
        }
        let current = await engine.currentMessageID(original.id)
        XCTAssertEqual(current, message)
        await engine.stop()
    }

    func testUndoReplayedFlagsFollowsMovedMessage() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        let flagged = try await engine.setFlagged(message.id, true)
        let seen = try await engine.setSeen(message.id, true)
        let trash = try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        _ = try await engine.undo(trash)
        _ = try await engine.undo(seen)
        _ = try await engine.undo(flagged)
        let server = await fixture.server.boxes
        XCTAssertEqual(server["INBOX"]?.first?.flags, [])
        await engine.stop()
    }

    func testUndoPendingFlagsRebasesLaterChanges() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        await engine.networkBecameUnavailable()
        let flagged = try await engine.setFlagged(message.id, true)
        let unflagged = try await engine.setFlagged(message.id, false)
        let seen = try await engine.setSeen(message.id, true)
        _ = try await engine.undo(flagged)
        _ = try await engine.undo(unflagged)
        _ = try await engine.undo(seen)
        let restored = try await engine.summary(message.id)
        let pending: [PendingMailOperation] = try await engine.store.pending(accountID: account.id)
        let server = await fixture.server.boxes
        XCTAssertEqual(restored.flags, [])
        XCTAssertEqual(server["INBOX"]?.first?.flags, [])
        XCTAssertTrue(pending.isEmpty)
        await engine.stop()
    }

    func testUndoMarkAllReadPreservesPreviouslyReadMessages() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        await fixture.server.put(.init(uid: 2))
        await fixture.server.put(.init(uid: 3, flags: [MailFlags.seen]))
        try await engine.refresh(accountID: account.id)
        let operations = try await engine.markAllRead([message.mailboxID])
        try await engine.flushPending(accountID: account.id)
        _ = try await engine.undo(XCTUnwrap(operations.first))
        let server = await fixture.server.boxes
        XCTAssertEqual(server["INBOX"]?.filter { $0.flags.contains(MailFlags.seen) }.map(\.uid), [3])
        await engine.stop()
    }

    func testUndoPermanentDeleteIsUnsupported() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        let mailboxes = try await engine.mailboxes()
        let trash = try XCTUnwrap(mailboxes.first { $0.role == .trash })
        let trashed = try await engine.messages(in: .mailbox(trash.id))
        let operation = try await engine.delete(XCTUnwrap(trashed.first).id)
        try await engine.flushPending(accountID: account.id)
        do { _ = try await engine.undo(operation); XCTFail("Undo accepted a permanent delete") }
        catch { XCTAssertEqual(error as? MailError, .unsupported) }
        let server = await fixture.server.boxes
        XCTAssertEqual(server["Trash"]?.count, 0)
        await engine.stop()
    }

    func testUndoInFlightMoveWaitsForReplay() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        let moveStarted = expectation(description: "Move reached the server")
        let gate = MailOperationGate()
        await gate.acquire()
        await fixture.server.pauseNextMove {
            moveStarted.fulfill()
            await gate.acquire()
            await gate.release()
        }
        let operation = try await engine.trash(message.id)
        await fulfillment(of: [moveStarted], timeout: 2)
        let undo = Task { try await engine.undo(operation) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while await !engine.undoingOperations.contains(operation), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let undoStarted = await engine.undoingOperations.contains(operation)
        XCTAssertTrue(undoStarted)
        let stillPending = try await engine.store.pendingOperation(operation)
        XCTAssertNotNil(stillPending)
        await gate.release()
        let result = try await undo.value
        try await assertRestored(result, from: "Trash", engine: engine, server: fixture.server)
        let pending: [PendingMailOperation] = try await engine.store.pending(accountID: account.id)
        XCTAssertTrue(pending.isEmpty)
        await engine.stop()
    }

    func testUndoMoveWithoutCopyUIDFindsBothCopiesByMessageID() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        await fixture.server.omitCopyUID()
        let operation = try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        let result = try await engine.undo(operation)
        try await assertRestored(result, from: "Trash", engine: engine, server: fixture.server)
        let current = await engine.currentMessageID(message.id)
        XCTAssertEqual(current, result.messageIDs.first)
        await engine.stop()
    }

    func testRedoOfflineInverseMoveCancelsItAndKeepsUndoAvailable() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        let operation = try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        await engine.networkBecameUnavailable()
        let undo = try await engine.undo(operation)
        let canceled = try await engine.cancelPendingUndoMove(XCTUnwrap(undo.operationIDs.first))
        let pending: [PendingMailOperation] = try await engine.store.pending(accountID: account.id)
        let remote = await fixture.server.boxes
        XCTAssertTrue(canceled)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(remote["Trash"]?.count, 1)
        await engine.networkBecameAvailable()
        let restored = try await engine.undo(operation)
        try await assertRestored(restored, from: "Trash", engine: engine, server: fixture.server)
        await engine.stop()
    }

    func testDeferredUndoMoveWithoutCopyUIDResolvesAfterReconnect() async throws {
        let (fixture, engine, account, message) = try await setUpMailbox()
        let operation = try await engine.trash(message.id)
        try await engine.flushPending(accountID: account.id)
        await fixture.server.omitCopyUID()
        await engine.networkBecameUnavailable()
        let undo = try await engine.undo(operation)
        await engine.networkBecameAvailable()
        try await engine.flushPending(accountID: account.id)
        let restoredID = try await engine.resolveCurrentMessageID(XCTUnwrap(undo.messageIDs.first))
        let inbox = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(restoredID, inbox.first?.id)
        await engine.stop()
    }

    private func assertRestored(_ result: MailUndoResult, from destination: String,
                                engine: MailEngine, server: FakeMailServer) async throws {
        let inbox = try await engine.messages(in: .unifiedInbox)
        let boxes = await server.boxes
        XCTAssertEqual(boxes["INBOX"]?.map(\.messageID), ["<undo@example.com>"])
        XCTAssertEqual(boxes[destination]?.count, 0)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(result.messageIDs, inbox.map(\.id))
        XCTAssertEqual(result.operationIDs.count, 1)
    }
}
