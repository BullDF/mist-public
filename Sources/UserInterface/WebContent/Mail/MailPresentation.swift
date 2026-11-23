import AppKit
import MistMailCore

enum MailPresentation {
    static let unifiedRoles: [MailboxRole] = [.inbox, .drafts, .sent, .trash, .junk]
    static func unifiedKey(_ role: MailboxRole) -> String { role == .inbox ? "unified" : "unified:" + role.rawValue }
    static func unifiedRole(for key: String) -> MailboxRole? { unifiedRoles.first { unifiedKey($0) == key } }
    static func unifiedTitle(_ role: MailboxRole) -> String {
        switch role {
        case .drafts: MailStrings.unifiedDrafts
        case .sent: MailStrings.unifiedSent
        case .trash: MailStrings.unifiedTrash
        case .junk: MailStrings.unifiedSpam
        default: MailStrings.unifiedInbox
        }
    }
    static func errorMessage(_ error: Error) -> String {
        switch error as? MailError {
        case .authenticationFailed: MailStrings.authenticationFailed
        case .cannotConnect: MailStrings.cannotConnect
        case .tlsFailure: MailStrings.tlsFailure
        case .timeout: MailStrings.timeout
        case .offline: MailStrings.offline
        case .serverRejected: MailStrings.serverRejected
        case .invalidConfiguration: MailStrings.invalidConfiguration
        case .signatureTooLong: MailStrings.signatureTooLong
        case .unsupported: MailStrings.unsupported
        case .notFound: MailStrings.missingItem
        case .missingCredentials: MailStrings.missingCredentials
        case .storage: MailStrings.storageFailure
        default: MailStrings.cannotConnect
        }
    }
    /// Senders sometimes encode a leading space into the subject (Google One's `=?UTF-8?Q?_Vous…?=`).
    static func subject(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MailStrings.noSubject : trimmed
    }
    static func address(_ value: MailAddress) -> String { value.name.flatMap { $0.isEmpty ? nil : $0 } ?? value.email }
    static func addresses(_ values: [MailAddress]) -> String { values.map(address).joined(separator: ", ") }
    static func correspondent(_ message: MailMessageSummary, role: MailboxRole?) -> String {
        if role == .sent || role == .drafts { return String(format: MailStrings.to, addresses(message.recipients ?? [])) }
        return addresses(message.sender)
    }
    static func date(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { formatter.timeStyle = .short }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return MailStrings.yesterday }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, (2...6).contains(days) { formatter.setLocalizedDateFormatFromTemplate("EEE") }
        else { formatter.dateStyle = .short }
        return formatter.string(from: date)
    }
    static func status(_ status: MailAccountStatus?) -> String {
        switch status {
        case .connected: MailStrings.connected
        case .connecting: MailStrings.connecting
        case .syncing: MailStrings.syncing
        case .retrying: MailStrings.retrying
        case .authFailed: MailStrings.authFailed
        default: MailStrings.disconnected
        }
    }
    static func statusColor(_ status: MailAccountStatus?) -> NSColor {
        switch status { case .connected: .systemGreen; case .connecting, .syncing: .systemBlue; case .retrying: .systemOrange; case .authFailed: .systemRed; default: .secondaryLabelColor }
    }
    /// Servers keep their own role names (French Gmail's "Messages envoyés"), except INBOX, a fixed protocol name.
    static func mailboxName(_ box: Mailbox) -> String { box.role == .inbox ? MailStrings.inbox : box.displayName }
    /// The last level of a nested mailbox's path ("Brouillons" for "[Gmail]/Brouillons"), as the sidebar shows it.
    static func mailboxTitle(_ box: Mailbox) -> String {
        guard box.role != .inbox, let delimiter = box.delimiter, !delimiter.isEmpty, let leaf = box.name.components(separatedBy: delimiter).last else { return mailboxName(box) }
        return Mailbox.decodeModifiedUTF7(leaf)
    }
    static func symbol(_ role: MailboxRole?) -> String {
        switch role { case .inbox: "tray"; case .drafts: "doc"; case .sent: "paperplane"; case .archive, .all: "archivebox"; case .junk: "exclamationmark.shield"; case .trash: "trash"; case .flagged: "flag"; default: "folder" }
    }
}

final class MailboxTreeNode: NSObject {
    let key: String
    var title: String
    var mailbox: Mailbox?
    var accountID: UUID?
    var children: [MailboxTreeNode] = []
    var unifiedRole: MailboxRole? { MailPresentation.unifiedRole(for: key) }
    var canSelect: Bool { unifiedRole != nil || mailbox.map { !$0.attributes.contains { $0.lowercased() == "\\noselect" } } == true }
    func unreadCount(in state: MailPageSnapshot) -> Int {
        if let unifiedRole { return state.mailboxes.filter { $0.role == unifiedRole }.reduce(0) { $0 + (state.unread.mailboxes[$1.id] ?? 0) } }
        return mailbox.flatMap { state.unread.mailboxes[$0.id] } ?? 0
    }
    init(key: String, title: String, mailbox: Mailbox? = nil, accountID: UUID? = nil) {
        self.key = key; self.title = title; self.mailbox = mailbox; self.accountID = accountID
    }
    static func build(_ state: MailPageSnapshot) -> [MailboxTreeNode] {
        let roles: [MailboxRole] = [.inbox, .drafts, .sent, .archive, .all, .junk, .trash, .flagged]
        let unified = MailPresentation.unifiedRoles.filter { role in role == .inbox || state.mailboxes.contains { $0.role == role } }
            .map { MailboxTreeNode(key: MailPresentation.unifiedKey($0), title: MailPresentation.unifiedTitle($0)) }
        return unified + state.accounts.map { account in
            let root = MailboxTreeNode(key: "account:" + account.id.uuidString, title: account.config.displayName, accountID: account.id)
            var nodes: [String: MailboxTreeNode] = [:]
            for box in state.mailboxes.filter({ $0.accountID == account.id }).sorted(by: { $0.name < $1.name }) {
                let parts = box.delimiter.flatMap { $0.isEmpty ? nil : box.name.components(separatedBy: $0) } ?? [box.name]
                var parent = root, path = ""
                for (index, part) in parts.enumerated() {
                    path += (path.isEmpty ? "" : box.delimiter ?? "") + part
                    let node = nodes[path] ?? MailboxTreeNode(key: "group:" + account.id.uuidString + path, title: Mailbox.decodeModifiedUTF7(part))
                    if nodes[path] == nil { nodes[path] = node; parent.children.append(node) }
                    if index == parts.count - 1 {
                        // Keep server role names, including French Gmail's names.
                        let replacement = MailboxTreeNode(key: box.id.uuidString, title: box.role == .inbox ? MailStrings.inbox : Mailbox.decodeModifiedUTF7(part), mailbox: box)
                        replacement.children = node.children
                        if let slot = parent.children.firstIndex(where: { $0 === node }) { parent.children[slot] = replacement }
                        nodes[path] = replacement
                    }
                    parent = nodes[path] ?? node
                }
            }
            func sort(_ node: MailboxTreeNode) {
                func rank(_ node: MailboxTreeNode) -> Int {
                    node.mailbox?.role.flatMap { roles.firstIndex(of: $0) } ?? node.children.map(rank).min() ?? 99
                }
                node.children.sort {
                    let left = rank($0), right = rank($1)
                    return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left < right
                }
                node.children.forEach(sort)
            }
            sort(root)
            return root
        }
    }
}
