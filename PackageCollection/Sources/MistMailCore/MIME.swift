import Foundation
import SwiftMail
import UniformTypeIdentifiers

/// Pure MIME conversion; networking stays in SwiftMailTransport.
enum MailMIME {
    static func serialize(_ draft: MailDraft, account: MailAccount, includeBcc: Bool) throws -> Data {
        let addresses = draft.to + draft.cc + draft.bcc
        guard ![draft.subject, account.config.senderName, account.config.email].contains(where: { $0.contains("\r") || $0.contains("\n") }),
              addresses.allSatisfy({ !$0.email.contains("\r") && !$0.email.contains("\n") && $0.email.contains("@") && !($0.name ?? "").contains(where: { $0 == "\r" || $0 == "\n" }) }) else { throw MailError.invalidConfiguration }
        var email = Email(sender: .init(name: account.config.senderName, address: account.config.email),
                          recipients: draft.to.map(address), ccRecipients: draft.cc.map(address), bccRecipients: draft.bcc.map(address),
                          subject: draft.subject, textBody: draft.plainText, htmlBody: draft.html,
                          attachments: try draft.attachments.map {
            Attachment(filename: $0.filename, mimeType: UTType(filenameExtension: $0.file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                       data: try Data(contentsOf: $0.file), contentID: $0.contentID, isInline: $0.contentID != nil)
        })
        let domain = String(account.config.email.split(separator: "@").last ?? "localhost")
        email.messageID = MessageID(localPart: draft.id.uuidString, domain: domain)
        if let context = draft.replyContext {
            var headers: [String: String] = [:]
            if let parent = context.inReplyTo, let parsed = MessageID(parent) { headers["In-Reply-To"] = parsed.description }
            if !context.references.isEmpty { headers["References"] = context.references.compactMap { MessageID($0)?.description }.joined(separator: " ") }
            email.additionalHeaders = headers
        }
        // SwiftMail writes UTF-8 quoted-printable/base64 parts and RFC 2047 headers.
        return Data(email.constructContent(use8BitMIME: false, includeBccHeader: includeBcc).utf8)
    }
    static func address(_ value: MailAddress) -> EmailAddress { .init(name: value.name, address: value.email) }
    static func addresses(_ entries: [AddressListEntry]) -> [MailAddress] { entries.mailboxes.map { .init($0.address, name: $0.name) } }
    static func part(_ value: MessagePart) -> MailPart {
        .init(section: value.section.description,
              mimeType: value.contentType.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces).lowercased(),
              charset: value.declaredCharset, encoding: value.encoding, filename: value.filename,
              contentID: value.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), size: value.size ?? 0,
              isAttachment: value.disposition?.lowercased() == "attachment" || value.filename != nil || (!value.contentType.lowercased().hasPrefix("text/") && value.contentId == nil))
    }
    static func swiftPart(_ value: MailPart, data: Data? = nil) -> MessagePart {
        .init(sectionString: value.section, contentType: value.mimeType + (value.charset.map { "; charset=\"\($0)\"" } ?? ""),
              disposition: value.isAttachment ? "attachment" : "inline", encoding: value.encoding, filename: value.filename,
              contentId: value.contentID, size: value.size, data: data)
    }
    static func remote(_ info: MessageInfo) -> MailRemoteMessage {
        .init(uid: info.uid?.value ?? 0, from: addresses(info.fromAddresses), to: addresses(info.toAddresses),
              cc: addresses(info.ccAddresses), bcc: addresses(info.bccAddresses), replyTo: addresses(info.replyToAddresses),
              subject: info.subject ?? "", messageID: info.messageId?.description,
              inReplyTo: info.inReplyTo?.description ?? messageIDs(info.additionalFields?["in-reply-to"] ?? "").first,
              references: info.references?.map(\.description) ?? messageIDs(info.additionalFields?["references"] ?? ""), date: info.date ?? info.internalDate ?? Date(timeIntervalSince1970: 0),
              internalDate: info.internalDate, size: info.size ?? 0, flags: Set(info.flags.map(flag)), parts: info.parts.map(part))
    }
    static func messageIDs(_ value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: "<[^>]+>")
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).flatMap { MessageID(String(value[$0]))?.description }
        }
    }
    static func flag(_ flag: Flag) -> String {
        switch flag {
        case .seen: return MailFlags.seen
        case .answered: return MailFlags.answered
        case .flagged: return MailFlags.flagged
        case .deleted: return MailFlags.deleted
        case .draft: return MailFlags.draft
        case .custom(let value): return value
        }
    }
    static func swiftFlag(_ value: String) -> Flag {
        switch value.lowercased() {
        case "\\seen": return .seen
        case "\\answered": return .answered
        case "\\flagged": return .flagged
        case "\\deleted": return .deleted
        case "\\draft": return .draft
        default: return .custom(value)
        }
    }
    /// The sections of the message's own body: its first text/plain and text/html parts outside any
    /// attached message. SwiftMail lists an attached message/rfc822's parts after it, under its
    /// section, so taking every text part let a bounce or forwarded mail replace the body.
    static func ownBodySections(_ parts: [MailPart]) -> Set<String> {
        let embedded = parts.filter { $0.mimeType == "message/rfc822" }.map { $0.section + "." }
        var types: Set<String> = [], sections: Set<String> = []
        for part in parts where !part.isAttachment && ["text/plain", "text/html"].contains(part.mimeType) && !embedded.contains(where: part.section.hasPrefix) {
            if types.insert(part.mimeType).inserted { sections.insert(part.section) }
        }
        return sections
    }
    static func decode(_ raw: Data) throws -> (MailRemoteMessage, MailBody, [String: Data]) {
        let message = try EMLParser.parse(raw)
        var info = message.header; info.parts = message.parts
        var body = MailBody(), attachments: [String: Data] = [:]
        let own = ownBodySections(message.parts.map(self.part))
        for part in message.parts {
            let metadata = self.part(part)
            if own.contains(metadata.section) && metadata.mimeType == "text/plain" { body.plainText = part.textContent }
            if own.contains(metadata.section) && metadata.mimeType == "text/html" { body.html = part.textContent }
            if metadata.isAttachment || metadata.contentID != nil { attachments[metadata.section] = part.decodedData() }
        }
        for part in message.parts {
            if let cid = part.contentId, (body.html ?? "").contains("cid:" + cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))) {
                body.inlineParts[part.section.description] = part.decodedData()
            }
        }
        return (remote(info), body, attachments)
    }
}
