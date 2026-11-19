import CryptoKit
import Foundation

@main
struct MistSyncTests {
    @MainActor static func main() async throws {
        try clocks()
        try encryption()
        try pairing()
        try await mergingAndPersistence()
        try await asynchronousApply()
        try await MistPasswordSyncTests.run()
        try await MistMailAccountSyncTests.run()
        try await MistClipboardSyncTests.run()
        try await MistClipboardPasteboardTests.run()
        try await MistBrowserDataSyncChecks.run()
        print("Mist sync hostless checks passed")
    }

    @MainActor static func asynchronousApply() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MemorySyncSource()
        let engine = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory, connectAutomatically: false)
        engine.register(source)
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        try engine.enable(credentials)
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 0)))
        var started = false
        source.beforeApply = {
            started = true
            try await Task.sleep(nanoseconds: 20_000_000)
            try engine.recordLocalChanges([MistSyncRecord(kind: "example", id: "local")])
        }
        func frame(_ id: String, seq: Int64) throws -> String {
            var wire = try MistSyncCrypto(groupKey: credentials.groupKey).seal(
                MistSyncRecord(kind: "example", id: id, hlc: String(format: "%015lld-000000-remote", seq)))
            wire.seq = seq
            return try syncFrame(MistSyncFrame(t: "records", items: [wire]))
        }
        let firstFrame = try frame("first", seq: 1), secondFrame = try frame("second", seq: 2)
        let first = Task { try await engine.receive(firstFrame) }
        while !started { await Task.yield() }
        try expectSync(engine.state.cursor == 0, "An awaiting apply does not advance the cursor")
        let second = Task { try await engine.receive(secondFrame) }
        try await first.value
        try await second.value
        try expectSync(source.applied == ["first", "second"] && engine.state.cursor == 2,
                       "Concurrent receives apply strictly serially")
        try expectSync(engine.state.outbox["example/local"] != nil,
                       "Local changes survive an asynchronous apply")
    }

    static func clocks() throws {
        var clock = MistSyncClock()
        let a = try clock.tick(deviceID: "a", now: 100)
        let b = try clock.tick(deviceID: "a", now: 90)
        let c = try clock.tick(deviceID: "a", receiving: "000000000000200-999999-b", now: 120)
        try expectSync(a == "000000000000100-000000-a", "Fixed-width clock encoding")
        try expectSync(a < b && b < c && c == "000000000000201-000000-a", "Rollback, receive and counter overflow")
        let d = try clock.tick(deviceID: "a", now: 1000)
        try expectSync(d > c, "Wall time advances the clock")
        try expectSyncThrows("Malformed clock") { _ = try MistSyncClock.parts("200-0-b") }
    }

    static func encryption() throws {
        let keys = try MistSyncCrypto(groupKey: Data(0..<32))
        try expectSync(keys.token == "lBU2G7oeF_VXczKawXAcO4qlFu3iSqxA4xj8lthuBdY", "Deterministic auth derivation")
        try expectSync(keys.serverID(kind: "login", id: "example") == "a60YGFEB7xN7hFbty0ILWHRbAsfriCEAG1pbaowEBDs", "Deterministic opaque ID")
        let record = MistSyncRecord(kind: "example", id: "one", hlc: "000000000000100-000000-a",
                                    payload: ["secret": .string("password"), "nested": .array([.bool(true), .null])])
        var wire = try keys.seal(record)
        try expectSync(try keys.open(wire) == record, "AES-GCM envelope round-trip")
        wire.hlc = "999999999999999-999999-untrusted"
        try expectSync(try keys.open(wire).hlc == record.hlc, "Envelope HLC is authoritative")
        try expectSyncThrows("Wrong group key") { _ = try MistSyncCrypto(groupKey: Data(repeating: 1, count: 32)).open(wire) }
        wire.id = String(repeating: "a", count: 43)
        try expectSyncThrows("Opaque ID mismatch") { _ = try keys.open(wire) }
        wire = try keys.seal(record)
        var bytes = Data(base64Encoded: wire.blob)!
        bytes[bytes.count - 1] ^= 1
        wire.blob = bytes.base64EncodedString()
        try expectSyncThrows("Ciphertext tampering") { _ = try keys.open(wire) }
    }

    static func pairing() throws {
        let value = try MistSyncCredentials(serverURL: "https://sync.example/", groupKey: Data(0..<32))
        try expectSync(try MistSyncCredentials.parse(value.pairingCode) == value, "Pairing round-trip")
        try expectSync(value.webSocketURL.absoluteString == "wss://sync.example/v1/connect", "WebSocket endpoint")
        for code in ["", "mist-sync:!", "other:" + value.pairingCode, value.pairingCode + "=",
                     "mist-sync:" + MistSyncBase64.encode(Data("{}".utf8))] {
            try expectSyncThrows("Invalid pairing code") { _ = try MistSyncCredentials.parse(code) }
        }
        for url in ["http://sync.example", "https://user:pass@sync.example", "https://sync.example/path", "https://sync.example?q=1"] {
            try expectSyncThrows("Unsafe server URL") { _ = try MistSyncCredentials(serverURL: url, groupKey: Data(0..<32)) }
        }
        try expectSyncThrows("Invalid key length") { _ = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data()) }
        try expectSync(MistSyncKeychain.service(bundleID: "com.bulldf.mist.dev") == "Mist Sync (com.bulldf.mist.dev)", "Separate Dev credentials")
    }

    @MainActor static func mergingAndPersistence() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = MemorySyncKeys()
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        let crypto = try MistSyncCrypto(groupKey: credentials.groupKey)
        let source = MemorySyncSource()
        let engine = MistSyncEngine(keyStorage: keys, stateDirectory: directory, connectAutomatically: false)
        engine.register(source)
        try engine.enable(credentials)
        func wire(_ id: String, _ time: Int, seq: Int64, deleted: Bool = false) throws -> MistSyncWireRecord {
            var value = try crypto.seal(MistSyncRecord(kind: "example", id: id,
                hlc: String(format: "%015lld-000000-remote", Int64(time)), deleted: deleted))
            value.seq = seq
            return value
        }
        // A live broadcast precedes hello catch-up: the initial marker must apply in seq order.
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("two", 8_000_000_000_000, seq: 2)])))
        var observed = engine.state.clock
        try expectSync(try observed.tick(deviceID: "test", now: 0) > "008000000000000-000000-remote",
                       "Local edits exceed remote clocks even while catch-up is buffered")
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("one", 1, seq: 1)])))
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 2)))
        try expectSync(source.applied == ["one", "two"], "Initial records apply in seq order")
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("one", 0, seq: 3)])))
        try expectSync(source.applied.count == 2 && engine.state.cursor == 3, "Stale records only advance the cursor")
        source.failID = "fail"
        try await expectSyncThrowsAsync("Failed apply") {
            try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("ok", 3, seq: 4), try wire("fail", 9_000_000_000_000, seq: 5)])))
        }
        try expectSync(engine.state.cursor == 4, "Cursor stops after last successful apply")
        try expectSync(try MistSyncStateStore(directory: directory).load().cursor == 4, "Cursor persisted only after apply")
        try engine.recordLocalChanges([MistSyncRecord(kind: "example", id: "local")])
        try expectSync(engine.state.outbox["example/local"]!.hlc > "009000000000000-000000-remote",
                       "An apply failure still advances the observed clock")
        source.failID = nil
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("fail", 9_000_000_000_000, seq: 5)])))
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [try wire("one", 5, seq: 6, deleted: true)])))
        try expectSync(source.records["one"] == nil, "Newer tombstone applies")
        try engine.recordLocalChanges([MistSyncRecord(kind: "example", id: "local", payload: ["secret": .string("plaintext-secret")])])
        let first = engine.state.outbox["example/local"]!.hlc
        try engine.recordLocalChanges([MistSyncRecord(kind: "example", id: "local", deleted: true)])
        try expectSync(engine.state.outbox.count == 1 && engine.state.outbox["example/local"]!.hlc > first, "Outbox coalesces latest per record")
        let disk = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
        try expectSync(!disk.contains("plaintext-secret"), "Outbox is encrypted at rest")
        let restored = MistSyncEngine(keyStorage: keys, stateDirectory: directory, connectAutomatically: false)
        restored.register(MemorySyncSource())
        let future = MemorySyncSource(kind: "future")
        future.records["existing"] = MistSyncRecord(kind: "future", id: "existing")
        restored.register(future)
        restored.start()
        try expectSync(restored.state.cursor == 6 && restored.state.outbox == engine.state.outbox, "Restart restores cursor and outbox")
        try await restored.receive(syncFrame(MistSyncFrame(t: "synced", seq: 6)))
        try expectSync(restored.state.outbox["future/existing"] != nil,
                       "A new source uploads existing records without engine changes or re-pairing")
        try restored.turnOff()
        try expectSync(keys.value == nil && !FileManager.default.fileExists(atPath: directory.path), "Turn off deletes only sync state and credentials")
    }
}
