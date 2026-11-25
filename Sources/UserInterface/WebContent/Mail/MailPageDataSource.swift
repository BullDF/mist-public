import Foundation
import MistMailCore

struct MailPageSnapshot {
    var accounts: [MailAccount]
    var mailboxes: [Mailbox]
    var statuses: [UUID: MailAccountStatus]
    var unread: MailUnreadCounts
}

enum MailPageAction {
    case seen(Bool), flagged(Bool), archive, delete, move(UUID)
    var title: String {
        switch self {
        case .seen(true): MailStrings.markRead
        case .seen(false): MailStrings.markUnread
        case .flagged(true): MailStrings.flag
        case .flagged(false): MailStrings.unflag
        case .archive: MailStrings.archive
        case .delete: MailStrings.delete
        case .move: MailStrings.move
        }
    }
    var removesMessage: Bool {
        switch self { case .archive, .delete, .move: true; default: false }
    }
}

@MainActor
protocol MailPageDataSource: AnyObject {
    func snapshot() async throws -> MailPageSnapshot
    func summary(_ id: UUID) async throws -> MailMessageSummary
    func messages(in scope: MailMessageScope, before: MailMessageCursor?, limit: Int) async throws -> [MailMessageSummary]
    func search(_ query: String, in mailboxIDs: [UUID]) async throws -> [MailMessageSummary]
    func searchServer(_ query: String, mailbox: UUID) async throws
    func markAllRead(_ mailboxIDs: [UUID]) async throws -> [UUID]
    func detail(_ id: UUID) async throws -> MailMessageDetail
    func attachmentFile(_ id: UUID) async throws -> URL
    func open(_ mailbox: UUID) async throws
    func refresh(_ mailboxes: [UUID]) async throws
    func loadOlder(_ mailbox: UUID) async throws
    func perform(_ action: MailPageAction, on id: UUID) async throws -> UUID
    func undo(_ operationIDs: [UUID]) async throws -> MailUndoResult
    func cancelPendingUndoMove(_ operationID: UUID) async throws -> Bool
    func currentSummary(_ id: UUID) async throws -> MailMessageSummary
    func canArchive(_ id: UUID) async -> Bool
    func trash(_ id: UUID) async throws -> UUID
    func drafts() async throws -> [MailDraft]
    func draft(_ id: UUID) async throws -> MailDraft
    func saveDraft(_ draft: MailDraft) async throws -> MailDraft
    func flushDraft(_ id: UUID) async throws
    func discardDraft(_ id: UUID) async throws
    func send(_ id: UUID) async throws
    func replyDraft(to id: UUID, all: Bool) async throws -> MailDraft
    func forwardDraft(_ id: UUID) async throws -> MailDraft
    func editDraft(fromMessage id: UUID) async throws -> MailDraft
    func addressSuggestions() async throws -> [MailAddressSuggestion]
    func events() async -> AsyncStream<MailEvent>
}

@MainActor
final class EngineMailPageDataSource: MailPageDataSource {
    private let engine: MailEngine?
    init(engine: MailEngine?) { self.engine = engine }
    private func requireEngine() throws -> MailEngine {
        guard let engine else { throw MailError.storage("Mail database unavailable") }
        return engine
    }
    func snapshot() async throws -> MailPageSnapshot {
        let engine = try requireEngine()
        return try await MailPageSnapshot(accounts: engine.accounts(), mailboxes: engine.mailboxes(), statuses: engine.accountStatuses(), unread: engine.unreadCounts())
    }
    func summary(_ id: UUID) async throws -> MailMessageSummary { try await requireEngine().summary(id) }
    func messages(in scope: MailMessageScope, before: MailMessageCursor?, limit: Int) async throws -> [MailMessageSummary] {
        try await requireEngine().messages(in: scope, before: before, limit: limit)
    }
    func detail(_ id: UUID) async throws -> MailMessageDetail { try await requireEngine().messageDetail(id) }
    func search(_ query: String, in mailboxIDs: [UUID]) async throws -> [MailMessageSummary] {
        try await requireEngine().search(query, scope: .mailboxes(mailboxIDs), limit: 200)
    }
    func searchServer(_ query: String, mailbox: UUID) async throws { _ = try await requireEngine().searchServer(query, mailbox: mailbox) }
    func markAllRead(_ mailboxIDs: [UUID]) async throws -> [UUID] { try await requireEngine().markAllRead(mailboxIDs) }
    func attachmentFile(_ id: UUID) async throws -> URL { try await requireEngine().attachmentFile(id) }
    func open(_ mailbox: UUID) async throws { try await requireEngine().open(mailbox) }
    func refresh(_ mailboxes: [UUID]) async throws {
        let engine = try requireEngine()
        for id in mailboxes { try await engine.refresh(mailboxID: id) }
    }
    func loadOlder(_ mailbox: UUID) async throws { try await requireEngine().loadOlder(mailbox) }
    func perform(_ action: MailPageAction, on id: UUID) async throws -> UUID {
        let engine = try requireEngine()
        switch action {
        case .seen(let value): return try await engine.setSeen(id, value)
        case .flagged(let value): return try await engine.setFlagged(id, value)
        case .archive: return try await engine.archive(id)
        case .delete: return try await engine.delete(id)
        case .move(let box): return try await engine.move(id, to: box)
        }
    }
    func undo(_ operationIDs: [UUID]) async throws -> MailUndoResult {
        let engine = try requireEngine()
        var result = MailUndoResult()
        for id in operationIDs.reversed() {
            let undone = try await engine.undo(id)
            result.operationIDs += undone.operationIDs
            result.messageIDs += undone.messageIDs
        }
        return result
    }
    func cancelPendingUndoMove(_ operationID: UUID) async throws -> Bool {
        try await requireEngine().cancelPendingUndoMove(operationID)
    }
    func currentSummary(_ id: UUID) async throws -> MailMessageSummary {
        let engine = try requireEngine()
        guard let current = try await engine.resolveCurrentMessageID(id) else { throw MailError.notFound }
        return try await engine.summary(current)
    }
    func canArchive(_ id: UUID) async -> Bool {
        (try? await requireEngine().canArchive(id)) ?? false
    }
    func trash(_ id: UUID) async throws -> UUID { try await requireEngine().trash(id) }
    func drafts() async throws -> [MailDraft] { try await requireEngine().drafts() }
    func events() async -> AsyncStream<MailEvent> {
        guard let engine else { return AsyncStream { $0.finish() } }
        return await engine.events()
    }
    func draft(_ id: UUID) async throws -> MailDraft { try await requireEngine().draft(id) }
    func saveDraft(_ draft: MailDraft) async throws -> MailDraft { try await requireEngine().saveDraft(draft) }
    func flushDraft(_ id: UUID) async throws { try await requireEngine().flushDraft(id) }
    func discardDraft(_ id: UUID) async throws { try await requireEngine().discardDraft(id) }
    func send(_ id: UUID) async throws { try await requireEngine().send(id) }
    func replyDraft(to id: UUID, all: Bool) async throws -> MailDraft { try await requireEngine().replyDraft(to: id, all: all, quoteIntro: MailStrings.quoteIntro) }
    func forwardDraft(_ id: UUID) async throws -> MailDraft { try await requireEngine().forwardDraft(id, quoteIntro: MailStrings.quoteIntro) }
    func editDraft(fromMessage id: UUID) async throws -> MailDraft { try await requireEngine().editDraft(fromMessage: id) }
    func addressSuggestions() async throws -> [MailAddressSuggestion] { try await requireEngine().addressSuggestions() }
}
