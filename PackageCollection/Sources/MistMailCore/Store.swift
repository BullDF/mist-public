import Foundation

struct StoredMessage: Codable, Equatable {
    var id: UUID
    var accountID: UUID
    var mailboxID: UUID
    var remote: MailRemoteMessage
    var plainText: String?
    var html: String?
    var bodyLoaded = false
    var attachments: [MailAttachment] = []
    var inlineFiles: [String: URL] = [:]
    var hidden = false
    var summary: MailMessageSummary {
        .init(id: id, accountID: accountID, mailboxID: mailboxID, sender: remote.from, recipients: remote.to, subject: remote.subject,
              snippet: String(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(200)), date: remote.date,
              flags: remote.flags, hasAttachments: remote.parts.contains { $0.isAttachment }, uid: remote.uid,
              gmailMessageID: remote.gmailMessageID)
    }
    var detail: MailMessageDetail {
        .init(summary: summary, headers: remote, plainText: html == nil ? plainText : plainPart, html: html, attachments: attachments, inlineFiles: inlineFiles)
    }
    /// The message's text, for its snippet and search.
    var text: String { plainPart ?? MailText.plain(html ?? plainText ?? "") }
    /// The plain part, unless it's HTML source: some senders put their HTML in the plain part too.
    private var plainPart: String? { plainText.flatMap { MailText.isHTMLDocument($0) ? nil : $0 } }
}

