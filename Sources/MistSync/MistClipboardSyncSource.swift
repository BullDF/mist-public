import AppKit
import Combine
import Foundation
import SystemConfiguration
import UniformTypeIdentifiers

enum MistClipboardType: String, Codable { case text, image, file }

struct MistClipboardDraft {
    var type: MistClipboardType
    var data: Data
    var name: String?
    var uti: String?
}

struct MistClipboardItem: Equatable, Identifiable {
    var id: String
    var type: MistClipboardType
    var text: String?
    var name: String?
    var uti: String?
    var size: Int
    var sender: String
    var sent: Date
    var expiry: Date
    /// How long the item lives from its send: its expiry counts down from this.
    var lifetime: TimeInterval
    var receiving: Bool
}

enum MistClipboardError: LocalizedError {
    case nothing, tooLarge, oneFile, expired, sharingOff
    var errorDescription: String? {
        switch self {
        case .nothing: return MistSyncStrings.clipboardNothing
        case .tooLarge: return String(format: MistSyncStrings.clipboardTooLarge, MistClipboardSyncSource.sizeLimit)
        case .oneFile: return MistSyncStrings.clipboardOneFile
        case .expired: return MistSyncStrings.clipboardExpired
        case .sharingOff: return MistSyncStrings.clipboardOffTitle
        }
    }
}

/// One independently written slot per device; only the greatest head can be presented.
@MainActor
final class MistClipboardSyncSource: ObservableObject, MistSyncSource {
    static let sharingKey = "MistClipboardSharing"
    nonisolated static let maxSize = 10_000_000
    nonisolated static let chunkSize = 32_768
    nonisolated static var sizeLimit: String { ByteCountFormatter.string(fromByteCount: Int64(maxSize), countStyle: .file) }
    nonisolated static let defaultLifetime: TimeInterval = {
        let override = UserDefaults.standard.double(forKey: "BrowserAgentIdleLifetime")
        return override > 0 ? min(300, max(1, override)) : 300
    }()

    #if !MIST_SYNC_HOSTLESS_TESTS
    // The closure is first evaluated on the next main-queue turn, after engine registration.
    static let shared = MistClipboardSyncSource(directory:
        URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
            .appendingPathComponent("MistSync/Clipboard", isDirectory: true), slot: {
                let engine = MistSyncEngine.shared
                return engine.credentials == nil ? nil : engine.state.deviceID
            })
    #endif

    let kinds: Set<String> = ["clipboard"]
    var onChange: (([MistSyncRecord]) throws -> Void)?
    var onError: (Error) -> Void = { NSLog("[MistSync] Clipboard: %@", String(describing: $0)) }
    @Published private(set) var current: MistClipboardItem?
    @Published private(set) var sharing: Bool
    private let defaults: UserDefaults
    let directory: URL
    private let slot: () -> String?
    private let deviceName: () -> String
    private let now: () -> Date
    private let timersEnabled: Bool
    private let lifetime: TimeInterval
    private var state = State()
    private var loaded = false
    private var scheduled = false
    private var timer: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    private struct Head: Codable {
        var item: String
        var sentAt: Int64
        var receivedAt: Date
        var lifetime: TimeInterval
        var sender: String
        var cleared: Bool
        var type: MistClipboardType?
        var name: String?
        var uti: String?
        var size: Int
        var chunks: Int
        var expiry: Date { min(Date(timeIntervalSince1970: Double(sentAt) / 1000), receivedAt).addingTimeInterval(lifetime) }
    }

    private struct State: Codable {
        var slot: String?
        var highWater: Int64 = 0
        var visibleAfter: Int64?
        // Retain the winning order even after a tombstone, so an older slot never resurfaces.
        var newestSlot = ""
        var ownChunks = 0
        var heads: [String: Head] = [:]
        // Persist cleanup until the engine has accepted it, including across a restart.
        var pending: [String: MistSyncRecord] = [:]
    }

