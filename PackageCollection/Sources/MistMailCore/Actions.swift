import Foundation

enum PendingMailAction: Codable, Equatable {
    case flag(String, Bool), markAllSeen(throughUID: UInt32), move(UUID), delete

    var flagChange: (String, Bool)? {
        switch self {
        case .flag(let flag, let value): return (flag, value)
        case .markAllSeen: return (MailFlags.seen, true)
        case .move, .delete: return nil
        }
    }
}
struct PendingMailOperation: Codable {
    var id: UUID
    var accountID: UUID
    var mailboxID: UUID
    var uidValidity: UInt32?
    var action: PendingMailAction
    var before: [StoredMessage]
    func apply(to message: inout StoredMessage) {
        guard before.contains(where: { $0.id == message.id }) else { return }
        switch action {
        case .flag(let flag, let value): if value { message.remote.flags.insert(flag) } else { message.remote.flags.remove(flag) }
        case .markAllSeen: message.remote.flags.insert(MailFlags.seen)
        case .move, .delete: message.hidden = true
        }
    }
}

extension MailEngine {
    @discardableResult
    public func markAllRead(_ mailboxIDs: [UUID]) throws -> [UUID] {
        var ids: [UUID] = []
        for mailboxID in Set(mailboxIDs) {
            let box = try store.mailbox(mailboxID)
            guard box.highestKnownUID > 0 else { continue }
            let unread = try store.messages(mailboxID: mailboxID).filter {
                !$0.hidden && !$0.remote.flags.contains(MailFlags.seen) && $0.remote.uid <= box.highestKnownUID
            }
            var before = Dictionary(uniqueKeysWithValues: unread.map { ($0.id, $0) })
            for message in unread {
                if let gmail = message.remote.gmailMessageID {
                    for copy in try store.matchingGmail(gmail, accountID: box.accountID) { before[copy.id] = copy }
                }
            }
            let operation = PendingMailOperation(id: UUID(), accountID: box.accountID, mailboxID: box.id,
                uidValidity: box.uidValidity, action: .markAllSeen(throughUID: box.highestKnownUID), before: Array(before.values))
            ids.append(try enqueue(operation))
        }
        return ids
    }
    @discardableResult
    public func setSeen(_ messageID: UUID, _ value: Bool) throws -> UUID { try enqueue(messageID, action: .flag(MailFlags.seen, value)) }
    @discardableResult
    public func setFlagged(_ messageID: UUID, _ value: Bool) throws -> UUID { try enqueue(messageID, action: .flag(MailFlags.flagged, value)) }
    @discardableResult
    public func move(_ messageID: UUID, to mailboxID: UUID) throws -> UUID {
        let message = try store.message(messageID), destination = try store.mailbox(mailboxID)
        guard destination.accountID == message.accountID, destination.id != message.mailboxID else { throw MailError.unsupported }
        return try enqueue(messageID, action: .move(mailboxID))
    }
    @discardableResult
    public func archive(_ messageID: UUID) async throws -> UUID {
        guard try canArchive(messageID) else { throw MailError.unsupported }
        let message = try store.message(messageID), box = try store.mailbox(message.mailboxID), account = try account(message.accountID)
        if account.isGmail {
            guard box.role == .inbox, let all = try store.mailboxes(accountID: account.id).first(where: { $0.role == .all }) else { throw MailError.unsupported }
            return try move(messageID, to: all.id)
        }
        // The mailbox can be represented locally offline; CREATE is replayed with the move.
        let archive = try ensureLocalMailbox(accountID: account.id, role: .archive, name: "Archive")
        return try move(messageID, to: archive.id)
    }
    /// Same eligibility as archive, without creating a mailbox or enqueuing an action.
    public func canArchive(_ messageID: UUID) throws -> Bool {
        let message = try store.message(messageID), box = try store.mailbox(message.mailboxID), account = try account(message.accountID)
        let boxes = try store.mailboxes(accountID: account.id)
        if account.isGmail { return box.role == .inbox && boxes.contains { $0.role == .all } }
        return boxes.first(where: { $0.role == .archive })?.id != box.id
    }
    @discardableResult
    public func trash(_ messageID: UUID) throws -> UUID {
        let message = try store.message(messageID), box = try store.mailbox(message.mailboxID)
        guard box.role != .trash, let trash = try store.mailboxes(accountID: message.accountID).first(where: { $0.role == .trash }) else { throw MailError.unsupported }
        return try move(messageID, to: trash.id)
    }
    @discardableResult
    public func delete(_ messageID: UUID) throws -> UUID {
        let message = try store.message(messageID), box = try store.mailbox(message.mailboxID)
        if box.role != .trash, let trash = try store.mailboxes(accountID: message.accountID).first(where: { $0.role == .trash }) {
            return try move(messageID, to: trash.id)
        }
        return try enqueue(messageID, action: .delete)
    }
    func ensureLocalMailbox(accountID: UUID, role: MailboxRole, name: String) throws -> Mailbox {
        if let box = try store.mailboxes(accountID: accountID).first(where: { $0.role == role }) { return box }
        var box = Mailbox(accountID: accountID, name: name, role: role)
        box.needsCreation = true
        try store.save(box); emit(.mailboxesChanged(accountID)); return box
    }
    func enqueue(_ messageID: UUID, action: PendingMailAction) throws -> UUID {
        let message = try store.message(messageID), box = try store.mailbox(message.mailboxID)
        var before = [message]
        if case .flag = action, let gmail = message.remote.gmailMessageID {
            before = try store.matchingGmail(gmail, accountID: message.accountID)
        }
        let operation = PendingMailOperation(id: UUID(), accountID: message.accountID, mailboxID: box.id, uidValidity: box.uidValidity, action: action, before: before)
        return try enqueue(operation)
    }
    func enqueue(_ operation: PendingMailOperation) throws -> UUID {
        // Pending state and its optimistic view become durable together.
        try store.db.transaction {
            try store.savePending(operation, id: operation.id, accountID: operation.accountID)
            for var item in operation.before { operation.apply(to: &item); try store.saveWithoutTransaction(item) }
        }
        try changed(Set(operation.before.map(\.mailboxID)).union([operation.mailboxID]))
        if online { Task { try? await self.replayPending(accountID: operation.accountID) } }
        return operation.id
    }
    public func flushPending(accountID: UUID) async throws { try await replayPending(accountID: accountID) }
    func replayPending(accountID: UUID) async throws {
        if let task = replayTasks[accountID] { return try await task.value }
        let task = Task { try await self.performReplay(accountID: accountID) }
        replayTasks[accountID] = task
        defer { replayTasks[accountID] = nil }
        try await task.value
    }
    func performReplay(accountID: UUID) async throws {
        do {
            let transport = try await connection(accountID)
            while let operation: PendingMailOperation = try store.pending(accountID: accountID).first {
                do {
                    let box = try store.mailbox(operation.mailboxID)
                    let selected = try await transport.select(box.name)
                    guard operation.uidValidity == nil || selected.uidValidity == operation.uidValidity else { throw MailError.notFound }
                    let source = operation.before.filter { $0.mailboxID == box.id }
                    let uids = source.map { $0.remote.uid }
                    switch operation.action {
                    case .flag(let flag, let value): try await transport.setFlag(flag, value: value, uids: uids, in: box.name)
                    case .markAllSeen(let throughUID):
                        try await transport.setFlag(MailFlags.seen, value: true, range: 1...throughUID, in: box.name)
                    case .delete:
                        try await transport.delete(uids, in: box.name)
                        for item in source { try store.deleteMessage(item.id) }
                    case .move(let destinationID):
                        var destination = try store.mailbox(destinationID)
                        let remoteBoxes = try await transport.listMailboxes()
                        if !remoteBoxes.contains(where: { $0.name == destination.name }) { try await transport.createMailbox(destination.name) }
                        destination.needsCreation = false; try store.save(destination)
                        let result = try await transport.move(uids, from: box.name, to: destination.name)
                        _ = try account(accountID)
                        if let result {
                            if let validity = destination.uidValidity, validity != result.uidValidity { try store.resetMailbox(destination.id) }
                            destination.uidValidity = result.uidValidity; try store.save(destination)
                            let existing = Set(try store.messages(mailboxID: destination.id).map { $0.remote.uid })
                            for item in source {
                                if let uid = result.uids[item.remote.uid], !existing.contains(uid) {
                                    var copy = makeStored(item.remote, mailbox: destination); copy.remote.uid = uid
                                    copy.plainText = item.plainText; copy.html = item.html; copy.bodyLoaded = item.bodyLoaded && item.inlineFiles.isEmpty
                                    try store.save(copy)
                                }
                            }
                            try changed([destination.id])
                        }
                        for item in source { try store.deleteMessage(item.id) }
                    }
                    try store.deletePending(operation.id); try changed(Set(operation.before.map(\.mailboxID)))
                } catch {
                    let failure = error as? MailError ?? .cannotConnect
                    if failure.isPermanent { try rollback(operation); emit(.actionFailed(operationID: operation.id, error: failure)) }
                    else { throw error }
                }
            }
        } catch { await failed(accountID, error); throw error }
    }
    func rollback(_ operation: PendingMailOperation) throws {
        let pending: [PendingMailOperation] = try store.pending(accountID: operation.accountID)
        var later = Array(pending.drop(while: { $0.id != operation.id }).dropFirst())
        for original in operation.before {
            guard var current = try? store.message(original.id) else { continue }
            if let (flag, _) = operation.action.flagChange {
                if original.remote.flags.contains(flag) { current.remote.flags.insert(flag) } else { current.remote.flags.remove(flag) }
            } else { current.hidden = original.hidden }
            // Later snapshots were taken over this failed optimistic change. Rebase
            // their rollback values too, so two refused toggles restore the server state.
            for index in later.indices {
                for beforeIndex in later[index].before.indices where later[index].before[beforeIndex].id == original.id {
                    if let (flag, _) = operation.action.flagChange {
                        if current.remote.flags.contains(flag) { later[index].before[beforeIndex].remote.flags.insert(flag) }
                        else { later[index].before[beforeIndex].remote.flags.remove(flag) }
                    } else { later[index].before[beforeIndex].hidden = current.hidden }
                }
                later[index].apply(to: &current)
            }
            try store.save(current)
        }
        for value in later { try store.savePending(value, id: value.id, accountID: value.accountID) }
        try store.deletePending(operation.id); try changed(Set(operation.before.map(\.mailboxID)))
    }
    func invalidatePending(mailboxID: UUID) throws {
        let box = try store.mailbox(mailboxID)
        let operations: [PendingMailOperation] = try store.pending(accountID: box.accountID)
        for operation in operations where operation.mailboxID == mailboxID {
            try store.deletePending(operation.id); emit(.actionFailed(operationID: operation.id, error: .notFound))
        }
    }
}
