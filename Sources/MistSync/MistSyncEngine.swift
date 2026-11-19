import Combine
import Foundation

@MainActor
final class MistSyncEngine: ObservableObject {
    #if !MIST_SYNC_HOSTLESS_TESTS
    static let shared: MistSyncEngine = {
        let engine = MistSyncEngine(
            keyStorage: MistSyncKeychain(),
            stateDirectory: URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
                .appendingPathComponent("MistSync", isDirectory: true))
        engine.register(MistPasswordSyncSource(store: MistPasswordVault.shared))
        engine.register(MistBrowserDataSyncSource(store: MistLocalBrowserDataSyncStorage(), directory:
            URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
                .appendingPathComponent("MistSync", isDirectory: true)))
        engine.register(MistMailAccountSyncSource(store: MistEngineMailAccountSyncStorage(engine: MistMailService.shared.engine), directory:
            URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
                .appendingPathComponent("MistSync", isDirectory: true)))
        engine.register(MistClipboardSyncSource.shared)
        return engine
    }()
    #endif

    enum Status { case off, connecting, connected, offline }
    @Published private(set) var status: Status = .off
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: Error?
    @Published private(set) var credentials: MistSyncCredentials?
    private(set) var state = MistSyncState()
    private let keyStorage: MistSyncKeyStorage
    private let store: MistSyncStateStore
    private let client: MistSyncClient
    private let connectAutomatically: Bool
    private var crypto: MistSyncCrypto?
    private var sources: [MistSyncSource] = []
    private var kinds: [String: MistSyncSource] = [:]
    private var connectionReady = false
    private var connectionID = UUID()
    private var catchingUp = true
    private var catchUpRecords: [MistSyncWireRecord] = []
    private var flight: (ref: Int, items: [String: MistSyncWireRecord])?
    private var nextRef = 0
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Error>?
    private var receivingCount = 0

    init(keyStorage: MistSyncKeyStorage, stateDirectory: URL, session: URLSession = .shared,
         connectAutomatically: Bool = true, monitorNetwork: Bool = true) {
        self.keyStorage = keyStorage
        store = MistSyncStateStore(directory: stateDirectory)
        client = MistSyncClient(session: session, monitorNetwork: monitorNetwork)
        self.connectAutomatically = connectAutomatically
        client.onOpen = { [weak self] in
            guard let self else { return }
            let attempt = self.connectionID
            try self.persist()
            try await self.client.send(MistSyncFrame(t: "hello", after: self.state.cursor))
            guard attempt == self.connectionID else { return }
            self.connectionReady = true
            self.pushOutbox()
        }
        client.onFrame = { [weak self] text in try await self?.receive(text) }
        client.onConnecting = { [weak self] in
            guard let self else { return }
            self.connectionID = UUID()
            self.connectionReady = false
            self.catchingUp = true
            self.catchUpRecords = []
            self.flight = nil
            self.sendTask?.cancel()
            self.status = .connecting
        }
        client.onDisconnect = { [weak self] error in self?.disconnected(error) }
    }

    func register(_ source: MistSyncSource) {
        for kind in source.kinds { precondition(kinds[kind] == nil); kinds[kind] = source }
        sources.append(source)
        source.onChange = { [weak self] records in try self?.recordLocalChanges(records) }
    }

    func start() {
        guard credentials == nil else { return }
        do {
            guard let saved = try keyStorage.load() else { return }
            let loaded = try store.load()
            crypto = try MistSyncCrypto(groupKey: saved.groupKey)
            state = loaded
            credentials = saved
            connect()
        } catch { lastError = error; status = .offline }
    }

    func enable(_ value: MistSyncCredentials) throws {
        guard credentials == nil else { throw MistSyncError.invalidConfiguration }
        let keys = try MistSyncCrypto(groupKey: value.groupKey)
        let initial = MistSyncState()
        try store.save(initial)
        try keyStorage.save(value)
        state = initial
        crypto = keys
        credentials = value
        lastSynced = nil
        lastError = nil
        connect()
    }

    func turnOff() throws {
        try keyStorage.delete()
        disconnect()
        credentials = nil
        crypto = nil
        status = .off
        state = MistSyncState()
        lastSynced = nil
        lastError = nil
        try store.delete()
    }

    /// Also used by local integration tests to simulate an offline Mac without discarding its group.
    func disconnect() {
        connectionID = UUID()
        client.stop()
        sendTask?.cancel(); sendTask = nil
        connectionReady = false
        catchUpRecords = []
        flight = nil
        if credentials != nil { status = .offline }
    }

    func connect() {
        guard let credentials, let crypto, connectAutomatically else { return }
        lastError = nil
        status = .connecting
        client.start(credentials: credentials, token: crypto.token)
    }

    func recordLocalChanges(_ records: [MistSyncRecord]) throws {
        guard let crypto, credentials != nil else { return }
        var next = state
        for var record in records {
            guard kinds[record.kind] != nil else { throw MistSyncError.unknownKind }
            record.hlc = try next.clock.tick(deviceID: next.deviceID)
            next.versions[record.versionKey] = record.hlc
            next.outbox[record.versionKey] = try crypto.seal(record)
        }
        state = next
        do { try persist() } catch { lastError = error; client.failConnection(); throw error }
        pushOutbox()
    }

