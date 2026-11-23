import Foundation

struct MistMailSyncServer: Equatable {
    var host: String
    var port: Int
    var security: String
}

struct MistMailSyncAccount: Equatable {
    var id: UUID
    var displayName: String
    var senderName: String
    var email: String
    var username: String
    var imap: MistMailSyncServer
    var smtp: MistMailSyncServer
    var sortOrder: Int
    var isGmail: Bool
    var password: String?
    var signatureHTML: String? = nil
}

@MainActor
protocol MistMailAccountSyncStorage: AnyObject {
    /// Fresh account and credential snapshot; a credential read failure fails the whole read.
    func read() async throws -> [MistMailSyncAccount]
    /// A nil password keeps the stored one.
    func write(_ account: MistMailSyncAccount) async throws
    func delete(id: UUID) async throws
    var didChange: (() -> Void)? { get set }
}

@MainActor
final class MistMailAccountSyncSource: MistSyncSource {
    let kinds: Set<String> = ["mail-account"]
    var onChange: (([MistSyncRecord]) throws -> Void)?
    var onError: (Error) -> Void = { NSLog("[MistSync] Mail accounts: %@", String(describing: $0)) }
    private let store: MistMailAccountSyncStorage
    private let file: URL
    private var aliases: [String: UUID] = [:]
    private var loaded = false
    private var initialReadFinished = false
    private var baseline: [String: MistSyncRecord]?
    private var current: [String: MistSyncRecord]?
    private var accounts: [MistMailSyncAccount] = []
    private var versions: [String: String] = [:]
    private var localRevision: UInt64 = 0
    private var changedAt: [String: UInt64] = [:]
    private var queue: Task<Void, Never>?

    init(store: MistMailAccountSyncStorage, directory: URL) {
        self.store = store
        file = directory.appendingPathComponent("mail-accounts.json")
        store.didChange = { [weak self] in self?.scheduleFlush() }
        scheduleFlush()
    }

    func prepare(versions: [String: String]) { self.versions = versions }
    func deduplicate(versions: [String: String]) { self.versions = versions }

    /// All reads and applies share this queue, including callbacks caused by remote writes.
    private func enqueue<T>(_ operation: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        queue = Task { _ = await task.result }
        return task
    }

    private func scheduleFlush() {
        let task = enqueue { try await self.flush() }
        Task { [weak self] in
            do { _ = try await task.value } catch { self?.onError(error) }
        }
    }

