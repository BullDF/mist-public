import Foundation

extension MailEngine {
    public func send(_ draftID: UUID) async throws {
        guard online else {
            var draft = try store.draft(draftID); draft.lastSendError = "offline"; try store.save(draft); emit(.draftsChanged)
            throw MailError.offline
        }
        draftTasks.removeValue(forKey: draftID)?.cancel()
        let lock = draftLock(draftID); await lock.acquire()
        do { try await performSend(draftID); await lock.release() }
        catch {
            if var draft = try? store.draft(draftID) {
                draft.lastSendError = String(describing: error as? MailError ?? .cannotConnect)
                try? store.save(draft); emit(.draftsChanged)
                if let failure = error as? MailError, !failure.isPermanent { await failed(draft.accountID, failure) }
            }
            await lock.release(); throw error
        }
    }
    func performSend(_ id: UUID) async throws {
        var draft = try store.draft(id)
        let account = try account(draft.accountID)
        let transport = try await connection(account.id)
        let recipients = draft.to + draft.cc + draft.bcc
        guard !recipients.isEmpty else { throw MailError.invalidConfiguration }
        let bytes: Data
        if let accepted = draft.acceptedMessage { bytes = accepted }
        else {
            bytes = try MailMIME.serialize(draft, account: account, includeBcc: false)
            try await transport.send(bytes, from: .init(account.config.email, name: account.config.senderName), recipients: recipients)
            // Preserve any newer editor data, but prevent another submission after acceptance.
            draft = try store.draft(id); draft.acceptedMessage = bytes; try store.save(draft)
        }
        if !account.isGmail && !draft.sentCopyFiled {
            let sent = try ensureLocalMailbox(accountID: account.id, role: .sent, name: "Sent")
            try await ensureRemoteMailbox(sent, transport: transport)
            _ = try await transport.append(bytes, to: sent.name, flags: [MailFlags.seen])
            draft.sentCopyFiled = true; try store.save(draft)
        }
        if let context = draft.replyContext, let source = try? store.message(context.sourceMessageID) {
            _ = try enqueue(source.id, action: .flag(context.kind == .forward ? MailFlags.forwarded : MailFlags.answered, true))
        }
        if let uid = draft.serverUID, let box = draft.serverMailboxID { try queueServerDelete(uid: uid, mailboxID: box, uidValidity: draft.serverUIDValidity) }
        try store.deleteDraft(id); try removeDraftFiles(id); emit(.draftsChanged)
        try? await replayPending(accountID: account.id)
        syncSentCopy(of: id, accountID: account.id)
    }
    /// Sent syncs only every few minutes, so a list showing it would miss the copy just sent. Gmail
    /// files its own copy of SMTP mail, possibly a moment after accepting it, so a sync that doesn't
    /// find the copy yet runs once more.
    func syncSentCopy(of draftID: UUID, accountID: UUID) {
        Task { [weak self] in
            guard await self?.syncSent(accountID, finding: draftID) == false else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            _ = await self?.syncSent(accountID, finding: draftID)
        }
    }
    /// Whether Sent holds the copy, whose Message-ID carries the draft's ID, after a sync. A failed
    /// sync counts as found: the periodic refresh retries it.
    private func syncSent(_ accountID: UUID, finding draftID: UUID) async -> Bool {
        guard let box = try? store.mailboxes(accountID: accountID).first(where: { $0.role == .sent }) else { return true }
        do { try await syncMailbox(box.id) } catch { return true }
        let key = draftID.uuidString.lowercased()
        return (try? store.messages(mailboxID: box.id))?.contains { $0.remote.messageID?.lowercased().contains(key) == true } ?? true
    }
}