    func receive(_ text: String) async throws {
        let previous = receiveTask
        let attempt = connectionID
        receivingCount += 1
        defer { receivingCount -= 1; pushOutbox() }
        let task = Task { @MainActor in
            try await previous?.value
            guard attempt == self.connectionID else { throw CancellationError() }
            try await self.receiveFrame(text, attempt: attempt)
        }
        receiveTask = task
        do {
            try await task.value
            if receivingCount == 1 { receiveTask = nil }
        } catch {
            if receivingCount == 1 { receiveTask = nil }
            throw error
        }
    }

    private func receiveFrame(_ text: String, attempt: UUID) async throws {
        let frame = try JSONDecoder().decode(MistSyncFrame.self, from: Data(text.utf8))
        switch frame.t {
        case "records":
            guard let items = frame.items, items.count <= 500 else { throw MistSyncError.invalidFrame }
            // A live broadcast can reach a newly accepted socket before its hello is handled.
            // Sort the entire catch-up at the marker so that it cannot skip older records.
            if catchingUp {
                guard let crypto else { throw MistSyncError.invalidFrame }
                var next = state
                for item in items {
                    let record = try crypto.open(item)
                    try next.clock.tick(deviceID: next.deviceID, receiving: record.hlc)
                }
                state.clock = next.clock
                try store.save(next)
                state = next
                catchUpRecords.append(contentsOf: items)
                return
            }
            for item in items { try await apply(item, attempt: attempt) }
            lastSynced = Date()
        case "synced":
            guard let crypto else { throw MistSyncError.invalidFrame }
            let incoming = try catchUpRecords.map { try crypto.open($0) }
            for source in sources { source.prepareIncoming(incoming) }
            for item in catchUpRecords.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
                try await apply(item, attempt: attempt)
            }
            catchUpRecords = []
            catchingUp = false
            guard let seq = frame.seq, seq >= state.cursor, seq <= 9_007_199_254_740_991 else {
                throw MistSyncError.invalidFrame
            }
            // The marker contains no unapplied records: hello's pages preceded it on this socket.
            state.cursor = seq
            try persist()
            // A source added by an app update may have existing records in an already-paired group.
            // Discover them through snapshots, without teaching the engine about any data kind.
            var needsUpload = state.needsInitialUpload
            if !needsUpload {
                for source in sources {
                    if try source.snapshot().contains(where: { state.versions[$0.versionKey] == nil }) {
                        needsUpload = true
                        break
                    }
                }
            }
            if needsUpload {
                for source in sources { try source.deduplicate(versions: state.versions) }
                for source in sources {
                    let initial = try source.snapshot().filter { state.versions[$0.versionKey] == nil }
                    try recordLocalChanges(initial)
                }
                state.needsInitialUpload = false
                try persist()
            }
            status = .connected
            lastError = nil
            lastSynced = Date()
            client.caughtUp()
            pushOutbox()
        case "ack":
            guard let ref = frame.ref else { throw MistSyncError.invalidFrame }
            guard let flight, flight.ref == ref else { return }
            for (key, sent) in flight.items where state.outbox[key]?.hlc == sent.hlc {
                state.outbox.removeValue(forKey: key)
            }
            self.flight = nil
            try persist()
            lastSynced = Date()
            pushOutbox()
        case "error": throw MistSyncError.server(frame.message ?? "")
        default: throw MistSyncError.invalidFrame
        }
    }

    private func apply(_ item: MistSyncWireRecord, attempt: UUID) async throws {
        guard let seq = item.seq, seq > 0, seq <= 9_007_199_254_740_991, let crypto else {
            throw MistSyncError.invalidFrame
        }
        if seq <= state.cursor { return }
        let record = try crypto.open(item)
        guard let source = kinds[record.kind] else { throw MistSyncError.unknownKind }
        var next = state
        try next.clock.tick(deviceID: next.deviceID, receiving: record.hlc)
        // Even an apply failure has seen this clock. Future local edits must exceed it.
        state.clock = next.clock
        // Debounced local edits must get a clock before the conflict check,
        // rather than being discovered inside an already-winning remote apply.
        try source.flushPendingChanges()
        next = state
        if record.hlc > (state.versions[record.versionKey] ?? "") {
            source.prepare(versions: state.versions)
            do { try await source.apply(record) }
            catch { try persist(); throw error }
            guard attempt == connectionID else { throw CancellationError() }
            // Local edits may have arrived while the state layer awaited Chromium.
            // Preserve their clocks and outbox entries across that suspension.
            next = state
            if record.hlc > (next.versions[record.versionKey] ?? "") {
                next.versions[record.versionKey] = record.hlc
                next.outbox.removeValue(forKey: record.versionKey)
            }
        }
        next.cursor = seq
        // Apply first, then atomically commit the version and cursor. A failed write retries idempotently.
        try store.save(next)
        state = next
    }

    private func persist() throws { try store.save(state) }

    private func disconnected(_ error: Error) {
        connectionReady = false
        flight = nil
        sendTask?.cancel(); sendTask = nil
        lastError = error
        status = .offline
    }

    private func pushOutbox() {
        guard connectionReady, receivingCount == 0, flight == nil, !state.outbox.isEmpty else { return }
        nextRef += 1
        let items = Dictionary(uniqueKeysWithValues: state.outbox.sorted { $0.key < $1.key }.prefix(500).map { ($0.key, $0.value) })
        let ref = nextRef
        flight = (ref, items)
        sendTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard self.receivingCount == 0 else { self.flight = nil; return }
            do { try await client.send(MistSyncFrame(t: "push", ref: ref, items: Array(items.values))) }
            catch { if !Task.isCancelled { client.failConnection() } }
        }
    }
}
