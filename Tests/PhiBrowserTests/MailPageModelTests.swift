import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailPageModelTests: XCTestCase {
    func testDeletingSelectedMessageSelectsNextAndMovesItToTrash() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let first = try XCTUnwrap(model.messages.first), next = model.messages[1].id
        model.selectMessage(first.id); model.perform(.delete)
        XCTAssertEqual(model.selection, next)
        for _ in 0..<100 where model.messages.contains(where: { $0.id == first.id }) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.messages.contains { $0.id == first.id })
        let state = try await source.snapshot(), trash = try XCTUnwrap(state.mailboxes.first { $0.accountID == first.accountID && $0.role == .trash })
        let deleted = try await source.messages(in: .mailbox(trash.id), before: nil, limit: 200)
        XCTAssertTrue(deleted.contains { $0.id == first.id })
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
