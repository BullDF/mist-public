import Foundation

@MainActor
enum MistClipboardSyncTests {
    @MainActor final class Peer {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var slot: String? = UUID().uuidString
        var records: [MistSyncRecord] = []
        let directory: URL
        let defaults: UserDefaults
        var source: MistClipboardSyncSource!
        init(_ root: URL, _ name: String, lifetime: TimeInterval = 300, defaults: UserDefaults? = nil) {
            directory = root.appendingPathComponent(name)
            self.defaults = defaults ?? UserDefaults(suiteName: root.appendingPathComponent(UUID().uuidString).path)!
            source = MistClipboardSyncSource(directory: directory, slot: { [unowned self] in self.slot },
                deviceName: { name }, now: { [unowned self] in self.time }, timersEnabled: false, lifetime: lifetime, defaults: self.defaults)
            source.onChange = { [unowned self] in self.records.append(contentsOf: $0) }
        }
        func take() -> [MistSyncRecord] { defer { records = [] }; return records }
        func receive(_ records: [MistSyncRecord]) async throws {
            for record in records { try await source.apply(record) }
            try await source.waitForPendingChanges()
        }
        func restart() throws {
            source = MistClipboardSyncSource(directory: directory, slot: { [unowned self] in self.slot },
                deviceName: { "Restarted" }, now: { [unowned self] in self.time }, timersEnabled: false, defaults: defaults)
            source.onChange = { [unowned self] in self.records.append(contentsOf: $0) }
            try source.flushPendingChanges()
        }
    }

