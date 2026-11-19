import Foundation

extension MailEngine {
    public func search(_ query: String, scope: MailSearchScope = .all, limit: Int = 200) throws -> [MailMessageSummary] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // unicode61 keeps a run of Chinese, Japanese or Korean characters as one token, so a word
        // inside it never matches a prefix query: look those terms up as substrings.
        func isCJK(_ token: String) -> Bool {
            token.unicodeScalars.contains { scalar in [0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F].contains { $0.contains(scalar.value) } }
        }
        let words = tokens.filter { !isCJK($0) }, substrings = tokens.filter(isCJK)
        var sql = "SELECT m.payload FROM messages m JOIN message_search f ON f.id=m.id WHERE m.hidden=0"
        var bindings: [SQLValue] = []
        if !words.isEmpty {
            sql += " AND message_search MATCH ?"
            bindings.append(.text(words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")))
        }
        for text in substrings {
            sql += " AND (instr(f.subject,?)>0 OR instr(f.addresses,?)>0 OR instr(f.body,?)>0)"
            bindings += Array(repeating: .text(text), count: 3)
        }
        switch scope {
        case .all: break
        case .account(let id): sql += " AND m.account_id=?"; bindings.append(.text(id.uuidString))
        case .mailbox(let id): sql += " AND m.mailbox_id=?"; bindings.append(.text(id.uuidString))
        case .mailboxes(let ids):
            guard !ids.isEmpty else { return [] }
            sql += " AND m.mailbox_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            bindings += ids.map { .text($0.uuidString) }
        }
        sql += " ORDER BY m.date DESC,m.id DESC"
        let records: [StoredMessage] = try store.decodeRows(sql, bindings)
        return Array(deduplicate(records).prefix(max(0, limit)))
    }
    func deduplicate(_ records: [StoredMessage]) -> [MailMessageSummary] {
        var seen: Set<String> = []
        return records.filter {
            let key = $0.accountID.uuidString + ":" + ($0.remote.gmailMessageID ?? $0.remote.messageID ?? $0.id.uuidString)
            return seen.insert(key).inserted
        }.map(\.summary)
    }
    public func searchServer(_ query: String, mailbox mailboxID: UUID) async throws -> [MailMessageSummary] {
        let box = try store.mailbox(mailboxID), account = try account(box.accountID)
        let transport = try await connection(account.id)
        let selection = try await transport.select(box.name)
        if let validity = box.uidValidity, validity != selection.uidValidity { try await syncMailbox(mailboxID) }
        let current = try store.mailbox(mailboxID)
        let hits = try await transport.search(.text(query), in: box.name)
        let existing = try store.messages(mailboxID: mailboxID)
        let known = Set(existing.map { $0.remote.uid })
        let remote = try await transport.fetch(hits.filter { !known.contains($0) }, in: box.name, gmail: account.isGmail)
        _ = try store.mailbox(mailboxID)
        for value in remote { try store.save(makeStored(value, mailbox: current)) }
        try changed([mailboxID])
        let records = try store.messages(mailboxID: mailboxID).filter { hits.contains($0.remote.uid) }.sorted { $0.remote.date > $1.remote.date }
        return deduplicate(records)
    }
}
