import Foundation

@MainActor
final class MemoryMailAccountStore: MistMailAccountSyncStorage {
    var accounts: [MistMailSyncAccount] = []
    var failNextWrite = false
    var failNextRead = false
    var beforeRead: (() async -> Void)?
    var beforeWrite: (() async -> Void)?
    var afterWrite: (() -> Void)?
    var didChange: (() -> Void)?

    func read() async throws -> [MistMailSyncAccount] {
        await beforeRead?()
        if failNextRead { failNextRead = false; throw SyncTestFailure(description: "Injected mail read failure") }
        return accounts
    }
    func write(_ account: MistMailSyncAccount) async throws {
        if failNextWrite { failNextWrite = false; throw SyncTestFailure(description: "Injected mail write failure") }
        await beforeWrite?()
        var value = account
        if value.password == nil || value.password?.isEmpty == true {
            value.password = accounts.first { $0.id == value.id }?.password
        }
        if let index = accounts.firstIndex(where: { $0.id == value.id }) { accounts[index] = value }
        else { accounts.append(value) }
        afterWrite?()
        notify()
    }
    func delete(id: UUID) async throws { accounts.removeAll { $0.id == id }; notify() }
    func localEdit(_ edit: (inout [MistMailSyncAccount]) -> Void) { edit(&accounts); notify() }
    private func notify() { Task { [weak self] in self?.didChange?() } }
}

@MainActor
enum MistMailAccountSyncTests {
    static func account(_ name: String = "Personal", password: String? = "secret") -> MistMailSyncAccount {
        MistMailSyncAccount(id: UUID(), displayName: name, senderName: "Johnny", email: "johnny@example.com", username: "johnny",
            imap: .init(host: "imap.example.com", port: 993, security: "tls"),
            smtp: .init(host: "smtp.example.com", port: 587, security: "startTLS"), sortOrder: 3, isGmail: true, password: password)
    }

    static func drain(_ source: MistMailAccountSyncSource) async throws {
        for _ in 0..<20 { await Task.yield() }
        try await source.flushLocalChanges()
    }

    static func run() async throws {
        try await localChanges()
        try await remoteChanges()
        try await conflictsAndFailures()
        try await queuedLocalConflict()
        try await validation()
        try await joining()
        try await reordering()
        try await failedAdoption()
        try await initialReadFailure()
    }

