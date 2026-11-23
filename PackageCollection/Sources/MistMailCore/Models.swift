import Foundation

public enum MailSecurity: String, Codable, Sendable { case tls, startTLS, plaintext }

public struct MailServer: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var security: MailSecurity
    public init(host: String, port: Int, security: MailSecurity) {
        self.host = host; self.port = port; self.security = security
    }
    public func validate() throws {
        guard !host.isEmpty, (1...65535).contains(port), !host.contains(where: { $0.isWhitespace }) else {
            throw MailError.invalidConfiguration
        }
        if security == .plaintext && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
            throw MailError.invalidConfiguration
        }
    }
}

public struct MailAccountConfig: Codable, Equatable, Sendable {
    public var displayName: String
    public var senderName: String
    public var email: String
    public var username: String
    public var imap: MailServer
    public var smtp: MailServer
    public var sortOrder: Int
    public var signatureHTML: String?
    public init(displayName: String, senderName: String, email: String, username: String,
                imap: MailServer, smtp: MailServer, sortOrder: Int = 0, signatureHTML: String? = nil) {
        self.displayName = displayName; self.senderName = senderName; self.email = email
        self.username = username; self.imap = imap; self.smtp = smtp; self.sortOrder = sortOrder
        self.signatureHTML = Self.normalizedSignature(signatureHTML)
    }
    public static func normalizedSignature(_ html: String?) -> String? {
        guard let html else { return nil }
        return MailText.readable(html).isEmpty &&
            html.range(of: "<img\\b", options: [.regularExpression, .caseInsensitive]) == nil ? nil : html
    }
    public func validate() throws {
        guard (signatureHTML?.utf8.count ?? 0) <= 32 * 1024 else { throw MailError.signatureTooLong }
        try imap.validate(); try smtp.validate()
        guard email.contains("@"), !username.isEmpty,
              ![email, senderName, username].contains(where: { $0.contains("\r") || $0.contains("\n") }) else {
            throw MailError.invalidConfiguration
        }
    }
}

public struct MailAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var config: MailAccountConfig
    public var isGmail: Bool
    public init(id: UUID = UUID(), config: MailAccountConfig, isGmail: Bool = false) {
        self.id = id; self.config = config; self.isGmail = isGmail
    }
}

public enum MailAccountStatus: Equatable, Sendable {
    case disconnected, connecting, syncing, connected, authFailed, retrying(seconds: Int)
}

public enum MailError: Error, Equatable, Sendable {
    case authenticationFailed, cannotConnect, tlsFailure, timeout, offline
    case serverRejected(String), invalidConfiguration, unsupported, notFound, missingCredentials
    case signatureTooLong
    case storage(String)
    public var isPermanent: Bool {
        switch self { case .serverRejected, .unsupported, .invalidConfiguration, .notFound, .signatureTooLong: return true; default: return false }
    }
}

public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged
}

public struct Mailbox: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public var name: String
    public var delimiter: String?
    public var attributes: Set<String>
    public var role: MailboxRole?
    public var uidValidity: UInt32?
    public var initialSyncComplete: Bool
    public var oldestLoadedUID: UInt32?
    public var hasMore: Bool
    public var highestKnownUID: UInt32
    public var needsCreation: Bool = false
    public init(id: UUID = UUID(), accountID: UUID, name: String, delimiter: String? = "/",
                attributes: Set<String> = [], role: MailboxRole? = nil, uidValidity: UInt32? = nil,
                initialSyncComplete: Bool = false, oldestLoadedUID: UInt32? = nil, hasMore: Bool = true, highestKnownUID: UInt32 = 0) {
        self.id = id; self.accountID = accountID; self.name = name; self.delimiter = delimiter
        self.attributes = attributes; self.role = role; self.uidValidity = uidValidity
        self.initialSyncComplete = initialSyncComplete; self.oldestLoadedUID = oldestLoadedUID; self.hasMore = hasMore
        self.highestKnownUID = highestKnownUID
    }
    /// The name to show: IMAP names travel in modified UTF-7 (RFC 3501 §5.1.3), so French Gmail's
    /// "Messages envoyés" arrives as `[Gmail]/Messages envoy&AOk-s`. `name` stays raw for commands.
    public var displayName: String { Self.decodeModifiedUTF7(name) }
    public static func decodeModifiedUTF7(_ name: String) -> String {
        var out = "", rest = Substring(name)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let dash = rest[amp...].firstIndex(of: "-") else { return out + rest[amp...] }
            let encoded = rest[rest.index(after: amp)..<dash]
            if encoded.isEmpty {
                out += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf16BigEndian) {
                    out += text
                } else {
                    out += rest[amp...dash]
                }
            }
            rest = rest[rest.index(after: dash)...]
        }
        return out + rest
    }
    public var autoSync: Bool {
        guard !attributes.contains(where: { $0.lowercased() == "\\noselect" }) else { return false }
        return role.map { [.inbox, .sent, .drafts, .trash, .junk, .archive].contains($0) } ?? false
    }
    public static func detectRole(name: String, attributes: Set<String>, gmail: Bool) -> MailboxRole? {
        let attrs = Set(attributes.map { $0.lowercased() })
        if name.lowercased() == "inbox" { return .inbox }
        for role in MailboxRole.allCases where attrs.contains("\\" + role.rawValue) {
            if role == .all || role == .flagged { if gmail { return role }; continue }
            return role
        }
        let names: [MailboxRole: [String]] = [
            .sent: ["sent", "sent messages", "sent items", "sent mail"], .drafts: ["drafts"],
            .trash: ["trash", "deleted messages", "deleted items", "bin"], .junk: ["junk", "spam"], .archive: ["archive"]]
        return names.first { $0.value.contains(name.lowercased()) }?.key
    }
}

