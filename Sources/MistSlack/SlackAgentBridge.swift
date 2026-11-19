import Combine
import Foundation

@MainActor final class SlackAgentBridge {
    enum StartError: Error { case noWindow, invalidSlackResponse }
    private let store: AgentChatStore
    private let threads: SlackThreadStore
    private let call: (String, [String: String]) async throws -> [String: Any]
    private let startChat: (String, AgentMessageSender, DrifterConfig) throws -> UUID
    private let models: () async -> [DrifterModel]
    private let launchConfig: () -> DrifterConfig
    private let reopenChat: (UUID) async -> Bool
    private let channelName: (String) -> String?
    private let owner: () -> String
    private let botUserID: () -> String
    private let workspaceURL: () -> String?
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void
    private let log: (String) -> Void
    private var inbound: [SlackThreadKey: Task<Void, Never>] = [:]
    private var observations: [UUID: Observation] = [:]
    private var linkedChats = Set<UUID>()
    private var sentTitles: [SlackThreadKey: String] = [:]
    private var updatedCards: [String: Set<String>] = [:]
    private var storeBinding: AnyCancellable?
    private var catchingUp = false

    private final class Observation {
        weak var conversation: AgentConversation?
        var status: AgentConversationStatus?
        var thinking = false
        var stopPending = false
        var bindings = Set<AnyCancellable>()
        var refresh: Task<Void, Never>?
        var title: Task<Void, Never>?
        var output: Task<Void, Never>?
        final class Card {
            let request: AgentChatItem.PermissionRequest
            var ts: String?
            init(request: AgentChatItem.PermissionRequest) { self.request = request }
        }
        var cards: [String: Card] = [:]
        final class HandOffCard {
            let handOff: AgentHandOff
            var ts: String?
            init(handOff: AgentHandOff) { self.handOff = handOff }
        }
        var handOffCard: HandOffCard?
        var posted = Set<String>()
        var updated = Set<String>()
        deinit { refresh?.cancel(); title?.cancel() }
    }

