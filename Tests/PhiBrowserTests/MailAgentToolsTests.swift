import XCTest
import MistMailCore
@testable import Phi

@MainActor
final class MailAgentToolsTests: XCTestCase {
    func testWriteSendAndUpdate() async throws {
        let source = FixtureMailPageDataSource(), tools = MailAgentTools(source: source, timeZone: TimeZone(secondsFromGMT: 0)!)
        let model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        let messages = try await source.messages(in: .unifiedInbox, before: nil, limit: 1)
        let message = try XCTUnwrap(messages.first)
        let result = try await tools.writeDraft(["replyTo": message.id.uuidString, "body": "Thanks"])
        let id = try XCTUnwrap((result["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let reply = try await source.draft(id)
        XCTAssertTrue(reply.subject.hasPrefix("Re:")); XCTAssertEqual(reply.replyContext?.sourceMessageID, message.id)
        XCTAssertTrue(reply.plainText.hasPrefix("Thanks")); XCTAssertEqual(source.flushedDrafts, [id]); XCTAssertNil(model.compose)
        _ = try await tools.writeDraft(["draftId": id.uuidString, "body": "Revised"])
        let revised = try await source.draft(id)
        XCTAssertTrue(revised.plainText.hasPrefix("Revised"))
        let blocked = MailAgentTools(source: source, isOpenInCompose: { $0 == id })
        do { _ = try await blocked.send(["draftId": id.uuidString]); XCTFail("Open draft sent") } catch {}
        _ = try await tools.send(["draftId": id.uuidString]); XCTAssertEqual(source.sent.count, 1)
        let update = try await tools.update(ids: [message.id.uuidString, UUID().uuidString], action: "trash", mailbox: nil)
        XCTAssertEqual((update["done"] as? [String])?.count, 1); XCTAssertEqual((update["failed"] as? [[String: String]])?.count, 1)
        let again = try await tools.update(ids: [message.id.uuidString], action: "trash", mailbox: nil)
        XCTAssertEqual((again["failed"] as? [[String: String]])?.count, 1)
    }

    func testDraftRevisionsForwardAttachmentsAndFailures() async throws {
        let source = FixtureMailPageDataSource(), tools = MailAgentTools(source: source, timeZone: TimeZone(secondsFromGMT: 0)!)
        let messages = try await source.messages(in: .unifiedInbox, before: nil, limit: 1)
        let original = try XCTUnwrap(messages.first)
        let expected = try await source.replyDraft(to: original.id, all: false)
        let result = try await tools.writeDraft(["replyTo": original.id.uuidString, "body": "Hello"])
        let id = try XCTUnwrap((result["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let draft = try await source.draft(id)
        XCTAssertEqual(draft.to, expected.to); XCTAssertEqual(draft.replyContext, expected.replyContext)
        XCTAssertEqual(draft.plainText, "Hello" + expected.plainText)
        let html = try XCTUnwrap(draft.html)
        XCTAssertLessThan(try XCTUnwrap(html.range(of: "Hello")?.lowerBound), try XCTUnwrap(html.range(of: "<blockquote")?.lowerBound))
        let detail = try await source.detail(original.id)
        let attachmentPath = try await source.attachmentFile(try XCTUnwrap(detail.attachments.first).id)
        let forwardedResult = try await tools.writeDraft(["forward": original.id.uuidString, "attachments": [attachmentPath.path]])
        let forwardedID = try XCTUnwrap((forwardedResult["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let forwarded = try await source.draft(forwardedID)
        XCTAssertEqual(forwarded.attachments.count, 2)
        let fresh = try await tools.writeDraft(["account": "Personal", "subject": "Attachment", "attachments": [attachmentPath.path]])
        let freshID = try XCTUnwrap((fresh["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let attached = try await source.draft(freshID)
        XCTAssertEqual(attached.attachments.last?.filename, "diagram.png")
        do { _ = try await tools.send(["draftId": freshID.uuidString]); XCTFail("Draft has no recipients") } catch {}
        _ = try await tools.writeDraft(["draftId": id.uuidString, "subject": "Revised"])
        let revised = try await source.draft(id)
        XCTAssertEqual(revised.subject, "Revised"); XCTAssertEqual(revised.to, draft.to); XCTAssertEqual(revised.plainText, draft.plainText); XCTAssertEqual(revised.html, draft.html)
        // Without a body, a revision keeps the draft's own text and formatting, even when its quote was edited.
        var edited = revised; edited.plainText = "Edited\n\n> trimmed quote"; edited.html = "<div><b>Edited</b></div><blockquote>trimmed quote</blockquote>"
        _ = try await source.saveDraft(edited)
        _ = try await tools.writeDraft(["draftId": id.uuidString, "to": ["ada@example.com"]])
        let kept = try await source.draft(id)
        XCTAssertEqual(kept.plainText, edited.plainText); XCTAssertEqual(kept.html, edited.html); XCTAssertEqual(kept.to.map(\.email), ["ada@example.com"])
        let blocked = MailAgentTools(source: source, isOpenInCompose: { $0 == id })
        do { _ = try await blocked.writeDraft(["draftId": id.uuidString]); XCTFail("Open draft revised") } catch { XCTAssertTrue(MailAgentTools.errorMessage(error).contains("close it")) }
        for input: [String: Any] in [["body": "No account"], ["account": "Personal"], ["account": "Personal", "to": ["bad address"]]] {
            do { _ = try await tools.writeDraft(input); XCTFail("Invalid draft accepted") } catch {}
        }
        source.flushError = .offline
        let offline = try await tools.writeDraft(["account": "Personal", "body": "Offline"])
        XCTAssertEqual(offline["savedToServer"] as? Bool, false); XCTAssertNotNil(offline["notice"])
    }

    func testFreshSendAndMessageActions() async throws {
        let source = FixtureMailPageDataSource(), tools = MailAgentTools(source: source)
        let state = try await source.snapshot()
        do { _ = try await tools.send(["account": "Personal", "to": []]); XCTFail("No recipients") } catch {}
        _ = try await tools.send(["account": "Personal", "to": ["Ada <ada@example.com>"], "subject": "Hello", "body": "Text"])
        XCTAssertEqual(source.sent.last?.to.first?.email, "ada@example.com")
        XCTAssertTrue(source.sent.last?.html?.contains("Example Sender") == true)
        source.sendError = .offline
        do { _ = try await tools.send(["account": "Personal", "to": ["ada@example.com"]]); XCTFail("Send should fail") }
        catch { XCTAssertTrue(MailAgentTools.errorMessage(error).contains("Draft ID:")) }
        let remaining = try await source.drafts(); XCTAssertEqual(remaining.count, 1)
        let messages = try await source.messages(in: .unifiedInbox, before: nil, limit: 20)
        let first = try XCTUnwrap(messages.first), other = try XCTUnwrap(messages.first { $0.accountID != first.accountID })
        let otherInbox = try XCTUnwrap(state.mailboxes.first { $0.id == other.mailboxID })
        let wrongAccount = try await tools.update(ids: [first.id.uuidString], action: "move", mailbox: otherInbox.id.uuidString)
        XCTAssertEqual((wrongAccount["failed"] as? [[String: String]])?.count, 1)
        let sameMailbox = try await tools.update(ids: [first.id.uuidString], action: "move", mailbox: "inbox")
        XCTAssertEqual((sameMailbox["failed"] as? [[String: String]])?.count, 1)
        for (action, flag, present) in [("unread", "\\Seen", false), ("read", "\\Seen", true), ("flag", "\\Flagged", true), ("unflag", "\\Flagged", false)] {
            let output = try await tools.update(ids: [first.id.uuidString], action: action, mailbox: nil)
            XCTAssertEqual(output["done"] as? [String], [first.id.uuidString])
            let summary = try await source.summary(first.id); XCTAssertEqual(summary.flags.contains(flag), present)
        }
        let moved = try await tools.update(ids: [first.id.uuidString, other.id.uuidString], action: "move", mailbox: "trash")
        XCTAssertEqual((moved["done"] as? [String])?.count, 2)
        for message in [first, other] {
            let summary = try await source.summary(message.id)
            XCTAssertEqual(state.mailboxes.first { $0.id == summary.mailboxID }?.role, .trash)
        }
        let archiveMessage = try XCTUnwrap(messages.first { $0.id != first.id && $0.id != other.id })
        let archived = try await tools.update(ids: [archiveMessage.id.uuidString], action: "archive", mailbox: nil)
        XCTAssertEqual((archived["done"] as? [String])?.count, 1)
    }
    func testNewReplyAndRevisedBodiesCarryTheAccountSignature() async throws {
        let source = FixtureMailPageDataSource(), tools = MailAgentTools(source: source)
        let state = try await source.snapshot(), account = state.accounts[0]
        let signature = try XCTUnwrap(account.config.signatureHTML)
        let fresh = try await tools.writeDraft(["account": account.config.displayName, "body": "New message"])
        let freshID = try XCTUnwrap((fresh["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let draft = try await source.draft(freshID)
        XCTAssertEqual(draft.plainText, "New message\n\n" + MailText.readable(signature))
        XCTAssertTrue(draft.html?.contains(signature) == true)

        let messages = try await source.messages(in: .unifiedInbox, before: nil, limit: 20)
        let message = try XCTUnwrap(messages.first { $0.accountID == account.id })
        let result = try await tools.writeDraft(["replyTo": message.id.uuidString, "body": "Reply"])
        let replyID = try XCTUnwrap((result["draftId"] as? String).flatMap(UUID.init(uuidString:)))
        let reply = try await source.draft(replyID)
        XCTAssertTrue(reply.plainText.hasPrefix("Reply\n\n" + MailText.readable(signature) + "\n\n"))
        XCTAssertTrue(reply.html?.contains(signature) == true)

        _ = try await tools.writeDraft(["draftId": replyID.uuidString, "body": "Revised"])
        let revised = try await source.draft(replyID)
        XCTAssertTrue(revised.plainText.hasPrefix("Revised\n\n" + MailText.readable(signature) + "\n\n"))
        XCTAssertEqual(revised.html?.components(separatedBy: signature).count, 2)
        XCTAssertEqual(revised.replyContext, reply.replyContext)
    }
    func testAccountsPagingScopesSearchAndRead() async throws {
        let source = FixtureMailPageDataSource()
        let tools = MailAgentTools(source: source, timeZone: TimeZone(secondsFromGMT: -18000)!)
        let state = try await source.snapshot()
        let accounts = try await tools.accounts()
        let listed = try XCTUnwrap(accounts["accounts"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 2)
        let boxes = try XCTUnwrap(listed[0]["mailboxes"] as? [[String: Any]])
        XCTAssertFalse(boxes.contains { ($0["name"] as? String) == "[Gmail]" })
        XCTAssertEqual((accounts["allMailboxes"] as? [[String: Any]])?.count, MailboxTreeNode.build(state).filter { $0.unifiedRole != nil }.count)
        let first = try await tools.list(mailbox: nil, account: "johnny@example.com", before: nil, limit: 2)
        let messages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        let next = try XCTUnwrap((first["next"] as? String).flatMap(UUID.init(uuidString:)))
        let second = try await tools.list(mailbox: "inbox", account: "personal", before: next, limit: 2)
        XCTAssertNotEqual((second["messages"] as? [[String: Any]])?.first?["id"] as? String, messages.first?["id"] as? String)
        let all = try XCTUnwrap(state.mailboxes.first { $0.role == .all })
        _ = try await tools.list(mailbox: all.id.uuidString, account: nil, before: nil, limit: 2)
        XCTAssertEqual(source.openCalls, [all.id])
        do { _ = try await tools.list(mailbox: "missing", account: nil, before: nil, limit: 2); XCTFail("Expected error") }
        catch { XCTAssertTrue(MailAgentTools.errorMessage(error).contains("list_mail_accounts")) }
        _ = try await tools.search(query: "Reading", mailbox: nil, account: nil, server: true, limit: 5)
        XCTAssertTrue(source.serverSearches.contains(all.id))
        XCTAssertTrue(source.serverSearches.contains { id in state.mailboxes.contains { $0.id == id && $0.accountID == state.accounts[1].id && $0.role == .inbox } })
        let page = try await tools.list(mailbox: nil, account: nil, before: nil, limit: 1)
        let id = try XCTUnwrap(((page["messages"] as? [[String: Any]])?.first?["id"] as? String).flatMap(UUID.init(uuidString:)))
        let detail = try await tools.read(id: id, maxChars: 20000)
        XCTAssertTrue((detail["body"] as? String)?.contains("Reading group") == true)
        XCTAssertNotNil((detail["attachments"] as? [[String: Any]])?.first?["path"])
        do { _ = try await tools.read(id: UUID(), maxChars: 20000); XCTFail("Expected error") }
        catch { XCTAssertTrue(MailAgentTools.errorMessage(error).contains("gone")) }
    }

    func testSearchAndReadPlainTextWithinAccount() async throws {
        let source = FixtureMailPageDataSource(), tools = MailAgentTools(source: source, timeZone: TimeZone(secondsFromGMT: -18000)!)
        let state = try await source.snapshot()
        let result = try await tools.search(query: "Reading group", mailbox: "inbox", account: "UofT CS", server: true, limit: 5)
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.allSatisfy { $0["account"] as? String == "UofT CS" })
        let inbox = try XCTUnwrap(state.mailboxes.first { $0.accountID == state.accounts[1].id && $0.role == .inbox })
        XCTAssertEqual(source.serverSearches, [inbox.id])
        let id = try XCTUnwrap((messages[0]["id"] as? String).flatMap(UUID.init(uuidString:)))
        let detail = try await tools.read(id: id, maxChars: 20000)
        XCTAssertTrue((detail["body"] as? String)?.contains("Hello Johnny") == true)
        XCTAssertTrue((detail["date"] as? String)?.hasSuffix("-05:00") == true)
    }
}