public enum MailText {
    public static func readable(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(head|style|script)\\b[^>]*>.*?</\\1\\s*>|<!--.*?-->", with: "", options: .regularExpression)
        let links = try! NSRegularExpression(pattern: "(?is)<a\\b[^>]*\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))[^>]*>(.*?)</a\\s*>")
        let original = text as NSString
        for match in links.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let urlRange = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let url = original.substring(with: urlRange)
            let label = original.substring(with: match.range(at: 4))
            let visible = label.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = (url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("mailto:")) && visible != url ? " (\(url))" : ""
            if let range = Range(match.range, in: text) { text.replaceSubrange(range, with: label + suffix) }
        }
        text = text.replacingOccurrences(of: "(?i)<br\\b[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<li\\b[^>]*>", with: "\n• ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(p|div|tr|li|h[1-6]|blockquote|table|ul|ol)\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = try! NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|nbsp|lt|gt|quot|amp|apos);", options: .caseInsensitive)
        let entitySource = text as NSString
        for match in entities.matches(in: text, range: NSRange(location: 0, length: entitySource.length)).reversed() {
            let key = entitySource.substring(with: match.range(at: 1)).lowercased()
            let named = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "amp": "&", "apos": "'"]
            var replacement = named[key]
            if key.hasPrefix("#") {
                let hex = key.hasPrefix("#x")
                let digits = String(key.dropFirst(hex ? 2 : 1))
                if let number = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) { replacement = String(scalar) }
            }
            if let replacement, let range = Range(match.range, in: text) { text.replaceSubrange(range, with: replacement) }
        }
        return text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func isHTMLDocument(_ text: String) -> Bool {
        text.range(of: "^\\s*<(!doctype\\s+html|html)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func plain(_ text: String) -> String {
        // Drop markup whose contents aren't text: <head> (with <title>), <style>, <script>, and
        // comments (Outlook's conditional CSS), or a snippet starts with "@font-face {…".
        text.replacingOccurrences(of: "(?is)<(head|style|script)\\b[^>]*>.*?</\\1\\s*>|<!--.*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MailStore {
    let base: URL
    let db: MailSQLite
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(base: URL) throws {
        self.base = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        db = try MailSQLite(url: base.appendingPathComponent("mail.sqlite"))
        let version = try db.rows("PRAGMA user_version").first?["user_version"]?.int ?? 0
        guard version <= 2 else { throw MailError.storage("Mail database is newer than this engine") }
        if version == 0 {
            try db.transaction {
                try db.execute("CREATE TABLE accounts (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                try db.execute("CREATE TABLE mailboxes (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(account_id,name))")
                try db.execute("CREATE TABLE messages (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, mailbox_id TEXT NOT NULL REFERENCES mailboxes(id) ON DELETE CASCADE, uid INTEGER NOT NULL, date REAL NOT NULL, gm_msgid TEXT, message_id TEXT, hidden INTEGER NOT NULL, seen INTEGER NOT NULL, payload BLOB NOT NULL, UNIQUE(mailbox_id,uid))")
                try db.execute("CREATE INDEX messages_order ON messages(mailbox_id,date DESC,id DESC)")
                try db.execute("CREATE INDEX messages_gmail ON messages(account_id,gm_msgid)")
                try db.execute("CREATE VIRTUAL TABLE message_search USING fts5(id UNINDEXED, subject, addresses, body, tokenize='unicode61 remove_diacritics 2')")
                try db.execute("CREATE TRIGGER messages_delete_search AFTER DELETE ON messages BEGIN DELETE FROM message_search WHERE id=old.id; END")
                try db.execute("CREATE TABLE drafts (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, payload BLOB NOT NULL)")
                try db.execute("CREATE TABLE pending (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, created REAL NOT NULL, payload BLOB NOT NULL)")
                try db.execute("PRAGMA user_version=1")
            }
        }
        if version < 2 {
            try db.transaction {
                // Preserve databases created by the engine before app lifecycle wiring.
                let defaults: [(String, [String: Any])] = [
                    ("mailboxes", ["highestKnownUID": 0, "needsCreation": false]),
                    ("drafts", ["revision": 0, "sentCopyFiled": false])]
                for (table, values) in defaults {
                    for row in try db.rows("SELECT id,payload FROM \(table)") {
                        guard let id = row["id"]?.string, let data = row["payload"]?.data,
                              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailError.storage("Invalid mail migration record") }
                        for (key, value) in values where object[key] == nil { object[key] = value }
                        try db.execute("UPDATE \(table) SET payload=? WHERE id=?", [.blob(try JSONSerialization.data(withJSONObject: object)), .text(id)])
                    }
                }
                try db.execute("CREATE TABLE attachments (id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE)")
                let messages: [StoredMessage] = try decodeRows("SELECT payload FROM messages")
                for message in messages {
                    for attachment in message.attachments { try db.execute("INSERT INTO attachments VALUES (?,?)", [.text(attachment.id.uuidString), .text(message.id.uuidString)]) }
                }
                try db.execute("PRAGMA user_version=2")
            }
        }
        for directory in ["Attachments", "DraftAttachments"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
    }
    func save(_ account: MailAccount) throws {
        try db.execute("INSERT INTO accounts VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.text(account.id.uuidString), .blob(try encoder.encode(account))])
    }
    func accounts() throws -> [MailAccount] { try decodeRows("SELECT payload FROM accounts").sorted { ($0.config.sortOrder, $0.id.uuidString) < ($1.config.sortOrder, $1.id.uuidString) } }
    func save(_ mailbox: Mailbox) throws {
        try db.execute("INSERT INTO mailboxes VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,payload=excluded.payload", [.text(mailbox.id.uuidString), .text(mailbox.accountID.uuidString), .text(mailbox.name), .blob(try encoder.encode(mailbox))])
    }
    func mailboxes(accountID: UUID? = nil) throws -> [Mailbox] {
        try decodeRows("SELECT payload FROM mailboxes" + (accountID == nil ? "" : " WHERE account_id=?"), accountID.map { [.text($0.uuidString)] } ?? [])
    }
    func mailbox(_ id: UUID) throws -> Mailbox {
        guard let box: Mailbox = try decodeRows("SELECT payload FROM mailboxes WHERE id=?", [.text(id.uuidString)]).first else { throw MailError.notFound }; return box
    }
    func save(_ message: StoredMessage) throws {
        try db.transaction { try saveWithoutTransaction(message) }
    }
    func saveWithoutTransaction(_ message: StoredMessage) throws {
            try db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET uid=excluded.uid,date=excluded.date,gm_msgid=excluded.gm_msgid,message_id=excluded.message_id,hidden=excluded.hidden,seen=excluded.seen,payload=excluded.payload", [
                .text(message.id.uuidString), .text(message.accountID.uuidString), .text(message.mailboxID.uuidString), .integer(Int64(message.remote.uid)), .real(message.remote.date.timeIntervalSince1970),
                message.remote.gmailMessageID.map(SQLValue.text) ?? .null, message.remote.messageID.map(SQLValue.text) ?? .null,
                .integer(message.hidden ? 1 : 0), .integer(message.remote.flags.contains(MailFlags.seen) ? 1 : 0), .blob(try encoder.encode(message))])
            try db.execute("DELETE FROM attachments WHERE message_id=?", [.text(message.id.uuidString)])
            for attachment in message.attachments {
                try db.execute("INSERT INTO attachments VALUES (?,?)", [.text(attachment.id.uuidString), .text(message.id.uuidString)])
            }
            try db.execute("DELETE FROM message_search WHERE id=?", [.text(message.id.uuidString)])
            let addresses = (message.remote.from + message.remote.to + message.remote.cc + message.remote.bcc).map { ($0.name ?? "") + " " + $0.email }.joined(separator: " ")
            try db.execute("INSERT INTO message_search VALUES (?,?,?,?)", [.text(message.id.uuidString), .text(message.remote.subject), .text(addresses), .text(message.text)])
    }
    func messages(mailboxID: UUID) throws -> [StoredMessage] { try decodeRows("SELECT payload FROM messages WHERE mailbox_id=? ORDER BY uid", [.text(mailboxID.uuidString)]) }
    func recentAddressMessages() throws -> [StoredMessage] {
        try decodeRows("SELECT payload FROM messages WHERE hidden=0 ORDER BY date DESC,id DESC LIMIT 5000")
    }
    func message(_ id: UUID) throws -> StoredMessage {
        guard let value: StoredMessage = try decodeRows("SELECT payload FROM messages WHERE id=?", [.text(id.uuidString)]).first else { throw MailError.notFound }; return value
    }
    func matchingGmail(_ id: String, accountID: UUID) throws -> [StoredMessage] {
        try decodeRows("SELECT payload FROM messages WHERE account_id=? AND gm_msgid=?", [.text(accountID.uuidString), .text(id)])
    }
    func list(scope: MailMessageScope, before: MailMessageCursor?, limit: Int) throws -> [MailMessageSummary] {
        let boxes = try mailboxes()
        let ids: [UUID]
        switch scope {
        case .mailbox(let id): ids = [id]
        case .unifiedInbox: ids = boxes.filter { $0.role == .inbox }.map(\.id)
        case .unifiedRole(let role): ids = boxes.filter { $0.role == role }.map(\.id)
        }
        guard !ids.isEmpty else { return [] }
        var bindings = ids.map { SQLValue.text($0.uuidString) }
        var sql = "SELECT payload FROM messages WHERE hidden=0 AND mailbox_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
        if let before {
            sql += " AND (date < ? OR (date = ? AND id < ?))"
            bindings += [.real(before.date.timeIntervalSince1970), .real(before.date.timeIntervalSince1970), .text(before.id.uuidString)]
        }
        sql += " ORDER BY date DESC,id DESC LIMIT ?"; bindings.append(.integer(Int64(max(0, min(limit, 1000)))))
        let records: [StoredMessage] = try decodeRows(sql, bindings)
        return records.map(\.summary)
    }
    func unreadCounts() throws -> MailUnreadCounts {
        let boxes = try mailboxes()
        var result = MailUnreadCounts(mailboxes: Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, 0) }))
        for row in try db.rows("SELECT mailbox_id,COUNT(*) AS count FROM messages WHERE hidden=0 AND seen=0 GROUP BY mailbox_id") {
            if let id = row["mailbox_id"]?.string.flatMap(UUID.init(uuidString:)) { result.mailboxes[id] = Int(row["count"]?.int ?? 0) }
        }
        result.unifiedInbox = boxes.filter { $0.role == .inbox }.reduce(0) { $0 + (result.mailboxes[$1.id] ?? 0) }
        return result
    }
    func deleteMessage(_ id: UUID) throws { try db.execute("DELETE FROM messages WHERE id=?", [.text(id.uuidString)]) }
    func resetMailbox(_ id: UUID) throws { try db.execute("DELETE FROM messages WHERE mailbox_id=?", [.text(id.uuidString)]) }
    func deleteMailbox(_ id: UUID) throws { try db.execute("DELETE FROM mailboxes WHERE id=?", [.text(id.uuidString)]) }
    func deleteAccount(_ id: UUID) throws { try db.execute("DELETE FROM accounts WHERE id=?", [.text(id.uuidString)]) }
    func save(_ draft: MailDraft) throws {
        try db.execute("INSERT INTO drafts VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,payload=excluded.payload", [.text(draft.id.uuidString), .text(draft.accountID.uuidString), .blob(try encoder.encode(draft))])
    }
    func drafts() throws -> [MailDraft] { try decodeRows("SELECT payload FROM drafts") }
    func draft(_ id: UUID) throws -> MailDraft {
        guard let draft = try drafts().first(where: { $0.id == id }) else { throw MailError.notFound }; return draft
    }
    func deleteDraft(_ id: UUID) throws { try db.execute("DELETE FROM drafts WHERE id=?", [.text(id.uuidString)]) }
    func savePending<T: Encodable>(_ value: T, id: UUID, accountID: UUID) throws {
        try db.execute("INSERT INTO pending VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.text(id.uuidString), .text(accountID.uuidString), .real(Date().timeIntervalSince1970), .blob(try encoder.encode(value))])
    }
    func pending<T: Decodable>(accountID: UUID) throws -> [T] { try decodeRows("SELECT payload FROM pending WHERE account_id=? ORDER BY created,rowid", [.text(accountID.uuidString)]) }
    func deletePending(_ id: UUID) throws { try db.execute("DELETE FROM pending WHERE id=?", [.text(id.uuidString)]) }
    func decodeRows<T: Decodable>(_ sql: String, _ bindings: [SQLValue] = []) throws -> [T] {
        try db.rows(sql, bindings).map {
            guard let data = $0["payload"]?.data else { throw MailError.storage("Missing mail record") }
            return try decoder.decode(T.self, from: data)
        }
    }
}