    init(directory: URL, slot: @escaping () -> String?,
         deviceName: @escaping () -> String = {
             (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
         }, now: @escaping () -> Date = Date.init, timersEnabled: Bool = true,
         lifetime: TimeInterval = MistClipboardSyncSource.defaultLifetime, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sharing = defaults.object(forKey: Self.sharingKey) as? Bool ?? true
        self.directory = directory
        self.slot = slot
        self.deviceName = deviceName
        self.now = now
        self.timersEnabled = timersEnabled
        self.lifetime = min(300, max(1, lifetime))
        if timersEnabled {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshAfterEvent() }
                }
        }
        DispatchQueue.main.async { [weak self] in self?.refreshAfterEvent() }
    }

    deinit {
        timer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func snapshot() throws -> [MistSyncRecord] { try refresh(); return [] }
    func setSharing(_ on: Bool) {
        guard sharing != on else { return }
        do {
            try refresh()
            defaults.set(on, forKey: Self.sharingKey)
            sharing = on
            if on { state.visibleAfter = state.highWater }
            try refresh()
            scheduleChanges()
            try persist()
        } catch { onError(error) }
    }

    private func isVisible(_ head: Head) -> Bool {
        sharing && head.sentAt > (state.visibleAfter ?? Int64.min)
    }
    func deduplicate(versions: [String: String]) {}
    func prepareIncoming(_ records: [MistSyncRecord]) { refreshAfterEvent() }

    func flushPendingChanges() throws {
        try refresh()
        guard !scheduled, !state.pending.isEmpty, let onChange else { return }
        let records = state.pending.values.sorted { $0.id < $1.id }
        try onChange(records)
        state.pending.removeAll()
        try persist()
    }

    /// The deferred callback cannot mutate engine state from inside an incoming apply.
    func waitForPendingChanges() async throws {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try flushPendingChanges()
    }

    func send(_ draft: MistClipboardDraft) throws {
        guard sharing else { throw MistClipboardError.sharingOff }
        try refresh()
        defer { scheduleChanges() }
        guard let own = state.slot else { throw MistSyncError.invalidConfiguration }
        guard !draft.data.isEmpty else { throw MistClipboardError.nothing }
        guard draft.data.count <= Self.maxSize else { throw MistClipboardError.tooLarge }
        guard draft.type != .text || String(data: draft.data, encoding: .utf8) != nil else { throw MistClipboardError.nothing }
        let head = Head(item: UUID().uuidString, sentAt: nextTimestamp(), receivedAt: now(), lifetime: lifetime,
                        sender: deviceName(), cleared: false, type: draft.type,
                        name: Self.safeName(draft.name), uti: draft.uti, size: draft.data.count,
                        chunks: (draft.data.count + Self.chunkSize - 1) / Self.chunkSize)
        try write(draft.data, to: itemURL(head.item))
        let previousCount = state.ownChunks
        state.heads[own] = head
        observe(head, slot: own)
        enqueue(record(head, slot: own))
        for index in 0..<head.chunks {
            let start = index * Self.chunkSize
            let data = draft.data.subdata(in: start..<min(start + Self.chunkSize, draft.data.count))
            enqueue(MistSyncRecord(kind: "clipboard", id: "\(own).\(index)", payload: [
                "item": .string(head.item), "index": .number(Double(index)), "data": .string(MistSyncBase64.encode(data))]))
        }
        if head.chunks < previousCount {
            for index in head.chunks..<previousCount { enqueue(tombstone("\(own).\(index)")) }
        }
        state.ownChunks = head.chunks
        try refresh()
        try flushPendingChanges()
    }

    func clear() throws {
        guard sharing else { throw MistClipboardError.sharingOff }
        try refresh()
        guard let own = state.slot else { throw MistSyncError.invalidConfiguration }
        let head = Head(item: UUID().uuidString, sentAt: nextTimestamp(), receivedAt: now(), lifetime: lifetime,
                        sender: deviceName(), cleared: true, size: 0, chunks: 0)
        state.heads[own] = head
        observe(head, slot: own)
        enqueue(record(head, slot: own))
        for index in 0..<state.ownChunks { enqueue(tombstone("\(own).\(index)")) }
        state.ownChunks = 0
        try refresh()
        try flushPendingChanges()
    }

    func data(for item: MistClipboardItem) throws -> Data {
        try refresh()
        scheduleChanges()
        guard let active = current, active.id == item.id, now() < item.expiry, !active.receiving else {
            throw MistClipboardError.expired
        }
        return try Data(contentsOf: itemURL(item.id))
    }

    func cachedFileURL(for item: MistClipboardItem) throws -> URL {
        let bytes = try data(for: item)
        let folder = directory.appendingPathComponent("Copied/\(item.id)", isDirectory: true)
        try removeChildren(of: directory.appendingPathComponent("Copied"), except: [item.id])
        let url = folder.appendingPathComponent(Self.fileName(for: item))
        if !FileManager.default.fileExists(atPath: url.path) { try write(bytes, to: url) }
        return url
    }

    /// Saves the item into `folder` (Downloads) under its own name, numbered like Chromium's downloads
    /// (`name (1).ext`) when that name is taken.
    func download(_ item: MistClipboardItem, to folder: URL) throws -> URL {
        let bytes = try data(for: item)
        let name = Self.fileName(for: item) as NSString
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index = 0
        while true {
            let candidate = index == 0 ? name as String
                : "\(name.deletingPathExtension) (\(index))" + (name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)")
            let url = folder.appendingPathComponent(candidate)
            do {
                try bytes.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                index += 1
            }
        }
    }

    private static func fileName(for item: MistClipboardItem) -> String {
        let ext = item.uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
        return safeName(item.name) ?? "\(MistSyncStrings.clipboardImage).\(ext)"
    }

    func apply(_ record: MistSyncRecord) async throws {
        try refresh()
        defer { scheduleChanges() }
        guard record.kind == "clipboard", state.slot != nil else { return }
        let parts = record.id.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = parts.first, Self.validSlot(String(first)) else {
            log("invalid record ID"); return
        }
        let remote = String(first)
        guard remote != state.slot else { return }
        if parts.count == 1 {
            if record.deleted {
                state.heads[remote] = nil
            } else {
                guard let head = parseHead(record) else { log("invalid head"); return }
                // Reapplying after an engine disk failure must not extend the receipt deadline.
                var received = head
                if let old = state.heads[remote], old.item == head.item { received.receivedAt = old.receivedAt }
                state.heads[remote] = received
                observe(received, slot: remote)
                try assemble(received)
            }
            try refresh()
        } else {
            guard let index = Int(parts[1]), (0..<Self.maxChunks).contains(index), String(index) == parts[1] else {
                log("invalid chunk index"); return
            }
            if !record.deleted {
                guard sharing else { return }
                guard let item = record.payload["item"]?.string, UUID(uuidString: item) != nil,
                      integer(record.payload["index"]) == index,
                      let encoded = record.payload["data"]?.string, encoded.utf8.count <= 43_691,
                      let bytes = try? MistSyncBase64.decode(encoded), !bytes.isEmpty, bytes.count <= Self.chunkSize else {
                    log("invalid chunk"); return
                }
                if let head = state.heads[remote], head.item == item {
                    guard isVisible(head) else { return }
                    guard validChunk(bytes, index: index, head: head) else { log("chunk length mismatch"); return }
                    guard !head.cleared, now() < head.expiry,
                          head.sentAt == state.highWater, remote == state.newestSlot else { return }
                }
                // Once assembled, retransmitted chunks do not recreate a chunk folder.
                if !FileManager.default.fileExists(atPath: itemURL(item).path) {
                    try write(bytes, to: chunkURL(item, index))
                    if let head = state.heads[remote], head.item == item { try assemble(head) }
                }
            }
            try publish()
            try persist()
            scheduleTimer()
        }
    }

    private static var maxChunks: Int { (maxSize + chunkSize - 1) / chunkSize }
    private func itemURL(_ item: String) -> URL { directory.appendingPathComponent("Items/\(item)") }
    private func chunkURL(_ item: String, _ index: Int) -> URL { directory.appendingPathComponent("Chunks/\(item)/\(index)") }
    private func tombstone(_ id: String) -> MistSyncRecord { MistSyncRecord(kind: "clipboard", id: id, deleted: true) }
    private func enqueue(_ record: MistSyncRecord) { state.pending[record.id] = record }
    private func log(_ message: String) { NSLog("[MistSync] Clipboard: %@", message) }

    private static func validSlot(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func safeName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let result = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return result.isEmpty || result == "." || result == ".." ? nil : result
    }

    private func integer(_ value: MistSyncValue?) -> Int? {
        guard case .number(let number) = value, number.isFinite else { return nil }
        return Int(exactly: number)
    }

    private func parseHead(_ record: MistSyncRecord) -> Head? {
        let p = record.payload
        guard integer(p["v"]) == 1, let item = p["item"]?.string, UUID(uuidString: item) != nil,
              let sentAt = integer(p["sentAt"]), (0...9_007_199_254_740_990).contains(sentAt),
              case .number(let lifetime) = p["lifetime"], lifetime.isFinite, (1...300).contains(lifetime),
              let sender = p["sender"]?.string, case .bool(let cleared) = p["cleared"],
              let size = integer(p["size"]), let chunks = integer(p["chunks"]) else { return nil }
        if cleared {
            guard size == 0, chunks == 0, p["type"] == nil || p["type"] == .null else { return nil }
            return Head(item: item, sentAt: Int64(sentAt), receivedAt: now(), lifetime: lifetime,
                        sender: sender, cleared: true, size: 0, chunks: 0)
        }
        guard let raw = p["type"]?.string, let type = MistClipboardType(rawValue: raw),
              (1...Self.maxSize).contains(size), chunks == (size + Self.chunkSize - 1) / Self.chunkSize,
              p["name"] == .null || p["name"]?.string != nil,
              p["uti"] == .null || p["uti"]?.string != nil else { return nil }
        return Head(item: item, sentAt: Int64(sentAt), receivedAt: now(), lifetime: lifetime, sender: sender,
                    cleared: false, type: type, name: Self.safeName(p["name"]?.string), uti: p["uti"]?.string,
                    size: size, chunks: chunks)
    }

    private func record(_ head: Head, slot: String) -> MistSyncRecord {
        var payload: [String: MistSyncValue] = [
            "v": .number(1), "item": .string(head.item), "sentAt": .number(Double(head.sentAt)),
            "lifetime": .number(head.lifetime), "sender": .string(head.sender), "cleared": .bool(head.cleared),
            "size": .number(Double(head.size)), "chunks": .number(Double(head.chunks))]
        if let type = head.type {
            payload["type"] = .string(type.rawValue)
            payload["name"] = head.name.map(MistSyncValue.string) ?? .null
            payload["uti"] = head.uti.map(MistSyncValue.string) ?? .null
        }
        return MistSyncRecord(kind: "clipboard", id: slot, payload: payload)
    }

    private func nextTimestamp() -> Int64 {
        max(Int64(now().timeIntervalSince1970 * 1000), state.highWater + 1)
    }

    private func observe(_ head: Head, slot: String) {
        if head.sentAt > state.highWater || (head.sentAt == state.highWater && slot > state.newestSlot) {
            state.highWater = head.sentAt
            state.newestSlot = slot
        }
    }

    private var newest: Head? {
        guard let head = state.heads[state.newestSlot], head.sentAt == state.highWater else { return nil }
        return head
    }

    private func refreshAfterEvent() {
        do { try refresh(); scheduleChanges() } catch { onError(error) }
    }

    private func refresh() throws {
        if !loaded {
            let file = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            }
            loaded = true
            try pruneOldCopies()
        }
        let own = slot()
        if own != state.slot {
            state = State(slot: own)
            try removeChildren(of: directory.appendingPathComponent("Chunks"))
            try removeChildren(of: directory.appendingPathComponent("Items"))
        }
        guard let own else {
            if current != nil { current = nil }
            timer?.cancel()
            return
        }
        if let head = state.heads[own], now() >= head.expiry || state.newestSlot != own || head.sentAt != state.highWater {
            enqueue(tombstone(own))
            for index in 0..<state.ownChunks { enqueue(tombstone("\(own).\(index)")) }
            state.ownChunks = 0
            state.heads[own] = nil
        }
        let active = newest.flatMap { isVisible($0) && !$0.cleared && now() < $0.expiry ? $0 : nil }
        try removeChildren(of: directory.appendingPathComponent("Items"), except: Set(active.map { [$0.item] } ?? []))
        let known = Set(state.heads.values.map(\.item))
        for url in try children(directory.appendingPathComponent("Chunks")) {
            if active?.item == url.lastPathComponent { continue }
            if try !sharing || known.contains(url.lastPathComponent) || age(of: url) >= 300 {
                try FileManager.default.removeItem(at: url)
            }
        }
        // Clear and expiry preserve an already copied file; a replacement item invalidates it.
        if let active {
            try removeChildren(of: directory.appendingPathComponent("Copied"), except: [active.item])
        }
        try publish()
        try persist()
        scheduleTimer()
    }

    private func publish() throws {
        var item: MistClipboardItem?
        if let head = newest, isVisible(head), !head.cleared, now() < head.expiry, let type = head.type {
            let url = itemURL(head.item)
            let ready = FileManager.default.fileExists(atPath: url.path)
            let text = type == .text && ready ? String(data: try Data(contentsOf: url), encoding: .utf8) : nil
            item = MistClipboardItem(id: head.item, type: type, text: text, name: head.name, uti: head.uti,
                                     size: head.size, sender: head.sender,
                                     sent: Date(timeIntervalSince1970: Double(head.sentAt) / 1000),
                                     expiry: head.expiry, lifetime: head.lifetime, receiving: !ready)
        }
        if current != item { current = item }
    }

    private func validChunk(_ bytes: Data, index: Int, head: Head) -> Bool {
        index < head.chunks && bytes.count == min(Self.chunkSize, head.size - index * Self.chunkSize)
    }

    private func assemble(_ head: Head) throws {
        guard isVisible(head) else { return }
        guard !head.cleared, now() < head.expiry, !FileManager.default.fileExists(atPath: itemURL(head.item).path) else { return }
        var data = Data()
        for index in 0..<head.chunks {
            let url = chunkURL(head.item, index)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let bytes = try Data(contentsOf: url)
            guard validChunk(bytes, index: index, head: head) else { log("assembled chunk length mismatch"); return }
            data.append(bytes)
        }
        guard data.count == head.size, head.type != .text || String(data: data, encoding: .utf8) != nil else {
            log("invalid assembled content"); return
        }
        try write(data, to: itemURL(head.item))
        let folder = directory.appendingPathComponent("Chunks/\(head.item)")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func persist() throws {
        guard state.slot != nil else { return }
        try write(JSONEncoder().encode(state), to: directory.appendingPathComponent("state.json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.deletingLastPathComponent().path)
    }

    private func children(_ url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])
    }

    private func removeChildren(of url: URL, except keep: Set<String> = []) throws {
        for child in try children(url) where !keep.contains(child.lastPathComponent) { try FileManager.default.removeItem(at: child) }
    }

    private func age(of url: URL) throws -> TimeInterval {
        now().timeIntervalSince(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
    }

    private func pruneOldCopies() throws {
        for url in try children(directory.appendingPathComponent("Copied")) where try age(of: url) >= 86_400 {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func scheduleChanges() {
        guard !state.pending.isEmpty, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            do { try self.flushPendingChanges() } catch { self.onError(error) }
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        guard timersEnabled, state.slot != nil else { return }
        var deadlines = state.heads.values.map(\.expiry).filter { $0 > now() }
        if !state.pending.isEmpty { deadlines.append(now().addingTimeInterval(1)) }
        // Reap orphan chunks even if their head never arrives.
        if let folders = try? children(directory.appendingPathComponent("Chunks")) {
            for folder in folders {
                if let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    deadlines.append(max(now().addingTimeInterval(1), modified.addingTimeInterval(300)))
                }
            }
        }
        guard let date = deadlines.min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshAfterEvent() }
        timer = work
        DispatchQueue.main.asyncAfter(wallDeadline: DispatchWallTime(timespec:
            timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000_000))), execute: work)
    }
}
