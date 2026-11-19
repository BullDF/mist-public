import Foundation

@main
struct MistSyncE2ETests {
    @MainActor static func wait(_ message: String, timeout: TimeInterval = 8,
                               until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw SyncTestFailure(description: "Timed out: \(message)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try MistSyncCredentials.create(serverURL: CommandLine.arguments[1])
        let keysA = MemorySyncKeys(), keysB = MemorySyncKeys()
        let storeA = MemoryPasswordStore(), storeB = MemoryPasswordStore()
        var a = MistSyncEngine(keyStorage: keysA, stateDirectory: directory.appendingPathComponent("a"), monitorNetwork: false)
        let b = MistSyncEngine(keyStorage: keysB, stateDirectory: directory.appendingPathComponent("b"), monitorNetwork: false)
        defer { a.disconnect(); b.disconnect() }
        a.register(MistPasswordSyncSource(store: storeA))
        b.register(MistPasswordSyncSource(store: storeB))

        let seed = MistLogin(site: "https://seed.example", username: "johnny", password: "seed")
        var duplicate = seed
        duplicate.id = UUID()
        storeA.data.logins = [seed]
        storeB.data.logins = [duplicate]
        try a.enable(credentials)
        try await wait("first Mac uploads initial snapshot") { a.status == .connected && a.state.outbox.isEmpty && a.state.cursor > 0 }
        try b.enable(MistSyncCredentials.parse(credentials.pairingCode))
        try await wait("second Mac catches up and dedupes") {
            b.status == .connected && storeB.data.logins.map(\.id) == [seed.id]
        }
        try expectSync(b.state.outbox.isEmpty, "Identical initial login never uploads")

        let login = MistLogin(site: "https://latency.example", username: "johnny", password: "one")
        let start = Date()
        try storeA.change { $0.logins.append(login) }
        try await wait("A edit reaches B within two seconds", timeout: 2) { storeB.data.logins.contains { $0.id == login.id } }
        let latency = Date().timeIntervalSince(start)
        print(String(format: "A → B propagation latency: %.1f ms", latency * 1000))
        try expectSync(latency < 2, "Online propagation under two seconds")

        try storeA.change { $0.logins.removeAll { $0.id == login.id } }
        try await wait("delete propagates") { !storeB.data.logins.contains { $0.id == login.id } }

        // Queue conflicting edits while disconnected, then reconnect both to the same relay.
        try await wait("outboxes empty before concurrency") { a.state.outbox.isEmpty && b.state.outbox.isEmpty }
        a.disconnect(); b.disconnect()
        try storeA.change { $0.logins[0].password = "from A" }
        try storeB.change { $0.logins[0].password = "from B" }
        let versionKey = "login/\(seed.id.uuidString)"
        let clockA = a.state.versions[versionKey]!, clockB = b.state.versions[versionKey]!
        let winner = clockA > clockB ? "from A" : "from B"
        let winningClock = max(clockA, clockB)
        a.connect(); b.connect()
        try await wait("concurrent edits converge to the greater HLC") {
            a.status == .connected && b.status == .connected && a.state.outbox.isEmpty && b.state.outbox.isEmpty &&
            storeA.data.logins[0].password == winner && storeB.data.logins[0].password == winner
        }
        try expectSync(a.state.versions[versionKey] == winningClock && b.state.versions[versionKey] == winningClock,
                       "Both clocks converge to the actual higher HLC")

        b.disconnect()
        try storeA.change { $0.logins[0].password = "missed while offline"; $0.neverSave.insert("never.example") }
        try await wait("online Mac commits missed edits") { a.state.outbox.isEmpty }
        b.connect()
        try await wait("offline Mac catches up on reconnect") {
            b.status == .connected && storeB.data.logins[0].password == "missed while offline" && storeB.data.neverSave.contains("never.example")
        }

        // Acknowledging an earlier send must not clear a later coalesced edit.
        for i in 0..<20 { try storeA.change { $0.logins[0].password = "burst-\(i)" } }
        try await wait("latest coalesced edit survives acknowledgments") {
            a.state.outbox.isEmpty && storeB.data.logins[0].password == "burst-19"
        }

        let cursorBeforeFailure = b.state.cursor
        storeB.failNextChange = true
        try storeA.change { $0.logins[0].password = "retry after apply failure" }
        try await wait("injected apply failure is reached") { !storeB.failNextChange }
        try expectSync(b.state.cursor == cursorBeforeFailure, "Failed source apply cannot advance the cursor")
        try expectSync(try MistSyncStateStore(directory: directory.appendingPathComponent("b")).load().cursor == cursorBeforeFailure,
                       "Disk cursor also stays before failed apply")
        try await wait("transport automatically retries a failed apply from the saved cursor") {
            b.status == .connected && storeB.data.logins[0].password == "retry after apply failure"
        }

        a.disconnect()
        try storeA.change { $0.logins[0].password = "persisted across restart" }
        a = MistSyncEngine(keyStorage: keysA, stateDirectory: directory.appendingPathComponent("a"), monitorNetwork: false)
        a.register(MistPasswordSyncSource(store: storeA))
        a.start()
        try await wait("persisted outbox survives process restart") {
            a.status == .connected && a.state.outbox.isEmpty && storeB.data.logins[0].password == "persisted across restart"
        }

        // An initial snapshot larger than a frame exercises the client's 500-record batching.
        let batch = (0..<501).map { MistLogin(site: "https://batch.example", username: "user-\($0)", password: "batch") }
        try storeA.change { $0.logins += batch }
        try await wait("multiple outbox batches arrive", timeout: 30) {
            a.state.outbox.isEmpty && storeB.data.logins.count == 502
        }
        print("Mist sync E2E passed: initial dedupe, edits, deletes, HLC convergence, reconnect, ack races, apply retry, restart, and batching")
        a.disconnect(); b.disconnect()
        try await browserData(serverURL: CommandLine.arguments[1], directory: directory.appendingPathComponent("browser"))
        try await clipboard(serverURL: CommandLine.arguments[1], directory: directory.appendingPathComponent("clipboard"))
    }

    @MainActor static func clipboard(serverURL: String, directory: URL) async throws {
        let a = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("a"), monitorNetwork: false)
        let b = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("b"), monitorNetwork: false)
        defer { a.disconnect(); b.disconnect() }
        let sourceA = MistClipboardSyncSource(directory: directory.appendingPathComponent("a/Clipboard"),
            slot: { [unowned a] in a.credentials == nil ? nil : a.state.deviceID }, deviceName: { "Mac A" })
        let sourceB = MistClipboardSyncSource(directory: directory.appendingPathComponent("b/Clipboard"),
            slot: { [unowned b] in b.credentials == nil ? nil : b.state.deviceID }, deviceName: { "Mac B" }, lifetime: 2)
        a.register(sourceA); b.register(sourceB)
        let credentials = try MistSyncCredentials.create(serverURL: serverURL)
        try a.enable(credentials); try b.enable(credentials)
        try await wait("clipboard peers connect") { a.status == .connected && b.status == .connected }
        let data = Data((0..<10_000_000).map { UInt8(truncatingIfNeeded: $0) })
        try sourceA.send(MistClipboardDraft(type: .file, data: data, name: "10 MB.bin", uti: "public.data"))
        let frameSize = try JSONEncoder().encode(MistSyncFrame(t: "push", ref: 1, items: Array(a.state.outbox.values))).count
        try await wait("10 MB clipboard file arrives", timeout: 30) {
            sourceB.current?.receiving == false && sourceB.current?.size == data.count && a.state.outbox.isEmpty
        }
        try expectSync(try sourceB.data(for: sourceB.current!) == data, "Full-size clipboard file arrives byte-identically through relay")
        try sourceB.send(MistClipboardDraft(type: .text, data: Data("replaces file".utf8), uti: "public.utf8-plain-text"))
        try await wait("text replaces file on both peers") {
            sourceA.current?.text == "replaces file" && sourceB.current?.text == "replaces file" && a.state.outbox.isEmpty && b.state.outbox.isEmpty
        }
        try sourceA.clear()
        try await wait("clear empties both clipboard peers") {
            sourceA.current == nil && sourceB.current == nil && a.state.outbox.isEmpty && b.state.outbox.isEmpty
        }
        try sourceB.send(MistClipboardDraft(type: .text, data: Data("expires soon".utf8)))
        try await wait("two-second item reaches both peers") { sourceA.current?.text == "expires soon" && sourceB.current?.text == "expires soon" }
        let headKey = "clipboard/\(b.state.deviceID)"
        let version = b.state.versions[headKey]!
        try await wait("expiry tombstones are acknowledged", timeout: 8) {
            sourceA.current == nil && sourceB.current == nil && b.state.outbox.isEmpty && b.state.versions[headKey] != version
        }
        try expectSync(b.state.versions[headKey] == a.state.versions[headKey], "Owner's expiry tombstone reaches the receiving engine")
        print("Mist clipboard E2E passed: 10,000,000 raw bytes, \(frameSize)-byte encrypted push frame, text replacement, clear, and acknowledged 2-second expiry")
    }

    @MainActor static func browserData(serverURL: String, directory: URL) async throws {
        let credentials = try MistSyncCredentials.create(serverURL: serverURL)
        let storeA = MistMemoryBrowserDataStore(), storeB = MistMemoryBrowserDataStore()
        for (store, suffix) in [(storeA, "a"), (storeB, "b")] {
            store.data.profiles = [MistBrowserSyncProfile(localID: "Default", name: "Default"),
                MistBrowserSyncProfile(localID: "work-\(suffix)", name: "Work")]
            store.data.spaces = [MistBrowserSyncSpace(localID: "space-\(suffix)", profile: "work-\(suffix)", name: "Work")]
            store.data.bookmarks = [MistBrowserSyncBookmark(localID: "folder-\(suffix)", space: "space-\(suffix)", folder: true,
                title: "Folder", url: "https://bookmark.phi/folder"),
                MistBrowserSyncBookmark(localID: "first-\(suffix)", space: "space-\(suffix)", parent: "folder-\(suffix)",
                    title: "First", url: "https://first.example/"),
                MistBrowserSyncBookmark(localID: "second-\(suffix)", space: "space-\(suffix)", parent: "folder-\(suffix)", index: 1,
                    title: "Second", url: "https://second.example/")]
        }
        let sourceA = MistBrowserDataSyncSource(store: storeA, directory: directory.appendingPathComponent("a"))
        let sourceB = MistBrowserDataSyncSource(store: storeB, directory: directory.appendingPathComponent("b"))
        let a = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("a"), monitorNetwork: false)
        let b = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory.appendingPathComponent("b"), monitorNetwork: false)
        defer { a.disconnect(); b.disconnect() }
        a.register(sourceA); b.register(sourceB)
        try a.enable(credentials)
        try await wait("browser seed uploads") { a.status == .connected && a.state.outbox.isEmpty && a.state.cursor > 0 }
        try b.enable(credentials)
        try await wait("joining browser dedupes its overlapping hierarchy") {
            b.status == .connected && b.state.outbox.isEmpty &&
            (try? sourceA.snapshot()) == (try? sourceB.snapshot())
        }
        try expectSync(storeB.data.profiles.count == 2 && storeB.data.spaces.count == 1 && storeB.data.bookmarks.count == 3,
                       "Joining keeps local rows while adopting all remote identities")
        _ = try await storeA.writeProfile(MistBrowserSyncProfile(localID: "extra-profile-a", name: "Extra"))
        try await storeA.writeSpace(MistBrowserSyncSpace(localID: "extra-space", profile: "extra-profile-a", name: "Extra", order: 1))
        try await storeA.writeBookmark(MistBrowserSyncBookmark(localID: "extra-folder", space: "extra-space", folder: true,
            title: "Extra folder", url: "https://bookmark.phi/folder"))
        for (index, id) in ["extra-first", "extra-second"].enumerated() {
            try await storeA.writeBookmark(MistBrowserSyncBookmark(localID: id, space: "extra-space", parent: "extra-folder",
                index: index, title: id, url: "https://\(id).example/"))
        }
        try await wait("a fresh profile, Space, folder and ordered pages are created on B") {
            storeB.data.profiles.count == 3 && storeB.data.spaces.count == 2 && storeB.data.bookmarks.count == 6 &&
            (try? sourceA.snapshot()) == (try? sourceB.snapshot())
        }
        let extraFolder = storeB.data.bookmarks.first { $0.syncID == "extra-folder" }!.localID
        try expectSync(storeB.data.bookmarks.filter { $0.parent == extraFolder }.sorted { $0.index < $1.index }.compactMap(\.syncID)
            == ["extra-first", "extra-second"], "Fresh hierarchy preserves exact sibling order")
        let start = Date()
        let localSpace = storeA.data.spaces.first { $0.name == "Work" }!.localID
        try await storeA.writeBookmark(MistBrowserSyncBookmark(localID: "new-page", space: localSpace,
            index: 1, title: "New", url: "https://new.example/"))
        try await wait("browser bookmark appears on B", timeout: 2) { storeB.data.bookmarks.contains { $0.syncID == "new-page" } }
        print(String(format: "Browser data A → B propagation latency (including debounce): %.1f ms", Date().timeIntervalSince(start) * 1000))

        let folderB = storeB.data.bookmarks.first { $0.title == "Folder" }!.localID
        for i in storeB.data.bookmarks.indices where storeB.data.bookmarks[i].parent == folderB {
            storeB.data.bookmarks[i].index = 1 - storeB.data.bookmarks[i].index
        }
        try sourceB.flushLocalChanges()
        try await wait("B reorder reaches A") { (try? sourceA.snapshot()) == (try? sourceB.snapshot()) && b.state.outbox.isEmpty }
        let moveIndex = storeB.data.bookmarks.firstIndex { $0.title == "First" }!
        storeB.data.bookmarks[moveIndex].parent = nil
        storeB.data.bookmarks[moveIndex].index = 2
        try sourceB.flushLocalChanges()
        try await wait("B move reaches A") { (try? sourceA.snapshot()) == (try? sourceB.snapshot()) && b.state.outbox.isEmpty }

        try await wait("outboxes drain before browser concurrency") { a.state.outbox.isEmpty && b.state.outbox.isEmpty }
        a.disconnect(); b.disconnect()
        for (store, source, reverse) in [(storeA, sourceA, false), (storeB, sourceB, true)] {
            let workSpace = store.data.spaces.first { $0.name == "Work" }!.localID
            let ids = store.data.bookmarks.filter { $0.parent == nil && $0.space == workSpace }.map(\.localID).sorted()
            for (rank, id) in (reverse ? ids.reversed().map { $0 } : ids).enumerated() {
                let i = store.data.bookmarks.firstIndex { $0.localID == id }!
                store.data.bookmarks[i].index = rank
            }
            try source.flushLocalChanges()
        }
        a.connect(); b.connect()
        try await wait("concurrent browser reorders converge") {
            a.status == .connected && b.status == .connected && a.state.outbox.isEmpty && b.state.outbox.isEmpty &&
            (try? sourceA.snapshot()) == (try? sourceB.snapshot())
        }
        let removed = storeB.data.bookmarks.first { $0.title == "New" }!.localID
        try await storeB.delete(kind: "bookmark", localID: removed)
        try await wait("browser delete propagates") { !storeA.data.bookmarks.contains { $0.syncID == "new-page" } }
        try await wait("final browser snapshots agree") { (try? sourceA.snapshot()) == (try? sourceB.snapshot()) }
        print("Mist browser data E2E passed: profiles, Spaces, folders, exact order, joining dedupe, moves, concurrent reorder convergence, and delete")
    }
}
