import XCTest
@testable import MistMailCore

final class LiveMailTests: XCTestCase {
    func testGmailUndoArchiveAndTrash() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIST_LIVE_MAIL"] == "1", env["MIST_LIVE_MAIL_UNDO"] == "1",
              env["MIST_LIVE_MAIL_PRESET"]?.lowercased() == "gmail",
              let user = env["MIST_LIVE_MAIL_USER"], !user.isEmpty,
              let password = env["MIST_LIVE_MAIL_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Gmail undo requires live Gmail credentials and MIST_LIVE_MAIL_UNDO=1")
        }
        let email = user.contains("@") ? user : user + "@gmail.com"
        let preset = MailAccountPreset.gmail
        let config = MailAccountConfig(displayName: "Live mail undo probe", senderName: "Mail probe", email: email,
                                       username: user, imap: preset.imap!, smtp: preset.smtp!)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-live-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = try MailEngine(baseDirectory: base, credentialStore: InMemoryMailCredentialStore())
        do {
            let account = try await engine.addAccount(config, password: password)
            try await engine.refreshMailboxes(accountID: account.id)
            let boxes = try await engine.mailboxes(accountID: account.id)
            let inbox = try XCTUnwrap(boxes.first { $0.role == .inbox })
            let trash = try XCTUnwrap(boxes.first { $0.role == .trash })
            let subject = "Mist mail undo probe \(UUID())"
            let draft = MailDraft(accountID: account.id, to: [.init(email)], subject: subject, plainText: "Mist mail undo integration probe.")
            _ = try await engine.saveDraft(draft)
            try await engine.send(draft.id)

            let clock = ContinuousClock(), deadline = clock.now + .seconds(30)
            var delivered: MailMessageSummary?
            repeat {
                try await engine.refresh(mailboxID: inbox.id)
                delivered = try await engine.messages(in: .mailbox(inbox.id), limit: 1000).first { $0.subject == subject }
                if delivered != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            } while clock.now < deadline
            var message = try XCTUnwrap(delivered, "Self-send did not arrive within 30 seconds")

            for archive in [true, false] {
                let operation = try await archive ? engine.archive(message.id) : engine.trash(message.id)
                try await engine.flushPending(accountID: account.id)
                _ = try await engine.undo(operation)
                try await engine.flushPending(accountID: account.id)
                try await engine.refresh(mailboxID: inbox.id)
                try await engine.refresh(mailboxID: trash.id)
                let restored = try await engine.messages(in: .mailbox(inbox.id), limit: 1000)
                let trashed = try await engine.messages(in: .mailbox(trash.id), limit: 1000)
                XCTAssertFalse(trashed.contains { $0.subject == subject })
                message = try XCTUnwrap(restored.first { $0.subject == subject })
            }
            try await engine.trash(message.id)
            try await engine.flushPending(accountID: account.id)
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    func testLiveAccount() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIST_LIVE_MAIL"] == "1" else { throw XCTSkip("Live mail disabled; set MIST_LIVE_MAIL=1 explicitly") }
        guard let name = env["MIST_LIVE_MAIL_PRESET"]?.lowercased(), let user = env["MIST_LIVE_MAIL_USER"], !user.isEmpty,
              let password = env["MIST_LIVE_MAIL_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Live mail requires MIST_LIVE_MAIL_PRESET, MIST_LIVE_MAIL_USER and MIST_LIVE_MAIL_PASSWORD")
        }
        let preset: MailAccountPreset, domain: String
        switch name {
        case "gmail": preset = .gmail; domain = "gmail.com"
        case "uoft", "uoft cs", "uoft-cs": preset = .uoftCS; domain = "cs.toronto.edu"
        default: throw MailError.invalidConfiguration
        }
        let email = user.contains("@") ? user : user + "@" + domain
        let config = MailAccountConfig(displayName: "Live mail probe", senderName: "Mail probe", email: email, username: user,
                                       imap: preset.imap!, smtp: preset.smtp!)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = try MailEngine(baseDirectory: base, credentialStore: InMemoryMailCredentialStore())
        do {
            let start = Date()
            let account = try await engine.addAccount(config, password: password)
            try await engine.refreshMailboxes(accountID: account.id)
            let boxes = try await engine.mailboxes(accountID: account.id)
            print("Live mail \(preset.name): \(boxes.count) mailboxes; login/LIST \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            guard let inbox = boxes.first(where: { $0.role == .inbox }) else { throw MailError.notFound }
            let syncStart = Date()
            try await engine.open(inbox.id)
            let rows = try await engine.messages(in: .mailbox(inbox.id), limit: 1000)
            print("Live mail: INBOX window \(rows.count) messages (up to 1000), sync \(String(format: "%.2f", Date().timeIntervalSince(syncStart)))s")
            if env["MIST_LIVE_MAIL_SEND_TO_SELF"] == "1" {
                let subject = "Mist mail probe \(UUID())"
                let draft = MailDraft(accountID: account.id, to: [.init(email)], subject: subject, plainText: "Mist mail integration probe.")
                _ = try await engine.saveDraft(draft)
                let sentAt = Date(); try await engine.send(draft.id)
                var found = false
                while Date().timeIntervalSince(sentAt) < 30 {
                    try await engine.refresh(mailboxID: inbox.id)
                    if try await engine.messages(in: .mailbox(inbox.id)).contains(where: { $0.subject == subject }) { found = true; break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                XCTAssertTrue(found, "Self-send did not arrive within 30 seconds")
                print("Live mail: self-send \(found ? "received" : "timed out") after \(String(format: "%.2f", Date().timeIntervalSince(sentAt)))s")
            }
            await engine.stop()
        } catch { await engine.stop(); throw error }
    }
}
