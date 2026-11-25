import Foundation

public struct MailUndoResult: Sendable {
    public var operationIDs: [UUID]
    public var messageIDs: [UUID]

    public init(operationIDs: [UUID] = [], messageIDs: [UUID] = []) {
        self.operationIDs = operationIDs
        self.messageIDs = messageIDs
    }
}

struct UnmappedMailMove {
    let destination: UUID
    let messageID: String
}

extension MailEngine {
    public func currentMessageID(_ id: UUID) -> UUID? {
        (try? store.message(latestMappedID(id)))?.id
    }

    public func resolveCurrentMessageID(_ id: UUID) async throws -> UUID? {
        let current = latestMappedID(id)
        if let message = try? store.message(current) { return message.id }
        guard let move = movesWithoutCopyUID[current] else { return nil }
        let copy = try await findCopy(of: move.messageID, in: move.destination)
        if let next = movedTo[current] { return try await resolveCurrentMessageID(next) }
        guard let copy else { return nil }
        movesWithoutCopyUID.removeValue(forKey: current)
        movedTo[current] = copy
        return copy
    }

    private func latestMappedID(_ id: UUID) -> UUID {
        var current = id
        while let next = movedTo[current] { current = next }
        return current
    }

    public func undo(_ operationID: UUID) async throws -> MailUndoResult {
        guard undoingOperations.insert(operationID).inserted else { throw MailError.unsupported }
        defer { undoingOperations.remove(operationID) }
        if let pending = try await pendingAfterReplay(operationID) {
            guard pending.action != .delete, !inFlightOperations.contains(operationID) else { throw MailError.unsupported }
            try rollback(pending)
            return MailUndoResult(messageIDs: pending.before.map(\.id))
        }
        guard let operation = replayedOperations[operationID] else { throw MailError.notFound }
        var result = MailUndoResult()
        var inverseMoves: [(copy: UUID, destination: UUID)] = []
        switch operation.action {
        case .delete:
            throw MailError.unsupported
        case .flag(let flag, _):
            // Gmail copies share their flags. Replay one inverse per logical message.
            var gmailMessages: Set<String> = []
            let primary = operation.before.filter { $0.mailboxID == operation.mailboxID }
            let other = operation.before.filter { $0.mailboxID != operation.mailboxID }
            for original in primary + other {
                guard let id = currentMessageID(original.id) else { continue }
                result.messageIDs.append(id)
                let message = try store.message(id)
                if let gmailID = message.remote.gmailMessageID, !gmailMessages.insert(gmailID).inserted { continue }
                result.operationIDs.append(try enqueue(id, action: .flag(flag, original.flags.contains(flag))))
            }
        case .markAllSeen:
            let messages = try Set(operation.before.filter { !$0.flags.contains(MailFlags.seen) }
                .compactMap { currentMessageID($0.id) }).map { try store.message($0) }
            result.messageIDs = messages.map(\.id)
            for (mailboxID, before) in Dictionary(grouping: messages, by: \.mailboxID) {
                let box = try store.mailbox(mailboxID)
                let inverse = PendingMailOperation(id: UUID(), accountID: box.accountID, mailboxID: mailboxID,
                    uidValidity: box.uidValidity, action: .flag(MailFlags.seen, false), before: before)
                result.operationIDs.append(try enqueue(inverse))
            }
        case .move:
            for original in operation.before {
                guard let id = try await resolveCurrentMessageID(original.id) else { throw MailError.notFound }
                inverseMoves.append((id, original.mailboxID))
            }
            for (copy, destination) in inverseMoves {
                result.operationIDs.append(try move(copy, to: destination))
            }
        }
        if online { try? await replayPending(accountID: operation.accountID) }
        for (copy, _) in inverseMoves {
            result.messageIDs.append((try? await resolveCurrentMessageID(copy)) ?? copy)
        }
        result.messageIDs = result.messageIDs.map { currentMessageID($0) ?? $0 }
        return result
    }

    /// Redoing an undo move that never reached the server leaves the original move in effect.
    public func cancelPendingUndoMove(_ operationID: UUID) async throws -> Bool {
        guard let pending = try await pendingAfterReplay(operationID), case .move = pending.action,
              !inFlightOperations.contains(operationID) else { return false }
        try rollback(pending)
        return true
    }

    private func pendingAfterReplay(_ id: UUID) async throws -> PendingMailOperation? {
        while let pending = try store.pendingOperation(id), inFlightOperations.contains(id) {
            guard let task = replayTasks[pending.accountID] else { break }
            _ = try? await task.value
        }
        return try store.pendingOperation(id)
    }

    private func findCopy(of messageID: String, in mailboxID: UUID) async throws -> UUID? {
        try await refresh(mailboxID: mailboxID)
        var matches = try store.messages(mailboxID: mailboxID).filter { !$0.hidden && $0.remote.messageID == messageID }
        if matches.isEmpty {
            // A first sync only loads recent mail. An older message can still be moved here.
            let box = try store.mailbox(mailboxID), account = try account(box.accountID)
            let transport = try await connection(account.id)
            let uids = try await transport.search(.header("Message-ID", messageID), in: box.name)
            let remote = try await transport.fetch(uids, in: box.name, gmail: account.isGmail)
            let existing = try store.messages(mailboxID: mailboxID)
            for item in remote where item.messageID == messageID && !existing.contains(where: { $0.remote.uid == item.uid }) {
                let copy = makeStored(item, mailbox: box)
                try store.save(copy)
                matches.append(copy)
            }
            if !matches.isEmpty { try changed([mailboxID]) }
        }
        return matches.count == 1 ? matches.first?.id : nil
    }
}
