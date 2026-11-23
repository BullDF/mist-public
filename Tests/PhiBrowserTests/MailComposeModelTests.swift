import XCTest
import MistMailCore
@testable import Phi

@MainActor
final class MailComposeModelTests: XCTestCase {
    private func page(_ source: FixtureMailPageDataSource, defaults: UserDefaults? = nil) async -> MailPageModel {
        let model = MailPageModel(source: source, defaults: defaults ?? makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages(); return model
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for compose state")
    }
    func testFromFollowsMailboxThenSelectionThenFirstAccount() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        await model.newMessage(); XCTAssertEqual(model.compose?.draft.accountID, model.state.accounts[0].id)
        await model.closeCompose()
        let second = try XCTUnwrap(model.messages.first { $0.accountID == model.state.accounts[1].id })
        model.selectMessage(second.id); await model.newMessage()
        XCTAssertEqual(model.compose?.draft.accountID, second.accountID); await model.closeCompose()
        let box = try XCTUnwrap(model.state.mailboxes.first { $0.accountID == model.state.accounts[1].id })
        model.selectMailbox(box.id.uuidString); await model.newMessage()
        XCTAssertEqual(model.compose?.draft.accountID, box.accountID)
        await model.closeCompose()
    }
    func testAutosaveDebounceAndSerializedChangesDuringSave() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        compose.update { $0.subject = "Autosaved" }
        XCTAssertTrue(compose.hasUnsavedChanges)
        try await waitFor { source.draftValues[compose.draft.id]?.subject == "Autosaved" }
        XCTAssertFalse(compose.hasUnsavedChanges)
        source.saveDelay = .milliseconds(100)
        compose.update { $0.subject = "First save" }
        let first = Task { try await compose.saveNow() }
        try await waitFor { source.activeSaves == 1 }
        compose.update { $0.subject = "Edited during save" }
        let second = Task { try await compose.saveNow() }
        try await first.value; try await second.value
        XCTAssertEqual(source.draftValues[compose.draft.id]?.subject, "Edited during save")
        XCTAssertEqual(source.maximumConcurrentSaves, 1)
        XCTAssertFalse(compose.hasUnsavedChanges)
        await model.closeCompose()
    }
    func testReplyReplyAllForwardAndUntouchedClose() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        let message = try XCTUnwrap(model.messages.first)
        await model.reply(to: message)
        let reply = try XCTUnwrap(model.compose)
        XCTAssertEqual(reply.draft.accountID, message.accountID); XCTAssertEqual(reply.draft.to, message.sender)
        XCTAssertTrue(reply.draft.subject.hasPrefix("Re: ")); XCTAssertTrue(reply.draft.html!.contains("<blockquote type=\"cite\">"))
        let detail = try await source.detail(message.id)
        let intro = String(format: MailStrings.quoteIntro, DateFormatter.localizedString(from: detail.headers.date, dateStyle: .medium, timeStyle: .short), MailPresentation.addresses(detail.headers.from))
        XCTAssertTrue(reply.draft.html!.contains(MailComposeFormatting.escape(intro)))
        XCTAssertEqual(reply.initialFocus, .body)
        await model.closeCompose(); XCTAssertNil(source.draftValues[reply.draft.id])
        await model.reply(to: message, all: true); XCTAssertEqual(model.compose?.draft.replyContext?.kind, .replyAll)
        await model.forward(message)
        let forward = try XCTUnwrap(model.compose)
        XCTAssertTrue(forward.draft.to.isEmpty); XCTAssertTrue(forward.draft.subject.hasPrefix("Fwd: "))
        XCTAssertEqual(forward.initialFocus, .recipients)
        await model.closeCompose(); XCTAssertNil(source.draftValues[forward.draft.id])
    }
    func testSendValidatesAllRecipientsThenClosesAndClearsDefaults() async throws {
        let source = FixtureMailPageDataSource(), defaults = makeTestDefaults().defaults, model = await page(source, defaults: defaults)
        await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        do { try await compose.send(); XCTFail("Missing recipient accepted") }
        catch { XCTAssertEqual(error as? MailComposeModel.ComposeError, .noRecipients) }
        XCTAssertNotNil(model.compose)
        compose.update { $0.to = [.init("ok@example.com")]; $0.bcc = [.init("invalid")] }
        do { try await compose.send(); XCTFail("Invalid Bcc accepted") }
        catch { XCTAssertEqual(error as? MailComposeModel.ComposeError, .invalidRecipient) }
        compose.update { $0.bcc = []; $0.subject = "Sent" }
        try await compose.send()
        XCTAssertEqual(source.sent.last?.subject, "Sent"); XCTAssertNil(model.compose)
        XCTAssertNil(defaults.string(forKey: "mist.mail.openDraft")); XCTAssertNil(source.draftValues[compose.draft.id])
    }
    func testDiscardAndUntouchedNewDraft() async throws {
        let source = FixtureMailPageDataSource(), defaults = makeTestDefaults().defaults, model = await page(source, defaults: defaults)
        await model.newMessage(); let untouched = try XCTUnwrap(model.compose?.draft.id)
        await model.closeCompose(); XCTAssertNil(source.draftValues[untouched]); XCTAssertNil(defaults.string(forKey: "mist.mail.openDraft"))
        await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        compose.update { $0.subject = "Delete this" }; try await compose.discard()
        XCTAssertNil(source.draftValues[compose.draft.id]); XCTAssertNil(model.compose)
    }
    func testNewMessageReplyAndForwardUseAccountSignature() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        let account = model.state.accounts[0]
        let signature = try XCTUnwrap(account.config.signatureHTML)
        await model.newMessage()
        let fresh = try XCTUnwrap(model.compose)
        XCTAssertTrue(fresh.draft.html?.contains(signature) == true)
        XCTAssertEqual(fresh.draft.plainText, MailText.readable(signature))
        XCTAssertFalse(fresh.hasContent)
        // A recipient added and then removed still leaves a signature-only draft.
        fresh.update { $0.to = [.init("recipient@example.com")] }
        fresh.update { $0.to = [] }
        await model.closeCompose()
        XCTAssertNil(source.draftValues[fresh.draft.id])

        let original = try XCTUnwrap(model.messages.first { $0.accountID == account.id })
        await model.reply(to: original)
        let reply = try XCTUnwrap(model.compose?.draft)
        XCTAssertTrue(reply.html?.contains("\(signature)</div><div><br></div>") == true)
        XCTAssertTrue(reply.plainText.hasPrefix(MailText.readable(signature) + "\n\n"))
        await model.forward(original)
        let forward = try XCTUnwrap(model.compose?.draft)
        XCTAssertTrue(forward.html?.contains("\(signature)</div><div><br></div>") == true)
        XCTAssertTrue(forward.plainText.hasPrefix(MailText.readable(signature) + "\n\n"))
        await model.closeCompose()
    }
    func testSelectingAnotherMessageSavesAndMailboxChangeKeepsCompose() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        let first = model.messages[0], second = model.messages[1]
        model.selectMessage(first.id); await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        compose.update { $0.subject = "Keep me" }
        model.selectMessage(second.id); try await waitFor { model.compose == nil }
        XCTAssertEqual(model.selection, second.id); XCTAssertEqual(source.draftValues[compose.draft.id]?.subject, "Keep me")
        await model.newMessage(); let id = model.compose?.draft.id
        model.selectMailbox(model.state.mailboxes[0].id.uuidString)
        XCTAssertEqual(model.compose?.draft.id, id); await model.closeCompose()
    }
    func testEmptiedDraftIsDeletedOnClose() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        let first = model.messages[0], second = model.messages[1]
        model.selectMessage(first.id); await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        compose.update { $0.subject = "Typed" }; try await compose.saveNow()
        compose.update { $0.subject = "" }
        model.selectMessage(second.id); try await waitFor { model.compose == nil }
        XCTAssertNil(source.draftValues[compose.draft.id])
        let box = try XCTUnwrap(model.state.mailboxes.first { $0.role == .drafts })
        model.selectMailbox(box.id.uuidString); await model.reloadMessages()
        let saved = try XCTUnwrap(model.messages.first)
        model.selectMessage(saved.id); try await waitFor { model.compose != nil }
        let existing = try XCTUnwrap(model.compose)
        existing.exportEditor = { .init(html: "<div><br></div>", plainText: "") }
        existing.update { $0.to = []; $0.subject = "" }
        await model.closeCompose()
        XCTAssertNil(source.draftValues[existing.draft.id]); XCTAssertNil(model.compose)
        await model.reloadMessages(); XCTAssertFalse(model.messages.contains { $0.id == saved.id })
    }
    func testSelectingDraftsMessageEditsAndReopensAfterClose() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        let box = try XCTUnwrap(model.state.mailboxes.first { $0.role == .drafts })
        model.selectMailbox(box.id.uuidString); await model.reloadMessages()
        let message = try XCTUnwrap(model.messages.first)
        model.selectMessage(message.id); try await waitFor { model.compose != nil }
        let draftID = model.compose!.draft.id
        XCTAssertEqual(model.compose?.draft.subject, message.subject)
        await model.closeCompose(); XCTAssertNotNil(source.draftValues[draftID]); XCTAssertNil(model.selection)
        model.selectMessage(message.id); try await waitFor { model.compose != nil }
        XCTAssertEqual(model.compose?.draft.id, draftID); await model.closeCompose()
    }
    func testRestoresOpenDraftAndClearsMissingDraftKey() async throws {
        let source = FixtureMailPageDataSource(), defaults = makeTestDefaults().defaults, model = await page(source, defaults: defaults)
        await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        compose.update { $0.subject = "Survives relaunch" }; try await compose.saveNow()
        let restored = MailPageModel(source: source, defaults: defaults); restored.start()
        try await waitFor { restored.compose != nil }
        XCTAssertEqual(restored.compose?.draft.id, compose.draft.id); XCTAssertEqual(restored.compose?.draft.subject, "Survives relaunch")
        await restored.closeCompose()
        defaults.set(UUID().uuidString, forKey: "mist.mail.openDraft")
        let missing = MailPageModel(source: source, defaults: defaults); missing.start()
        try await waitFor { defaults.string(forKey: "mist.mail.openDraft") == nil }
        XCTAssertNil(missing.compose)
        await model.closeCompose()
    }
    func testSavePrunesUnusedInlinePartsAndKeepsRegularAttachments() async throws {
        let source = FixtureMailPageDataSource(), model = await page(source)
        await model.newMessage(); let compose = try XCTUnwrap(model.compose)
        let first = try compose.addInlineImage(Data([1])), second = try compose.addInlineImage(Data([2]))
        compose.update { $0.attachments.append(.init(filename: "regular", file: URL(fileURLWithPath: "/unused"))) }
        compose.exportEditor = { .init(html: "<img src=\"cid:\(first)\">", plainText: "") }
        try await compose.saveNow()
        XCTAssertEqual(compose.draft.attachments.count, 2)
        XCTAssertFalse(compose.draft.attachments.contains { $0.contentID == second })
        XCTAssertTrue(compose.draft.attachments.contains { $0.contentID == nil })
        try await compose.discard()
    }
}
