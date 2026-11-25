import Foundation
@testable import MistMailCore

actor FakeMailServer: MailTransport {
    var boxes: [String: [MailRemoteMessage]] = ["INBOX": [], "Sent": [], "Drafts": [], "Trash": [], "Projects": []]
    var validity: [String: UInt32] = [:]
    var nextUID: [String: UInt32] = [:]
    var bodies: [String: MailBody] = [:]
    var parts: [String: Data] = [:]
    var gmail = false
    var failure: MailError?
    var actionFailure: MailError?
    var connectCount = 0
    var fetched: [String: [UInt32]] = [:]
    var sent: [Data] = []
    var envelopes: [[MailAddress]] = []
    var appended: [(String, Data)] = []
    var moveCount = 0
    var returnsCopyUID = true
    var pauseBeforeMove: (@Sendable () async -> Void)?
    var watchers: [UUID: AsyncStream<MailPushEvent>.Continuation] = [:]
    func check() throws { if let failure { throw failure } }
    func setFailure(_ value: MailError?) { failure = value }
    func setActionFailure(_ value: MailError?) { actionFailure = value }
    func omitCopyUID() { returnsCopyUID = false }
    func pauseNextMove(_ pause: @escaping @Sendable () async -> Void) { pauseBeforeMove = pause }
    func setGmail() { gmail = true; boxes["All Mail"] = []; boxes["Starred"] = []; boxes["Important"] = [] }
    func put(_ message: MailRemoteMessage, in mailbox: String = "INBOX", body: MailBody = .init(plainText: "Test body")) {
        boxes[mailbox, default: []].removeAll { $0.uid == message.uid }
        boxes[mailbox, default: []].append(message)
        nextUID[mailbox] = max(nextUID[mailbox] ?? 1, message.uid + 1)
        bodies["\(mailbox):\(message.uid)"] = body
        for watcher in watchers.values { watcher.yield(.changed) }
    }
    func remove(_ uid: UInt32, in mailbox: String = "INBOX") { boxes[mailbox]?.removeAll { $0.uid == uid } }
    func reset(_ mailbox: String) { boxes[mailbox] = []; validity[mailbox] = (validity[mailbox] ?? 1) + 1; nextUID[mailbox] = 1 }
    func connect() throws -> Set<String> { connectCount += 1; try check(); return gmail ? ["IDLE", "UIDPLUS", "X-GM-EXT-1"] : ["IDLE", "UIDPLUS"] }
    func disconnect() { for watcher in watchers.values { watcher.finish() }; watchers = [:] }
    func testSMTP() throws { try check() }
    func listMailboxes() throws -> [MailRemoteMailbox] {
        try check()
        return boxes.keys.sorted().map { name in
            .init(name: name, attributes: name == "All Mail" ? ["\\All"] : name == "Starred" ? ["\\Flagged"] : name == "Important" ? ["\\Important"] : [])
        }
    }
    func select(_ mailbox: String) throws -> MailSelection {
        try check(); guard boxes[mailbox] != nil else { throw MailError.serverRejected("No mailbox") }
        return .init(uidValidity: validity[mailbox] ?? 1, uidNext: nextUID[mailbox] ?? 1)
    }
    func search(_ query: MailUIDQuery, in mailbox: String) throws -> [UInt32] {
        try check()
        return (boxes[mailbox] ?? []).filter {
            switch query {
            case .all: return true
            case .since(let date): return $0.internalDate >= date
            case .range(let range): return range.contains($0.uid)
            case .text(let query): return $0.subject.localizedCaseInsensitiveContains(query)
            case .header(_, let query): return $0.messageID == query
            }
        }.map(\.uid)
    }
    func fetch(_ uids: [UInt32], in mailbox: String, gmail: Bool) throws -> [MailRemoteMessage] {
        try check(); fetched[mailbox, default: []] += uids; return (boxes[mailbox] ?? []).filter { uids.contains($0.uid) }
    }
    func flags(_ range: ClosedRange<UInt32>, in mailbox: String) throws -> [UInt32: Set<String>] {
        try check(); return Dictionary(uniqueKeysWithValues: (boxes[mailbox] ?? []).filter { range.contains($0.uid) }.map { ($0.uid, $0.flags) })
    }
    func body(_ message: MailRemoteMessage, in mailbox: String) throws -> MailBody { try check(); return bodies["\(mailbox):\(message.uid)"] ?? .init(plainText: "Test body") }
    func attachment(_ part: MailPart, uid: UInt32, in mailbox: String) throws -> Data { try check(); return parts[part.section] ?? Data("attachment".utf8) }
    func setFlag(_ flag: String, value: Bool, uids: [UInt32], in mailbox: String) throws {
        try check()
        if let actionFailure { throw actionFailure }
        for i in (boxes[mailbox] ?? []).indices where uids.contains(boxes[mailbox]![i].uid) {
            if value { boxes[mailbox]![i].flags.insert(flag) } else { boxes[mailbox]![i].flags.remove(flag) }
        }
    }
    func setFlag(_ flag: String, value: Bool, range: ClosedRange<UInt32>, in mailbox: String) throws {
        try setFlag(flag, value: value, uids: (boxes[mailbox] ?? []).filter { range.contains($0.uid) }.map(\.uid), in: mailbox)
    }
    func move(_ uids: [UInt32], from: String, to: String) async throws -> MailMoveResult? {
        try check(); guard boxes[to] != nil else { throw MailError.serverRejected("No destination") }
        moveCount += 1
        if let pauseBeforeMove {
            self.pauseBeforeMove = nil
            await pauseBeforeMove()
        }
        var mapping: [UInt32: UInt32] = [:]
        for var message in boxes[from] ?? [] where uids.contains(message.uid) {
            let original = message.uid; message.uid = nextUID[to] ?? 1
            mapping[original] = message.uid; put(message, in: to)
        }
        boxes[from]?.removeAll { uids.contains($0.uid) }
        return returnsCopyUID ? .init(uidValidity: validity[to] ?? 1, uids: mapping) : nil
    }
    func delete(_ uids: [UInt32], in mailbox: String) throws { try check(); boxes[mailbox]?.removeAll { uids.contains($0.uid) } }
    func createMailbox(_ name: String) throws { try check(); boxes[name] = boxes[name] ?? [] }
    func append(_ bytes: Data, to mailbox: String, flags: Set<String>) throws -> UInt32? {
        try check(); let uid = nextUID[mailbox] ?? 1; appended.append((mailbox, bytes))
        put(.init(uid: uid, messageID: try? MailMIME.decode(bytes).0.messageID, flags: flags), in: mailbox); return uid
    }
    /// Gmail files its own Sent copy of SMTP mail.
    func send(_ bytes: Data, from: MailAddress, recipients: [MailAddress]) throws {
        try check(); sent.append(bytes); envelopes.append(recipients)
        if gmail { put(.init(uid: nextUID["Sent"] ?? 1, messageID: try? MailMIME.decode(bytes).0.messageID, flags: [MailFlags.seen]), in: "Sent") }
    }
    func idle(in mailbox: String, renewalInterval: TimeInterval) -> AsyncStream<MailPushEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            watchers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeWatcher(id) } }
        }
    }
    func removeWatcher(_ id: UUID) { watchers[id] = nil }
}

func testConfig() -> MailAccountConfig {
    .init(displayName: "Test", senderName: "Me", email: "me@example.com", username: "me",
          imap: .init(host: "localhost", port: 143, security: .plaintext), smtp: .init(host: "localhost", port: 25, security: .plaintext))
}

final class EngineFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("mist-mail-test-\(UUID())")
    let server = FakeMailServer()
    let credentials = InMemoryMailCredentialStore()
    func engine() throws -> MailEngine {
        let server = server
        return try MailEngine(baseDirectory: base, credentialStore: credentials, transportFactory: { _, _ in server })
    }
    deinit { try? FileManager.default.removeItem(at: base) }
}
