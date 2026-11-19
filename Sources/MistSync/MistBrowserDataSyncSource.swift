import Foundation

/// Browser identities, pending dependencies and the unnormalized LWW ranks live
/// outside SwiftData. Keeping ranks prevents partial reorder deliveries from
/// changing the meaning of a later record's index.
@MainActor
final class MistBrowserDataSyncSource: MistSyncSource {
    let kinds: Set<String> = ["profile", "space", "bookmark"]
    var onChange: (([MistSyncRecord]) throws -> Void)?
    var onError: (Error) -> Void = { NSLog("[MistSync] Browser data: %@", String(describing: $0)) }
    private let store: MistBrowserDataSyncStorage
    private let file: URL
    private var saved = Saved()
    private var loaded = false
    private var versions: [String: String] = [:]
    private var incomingSpaceIDs: Set<String> = []
    private var baseline: [String: MistSyncRecord]?
    private var applying = false
    private var remoteKeys: Set<String> = []
    private var changeTask: Task<Void, Never>?
    private var applyTask: Task<Void, Error>?
    private var applyCount = 0

    private struct Saved: Codable {
        var spaces: [String: String] = [:] // sync ID -> local ID, including dedupe aliases
        var records: [String: MistSyncRecord] = [:]
        var pending: [String: MistSyncRecord] = [:]
        var deleted: Set<String> = []
    }

    init(store: MistBrowserDataSyncStorage, directory: URL) {
        self.store = store
        file = directory.appendingPathComponent("browser-data.json")
        store.didChange = { [weak self] in self?.scheduleChanges() }
    }

