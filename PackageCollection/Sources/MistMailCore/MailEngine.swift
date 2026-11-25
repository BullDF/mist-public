import Foundation

/// The UI-facing owner of mail state. All paths, credentials and transports are injected.
/// Observers take their initial snapshot with accounts/mailboxes/unreadCounts, then consume events.
public actor MailEngine {
    let store: MailStore
    let credentials: any MailCredentialStore
    let transportFactory: MailTransportFactory
    var connections: [UUID: any MailTransport] = [:]
    var connecting: [UUID: Task<any MailTransport, Error>] = [:]
    var statuses: [UUID: MailAccountStatus] = [:]
    var observers: [UUID: AsyncStream<MailEvent>.Continuation] = [:]
    var syncTasks: [UUID: Task<Void, Error>] = [:]
    var syncAgain: Set<UUID> = []
    var periodicTasks: [UUID: Task<Void, Never>] = [:]
    var idleTasks: [UUID: Task<Void, Never>] = [:]
    var idleStarting: Set<UUID> = []
    var generations: [UUID: UUID] = [:]
    var coalescedTasks: [UUID: Task<Void, Never>] = [:]
    var retryTasks: [UUID: Task<Void, Never>] = [:]
    var backoff: [UUID: Int] = [:]
    var replayTasks: [UUID: Task<Void, Error>] = [:]
    var inFlightOperations: Set<UUID> = []
    var undoingOperations: Set<UUID> = []
    var replayedOperations: [UUID: ReplayedMailOperation] = [:]
    var movedTo: [UUID: UUID] = [:]
    var movesWithoutCopyUID: [UUID: UnmappedMailMove] = [:]
    var draftTasks: [UUID: Task<Void, Never>] = [:]
    var draftLocks: [UUID: MailOperationGate] = [:]
    var online = true
    /// The interfaces of the last satisfied network path, nil until the first one.
    var networkInterfaces: [String]?
    var started = false
    let now: @Sendable () -> Date

    public init(baseDirectory: URL, credentialStore: any MailCredentialStore,
                transportFactory: @escaping MailTransportFactory, now: @escaping @Sendable () -> Date = { Date() }) throws {
        store = try MailStore(base: baseDirectory); credentials = credentialStore
        self.transportFactory = transportFactory; self.now = now
    }
    deinit {
        for tasks in [periodicTasks, idleTasks, coalescedTasks, retryTasks, draftTasks] { for task in tasks.values { task.cancel() } }
        for task in syncTasks.values { task.cancel() }; for task in connecting.values { task.cancel() }
        for task in replayTasks.values { task.cancel() }
        for continuation in observers.values { continuation.finish() }
        let transports = Array(connections.values)
        Task { for transport in transports { await transport.disconnect() } }
    }
    public func events() -> AsyncStream<MailEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func emit(_ event: MailEvent) { for continuation in observers.values { continuation.yield(event) } }
    func changed(_ mailboxIDs: Set<UUID>) throws {
        emit(.messagesChanged(mailboxIDs)); emit(.unreadCountsChanged(try store.unreadCounts()))
    }
    func setStatus(_ id: UUID, _ status: MailAccountStatus) { statuses[id] = status; emit(.accountStatusChanged(id, status)) }
    public func accounts() throws -> [MailAccount] { try store.accounts() }
    public func storedPassword(accountID: UUID) throws -> String? { try credentials.load(accountID: accountID) }
    public func accountStatuses() -> [UUID: MailAccountStatus] { statuses }
    public func mailboxes(accountID: UUID? = nil) throws -> [Mailbox] { try store.mailboxes(accountID: accountID) }
    public func unreadCounts() throws -> MailUnreadCounts { try store.unreadCounts() }
    public func summary(_ id: UUID) throws -> MailMessageSummary {
        let message = try store.message(id)
        guard !message.hidden else { throw MailError.notFound }
        return message.summary
    }
    public func messages(in scope: MailMessageScope, before cursor: MailMessageCursor? = nil, limit: Int = 100) throws -> [MailMessageSummary] {
        try store.list(scope: scope, before: cursor, limit: limit)
    }
    func account(_ id: UUID) throws -> MailAccount {
        guard let account = try store.accounts().first(where: { $0.id == id }) else { throw MailError.notFound }; return account
    }
    public func testAccount(_ config: MailAccountConfig, password: String) async throws -> Bool {
        try config.validate()
        guard online else { throw MailError.offline }
        let transport = transportFactory(config, password)
        do {
            let capabilities = try await transport.connect()
            _ = try await transport.listMailboxes()
            try await transport.testSMTP()
            await transport.disconnect()
            return capabilities.contains { $0.uppercased() == "X-GM-EXT-1" }
        } catch { await transport.disconnect(); throw error }
    }
    @discardableResult
    public func addAccount(_ config: MailAccountConfig, password: String) async throws -> MailAccount {
        let gmail = try await testAccount(config, password: password)
        let account = MailAccount(config: config, isGmail: gmail)
        try credentials.save(password, accountID: account.id)
        do { try store.save(account) } catch { try? credentials.delete(accountID: account.id); throw error }
        setStatus(account.id, .disconnected); emit(.accountsChanged)
        if started { scheduleAccount(account.id) }
        return account
    }
    public func updateAccount(_ id: UUID, config: MailAccountConfig, password: String? = nil) async throws {
        var value = try account(id); try config.validate()
        let connectionChanged = value.config.imap != config.imap || value.config.smtp != config.smtp || value.config.username != config.username || password != nil
        if connectionChanged {
            guard let secret = try password ?? credentials.load(accountID: id) else { throw MailError.missingCredentials }
            value.isGmail = try await testAccount(config, password: secret)
            try credentials.save(secret, accountID: id)
            await disconnectAccount(id)
        }
        // An edit keeps the account's current position, which a reorder may have changed while the server test awaited.
        value.config = config; value.config.sortOrder = try account(id).config.sortOrder; try store.save(value)
        if connectionChanged { setStatus(id, .disconnected); backoff[id] = nil; if started { scheduleAccount(id) } }
        emit(.accountsChanged)
    }
    /// Puts the listed accounts first, in the given order, and any others after them in their current order.
    /// The new order takes positions above every current one, so every account's synced record changes in
    /// one batch: a concurrent reorder on another Mac then wins or loses as a whole instead of interleaving.
    public func reorderAccounts(_ ids: [UUID]) throws {
        let current = try store.accounts()
        var listed = Set<UUID>()
        let moved = ids.compactMap { id in listed.insert(id).inserted ? current.first { $0.id == id } : nil }
        let ordered = moved + current.filter { !listed.contains($0.id) }
        guard ordered.map(\.id) != current.map(\.id) else { return }
        let top = current.map(\.config.sortOrder).max() ?? -1
        let base = top < Int.max - ordered.count ? top + 1 : 0
        try store.db.transaction {
            for (offset, var account) in ordered.enumerated() { account.config.sortOrder = base + offset; try store.save(account) }
        }
        emit(.accountsChanged)
    }
    /// Applies account setup without testing a server. A missing password preserves local credentials.
    public func applySyncedAccount(_ account: MailAccount, password: String?) async throws {
        try account.config.validate()
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        if let existing = try store.accounts().first(where: { $0.id == account.id }) {
            let passwordChanged = try password.map { try credentials.load(accountID: account.id) != $0 } ?? false
            if passwordChanged, let password { try credentials.save(password, accountID: account.id) }
            let connectionChanged = existing.config.imap != account.config.imap || existing.config.smtp != account.config.smtp
                || existing.config.username != account.config.username || passwordChanged
            if connectionChanged { await disconnectAccount(account.id) }
            try store.save(account)
            if connectionChanged {
                setStatus(account.id, .disconnected); backoff[account.id] = nil
                if started { scheduleAccount(account.id) }
            }
            emit(.accountsChanged)
        } else {
            if let password { try credentials.save(password, accountID: account.id) }
            do { try store.save(account) } catch {
                if password != nil { try? credentials.delete(accountID: account.id) }
                throw error
            }
            setStatus(account.id, .disconnected); emit(.accountsChanged)
            if started { scheduleAccount(account.id) }
        }
    }
    public func removeAccount(_ id: UUID) async throws {
        let drafts = try store.drafts().filter { $0.accountID == id }
        for box in try store.mailboxes(accountID: id) { syncTasks.removeValue(forKey: box.id)?.cancel() }
        try credentials.delete(accountID: id)
        // Delete state before awaiting disconnect so suspended work cannot restore it.
        try store.deleteAccount(id)
        for draft in drafts { draftTasks.removeValue(forKey: draft.id)?.cancel(); try removeDraftFiles(draft.id) }
        let files = store.base.appendingPathComponent("Attachments").appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: files.path) { try FileManager.default.removeItem(at: files) }
        await disconnectAccount(id); statuses[id] = nil
        emit(.accountsChanged); emit(.mailboxesChanged(id)); emit(.draftsChanged)
        emit(.unreadCountsChanged(try store.unreadCounts()))
    }
    public func start() throws {
        guard !started else { return }; started = true
        for account in try store.accounts() { scheduleAccount(account.id) }
    }
    public func stop() async {
        started = false
        for task in draftTasks.values { task.cancel() }; draftTasks = [:]
        for account in (try? store.accounts()) ?? [] { await disconnectAccount(account.id) }
    }
    func scheduleAccount(_ id: UUID) {
        guard periodicTasks[id] == nil else { return }
        periodicTasks[id] = Task { [weak self] in
            await self?.refreshQuietly(id)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                await self?.refreshQuietly(id)
            }
        }
    }
    func refreshQuietly(_ id: UUID) async { do { try await refreshAccounts(accountID: id, autoOnly: true) } catch { /* Status and retry are set by refresh. */ } }
    public func networkBecameAvailable() async { online = true; await reconnectAll() }
    public func systemDidWake() async { await reconnectAll() }
    /// Reconnects only when the network came back or moved to other interfaces. Path updates that keep the
    /// interfaces (Wi-Fi link quality going between good and moderate sends one every few seconds) keep every
    /// connection: reconnecting on each one logged in to every account again and again, which Gmail refused.
    public func networkPathChanged(satisfied: Bool, interfaces: [String]) async {
        guard satisfied else {
            networkInterfaces = nil
            if online { await networkBecameUnavailable() }
            return
        }
        let changed = !online || (networkInterfaces != nil && networkInterfaces != interfaces)
        networkInterfaces = interfaces
        if changed { await networkBecameAvailable() }
    }
    /// Connects the account again now, even after a failed sign-in, and restarts its retry delays.
    public func reconnect(accountID id: UUID) async {
        guard (try? account(id)) != nil else { return }
        await disconnectAccount(id); backoff[id] = nil
        setStatus(id, .disconnected)
        if started { scheduleAccount(id) } else { await refreshQuietly(id) }
    }
    public func networkBecameUnavailable() async {
        online = false
        for id in Set(connections.keys).union(connecting.keys) { await disconnectAccount(id) }
        for (id, status) in statuses where status != .authFailed && status != .disconnected { setStatus(id, .disconnected) }
    }
    func reconnectAll() async {
        for account in (try? store.accounts()) ?? [] where statuses[account.id] != .authFailed {
            await disconnectAccount(account.id); if started { scheduleAccount(account.id) } else { await refreshQuietly(account.id) }
        }
    }
    func disconnectAccount(_ id: UUID) async {
        generations[id] = UUID()
        periodicTasks.removeValue(forKey: id)?.cancel(); idleTasks.removeValue(forKey: id)?.cancel()
        coalescedTasks.removeValue(forKey: id)?.cancel(); retryTasks.removeValue(forKey: id)?.cancel()
        connecting.removeValue(forKey: id)?.cancel()
        for box in (try? store.mailboxes(accountID: id)) ?? [] {
            syncTasks.removeValue(forKey: box.id)?.cancel(); syncAgain.remove(box.id)
        }
        replayTasks[id]?.cancel()
        let transport = connections.removeValue(forKey: id)
        if let transport { await transport.disconnect() }
    }
    func connection(_ id: UUID) async throws -> any MailTransport {
        guard online else { throw MailError.offline }
        guard statuses[id] != .authFailed else { throw MailError.authenticationFailed }
        if let value = connections[id] { return value }
        if let task = connecting[id] { return try await task.value }
        let value = try account(id)
        guard let password = try credentials.load(accountID: id) else { throw MailError.missingCredentials }
        setStatus(id, .connecting)
        let generation = generations[id]
        let transport = transportFactory(value.config, password)
        let task = Task<any MailTransport, Error> { _ = try await transport.connect(); try Task.checkCancellation(); return transport }
        connecting[id] = task
        do {
            let result = try await task.value; try Task.checkCancellation(); _ = try account(id)
            guard generations[id] == generation else { throw CancellationError() }
            connections[id] = result; connecting[id] = nil; return result
        } catch { if generations[id] == generation { connecting[id] = nil }; await transport.disconnect(); throw error }
    }
    func failed(_ id: UUID, _ error: Error) async {
        guard (try? account(id)) != nil, !(error is CancellationError) else { return }
        let failure = error as? MailError ?? .cannotConnect
        if retryTasks[id] != nil && failure != .authenticationFailed && failure != .missingCredentials { return }
        idleTasks.removeValue(forKey: id)?.cancel()
        if let transport = connections.removeValue(forKey: id) { await transport.disconnect() }
        if failure == .authenticationFailed || failure == .missingCredentials {
            retryTasks.removeValue(forKey: id)?.cancel(); setStatus(id, .authFailed); return
        }
        guard online else { setStatus(id, .disconnected); return }
        let seconds = min(backoff[id] ?? 1, 300); backoff[id] = min(seconds * 2, 300)
        setStatus(id, .retrying(seconds: seconds))
        guard retryTasks[id] == nil else { return }
        retryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) } catch { return }
            await self?.retry(id)
        }
    }
    /// Ignores the failure of a connection that a reconnect has replaced since, so it can't tear down its replacement.
    func failed(_ id: UUID, _ error: Error, generation: UUID?) async {
        guard generations[id] == generation else { return }
        await failed(id, error)
    }
    func retry(_ id: UUID) async { retryTasks[id] = nil; await refreshQuietly(id) }
    func removeDraftFiles(_ id: UUID) throws {
        let path = store.base.appendingPathComponent("DraftAttachments").appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
