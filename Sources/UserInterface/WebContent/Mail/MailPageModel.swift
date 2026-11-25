import AppKit
import Combine
import MistMailCore

@MainActor
final class MailPageModel: ObservableObject {
    let source: any MailPageDataSource
    var takePendingRevealMessageID: (() -> UUID?)?
    private(set) var didStart = false
    @Published private(set) var state = MailPageSnapshot(accounts: [], mailboxes: [], statuses: [:], unread: .init())
    @Published private(set) var messages: [MailMessageSummary] = []
    @Published private(set) var selection: UUID?
    @Published private(set) var mailboxKey: String
    @Published private(set) var syncing: Set<UUID> = []
    @Published private(set) var loading = false
    @Published private(set) var banner: String?
    @Published private(set) var compose: MailComposeModel?
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchingServer = false
    private let defaults: UserDefaults
    private var eventTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = UUID()
    private var reloadRevision = 0
    private var undoSelection: (generation: UUID, ids: [UUID])?
    private var exhausted = false
    private var operations: [UUID: String] = [:]
    private var pendingFailures: Set<UUID> = []
    private enum HistoryAction {
        case message(MailPageAction, mailboxID: UUID)
        case markAllRead([UUID])
    }
    private struct HistoryEntry {
        var action: HistoryAction
        var operationIDs: [UUID]
        var messageIDs: [UUID]
    }
    private struct RedoEntry {
        var entry: HistoryEntry
        var inverseOperationIDs: [UUID]
    }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [RedoEntry] = []
    private var actionTask: Task<Void, Never>?
    private var actionTaskID = UUID()
    private var composeTransition: Task<Void, Never>?
    private var composeTransitionID = UUID()

