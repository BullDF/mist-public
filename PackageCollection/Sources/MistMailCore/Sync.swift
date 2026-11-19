import Foundation

extension MailEngine {
    /// Refresh LIST without synchronizing messages; useful for read-only account probes.
    public func refreshMailboxes(accountID: UUID) async throws {
        let account = try account(accountID), transport = try await connection(accountID)
        try await discoverMailboxes(account, transport: transport)
    }
    public func refresh(accountID: UUID? = nil) async throws {
        try await refreshAccounts(accountID: accountID, autoOnly: false)
    }
    func refreshAccounts(accountID: UUID? = nil, autoOnly: Bool) async throws {
        let accounts = try store.accounts().filter { accountID == nil || $0.id == accountID }
        for account in accounts {
            let generation = generations[account.id]
            do {
                let transport = try await connection(account.id)
                setStatus(account.id, .syncing)
                try await discoverMailboxes(account, transport: transport)
                try await replayPending(accountID: account.id)
                for box in try store.mailboxes(accountID: account.id) where box.autoSync || (!autoOnly && box.initialSyncComplete) { try await syncMailbox(box.id) }
                backoff[account.id] = nil; retryTasks.removeValue(forKey: account.id)?.cancel()
                setStatus(account.id, .connected)
                try scheduleDirtyDrafts(accountID: account.id)
                if started { try await startIdle(account.id, transport: transport) }
            } catch { await failed(account.id, error, generation: generation); throw error }
        }
    }
    func discoverMailboxes(_ account: MailAccount, transport: any MailTransport) async throws {
        let remote = try await transport.listMailboxes(); _ = try self.account(account.id)
        let existing = try store.mailboxes(accountID: account.id)
        for box in remote {
            var local = existing.first { $0.name == box.name } ?? Mailbox(accountID: account.id, name: box.name)
            local.delimiter = box.delimiter; local.attributes = box.attributes
            local.needsCreation = false
            local.role = Mailbox.detectRole(name: box.name, attributes: box.attributes, gmail: account.isGmail)
            try store.save(local)
        }
        for box in existing where !box.needsCreation && !remote.contains(where: { $0.name == box.name }) { try store.deleteMailbox(box.id) }
        emit(.mailboxesChanged(account.id))
    }
    public func open(_ mailboxID: UUID) async throws { try await syncMailbox(mailboxID) }
    public func refresh(mailboxID: UUID) async throws { try await syncMailbox(mailboxID) }
    func syncMailbox(_ id: UUID) async throws {
        if let task = syncTasks[id] { syncAgain.insert(id); return try await task.value }
        let task = Task { try await self.performSync(id) }
        syncTasks[id] = task
        do {
            try await task.value; syncTasks[id] = nil
            if syncAgain.remove(id) != nil { try await syncMailbox(id) }
        } catch { syncTasks[id] = nil; syncAgain.remove(id); throw error }
    }
    func performSync(_ id: UUID) async throws {
        var box = try store.mailbox(id)
        let account = try account(box.accountID), transport = try await connection(box.accountID)
        let selection = try await transport.select(box.name)
        try Task.checkCancellation(); _ = try store.mailbox(id)
        var wasInitialized = box.initialSyncComplete
        if let validity = box.uidValidity, validity != selection.uidValidity {
            try invalidatePending(mailboxID: id)
            try store.resetMailbox(id); box.initialSyncComplete = false; box.oldestLoadedUID = nil; box.hasMore = true
            wasInitialized = false
            box.highestKnownUID = 0
        }
        box.uidValidity = selection.uidValidity
        var cached = try store.messages(mailboxID: id)
        // Not the highest stored UID: a move's copy or a server search hit can be stored above mail
        // that arrived since the last sync, which would then never load.
        let highest = box.highestKnownUID > 0 ? box.highestKnownUID : cached.map { $0.remote.uid }.max() ?? 0
        let uids: [UInt32]
        if !box.initialSyncComplete { uids = try await transport.search(.since(now().addingTimeInterval(-90 * 86400)), in: box.name) }
        else if highest < UInt32.max && highest + 1 < selection.uidNext { uids = try await transport.search(.range((highest + 1)...(selection.uidNext - 1)), in: box.name) }
        else { uids = [] }
        let remote = try await transport.fetch(uids, in: box.name, gmail: account.isGmail)
        try Task.checkCancellation(); _ = try store.mailbox(id)
        var fresh: [MailMessageSummary] = []
        for item in remote where !cached.contains(where: { $0.remote.uid == item.uid }) {
            let record = makeStored(item, mailbox: box); try store.save(record); fresh.append(record.summary)
        }
        if let low = cached.map({ $0.remote.uid }).min(), let high = cached.map({ $0.remote.uid }).max() {
            let flags = try await transport.flags(low...high, in: box.name)
            try Task.checkCancellation(); _ = try store.mailbox(id)
            // Read current rows after the network wait, preserving optimistic changes made meanwhile.
            cached = try store.messages(mailboxID: id)
            let pending: [PendingMailOperation] = try store.pending(accountID: box.accountID)
            for var item in cached where item.remote.uid >= low && item.remote.uid <= high {
                guard let serverFlags = flags[item.remote.uid] else {
                    if !pending.contains(where: { $0.before.contains(where: { $0.id == item.id }) }) { try store.deleteMessage(item.id) }
                    continue
                }
                item.remote.flags = serverFlags
                for operation in pending { operation.apply(to: &item) }
                try store.save(item)
            }
        }
        box.initialSyncComplete = true
        box.highestKnownUID = max(selection.uidNext > 0 ? selection.uidNext - 1 : 0, remote.map(\.uid).max() ?? 0)
        box.oldestLoadedUID = try store.messages(mailboxID: id).map { $0.remote.uid }.min() ?? selection.uidNext
        try store.save(box); try changed([id])
        if wasInitialized && box.role == .inbox && !fresh.isEmpty { emit(.newMessages(fresh)) }
        if box.role == .inbox {
            for item in try store.messages(mailboxID: id) where !item.bodyLoaded && item.remote.internalDate >= now().addingTimeInterval(-14 * 86400) {
                _ = try await messageDetail(item.id)
            }
        }
    }
    func makeStored(_ remote: MailRemoteMessage, mailbox: Mailbox) -> StoredMessage {
        let id = UUID()
        return StoredMessage(id: id, accountID: mailbox.accountID, mailboxID: mailbox.id, remote: remote,
                             attachments: remote.parts.filter { $0.isAttachment || $0.contentID != nil }.map { .init(id: UUID(), messageID: id, part: $0) })
    }
    public func loadOlder(_ mailboxID: UUID, batch: Int = 200) async throws {
        var box = try store.mailbox(mailboxID)
        if !box.initialSyncComplete { try await syncMailbox(mailboxID); box = try store.mailbox(mailboxID) }
        guard box.hasMore, box.highestKnownUID > 0 else { return }
        let transport = try await connection(box.accountID), account = try account(box.accountID)
        let selection = try await transport.select(box.name)
        guard selection.uidValidity == box.uidValidity else { try await syncMailbox(mailboxID); return }
        // Page down through every synced UID not stored yet, not only those below the oldest stored
        // one: the first sync takes mail by arrival date (an old message moved here today has a high
        // UID), and server search hits are stored wherever they fall.
        let stored = Set(try store.messages(mailboxID: mailboxID).map { $0.remote.uid })
        let uids = try await transport.search(.range(1...box.highestKnownUID), in: box.name).filter { !stored.contains($0) }.sorted(by: >)
        let page = Array(uids.prefix(max(1, batch)))
        let messages = try await transport.fetch(page, in: box.name, gmail: account.isGmail)
        _ = try store.mailbox(mailboxID)
        let existing = Set(try store.messages(mailboxID: mailboxID).map { $0.remote.uid })
        for message in messages where !existing.contains(message.uid) { try store.save(makeStored(message, mailbox: box)) }
        box.oldestLoadedUID = min(box.oldestLoadedUID ?? .max, page.min() ?? .max); box.hasMore = uids.count > page.count
        try store.save(box); try changed([mailboxID])
    }
    func startIdle(_ id: UUID, transport: any MailTransport) async throws {
        guard idleTasks[id] == nil, !idleStarting.contains(id), let inbox = try store.mailboxes(accountID: id).first(where: { $0.role == .inbox }) else { return }
        idleStarting.insert(id); defer { idleStarting.remove(id) }
        let generation = generations[id]
        let stream = try await transport.idle(in: inbox.name, renewalInterval: 600)
        // A reconnect while IDLE started has disconnected this transport, which ends its IDLE.
        guard generations[id] == generation else { return }
        idleTasks[id] = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .changed: await self?.coalesceInbox(id, mailboxID: inbox.id)
                case .disconnected(let error): await self?.failed(id, error, generation: generation); return
                }
            }
        }
    }
    func coalesceInbox(_ id: UUID, mailboxID: UUID) {
        guard coalescedTasks[id] == nil else { return }
        coalescedTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            await self?.syncInbox(id, mailboxID: mailboxID)
        }
    }
    func syncInbox(_ id: UUID, mailboxID: UUID) async {
        coalescedTasks[id] = nil
        do { try await syncMailbox(mailboxID) } catch { await failed(id, error) }
    }
    public func messageDetail(_ id: UUID) async throws -> MailMessageDetail {
        var value = try store.message(id)
        if value.bodyLoaded { return value.detail }
        let box = try store.mailbox(value.mailboxID), transport = try await connection(value.accountID)
        let body = try await transport.body(value.remote, in: box.name)
        value = try store.message(id)
        value.plainText = body.plainText; value.html = body.html; value.bodyLoaded = true
        for attachment in value.attachments {
            guard let cid = attachment.part.contentID, let data = body.inlineParts[attachment.part.section] else { continue }
            let url = try attachmentURL(attachment, accountID: value.accountID)
            try data.write(to: url, options: .atomic); value.inlineFiles[cid] = url
        }
        try store.save(value); try changed([box.id]); return value.detail
    }
    func attachmentURL(_ attachment: MailAttachment, accountID: UUID) throws -> URL {
        let folder = store.base.appendingPathComponent("Attachments").appendingPathComponent(accountID.uuidString).appendingPathComponent(attachment.messageID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(attachment.id.uuidString + "-" + URL(fileURLWithPath: attachment.filename).lastPathComponent)
    }
    public func attachmentFile(_ id: UUID) async throws -> URL {
        let records: [StoredMessage] = try store.decodeRows("SELECT payload FROM messages WHERE id=(SELECT message_id FROM attachments WHERE id=?)", [.text(id.uuidString)])
        guard let value = records.first(where: { $0.attachments.contains(where: { $0.id == id }) }), let attachment = value.attachments.first(where: { $0.id == id }) else { throw MailError.notFound }
        let url = try attachmentURL(attachment, accountID: value.accountID)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let box = try store.mailbox(value.mailboxID), transport = try await connection(value.accountID)
        let bytes = try await transport.attachment(attachment.part, uid: value.remote.uid, in: box.name)
        _ = try store.message(value.id); try bytes.write(to: url, options: .atomic); return url
    }
}
