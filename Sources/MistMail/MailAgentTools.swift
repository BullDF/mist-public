import Foundation
import MistMailCore

struct MailAgentToolError: Error { let message: String }

@MainActor
final class MailAgentTools {
    static let shared = MailAgentTools(source: EngineMailPageDataSource(engine: MistMailService.shared.engine), isOpenInCompose: { MistMailService.shared.isComposing(draftID: $0) })
    private let source: any MailPageDataSource
    private let timeZone: TimeZone
    private let isOpenInCompose: (UUID) -> Bool
    init(source: any MailPageDataSource, timeZone: TimeZone = .current, isOpenInCompose: @escaping (UUID) -> Bool = { _ in false }) { self.source = source; self.timeZone = timeZone; self.isOpenInCompose = isOpenInCompose }

    static func errorMessage(_ error: Error) -> String {
        if let error = error as? MailAgentToolError { return error.message }
        switch error as? MailError {
        case .authenticationFailed, .missingCredentials: return "Mail authentication failed. Check the account in Settings ▸ Mail."
        case .offline: return "Mist Mail is offline."
        case .cannotConnect: return "Mist Mail can't connect to the server."
        case .timeout: return "The mail server timed out."
        case .notFound: return "The message is gone. List or search again."
        case .storage(let message) where message == "Mail database unavailable": return "Mist Mail's database couldn't be opened."
        case let .some(value): return "Mail error: \(value)"
        default: return "Mail error: \(error)"
        }
    }
    private func snapshot() async throws -> MailPageSnapshot {
        let state = try await source.snapshot()
        guard !state.accounts.isEmpty else { throw MailAgentToolError(message: "No mail accounts are set up in Mist. Johnny adds them in Settings ▸ Mail.") }
        return state
    }
    private func selectable(_ box: Mailbox) -> Bool { !box.attributes.contains { $0.lowercased() == "\\noselect" } }
    private func account(_ value: String?, state: MailPageSnapshot) throws -> MailAccount? {
        guard let value else { return nil }
        let matches = state.accounts.filter { [$0.id.uuidString, $0.config.email, $0.config.displayName].contains { $0.caseInsensitiveCompare(value) == .orderedSame } }
        guard matches.count == 1 else { throw MailAgentToolError(message: "Unknown or ambiguous account. Accounts: " + state.accounts.map { "\($0.config.displayName) <\($0.config.email)>" }.joined(separator: ", ")) }
        return matches[0]
    }
    private func boxes(_ value: String, account: MailAccount?, state: MailPageSnapshot) throws -> (boxes: [Mailbox], role: MailboxRole?, name: String) {
        let available = state.mailboxes.filter { selectable($0) && (account == nil || $0.accountID == account?.id) }
        if let id = UUID(uuidString: value), let box = available.first(where: { $0.id == id }) { return ([box], nil, MailPresentation.mailboxName(box)) }
        let name = value.lowercased().hasPrefix("all:") ? String(value.dropFirst(4)) : value
        guard let role = MailboxRole(rawValue: name.lowercased()), role != .flagged else { throw MailAgentToolError(message: "Unknown mailbox. Call list_mail_accounts for mailbox IDs.") }
        let matches = available.filter { $0.role == role }
        let title = account != nil && matches.count == 1 ? MailPresentation.mailboxName(matches[0]) : (MailPresentation.unifiedRoles.contains(role) ? MailPresentation.unifiedTitle(role) : role.rawValue)
        return (matches, role, title)
    }
    private func address(_ value: MailAddress) -> String { value.name.flatMap { $0.isEmpty ? nil : "\($0) <\(value.email)>" } ?? value.email }
    private func date(_ value: Date) -> String { let f = ISO8601DateFormatter(); f.timeZone = timeZone; f.formatOptions = [.withInternetDateTime]; return f.string(from: value) }
    private func row(_ message: MailMessageSummary, state: MailPageSnapshot) -> [String: Any] {
        let recipients = message.recipients ?? []
        var to = recipients.prefix(3).map(address).joined(separator: ", ")
        if recipients.count > 3 { to += ", +\(recipients.count - 3) more" }
        var result: [String: Any] = ["id": message.id.uuidString, "account": state.accounts.first { $0.id == message.accountID }?.config.displayName ?? "", "mailbox": state.mailboxes.first { $0.id == message.mailboxID }.map(MailPresentation.mailboxName) ?? "", "from": message.sender.map(address).joined(separator: ", "), "to": to, "subject": message.subject, "date": date(message.date), "snippet": message.snippet]
        if !message.flags.contains(MailFlags.seen) { result["unread"] = true }
        if message.flags.contains(MailFlags.flagged) { result["flagged"] = true }
        if message.hasAttachments { result["attachments"] = true }
        return result
    }
    func accounts() async throws -> [String: Any] {
        let state = try await snapshot()
        let accounts: [[String: Any]] = state.accounts.map { account in
            let status: String
            switch state.statuses[account.id] { case .connected: status = "connected"; case .syncing: status = "syncing"; case .connecting: status = "connecting"; case .authFailed: status = "authFailed"; case .retrying: status = "retrying"; default: status = "disconnected" }
            let boxes: [[String: Any]] = state.mailboxes.filter { $0.accountID == account.id && selectable($0) }.map { box in
                var result: [String: Any] = ["id": box.id.uuidString, "name": MailPresentation.mailboxName(box), "unread": state.unread.mailboxes[box.id] ?? 0]
                if let role = box.role { result["role"] = role.rawValue }; return result
            }
            return ["id": account.id.uuidString, "name": account.config.displayName, "email": account.config.email, "status": status, "mailboxes": boxes]
        }
        let unified: [[String: Any]] = MailboxTreeNode.build(state).compactMap { node in
            guard let role = node.unifiedRole else { return nil }
            return ["id": "all:" + role.rawValue, "name": node.title, "unread": node.unreadCount(in: state)]
        }
        return ["accounts": accounts, "allMailboxes": unified]
    }
    func list(mailbox: String?, account accountName: String?, before: UUID?, limit: Int) async throws -> [String: Any] {
        let state = try await snapshot(), account = try account(accountName, state: state)
        let selection = try boxes(mailbox ?? "inbox", account: account, state: state)
        let cursor = try await before.mapAsync { MailMessageCursor(try await source.summary($0)) }
        var result: [String: Any] = ["mailbox": selection.name]
        if selection.boxes.isEmpty { result["messages"] = []; return result }
        if selection.boxes.count == 1, let box = selection.boxes.first, !box.autoSync {
            do { try await source.open(box.id) } catch { result["notice"] = Self.errorMessage(error) }
        }
        guard let scope: MailMessageScope = selection.boxes.count == 1 || account != nil ? .mailbox(selection.boxes[0].id) : selection.role.map({ .unifiedRole($0) }) else { result["messages"] = []; return result }
        var messages = try await source.messages(in: scope, before: cursor, limit: limit)
        if messages.count < limit {
            for box in selection.boxes where box.hasMore { do { try await source.loadOlder(box.id) } catch { result["notice"] = Self.errorMessage(error) } }
            messages = try await source.messages(in: scope, before: cursor, limit: limit)
        }
        result["messages"] = messages.map { row($0, state: state) }
        if messages.count == limit, let last = messages.last { result["next"] = last.id.uuidString }
        return result
    }
    func search(query: String, mailbox: String?, account accountName: String?, server: Bool, limit: Int) async throws -> [String: Any] {
        let state = try await snapshot(), account = try account(accountName, state: state)
        let available = state.mailboxes.filter { selectable($0) && (account == nil || $0.accountID == account?.id) }
        let scope = try mailbox.map { try boxes($0, account: account, state: state).boxes } ?? available
        var result: [String: Any] = ["query": query]
        if server {
            let targets: [Mailbox]
            if mailbox != nil { targets = scope } else {
                targets = state.accounts.filter { account == nil || $0.id == account?.id }.flatMap { account in
                    let own = available.filter { $0.accountID == account.id }
                    if let all = own.first(where: { $0.role == .all }) { return [all] }
                    return own.filter { [.inbox, .sent, .archive].contains($0.role) }
                }
            }
            for box in targets { do { try await source.searchServer(query, mailbox: box.id) } catch { result["notice"] = Self.errorMessage(error) } }
            result["searchedServer"] = true
        }
        result["messages"] = try await source.search(query, in: scope.map(\.id)).prefix(limit).map { row($0, state: state) }
        return result
    }
    func read(id: UUID, maxChars: Int) async throws -> [String: Any] {
        let state = try await snapshot()
        _ = try await source.summary(id)
        let detail = try await source.detail(id), message = detail.summary
        var result = row(message, state: state); result.removeValue(forKey: "snippet"); result.removeValue(forKey: "attachments")
        result["to"] = detail.headers.to.map(address)
        if !detail.headers.cc.isEmpty { result["cc"] = detail.headers.cc.map(address) }
        if !detail.headers.replyTo.isEmpty { result["replyTo"] = detail.headers.replyTo.map(address) }
        let body = detail.plainText ?? detail.html.map(MailText.readable) ?? ""
        result["body"] = String(body.prefix(maxChars)); if body.count > maxChars { result["truncated"] = true }
        var attachments: [[String: Any]] = []
        for item in detail.attachments {
            var entry: [String: Any] = ["name": item.filename, "type": item.part.mimeType, "size": item.part.size]
            do { entry["path"] = try await source.attachmentFile(item.id).path } catch { entry["error"] = Self.errorMessage(error) }
            attachments.append(entry)
        }
        result["attachments"] = attachments; return result
    }
    private func addresses(_ values: [String]) throws -> [MailAddress] {
        try values.flatMap { value in
            let parsed = MailComposeFormatting.addresses(value)
            guard !parsed.isEmpty, parsed.allSatisfy(MailComposeFormatting.isValid) else { throw MailAgentToolError(message: "Invalid address: \(value)") }
            return parsed
        }
    }
    private func checkedDraft(_ id: UUID, allowAccepted: Bool = false) async throws -> MailDraft {
        let draft = try await source.draft(id)
        guard allowAccepted || draft.acceptedMessage == nil else { throw MailAgentToolError(message: "This draft is being sent.") }
        guard !isOpenInCompose(id) else { throw MailAgentToolError(message: "Johnny has this draft open in Mail; ask him to close it first.") }
        return draft
    }
    private func buildDraft(_ input: [String: Any], state: MailPageSnapshot) async throws -> MailDraft {
        let reply = (input["replyTo"] as? String).flatMap(UUID.init(uuidString:))
        let forward = (input["forward"] as? String).flatMap(UUID.init(uuidString:))
        let draftID = (input["draftId"] as? String).flatMap(UUID.init(uuidString:))
        guard [reply, forward, draftID].compactMap({ $0 }).count <= 1,
              input["replyAll"] == nil || reply != nil,
              input["account"] == nil || (reply == nil && forward == nil && draftID == nil) else { throw MailAgentToolError(message: "Invalid draft arguments.") }
        var base: MailDraft
        // A revision without a body keeps the draft's own text and formatting, quote included.
        var keepsContent = false
        if let reply { base = try await source.replyDraft(to: reply, all: input["replyAll"] as? Bool ?? false) }
        else if let forward { base = try await source.forwardDraft(forward) }
        else if let draftID {
            let existing = try await checkedDraft(draftID)
            if input["body"] == nil { base = existing; keepsContent = true }
            else if let context = existing.replyContext {
                let quote = context.kind == .forward ? try await source.forwardDraft(context.sourceMessageID) : try await source.replyDraft(to: context.sourceMessageID, all: context.kind == .replyAll)
                base = MailDraft(id: existing.id, accountID: existing.accountID, to: existing.to, cc: existing.cc, bcc: existing.bcc, subject: existing.subject, plainText: quote.plainText, html: quote.html, attachments: quote.attachments.filter { $0.contentID != nil } + existing.attachments.filter { $0.contentID == nil }, replyContext: existing.replyContext)
            } else { base = existing; base.plainText = ""; base.html = nil }
        } else {
            let selected = try account(input["account"] as? String, state: state)
            guard let selected = selected ?? (state.accounts.count == 1 ? state.accounts.first : nil) else { throw MailAgentToolError(message: "Choose an account for this draft.") }
            base = MailDraft(accountID: selected.id)
        }
        if let values = input["to"] as? [String] { base.to = try addresses(values) }
        if let values = input["cc"] as? [String] { base.cc = try addresses(values) }
        if let values = input["bcc"] as? [String] { base.bcc = try addresses(values) }
        if let subject = input["subject"] as? String { base.subject = subject }
        if let paths = input["attachments"] as? [String] {
            if draftID != nil { base.attachments = base.attachments.filter { $0.contentID != nil } }
            base.attachments += paths.map { let url = URL(fileURLWithPath: $0); return MailDraftAttachment(filename: url.lastPathComponent, file: url) }
        }
        if !keepsContent {
            let body = input["body"] as? String ?? ""
            base.plainText = body + base.plainText
            base.html = MailComposeFormatting.document(html: base.html.map { MailComposeFormatting.plainHTML(body) + $0 }, plainText: base.plainText)
        }
        guard !base.isEmpty else { throw MailAgentToolError(message: "The draft is empty.") }
        return base
    }
    func writeDraft(_ input: [String: Any]) async throws -> [String: Any] {
        let state = try await snapshot(), value = try await buildDraft(input, state: state)
        if input["draftId"] != nil, isOpenInCompose(value.id) { throw MailAgentToolError(message: "Johnny has this draft open in Mail; ask him to close it first.") }
        let draft = try await source.saveDraft(value)
        let sender = state.accounts.first { $0.id == draft.accountID }
        var result: [String: Any] = ["draftId": draft.id.uuidString, "account": sender?.config.displayName ?? "", "from": sender?.config.email ?? "", "to": draft.to.map(address), "subject": draft.subject, "attachments": draft.attachments.filter { $0.contentID == nil }.map(\.filename), "savedToServer": true]
        if !draft.cc.isEmpty { result["cc"] = draft.cc.map(address) }; if !draft.bcc.isEmpty { result["bcc"] = draft.bcc.map(address) }
        do { try await source.flushDraft(draft.id) } catch { result["savedToServer"] = false; result["notice"] = Self.errorMessage(error) }
        return result
    }
    func send(_ input: [String: Any]) async throws -> [String: Any] {
        let state = try await snapshot()
        let existing = (input["draftId"] as? String).flatMap(UUID.init(uuidString:))
        guard existing == nil || input.count == 1 else { throw MailAgentToolError(message: "Send a draft by itself or provide a fresh message.") }
        let draft: MailDraft
        if let existing { draft = try await checkedDraft(existing, allowAccepted: true) }
        else { guard let to = input["to"] as? [String], !to.isEmpty else { throw MailAgentToolError(message: "Add at least one recipient.") }; draft = try await buildDraft(input, state: state) }
        let recipients = draft.to + draft.cc + draft.bcc
        guard !recipients.isEmpty else { throw MailAgentToolError(message: "Add at least one recipient.") }
        for item in recipients where !MailComposeFormatting.isValid(item) { throw MailAgentToolError(message: "Invalid address: \(address(item))") }
        let saved = existing == nil ? try await source.saveDraft(draft) : draft
        if existing != nil, isOpenInCompose(saved.id) { throw MailAgentToolError(message: "Johnny has this draft open in Mail; ask him to close it first.") }
        do { try await source.send(saved.id) } catch { throw MailAgentToolError(message: "\(Self.errorMessage(error)) Draft ID: \(saved.id.uuidString)") }
        return ["sent": true, "account": state.accounts.first { $0.id == saved.accountID }?.config.displayName ?? "", "to": saved.to.map(address), "subject": saved.subject]
    }
    func update(ids: [String], action: String, mailbox: String?) async throws -> [String: Any] {
        guard (1...100).contains(ids.count), ["read", "unread", "flag", "unflag", "archive", "move", "trash"].contains(action), (action == "move") == (mailbox != nil) else { throw MailAgentToolError(message: "Invalid update arguments.") }
        let state = try await snapshot()
        var done: [String] = [], failed: [[String: String]] = []
        for value in ids {
            do {
                guard let id = UUID(uuidString: value) else { throw MailError.notFound }
                let message = try await source.summary(id)
                switch action {
                case "read": _ = try await source.perform(.seen(true), on: id)
                case "unread": _ = try await source.perform(.seen(false), on: id)
                case "flag": _ = try await source.perform(.flagged(true), on: id)
                case "unflag": _ = try await source.perform(.flagged(false), on: id)
                case "archive": guard await source.canArchive(id) else { throw MailError.unsupported }; _ = try await source.perform(.archive, on: id)
                case "trash": _ = try await source.trash(id)
                case "move":
                    guard let mailbox, let owner = state.accounts.first(where: { $0.id == message.accountID }), let target = try boxes(mailbox, account: owner, state: state).boxes.first else { throw MailError.unsupported }
                    _ = try await source.perform(.move(target.id), on: id)
                default: throw MailError.unsupported
                }
                done.append(value)
            } catch { failed.append(["id": value, "error": Self.errorMessage(error)]) }
        }
        var result: [String: Any] = ["done": done, "failed": failed]
        if ["archive", "move", "trash"].contains(action) { result["note"] = "Moved messages get new IDs; search again to find them." }
        return result
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
