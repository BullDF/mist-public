import Foundation

@MainActor
enum MistBrowserDataSyncChecks {
    static func profile(_ id: String = "default", _ name: String = "Default") -> MistSyncRecord {
        MistSyncRecord(kind: "profile", id: id, payload: ["name": .string(name)])
    }
    static func space(_ id: String, profile: String = "default", name: String? = nil, order: Int = 0) -> MistSyncRecord {
        MistSyncRecord(kind: "space", id: id, payload: ["name": .string(name ?? id), "profile": .string(profile),
            "color": .string("#123456"), "icon": .string("star"), "order": .number(Double(order))])
    }
    static func bookmark(_ id: String, space: String = "s", parent: String? = nil, index: Int = 0,
                         folder: Bool = false, title: String? = nil) -> MistSyncRecord {
        MistSyncRecord(kind: "bookmark", id: id, payload: ["space": .string(space), "parent": parent.map(MistSyncValue.string) ?? .null,
            "index": .number(Double(index)), "folder": .bool(folder), "title": .string(title ?? id),
            "url": .string(folder ? "https://bookmark.phi/folder" : "https://\(id).example/"),
            "secondaryUrl": .null, "secondaryTitle": .null, "layout": .null])
    }

    static func run() async throws {
        let directory = try syncTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MistMemoryBrowserDataStore()
        var source = MistBrowserDataSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        // Deliberately deliver dependencies in reverse order, across a restart.
        try await source.apply(bookmark("child", parent: "folder"))
        source = MistBrowserDataSyncSource(store: store, directory: directory)
        source.onChange = { changes += $0 }
        try await source.apply(bookmark("folder", folder: true))
        try await source.apply(space("s"))
        try expectSync(store.data.bookmarks.isEmpty, "Missing profile holds the whole dependency chain")
        try await source.apply(profile())
        try expectSync(store.data.bookmarks.count == 2 && changes.isEmpty, "Persisted pending dependencies drain without echo")
        try await source.apply(bookmark("z", index: 1))
        try await source.apply(bookmark("a", index: 1))
        let order = try source.snapshot().filter { $0.kind == "bookmark" && $0.payload["parent"] == .null }
            .sorted { $0.payload["index"]!.number! < $1.payload["index"]!.number! }.map(\.id)
        try expectSync(order == ["folder", "a", "z"], "Sibling ties use sync IDs and normalize")
        try source.flushLocalChanges()
        try expectSync(changes.isEmpty, "Normalization does not echo")
        try await source.apply(space("other", order: 1))
        try await source.apply(bookmark("child", space: "other"))
        try expectSync(store.data.bookmarks.first { $0.syncID == "child" }?.space == "other", "Move between Spaces")
        try await source.apply(bookmark("child", parent: "folder"))
        try expectSync(store.data.bookmarks.first { $0.syncID == "child" }?.parent != nil, "Move into a folder")
        try await source.apply(bookmark("second-folder", folder: true))
        try await source.apply(bookmark("child", parent: "second-folder"))
        try expectSync(store.data.bookmarks.first { $0.syncID == "child" }?.parent == store.data.bookmarks.first { $0.syncID == "second-folder" }?.localID,
                       "Move between folders")
        try await source.apply(MistSyncRecord(kind: "bookmark", id: "second-folder", deleted: true))
        try expectSync(!store.data.bookmarks.contains { $0.syncID == "child" }, "Deleting a folder cascades")
        try await source.apply(bookmark("late-child", parent: "second-folder"))
        try await source.apply(MistSyncRecord(kind: "bookmark", id: "child", deleted: true))
        try expectSync(!store.data.bookmarks.contains { $0.syncID == "late-child" }, "Late child of a deleted dependency is dropped")
        try await source.apply(profile("work", "Work"))
        try await source.apply(space("other", profile: "work", order: 1))
        try expectSync(store.data.spaces.first { $0.localID == "other" }?.profile == store.data.profiles.first { $0.syncID == "work" }?.localID,
                       "A Space changes profiles")
        changes = []
        let local = MistBrowserSyncBookmark(localID: "LOCAL-GUID", space: "s", title: "Local", url: "https://local.example/")
        store.data.bookmarks.append(local)
        try source.flushLocalChanges()
        try expectSync(changes.count == 1 && changes[0].id == "local-guid", "Snapshot diff assigns lowercase GUIDs")
        changes = []
        store.data.bookmarks.removeAll { $0.localID == local.localID }
        try source.flushLocalChanges()
        try expectSync(changes.count == 1 && changes[0].deleted, "Snapshot diff emits tombstones")
        try await dedupe(directory: directory.appendingPathComponent("dedupe"))
        try await edgeCases(directory: directory.appendingPathComponent("edges"))
        try await debouncedConflict(directory: directory.appendingPathComponent("conflict"))
        try exclusions(directory: directory.appendingPathComponent("exclude"))
    }

