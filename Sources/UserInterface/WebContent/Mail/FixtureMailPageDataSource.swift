import Foundation
import MistMailCore

/// No keychain or network access. Each fixture owns its actions and event subscribers.
@MainActor
final class FixtureMailPageDataSource: MailPageDataSource {
    private(set) var state: MailPageSnapshot
    private var details: [UUID: MailMessageDetail] = [:]
    private var observers: [UUID: AsyncStream<MailEvent>.Continuation] = [:]
    private var directory: URL?
    private(set) var draftValues: [UUID: MailDraft] = [:]
    private(set) var flushedDrafts: [UUID] = [], trashed: [UUID] = []
    var flushError: MailError?, sendError: MailError?
    private(set) var sent: [MailDraft] = []
    var saveDelay: Duration = .zero
    private(set) var activeSaves = 0, maximumConcurrentSaves = 0
    private(set) var loadOlderCalls = 0
    private(set) var serverSearches: [UUID] = []
    private(set) var openCalls: [UUID] = []
    private(set) var lastOperationID: UUID?
    private enum UndoChange { case flag(String, [UUID: Bool]), move(UUID, from: UUID) }
    private var undoChanges: [UUID: UndoChange] = [:]

    init(empty: Bool = false) {
        let signature = "<div>Best,</div><div style=\"font-family: Georgia, serif; color: #265a87\">Example Sender</div>"
        let gmail = MailAccount(config: .init(displayName: "Personal", senderName: "Johnny", email: "johnny@example.com", username: "johnny@example.com", imap: MailAccountPreset.gmail.imap!, smtp: MailAccountPreset.gmail.smtp!, signatureHTML: signature), isGmail: true)
        let school = MailAccount(config: .init(displayName: "UofT CS", senderName: "Johnny", email: "johnny@cs.example.edu", username: "johnny", imap: MailAccountPreset.uoftCS.imap!, smtp: MailAccountPreset.uoftCS.smtp!, sortOrder: 1))
        var boxes = [Mailbox(accountID: gmail.id, name: "INBOX", role: .inbox),
                     Mailbox(accountID: gmail.id, name: "[Gmail]", attributes: ["\\Noselect"]),
                     Mailbox(accountID: gmail.id, name: "[Gmail]/Messages envoy&AOk-s", role: .sent),
                     Mailbox(accountID: gmail.id, name: "[Gmail]/Tous les messages", role: .all),
                     Mailbox(accountID: gmail.id, name: "[Gmail]/Brouillons", role: .drafts),
                     Mailbox(accountID: gmail.id, name: "[Gmail]/Corbeille", role: .trash),
                     Mailbox(accountID: school.id, name: "INBOX", role: .inbox),
                     Mailbox(accountID: school.id, name: "Projects/NLP/Reading"),
                     Mailbox(accountID: school.id, name: "Sent", role: .sent),
                     Mailbox(accountID: school.id, name: "Trash", role: .trash),
                     Mailbox(accountID: school.id, name: "Spam", role: .junk)]
        for index in boxes.indices { boxes[index].hasMore = false; boxes[index].initialSyncComplete = true }
        state = .init(accounts: empty ? [] : [gmail, school], mailboxes: empty ? [] : boxes, statuses: [gmail.id: .connected, school.id: .retrying(seconds: 30)], unread: .init())
        guard !empty else { return }
        for index in 0..<240 {
            let box = boxes[index % 4 == 0 ? 6 : 0]
            let id = UUID(), attachment = MailAttachment(messageID: id, part: .init(section: "2", mimeType: "image/png", filename: "diagram.png", contentID: "diagram", size: 68, isAttachment: true))
            let headers = MailRemoteMessage(uid: UInt32(index + 1), from: [.init(index % 2 == 0 ? "ada@example.com" : "research@example.edu", name: index % 2 == 0 ? "Ada" : nil)], to: [.init("johnny@example.com", name: "Johnny")], subject: index == 0 ? "A message with images" : "Reading group \(index)", date: Date().addingTimeInterval(-Double(index) * 3600), flags: index % 3 == 0 ? [MailFlags.flagged] : [MailFlags.seen])
            let summary = MailMessageSummary(id: id, accountID: box.accountID, mailboxID: box.id, sender: headers.from, recipients: headers.to, subject: headers.subject, snippet: "Here are the notes for our next meeting. Please take a look at the attached diagram.", date: headers.date, flags: headers.flags, hasAttachments: index == 0, uid: headers.uid)
            details[id] = .init(summary: summary, headers: headers, plainText: index == 0 ? nil : "Hello Johnny,\n\nNotes: https://example.com/notes?a=1&b=2\n\n<This stays text> & so does this.", html: index == 0 ? "<h1>Reading group</h1><p>Inline diagram:</p><img src=\"cid:diagram\"><img src=\"https://example.com/tracker.png\"><a href=\"https://example.com\">Notes</a>" : nil, attachments: index == 0 ? [attachment] : [])
        }
        for box in boxes where box.role == .sent || box.role == .drafts {
            let id = UUID(), headers = MailRemoteMessage(uid: 1, from: [.init(gmail.config.email)], to: [.init("ada@example.com", name: "Ada")], subject: "Meeting notes")
            let summary = MailMessageSummary(id: id, accountID: box.accountID, mailboxID: box.id, sender: headers.from, recipients: headers.to, subject: headers.subject, snippet: "Here are my notes.", date: headers.date, flags: [MailFlags.seen], hasAttachments: false, uid: 1)
            details[id] = .init(summary: summary, headers: headers, plainText: "Here are my notes.")
        }
        updateCounts()
    }
    deinit {
        observers.values.forEach { $0.finish() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func updateCounts() {
        var counts: [UUID: Int] = [:]
        for value in details.values where !value.summary.flags.contains(MailFlags.seen) { counts[value.summary.mailboxID, default: 0] += 1 }
        state.unread = .init(mailboxes: counts, unifiedInbox: state.mailboxes.filter { $0.role == .inbox }.reduce(0) { $0 + counts[$1.id, default: 0] })
    }
    func snapshot() async throws -> MailPageSnapshot { state }
    func summary(_ id: UUID) async throws -> MailMessageSummary {
        guard let value = details[id]?.summary else { throw MailError.notFound }
        return value
    }
    func messages(in scope: MailMessageScope, before: MailMessageCursor?, limit: Int) async throws -> [MailMessageSummary] {
        let ids: Set<UUID>
        switch scope {
        case .mailbox(let id): ids = [id]
        case .unifiedInbox: ids = Set(state.mailboxes.filter { $0.role == .inbox }.map(\.id))
        case .unifiedRole(let role): ids = Set(state.mailboxes.filter { $0.role == role }.map(\.id))
        }
        return Array(details.values.map(\.summary).filter { value in
            ids.contains(value.mailboxID) && (before.map { value.date < $0.date || (value.date == $0.date && value.id.uuidString < $0.id.uuidString) } ?? true)
        }.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }.prefix(limit))
    }
    func detail(_ id: UUID) async throws -> MailMessageDetail {
        guard var detail = details[id] else { throw MailError.notFound }
        if let attachment = detail.attachments.first { detail.inlineFiles["diagram"] = try await attachmentFile(attachment.id) }
        return detail
    }
    func attachmentFile(_ id: UUID) async throws -> URL {
        guard details.values.contains(where: { $0.attachments.contains { $0.id == id } }) else { throw MailError.notFound }
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-fixture-" + UUID().uuidString)
        directory = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("diagram.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: url)
        return url
    }
    func open(_ mailbox: UUID) async throws { openCalls.append(mailbox) }
    func refresh(_ mailboxes: [UUID]) async throws { emit(.messagesChanged(Set(mailboxes))) }
    func loadOlder(_ mailbox: UUID) async throws { loadOlderCalls += 1 }
    func search(_ query: String, in mailboxIDs: [UUID]) async throws -> [MailMessageSummary] {
        Array(details.values.map(\.summary).filter {
            mailboxIDs.contains($0.mailboxID) && ([$0.subject, MailPresentation.addresses($0.sender), $0.snippet].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }.prefix(200))
    }
    func searchServer(_ query: String, mailbox: UUID) async throws { serverSearches.append(mailbox) }
    func markAllRead(_ mailboxIDs: [UUID]) async throws -> [UUID] {
        var operations: [UUID] = []
        for mailboxID in Set(mailboxIDs) {
            let unread = details.values.filter { $0.summary.mailboxID == mailboxID && !$0.summary.flags.contains(MailFlags.seen) }
            guard !unread.isEmpty else { continue }
            for value in unread {
                details[value.summary.id]?.summary.flags.insert(MailFlags.seen)
                details[value.summary.id]?.headers.flags.insert(MailFlags.seen)
            }
            let operation = UUID()
            undoChanges[operation] = .flag(MailFlags.seen, Dictionary(uniqueKeysWithValues: unread.map { ($0.summary.id, false) }))
            operations.append(operation)
        }
        updateCounts(); emit(.messagesChanged(Set(mailboxIDs))); emit(.unreadCountsChanged(state.unread))
        return operations
    }
    func canArchive(_ id: UUID) async -> Bool {
        guard let value = details[id]?.summary, let account = state.accounts.first(where: { $0.id == value.accountID }) else { return false }
        let role = state.mailboxes.first { $0.id == value.mailboxID }?.role
        return account.isGmail ? role == .inbox && state.mailboxes.contains { $0.accountID == account.id && $0.role == .all } : role != .archive
    }
    func trash(_ id: UUID) async throws -> UUID {
        let message = try await summary(id)
        guard let target = state.mailboxes.first(where: { $0.accountID == message.accountID && $0.role == .trash && $0.id != message.mailboxID }) else { throw MailError.unsupported }
        let result = try await perform(.move(target.id), on: id); trashed.append(id); return result
    }
    func drafts() async throws -> [MailDraft] { Array(draftValues.values) }
    func perform(_ action: MailPageAction, on id: UUID) async throws -> UUID {
        guard var value = details[id] else { throw MailError.notFound }
        let box = value.summary.mailboxID, operation = UUID()
        var destination: UUID?
        switch action {
        case .seen(let seen):
            undoChanges[operation] = .flag(MailFlags.seen, [id: value.summary.flags.contains(MailFlags.seen)])
            setFlag(MailFlags.seen, seen, on: &value)
        case .flagged(let flag):
            undoChanges[operation] = .flag(MailFlags.flagged, [id: value.summary.flags.contains(MailFlags.flagged)])
            setFlag(MailFlags.flagged, flag, on: &value)
        case .archive:
            guard await canArchive(id) else { throw MailError.unsupported }
            let gmail = state.accounts.first { $0.id == value.summary.accountID }?.isGmail == true
            if let target = state.mailboxes.first(where: { $0.accountID == value.summary.accountID && $0.role == (gmail ? .all : .archive) }) { destination = target.id }
            else {
                let target = Mailbox(accountID: value.summary.accountID, name: "Archive", role: .archive, initialSyncComplete: true, hasMore: false)
                state.mailboxes.append(target); destination = target.id; emit(.mailboxesChanged(target.accountID))
            }
        case .delete:
            destination = state.mailboxes.first { $0.accountID == value.summary.accountID && $0.role == .trash && $0.id != box }?.id
            if destination == nil {
                details[id] = nil; lastOperationID = operation; publishChanges([box]); return operation
            }
        case .move(let target):
            guard state.mailboxes.contains(where: { $0.id == target && $0.accountID == value.summary.accountID && $0.id != box && !$0.attributes.contains { $0.lowercased() == "\\noselect" } }) else { throw MailError.unsupported }
            destination = target
        }
        if let destination {
            undoChanges[operation] = .move(id, from: box)
            move(&value, to: destination)
        }
        details[id] = value
        lastOperationID = operation
        publishChanges(Set([box, value.summary.mailboxID]))
        return operation
    }
    func undo(_ operationIDs: [UUID]) async throws -> MailUndoResult {
        var messages: [UUID] = [], mailboxes: Set<UUID> = []
        for id in operationIDs.reversed() {
            guard let change = undoChanges.removeValue(forKey: id) else { throw MailError.notFound }
            switch change {
            case .flag(let flag, let before):
                for (messageID, enabled) in before {
                    guard var value = details[messageID] else { continue }
                    setFlag(flag, enabled, on: &value)
                    details[messageID] = value
                    messages.append(messageID); mailboxes.insert(value.summary.mailboxID)
                }
            case .move(let messageID, let mailboxID):
                guard var value = details[messageID] else { throw MailError.notFound }
                mailboxes.formUnion([value.summary.mailboxID, mailboxID])
                move(&value, to: mailboxID)
                details[messageID] = value; messages.append(messageID)
            }
        }
        publishChanges(mailboxes)
        return MailUndoResult(messageIDs: messages)
    }
    func cancelPendingUndoMove(_ operationID: UUID) async throws -> Bool { false }
    func currentSummary(_ id: UUID) async throws -> MailMessageSummary { try await summary(id) }
    func failAction(_ operationID: UUID) async throws {
        _ = try await undo([operationID])
        emit(.actionFailed(operationID: operationID, error: .unsupported))
    }
    private func setFlag(_ flag: String, _ enabled: Bool, on value: inout MailMessageDetail) {
        if enabled { value.summary.flags.insert(flag); value.headers.flags.insert(flag) }
        else { value.summary.flags.remove(flag); value.headers.flags.remove(flag) }
    }
    private func move(_ value: inout MailMessageDetail, to mailboxID: UUID) {
        let summary = value.summary
        value.summary = .init(id: summary.id, accountID: summary.accountID, mailboxID: mailboxID, sender: summary.sender, recipients: summary.recipients ?? [], subject: summary.subject, snippet: summary.snippet, date: summary.date, flags: summary.flags, hasAttachments: summary.hasAttachments, uid: summary.uid)
    }
    private func publishChanges(_ mailboxes: Set<UUID>) {
        updateCounts(); emit(.messagesChanged(mailboxes)); emit(.unreadCountsChanged(state.unread))
    }
    func events() async -> AsyncStream<MailEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        }
    }
    func draft(_ id: UUID) async throws -> MailDraft {
        guard let draft = draftValues[id] else { throw MailError.notFound }; return draft
    }
    func saveDraft(_ draft: MailDraft) async throws -> MailDraft {
        activeSaves += 1; maximumConcurrentSaves = max(maximumConcurrentSaves, activeSaves)
        defer { activeSaves -= 1 }
        if saveDelay > .zero { try await Task.sleep(for: saveDelay) }
        var value = draft; value.updatedAt = Date(); draftValues[value.id] = value; emit(.draftsChanged); return value
    }
    func flushDraft(_ id: UUID) async throws { flushedDrafts.append(id); if let flushError { throw flushError } }
    func discardDraft(_ id: UUID) async throws {
        if let draft = draftValues.removeValue(forKey: id), let box = draft.serverMailboxID, let uid = draft.serverUID {
            details = details.filter { !($0.value.summary.mailboxID == box && $0.value.summary.uid == uid) }
            emit(.messagesChanged([box]))
        }
        emit(.draftsChanged)
    }
    func send(_ id: UUID) async throws { if let sendError { throw sendError }; sent.append(try await draft(id)); try await discardDraft(id) }
    func replyDraft(to id: UUID, all: Bool) async throws -> MailDraft { try await quotedDraft(id, kind: all ? .replyAll : .reply) }
    func forwardDraft(_ id: UUID) async throws -> MailDraft { try await quotedDraft(id, kind: .forward) }
    private func quotedDraft(_ id: UUID, kind: MailReplyKind) async throws -> MailDraft {
        let detail = try await detail(id), headers = detail.headers
        let sender = headers.replyTo.isEmpty ? headers.from : headers.replyTo
        var seen = Set(kind == .replyAll ? state.accounts.filter { $0.id == detail.summary.accountID }.map { $0.config.email.lowercased() } : [])
        func unique(_ values: [MailAddress]) -> [MailAddress] { values.filter { seen.insert($0.email.lowercased()).inserted } }
        let to = kind == .forward ? [] : unique(sender + (kind == .replyAll ? headers.to : []))
        let cc = kind == .replyAll ? unique(headers.cc) : []
        let subject = headers.subject.replacingOccurrences(of: "^(?:(?:re|fw|fwd):\\s*)+", with: "", options: [.regularExpression, .caseInsensitive])
        let intro = String(format: MailStrings.quoteIntro, DateFormatter.localizedString(from: headers.date, dateStyle: .medium, timeStyle: .short), MailPresentation.addresses(headers.from))
        let quote = (detail.plainText ?? "").components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        var value = MailDraft(accountID: detail.summary.accountID, to: to, cc: cc, subject: (kind == .forward ? "Fwd: " : "Re: ") + subject,
                              plainText: "\n\n\(intro)\n\(quote)", html: detail.html.map { "<div><br></div><p>\(MailComposeFormatting.escape(intro))</p><blockquote type=\"cite\">\($0)</blockquote>" },
                              replyContext: .init(kind: kind, sourceMessageID: id, inReplyTo: kind == .forward ? nil : headers.messageID, references: headers.references + (headers.messageID.map { [$0] } ?? [])))
        value.attachments = try await copiedAttachments(detail, includeRegular: kind == .forward)
        return value
    }
    private func copiedAttachments(_ detail: MailMessageDetail, includeRegular: Bool) async throws -> [MailDraftAttachment] {
        let referenced = MailComposeFormatting.referencedCIDs(detail.html ?? "")
        var values: [MailDraftAttachment] = []
        for attachment in detail.attachments {
            let cid = attachment.part.contentID.map(MailBodyPreparation.normalizedCID)
            let inline = cid.map { referenced.contains($0) } ?? false
            if inline || (includeRegular && attachment.part.isAttachment) { values.append(.init(filename: attachment.filename, file: try await attachmentFile(attachment.id), contentID: inline ? cid : nil)) }
        }
        return values
    }
    func editDraft(fromMessage id: UUID) async throws -> MailDraft {
        let detail = try await detail(id)
        if let existing = draftValues.values.first(where: { $0.serverMailboxID == detail.summary.mailboxID && $0.serverUID == detail.summary.uid }) { return existing }
        var value = MailDraft(accountID: detail.summary.accountID, to: detail.headers.to, cc: detail.headers.cc, bcc: detail.headers.bcc,
                              subject: detail.summary.subject, plainText: detail.plainText ?? "", html: detail.html,
                              serverUID: detail.summary.uid, serverMailboxID: detail.summary.mailboxID)
        value.attachments = try await copiedAttachments(detail, includeRegular: true)
        return try await saveDraft(value)
    }
    func addressSuggestions() async throws -> [MailAddressSuggestion] {
        var values: [String: MailAddressSuggestion] = [:]
        for detail in details.values.sorted(by: { $0.headers.date > $1.headers.date }) {
            for address in detail.headers.from + detail.headers.to + detail.headers.cc + detail.headers.replyTo {
                let key = address.email.lowercased()
                if var value = values[key] {
                    value.count += 1
                    if value.address.name?.isEmpty != false, address.name?.isEmpty == false { value.address.name = address.name }
                    values[key] = value
                } else { values[key] = .init(address: address, count: 1, lastUsed: detail.headers.date) }
            }
        }
        return values.values.sorted { $0.count == $1.count ? ($0.lastUsed == $1.lastUsed ? $0.address.email < $1.address.email : $0.lastUsed > $1.lastUsed) : $0.count > $1.count }
    }
    private func emit(_ event: MailEvent) { observers.values.forEach { $0.yield(event) } }
}