    static func localChanges() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), original = account()
        store.accounts = [original]
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        try expectSyncThrows("Snapshot waits for initial read") { _ = try source.snapshot() }
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        let record = source.record(original)
        try expectSync(try source.snapshot() == [record] && changes.isEmpty, "Initial read snapshots every account without changes")
        try expectSync(record.payload == [
            "displayName": .string("Personal"), "senderName": .string("Johnny"), "email": .string("johnny@example.com"),
            "username": .string("johnny"), "imap": .object(["host": .string("imap.example.com"), "port": .number(993), "security": .string("tls")]),
            "smtp": .object(["host": .string("smtp.example.com"), "port": .number(587), "security": .string("startTLS")]),
            "sortOrder": .number(3), "isGmail": .bool(true), "password": .string("secret")], "Every account field is serialized")
        let added = account("Work")
        store.localEdit { $0.append(added) }
        try await drain(source)
        try expectSync(changes == [source.record(added)], "Local addition reports one full account")
        changes = []
        store.localEdit { $0[0].displayName = "Renamed" }
        try await drain(source)
        try expectSync(changes.count == 1 && changes[0].payload["displayName"] == .string("Renamed"), "Display name edit")
        changes = []
        store.localEdit { $0[0].password = "replacement" }
        try await drain(source)
        try expectSync(changes.count == 1 && changes[0].payload["password"] == .string("replacement"), "Password edit")
        changes = []
        store.localEdit { $0[0].sortOrder = 9 }
        try await drain(source)
        try expectSync(changes.count == 1 && changes[0].payload["sortOrder"] == .number(9), "Sort order edit")
        changes = []
        store.localEdit { $0.removeAll { $0.id == original.id } }
        try await drain(source)
        try expectSync(changes == [MistSyncRecord(kind: "mail-account", id: original.id.uuidString, deleted: true)], "Local removal tombstone")
    }

    static func remoteChanges() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), source = MistMailAccountSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        var remote = account()
        try await source.apply(source.record(remote)); try await drain(source)
        try expectSync(store.accounts == [remote] && changes.isEmpty, "Full remote account round-trip without echo")
        remote.displayName = "Remote"; remote.senderName = "Other sender"; remote.username = "new user"
        remote.email = "new@example.com"; remote.imap.port = 143; remote.imap.security = "plaintext"
        remote.smtp.host = "other.example.com"; remote.sortOrder = -2; remote.isGmail = false; remote.password = "new"
        try await source.apply(source.record(remote)); try await drain(source)
        try expectSync(store.accounts == [remote] && changes.isEmpty, "Remote update round-trips all fields without echo")
        var withoutPassword = source.record(remote)
        withoutPassword.payload["password"] = .null
        try await source.apply(withoutPassword); try await drain(source)
        try expectSync(store.accounts[0].password == "new" && changes.isEmpty, "Null password preserves credentials")
        withoutPassword.payload["password"] = nil
        try await source.apply(withoutPassword); try await drain(source)
        try expectSync(store.accounts[0].password == "new" && changes.isEmpty, "Absent password preserves credentials")
        let missing = account("Missing", password: nil)
        try await source.apply(source.record(missing)); try await drain(source)
        try expectSync(store.accounts.last == missing && changes.isEmpty, "New account may have no password")
        try await source.apply(MistSyncRecord(kind: "mail-account", id: remote.id.uuidString, deleted: true))
        try await drain(source)
        try expectSync(store.accounts == [missing] && changes.isEmpty, "Remote tombstone never echoes")
        try await source.apply(MistSyncRecord(kind: "mail-account", id: UUID().uuidString, deleted: true))
        try await drain(source)
        try expectSync(store.accounts == [missing] && changes.isEmpty, "Unknown tombstone is a no-op")
    }

    static func conflictsAndFailures() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), source = MistMailAccountSyncSource(store: store, directory: directory)
        let a = account(), b = account("Work")
        store.accounts = [a, b]
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        store.localEdit { $0[0].displayName = "Local wins" }
        var remote = source.record(a)
        remote.payload["displayName"] = .string("Remote loses")
        // Enqueue apply before the fake engine delivers its delayed change event.
        try await source.apply(remote); try await drain(source)
        try expectSync(store.accounts[0].displayName == "Local wins" && changes.count == 1, "Pending local edit wins same-account conflict")
        changes = []
        store.beforeWrite = {
            store.localEdit { $0[1].displayName = "Other local edit" }
            await Task.yield()
        }
        remote.payload["displayName"] = .string("Remote wins")
        try await source.apply(remote)
        store.beforeWrite = nil
        try await drain(source)
        try expectSync(store.accounts[0].displayName == "Remote wins" && changes.count == 1 && changes[0].id == b.id.uuidString,
                       "Apply does not absorb another account's concurrent local edit")
        changes = []
        store.failNextWrite = true
        try await expectSyncThrowsAsync("Injected write failure") { try await source.apply(remote) }
        try await drain(source)
        try expectSync(changes.isEmpty, "Failed write leaves baseline untouched")
        // Re-read can fail after a successful write; its fallback must still suppress the remote echo.
        store.afterWrite = { store.failNextRead = true }
        remote.payload["displayName"] = .string("Applied despite read failure"); remote.payload["password"] = .null
        try await expectSyncThrowsAsync("Injected read failure after write") { try await source.apply(remote) }
        store.afterWrite = nil
        try await drain(source)
        try expectSync(changes.isEmpty && store.accounts[0].password == a.password, "Read failure fallback keeps password and suppresses echo")
        // Callback failures retry the diff at the next explicit boundary.
        source.onChange = { _ in throw SyncTestFailure(description: "Injected commit failure") }
        store.accounts[1].sortOrder = 77
        do { try await source.flushLocalChanges(); throw SyncTestFailure(description: "Expected callback failure") }
        catch let error as SyncTestFailure { try expectSync(error.description == "Injected commit failure", "Commit failed as injected") }
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        try expectSync(changes.count == 1 && changes[0].payload["sortOrder"] == .number(77), "Failed local commit retries unchanged baseline")
    }

    static func validation() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), source = MistMailAccountSyncSource(store: store, directory: directory)
        try await source.flushLocalChanges()
        let valid = source.record(account())
        var bad = valid; bad.id = "not-a-uuid"
        var invalid = [bad]
        bad = valid; bad.kind = "other"; invalid.append(bad)
        bad = valid; bad.payload["email"] = nil; invalid.append(bad)
        for port in [0.0, 70000.0, 993.5] {
            bad = valid; bad.payload["imap"] = .object(["host": .string("imap.example.com"), "port": .number(port), "security": .string("tls")]); invalid.append(bad)
        }
        bad = valid; bad.payload["smtp"] = .object(["host": .string("smtp.example.com"), "port": .number(587), "security": .string("unknown")]); invalid.append(bad)
        for order in [0.5, Double.infinity, Double(Int.max)] {
            bad = valid; bad.payload["sortOrder"] = .number(order); invalid.append(bad)
        }
        bad = valid; bad.payload["isGmail"] = .number(1); invalid.append(bad)
        bad = valid; bad.payload["password"] = .bool(false); invalid.append(bad)
        for record in invalid {
            do { try await source.apply(record); throw SyncTestFailure(description: "Invalid mail record accepted") }
            catch MistSyncError.invalidRecord {} // Assert the specific validation error.
        }
        try expectSync(store.accounts.isEmpty, "Invalid records store nothing")
    }

    static func queuedLocalConflict() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), local = account()
        store.accounts = [local]
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        var reading = false
        var releaseRead: CheckedContinuation<Void, Never>?
        store.beforeRead = {
            store.beforeRead = nil
            reading = true
            await withCheckedContinuation { releaseRead = $0 }
        }
        store.localEdit { $0[0].displayName = "Local queued edit" }
        while !reading { await Task.yield() }
        let applying = Task { try await source.apply(source.record(local)) }
        for _ in 0..<20 { await Task.yield() }
        releaseRead?.resume()
        try await applying.value
        try await drain(source)
        try expectSync(store.accounts[0].displayName == "Local queued edit" && changes.count == 1,
                       "A local flush already waiting on MailEngine wins the queued remote apply")
    }

    static func joining() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = account("Remote", password: "remote password")
        var local = remote; local.id = UUID(); local.displayName = "Local"; local.sortOrder = 10
        local.email = remote.email.uppercased(); local.imap.host = remote.imap.host.uppercased()
        var distinct = account("Distinct"); distinct.email = "different@example.com"
        let store = MemoryMailAccountStore()
        store.accounts = [local, distinct]
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        try await source.flushLocalChanges()
        let engine = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("sync"),
                                    connectAutomatically: false, monitorNetwork: false)
        engine.register(source)
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        try engine.enable(credentials)
        var record = source.record(remote)
        record.hlc = "000000000000001-000000-remote"
        var wire = try MistSyncCrypto(groupKey: credentials.groupKey).seal(record); wire.seq = 1
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [wire])))
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 1)))
        try await drain(source)
        var adopted = remote; adopted.id = local.id
        try expectSync(store.accounts == [adopted, distinct], "Joining adopts local UUID with remote fields")
        try expectSync(engine.state.outbox.count == 1 && engine.state.outbox["mail-account/\(distinct.id.uuidString)"] != nil,
                       "Initial upload contains only distinct local account")
        store.localEdit { $0[0].displayName = "Edited after joining" }
        try await drain(source)
        let key = "mail-account/\(remote.id.uuidString)"
        let uploaded = try engine.state.outbox[key].map { try MistSyncCrypto(groupKey: credentials.groupKey).open($0) }
        try expectSync(uploaded?.payload["displayName"] == .string("Edited after joining")
                       && engine.state.outbox["mail-account/\(local.id.uuidString)"] == nil, "Later local edit uses remote ID")
        let reopened = MistMailAccountSyncSource(store: store, directory: directory)
        try await reopened.flushLocalChanges()
        try expectSync(try reopened.snapshot().contains { $0.id == remote.id.uuidString }
                       && !reopened.snapshot().contains { $0.id == local.id.uuidString }, "Alias survives source recreation")
        var changes: [MistSyncRecord] = []
        reopened.onChange = { changes += $0 }
        store.localEdit { $0.removeAll { $0.id == local.id } }
        try await drain(reopened)
        try expectSync(changes == [MistSyncRecord(kind: "mail-account", id: remote.id.uuidString, deleted: true)], "Adopted removal uses remote ID")
        let aliases = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: directory.appendingPathComponent("mail-accounts.json")))
        try expectSync(aliases.isEmpty, "Removal drops persisted alias")
    }

    /// A reorder gives every account a new position above the old ones (`MailEngine.reorderAccounts`), so its
    /// records go out in one batch of consecutive clocks and a concurrent reorder from another Mac wins or loses whole.
    static func reordering() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore()
        store.accounts = (0..<3).map { var value = account("Account \($0)"); value.sortOrder = $0; return value }
        let a = store.accounts[0].id, b = store.accounts[1].id, c = store.accounts[2].id
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        try await source.flushLocalChanges()
        let engine = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("sync"),
                                    connectAutomatically: false, monitorNetwork: false)
        engine.register(source)
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        let crypto = try MistSyncCrypto(groupKey: credentials.groupKey)
        try engine.enable(credentials)
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 0)))
        var batches: [[MistSyncRecord]] = []
        let record = source.onChange
        source.onChange = { batches.append($0); try record?($0) }
        func reordered(_ accounts: [MistMailSyncAccount], _ ids: [UUID]) -> [MistMailSyncAccount] {
            let top = accounts.map(\.sortOrder).max() ?? -1
            return accounts.map { value in var value = value; value.sortOrder = top + 1 + ids.firstIndex(of: value.id)!; return value }
        }
        func order() -> [UUID] { store.accounts.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }.map(\.id) }
        var seq: Int64 = 0
        func receive(_ accounts: [MistMailSyncAccount], at milliseconds: Int64) async throws {
            let items = try accounts.enumerated().map { offset, value in
                var record = source.record(value)
                record.hlc = String(format: "%015lld-%06d-remote", milliseconds, offset)
                var wire = try crypto.seal(record); seq += 1; wire.seq = seq
                return wire
            }
            try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: items)))
            try await drain(source)
        }
        let original = store.accounts
        store.localEdit { $0 = reordered($0, [c, a, b]) }
        try await drain(source)
        try expectSync(batches.count == 1 && Set(batches[0].map(\.id)) == Set([a, b, c].map(\.uuidString)) && order() == [c, a, b],
                       "A local reorder reports every account in one batch")
        try await receive(reordered(original, [b, c, a]), at: 1)
        try expectSync(order() == [c, a, b] && batches.count == 1, "An older remote reorder loses as a whole")
        try await receive(reordered(original, [b, a, c]), at: 9_000_000_000_000)
        try expectSync(order() == [b, a, c] && Set(store.accounts.map(\.sortOrder)).count == 3 && batches.count == 1,
                       "A newer remote reorder wins as a whole, with distinct positions and no echo")
    }

    static func failedAdoption() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore(), local = account(), remote = account("Remote")
        store.accounts = [local]
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.flushLocalChanges()
        store.failNextWrite = true
        try await expectSyncThrowsAsync("Failed adoption") { try await source.apply(source.record(remote)) }
        try await drain(source)
        try expectSync(changes.isEmpty && store.accounts == [local] && source.record(local).id == local.id.uuidString,
                       "Failed adoption rolls alias back without inventing local changes")
        source.prepare(versions: ["mail-account/\(local.id.uuidString)": "already synced"])
        try await source.apply(source.record(remote)); try await drain(source)
        try expectSync(store.accounts == [local, remote] && changes.isEmpty, "Previously synced accounts are never adopted")
    }

    static func initialReadFailure() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryMailAccountStore()
        store.failNextRead = true
        let source = MistMailAccountSyncSource(store: store, directory: directory)
        var errors = 0
        source.onError = { _ in errors += 1 }
        for _ in 0..<20 { await Task.yield() }
        try expectSync(try source.snapshot().isEmpty && errors == 1, "Failed initial read reports error and leaves empty snapshot")
        try await source.flushLocalChanges()
    }
}
