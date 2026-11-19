import AppKit
import Combine
import MistMailCore
import Network

/// App lifecycle adapter. The native mail page will use this engine directly.
@MainActor
final class MistMailService: ObservableObject {
    static let shared = MistMailService()
    let engine: MailEngine?
    let newMessages = PassthroughSubject<[MailMessageSummary], Never>()
    @Published private(set) var accounts: [MailAccount] = []
    @Published private(set) var statuses: [UUID: MailAccountStatus] = [:]
    @Published private(set) var unreadCounts = MailUnreadCounts()
    @Published private(set) var initializationError: Error?
    private(set) var pendingRevealMessageID: UUID?
    private lazy var notifier = MistMailNotifier { [weak self] in self?.openNotification(messageID: $0) }
    private var eventsTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var networkTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var terminationFlushed = false
    private let composers = NSHashTable<MailComposeModel>.weakObjects()
    private var localDrafts: [MailDraft] = []

    private init() {
        MailDiagnostics.log = { message in AppLogWarn(message) }
        do {
            let base = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true).appendingPathComponent("MistMail", isDirectory: true)
            let bundleID = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
            engine = try MailEngine(baseDirectory: base, credentialStore: KeychainMailCredentialStore(service: KeychainMailCredentialStore.service(bundleID: bundleID)))
        } catch {
            engine = nil; initializationError = error
            AppLogError("[MistMail] Mail database could not be opened: \(error)")
        }
    }
    func start() {
        AgentChatStrings.mailDraftPreview = { [weak self] id in
            guard let self, let draft = self.localDrafts.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
            return AgentMailDraftPreview(from: self.accounts.first { $0.id == draft.accountID }?.config.email ?? "", to: draft.to.map(MailComposeFormatting.display), cc: draft.cc.map(MailComposeFormatting.display), bcc: draft.bcc.map(MailComposeFormatting.display), subject: draft.subject, body: String(draft.plainText.prefix(2000)), attachments: draft.attachments.filter { $0.contentID == nil }.map(\.filename))
        }
        notifier.start()
        guard eventsTask == nil, let engine else { return }
        eventsTask = Task { [weak self] in
            let events = await engine.events()
            await self?.reloadAccounts(engine)
            self?.localDrafts = (try? await engine.drafts()) ?? []
            try? await engine.start()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .accountsChanged: await reloadAccounts(engine)
                case .accountStatusChanged(let id, let value): statuses[id] = value
                case .unreadCountsChanged(let counts): unreadCounts = counts
                case .draftsChanged: terminationFlushed = false; localDrafts = (try? await engine.drafts()) ?? []
                case .newMessages(let messages):
                    newMessages.send(messages)
                    // A system authorization prompt must not hold up mail state updates.
                    Task { [notifier, accounts] in await notifier.post(messages, accounts: accounts) }
                default: break
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await engine.systemDidWake() }
        }
        // One consumer keeps path updates in order; the engine decides which ones are real changes.
        let (paths, pathInput) = AsyncStream<(satisfied: Bool, interfaces: [String])>.makeStream()
        networkTask = Task {
            for await path in paths { await engine.networkPathChanged(satisfied: path.satisfied, interfaces: path.interfaces) }
        }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { path in
            pathInput.yield((path.status == .satisfied, path.availableInterfaces.map(\.name)))
        }
        pathMonitor.start(queue: DispatchQueue(label: "mist.mail.network")); monitor = pathMonitor
    }
    /// Settings ▸ Mail's Reconnect, for an account that isn't connected.
    func reconnect(_ id: UUID) {
        guard let engine else { return }
        Task { await engine.reconnect(accountID: id) }
    }
    func notificationsEnabledDidChange(_ enabled: Bool) {
        if enabled { Task { await notifier.requestAuthorization() } }
    }
    func removeNotification(messageID: UUID) {
        notifier.removeNotification(messageID: messageID)
    }
    func consumePendingRevealMessageID() -> UUID? {
        defer { pendingRevealMessageID = nil }
        return pendingRevealMessageID
    }
    private func openNotification(messageID: UUID?) {
        pendingRevealMessageID = messageID
        NSApp.activate(ignoringOtherApps: true)
        let manager = SpaceSessionControllersManager.shared
        if let controller = manager.activeWindowController, !controller.browserState.isIncognito {
            controller.window?.makeKeyAndOrderFront(nil)
            controller.browserState.openApp(.mail)
        } else {
            AppController.shared?.application(NSApp, open: [MistAppRoute.current.url(.mail)])
        }
        NotificationCenter.default.post(name: .mistMailRevealMessage, object: self)
    }
    private func reloadAccounts(_ engine: MailEngine) async {
        do {
            accounts = try await engine.accounts(); statuses = await engine.accountStatuses(); unreadCounts = try await engine.unreadCounts()
        } catch { AppLogError("[MistMail] Could not read mail state: \(error)") }
    }
    func registerComposer(_ model: MailComposeModel) { composers.add(model); terminationFlushed = false }
    func isComposing(draftID: UUID) -> Bool { composers.allObjects.contains { $0.draft.id == draftID } }
    var needsTerminationFlush: Bool {
        composers.allObjects.contains { $0.hasUnsavedChanges } || (engine != nil && !accounts.isEmpty && !terminationFlushed)
    }
    /// Awaited through AppController's existing asynchronous termination gate.
    /// Drafts are already saved locally, so the server copy is best-effort: Quit waits at most 3 s for it.
    func flushForTermination() async {
        if let engine {
            let gate = TerminationFlushGate()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task { @MainActor in
                    for composer in composers.allObjects {
                        composer.commitFieldEdits?()
                        do { try await composer.saveNow() } catch { AppLogError("[MistMail] Could not save composer: \(error)") }
                    }
                    await engine.flushDrafts(); gate.finish(continuation)
                }
                Task { @MainActor in try? await Task.sleep(for: .seconds(3)); gate.finish(continuation) }
            }
        }
        terminationFlushed = true
    }
    func applicationWillTerminate() {
        monitor?.cancel(); monitor = nil; networkTask?.cancel(); networkTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil; eventsTask?.cancel(); eventsTask = nil
        let engine = engine
        Task { await engine?.flushDrafts(); await engine?.stop() }
    }
}

/// Resumes a termination wait once, whichever of the flush or its deadline ends first.
@MainActor
private final class TerminationFlushGate {
    private var finished = false
    func finish(_ continuation: CheckedContinuation<Void, Never>) {
        guard !finished else { return }
        finished = true
        continuation.resume()
    }
}