    static func dedupe(directory: URL) async throws {
        let store = MistMemoryBrowserDataStore()
        store.data.profiles = [MistBrowserSyncProfile(localID: "Default", name: "Default"),
                               MistBrowserSyncProfile(localID: "Profile 9", name: "Work")]
        store.data.spaces = [MistBrowserSyncSpace(localID: "local-space", profile: "Profile 9", name: "Work Space")]
        store.data.bookmarks = [MistBrowserSyncBookmark(localID: "local-folder", space: "local-space", folder: true,
            title: "folder", url: "https://bookmark.phi/folder"),
            MistBrowserSyncBookmark(localID: "local-child", space: "local-space", parent: "local-folder", title: "child", url: "https://child.example/")]
        let source = MistBrowserDataSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.apply(bookmark("remote-child", space: "remote-space", parent: "remote-folder", title: "child").withURL("https://child.example/"))
        try await source.apply(bookmark("remote-folder", space: "remote-space", folder: true, title: "folder"))
        try await source.apply(space("remote-space", profile: "remote-profile", name: "Work Space"))
        try await source.apply(profile("remote-profile", "Work"))
        try source.deduplicate(versions: ["profile/remote-profile": "v", "space/remote-space": "v",
                                         "bookmark/remote-folder": "v", "bookmark/remote-child": "v"])
        let records = try source.snapshot()
        try expectSync(store.data.profiles.count == 2 && store.data.profiles[1].syncID == "remote-profile", "Profiles dedupe by name")
        try expectSync(store.data.spaces.count == 1 && records.contains { $0.kind == "space" && $0.id == "remote-space" }, "Spaces dedupe by profile and name")
        try expectSync(store.data.bookmarks.count == 2 && Set(store.data.bookmarks.compactMap(\.syncID)) == ["remote-folder", "remote-child"],
                       "Bookmarks dedupe by mapped Space, parent, folder flag, title and URL")
        try expectSync(changes.isEmpty, "Identity adoption emits neither local edits nor tombstones")
        let restored = MistBrowserDataSyncSource(store: store, directory: directory)
        try expectSync(try restored.snapshot().contains { $0.kind == "space" && $0.id == "remote-space" }, "Space aliases survive restart")
    }

    static func edgeCases(directory: URL) async throws {
        let store = MistMemoryBrowserDataStore()
        let source = MistBrowserDataSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try await source.apply(profile())
        try await source.apply(space("s"))
        try await source.apply(bookmark("pending", parent: "old-parent", title: "Old"))
        try await source.apply(bookmark("pending", parent: "new-parent", title: "New"))
        try await source.apply(bookmark("old-parent", folder: true))
        try expectSync(!store.data.bookmarks.contains { $0.syncID == "pending" }, "A newer held record replaces its old dependency")
        try await source.apply(bookmark("new-parent", folder: true))
        try expectSync(store.data.bookmarks.first { $0.syncID == "pending" }?.title == "New", "Only the latest held payload lands")
        try await source.apply(MistSyncRecord(kind: "space", id: "s", deleted: true))
        try await source.apply(MistSyncRecord(kind: "profile", id: "default", deleted: true))
        try await source.apply(bookmark("after-ignored-delete"))
        try expectSync(store.data.spaces.count == 1 && store.data.bookmarks.contains { $0.syncID == "after-ignored-delete" },
                       "Ignored default profile and last-Space deletes do not invalidate dependencies")
        try await source.apply(profile("work", "Work"))
        try await source.apply(space("work-space", profile: "work"))
        try await source.apply(MistSyncRecord(kind: "profile", id: "work", deleted: true))
        try expectSync(store.data.profiles.contains { $0.syncID == "work" }, "Profile deletion waits for bound Spaces")
        try await source.apply(MistSyncRecord(kind: "space", id: "work-space", deleted: true))
        try expectSync(!store.data.profiles.contains { $0.syncID == "work" }, "A later Space delete releases the profile tombstone")

        changes = []
        store.beforeProfileWrite = {
            try await Task.sleep(nanoseconds: 5_000_000)
            let i = store.data.bookmarks.firstIndex { $0.syncID == "pending" }!
            store.data.bookmarks[i].title = "Local edit during async creation"
            store.didChange?()
        }
        try await source.apply(profile("async", "Async"))
        store.beforeProfileWrite = nil
        try expectSync(changes.count == 1 && changes[0].id == "pending" && changes[0].payload["title"] == .string("Local edit during async creation"),
                       "Unrelated user content edits survive asynchronous profile application")
        changes = []
        store.failAfterBookmarkWrite = true
        try await expectSyncThrowsAsync("Partial state-layer commit") { try await source.apply(bookmark("retry")) }
        try source.flushLocalChanges()
        try expectSync(changes.isEmpty, "A partial remote commit does not echo before retry")
        try await source.apply(bookmark("retry"))
        try expectSync(changes.isEmpty && store.data.bookmarks.filter { $0.syncID == "retry" }.count == 1, "Remote retry is idempotent")

        let exactStore = MistMemoryBrowserDataStore()
        exactStore.data.profiles = [MistBrowserSyncProfile(localID: "Default", name: "Default")]
        exactStore.data.spaces = [MistBrowserSyncSpace(localID: "exact-id", profile: "Default", name: "Shared name")]
        let exact = MistBrowserDataSyncSource(store: exactStore, directory: directory.appendingPathComponent("exact"))
        let incoming = [space("other-id", name: "Shared name"), space("exact-id", name: "Shared name")]
        exact.prepareIncoming(incoming)
        try await exact.apply(profile())
        for record in incoming { try await exact.apply(record) }
        try expectSync(exactStore.data.spaces.count == 2 && Set(try exact.snapshot().filter { $0.kind == "space" }.map(\.id)) == ["exact-id", "other-id"],
                       "An exact Space ID is reserved before a same-name record can adopt it")
    }

