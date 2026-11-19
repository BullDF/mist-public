import XCTest
@testable import MistMailCore

final class DraftTests: XCTestCase {
    func testSameTimestampEditsStillReplaceServerDraft() async throws {
        let fixture = EngineFixture(), server = fixture.server, time = Date()
        let engine = try MailEngine(baseDirectory: fixture.base, credentialStore: fixture.credentials, transportFactory: { _, _ in server }, now: { time })
        let account = try await engine.addAccount(testConfig(), password: "test")
        var draft = MailDraft(accountID: account.id, subject: "First")
        draft = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        draft.subject = "Second"; _ = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        let copies = await server.appended
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(try MailMIME.decode(copies.last!.1).0.subject, "Second")
        await engine.stop()
    }
    func testFlushedDraftShowsInAnOpenedDraftsMailbox() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, subject: "Older draft"), in: "Drafts")
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let drafts = try await engine.mailboxes().first { $0.role == .drafts }!
        try await engine.open(drafts.id)
        let draft = try await engine.saveDraft(MailDraft(accountID: account.id, subject: "New draft"))
        try await engine.flushDraft(draft.id)
        let listed = try await engine.messages(in: .mailbox(drafts.id))
        XCTAssertEqual(listed.count, 2)
        await engine.stop()
    }
    func testDiscardDoesNotDeleteReusedUIDAfterValidityChanges() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let draft = MailDraft(accountID: account.id, plainText: "Draft")
        _ = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        await fixture.server.reset("Drafts")
        await fixture.server.put(.init(uid: 1, subject: "Unrelated"), in: "Drafts")
        try await engine.discardDraft(draft.id)
        let server = await fixture.server.boxes["Drafts"]!
        XCTAssertEqual(server.map(\.subject), ["Unrelated"])
        await engine.stop()
    }
    func testDirtyDraftResumesAfterRelaunchAndUnchangedFlushIsCheap() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        await engine.stop()
        let draft = MailDraft(accountID: account.id, to: [.init("to@example.com")], plainText: "Unsynced", updatedAt: Date().addingTimeInterval(-60))
        do { let store = try MailStore(base: fixture.base); try store.save(draft) }
        let restoredEngine = try fixture.engine()
        try await restoredEngine.start()
        var uploaded: MailDraft?
        for _ in 0..<50 {
            let current = try await restoredEngine.draft(draft.id)
            if current.serverUID != nil { uploaded = current; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(uploaded)
        let count = await fixture.server.appended.count
        try await restoredEngine.flushDraft(draft.id)
        let after = await fixture.server.appended.count
        XCTAssertEqual(after, count)
        await restoredEngine.stop()
    }
    func testDraftRelaunchReplacementBccAndDiscard() async throws {
        let fixture = EngineFixture()
        var engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let attachment = fixture.base.appendingPathComponent("input.txt")
        try Data("File content".utf8).write(to: attachment)
        var draft = MailDraft(accountID: account.id, to: [.init("to@example.com")], bcc: [.init("secret@example.com")],
                              subject: "Draft", plainText: "Persist me", attachments: [.init(filename: "input.txt", file: attachment)])
        draft = try await engine.saveDraft(draft)
        XCTAssertNotEqual(draft.attachments[0].file, attachment)
        try FileManager.default.removeItem(at: attachment)
        await engine.stop(); engine = try fixture.engine()
        var restored = try await engine.draft(draft.id)
        XCTAssertEqual(restored.plainText, "Persist me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.attachments[0].file.path))
        try await engine.flushDraft(draft.id)
        restored = try await engine.draft(draft.id)
        let firstUID = restored.serverUID
        restored.subject = "Updated"; _ = try await engine.saveDraft(restored)
        try await engine.flushDraft(draft.id)
        restored = try await engine.draft(draft.id)
        XCTAssertNotEqual(restored.serverUID, firstUID)
        let serverDrafts = await fixture.server.boxes["Drafts"]!
        XCTAssertEqual(serverDrafts.count, 1)
        let bytes = await fixture.server.appended.last!.1
        let decoded = try MailMIME.decode(bytes)
        XCTAssertEqual(decoded.0.bcc.map(\.email), ["secret@example.com"])
        XCTAssertEqual(decoded.0.subject, "Updated")
        try await engine.discardDraft(draft.id)
        let local = try await engine.drafts(), remote = await fixture.server.boxes["Drafts"]!
        XCTAssertTrue(local.isEmpty); XCTAssertTrue(remote.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.attachments[0].file.path))
        await engine.stop()
    }
    func testQuotedDocumentKeepsItsStylesAndBodyOnly() {
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>p{margin:0}</style><title>T</title></head><BODY style=\"font-family:Calibri\"><p>Hi</p></body></html>"
        XCTAssertEqual(MailEngine.quotableHTML(html), "<style>p{margin:0}</style><div style=\"font-family:Calibri\"><p>Hi</p></div>")
        XCTAssertEqual(MailEngine.quotableHTML("<html><body bgcolor=white>\n<p>Hi</p>\n</body></html>"), "\n<p>Hi</p>\n")
        XCTAssertEqual(MailEngine.quotableHTML("<div dir=\"ltr\">Hi</div>"), "<div dir=\"ltr\">Hi</div>")
    }
    func testReplyForwardRecipientsQuotingAndThreadHeaders() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.put(.init(uid: 1, from: [.init("author@example.com", name: "Author")],
                                      to: [.init("ME@example.com"), .init("friend@example.com")], cc: [.init("friend@example.com"), .init("other@example.com")],
                                      replyTo: [.init("reply@example.com")], subject: "Re: Re: Topic", messageID: "<parent@example.com>", references: ["<root@example.com>"],
                                      parts: [.init(section: "2", mimeType: "application/pdf", filename: "report.pdf", isAttachment: true)]),
                                 body: .init(plainText: "One\nTwo", html: "<p>One</p><p>Two</p>"))
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let source = try await engine.messages(in: .unifiedInbox).first!
        let unsaved = try await engine.replyDraft(to: source.id, all: true)
        let beforeSave = try await engine.drafts()
        XCTAssertFalse(beforeSave.contains { $0.id == unsaved.id })
        let reply = try await engine.makeReply(to: source.id, all: true, quoteIntro: "Le %1$@, %2$@ a écrit :")
        let intro = String(format: "Le %1$@, %2$@ a écrit :", DateFormatter.localizedString(from: source.date, dateStyle: .medium, timeStyle: .short), "Author")
        XCTAssertTrue(reply.plainText.contains(intro)); XCTAssertTrue(reply.html!.contains(intro))
        XCTAssertEqual(reply.to.map(\.email), ["reply@example.com", "friend@example.com"])
        XCTAssertEqual(reply.cc.map(\.email), ["other@example.com"])
        XCTAssertEqual(reply.subject, "Re: Topic")
        XCTAssertTrue(reply.plainText.contains("> One\n> Two")); XCTAssertTrue(reply.html!.contains("<blockquote type=\"cite\">"))
        XCTAssertTrue(reply.html!.hasPrefix("<div><br></div>"))
        let savedReply = try await engine.draft(reply.id)
        XCTAssertEqual(savedReply, reply)
        XCTAssertEqual(reply.replyContext?.references, ["<root@example.com>", "<parent@example.com>"])
        let forwarded = try await engine.makeForward(source.id)
        XCTAssertEqual(forwarded.subject, "Fwd: Topic")
        XCTAssertTrue(forwarded.plainText.contains("> One\n> Two"))
        XCTAssertEqual(forwarded.attachments.count, 1)
        XCTAssertTrue(forwarded.attachments[0].file.path.contains("DraftAttachments"))
        _ = try await engine.saveDraft(reply); try await engine.send(reply.id)
        let sourceAfter = try await engine.messages(in: .unifiedInbox).first!
        XCTAssertTrue(sourceAfter.flags.contains(MailFlags.answered))
        let bytes = await fixture.server.sent.last!
        let parsed = try MailMIME.decode(bytes)
        XCTAssertEqual(parsed.0.inReplyTo, "<parent@example.com>")
        XCTAssertEqual(parsed.0.references, ["<root@example.com>", "<parent@example.com>"])
        await engine.stop()
    }
    func testSendExactSentCopyEnvelopeBccAndOfflineFailure() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        let draft = MailDraft(accountID: account.id, to: [.init("to@example.com")], cc: [.init("cc@example.com")], bcc: [.init("secret@example.com")],
                              subject: "中文 café", plainText: "Hello", html: "<p>Hello</p>")
        _ = try await engine.saveDraft(draft)
        await engine.networkBecameUnavailable()
        do { try await engine.send(draft.id); XCTFail() } catch { XCTAssertEqual(error as? MailError, .offline) }
        let retained = try await engine.draft(draft.id)
        XCTAssertEqual(retained.lastSendError, "offline")
        await engine.networkBecameAvailable(); try await engine.send(draft.id)
        let bytes = await fixture.server.sent.last!, sentCopy = await fixture.server.appended.last!
        XCTAssertEqual(sentCopy.0, "Sent"); XCTAssertEqual(bytes, sentCopy.1)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Bcc:"))
        let envelope = await fixture.server.envelopes.last!
        XCTAssertEqual(Set(envelope.map(\.email)), ["to@example.com", "cc@example.com", "secret@example.com"])
        let decoded = try MailMIME.decode(bytes)
        XCTAssertEqual(decoded.0.subject, "中文 café"); XCTAssertEqual(decoded.1.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello")
        let drafts = try await engine.drafts(); XCTAssertTrue(drafts.isEmpty)
        await engine.stop()
    }
    func testSendSyncsSentCopyWithoutRefresh() async throws {
        for gmail in [false, true] {
            let fixture = EngineFixture(), engine = try fixture.engine()
            if gmail { await fixture.server.setGmail() }
            let account = try await engine.addAccount(testConfig(), password: "test")
            try await engine.refresh(accountID: account.id)
            let sent = try await engine.mailboxes(accountID: account.id).first { $0.role == .sent }!
            let draft = MailDraft(accountID: account.id, to: [.init("a@example.com")], plainText: "Hello")
            _ = try await engine.saveDraft(draft); try await engine.send(draft.id)
            var listed = try await engine.messages(in: .mailbox(sent.id))
            for _ in 0..<200 where listed.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000); listed = try await engine.messages(in: .mailbox(sent.id))
            }
            XCTAssertEqual(listed.count, 1, gmail ? "Gmail" : "IMAP")
            await engine.stop()
        }
    }
    func testEmptyDraftNeverReachesServerAndEmptiedOneLeavesIt() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let account = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh(accountID: account.id)
        var draft = try await engine.saveDraft(MailDraft(accountID: account.id, subject: " ", html: "<div><br></div>"))
        try await engine.flushDraft(draft.id)
        var appended = await fixture.server.appended
        XCTAssertTrue(appended.isEmpty)
        draft.subject = "Keep"; draft = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        appended = await fixture.server.appended
        XCTAssertEqual(appended.count, 1)
        draft.subject = ""; draft = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        appended = await fixture.server.appended
        XCTAssertEqual(appended.count, 1)
        let server = await fixture.server.boxes["Drafts"]!
        XCTAssertTrue(server.isEmpty)
        let local = try await engine.draft(draft.id)
        XCTAssertNil(local.serverUID)
        await engine.stop()
    }
    func testGmailDoesNotAppendSent() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        await fixture.server.setGmail()
        let account = try await engine.addAccount(testConfig(), password: "test")
        let draft = MailDraft(accountID: account.id, to: [.init("a@example.com")], plainText: "Hello")
        _ = try await engine.saveDraft(draft); try await engine.send(draft.id)
        let copies = await fixture.server.appended
        XCTAssertTrue(copies.isEmpty)
        await engine.stop()
    }
    func testQuotedInlinePartsAndRegularForwardAttachments() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let parts: [MailPart] = [
            .init(section: "2", mimeType: "image/png", filename: "inline.png", contentID: "<image@mist>"),
            .init(section: "3", mimeType: "application/pdf", filename: "report.pdf", contentID: "unused", isAttachment: true),
            .init(section: "4", mimeType: "image/png", contentID: "unused-inline")]
        await fixture.server.put(.init(uid: 1, from: [.init("a@example.com")], parts: parts), body: .init(html: "<img src=\"cid:image%40mist\">"))
        _ = try await engine.addAccount(testConfig(), password: "test")
        try await engine.refresh()
        let source = try await engine.messages(in: .unifiedInbox).first!
        let reply = try await engine.makeReply(to: source.id)
        XCTAssertEqual(reply.attachments.map(\.contentID), ["image@mist"])
        let forward = try await engine.makeForward(source.id)
        XCTAssertEqual(forward.attachments.count, 2)
        XCTAssertNil(forward.attachments.first { $0.filename == "report.pdf" }?.contentID)
        let edited = try await engine.editDraft(fromMessage: source.id)
        XCTAssertEqual(edited.attachments.count, 2)
        XCTAssertEqual(edited.attachments.first { $0.filename == "inline.png" }?.contentID, "image@mist")
        XCTAssertNil(edited.attachments.first { $0.filename == "report.pdf" }?.contentID)
        await engine.stop()
    }
    func testSavedDraftChangesAccountCascade() throws {
        let fixture = EngineFixture(), store = try MailStore(base: fixture.base)
        let first = MailAccount(config: testConfig()), second = MailAccount(config: testConfig())
        try store.save(first); try store.save(second)
        var draft = MailDraft(accountID: first.id, subject: "Moved")
        try store.save(draft); draft.accountID = second.id; try store.save(draft)
        try store.deleteAccount(first.id)
        XCTAssertEqual(try store.draft(draft.id).accountID, second.id)
        try store.deleteAccount(second.id)
        XCTAssertTrue(try store.drafts().isEmpty)
    }
    func testChangingFromClearsOldServerDraftIdentity() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let first = try await engine.addAccount(testConfig(), password: "test")
        var config = testConfig(); config.email = "second@example.com"; config.username = "second"
        let second = try await engine.addAccount(config, password: "test")
        var draft = try await engine.saveDraft(MailDraft(accountID: first.id, subject: "Move me"))
        try await engine.flushDraft(draft.id)
        draft = try await engine.draft(draft.id); XCTAssertNotNil(draft.serverUID)
        draft.accountID = second.id; draft = try await engine.saveDraft(draft)
        XCTAssertNil(draft.serverUID); XCTAssertNil(draft.serverMailboxID); XCTAssertNil(draft.serverRevision)
        try await engine.flushDraft(draft.id)
        let moved = try await engine.draft(draft.id), boxes = try await engine.mailboxes(accountID: second.id)
        XCTAssertEqual(moved.serverMailboxID, boxes.first { $0.role == .drafts }?.id)
        await engine.stop()
    }
}