    func flushLocalChanges() async throws {
        _ = try await enqueue { try await self.flush() }.value
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            aliases = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: file))
        }
        loaded = true
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(aliases).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func read() async throws -> [String: MistSyncRecord] {
        try load()
        accounts = try await store.read()
        return Dictionary(uniqueKeysWithValues: accounts.map { account in
            let value = record(account)
            return (value.versionKey, value)
        })
    }

    /// Returns the keys reported at this boundary so a pending local edit wins an incoming apply.
    private func flush() async throws -> Set<String> {
        defer { initialReadFinished = true }
        let values = try await read()
        current = values
        guard let baseline else { self.baseline = values; return [] }
        let edits = values.values.filter { baseline[$0.versionKey] != $0 }
        let removals = baseline.values.filter { values[$0.versionKey] == nil }.map {
            MistSyncRecord(kind: "mail-account", id: $0.id, deleted: true)
        }
        let changes = (edits + removals).sorted { $0.versionKey < $1.versionKey }
        if !changes.isEmpty {
            try onChange?(changes)
            localRevision += 1
            for change in changes { changedAt[change.versionKey] = localRevision }
        }
        self.baseline = values
        let removedAliases = removals.filter { aliases[$0.id] != nil }
        if !removedAliases.isEmpty {
            for value in removedAliases { aliases[value.id] = nil }
            try persist()
        }
        return Set(changes.map(\.versionKey))
    }

    func snapshot() throws -> [MistSyncRecord] {
        guard initialReadFinished else { throw MistSyncError.invalidConfiguration }
        return (current ?? [:]).values.sorted { $0.versionKey < $1.versionKey }
    }

    func record(_ account: MistMailSyncAccount) -> MistSyncRecord {
        let id = aliases.first { $0.value == account.id }?.key ?? account.id.uuidString
        return Self.record(account, id: id)
    }

    static func fitsBlobLimit(_ account: MistMailSyncAccount) throws -> Bool {
        var record = record(account, id: account.id.uuidString)
        var clock = MistSyncClock()
        record.hlc = try clock.tick(deviceID: account.id.uuidString)
        return try MistSyncCrypto.fitsBlobLimit(record)
    }

    private static func record(_ account: MistMailSyncAccount, id: String) -> MistSyncRecord {
        func server(_ value: MistMailSyncServer) -> MistSyncValue {
            .object(["host": .string(value.host), "port": .number(Double(value.port)), "security": .string(value.security)])
        }
        return MistSyncRecord(kind: "mail-account", id: id, payload: [
            "displayName": .string(account.displayName), "senderName": .string(account.senderName),
            "email": .string(account.email), "username": .string(account.username),
            "imap": server(account.imap), "smtp": server(account.smtp), "sortOrder": .number(Double(account.sortOrder)),
            "isGmail": .bool(account.isGmail), "password": account.password.map(MistSyncValue.string) ?? .null,
            "signature": account.signatureHTML.map(MistSyncValue.string) ?? .null])
    }

    func apply(_ record: MistSyncRecord) async throws {
        let revision = localRevision
        try await enqueue { try await self.applyQueued(record, revision: revision) }.value
    }

    private func applyQueued(_ incoming: MistSyncRecord, revision: UInt64) async throws {
        guard incoming.kind == "mail-account", let remoteID = UUID(uuidString: incoming.id) else {
            throw MistSyncError.invalidRecord
        }
        _ = try await flush()
        // A preceding queued flush may report the edit after apply was called but before
        // this operation starts. Its clock also wins, even though our own flush is now empty.
        if (changedAt[incoming.versionKey] ?? 0) > revision { return }
        let localID = aliases[incoming.id] ?? accounts.first { $0.id == remoteID }?.id
        var written: MistMailSyncAccount?
        var adoptedID: UUID?
        if incoming.deleted {
            if let localID { try await store.delete(id: localID) }
            if aliases.removeValue(forKey: incoming.id) != nil { try persist() }
        } else {
            var account = try Self.account(incoming, id: localID ?? remoteID)
            if localID == nil, let match = accounts.first(where: {
                $0.email.caseInsensitiveCompare(account.email) == .orderedSame && $0.username == account.username
                    && $0.imap.host.caseInsensitiveCompare(account.imap.host) == .orderedSame
                    && !aliases.values.contains($0.id) && versions["mail-account/\($0.id.uuidString)"] == nil
            }) {
                adoptedID = match.id
                account.id = match.id
                aliases[incoming.id] = match.id
                try persist()
            }
            do { try await store.write(account) } catch {
                // A failed adoption must not turn the untouched local account into an edit on the next read.
                if adoptedID != nil { aliases[incoming.id] = nil; try persist() }
                throw error
            }
            written = account
        }
        let previousPassword = current?[incoming.versionKey]?.payload["password"]
            ?? adoptedID.flatMap { baseline?["mail-account/\($0.uuidString)"]?.payload["password"] }
        // Commit only the applied key. Other accounts may have been edited while write awaited MailEngine.
        if let adoptedID { baseline?["mail-account/\(adoptedID.uuidString)"] = nil }
        do {
            let values = try await read()
            current = values
            baseline?[incoming.versionKey] = values[incoming.versionKey]
        } catch {
            if let written {
                var fallback = record(written)
                if written.password == nil || written.password?.isEmpty == true {
                    fallback.payload["password"] = previousPassword ?? .null
                }
                baseline?[incoming.versionKey] = fallback
                current?[incoming.versionKey] = fallback
            } else {
                baseline?[incoming.versionKey] = nil
                current?[incoming.versionKey] = nil
            }
            throw error
        }
    }

    private static func account(_ record: MistSyncRecord, id: UUID) throws -> MistMailSyncAccount {
        func string(_ object: [String: MistSyncValue], _ key: String) throws -> String {
            guard case .string(let value) = object[key] else { throw MistSyncError.invalidRecord }
            return value
        }
        func integer(_ value: MistSyncValue?) throws -> Int {
            guard case .number(let number) = value, number.isFinite, let result = Int(exactly: number) else {
                throw MistSyncError.invalidRecord
            }
            return result
        }
        func server(_ key: String) throws -> MistMailSyncServer {
            guard case .object(let object) = record.payload[key] else { throw MistSyncError.invalidRecord }
            let port = try integer(object["port"]), security = try string(object, "security")
            guard (1...65535).contains(port), ["tls", "startTLS", "plaintext"].contains(security) else {
                throw MistSyncError.invalidRecord
            }
            return MistMailSyncServer(host: try string(object, "host"), port: port, security: security)
        }
        guard case .bool(let gmail) = record.payload["isGmail"] else { throw MistSyncError.invalidRecord }
        let password: String?
        switch record.payload["password"] {
        case .string(let value): password = value
        case .null, nil: password = nil
        default: throw MistSyncError.invalidRecord
        }
        let signature: String?
        switch record.payload["signature"] {
        case .string(let value) where value.utf8.count <= 32 * 1024: signature = value
        case .null, nil: signature = nil
        default: throw MistSyncError.invalidRecord
        }
        return try MistMailSyncAccount(id: id, displayName: string(record.payload, "displayName"),
            senderName: string(record.payload, "senderName"), email: string(record.payload, "email"),
            username: string(record.payload, "username"), imap: server("imap"), smtp: server("smtp"),
            sortOrder: integer(record.payload["sortOrder"]), isGmail: gmail, password: password, signatureHTML: signature)
    }
}