    static func exclusions(directory: URL) throws {
        let store = MistMemoryBrowserDataStore()
        store.data.profiles = [MistBrowserSyncProfile(localID: "Default", name: "Default"),
                               MistBrowserSyncProfile(localID: "agent", name: "Agent", excluded: true)]
        store.data.spaces = [MistBrowserSyncSpace(localID: "normal", profile: "Default", name: "Normal"),
                            MistBrowserSyncSpace(localID: "private", profile: "Default", name: "Incognito", excluded: true),
                            MistBrowserSyncSpace(localID: "agent-space", profile: "agent", name: "Agent")]
        store.data.bookmarks = [MistBrowserSyncBookmark(localID: "pin", space: "normal", title: "Pin", url: "https://pin.example", excluded: true),
                               MistBrowserSyncBookmark(localID: "private", space: "private", title: "Private", url: "https://private.example")]
        let source = MistBrowserDataSyncSource(store: store, directory: directory)
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        try expectSync(try source.snapshot().map(\.kind).sorted() == ["profile", "space"], "Agent, incognito and non-bookmark rows are excluded")
        store.data.spaces[0].excluded = true
        try source.flushLocalChanges()
        try expectSync(changes.isEmpty, "Temporary exclusion never sends deletion tombstones")
    }

    static func debouncedConflict(directory: URL) async throws {
        let store = MistMemoryBrowserDataStore()
        store.data.profiles = [MistBrowserSyncProfile(localID: "Default", name: "Default")]
        store.data.spaces = [MistBrowserSyncSpace(localID: "s", profile: "Default", name: "s")]
        store.data.bookmarks = [MistBrowserSyncBookmark(localID: "page", space: "s", title: "Original", url: "https://page.example/")]
        let source = MistBrowserDataSyncSource(store: store, directory: directory)
        let engine = MistSyncEngine(keyStorage: MemorySyncKeys(), stateDirectory: directory, connectAutomatically: false)
        engine.register(source)
        let credentials = try MistSyncCredentials(serverURL: "https://sync.example", groupKey: Data(0..<32))
        try engine.enable(credentials)
        try await engine.receive(syncFrame(MistSyncFrame(t: "synced", seq: 0)))
        store.data.bookmarks[0].title = "Pending local edit"
        var remote = bookmark("page", title: "Remote")
        remote.hlc = "008000000000000-000000-remote"
        var wire = try MistSyncCrypto(groupKey: credentials.groupKey).seal(remote)
        wire.seq = 1
        try await engine.receive(syncFrame(MistSyncFrame(t: "records", items: [wire])))
        try expectSync(store.data.bookmarks[0].title == "Pending local edit" && engine.state.versions["bookmark/page"]! > remote.hlc,
                       "A debounced local edit is clocked before the incoming conflict check")
    }
}

extension MistSyncValue {
    var number: Double? { if case .number(let value) = self { return value }; return nil }
}

extension MistSyncRecord {
    func withURL(_ url: String) -> Self {
        var copy = self
        copy.payload["url"] = .string(url)
        return copy
    }
}