    init(source: any MailPageDataSource, defaults: UserDefaults = .standard) {
        self.source = source; self.defaults = defaults
        mailboxKey = defaults.string(forKey: "mist.mail.selectedMailbox") ?? "unified"
    }
    deinit { eventTask?.cancel(); bannerTask?.cancel(); searchTask?.cancel() }
    var mailbox: Mailbox? { state.mailboxes.first { $0.id.uuidString == mailboxKey } }
    var unifiedRole: MailboxRole? { MailPresentation.unifiedRole(for: mailboxKey) }
    var scope: MailMessageScope { mailbox.map { .mailbox($0.id) } ?? .unifiedRole(unifiedRole ?? .inbox) }
    var mailboxIDs: [UUID] { mailbox.map { [$0.id] } ?? state.mailboxes.filter { $0.role == (unifiedRole ?? .inbox) }.map(\.id) }
    var title: String { mailbox.map(MailPresentation.mailboxTitle) ?? MailPresentation.unifiedTitle(unifiedRole ?? .inbox) }
    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canMarkAllRead: Bool { mailboxIDs.contains { (state.unread.mailboxes[$0] ?? 0) > 0 } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedMessage: MailMessageSummary? { messages.first { $0.id == selection } }
    var failedAccounts: [MailAccount] {
        let ids = Set(mailbox.map { [$0.accountID] } ?? state.accounts.map(\.id))
        return state.accounts.filter { ids.contains($0.id) && state.statuses[$0.id] == .authFailed }
    }
    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, source] in
            let events = await source.events()
            await self?.reloadState()
            await self?.reloadMessages()
            await self?.restoreCompose()
            self?.didStart = true
            if let id = self?.takePendingRevealMessageID?() { await self?.reveal(messageID: id) }
            if let box = self?.mailbox, !box.autoSync { await self?.open(box) }
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }
    func reloadState() async {
        do {
            state = try await source.snapshot()
            let validUnified = unifiedRole.map { role in role == .inbox || state.mailboxes.contains { $0.role == role } } ?? false
            if mailbox == nil, !validUnified { selectMailbox("unified") }
        } catch { showError(MailStrings.loadFailed) }
    }
    func selectMailbox(_ key: String) {
        guard key != mailboxKey else { return }
        changeMailbox(key)
        Task { [weak self] in
            guard let self else { return }
            await reloadMessages()
            if let box = mailbox, !box.autoSync { await open(box) }
        }
    }
    private func changeMailbox(_ key: String) {
        mailboxKey = key; defaults.set(key, forKey: "mist.mail.selectedMailbox")
        searchTask?.cancel(); searchQuery = ""; searchingServer = false
        generation = UUID(); selection = nil; messages = []; exhausted = false; loading = false
    }
    func setSearchQuery(_ query: String) {
        guard query != searchQuery else { return }
        searchTask?.cancel(); searchQuery = query; searchingServer = false
        generation = UUID(); exhausted = false; loading = false
        if !isSearching { clearSearch(); return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.reloadMessages()
        }
    }
    func clearSearch() {
        searchTask?.cancel(); searchQuery = ""; searchingServer = false
        generation = UUID(); exhausted = false; loading = false
        Task { [weak self] in await self?.reloadMessages() }
    }
    func searchServer() async {
        guard isSearching, !searchingServer else { return }
        let token = generation, query = searchQuery, ids = mailboxIDs
        searchingServer = true
        defer { if generation == token { searchingServer = false } }
        do {
            for id in ids { try await source.searchServer(query, mailbox: id) }
            if generation == token { await reloadMessages() }
        } catch { if generation == token { showError(MailPresentation.errorMessage(error)) } }
    }
    func markAllRead() async {
        let ids = mailboxIDs
        await queueAction { model in
            do { try await model.applyMarkAllRead(ids, clearingRedo: true) }
            catch { model.showActionError(MailStrings.markAllRead) }
        }.value
    }
    func reveal(messageID: UUID) async {
        do {
            let message = try await source.detail(messageID).summary
            let box = state.mailboxes.first { $0.id == message.mailboxID }
            changeMailbox(box?.role == .inbox ? "unified" : message.mailboxID.uuidString)
            await reloadMessages()
            if !messages.contains(where: { $0.id == messageID }) {
                messages.append(message); messages.sort { $0.date > $1.date }
            }
            selectMessage(messageID)
        } catch { showError(MailPresentation.errorMessage(error)) }
    }
    func selectMessage(_ id: UUID?) {
        guard selection != id else { return }
        let message = messages.first { $0.id == id }
        let isDraft = message.map { value in value.flags.contains(MailFlags.draft) || state.mailboxes.first { $0.id == value.mailboxID }?.role == .drafts } ?? false
        if compose == nil, !isDraft, composeTransition == nil { selection = id; return }
        queueComposeTransition { [self] in
            guard try await endCompose() else { return }
            if isDraft, let message {
                let draft = try await source.editDraft(fromMessage: message.id)
                selection = id; showCompose(draft, fresh: false)
            } else { selection = id }
        }
    }
    @discardableResult
    private func queueComposeTransition(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let previous = composeTransition
        let token = UUID(); composeTransitionID = token
        let task = Task { [self] in
            defer { if composeTransitionID == token { composeTransition = nil } }
            await previous?.value
            do { try await action() } catch { showError(MailPresentation.errorMessage(error)) }
        }
        composeTransition = task
        return task
    }
    func newMessage(prefill: MailComposePrefill = .init()) async {
        await queueComposeTransition { [self] in
            guard try await endCompose() else { return }
            guard let account = prefill.accountID ?? mailbox?.accountID ?? selectedMessage?.accountID ?? state.accounts.first?.id else { throw MailError.notFound }
            let signature = signature(for: account)
            var draft = MailDraft(accountID: account, to: prefill.to, cc: prefill.cc, bcc: prefill.bcc, subject: prefill.subject)
            MailComposeFormatting.applyMessageBody(prefill.body, signature: signature, to: &draft)
            showCompose(try await source.saveDraft(draft), fresh: true, focus: .recipients, automaticSignature: signature)
        }.value
    }
    func reply(to message: MailMessageSummary, all: Bool = false) async {
        await queueComposeTransition { [self] in
            guard try await endCompose() else { return }
            var draft = try await source.replyDraft(to: message.id, all: all)
            MailComposeFormatting.applyMessageBody(signature: signature(for: draft.accountID), to: &draft)
            showCompose(try await source.saveDraft(draft), fresh: true, focus: .body)
        }.value
    }
    func forward(_ message: MailMessageSummary) async {
        await queueComposeTransition { [self] in
            guard try await endCompose() else { return }
            var draft = try await source.forwardDraft(message.id)
            MailComposeFormatting.applyMessageBody(signature: signature(for: draft.accountID), to: &draft)
            showCompose(try await source.saveDraft(draft), fresh: true, focus: .recipients)
        }.value
    }
    private func signature(for accountID: UUID) -> String? {
        MailAccountConfig.normalizedSignature(state.accounts.first { $0.id == accountID }?.config.signatureHTML)
    }
    func closeCompose() async {
        await queueComposeTransition { [self] in _ = try await endCompose() }.value
    }
    private func endCompose() async throws -> Bool {
        guard let compose else { return true }
        guard !compose.isSending else { return false }
        try await compose.close()
        return self.compose == nil
    }
    private func showCompose(_ draft: MailDraft, fresh: Bool, focus: MailComposeModel.InitialFocus? = nil, automaticSignature: String? = nil) {
        let model = MailComposeModel(draft: draft, source: source, discardIfUntouched: fresh,
                                     initialFocus: focus ?? (draft.to.isEmpty ? .recipients : .body), automaticSignature: automaticSignature)
        model.onError = { [weak self] in self?.showError($0) }
        model.onFinish = { [weak self, weak model] in
            guard let self, compose === model else { return }
            if let message = selectedMessage, message.flags.contains(MailFlags.draft) || state.mailboxes.first(where: { $0.id == message.mailboxID })?.role == .drafts { selection = nil }
            compose = nil; defaults.removeObject(forKey: "mist.mail.openDraft")
        }
        compose = model; defaults.set(draft.id.uuidString, forKey: "mist.mail.openDraft")
    }
    private func restoreCompose() async {
        guard compose == nil, let value = defaults.string(forKey: "mist.mail.openDraft") else { return }
        guard let id = UUID(uuidString: value) else { defaults.removeObject(forKey: "mist.mail.openDraft"); return }
        do {
            let draft = try await source.draft(id)
            guard compose == nil, defaults.string(forKey: "mist.mail.openDraft") == value else { return }
            showCompose(draft, fresh: false)
        }
        catch {
            if error as? MailError == .notFound {
                if defaults.string(forKey: "mist.mail.openDraft") == value { defaults.removeObject(forKey: "mist.mail.openDraft") }
            }
            else { showError(MailPresentation.errorMessage(error)) }
        }
    }
    func open(_ box: Mailbox) async {
        syncing.insert(box.id)
        defer { syncing.remove(box.id) }
        do { try await source.open(box.id) } catch { showError(MailStrings.refreshFailed) }
    }
    func refresh() {
        let ids = mailboxIDs
        syncing.formUnion(ids)
        Task { [weak self, source] in
            do { try await source.refresh(ids) } catch { self?.showError(MailStrings.refreshFailed) }
            self?.syncing.subtract(ids)
            await self?.reloadState()
            await self?.reloadMessages()
        }
    }
    func reloadMessages() async {
        let token = generation
        reloadRevision += 1
        let revision = reloadRevision
        do {
            let values: [MailMessageSummary]
            if isSearching { values = try await source.search(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines), in: mailboxIDs) }
            else { values = try await source.messages(in: scope, before: nil, limit: max(200, messages.count)) }
            guard generation == token, revision == reloadRevision else { return }
            messages = values
            if let selection, !values.contains(where: { $0.id == selection }) { self.selection = nil }
            if let restore = undoSelection {
                undoSelection = nil
                if restore.generation == token, let id = restore.ids.first(where: { id in values.contains { $0.id == id } }) {
                    selectMessage(id)
                }
            }
        } catch {
            if generation == token, revision == reloadRevision {
                undoSelection = nil
                showError(MailStrings.loadFailed)
            }
        }
    }
    func loadMore() {
        guard !isSearching, !loading, !exhausted else { return }
        loading = true
        let token = generation, scope = scope, ids = mailboxIDs, cursor = messages.last.map(MailMessageCursor.init)
        Task { [weak self, source] in
            do {
                var page = try await source.messages(in: scope, before: cursor, limit: 200)
                if page.isEmpty {
                    for id in ids { try await source.loadOlder(id) }
                    page = try await source.messages(in: scope, before: cursor, limit: 200)
                }
                guard let self, generation == token else { return }
                let existing = Set(messages.map(\.id))
                messages += page.filter { !existing.contains($0.id) }
                exhausted = page.isEmpty
            } catch { if self?.generation == token { self?.showError(MailStrings.loadFailed) } }
            if self?.generation == token { self?.loading = false }
        }
    }
    @discardableResult
    func perform(_ action: MailPageAction, message: MailMessageSummary? = nil, undoable: Bool = true) -> Task<Void, Never>? {
        guard let message = message ?? selectedMessage else { return nil }
        let restoreSelection = prepareSelection(for: action, message: message)
        let record = undoable && isUndoable(action, message: message)
        return queueAction { model in
            do {
                let operation = try await model.source.perform(action, on: message.id)
                let succeeded = model.trackOperations([operation], title: action.title)
                if succeeded, record {
                    model.pushUndo(.init(action: .message(action, mailboxID: message.mailboxID),
                        operationIDs: [operation], messageIDs: [message.id]), clearingRedo: true)
                }
                await model.reloadMessages()
            } catch {
                restoreSelection?()
                model.showActionError(action.title)
            }
        }
    }
    private func isUndoable(_ action: MailPageAction, message: MailMessageSummary) -> Bool {
        guard case .delete = action else { return true }
        return state.mailboxes.first { $0.id == message.mailboxID }?.role != .trash
            && state.mailboxes.contains { $0.accountID == message.accountID && $0.role == .trash }
    }
    private func prepareSelection(for action: MailPageAction, message: MailMessageSummary) -> (() -> Void)? {
        guard action.removesMessage, selection == message.id else { return nil }
        let next: UUID? = {
            guard let index = messages.firstIndex(where: { $0.id == message.id }), messages.count > 1 else { return nil }
            return messages[index + 1 < messages.count ? index + 1 : index - 1].id
        }()
        let token = generation
        selection = next
        return { [weak self] in
            if let self, generation == token, selection == next { selection = message.id }
        }
    }
    @discardableResult
    private func queueAction(_ action: @escaping @MainActor (MailPageModel) async -> Void) -> Task<Void, Never> {
        let previous = actionTask, token = UUID()
        actionTaskID = token
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if actionTaskID == token { actionTask = nil } }
            await action(self)
        }
        actionTask = task
        return task
    }
    private func trackOperations(_ ids: [UUID], title: String) -> Bool {
        var succeeded = true
        for id in ids {
            if pendingFailures.remove(id) != nil {
                showActionError(title)
                succeeded = false
            } else { operations[id] = title }
        }
        return succeeded
    }
    private func pushUndo(_ entry: HistoryEntry, clearingRedo: Bool) {
        guard !entry.operationIDs.isEmpty else { return }
        undoStack.append(entry)
        if clearingRedo { redoStack.removeAll() }
    }
    private func applyMarkAllRead(_ ids: [UUID], clearingRedo: Bool) async throws {
        let operations = try await source.markAllRead(ids)
        let title = clearingRedo ? MailStrings.markAllRead : MailStrings.redo
        if trackOperations(operations, title: title) {
            pushUndo(.init(action: .markAllRead(ids), operationIDs: operations, messageIDs: []), clearingRedo: clearingRedo)
        }
        await reloadState(); await reloadMessages()
    }
    func undo() async {
        await queueAction { model in await model.undoLastAction() }.value
    }
    private func undoLastAction() async {
        guard var entry = undoStack.popLast() else { return }
        do {
            let result = try await source.undo(entry.operationIDs)
            if trackOperations(result.operationIDs, title: MailStrings.undo) {
                // A Gmail flag operation also affects other labels. Redo targets the
                // message the user picked and lets the engine update those copies.
                if case .message(let action, _) = entry.action, action.removesMessage {
                    entry.messageIDs = result.messageIDs
                }
                redoStack.append(.init(entry: entry, inverseOperationIDs: result.operationIDs))
            }
            if case .message(let action, _) = entry.action, action.removesMessage {
                undoSelection = (generation, result.messageIDs)
            }
            await reloadMessages()
        } catch { showActionError(MailStrings.undo) }
    }
    func redo() async {
        await queueAction { model in await model.redoLastAction() }.value
    }
    private func redoLastAction() async {
        guard let redo = redoStack.popLast() else { return }
        var entry = redo.entry
        do {
            switch entry.action {
            case .markAllRead(let ids):
                try await applyMarkAllRead(ids, clearingRedo: false)
            case .message(let action, let mailboxID):
                if action.removesMessage, redo.inverseOperationIDs.count == 1, let inverse = redo.inverseOperationIDs.first,
                   try await source.cancelPendingUndoMove(inverse) {
                    pushUndo(entry, clearingRedo: false)
                    await reloadMessages()
                    return
                }
                var messages: [MailMessageSummary] = []
                for id in Set(entry.messageIDs) { messages.append(try await source.currentSummary(id)) }
                guard !messages.isEmpty else { throw MailError.notFound }
                if action.removesMessage, !messages.allSatisfy({ isUndoable(action, message: $0) && $0.mailboxID == mailboxID }) {
                    throw MailError.notFound
                }
                entry.operationIDs = []
                entry.messageIDs = messages.map(\.id)
                for message in messages {
                    let restoreSelection = prepareSelection(for: action, message: message)
                    do {
                        let operation: UUID
                        if case .delete = action { operation = try await source.trash(message.id) }
                        else { operation = try await source.perform(action, on: message.id) }
                        entry.operationIDs.append(operation)
                    }
                    catch { restoreSelection?(); throw error }
                }
                if trackOperations(entry.operationIDs, title: MailStrings.redo) { pushUndo(entry, clearingRedo: false) }
                await reloadMessages()
            }
        } catch { showActionError(MailStrings.redo) }
    }
    private func handle(_ event: MailEvent) async {
        switch event {
        case .accountsChanged, .mailboxesChanged, .accountStatusChanged, .unreadCountsChanged:
            await reloadState()
            if case .accountsChanged = event { await reloadMessages() }
        case .messagesChanged(let ids):
            if !ids.isDisjoint(with: mailboxIDs) { exhausted = false; await reloadMessages() }
        case .actionFailed(let id, _):
            undoStack.removeAll { $0.operationIDs.contains(id) }
            redoStack.removeAll { $0.inverseOperationIDs.contains(id) || $0.entry.operationIDs.contains(id) }
            if let action = operations.removeValue(forKey: id) { showActionError(action) }
            else { pendingFailures.insert(id); showError(MailStrings.actionFailed) }
        default: break
        }
    }
    func showError(_ text: String) {
        banner = text; bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.banner = nil
        }
    }
    private func showActionError(_ action: String) { showError(String(format: MailStrings.couldNotAction, action)) }
}
