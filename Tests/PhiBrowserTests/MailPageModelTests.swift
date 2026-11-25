import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailPageModelTests: XCTestCase {
    func testDeletingSelectedMessageSelectsNextThenUndoReselectsAndRedoRemovesIt() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let first = try XCTUnwrap(model.messages.first), next = model.messages[1].id
        model.selectMessage(first.id)
        let delete = model.perform(.delete)
        XCTAssertEqual(model.selection, next)
        await delete?.value
        XCTAssertFalse(model.messages.contains { $0.id == first.id })
        let state = try await source.snapshot(), trash = try XCTUnwrap(state.mailboxes.first { $0.accountID == first.accountID && $0.role == .trash })
        let deleted = try await source.messages(in: .mailbox(trash.id), before: nil, limit: 200)
        XCTAssertTrue(deleted.contains { $0.id == first.id })
        XCTAssertTrue(model.canUndo)
        await model.undo()
        XCTAssertEqual(model.selection, first.id)
        XCTAssertTrue(model.messages.contains { $0.id == first.id })
        XCTAssertTrue(model.canRedo)
        await model.redo()
        XCTAssertEqual(model.selection, next)
        XCTAssertFalse(model.messages.contains { $0.id == first.id })
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testOpeningUnreadMessageDoesNotRecordUndo() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let message = try XCTUnwrap(model.messages.first { !$0.flags.contains(MailFlags.seen) && !$0.hasAttachments })
        let reader = MailReaderViewController(model: model)
        reader.show(message)
        // The empty undo drains the model's queue after the reader's automatic action.
        await model.undo()
        let seen = try await source.summary(message.id)
        XCTAssertTrue(seen.flags.contains(MailFlags.seen))
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testNewActionClearsRedoAndRedoPreservesOlderEntries() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let first = model.messages[0], second = model.messages[1]
        await model.perform(.seen(true), message: first)?.value
        await model.perform(.flagged(true), message: second)?.value
        await model.undo()
        await model.undo()
        await model.redo()
        XCTAssertTrue(model.canRedo)
        XCTAssertTrue(model.canUndo)
        await model.perform(.seen(false), message: second)?.value
        XCTAssertFalse(model.canRedo)
    }

    func testFailedOperationDropsItsUndoEntry() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        model.start()
        for _ in 0..<100 where !model.didStart { try await Task.sleep(for: .milliseconds(5)) }
        let message = try XCTUnwrap(model.messages.first)
        await model.perform(.flagged(false), message: message)?.value
        XCTAssertTrue(model.canUndo)
        try await source.failAction(XCTUnwrap(source.lastOperationID))
        for _ in 0..<100 where model.canUndo { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.canUndo)
        XCTAssertNotNil(model.banner)
    }

    func testPermanentDeleteInTrashDoesNotRecordUndo() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let message = try XCTUnwrap(model.messages.first)
        _ = try await source.trash(message.id)
        let trashed = try await source.summary(message.id)
        await model.perform(.delete, message: trashed)?.value
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testUndoWithEmptyStackDoesNothing() async {
        let model = MailPageModel(source: FixtureMailPageDataSource(), defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let before = model.messages
        await model.undo()
        XCTAssertEqual(model.messages, before)
        XCTAssertNil(model.banner)
        XCTAssertFalse(model.canRedo)
    }

    func testUndoAndRedoMarkAllReadAfterChangingMailbox() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let unread = model.state.unread.unifiedInbox
        await model.markAllRead()
        XCTAssertEqual(model.state.unread.unifiedInbox, 0)
        model.selectMailbox(try XCTUnwrap(model.state.mailboxes.first { $0.role == .sent }).id.uuidString)
        await model.undo()
        let restored = try await source.snapshot()
        XCTAssertEqual(restored.unread.unifiedInbox, unread)
        await model.redo()
        XCTAssertEqual(model.state.unread.unifiedInbox, 0)
    }
    func testFixturePagesAreCursorOrderedAndHaveFrenchNestedMailboxes() async throws {
        let source = FixtureMailPageDataSource(), state = try await source.snapshot()
        let first = try await source.messages(in: .unifiedInbox, before: nil, limit: 200)
        let second = try await source.messages(in: .unifiedInbox, before: first.last.map(MailMessageCursor.init), limit: 200)
        XCTAssertEqual(first.count, 200); XCTAssertEqual(second.count, 40)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        XCTAssertTrue(state.mailboxes.contains { $0.displayName == "[Gmail]/Messages envoyés" })
        let nodes = MailboxTreeNode.build(state)
        XCTAssertEqual(nodes.first?.key, "unified")
        XCTAssertTrue(nodes.first { $0.accountID == state.accounts[0].id }!.children.contains { $0.title == "[Gmail]" && !$0.canSelect && !$0.children.isEmpty })
        XCTAssertTrue(nodes.first { $0.accountID == state.accounts[1].id }!.children.contains { $0.title == "Projects" && !$0.children.isEmpty })
    }
    func testSeparateModelsShareDataButKeepTheirOwnMessageSelection() async throws {
        let source = FixtureMailPageDataSource(), defaults = makeTestDefaults().defaults
        let first = MailPageModel(source: source, defaults: defaults), second = MailPageModel(source: source, defaults: defaults)
        await first.reloadState(); await first.reloadMessages(); await second.reloadState(); await second.reloadMessages()
        let id = try XCTUnwrap(first.messages.first?.id)
        first.selectMessage(id)
        XCTAssertEqual(first.selection, id); XCTAssertNil(second.selection)
        _ = try await source.perform(.seen(true), on: id)
        await second.reloadMessages()
        XCTAssertTrue(second.messages.first { $0.id == id }!.flags.contains(MailFlags.seen))
    }
}
