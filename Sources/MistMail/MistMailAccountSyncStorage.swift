import Foundation
import MistMailCore

@MainActor
final class MistEngineMailAccountSyncStorage: MistMailAccountSyncStorage {
    var didChange: (() -> Void)?
    private let engine: MailEngine?
    private var eventsTask: Task<Void, Never>?

    init(engine: MailEngine?) {
        self.engine = engine
        if let engine {
            eventsTask = Task { [weak self] in
                for await event in await engine.events() {
                    guard !Task.isCancelled else { return }
                    if case .accountsChanged = event { self?.didChange?() }
                }
            }
        }
    }

    deinit { eventsTask?.cancel() }

    func read() async throws -> [MistMailSyncAccount] {
        guard let engine else { return [] }
        var result: [MistMailSyncAccount] = []
        for account in try await engine.accounts() {
            let config = account.config
            result.append(MistMailSyncAccount(id: account.id, displayName: config.displayName, senderName: config.senderName,
                email: config.email, username: config.username,
                imap: .init(host: config.imap.host, port: config.imap.port, security: config.imap.security.rawValue),
                smtp: .init(host: config.smtp.host, port: config.smtp.port, security: config.smtp.security.rawValue),
                sortOrder: config.sortOrder, isGmail: account.isGmail, password: try await engine.storedPassword(accountID: account.id)))
        }
        return result
    }

    func write(_ account: MistMailSyncAccount) async throws {
        guard let engine else { AppLogError("[MistSync] Cannot apply mail account: Mail database is unavailable"); return }
        guard let imapSecurity = MailSecurity(rawValue: account.imap.security),
              let smtpSecurity = MailSecurity(rawValue: account.smtp.security) else { throw MistSyncError.invalidRecord }
        let config = MailAccountConfig(displayName: account.displayName, senderName: account.senderName,
            email: account.email, username: account.username,
            imap: .init(host: account.imap.host, port: account.imap.port, security: imapSecurity),
            smtp: .init(host: account.smtp.host, port: account.smtp.port, security: smtpSecurity), sortOrder: account.sortOrder)
        try await engine.applySyncedAccount(MailAccount(id: account.id, config: config, isGmail: account.isGmail), password: account.password)
    }

    func delete(id: UUID) async throws {
        guard let engine else { AppLogError("[MistSync] Cannot remove mail account: Mail database is unavailable"); return }
        if try await engine.accounts().contains(where: { $0.id == id }) { try await engine.removeAccount(id) }
    }
}
