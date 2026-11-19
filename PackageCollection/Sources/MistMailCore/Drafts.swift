import Foundation

extension MailEngine {
    public func drafts(accountID: UUID? = nil) throws -> [MailDraft] {
        try store.drafts().filter { accountID == nil || $0.accountID == accountID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func draft(_ id: UUID) throws -> MailDraft { try store.draft(id) }
    @discardableResult
    public func saveDraft(_ draft: MailDraft) throws -> MailDraft {
        _ = try account(draft.accountID)
        if let existing = try? store.draft(draft.id), existing.acceptedMessage != nil { throw MailError.unsupported }
        var value = draft
        var previousServerDraft: (uid: UInt32, mailboxID: UUID, validity: UInt32?)?
        value.revision = (try? store.draft(draft.id).revision).map { $0 + 1 } ?? 1
        // Network metadata is owned by the engine; a stale editor snapshot cannot undo APPENDUID.
        if let existing = try? store.draft(draft.id) {
            if existing.accountID == value.accountID {
                value.serverUID = existing.serverUID; value.serverMailboxID = existing.serverMailboxID
                value.serverUpdatedAt = existing.serverUpdatedAt
                value.serverUIDValidity = existing.serverUIDValidity
                value.serverRevision = existing.serverRevision
            } else {
                if let uid = existing.serverUID, let box = existing.serverMailboxID { previousServerDraft = (uid, box, existing.serverUIDValidity) }
                value.serverUID = nil; value.serverMailboxID = nil; value.serverUpdatedAt = nil
                value.serverUIDValidity = nil; value.serverRevision = nil
            }
        }
        let folder = store.base.appendingPathComponent("DraftAttachments").appendingPathComponent(draft.id.uuidString)
        for i in value.attachments.indices {
            let attachment = value.attachments[i]
            if attachment.file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = attachment.id.uuidString + "-" + URL(fileURLWithPath: attachment.filename).lastPathComponent
            let destination = folder.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: attachment.file, to: destination) }
            value.attachments[i].file = destination
        }
        value.updatedAt = now(); value.lastSendError = nil
        try store.db.transaction {
            if let previousServerDraft { try queueServerDelete(uid: previousServerDraft.uid, mailboxID: previousServerDraft.mailboxID, uidValidity: previousServerDraft.validity) }
            try store.save(value)
        }
        emit(.draftsChanged)
        scheduleDraftFlush(value.id, delay: 30)
        return value
    }
    func scheduleDraftFlush(_ id: UUID, delay: TimeInterval) {
        draftTasks.removeValue(forKey: id)?.cancel()
        draftTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
            await self?.debouncedDraftFlush(id)
        }
    }
    func scheduleDirtyDrafts(accountID: UUID) throws {
        for draft in try store.drafts() where draft.accountID == accountID && draft.acceptedMessage == nil &&
            draft.serverRevision != draft.revision && draftTasks[draft.id] == nil {
            scheduleDraftFlush(draft.id, delay: max(0, 30 - now().timeIntervalSince(draft.updatedAt)))
        }
    }
    func debouncedDraftFlush(_ id: UUID) async {
        draftTasks[id] = nil
        try? await flushDraft(id)
    }
    func draftLock(_ id: UUID) -> MailOperationGate {
        if let lock = draftLocks[id] { return lock }
        let lock = MailOperationGate(); draftLocks[id] = lock; return lock
    }
    public func flushDraft(_ id: UUID) async throws {
        draftTasks.removeValue(forKey: id)?.cancel()
        let lock = draftLock(id); await lock.acquire()
        do { try await performFlushDraft(id); await lock.release() }
        catch {
            await lock.release()
            // A draft the server or MIME refuses (a half-typed address) is no connection failure:
            // reconnecting would flush it again at once, looping every second or two.
            if let draft = try? store.draft(id), (error as? MailError)?.isPermanent != true { await failed(draft.accountID, error) }
            throw error
        }
    }
    func performFlushDraft(_ id: UUID) async throws {
        let value = try store.draft(id), account = try account(value.accountID)
        guard value.acceptedMessage == nil else { return }
        if value.serverRevision == value.revision { return }
        // An empty draft never reaches the server, and an emptied one leaves it.
        if value.isEmpty {
            var draft = value
            draft.serverUID = nil; draft.serverMailboxID = nil; draft.serverUpdatedAt = nil; draft.serverUIDValidity = nil
            draft.serverRevision = value.revision
            guard let uid = value.serverUID, let box = value.serverMailboxID else { try store.save(draft); return }
            try store.db.transaction {
                try queueServerDelete(uid: uid, mailboxID: box, uidValidity: value.serverUIDValidity)
                try store.save(draft)
            }
            emit(.draftsChanged)
            if online { try await replayPending(accountID: account.id) }
            return
        }
        let transport = try await connection(account.id)
        let box = try ensureLocalMailbox(accountID: account.id, role: .drafts, name: "Drafts")
        try await ensureRemoteMailbox(box, transport: transport)
        let selection = try await transport.select(box.name)
        let bytes = try MailMIME.serialize(value, account: account, includeBcc: true)
        guard let uid = try await transport.append(bytes, to: box.name, flags: [MailFlags.draft, MailFlags.seen]) else {
            throw MailError.serverRejected("Server did not identify the appended draft")
        }
        var latest = try store.draft(id)
        // The sender can change while APPEND awaits the old account's server.
        guard latest.accountID == value.accountID else {
            try queueServerDelete(uid: uid, mailboxID: box.id, uidValidity: selection.uidValidity)
            try await replayPending(accountID: account.id)
            return
        }
        let previousUID = latest.serverUID, previousBox = latest.serverMailboxID, previousValidity = latest.serverUIDValidity
        latest.serverUID = uid; latest.serverMailboxID = box.id
        latest.serverUpdatedAt = value.updatedAt
        latest.serverUIDValidity = selection.uidValidity
        latest.serverRevision = value.revision
        try store.save(latest)
        if let previousUID, let previousBox { try queueServerDelete(uid: previousUID, mailboxID: previousBox, uidValidity: previousValidity) }
        try await replayPending(accountID: account.id); emit(.draftsChanged)
        // Drafts syncs only when opened, so a list showing it would miss the copy just saved.
        if try store.mailbox(box.id).initialSyncComplete { try? await syncMailbox(box.id) }
    }
    func ensureRemoteMailbox(_ box: Mailbox, transport: any MailTransport) async throws {
        let boxes = try await transport.listMailboxes()
        if !boxes.contains(where: { $0.name == box.name }) { try await transport.createMailbox(box.name) }
    }
    public func flushDrafts() async {
        for draft in (try? store.drafts()) ?? [] { try? await flushDraft(draft.id) }
    }
    func queueServerDelete(uid: UInt32, mailboxID: UUID, uidValidity: UInt32? = nil) throws {
        let box = try store.mailbox(mailboxID)
        let cached = try store.messages(mailboxID: box.id).first { $0.remote.uid == uid }
        let message = cached ?? StoredMessage(id: UUID(), accountID: box.accountID, mailboxID: box.id, remote: .init(uid: uid))
        let operation = PendingMailOperation(id: UUID(), accountID: box.accountID, mailboxID: box.id, uidValidity: uidValidity ?? box.uidValidity, action: .delete, before: [message])
        try store.savePending(operation, id: operation.id, accountID: operation.accountID)
        if var cached { operation.apply(to: &cached); try store.saveWithoutTransaction(cached); try changed([box.id]) }
    }
    public func discardDraft(_ id: UUID) async throws {
        draftTasks.removeValue(forKey: id)?.cancel()
        let lock = draftLock(id); await lock.acquire()
        let accountID: UUID
        do {
            let value = try store.draft(id)
            accountID = value.accountID
            try store.db.transaction {
                if let uid = value.serverUID, let box = value.serverMailboxID { try queueServerDelete(uid: uid, mailboxID: box, uidValidity: value.serverUIDValidity) }
                try store.deleteDraft(id)
            }
            try removeDraftFiles(id); emit(.draftsChanged)
            await lock.release()
        } catch { await lock.release(); throw error }
        if online { try await replayPending(accountID: accountID) }
    }
    public func editDraft(fromMessage id: UUID) async throws -> MailDraft {
        let detail = try await messageDetail(id)
        if let existing = try store.drafts().first(where: { $0.accountID == detail.summary.accountID && $0.serverMailboxID == detail.summary.mailboxID && $0.serverUID == detail.summary.uid }) { return existing }
        var draft = MailDraft(accountID: detail.summary.accountID, to: detail.headers.to, cc: detail.headers.cc, bcc: detail.headers.bcc,
                              subject: detail.summary.subject, plainText: detail.plainText ?? "", html: detail.html,
                              serverUID: detail.summary.uid, serverMailboxID: detail.summary.mailboxID)
        draft.serverUIDValidity = try store.mailbox(detail.summary.mailboxID).uidValidity
        draft.attachments = try await copiedAttachments(detail, includeRegular: true)
        return try saveDraft(draft)
    }
    public func makeReply(to id: UUID, all: Bool = false, quoteIntro: String = "On %1$@, %2$@ wrote:") async throws -> MailDraft {
        try saveDraft(await replyDraft(to: id, all: all, quoteIntro: quoteIntro))
    }
    public func replyDraft(to id: UUID, all: Bool = false, quoteIntro: String = "On %1$@, %2$@ wrote:") async throws -> MailDraft {
        let detail = try await messageDetail(id), account = try account(detail.summary.accountID)
        let parent = detail.headers
        let from = parent.replyTo.isEmpty ? parent.from : parent.replyTo
        var seen: Set<String> = all ? [account.config.email.lowercased()] : []
        func unique(_ addresses: [MailAddress]) -> [MailAddress] { addresses.filter { seen.insert($0.email.lowercased()).inserted } }
        let to = unique(from + (all ? parent.to : [])), cc = all ? unique(parent.cc) : []
        let name = parent.from.first?.name ?? parent.from.first?.email ?? ""
        let date = DateFormatter.localizedString(from: parent.date, dateStyle: .medium, timeStyle: .short)
        let intro = String(format: quoteIntro, date, name)
        let text = detail.plainText ?? MailText.plain(detail.html ?? "")
        let quote = text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        let refs = parent.references + (parent.messageID.map { [$0] } ?? [])
        var draft = MailDraft(accountID: account.id, to: to, cc: cc, subject: prefixedSubject(parent.subject, prefix: "Re"),
                         plainText: "\n\n\(intro)\n\(quote)", html: detail.html.map { "<div><br></div><p>\(escapeHTML(intro))</p><blockquote type=\"cite\">\(Self.quotableHTML($0))</blockquote>" },
                         replyContext: .init(kind: all ? .replyAll : .reply, sourceMessageID: id, inReplyTo: parent.messageID, references: refs))
        draft.attachments = try await copiedAttachments(detail, includeRegular: false)
        return draft
    }
    public func makeForward(_ id: UUID, quoteIntro: String = "On %1$@, %2$@ wrote:") async throws -> MailDraft {
        try saveDraft(await forwardDraft(id, quoteIntro: quoteIntro))
    }
    public func forwardDraft(_ id: UUID, quoteIntro: String = "On %1$@, %2$@ wrote:") async throws -> MailDraft {
        let detail = try await messageDetail(id)
        let name = detail.headers.from.first?.name ?? detail.headers.from.first?.email ?? ""
        let date = DateFormatter.localizedString(from: detail.headers.date, dateStyle: .medium, timeStyle: .short)
        let intro = String(format: quoteIntro, date, name)
        let quote = (detail.plainText ?? MailText.plain(detail.html ?? "")).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        var draft = MailDraft(accountID: detail.summary.accountID, subject: prefixedSubject(detail.summary.subject, prefix: "Fwd"),
                              plainText: "\n\n\(intro)\n\(quote)",
                              html: detail.html.map { "<div><br></div><p>\(escapeHTML(intro))</p><blockquote type=\"cite\">\(Self.quotableHTML($0))</blockquote>" },
                              replyContext: .init(kind: .forward, sourceMessageID: id, inReplyTo: nil, references: detail.headers.references + (detail.headers.messageID.map { [$0] } ?? [])))
        draft.attachments = try await copiedAttachments(detail, includeRegular: true)
        return draft
    }
    private func copiedAttachments(_ detail: MailMessageDetail, includeRegular: Bool) async throws -> [MailDraftAttachment] {
        let html = detail.html ?? ""
        let regex = try NSRegularExpression(pattern: "cid:([^\\s\"'<>]+)", options: .caseInsensitive)
        func normalized(_ cid: String) -> String {
            (cid.removingPercentEncoding ?? cid).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        let referenced = Set(regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { normalized(String(html[$0])) }
        })
        var result: [MailDraftAttachment] = []
        for attachment in detail.attachments {
            let cid = attachment.part.contentID.map(normalized)
            let inline = cid.map { referenced.contains($0) } ?? false
            guard inline || (includeRegular && attachment.part.isAttachment) else { continue }
            let file = try await attachmentFile(attachment.id)
            result.append(.init(filename: attachment.filename, file: file, contentID: inline ? cid : nil))
        }
        return result
    }
    func prefixedSubject(_ subject: String, prefix: String) -> String {
        let stripped = subject.replacingOccurrences(of: "^(?:(?:re|fw|fwd):\\s*)+", with: "", options: [.regularExpression, .caseInsensitive])
        return prefix + ": " + stripped
    }
    /// A whole HTML document can't nest in a quote: the compose page would take the quote's `<body>`
    /// for its own and skip its own wrapper, so typed text lost the compose font. Quote the body's
    /// content with the head's style sheets, in a `<div>` carrying the body's own style.
    static func quotableHTML(_ html: String) -> String {
        guard let open = html.range(of: "<body\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return html }
        let close = html.range(of: "</body\\s*>", options: [.regularExpression, .caseInsensitive, .backwards], range: open.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
        let head = String(html[..<open.lowerBound])
        let styles = (try? NSRegularExpression(pattern: "<style\\b[^>]*>.*?</style\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators]))?
            .matches(in: head, range: NSRange(head.startIndex..., in: head)).compactMap { Range($0.range, in: head).map { String(head[$0]) } } ?? []
        let content = String(html[open.upperBound..<close])
        guard let style = html[open].range(of: "\\sstyle\\s*=\\s*(\"[^\"]*\"|'[^']*')", options: [.regularExpression, .caseInsensitive]) else { return styles.joined() + content }
        return styles.joined() + "<div" + html[open][style] + ">" + content + "</div>"
    }
    func escapeHTML(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}
