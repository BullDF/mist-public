import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailUnifiedMailboxTests: XCTestCase {
    func testUnifiedTreeOrderPresenceCountsAndEmptyInbox() async throws {
        let source = FixtureMailPageDataSource(), state = try await source.snapshot()
        let nodes = MailboxTreeNode.build(state)
        XCTAssertEqual(Array(nodes.prefix(5)).map(\.key), ["unified", "unified:drafts", "unified:sent", "unified:trash", "unified:junk"])
        XCTAssertTrue(nodes.prefix(5).allSatisfy(\.canSelect))
        XCTAssertEqual(nodes[0].unreadCount(in: state), state.unread.unifiedInbox)
        var withoutSpam = state; withoutSpam.mailboxes.removeAll { $0.role == .junk }
        XCTAssertFalse(MailboxTreeNode.build(withoutSpam).contains { $0.key == "unified:junk" })
        let empty = try await FixtureMailPageDataSource(empty: true).snapshot()
        XCTAssertEqual(MailboxTreeNode.build(empty).map(\.key), ["unified"])
    }
    func testUnifiedSentSurvivesReloadAndUsesRecipients() async throws {
        let defaults = makeTestDefaults().defaults
        defaults.set("unified:sent", forKey: "mist.mail.selectedMailbox")
        let model = MailPageModel(source: FixtureMailPageDataSource(), defaults: defaults)
        await model.reloadState(); await model.reloadMessages(); await model.reloadState()
        XCTAssertEqual(model.mailboxKey, "unified:sent")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(Set(model.messages.map(\.accountID)).count, 2)
        XCTAssertEqual(model.mailboxIDs.count, 2)
        for message in model.messages {
            let role = model.state.mailboxes.first { $0.id == message.mailboxID }?.role
            XCTAssertEqual(role, .sent)
            XCTAssertEqual(MailPresentation.correspondent(message, role: role), String(format: MailStrings.to, "Ada"))
        }
    }
    func testMissingUnifiedRoleFallsBackAndMarkAllReadDisablesAction() async throws {
        let defaults = makeTestDefaults().defaults
        defaults.set("unified:trash", forKey: "mist.mail.selectedMailbox")
        let empty = MailPageModel(source: FixtureMailPageDataSource(empty: true), defaults: defaults)
        await empty.reloadState()
        XCTAssertEqual(empty.mailboxKey, "unified")
        let model = MailPageModel(source: FixtureMailPageDataSource(), defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        XCTAssertTrue(model.canMarkAllRead)
        await model.markAllRead()
        XCTAssertEqual(model.state.unread.unifiedInbox, 0)
        XCTAssertFalse(model.canMarkAllRead)
        XCTAssertTrue(model.messages.allSatisfy { $0.flags.contains(MailFlags.seen) })
    }
    func testRevealSelectsInboxAndNonInboxMessages() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        let inbox = try XCTUnwrap(model.messages.first)
        let sent = try await source.messages(in: .unifiedRole(.sent), before: nil, limit: 200)[0]
        model.setSearchQuery("missing")
        await model.reveal(messageID: sent.id)
        XCTAssertEqual(model.mailboxKey, sent.mailboxID.uuidString)
        XCTAssertEqual(model.selection, sent.id); XCTAssertFalse(model.isSearching)
        await model.reveal(messageID: inbox.id)
        XCTAssertEqual(model.mailboxKey, "unified"); XCTAssertEqual(model.selection, inbox.id)
    }
    func testStartupConsumesPendingRevealAfterLoadingState() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        let message = try await source.messages(in: .unifiedInbox, before: nil, limit: 1)[0]
        var consumptions = 0
        model.takePendingRevealMessageID = {
            XCTAssertFalse(model.state.mailboxes.isEmpty)
            consumptions += 1
            return message.id
        }
        model.start()
        for _ in 0..<100 where model.selection != message.id { try await Task.sleep(for: .milliseconds(5)) }
        model.takePendingRevealMessageID = nil
        XCTAssertEqual(consumptions, 1); XCTAssertTrue(model.didStart)
        XCTAssertEqual(model.selection, message.id); XCTAssertEqual(model.mailboxKey, "unified")
    }
}