    static func text(_ value: String) -> MistClipboardDraft { MistClipboardDraft(type: .text, data: Data(value.utf8), uti: "public.utf8-plain-text") }
    static func file(_ count: Int) -> MistClipboardDraft {
        MistClipboardDraft(type: .file, data: Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }), name: "Example.bin", uti: "public.data")
    }

    static func run() async throws {
        let root = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, check) in [("transfer", transferAndLimits), ("ordering", orderAndClear),
                              ("expiry/restart", expirationAndRestart), ("malformed/cache", malformedAndCache), ("sharing", sharingSwitch)] {
            do { try await check(root) }
            catch { throw SyncTestFailure(description: "Clipboard \(name): \(error)") }
        }
        print("Mist clipboard checks passed: limits, sealed chunks, shuffled assembly, ordering, cleanup, expiry, restart, and cache")
    }

    static func sharingSwitch(_ root: URL) async throws {
        let suite = root.appendingPathComponent(UUID().uuidString).path
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let a = Peer(root, "sharing-a", defaults: defaults), b = Peer(root, "sharing-b")
        try expectSync(a.source.sharing, "Sharing defaults on")
        a.source.setSharing(false)
        try expectSync(defaults.object(forKey: MistClipboardSyncSource.sharingKey) as? Bool == false, "Switch persists")
        try a.restart()
        try expectSync(!a.source.sharing, "Restart retains off")
        for action in [{ try a.source.send(text("blocked")) }, { try a.source.clear() }] {
            do { try action(); throw SyncTestFailure(description: "Sharing-off action succeeded") }
            catch MistClipboardError.sharingOff {}
        }
        try expectSync(a.take().isEmpty, "Off emits no sends")
        try b.source.send(file(70_000))
        try await a.receive(b.take())
        try expectSync(a.source.current == nil, "Off hides incoming item")
        for folder in ["Items", "Chunks"] {
            let files = try? FileManager.default.contentsOfDirectory(atPath: a.directory.appendingPathComponent(folder).path)
            try expectSync(files?.isEmpty ?? true, "Off retains no content")
        }
        a.source.setSharing(true)
        try expectSync(a.source.current == nil, "Re-enabling hides previously observed head")
        try a.restart()
        try expectSync(a.source.current == nil, "Visibility cutoff survives restart")
        let next = file(40_000)
        try b.source.send(next)
        try await a.receive(b.take())
        try expectSync(try a.source.data(for: a.source.current!) == next.data, "Next send arrives byte-identically")
        try a.source.send(file(70_000))
        try await b.receive(a.take())
        a.source.setSharing(false)
        try expectSync(a.source.current == nil && b.source.current != nil, "Off only hides locally")
        a.time = a.time.addingTimeInterval(301)
        try a.source.flushPendingChanges()
        let expired = a.take()
        try expectSync(expired.count == 4 && expired.allSatisfy(\.deleted), "Off expires own head and chunks")
        try await b.receive(expired)
        try expectSync(b.source.current == nil, "Owner expiry clears remote")
        a.source.setSharing(true)
        try a.source.send(text("superseded"))
        try await b.receive(a.take())
        a.source.setSharing(false)
        try b.source.send(text("newer"))
        try await a.receive(b.take())
        try expectSync(a.take().filter(\.deleted).count == 2, "Off tombstones superseded own slot")
    }

    static func transferAndLimits(_ root: URL) async throws {
        let a = Peer(root, "limits-a"), b = Peer(root, "limits-b")
        try expectSync(try a.source.snapshot().isEmpty, "Clipboard never enters initial uploads")
        try expectSyncThrows("Empty") { try a.source.send(text("")) }
        try expectSyncThrows("Above cap") { try a.source.send(file(10_000_001)) }
        let draft = file(10_000_000)
        try a.source.send(draft)
        let records = a.take(), head = records.first { $0.id == a.slot }!
        let chunks = records.filter { $0.id != a.slot }
        try expectSync(records.count == 307 && chunks.count == 306, "Cap produces a head and 306 chunks")
        let crypto = try MistSyncCrypto(groupKey: Data(0..<32))
        var frame: [MistSyncWireRecord] = []
        for var record in records {
            record.hlc = "000000000000100-000000-a"
            let sealed = try crypto.seal(record)
            try expectSync(sealed.blob.utf8.count <= 65_536, "Every clipboard record fits the seal limit")
            frame.append(sealed)
        }
        print("Clipboard 10 MB sealed push frame: \(try JSONEncoder().encode(MistSyncFrame(t: "push", ref: 1, items: frame)).count) bytes")
        // Deliberately reverse the indices before applying the head last.
        try await b.receive(chunks.reversed())
        try expectSync(b.source.current == nil, "Chunks without a head are not shown")
        try await b.receive([head])
        let item = b.source.current!
        try expectSync(try b.source.data(for: item) == draft.data, "Shuffled chunks assemble byte-identically")
        try expectSync(item.type == .file && item.name == draft.name && item.uti == draft.uti && item.sender == "limits-a"
            && item.sent == a.time && !item.receiving, "All preview metadata survives transfer")
        try expectSync(!FileManager.default.fileExists(atPath: b.directory.appendingPathComponent("Chunks/\(item.id)").path),
                       "Assembly removes its chunk files")
        try a.source.send(text("small"))
        let smaller = a.take()
        try expectSync(smaller.filter(\.deleted).count == 305, "Smaller replacement tombstones leftover chunk IDs")
        try await b.receive(smaller)
        try expectSync(b.source.current?.text == "small", "A text send replaces a file")
        try expectSync(!FileManager.default.fileExists(atPath: b.directory.appendingPathComponent("Items/\(item.id)").path),
                       "Replacement deletes old assembled data")
    }

    static func orderAndClear(_ root: URL) async throws {
        let a = Peer(root, "order-a"), b = Peer(root, "order-b"), c = Peer(root, "order-c")
        try a.source.send(file(70_000))
        let first = a.take()
        try await b.receive(first)
        b.time = b.time.addingTimeInterval(-100)
        try b.source.send(text("behind"))
        let second = b.take()
        try expectSync(second.first { $0.id == b.slot }!.payload["sentAt"] != first.first { $0.id == a.slot }!.payload["sentAt"],
                       "A clock behind advances past the observed high-water mark")
        var insideApply = false, reentered = false
        a.source.onChange = { [unowned a] records in
            reentered = reentered || insideApply
            a.records.append(contentsOf: records)
        }
        insideApply = true
        for record in second { try await a.source.apply(record) }
        insideApply = false
        try await a.source.waitForPendingChanges()
        try expectSync(!reentered, "Apply-generated cleanup reports on a later main-queue turn")
        let cleanup = a.take()
        try expectSync(cleanup.count == 4 && cleanup.allSatisfy(\.deleted), "Superseded owner tombstones head and every chunk")
        try expectSync(a.source.current?.text == "behind", "A later send wins despite clock rollback")
        try await c.receive(first)
        try await c.receive(second)
        try b.source.clear()
        let clear = b.take()
        try expectSync(clear.contains { $0.id == b.slot && $0.payload["cleared"] == .bool(true) }, "Clear writes a fresh marker")
        try await a.receive(clear)
        try await c.receive(clear)
        try expectSync(a.source.current == nil && b.source.current == nil && c.source.current == nil, "Clear empties all peers")
        // Removing a clear marker must never reveal older, still-unexpired heads.
        try await c.receive([MistSyncRecord(kind: "clipboard", id: b.slot!, deleted: true)])
        try expectSync(c.source.current == nil, "Older slots cannot resurface after a marker tombstone")
        b.time = b.time.addingTimeInterval(301)
        try b.source.flushPendingChanges()
        try expectSync(b.take().contains { $0.id == b.slot && $0.deleted }, "Clear markers also expire to tombstones")

        let d = Peer(root, "clear-owner"), e = Peer(root, "clear-other")
        try d.source.send(text("to clear"))
        try await e.receive(d.take())
        try e.source.clear()
        try await d.receive(e.take())
        try expectSync(d.take().filter(\.deleted).count == 2 && d.source.current == nil, "Clearing another slot makes its owner clean up")
    }

    static func expirationAndRestart(_ root: URL) async throws {
        let a = Peer(root, "expire-a", lifetime: 2), b = Peer(root, "expire-b")
        try a.source.send(file(40_000))
        let records = a.take(), old = a.source.current!
        try await b.receive(records)
        let copy = try b.source.cachedFileURL(for: b.source.current!)
        a.time = a.time.addingTimeInterval(2)
        b.time = b.time.addingTimeInterval(2)
        try a.source.flushPendingChanges(); try b.source.flushPendingChanges()
        try expectSync(a.source.current == nil && b.source.current == nil, "Expiry clears the preview at the deadline")
        try expectSync(a.take().filter(\.deleted).count == 3, "Expiry tombstones own head and chunks")
        try expectSync(!FileManager.default.fileExists(atPath: a.directory.appendingPathComponent("Items/\(old.id)").path), "Expired data is deleted")
        try expectSync(FileManager.default.fileExists(atPath: copy.path), "Copied files outlive expiry")
        try expectSyncThrows("Expired data") { _ = try a.source.data(for: old) }
        try expectSyncThrows("Expired cache") { _ = try a.source.cachedFileURL(for: old) }
        let late = Peer(root, "expire-late")
        late.time = late.time.addingTimeInterval(3)
        try await late.receive(records)
        try expectSync(late.source.current == nil, "An already expired head never appears")

        let future = Peer(root, "future"), receiver = Peer(root, "future-receiver")
        future.time = future.time.addingTimeInterval(1_000)
        try future.source.send(text("future"))
        try await receiver.receive(future.take())
        try expectSync(receiver.source.current?.expiry == receiver.time.addingTimeInterval(300), "Future send time is clamped to receipt time")

        let sender = Peer(root, "resume-sender"), resumed = Peer(root, "resume-receiver")
        try sender.source.send(file(90_000))
        let parts = sender.take(), head = parts.first { $0.id == sender.slot }!, chunks = parts.filter { $0.id != sender.slot }
        try await resumed.receive([head, chunks[0]])
        try expectSync(resumed.source.current?.receiving == true, "Partial content is shown as receiving")
        try resumed.restart()
        try expectSync(resumed.source.current?.receiving == true, "Restart restores a partial transfer")
        try await resumed.receive(Array(chunks.dropFirst()))
        let ready = resumed.source.current!
        try expectSync(try resumed.source.data(for: ready) == file(90_000).data, "Restart resumes assembly")
        try resumed.restart()
        try expectSync(resumed.source.current == ready, "Restart restores an assembled item and its original receipt deadline")
        let cached = try resumed.source.cachedFileURL(for: ready)
        resumed.slot = UUID().uuidString
        try resumed.source.flushPendingChanges()
        try expectSync(resumed.source.current == nil && FileManager.default.fileExists(atPath: cached.path), "New pairing resets source state and preserves copy cache")
        resumed.slot = nil
        try resumed.source.flushPendingChanges()
        try expectSyncThrows("Sync off") { try resumed.source.send(text("off")) }
    }

    static func malformedAndCache(_ root: URL) async throws {
        let a = Peer(root, "bad-a"), b = Peer(root, "bad-b")
        try a.source.send(file(40_000))
        let records = a.take(), head = records.first { $0.id == a.slot }!, chunk = records.first { $0.id != a.slot }!
        var invalid: [MistSyncRecord] = [MistSyncRecord(kind: "clipboard", id: "../bad")]
        for (key, value) in [("v", MistSyncValue.number(2)), ("type", .string("unknown")), ("size", .number(10_000_001)),
                             ("size", .number(0)), ("chunks", .number(1)), ("lifetime", .number(0)), ("lifetime", .number(301)),
                             ("sentAt", .number(.infinity)), ("item", .string("../../bad")), ("name", .bool(true))] {
            var bad = head; bad.payload[key] = value; invalid.append(bad)
        }
        for (key, value) in [("data", MistSyncValue.string("!")), ("data", .string(MistSyncBase64.encode(Data(repeating: 1, count: 32_769)))),
                             ("index", .number(400)), ("item", .string("../../bad"))] {
            var bad = chunk; bad.payload[key] = value; invalid.append(bad)
        }
        for bad in invalid { try await b.source.apply(bad) }
        try expectSync(b.source.current == nil, "Malformed records are ignored without throwing")
        try await b.receive([head])
        var wrongLength = chunk
        wrongLength.payload["data"] = .string(MistSyncBase64.encode(Data([1])))
        try await b.receive([wrongLength])
        try expectSync(b.source.current?.receiving == true, "Chunk length mismatch is ignored")
        try await b.receive(records)
        let first = b.source.current!, url = try b.source.cachedFileURL(for: first)
        try a.source.clear(); try await b.receive(a.take())
        try expectSync(FileManager.default.fileExists(atPath: url.path), "A clear marker preserves the copy cache")
        try a.source.send(MistClipboardDraft(type: .image, data: Data([1, 2, 3]), uti: "public.png"))
        try await b.receive(a.take())
        try expectSync(!FileManager.default.fileExists(atPath: url.path), "A newer item invalidates the previous copy cache")
        let image = b.source.current!, imageURL = try b.source.cachedFileURL(for: image)
        try expectSync(imageURL.pathExtension == "png", "An unnamed image uses its type extension")
        let files = try FileManager.default.contentsOfDirectory(atPath: b.directory.appendingPathComponent("Copied").path)
        try expectSync(files == [image.id], "Only the newest copied item is cached")
        let late = Peer(root, "cache-expired-arrival", lifetime: 2)
        late.time = late.time.addingTimeInterval(1)
        try late.source.send(text("already expired"))
        b.time = b.time.addingTimeInterval(4)
        try await b.receive(late.take())
        try expectSync(b.source.current == nil && FileManager.default.fileExists(atPath: imageURL.path),
                       "An already expired arrival never replaces the copied item")
    }
}
