import Foundation

/// The vault and hostless in-memory stores share the same commit boundary.
@MainActor
protocol MistPasswordSyncStorage: AnyObject {
    var data: MistPasswordData { get }
    var syncDidCommit: ((MistPasswordData, MistPasswordData) throws -> Void)? { get set }
    func load() throws
    func change(_ edit: (inout MistPasswordData) -> Void, reportingLocalChanges: Bool) throws
}

@MainActor
final class MistPasswordSyncSource: MistSyncSource {
    let kinds: Set<String> = ["login", "never-save", "email"]
    var onChange: (([MistSyncRecord]) throws -> Void)?
    private let store: MistPasswordSyncStorage

    init(store: MistPasswordSyncStorage) {
        self.store = store
        store.syncDidCommit = { [weak self] old, new in
            let records = Self.diff(old: old, new: new)
            if !records.isEmpty { try self?.onChange?(records) }
        }
    }

    static func record(_ login: MistLogin) -> MistSyncRecord {
        MistSyncRecord(kind: "login", id: login.id.uuidString,
                       payload: ["site": .string(login.site), "username": .string(login.username),
                                 "password": .string(login.password)])
    }

    static func record(_ email: MistEmail) -> MistSyncRecord {
        MistSyncRecord(kind: "email", id: email.id, payload: ["address": .string(email.address)])
    }

    static func diff(old: MistPasswordData, new: MistPasswordData) -> [MistSyncRecord] {
        let before = Dictionary(uniqueKeysWithValues: old.logins.map { ($0.id, record($0)) })
        let after = Dictionary(uniqueKeysWithValues: new.logins.map { ($0.id, record($0)) })
        var changes = after.values.filter { before[UUID(uuidString: $0.id)!] != $0 }
        for login in old.logins where after[login.id] == nil {
            changes.append(MistSyncRecord(kind: "login", id: login.id.uuidString, deleted: true))
        }
        for host in new.neverSave.subtracting(old.neverSave) {
            changes.append(MistSyncRecord(kind: "never-save", id: host))
        }
        for host in old.neverSave.subtracting(new.neverSave) {
            changes.append(MistSyncRecord(kind: "never-save", id: host, deleted: true))
        }
        let oldEmails = Dictionary(uniqueKeysWithValues: old.emails.map { ($0.id, record($0)) })
        let newEmails = Dictionary(uniqueKeysWithValues: new.emails.map { ($0.id, record($0)) })
        changes += newEmails.values.filter { oldEmails[$0.id] != $0 }
        for email in old.emails where newEmails[email.id] == nil {
            changes.append(MistSyncRecord(kind: "email", id: email.id, deleted: true))
        }
        return changes.sorted { $0.versionKey < $1.versionKey }
    }

    func snapshot() throws -> [MistSyncRecord] {
        try store.load()
        return store.data.emails.map(Self.record) + store.data.logins.map(Self.record) + store.data.neverSave.sorted().map {
            MistSyncRecord(kind: "never-save", id: $0)
        }
    }

    func apply(_ record: MistSyncRecord) async throws {
        switch record.kind {
        case "login":
            guard let id = UUID(uuidString: record.id) else { throw MistSyncError.invalidRecord }
            if record.deleted {
                try store.change({ $0.logins.removeAll { $0.id == id } }, reportingLocalChanges: false)
            } else {
                guard let site = record.payload["site"]?.string, MistPasswordMatching.origin(site) != nil,
                      let username = record.payload["username"]?.string,
                      let password = record.payload["password"]?.string else { throw MistSyncError.invalidRecord }
                try store.change({ data in
                    if let index = data.logins.firstIndex(where: { $0.id == id }) {
                        data.logins[index].site = site
                        data.logins[index].username = username
                        data.logins[index].password = password
                    } else {
                        data.logins.append(MistLogin(id: id, site: site, username: username, password: password))
                    }
                }, reportingLocalChanges: false)
            }
        case "email":
            guard !record.id.isEmpty else { throw MistSyncError.invalidRecord }
            if record.deleted {
                try store.change({ $0.removeEmail(id: record.id) }, reportingLocalChanges: false)
            } else {
                guard let raw = record.payload["address"]?.string,
                      let address = MistEmailAddress.normalized(raw), address.lowercased() == record.id else {
                    throw MistSyncError.invalidRecord
                }
                try store.change({ $0.insertEmail(address) }, reportingLocalChanges: false)
            }
        case "never-save":
            guard !record.id.isEmpty else { throw MistSyncError.invalidRecord }
            try store.change({ data in
                if record.deleted { data.neverSave.remove(record.id) } else { data.neverSave.insert(record.id) }
            }, reportingLocalChanges: false)
        default: throw MistSyncError.unknownKind
        }
    }

    func deduplicate(versions: [String: String]) throws {
        try store.load()
        struct Identity: Hashable {
            let origin: String
            let username: String
            let password: String
            init(_ login: MistLogin) {
                origin = MistPasswordMatching.origin(login.site) ?? login.site
                username = login.username
                password = login.password
            }
        }
        let applied = Set(store.data.logins.filter { versions["login/\($0.id.uuidString)"] != nil }.map(Identity.init))
        let duplicates = Set(store.data.logins.filter {
            versions["login/\($0.id.uuidString)"] == nil && applied.contains(Identity($0))
        }.map(\.id))
        if !duplicates.isEmpty {
            try store.change({ $0.logins.removeAll { duplicates.contains($0.id) } }, reportingLocalChanges: false)
        }
    }
}

extension MistPasswordVault: MistPasswordSyncStorage {}
