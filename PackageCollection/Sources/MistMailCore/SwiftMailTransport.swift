import Foundation
import SwiftMail

/// SwiftMail is confined here for networking. A gate protects SELECT + command across awaits.
public actor SwiftMailTransport: MailTransport {
    private let config: MailAccountConfig
    private let password: String
    private let imap: IMAPServer
    private let gate = MailOperationGate()
    private var capabilities: Set<String> = []
    private var idleServer: IMAPServer?
    private var idleTask: Task<Void, Never>?
    private var idleContinuation: AsyncStream<MailPushEvent>.Continuation?
    /// Set by disconnect, for good: a connection set up across it is closed instead of kept.
    private var closed = false

    public init(config: MailAccountConfig, password: String) {
        self.config = config; self.password = password
        imap = Self.makeIMAP(config.imap)
    }
    private static func security(_ value: MailSecurity) -> MailTransportSecurity {
        switch value { case .tls: return .implicitTLS; case .startTLS: return .startTLS; case .plaintext: return .plainText }
    }
    private static func makeIMAP(_ server: MailServer) -> IMAPServer {
        IMAPServer(host: server.host, port: server.port, transportSecurity: security(server.security))
    }
    private func makeSMTP() -> SMTPServer {
        SMTPServer(host: config.smtp.host, port: config.smtp.port, transportSecurity: Self.security(config.smtp.security), clientIdentity: "mist.local")
    }
    private func command<T>(_ body: () async throws -> T) async throws -> T {
        await gate.acquire()
        do { try Task.checkCancellation(); let value = try await body(); await gate.release(); return value }
        catch { await gate.release(); if error is CancellationError { throw error }; report(error, host: config.imap.host); throw Self.classify(error) }
    }
    /// The server's own words go to the app's log, which the account status can't show. Never the password.
    private func report(_ error: Error, host: String) {
        MailDiagnostics.log?("[MistMail] \(config.username) on \(host): \(error)")
    }
    public func connect() async throws -> Set<String> {
        try await command {
            try config.validate()
            await imap.setReconnectsInsideCommands(false)
            try await imap.connect(); try await imap.login(username: config.username, password: password)
            let caps = try await imap.fetchCapabilities()
            if closed { try? await imap.disconnect(); throw CancellationError() }
            capabilities = Set(caps.map { ($0.name + ($0.value.map { "=" + $0 } ?? "")).uppercased() })
            return capabilities
        }
    }
    public func disconnect() async {
        closed = true
        idleTask?.cancel(); idleTask = nil; idleContinuation?.finish(); idleContinuation = nil
        if let server = idleServer { idleServer = nil; try? await server.done(); try? await server.disconnect() }
        try? await imap.disconnect()
    }
    public func testSMTP() async throws {
        let smtp = makeSMTP()
        do {
            try config.smtp.validate()
            try await smtp.connect(); try await smtp.login(username: config.username, password: password)
            try await smtp.disconnect()
        } catch { try? await smtp.disconnect(); report(error, host: config.smtp.host); throw Self.classify(error) }
    }
    public func listMailboxes() async throws -> [MailRemoteMailbox] {
        try await command {
            try await imap.listMailboxes().map { box in
                let mappings: [(SwiftMail.Mailbox.Info.Attributes, String)] = [
                    (.noSelect, "\\Noselect"), (.hasChildren, "\\HasChildren"), (.hasNoChildren, "\\HasNoChildren"),
                    (.inbox, "\\Inbox"), (.sent, "\\Sent"), (.drafts, "\\Drafts"), (.trash, "\\Trash"),
                    (.junk, "\\Junk"), (.archive, "\\Archive"), (.all, "\\All"), (.flagged, "\\Flagged"), (.important, "\\Important")]
                return .init(name: box.name, delimiter: box.hierarchyDelimiter, attributes: Set(mappings.filter { box.attributes.contains($0.0) }.map { $0.1 }))
            }
        }
    }
    public func select(_ mailbox: String) async throws -> MailSelection {
        try await command {
            let selection = try await imap.selectMailbox(mailbox)
            return .init(uidValidity: selection.uidValidity.value, uidNext: selection.uidNext.value)
        }
    }
    public func search(_ query: MailUIDQuery, in mailbox: String) async throws -> [UInt32] {
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            var range: UIDSet?, criteria: [SearchCriteria]
            switch query {
            case .all: criteria = [.all]
            case .since(let date): criteria = [.since(date)]
            case .range(let uids): range = UIDSet(UID(uids.lowerBound)...UID(uids.upperBound)); criteria = [.all]
            case .text(let text): criteria = [.text(text)]
            case .header(let name, let value): criteria = [.header(name, value)]
            }
            let uids: [UID] = try await imap.search(identifierSet: range, criteria: criteria, sortCriteria: [])
            return uids.map(\.value)
        }
    }
    public func fetch(_ uids: [UInt32], in mailbox: String, gmail: Bool) async throws -> [MailRemoteMessage] {
        guard !uids.isEmpty else { return [] }
        return try await command {
            _ = try await imap.selectMailbox(mailbox)
            var output: [MailRemoteMessage] = []
            // Bound response size and command length while retaining BODYSTRUCTURE list data.
            for start in stride(from: 0, to: uids.count, by: 50) {
                let set = UIDSet(uids[start..<min(start + 50, uids.count)].map { UID($0) })
                let infos = try await imap.fetchMessageInfosBulk(using: set, options: [.envelope, .flags, .internalDate, .size, .bodyStructure], headerFields: ["References", "In-Reply-To"])
                let gm = gmail ? try await imap.fetchGmailAttributes(for: set) : [:]
                for info in infos {
                    var value = MailMIME.remote(info)
                    if let uid = info.uid, let attributes = gm[uid] {
                        value.gmailMessageID = String(attributes.messageID); value.gmailThreadID = String(attributes.threadID); value.gmailLabels = attributes.labels
                    }
                    output.append(value)
                }
            }
            return output
        }
    }
    public func flags(_ range: ClosedRange<UInt32>, in mailbox: String) async throws -> [UInt32: Set<String>] {
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            var flags: [UInt32: Set<String>] = [:]
            for try await info in imap.fetchMessageInfos(using: UIDSet(UID(range.lowerBound)...UID(range.upperBound)), options: .uidFlagsOnly) {
                if let uid = info.uid { flags[uid.value] = Set(info.flags.map(MailMIME.flag)) }
            }
            return flags
        }
    }
    public func body(_ message: MailRemoteMessage, in mailbox: String) async throws -> MailBody {
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            var body = MailBody()
            let own = MailMIME.ownBodySections(message.parts)
            for part in message.parts where own.contains(part.section) {
                let raw = try await imap.fetchPart(section: Section(part.section), of: UID(message.uid))
                let decoded = MailMIME.swiftPart(part, data: raw).textContent
                if part.mimeType == "text/plain" { body.plainText = decoded } else { body.html = decoded }
            }
            for part in message.parts {
                if let cid = part.contentID, (body.html ?? "").contains("cid:" + cid) {
                    let raw = try await imap.fetchPart(section: Section(part.section), of: UID(message.uid))
                    body.inlineParts[part.section] = MailMIME.swiftPart(part, data: raw).decodedData()
                }
            }
            return body
        }
    }
    public func attachment(_ part: MailPart, uid: UInt32, in mailbox: String) async throws -> Data {
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            let raw = try await imap.fetchPart(section: Section(part.section), of: UID(uid))
            guard let data = MailMIME.swiftPart(part, data: raw).decodedData() else { throw MailError.serverRejected("Invalid attachment encoding") }
            return data
        }
    }
    public func setFlag(_ flag: String, value: Bool, uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            try await imap.store(flags: [MailMIME.swiftFlag(flag)], on: UIDSet(uids.map { UID($0) }), operation: value ? .add : .remove)
        }
    }
    public func setFlag(_ flag: String, value: Bool, range: ClosedRange<UInt32>, in mailbox: String) async throws {
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            try await imap.store(flags: [MailMIME.swiftFlag(flag)], on: UIDSet(UID(range.lowerBound)...UID(range.upperBound)), operation: value ? .add : .remove)
        }
    }
    public func move(_ uids: [UInt32], from: String, to: String) async throws -> MailMoveResult? {
        guard !uids.isEmpty else { return nil }
        return try await command {
            _ = try await imap.selectMailbox(from)
            guard let result = try await imap.move(messages: UIDSet(uids.map { UID($0) }), to: to) else { return nil }
            return .init(uidValidity: result.destinationUIDValidity.value, uids: Dictionary(uniqueKeysWithValues: result.mapping.map { ($0.source.value, $0.destination.value) }))
        }
    }
    public func delete(_ uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        try await command {
            _ = try await imap.selectMailbox(mailbox)
            let set = UIDSet(uids.map { UID($0) })
            // Without UIDPLUS, temporarily protect other clients' deleted messages from EXPUNGE.
            var protected: [UID] = []
            if !capabilities.contains("UIDPLUS") {
                let deleted: [UID] = try await imap.search(criteria: [.deleted], sortCriteria: [])
                protected = deleted.filter { !uids.contains($0.value) }
                if !protected.isEmpty { try await imap.store(flags: [.deleted], on: UIDSet(protected), operation: .remove) }
            }
            do {
                try await imap.store(flags: [.deleted], on: set, operation: .add)
                try await imap.expunge(messages: set)
            } catch {
                if !protected.isEmpty { try? await imap.store(flags: [.deleted], on: UIDSet(protected), operation: .add) }
                throw error
            }
            if !protected.isEmpty { try await imap.store(flags: [.deleted], on: UIDSet(protected), operation: .add) }
        }
    }
    public func createMailbox(_ name: String) async throws { try await command { try await imap.createMailbox(name) } }
    public func append(_ bytes: Data, to mailbox: String, flags: Set<String>) async throws -> UInt32? {
        try await command {
            let result = try await imap.append(rawMessage: bytes, to: mailbox, flags: flags.map(MailMIME.swiftFlag), internalDate: nil)
            if let uid = result.firstUID { return uid.value }
            // Servers without APPENDUID can still identify our unique Message-ID.
            guard let id = try MailMIME.decode(bytes).0.messageID else { return nil }
            _ = try await imap.selectMailbox(mailbox)
            let matches: [UID] = try await imap.search(criteria: [.header("Message-ID", id)], sortCriteria: [])
            return matches.map(\.value).max()
        }
    }
    public func send(_ bytes: Data, from: MailAddress, recipients: [MailAddress]) async throws {
        let smtp = makeSMTP()
        do {
            try config.smtp.validate()
            try await smtp.connect(); try await smtp.login(username: config.username, password: password)
            _ = try await smtp.sendRawMessage(bytes, from: MailMIME.address(from), to: recipients.map(MailMIME.address))
            try await smtp.disconnect()
        } catch { try? await smtp.disconnect(); report(error, host: config.smtp.host); throw Self.classify(error) }
    }
    public func idle(in mailbox: String, renewalInterval: TimeInterval) async throws -> AsyncStream<MailPushEvent> {
        if !capabilities.contains("IDLE") { return AsyncStream { $0.finish() } }
        guard !closed else { throw CancellationError() }
        let server = Self.makeIMAP(config.imap)
        do {
            await server.setReconnectsInsideCommands(false)
            try await server.connect(); try await server.login(username: config.username, password: password)
            _ = try await server.selectMailbox(mailbox)
            // Enter IDLE before returning so a delivery immediately after startup is observed.
            let first = try await server.idle()
            // A disconnect during the awaits above found no IDLE connection to close. Keeping this one leaked a
            // logged-in connection per reconnect, until Gmail refused new sign-ins (too many simultaneous connections).
            if closed || idleServer != nil { try? await server.done(); try? await server.disconnect(); throw CancellationError() }
            idleServer = server
            let pair = AsyncStream<MailPushEvent>.makeStream(), host = config.imap.host
            idleContinuation = pair.continuation
            let task = Task { [weak self] in
                var events = first
                do {
                    while !Task.isCancelled {
                        let renewal = Task {
                            do { try await Task.sleep(nanoseconds: UInt64(max(1, renewalInterval) * 1_000_000_000)); try await server.done() } catch {}
                        }
                        for await event in events {
                            if Task.isCancelled { break }
                            switch event {
                            case .exists, .expunge, .fetch, .fetchUID, .vanished: pair.continuation.yield(.changed)
                            case .bye: renewal.cancel(); throw MailError.cannotConnect
                            default: break
                            }
                        }
                        renewal.cancel()
                        try Task.checkCancellation()
                        guard await server.isConnected else { throw MailError.cannotConnect }
                        events = try await server.idle()
                    }
                } catch {
                    if !(error is CancellationError) {
                        await self?.report(error, host: host)
                        pair.continuation.yield(.disconnected(Self.classify(error)))
                    }
                }
                pair.continuation.finish()
                try? await server.done(); try? await server.disconnect()
                await self?.idleEnded()
            }
            idleTask = task
            // Cancelled directly too: once the transport is gone, `self` can't, and the loop kept the connection alive.
            pair.continuation.onTermination = { [weak self] _ in task.cancel(); Task { await self?.cancelIdle() } }
            return pair.stream
        } catch {
            try? await server.disconnect()
            if error is CancellationError { throw error }
            report(error, host: config.imap.host); throw Self.classify(error)
        }
    }
    private func idleEnded() { idleTask = nil; idleServer = nil; idleContinuation = nil }
    private func cancelIdle() async {
        idleTask?.cancel()
        if let server = idleServer { try? await server.done(); try? await server.disconnect() }
    }
    static func classify(_ error: Error) -> MailError {
        if let value = error as? MailError { return value }
        if let value = error as? IMAPError {
            switch value {
            case .authFailed(let reason), .loginFailed(let reason): return signInRefusal(reason)
            case .timeout: return .timeout
            case .connectionFailed: return connectionError(error)
            case .commandNotSupported: return .unsupported
            default: return .serverRejected("IMAP command refused")
            }
        }
        if let value = error as? SMTPError {
            switch value {
            case .authenticationFailed(let reason): return signInRefusal(reason)
            case .tlsFailed: return .tlsFailure
            case .connectionFailed: return connectionError(error)
            default: return .serverRejected("SMTP command refused")
            }
        }
        if let value = error as? SMTPSendError {
            switch value.reason {
            case .timedOut: return .timeout
            case .connectionLost: return .cannotConnect
            case .reply(let response): return response.code >= 500 ? .serverRejected("SMTP \(response.code)") : .cannotConnect
            default: return .cannotConnect
            }
        }
        return connectionError(error)
    }
    /// A sign-in the server turns down for now (too many connections, an outage, a rate limit) retries like a
    /// dropped connection. Anything else, wrong credentials included, is a failed sign-in, which waits for new
    /// credentials or a manual reconnect.
    static func signInRefusal(_ reason: String) -> MailError {
        let text = reason.uppercased()
        let permanent = ["AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED", "CONTACTADMIN", "PRIVACYREQUIRED"]
        let temporary = ["UNAVAILABLE", "INUSE", "LIMIT", "SERVERBUG", "THROTTLED", "TOO MANY", "TRY AGAIN", "TEMPORAR"]
        if permanent.contains(where: text.contains) { return .authenticationFailed }
        return temporary.contains(where: text.contains) ? .cannotConnect : .authenticationFailed
    }
    private static func connectionError(_ error: Error) -> MailError {
        let description = String(describing: error).lowercased()
        if description.contains("tls") || description.contains("ssl") || description.contains("certificate") { return .tlsFailure }
        if description.contains("timeout") || description.contains("timed out") { return .timeout }
        let code = (error as NSError).code
        if (error as NSError).domain == NSURLErrorDomain && code == NSURLErrorNotConnectedToInternet { return .offline }
        return .cannotConnect
    }
}

extension MailEngine {
    public init(baseDirectory: URL, credentialStore: any MailCredentialStore) throws {
        try self.init(baseDirectory: baseDirectory, credentialStore: credentialStore,
                      transportFactory: { SwiftMailTransport(config: $0, password: $1) })
    }
}