    func prepare(versions: [String: String]) { self.versions = versions }
    func prepareIncoming(_ records: [MistSyncRecord]) {
        incomingSpaceIDs = Set(records.filter { $0.kind == "space" && !$0.deleted }.map(\.id))
    }
    func flushPendingChanges() throws { try flushLocalChanges() }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
        }
        loaded = true
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func scheduleChanges() {
        guard !applying else { return }
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                try self?.flushLocalChanges()
                // A local dependency or an ownership change can release a held
                // remote record without another relay message arriving.
                if let self, let pending = self.saved.pending.values.sorted(by: { $0.versionKey < $1.versionKey }).first {
                    try await self.apply(pending)
                }
            } catch is CancellationError {} catch { self?.onError(error) }
        }
    }

    /// Also an explicit commit boundary for deterministic hostless tests.
    func flushLocalChanges() throws {
        guard !applying else { return }
        let current = try snapshotMap()
        guard let baseline else { self.baseline = current; return }
        let raw = try store.read()
        let changes = Self.diff(before: baseline, after: current).filter { record in
            // Becoming temporarily excluded is not a user deletion.
            guard record.deleted else { return true }
            switch record.kind {
            case "profile": return !raw.profiles.contains { $0.syncID == record.id || ($0.localID == "Default" && record.id == "default") }
            case "space": return !raw.spaces.contains { spaceID($0.localID) == record.id }
            case "bookmark": return !raw.bookmarks.contains { ($0.syncID ?? $0.localID.lowercased()) == record.id }
            default: return true
            }
        }
        if !changes.isEmpty { try onChange?(changes) }
        for record in changes {
            saved.records[record.versionKey] = record
            if record.deleted { saved.deleted.insert(record.versionKey) }
        }
        try persist()
        self.baseline = current
    }

    static func diff(before: [String: MistSyncRecord], after: [String: MistSyncRecord]) -> [MistSyncRecord] {
        let edits = after.values.filter { before[$0.versionKey] != $0 }
        let deletes = before.values.filter { after[$0.versionKey] == nil }.map {
            MistSyncRecord(kind: $0.kind, id: $0.id, deleted: true)
        }
        return (edits + deletes).sorted { $0.versionKey < $1.versionKey }
    }

    func snapshot() throws -> [MistSyncRecord] {
        let current = try snapshotMap()
        if baseline == nil { baseline = current }
        return current.values.sorted { $0.versionKey < $1.versionKey }
    }

    private func dataWithIdentities() throws -> MistBrowserSyncData {
        try load()
        var data = try store.read().eligible
        for i in data.profiles.indices {
            let id = data.profiles[i].localID == "Default" ? "default"
                : (data.profiles[i].syncID ?? UUID().uuidString.lowercased())
            if data.profiles[i].syncID != id {
                try store.identify(kind: "profile", localID: data.profiles[i].localID, syncID: id)
                data.profiles[i].syncID = id
            }
        }
        for i in data.bookmarks.indices where data.bookmarks[i].syncID == nil {
            let id = data.bookmarks[i].localID.lowercased()
            try store.identify(kind: "bookmark", localID: data.bookmarks[i].localID, syncID: id)
            data.bookmarks[i].syncID = id
        }
        return data
    }

    private func spaceID(_ localID: String) -> String {
        saved.spaces.first(where: { $0.value == localID })?.key ?? localID
    }

    private func snapshotMap() throws -> [String: MistSyncRecord] {
        let data = try dataWithIdentities()
        let profiles = Dictionary(uniqueKeysWithValues: data.profiles.map { ($0.localID, $0.syncID!) })
        let bookmarks = Dictionary(uniqueKeysWithValues: data.bookmarks.map { ($0.localID, $0.syncID!) })
        var records = data.profiles.map {
            MistSyncRecord(kind: "profile", id: $0.syncID!, payload: ["name": .string($0.name)])
        }
        records += data.spaces.map {
            MistSyncRecord(kind: "space", id: spaceID($0.localID), payload: [
                "name": .string($0.name), "color": .string($0.color), "icon": .string($0.icon),
                "order": .number(Double($0.order)), "profile": .string(profiles[$0.profile]!)])
        }
        records += data.bookmarks.compactMap { row in
            // A missing parent is never silently promoted to the Space root.
            if let parent = row.parent, bookmarks[parent] == nil { return nil }
            return MistSyncRecord(kind: "bookmark", id: row.syncID!, payload: [
                "space": .string(spaceID(row.space)), "parent": row.parent.flatMap { bookmarks[$0] }.map(MistSyncValue.string) ?? .null,
                "index": .number(Double(row.index)), "folder": .bool(row.folder),
                "title": .string(row.title), "url": .string(row.url),
                "secondaryUrl": row.secondaryURL.map(MistSyncValue.string) ?? .null,
                "secondaryTitle": row.secondaryTitle.map(MistSyncValue.string) ?? .null,
                "layout": row.layout.map(MistSyncValue.string) ?? .null])
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.versionKey, $0) })
    }

    private func unsynced(_ kind: String, _ id: String) -> Bool {
        versions["\(kind)/\(id)"] == nil
    }

    func apply(_ record: MistSyncRecord) async throws {
        // Local dependency notifications can retry held records while the
        // engine receives new ones. Share one serial state-layer apply queue.
        let previous = applyTask
        applyCount += 1
        defer { applyCount -= 1; if applyCount == 0 { applyTask = nil } }
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await self.performApply(record)
        }
        applyTask = task
        try await task.value
    }

    private func performApply(_ record: MistSyncRecord) async throws {
        guard kinds.contains(record.kind), !record.id.isEmpty else { throw MistSyncError.invalidRecord }
        // Flush genuine local edits before suppressing notifications from this apply.
        if baseline != nil { try flushLocalChanges() }
        try load()
        applying = true
        remoteKeys = []
        changeTask?.cancel()
        // Even a partial state-layer commit must not echo when its cursor is
        // retried. The durable pending list still replays the failed operation.
        defer { baseline = try? snapshotMap(); applying = false }
        let before = try snapshotMap()
        let oldData = try dataWithIdentities()
        let oldSpaceIDs = Dictionary(uniqueKeysWithValues: oldData.spaces.map { ($0.localID, spaceID($0.localID)) })
        try validate(record)
        if record.deleted && record.kind == "profile" && record.id == "default" { return }
        if record.deleted && record.kind == "space" {
            let spaces = try dataWithIdentities().spaces
            if spaces.count <= 1 && spaces.contains(where: { spaceID($0.localID) == record.id }) {
                NSLog("[MistSync] Skipping deletion of the last normal Space")
                return
            }
        }
        saved.records[record.versionKey] = record
        if record.deleted {
            saved.deleted.insert(record.versionKey)
            saved.pending.removeValue(forKey: record.versionKey)
            if try await !remove(record) { saved.pending[record.versionKey] = record }
        } else {
            saved.deleted.remove(record.versionKey)
            saved.pending[record.versionKey] = record
        }
        // Save the pending record before a cursor can advance, including on a
        // failed state-layer write. Retrying the same record is idempotent.
        try persist()
        try await drainPending()
        try await normalize()
        let current = try snapshotMap()
        let newData = try dataWithIdentities()
        // Preserve unrelated user content edits made while Chromium was awaited.
        // Identity adoption and rank normalization are remote side effects.
        let oldProfileIDs = Dictionary(uniqueKeysWithValues: oldData.profiles.map { ($0.localID, $0.syncID!) })
        let oldBookmarkIDs = Dictionary(uniqueKeysWithValues: oldData.bookmarks.map { ($0.localID, $0.syncID!) })
        let adopted = Set(newData.profiles.filter { oldProfileIDs[$0.localID] != $0.syncID }.compactMap { oldProfileIDs[$0.localID].map { "profile/\($0)" } })
            .union(newData.bookmarks.filter { oldBookmarkIDs[$0.localID] != $0.syncID }.compactMap { oldBookmarkIDs[$0.localID].map { "bookmark/\($0)" } })
            .union(newData.spaces.filter { oldSpaceIDs[$0.localID] != spaceID($0.localID) }.compactMap { oldSpaceIDs[$0.localID].map { "space/\($0)" } })
        let edits = Self.diff(before: before, after: current).filter { record in
            guard !remoteKeys.contains(record.versionKey), !adopted.contains(record.versionKey) else { return false }
            // Retagged descendants follow their remotely moved folder.
            if record.kind == "bookmark", let row = newData.bookmarks.first(where: { $0.syncID == record.id }),
               let old = oldData.bookmarks.first(where: { $0.localID == row.localID }), row.space != old.space { return false }
            guard var previous = before[record.versionKey], !record.deleted else { return true }
            var after = record
            for key in ["index", "order", "parent", "profile", "space"] {
                // Parent/profile aliases can change during initial dedupe.
                if key == "index" || key == "order" || !adopted.isEmpty {
                    previous.payload.removeValue(forKey: key)
                    after.payload.removeValue(forKey: key)
                }
            }
            return previous != after
        }
        if !edits.isEmpty {
            try onChange?(edits)
            for record in edits { saved.records[record.versionKey] = record }
        }
        try persist()
    }

    private func validate(_ record: MistSyncRecord) throws {
        if record.deleted { return }
        func string(_ key: String) throws {
            guard record.payload[key]?.string != nil else { throw MistSyncError.invalidRecord }
        }
        switch record.kind {
        case "profile": try string("name")
        case "space":
            for key in ["name", "color", "icon", "profile"] { try string(key) }
            _ = try number(record, "order")
        case "bookmark":
            for key in ["space", "title", "url"] { try string(key) }
            _ = try number(record, "index")
            guard case .bool? = record.payload["folder"],
                  record.payload["parent"] == .null || record.payload["parent"]?.string != nil else {
                throw MistSyncError.invalidRecord
            }
        default: throw MistSyncError.unknownKind
        }
    }

    private func number(_ record: MistSyncRecord, _ key: String) throws -> Int {
        guard case .number(let n)? = record.payload[key], n.isFinite,
              n >= 0, n < Double(Int.max), n.rounded() == n else { throw MistSyncError.invalidRecord }
        return Int(n)
    }

    private func dependencies(_ record: MistSyncRecord) -> [String] {
        if record.kind == "space", let profile = record.payload["profile"]?.string { return ["profile/\(profile)"] }
        if record.kind == "bookmark", let space = record.payload["space"]?.string {
            return ["space/\(space)"] + (record.payload["parent"]?.string.map { ["bookmark/\($0)"] } ?? [])
        }
        return []
    }

    private func drainPending() async throws {
        var progress = true
        while progress {
            progress = false
            for record in saved.pending.values.sorted(by: { $0.versionKey < $1.versionKey }) {
                if record.deleted {
                    if try await remove(record) {
                        saved.pending.removeValue(forKey: record.versionKey)
                        progress = true
                    }
                } else if dependencies(record).contains(where: { saved.deleted.contains($0) }) {
                    saved.pending.removeValue(forKey: record.versionKey)
                    saved.deleted.insert(record.versionKey)
                    progress = true
                } else if try await put(record) {
                    saved.pending.removeValue(forKey: record.versionKey)
                    progress = true
                }
            }
        }
    }

    private func put(_ record: MistSyncRecord) async throws -> Bool {
        let data = try dataWithIdentities()
        let raw = try store.read()
        // An excluded local row is held, never recreated as a duplicate.
        if record.kind == "profile", raw.profiles.contains(where: { $0.syncID == record.id }),
           !data.profiles.contains(where: { $0.syncID == record.id }) { return false }
        if record.kind == "space", raw.spaces.contains(where: { spaceID($0.localID) == record.id }),
           !data.spaces.contains(where: { spaceID($0.localID) == record.id }) { return false }
        if record.kind == "bookmark", raw.bookmarks.contains(where: { $0.syncID == record.id }),
           !data.bookmarks.contains(where: { $0.syncID == record.id }) { return false }
        let p = record.payload
        switch record.kind {
        case "profile":
            let name = p["name"]!.string!
            let existing = data.profiles.first { $0.syncID == record.id }
                ?? data.profiles.sorted { $0.localID < $1.localID }.first {
                    $0.localID != "Default" && $0.name == name && unsynced("profile", $0.syncID!)
                }
            _ = try await store.writeProfile(MistBrowserSyncProfile(
                localID: existing?.localID ?? (record.id == "default" ? "Default" : ""), syncID: record.id, name: name))
        case "space":
            guard let profile = data.profiles.first(where: { $0.syncID == p["profile"]?.string }) else { return false }
            let existing = data.spaces.first { spaceID($0.localID) == record.id }
                ?? data.spaces.sorted { $0.localID < $1.localID }.first {
                    !incomingSpaceIDs.contains($0.localID) && $0.profile == profile.localID
                    && $0.name == p["name"]!.string! && unsynced("space", spaceID($0.localID))
                }
            let localID = existing?.localID ?? record.id
            saved.spaces[record.id] = localID
            try await store.writeSpace(MistBrowserSyncSpace(localID: localID, profile: profile.localID,
                name: p["name"]!.string!, color: p["color"]!.string!, icon: p["icon"]!.string!, order: try number(record, "order")))
        case "bookmark":
            guard let space = data.spaces.first(where: { spaceID($0.localID) == p["space"]?.string }) else { return false }
            let parentID = p["parent"]?.string
            let parent = data.bookmarks.first { $0.syncID == parentID && $0.folder && $0.space == space.localID }
            if parentID != nil && parent == nil { return false }
            let folder = p["folder"] == .bool(true)
            let existing = data.bookmarks.first { $0.syncID == record.id }
                ?? data.bookmarks.sorted { $0.localID < $1.localID }.first {
                    $0.space == space.localID && $0.parent == parent?.localID && $0.folder == folder
                    && $0.title == p["title"]!.string! && $0.url == p["url"]!.string! && unsynced("bookmark", $0.syncID!)
                }
            let localID = existing?.localID ?? UUID().uuidString
            // A concurrent move must not turn the local tree into a cycle.
            var ancestor = parent
            var visited: Set<String> = [localID]
            while let row = ancestor {
                guard visited.insert(row.localID).inserted else { return false }
                ancestor = data.bookmarks.first { $0.localID == row.parent }
            }
            try await store.writeBookmark(MistBrowserSyncBookmark(localID: localID, syncID: record.id,
                space: space.localID, parent: parent?.localID, index: try number(record, "index"), folder: folder,
                title: p["title"]!.string!, url: p["url"]!.string!, secondaryURL: p["secondaryUrl"]?.string,
                secondaryTitle: p["secondaryTitle"]?.string, layout: p["layout"]?.string))
        default: throw MistSyncError.unknownKind
        }
        remoteKeys.insert(record.versionKey)
        return true
    }

    private func remove(_ record: MistSyncRecord) async throws -> Bool {
        let data = try dataWithIdentities()
        let id: String?
        switch record.kind {
        case "profile":
            if record.id == "default" { return true }
            id = data.profiles.first { $0.syncID == record.id }?.localID
            // ProfileManager requires every bound Space to leave first. Hold
            // the tombstone without blocking later Space records in seq order.
            if let id, data.spaces.contains(where: { $0.profile == id }) { return false }
        case "space":
            id = data.spaces.first { spaceID($0.localID) == record.id }?.localID
            if id != nil && data.spaces.count <= 1 {
                NSLog("[MistSync] Skipping deletion of the last normal Space")
                return true
            }
        case "bookmark": id = data.bookmarks.first { $0.syncID == record.id }?.localID
        default: throw MistSyncError.unknownKind
        }
        if let id {
            // Cascade tombstones need not have arrived yet. Remember descendants
            // so late dependent records cannot resurrect a deleted subtree.
            let descendants = data.bookmarks.filter { row in
                if record.kind == "space" { return row.space == id }
                if record.kind == "profile" { return data.spaces.contains { $0.profile == id && $0.localID == row.space } }
                var parent = row.parent
                var visited: Set<String> = []
                while let value = parent, visited.insert(value).inserted {
                    if value == id { return true }
                    parent = data.bookmarks.first { $0.localID == value }?.parent
                }
                return false
            }
            for row in descendants {
                saved.deleted.insert("bookmark/\(row.syncID!)")
                remoteKeys.insert("bookmark/\(row.syncID!)")
            }
            try await store.delete(kind: record.kind, localID: id)
        }
        remoteKeys.insert(record.versionKey)
        return true
    }

    private func normalize() async throws {
        let data = try dataWithIdentities()
        let spaces = try data.spaces.map { row -> (String, Int, String) in
            let id = spaceID(row.localID)
            let record = saved.records["space/\(id)"]
            let order = try record.flatMap { $0.deleted ? nil : $0 }.map { try number($0, "order") } ?? row.order
            return (row.localID, order, id)
        }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        try await store.reorderSpaces(spaces.map { $0.0 })
        let groups = Dictionary(grouping: data.bookmarks) { "\($0.space)/\($0.parent ?? "")" }
        for siblings in groups.values {
            let sorted = try siblings.map { row -> (String, Int, String) in
                let id = row.syncID!
                let record = saved.records["bookmark/\(id)"]
                let index = try record.flatMap { $0.deleted ? nil : $0 }.map { try number($0, "index") } ?? row.index
                return (row.localID, index, id)
            }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            try await store.reorderBookmarks(sorted.map { $0.0 })
        }
    }

    func deduplicate(versions: [String: String]) throws {
        // Matching is performed as dependencies arrive, before profile creation
        // (Chromium refuses duplicate display names). The catch-up boundary marks
        // all remaining rows as synced so later equal user-created rows stay distinct.
        self.versions = versions
        let current = try snapshotMap()
        for record in current.values where saved.records[record.versionKey] == nil {
            saved.records[record.versionKey] = record
        }
        baseline = current
        try persist()
    }
}
