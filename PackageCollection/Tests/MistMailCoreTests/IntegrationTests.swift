import XCTest
@testable import MistMailCore

final class IntegrationTests: XCTestCase {
    /// A reconnect that lands while IDLE is being set up used to leave that logged-in connection open for good.
    func testDisconnectDuringIdleSetupLeavesNoConnection() async throws {
        guard let imap = ProcessInfo.processInfo.environment["MIST_MAIL_IMAP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("GreenMail integration requires Docker; run build-scripts/test-mist-mail.sh")
        }
        let config = MailAccountConfig(displayName: "GreenMail", senderName: "Test", email: "mail@example.test", username: "mail",
                                       imap: .init(host: "127.0.0.1", port: imap, security: .plaintext), smtp: .init(host: "127.0.0.1", port: 1, security: .plaintext))
        let before = try openConnections(port: imap)
        for attempt in 0..<30 {
            let transport = SwiftMailTransport(config: config, password: "secret")
            _ = try await transport.connect()
            let idle = Task { try await transport.idle(in: "INBOX", renewalInterval: 600) }
            // Every third disconnect comes once IDLE is up, the rest at points during its setup.
            if attempt.isMultiple(of: 3) { _ = try? await idle.value } else { try await Task.sleep(nanoseconds: UInt64(attempt % 15) * 1_000_000) }
            await transport.disconnect()
            _ = try? await idle.value
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try openConnections(port: imap)
        XCTAssertEqual(after, before, "IMAP connections left open")
    }
    private func openConnections(port: Int) throws -> Int {
        let lsof = Process(), pipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:\(port)", "-sTCP:ESTABLISHED"]
        lsof.standardOutput = pipe; lsof.standardError = FileHandle.nullDevice
        try lsof.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().count
    }
    func testGreenMailEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let imap = env["MIST_MAIL_IMAP_PORT"].flatMap(Int.init), let smtp = env["MIST_MAIL_SMTP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("GreenMail integration requires Docker; run build-scripts/test-mist-mail.sh")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-greenmail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let config = MailAccountConfig(displayName: "GreenMail", senderName: "Test", email: "mail@example.test", username: "mail",
                                       imap: .init(host: "127.0.0.1", port: imap, security: .plaintext), smtp: .init(host: "127.0.0.1", port: smtp, security: .plaintext))
        let setup = SwiftMailTransport(config: config, password: "secret")
        let capabilities = try await setup.connect()
        print("GreenMail capabilities: \(capabilities.sorted().joined(separator: ", "))")
        for name in ["Sent", "Drafts", "Trash", "Projects"] { try await setup.createMailbox(name) }
        let seed = MailDraft(accountID: UUID(), to: [.init("mail@example.test")], subject: "Initial GreenMail message", plainText: "Integration fixture")
        let seedBytes = try MailMIME.serialize(seed, account: .init(config: config), includeBcc: false)
        let seedUID = try await setup.append(seedBytes, to: "INBOX", flags: [])
        XCTAssertNotNil(seedUID)
        let engine = try MailEngine(baseDirectory: base, credentialStore: InMemoryMailCredentialStore())
        let isGmail = try await engine.testAccount(config, password: "secret"); XCTAssertFalse(isGmail)
        do { _ = try await engine.testAccount(config, password: "wrong"); XCTFail("Bad credentials accepted") }
        catch { XCTAssertEqual(error as? MailError, .authenticationFailed) }
        let account = try await engine.addAccount(config, password: "secret")
        try await engine.refresh(accountID: account.id)
        var inbox = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(inbox.count, 1)
        let detail = try await engine.messageDetail(inbox[0].id)
        XCTAssertEqual(detail.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Integration fixture")
        let initialFlags = try await setup.flags(seedUID!...seedUID!, in: "INBOX")
        XCTAssertFalse(initialFlags[seedUID!]!.contains(MailFlags.seen), "BODY.PEEK must preserve unread state")
        // Add a second message externally; UID-only incremental discovery must find it.
        var incremental = seed; incremental = MailDraft(accountID: account.id, to: seed.to, subject: "Incremental message", plainText: "Incremental fixture")
        _ = try await setup.append(MailMIME.serialize(incremental, account: account, includeBcc: false), to: "INBOX", flags: [])
        try await engine.refresh(accountID: account.id)
        let incrementalRows = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(incrementalRows.count, 2)
        let incrementalRow = incrementalRows.first { $0.subject == "Incremental message" }!
        try await setup.delete([incrementalRow.uid], in: "INBOX")
        try await engine.refresh(accountID: account.id)
        try await engine.setSeen(inbox[0].id, true); try await engine.flushPending(accountID: account.id)
        try await engine.setFlagged(inbox[0].id, true); try await engine.flushPending(accountID: account.id)
        let seenFlags = try await setup.flags(seedUID!...seedUID!, in: "INBOX")
        XCTAssertTrue(seenFlags[seedUID!]!.contains(MailFlags.seen)); XCTAssertTrue(seenFlags[seedUID!]!.contains(MailFlags.flagged))
        let projects = try await engine.mailboxes().first { $0.name == "Projects" }!
        try await engine.move(inbox[0].id, to: projects.id); try await engine.flushPending(accountID: account.id)
        try await engine.open(projects.id)
        var projectMessages = try await engine.messages(in: .mailbox(projects.id))
        XCTAssertEqual(projectMessages.count, 1)
        try await engine.archive(projectMessages[0].id); try await engine.flushPending(accountID: account.id)
        let archive = try await engine.mailboxes().first { $0.role == .archive }!
        try await engine.open(archive.id)
        let archived = try await engine.messages(in: .mailbox(archive.id))
        XCTAssertEqual(archived.count, 1)
        let trashOperation = try await engine.delete(archived[0].id)
        try await engine.flushPending(accountID: account.id)
        let trash = try await engine.mailboxes().first { $0.role == .trash }!
        let undo = try await engine.undo(trashOperation)
        let restored = try await engine.messages(in: .mailbox(archive.id))
        let serverArchive = try await setup.search(.all, in: "Archive")
        let serverTrash = try await setup.search(.all, in: "Trash")
        XCTAssertEqual(restored.map(\.id), undo.messageIDs)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(serverArchive.count, 1)
        XCTAssertTrue(serverTrash.isEmpty)
        try await engine.delete(restored[0].id); try await engine.flushPending(accountID: account.id)
        try await engine.open(trash.id)
        let trashed = try await engine.messages(in: .mailbox(trash.id))
        XCTAssertEqual(trashed.count, 1)
        try await engine.delete(trashed[0].id); try await engine.flushPending(accountID: account.id)
        let deleted = try await setup.search(.all, in: "Trash"); XCTAssertTrue(deleted.isEmpty)
        var draft = MailDraft(accountID: account.id, to: [.init("mail@example.test")], subject: "Draft first", plainText: "Draft fixture")
        draft = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        let first = try await engine.draft(draft.id)
        draft.subject = "Draft replacement"; draft = try await engine.saveDraft(draft); try await engine.flushDraft(draft.id)
        let replacement = try await engine.draft(draft.id)
        XCTAssertNotEqual(first.serverUID, replacement.serverUID)
        let serverDrafts = try await setup.search(.all, in: "Drafts"); XCTAssertEqual(serverDrafts.count, 1)
        try await engine.start(); try await engine.refresh(accountID: account.id)
        let events = await engine.events(), delivered = expectation(description: "SMTP delivery arrives through IDLE")
        let reader = Task {
            for await event in events {
                if case .newMessages(let summaries) = event, summaries.contains(where: { $0.subject == "Draft replacement" }) { delivered.fulfill(); break }
            }
        }
        print("GreenMail: sending with IDLE active")
        do { try await engine.send(draft.id) }
        catch { print("GreenMail: send failed with \(error)"); delivered.fulfill(); await fulfillment(of: [delivered], timeout: 1); reader.cancel(); await engine.stop(); await setup.disconnect(); throw error }
        print("GreenMail: SMTP accepted and Sent copy filed")
        await fulfillment(of: [delivered], timeout: 8)
        reader.cancel()
        inbox = try await engine.messages(in: .unifiedInbox)
        XCTAssertEqual(inbox.map(\.subject), ["Draft replacement"])
        let sentUIDs = try await setup.search(.all, in: "Sent")
        XCTAssertEqual(sentUIDs.count, 1)
        let sentInfo = try await setup.fetch(sentUIDs, in: "Sent", gmail: false)
        XCTAssertEqual(sentInfo[0].subject, "Draft replacement")
        let remainingDrafts = try await setup.search(.all, in: "Drafts"); XCTAssertTrue(remainingDrafts.isEmpty)
        // Incremental FLAGS and disappearance after an external change.
        let inboxUIDs = try await setup.search(.all, in: "INBOX")
        try await setup.setFlag(MailFlags.seen, value: true, uids: inboxUIDs, in: "INBOX")
        try await engine.refresh(accountID: account.id)
        inbox = try await engine.messages(in: .unifiedInbox); XCTAssertTrue(inbox[0].flags.contains(MailFlags.seen))
        try await setup.delete(inboxUIDs, in: "INBOX"); try await engine.refresh(accountID: account.id)
        projectMessages = try await engine.messages(in: .unifiedInbox); XCTAssertTrue(projectMessages.isEmpty)
        await engine.stop(); await setup.disconnect()
    }
}