public struct MailAddress: Codable, Equatable, Hashable, Sendable {
    public var name: String?
    public var email: String
    public init(_ email: String, name: String? = nil) { self.email = email; self.name = name }
}

public enum MailFlags {
    public static let seen = "\\Seen", flagged = "\\Flagged", answered = "\\Answered"
    public static let deleted = "\\Deleted", draft = "\\Draft", forwarded = "$Forwarded"
}

public struct MailPart: Codable, Equatable, Sendable, Identifiable {
    public var id: String { section }
    public var section: String
    public var mimeType: String
    public var charset: String?
    public var encoding: String?
    public var filename: String?
    public var contentID: String?
    public var size: Int
    public var isAttachment: Bool
    public init(section: String, mimeType: String, charset: String? = nil, encoding: String? = nil,
                filename: String? = nil, contentID: String? = nil, size: Int = 0, isAttachment: Bool = false) {
        self.section = section; self.mimeType = mimeType; self.charset = charset; self.encoding = encoding
        self.filename = filename; self.contentID = contentID; self.size = size; self.isAttachment = isAttachment
    }
}

/// List metadata only. Body bytes are fetched separately with BODY.PEEK.
public struct MailRemoteMessage: Codable, Equatable, Sendable {
    public var uid: UInt32
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var date: Date
    public var internalDate: Date
    public var size: Int
    public var flags: Set<String>
    public var parts: [MailPart]
    public var gmailMessageID: String?
    public var gmailThreadID: String?
    public var gmailLabels: [String]
    public init(uid: UInt32, from: [MailAddress] = [], to: [MailAddress] = [], cc: [MailAddress] = [],
                bcc: [MailAddress] = [], replyTo: [MailAddress] = [], subject: String = "", messageID: String? = nil,
                inReplyTo: String? = nil, references: [String] = [], date: Date = Date(), internalDate: Date? = nil,
                size: Int = 0, flags: Set<String> = [], parts: [MailPart] = [],
                gmailMessageID: String? = nil, gmailThreadID: String? = nil, gmailLabels: [String] = []) {
        self.uid = uid; self.from = from; self.to = to; self.cc = cc; self.bcc = bcc; self.replyTo = replyTo
        self.subject = subject; self.messageID = messageID; self.inReplyTo = inReplyTo; self.references = references
        self.date = date; self.internalDate = internalDate ?? date; self.size = size; self.flags = flags; self.parts = parts
        self.gmailMessageID = gmailMessageID; self.gmailThreadID = gmailThreadID; self.gmailLabels = gmailLabels
    }
}

public struct MailMessageSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let mailboxID: UUID
    public var sender: [MailAddress]
    public var recipients: [MailAddress]?
    public var subject: String
    public var snippet: String
    public var date: Date
    public var flags: Set<String>
    public var hasAttachments: Bool
    public var uid: UInt32
    public var gmailMessageID: String?
    public init(id: UUID, accountID: UUID, mailboxID: UUID, sender: [MailAddress], recipients: [MailAddress] = [],
                subject: String, snippet: String, date: Date, flags: Set<String>, hasAttachments: Bool, uid: UInt32, gmailMessageID: String? = nil) {
        self.id = id; self.accountID = accountID; self.mailboxID = mailboxID; self.sender = sender; self.recipients = recipients
        self.subject = subject; self.snippet = snippet; self.date = date; self.flags = flags
        self.hasAttachments = hasAttachments; self.uid = uid; self.gmailMessageID = gmailMessageID
    }
}

public struct MailAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let messageID: UUID
    public let part: MailPart
    public var filename: String { part.filename ?? "attachment" }
    public init(id: UUID = UUID(), messageID: UUID, part: MailPart) { self.id = id; self.messageID = messageID; self.part = part }
}

