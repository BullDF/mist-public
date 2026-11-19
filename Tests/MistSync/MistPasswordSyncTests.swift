import CryptoKit
import Foundation

@MainActor
enum MistPasswordSyncTests {
    static func run() async throws {
        let store = MemoryPasswordStore()
        let source = MistPasswordSyncSource(store: store)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        let login = MistLogin(site: "https://example.com", username: "johnny", password: "secret")
        try store.change { $0.logins.append(login); $0.neverSave.insert("never.example") }
        try expectSync(changes.count == 2 && changes.map(\.kind) == ["login", "never-save"], "Local login and exclusion additions")
        changes = []
        try store.change { $0.logins[0].lastUsed = Date() }
        try expectSync(changes.isEmpty, "Last used is per Mac")
        var remote = MistPasswordSyncSource.record(login)
        remote.payload["password"] = .string("remote")
        let lastUsed = store.data.logins[0].lastUsed
        try await source.apply(remote)
        try expectSync(store.data.logins[0].lastUsed == lastUsed && changes.isEmpty, "Remote edits retain last used without echo")
        let new = MistLogin(site: "https://new.example", username: "", password: "new")
        try await source.apply(MistPasswordSyncSource.record(new))
        try expectSync(store.data.logins.last?.lastUsed == .distantPast, "New remote login has never been used locally")
        try store.change { $0.logins[0].username = "changed"; $0.neverSave.remove("never.example") }
        try expectSync(changes.count == 2 && changes.last?.deleted == true, "Local edits and never-save removal")
        changes = []
        try store.change { $0.logins.removeAll { $0.id == login.id } }
        try expectSync(changes.count == 1 && changes[0].deleted && changes[0].id == login.id.uuidString, "Local deletion emits tombstone")
        changes = []
        remote.deleted = true
        try await source.apply(remote)
        try await source.apply(MistSyncRecord(kind: "never-save", id: "remote.example"))
        try await source.apply(MistSyncRecord(kind: "never-save", id: "remote.example", deleted: true))
        try expectSync(changes.isEmpty && !store.data.neverSave.contains("remote.example"), "Remote deletions and exclusions never echo")

        var duplicate = new
        duplicate.id = UUID()
        duplicate.site += "/path?q=ignored"
        var different = duplicate
        different.id = UUID()
        different.password = "different"
        try store.change({ $0.logins += [duplicate, different] }, reportingLocalChanges: false)
        try source.deduplicate(versions: ["login/\(new.id.uuidString)": "applied"])
        try expectSync(Set(store.data.logins.map(\.id)) == [new.id, different.id] && changes.isEmpty,
                       "Initial dedupe uses origin, username and password without tombstones")

        try expectSync(source.kinds.contains("email"), "Email sync kind is registered")
        try store.change { $0.insertEmail("Johnny@example") }
        try expectSync(changes == [MistSyncRecord(kind: "email", id: "johnny@example",
                                                  payload: ["address": .string("Johnny@example")])], "Email add emits upsert")
        changes = []
        try store.change { $0.insertEmail("JOHNNY@example") }
        try expectSync(changes.count == 1 && changes[0].payload["address"] == .string("JOHNNY@example"), "Casing change syncs")
        changes = []
        try store.change { $0.emails[0].lastUsed = Date() }
        try expectSync(changes.isEmpty, "Email usage stays local")
        let emailLastUsed = store.data.emails[0].lastUsed
        let emailRecord = MistSyncRecord(kind: "email", id: "johnny@example", payload: ["address": .string("Johnny@example")])
        try await source.apply(emailRecord)
        try await source.apply(emailRecord)
        try expectSync(store.data.emails.count == 1 && store.data.emails[0].lastUsed == emailLastUsed && changes.isEmpty,
                       "Remote email upserts deduplicate and retain local usage without echo")
        try expectSync(try source.snapshot().contains(emailRecord), "Snapshot includes email")
        for invalid in [MistSyncRecord(kind: "email", id: "bad", payload: ["address": .string("bad")]),
                        MistSyncRecord(kind: "email", id: "other@example", payload: ["address": .string("Johnny@example")]),
                        MistSyncRecord(kind: "email", id: "", payload: ["address": .string("Johnny@example")])] {
            do {
                try await source.apply(invalid)
                throw SyncTestFailure(description: "Invalid email accepted")
            } catch MistSyncError.invalidRecord {}
        }
        try store.change { $0.removeEmail(id: "johnny@example") }
        try expectSync(changes == [MistSyncRecord(kind: "email", id: "johnny@example", deleted: true)], "Email removal emits tombstone")
        changes = []
        try await source.apply(emailRecord)
        try await source.apply(MistSyncRecord(kind: "email", id: emailRecord.id, deleted: true))
        try expectSync(store.data.emails.isEmpty && changes.isEmpty, "Remote email deletion never echoes")

        // Exercise the real encrypted vault commit hook, including CSV imports.
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let vault = MistPasswordVault(file: directory.appendingPathComponent("vault"), keyProvider: { _ in key })
        let vaultSource = MistPasswordSyncSource(store: vault)
        var committed: [MistSyncRecord] = []
        vaultSource.onChange = { committed += $0 }
        _ = try vault.importCSV("url,username,password\nhttps://csv.example,user,pass\n", domain: { $0 })
        try expectSync(committed.count == 1 && committed[0].payload["password"] == .string("pass"), "CSV import reports committed changes")
        try vault.change { $0.logins[0].lastUsed = Date() }
        try expectSync(committed.count == 1, "Real vault also ignores last used")
        let reopened = MistPasswordVault(file: directory.appendingPathComponent("vault"), keyProvider: { _ in key })
        try reopened.load()
        try expectSync(reopened.data.version == 1 && reopened.data == vault.data, "Vault format and key are unchanged")

        // Joining a group removes the identical local ID and uploads only the distinct login.
        let syncDirectory = directory.appendingPathComponent("sync")
        let engine = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: syncDirectory, connectAutomatically: false)
        let joiningStore = MemoryPasswordStore()
        joiningStore.data.logins = [duplicate, different]
        engine.register(MistPasswordSyncSource(store: joiningStore))
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        try engine.enable(credentials)
        var record = MistPasswordSyncSource.record(new)
        record.hlc = "000000000000001-000000-remote"
        var wire = try MistSyncCrypto(groupKey: credentials.groupKey).seal(record)
        wire.seq = 1
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [wire])))
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 1)))
        try expectSync(Set(joiningStore.data.logins.map(\.id)) == [new.id, different.id], "Joining dedupes after remote catch-up")
        try expectSync(engine.state.outbox.count == 1 && engine.state.outbox["login/\(different.id.uuidString)"] != nil,
                       "Only unsynced distinct records upload initially")
    }
}