    init(store: AgentChatStore, threads: SlackThreadStore,
         call: @escaping (String, [String: String]) async throws -> [String: Any],
         startChat: @escaping (String, AgentMessageSender, DrifterConfig) throws -> UUID,
         models: @escaping () async -> [DrifterModel],
         launchConfig: @escaping () -> DrifterConfig,
         reopenChat: @escaping (UUID) async -> Bool,
         channelName: @escaping (String) -> String? = { _ in nil },
         owner: @escaping () -> String = { "" },
         botUserID: @escaping () -> String = { "" },
         workspaceURL: @escaping () -> String? = { nil },
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.store = store; self.threads = threads; self.call = call; self.startChat = startChat
        self.models = models; self.launchConfig = launchConfig
        self.reopenChat = reopenChat; self.channelName = channelName; self.now = now; self.sleep = sleep
        self.owner = owner; self.botUserID = botUserID; self.workspaceURL = workspaceURL; self.log = log
        store.isSlackThreadChat = { [weak self] in self?.threads.record(forChat: $0) != nil }
        store.onSlackTaskFinished = { [weak self] in self?.taskFinished($0, $1, items: $2) }
        for kind in [SlackThreadKind.dm, .channel] {
            linkedChats.formUnion(threads.recentThreads(kind: kind, since: .distantPast).compactMap(\.chatId))
        }
        storeBinding = store.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.reconcileObservations() }
        }
        // A thread's chat tab, opened in the background, closes once idle; the thread keeps its chat.
        store.closeTabsWhenIdle(Array(linkedChats))
        reconcileObservations()
    }

    func receive(_ event: SlackInbound) {
        switch event {
        case let .threadStarted(key, context), let .contextChanged(key, context):
            var record = threads.record(for: key) ?? .init(key: key, kind: .dm, updatedAt: now())
            record.context = context; record.updatedAt = now(); threads.upsert(record)
            Task { [weak self] in await self?.suggestPrompts(for: key, context: context) }
        case let .message(message):
            let previous = inbound[message.key]
            inbound[message.key] = Task { [weak self] in
                await previous?.value
                await self?.handle(message)
            }
        case let .action(action):
            Task { [weak self] in await self?.handle(action) }
        case let .stopped(key):
            stop(key)
        }
    }

    /// Slack's stop acts like Mist's Stop; a chat still starting stops once its turn runs. Slack
    /// leaves the session working until the app moves it, so with nothing to stop it's cleared here.
    private func stop(_ key: SlackThreadKey) {
        let id = threads.record(for: key)?.chatId
        let conversation = id.flatMap { store.conversation(for: $0) }
        switch conversation?.status {
        case .running?, .awaitingPermission?:
            log("slack: stop routed to chat")
            conversation?.onStop?()
        case .starting?:
            guard let id else { return }
            observe(id)
            observations[id]?.stopPending = true
            log("slack: stop pending until the turn runs")
        default:
            log("slack: stop with no running turn")
            if let id, let observation = observations[id] {
                observation.thinking = false
                observation.refresh?.cancel(); observation.refresh = nil
                enqueue(observation) { [weak self] in await self?.status(working: false, for: key) }
            } else {
                Task { [weak self] in await self?.status(working: false, for: key) }
            }
        }
    }

    func chatReplaced(_ old: UUID, with new: UUID) {
        if let observation = observations.removeValue(forKey: old), let record = threads.record(forChat: old) {
            observation.refresh?.cancel(); observation.title?.cancel()
            clearThinking(observation, for: record.key)
            closeCards(observation, for: record.key, chat: old)
        }
        threads.replaceChat(old, with: new)
        linkedChats.remove(old); linkedChats.insert(new)
        observe(new)
    }

    func catchUp(since previousConnectedAt: Date?) async {
        guard let previousConnectedAt, !catchingUp, !owner().isEmpty, !botUserID().isEmpty else { return }
        catchingUp = true
        defer { catchingUp = false }
        let since = String(format: "%.6f", previousConnectedAt.timeIntervalSince1970 - 120)
        do {
            let dm: String
            if let saved = threads.dmChannel { dm = saved }
            else {
                let opened = try await call("conversations.open", ["users": owner()])
                guard let id = (opened["channel"] as? [String: Any])?["id"] as? String, !id.isEmpty else {
                    throw StartError.invalidSlackResponse
                }
                dm = id; threads.dmChannel = id
            }
            let history = try await messages("conversations.history", ["channel": dm, "oldest": since, "limit": "200"])
            var keys = Set<SlackThreadKey>()
            for message in history {
                guard let ts = message["ts"] as? String else { continue }
                let topLevelOwner = message["user"] as? String == owner() && message["thread_ts"] == nil
                let recentReply = (message["latest_reply"] as? String).map { SlackThreadStore.compare($0, since) == .orderedDescending } ?? false
                if topLevelOwner || recentReply {
                    keys.insert(.init(channel: dm, threadTs: message["thread_ts"] as? String ?? ts))
                }
            }
            for record in threads.recentThreads(kind: .dm, since: now().addingTimeInterval(-7 * 24 * 60 * 60)).prefix(30) {
                keys.insert(record.key)
            }
            for key in keys.sorted(by: {
                let order = SlackThreadStore.compare($0.threadTs, $1.threadTs)
                return order == .orderedSame ? $0.channel < $1.channel : order == .orderedAscending
            }) {
                let replies = try await messages("conversations.replies", ["channel": key.channel, "ts": key.threadTs, "oldest": since, "limit": "200"])
                // Serialize with already queued live events before checking their handled watermark.
                let previous = inbound[key]
                let task = Task { [weak self] in
                    await previous?.value
                    guard let self, let message = SlackCatchUp.message(replies, key: key, since: since,
                        owner: self.owner(), botUserID: self.botUserID(), isHandled: { self.threads.isHandled(ts: $0, for: key) }) else { return }
                    await self.handle(message)
                }
                inbound[key] = task
                await task.value
            }
        } catch { log("slack: catch-up failed (\(Self.code(error)))") }
    }

    private func messages(_ method: String, _ parameters: [String: String]) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var cursor = ""
        repeat {
            var parameters = parameters
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let page = try await call(method, parameters)
            guard let messages = page["messages"] as? [[String: Any]] else { throw StartError.invalidSlackResponse }
            result.append(contentsOf: messages)
            cursor = ((page["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } while !cursor.isEmpty
        return result
    }

    /// A channel thread is named exactly, so the agent never has to search for it.
    private func sender(for record: SlackThreadRecord) -> AgentMessageSender {
        let key = record.key
        var place: String
        if record.kind == .dm { place = "in his DM with you" }
        else {
            place = "in a thread in <#\(key.channel)>" + (channelName(key.channel).map { " (\($0))" } ?? "") + ": "
                + (Self.permalink(key, workspace: workspaceURL()).map { $0 + ", " } ?? "")
                + "channel ID \(key.channel), thread ts \(key.threadTs) (what slack_read_thread takes)"
        }
        if let context = record.context {
            let name = channelName(context).map { " (\($0))" } ?? ""
            place += ". He's viewing <#\(context)>\(name) beside the thread; read it with the slack_* tools when he refers to it"
        }
        return .init(id: AgentChatTranscriptText.slackSender, title: "", kind: .slack,
                     note: AgentMessageSender.slackNote(place: place, publicThread: record.kind == .channel))
    }

    /// A thread's root message link, as Slack's `chat.getPermalink` gives it.
    static func permalink(_ key: SlackThreadKey, workspace: String?) -> String? {
        guard var base = workspace, base.hasPrefix("https://"), key.threadTs.contains(".") else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/archives/\(key.channel)/p" + key.threadTs.replacingOccurrences(of: ".", with: "")
    }

    private func suggestPrompts(for key: SlackThreadKey, context: String?) async {
        let general = [
            ["title": SlackAgentStrings.catchUpSlack, "message": SlackAgentStrings.catchUpSlackMessage],
            ["title": SlackAgentStrings.checkInbox, "message": SlackAgentStrings.checkInboxMessage],
            ["title": SlackAgentStrings.planDay, "message": SlackAgentStrings.planDayMessage]]
        let prompts: [[String: String]]
        if let context, let name = channelName(context) {
            prompts = [
                ["title": String(format: SlackAgentStrings.catchUpChannel, name), "message": String(format: SlackAgentStrings.catchUpChannelMessage, "<#\(context)>")],
                ["title": String(format: SlackAgentStrings.summarizeChannel, name), "message": String(format: SlackAgentStrings.summarizeChannelMessage, "<#\(context)>")], general[0]]
        } else { prompts = general }
        await request("assistant.threads.setSuggestedPrompts", ["channel_id": key.channel, "thread_ts": key.threadTs, "prompts": SlackAgentCards.json(prompts)])
    }

    private func handle(_ message: SlackIncomingMessage) async {
        guard !threads.isHandled(ts: message.ts, for: message.key) else { return }
        let record = threads.record(for: message.key) ?? .init(key: message.key, kind: message.kind, updatedAt: now())
        threads.upsert(record); threads.markHandled(ts: message.ts, for: message.key)
        let source = sender(for: record)
        do {
            let id: UUID
            if let existing = record.chatId, await reopenChat(existing) {
                id = existing
                observe(id)
                if store.answerPendingQuestion(message.text, in: id) { return }
                let models = await self.models()
                var text = message.text
                if let prefix = SlackModelPrefix.parse(text, models: models) {
                    switch await store.switchModel(of: id, engine: prefix.engine, model: prefix.model, effort: prefix.effort) {
                    case .otherEngine:
                        let title = SlackModelPrefix.title(engine: prefix.engine, model: prefix.model, models: models)
                        await post(String(format: SlackAgentStrings.otherEngine, title), to: message.key); return
                    case .unavailable: await post(SlackAgentStrings.notTaken, to: message.key); return
                    case .switched, .unchanged: break
                    }
                    if prefix.rest.isEmpty {
                        let label = SlackModelPrefix.label(engine: prefix.engine, model: prefix.model, effort: prefix.effort, models: models)
                        await post(String(format: SlackAgentStrings.modelSet, label), to: message.key); return
                    }
                    text = prefix.rest
                }
                // His reply answers a waiting hand-off in place of its Done.
                store.conversation(for: id)?.setHandOff(nil)
                guard await store.deliverExternalMessage(.init(text: text, sender: source), to: id) else {
                    await post(SlackAgentStrings.notTaken, to: message.key); return
                }
                store.conversation(for: id)?.refusePendingPermissions()
            } else {
                let models = await self.models()
                let prefix = SlackModelPrefix.parse(message.text, models: models)
                var config = launchConfig()
                if let prefix { config.engine = prefix.engine; config.model = prefix.model; config.effort = prefix.effort }
                else if let saved = record.model, let engine = DrifterEngine(rawValue: saved.engine) {
                    config.engine = engine; config.model = saved.model; config.effort = saved.effort
                } else { (config.engine, config.model, config.effort) = SlackModelPrefix.defaultModel(in: models) }
                if let prefix, prefix.rest.isEmpty {
                    threads.setModel(.init(engine: config.engine.rawValue, model: config.model, effort: config.effort), for: message.key)
                    let label = SlackModelPrefix.label(engine: config.engine, model: config.model, effort: config.effort, models: models)
                    await post(String(format: SlackAgentStrings.modelSet, label), to: message.key); return
                }
                id = try startChat(prefix?.rest ?? message.text, source, config)
                threads.setChat(id, for: message.key)
            }
            observe(id)
        } catch StartError.noWindow { await post(SlackAgentStrings.noWindow, to: message.key) }
        catch { await post(SlackAgentStrings.notTaken + " " + error.localizedDescription, to: message.key) }
    }

    private func reconcileObservations() {
        for id in linkedChats {
            guard store.conversation(for: id) != nil else {
                if let old = observations.removeValue(forKey: id), let record = threads.record(forChat: id) {
                    old.refresh?.cancel(); old.title?.cancel()
                    clearThinking(old, for: record.key)
                    closeCards(old, for: record.key, chat: id)
                }
                continue
            }
            observe(id)
        }
    }

    private func observe(_ id: UUID) {
        linkedChats.insert(id)
        guard let conversation = store.conversation(for: id), let record = threads.record(forChat: id),
              observations[id]?.conversation !== conversation else { return }
        observations[id]?.refresh?.cancel(); observations[id]?.title?.cancel()
        let observation = Observation(); observation.conversation = conversation
        observations[id] = observation
        store.closeTabsWhenIdle([id])
        conversation.$status.sink { [weak self, weak observation, weak conversation] status in
            guard let self, let observation, let conversation else { return }
            self.cardsPublished(status, conversation: conversation, record: record, observation: observation)
            guard observation.status != status else { return }
            let previous = observation.status; observation.status = status
            self.changed(status, from: previous, conversation: conversation, record: record, observation: observation)
        }.store(in: &observation.bindings)
        // Only changes: a card posted before Mist relaunched still answers its Done.
        conversation.$handOff.dropFirst().removeDuplicates().sink { [weak self, weak observation, weak conversation] handOff in
            guard let self, let observation, let conversation else { return }
            self.handOffChanged(handOff, conversation: conversation, record: record, observation: observation)
        }.store(in: &observation.bindings)
        // Channel threads are agent sessions too, so every thread takes its chat's title.
        conversation.$title.removeDuplicates().sink { [weak self, weak observation] title in
            guard let self, let observation else { return }
            observation.title?.cancel()
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title != MistAppID.drifter.name, self.sentTitles[record.key] != title else { return }
            observation.title = Task { [weak self] in
                guard let self else { return }
                do { try await self.sleep(1_000_000_000); try Task.checkCancellation() } catch { return }
                self.sentTitles[record.key] = title
                self.enqueue(observation) { [weak self] in
                    await self?.request("agents.sessions.rename", ["channel_id": record.key.channel, "thread_ts": record.key.threadTs, "title": String(title.prefix(200))])
                }
            }
        }.store(in: &observation.bindings)
    }

    private func changed(_ status: AgentConversationStatus, from previous: AgentConversationStatus?,
                         conversation: AgentConversation, record: SlackThreadRecord, observation: Observation) {
        observation.refresh?.cancel(); observation.refresh = nil
        if observation.stopPending, status != .starting {
            observation.stopPending = false
            if status == .running || status == .awaitingPermission {
                // `$status` publishes before the value is stored, and the session's stop checks it.
                Task { @MainActor [weak conversation] in conversation?.onStop?() }
                log("slack: pending stop routed to chat")
            }
        }
        let slack = AgentChatTranscriptText.isSlackTurn(conversation.items)
        if slack && (status == .starting || status == .running) {
            observation.thinking = true
            enqueue(observation) { [weak self] in await self?.status(working: true, for: record.key) }
            observation.refresh = Task { [weak self, weak observation, sleep] in
                while !Task.isCancelled {
                    do { try await sleep(60_000_000_000); try Task.checkCancellation() } catch { return }
                    guard let observation else { return }
                    self?.enqueue(observation) { [weak self] in await self?.status(working: true, for: record.key) }
                }
            }
        } else if status != .starting && status != .running {
            clearThinking(observation, for: record.key)
        }
        guard slack else { return }
        if case let .failed(message) = status, previous == .starting || previous == .running || previous == .awaitingPermission {
            enqueue(observation) { [weak self] in await self?.post(String(format: SlackAgentStrings.failed, message), to: record.key) }
        }
    }

    private func taskFinished(_ id: UUID, _ finish: AgentTaskFinish, items: [AgentChatItem]) {
        guard let record = threads.record(forChat: id), AgentChatTranscriptText.isSlackTurn(items) else { return }
        if observations[id] == nil { observe(id) }
        guard let observation = observations[id] else { return }
        enqueue(observation) { [weak self] in await self?.postReply(finish.message, chat: id, to: record.key) }
    }

    private func enqueue(_ observation: Observation, _ action: @escaping @MainActor () async -> Void) {
        let previous = observation.output
        observation.output = Task { await previous?.value; await action() }
    }

    private func clearThinking(_ observation: Observation, for key: SlackThreadKey) {
        guard observation.thinking else { return }
        observation.thinking = false
        enqueue(observation) { [weak self] in await self?.status(working: false, for: key) }
    }

    private func findRequest(_ id: String, in conversation: AgentConversation) -> AgentChatItem.PermissionRequest? {
        for item in conversation.items.reversed() {
            if case let .permissionRequest(request) = item.kind, request.requestId == id { return request }
        }
        return nil
    }

    private func cardsPublished(_ status: AgentConversationStatus, conversation: AgentConversation,
                                record: SlackThreadRecord, observation: Observation) {
        // Completed cards leave the outstanding set; streaming updates never rescan their history.
        for (id, card) in observation.cards {
            let current = findRequest(id, in: conversation)
            guard current?.status != .pending else { continue }
            observation.cards[id] = nil
            observation.updated.insert(id)
            let request = current ?? card.request
            let outcome = current.map(SlackAgentCards.outcome) ?? SlackAgentStrings.noLongerWaiting
            enqueue(observation) { [weak self] in
                guard let ts = card.ts else { return }
                await self?.updateCard(request, chat: conversation.id, channel: record.key.channel, ts: ts, outcome: outcome)
            }
        }
        guard status == .awaitingPermission, AgentChatTranscriptText.isSlackTurn(conversation.items) else { return }
        for item in conversation.items.reversed() {
            if case .userMessage = item.kind { break }
            if case .peerMessage = item.kind { break }
            guard case let .permissionRequest(request) = item.kind, request.status == .pending,
                  observation.posted.insert(request.requestId).inserted else { continue }
            let card = Observation.Card(request: request)
            observation.cards[request.requestId] = card
            enqueue(observation) { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.call("chat.postMessage", ["channel": record.key.channel, "thread_ts": record.key.threadTs,
                        "text": SlackAgentCards.title(request), "blocks": SlackAgentCards.json(SlackAgentCards.blocks(request, chat: conversation.id))])
                    card.ts = result["ts"] as? String
                    self.log("slack: card posted")
                } catch { self.log("slack: card post failed (\(Self.code(error)))") }
            }
        }
    }

    /// A hand-off in a Slack turn posts its own card; once it closes (Done in Mist or Slack, or Johnny's message), the
    /// card shows it's done.
    private func handOffChanged(_ handOff: AgentHandOff?, conversation: AgentConversation, record: SlackThreadRecord, observation: Observation) {
        if let card = observation.handOffCard, card.handOff.id != handOff?.id {
            observation.handOffCard = nil
            enqueue(observation) { [weak self] in
                guard let ts = card.ts else { return }
                await self?.updateHandOffCard(card.handOff, chat: conversation.id, channel: record.key.channel, ts: ts, outcome: AgentChatStrings.handOffDone)
            }
        }
        guard let handOff, observation.handOffCard == nil, AgentChatTranscriptText.isSlackTurn(conversation.items) else { return }
        let card = Observation.HandOffCard(handOff: handOff)
        observation.handOffCard = card
        enqueue(observation) { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.call("chat.postMessage", ["channel": record.key.channel, "thread_ts": record.key.threadTs,
                    "text": handOff.message, "blocks": SlackAgentCards.json(SlackAgentCards.handOffBlocks(handOff, chat: conversation.id))])
                card.ts = result["ts"] as? String
                self.log("slack: hand-off card posted")
            } catch { self.log("slack: hand-off card post failed (\(Self.code(error)))") }
        }
    }

    private func updateHandOffCard(_ handOff: AgentHandOff, chat: UUID, channel: String, ts: String, outcome: String) async {
        guard updatedCards[channel, default: []].insert(ts).inserted else { return }
        await request("chat.update", ["channel": channel, "ts": ts, "text": handOff.message,
            "blocks": SlackAgentCards.json(SlackAgentCards.handOffBlocks(handOff, chat: chat, outcome: outcome))])
    }

    /// Done pressed in Slack arrives as Johnny's Slack "Done.", so the turn it wakes posts back to the thread.
    private func handOffDone(_ value: SlackAgentCards.Value, action: SlackBlockAction) async {
        guard let record = threads.record(forChat: value.chat), record.key.channel == action.channel,
              action.threadTs == nil || action.threadTs == record.key.threadTs else { return }
        guard let conversation = store.conversation(for: value.chat), conversation.handOff?.id == value.request else {
            // Already closed: its own change updated the card, or the chat is gone.
            await updateCard(nil, chat: value.chat, channel: action.channel, ts: action.messageTs, outcome: SlackAgentStrings.noLongerWaiting)
            return
        }
        conversation.setHandOff(nil)
        guard await reopenChat(value.chat), await store.deliverExternalMessage(.init(text: "Done.", sender: sender(for: record)), to: value.chat) else {
            await post(SlackAgentStrings.notTaken, to: record.key)
            return
        }
    }

    private func closeCards(_ observation: Observation, for key: SlackThreadKey, chat: UUID) {
        if let card = observation.handOffCard {
            observation.handOffCard = nil
            enqueue(observation) { [weak self] in
                guard let ts = card.ts else { return }
                await self?.updateHandOffCard(card.handOff, chat: chat, channel: key.channel, ts: ts, outcome: SlackAgentStrings.noLongerWaiting)
            }
        }
        for (id, card) in observation.cards {
            observation.cards[id] = nil
            observation.updated.insert(id)
            enqueue(observation) { [weak self] in
                guard let ts = card.ts else { return }
                await self?.updateCard(card.request, chat: chat, channel: key.channel, ts: ts, outcome: SlackAgentStrings.noLongerWaiting)
            }
        }
    }

    private func updateCard(_ request: AgentChatItem.PermissionRequest?, chat: UUID, channel: String, ts: String, outcome: String) async {
        guard updatedCards[channel, default: []].insert(ts).inserted else { return }
        let blocks = request.map { SlackAgentCards.blocks($0, chat: chat, outcome: outcome) } ?? [SlackAgentCards.context(outcome)]
        await self.request("chat.update", ["channel": channel, "ts": ts, "text": outcome, "blocks": SlackAgentCards.json(blocks)])
    }

    private func handle(_ action: SlackBlockAction) async {
        guard action.actionId != "drifter.select",
              let value = try? JSONDecoder().decode(SlackAgentCards.Value.self, from: Data(action.value.utf8)) else { return }
        if action.actionId == "drifter.handOffDone" { await handOffDone(value, action: action); return }
        let conversation = store.conversation(for: value.chat)
        let request = conversation.flatMap { findRequest(value.request, in: $0) }
        guard let conversation, let request, request.status == .pending else {
            // A card already reconciled by its status publish needs no second update.
            if observations[value.chat]?.updated.contains(value.request) == true { return }
            let original = request ?? observations[value.chat]?.cards[value.request]?.request
            await updateCard(original, chat: value.chat, channel: action.channel, ts: action.messageTs, outcome: SlackAgentStrings.noLongerWaiting)
            return
        }
        guard let record = threads.record(forChat: value.chat), record.key.channel == action.channel,
              action.threadTs == nil || action.threadTs == record.key.threadTs else { return }
        let response: AgentPermissionResponse
        switch action.actionId {
        case "drifter.allow": response = .allow
        case "drifter.deny": response = .deny(message: nil)
        case "drifter.submit":
            let selections = Dictionary(uniqueKeysWithValues: request.questions.indices.map { index in
                (index, AgentPermissionQuestion.Selection(options: Set((action.selections["q\(index)"] ?? []).compactMap(Int.init))))
            })
            guard let answer = request.answerResponse(selections) else {
                await self.request("chat.postEphemeral", ["channel": action.channel, "user": owner(), "thread_ts": action.threadTs ?? record.key.threadTs, "text": SlackAgentStrings.answerEveryQuestion])
                return
            }
            response = answer
        default:
            guard let q = value.q, let o = value.o, action.actionId == "drifter.option.\(o)",
                  request.questions.indices.contains(q), request.questions[q].options.indices.contains(o),
                  let answer = request.answerResponse([q: .init(options: [o])]) else { return }
            response = answer
        }
        conversation.onPermissionDecision?(request.requestId, response)
    }

    /// Slack shows its own working line and stop button while a session is `processing`.
    private func status(working: Bool, for key: SlackThreadKey) async {
        await request("agents.sessions.setStatus", ["channel_id": key.channel, "thread_ts": key.threadTs, "status": working ? "processing" : "active"])
    }

    private func post(_ text: String, to key: SlackThreadKey) async {
        for chunk in SlackMrkdwn.chunks(text) {
            await request("chat.postMessage", ["channel": key.channel, "thread_ts": key.threadTs, "text": chunk, "unfurl_links": "false", "unfurl_media": "false"])
        }
    }

    /// Every reply ends with a context line naming its model and effort, under its last chunk, a
    /// section block (3000 characters at most).
    private func postReply(_ text: String, chat: UUID, to key: SlackThreadKey) async {
        guard let config = store.drifterConfig(for: chat) else { await post(text, to: key); return }
        let chunks = SlackMrkdwn.chunks(text, limit: 3000)
        guard !chunks.isEmpty else { return }
        let label = SlackModelPrefix.label(engine: config.engine, model: config.model, effort: config.effort, models: await models())
        for (index, chunk) in chunks.enumerated() {
            var parameters = ["channel": key.channel, "thread_ts": key.threadTs, "text": chunk, "unfurl_links": "false", "unfurl_media": "false"]
            if index == chunks.count - 1 {
                parameters["blocks"] = SlackAgentCards.json([["type": "section", "text": ["type": "mrkdwn", "text": chunk]], SlackAgentCards.context(label)])
            }
            await request("chat.postMessage", parameters)
        }
    }

    private func request(_ method: String, _ parameters: [String: String]) async {
        do {
            _ = try await call(method, parameters)
            log("slack: \(method) ok")
        } catch { log("slack: \(method) failed (\(Self.code(error)))") }
    }

    private static func code(_ error: Error) -> String {
        (error as? SlackAPIError)?.code ?? String((error as NSError).code)
    }
}