public struct MailMessageDetail: Codable, Equatable, Sendable {
    public var summary: MailMessageSummary
    public var headers: MailRemoteMessage
    public var plainText: String?
    public var html: String?
    public var attachments: [MailAttachment]
    public var inlineFiles: [String: URL]
    public init(summary: MailMessageSummary, headers: MailRemoteMessage, plainText: String? = nil, html: String? = nil,
                attachments: [MailAttachment] = [], inlineFiles: [String: URL] = [:]) {
        self.summary = summary; self.headers = headers; self.plainText = plainText; self.html = html
        self.attachments = attachments; self.inlineFiles = inlineFiles
    }
}

public enum MailMessageScope: Sendable { case unifiedInbox, unifiedRole(MailboxRole), mailbox(UUID) }
public enum MailSearchScope: Sendable { case all, account(UUID), mailbox(UUID), mailboxes([UUID]) }
public struct MailMessageCursor: Sendable {
    public let date: Date
    public let id: UUID
    public init(date: Date, id: UUID) { self.date = date; self.id = id }
    public init(_ summary: MailMessageSummary) { date = summary.date; id = summary.id }
}
public struct MailUnreadCounts: Equatable, Sendable {
    public var mailboxes: [UUID: Int]
    public var unifiedInbox: Int
    public init(mailboxes: [UUID: Int] = [:], unifiedInbox: Int = 0) { self.mailboxes = mailboxes; self.unifiedInbox = unifiedInbox }
}

public enum MailReplyKind: String, Codable, Sendable { case reply, replyAll, forward }
public struct MailReplyContext: Codable, Equatable, Sendable {
    public var kind: MailReplyKind
    public var sourceMessageID: UUID
    public var inReplyTo: String?
    public var references: [String]
    public init(kind: MailReplyKind, sourceMessageID: UUID, inReplyTo: String?, references: [String]) {
        self.kind = kind; self.sourceMessageID = sourceMessageID; self.inReplyTo = inReplyTo; self.references = references
    }
}
public struct MailDraftAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var filename: String
    public var file: URL
    public var contentID: String?
    public init(id: UUID = UUID(), filename: String, file: URL, contentID: String? = nil) { self.id = id; self.filename = filename; self.file = file; self.contentID = contentID }
}
public struct MailDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var accountID: UUID
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var plainText: String
    public var html: String?
    public var attachments: [MailDraftAttachment]
    public var replyContext: MailReplyContext?
    public var serverUID: UInt32?
    public var serverMailboxID: UUID?
    public internal(set) var serverUpdatedAt: Date?
    public internal(set) var serverUIDValidity: UInt32?
    var revision: Int64 = 0
    var serverRevision: Int64?
    public var updatedAt: Date
    public var lastSendError: String?
    /// SMTP acceptance is durable so retrying Sent filing never sends the message twice.
    public internal(set) var acceptedMessage: Data?
    public internal(set) var sentCopyFiled: Bool = false
    public init(id: UUID = UUID(), accountID: UUID, to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                subject: String = "", plainText: String = "", html: String? = nil, attachments: [MailDraftAttachment] = [],
                replyContext: MailReplyContext? = nil, serverUID: UInt32? = nil, serverMailboxID: UUID? = nil,
                updatedAt: Date = Date(), lastSendError: String? = nil) {
        self.id = id; self.accountID = accountID; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.plainText = plainText; self.html = html; self.attachments = attachments; self.replyContext = replyContext
        self.serverUID = serverUID; self.serverMailboxID = serverMailboxID; self.updatedAt = updatedAt; self.lastSendError = lastSendError
    }
    /// No recipients, subject, body text or attachments: nothing worth keeping in Drafts.
    public var isEmpty: Bool {
        (to + cc + bcc).isEmpty && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty &&
            plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && MailText.plain(html ?? "").isEmpty
    }
}

public enum MailEvent: Sendable {
    case accountsChanged, accountStatusChanged(UUID, MailAccountStatus), mailboxesChanged(UUID)
    case messagesChanged(Set<UUID>), unreadCountsChanged(MailUnreadCounts), draftsChanged
    case actionFailed(operationID: UUID, error: MailError)
    case newMessages([MailMessageSummary])
}

public struct MailAccountPreset: Sendable {
    public let name: String
    public let imap: MailServer?
    public let smtp: MailServer?
    public static let gmail = Self(name: "Gmail", imap: .init(host: "imap.gmail.com", port: 993, security: .tls), smtp: .init(host: "smtp.gmail.com", port: 465, security: .tls))
    public static let uoftCS = Self(name: "UofT CS", imap: .init(host: "imap.cs.toronto.edu", port: 993, security: .tls), smtp: .init(host: "smtp.cs.toronto.edu", port: 587, security: .startTLS))
    public static let other = Self(name: "Other", imap: nil, smtp: nil)
    public static let all: [Self] = [.gmail, .uoftCS, .other]
}
