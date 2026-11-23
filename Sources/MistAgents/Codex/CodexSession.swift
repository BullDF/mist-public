import Foundation

@MainActor
final class CodexSession: DrifterBackgroundTaskSession {
    var automaticallyAllows: ((String, Bool) -> Bool)?
    var onToolPaths: (([String]) -> Void)?
    var agentTextTransform: ((String) -> String)?
    var allowsFileChange: (([String]) -> Bool)?
    var onStarted: ((Int32) -> Void)?
    var onEnded: (() -> Void)?
    var model: String
    var effort: String
    let conversation: AgentConversation
    private(set) var transcript = CodexTranscript()
    private(set) var threadId: String?
    private(set) var resumeId: String?
    private var turnId: String?
    private let request: CodexLaunchRequest
    private var process: CodexProcess?
    private var pending: [String: CodexServerRequest] = [:]
    private var closed = false
    private var failed = false
    private var stopping = false
    private var startup: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var titleThread: CodexTitleThread?
    private var titleRequested = false
    private var inheritedServers: Set<String> = []
    private let replyWriter: ((CodexJSON, CodexJSON) -> Void)?
    private let requestWriter: ((String, CodexJSON) async throws -> CodexJSON)?
    private var queue = AgentMessageQueue()
    private var pendingSendNow: String?

    init(request: CodexLaunchRequest, conversation: AgentConversation,
         environment: @escaping @Sendable () async -> ClaudeCodeEnvironment = { await ClaudeCodeEnvironment.shared.value },
         replyWriter: ((CodexJSON, CodexJSON) -> Void)? = nil,
         requestWriter: ((String, CodexJSON) async throws -> CodexJSON)? = nil) {
        self.request = request; self.conversation = conversation
        self.replyWriter = replyWriter
        self.requestWriter = requestWriter
        model = request.model; effort = request.effort
        if let resume = request.resume {
            transcript = CodexTranscript(restoring: resume.items)
            threadId = resume.sessionId
            resumeId = resume.sessionId
            // A chat that never started (restored before its first message, or /clear's fresh one) still needs a title.
            titleRequested = resume.sessionId != nil || !resume.items.isEmpty
            conversation.update(items: transcript.items, status: .starting)
        }
        conversation.onSend = { [weak self] text, attachments, mentions in self?.send(text: text, attachments: attachments, mentions: mentions) }
        conversation.onDeliver = { [weak self] message in
            guard let self else { return false }
            switch self.conversation.status {
            case .idle: return self.send(text: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender, clientId: nil)
            case .running, .awaitingPermission: return self.enqueue(message)
            default: return false
            }
        }
        conversation.onStop = { [weak self] in self?.stop() }
        conversation.onPermissionDecision = { [weak self] id, response in self?.decidePermission(requestId: id, response: response) }
        conversation.onClose = { [weak self] in self?.close() }
        conversation.onQueue = { [weak self] text, attachments, mentions in _ = self?.enqueue(AgentQueuedMessage(text: text, attachments: attachments, mentions: mentions)) }
        conversation.onRemoveQueued = { [weak self] id in self?.removeQueued(id) }
        conversation.onSendQueuedNow = { [weak self] id in self?.sendQueuedNow(id) }
        if requestWriter != nil {
            threadId = conversation.id.uuidString
            transcript.ready()
            publish()
            return
        }
        // An injected reply transport exercises permission handling without launching a CLI.
        if replyWriter != nil { return }
        startup = Task { [weak self] in
            let captured = await environment()
            guard !Task.isCancelled else { return }
            do {
                let process = try await CodexProcess.launch(folder: request.cwd, environment: captured, request: request)
                guard let self, !self.closed, !Task.isCancelled else { process.terminate(); return }
                self.process = process
                self.onStarted?(process.processIdentifier)
                self.eventTask = Task { [weak self] in
                    for await output in process.output { self?.receive(output) }
                }
                try await process.initialize()
                let account = try CodexAccount.parse(await process.request("account/read", .object(["refreshToken": .bool(false)])))
                guard account == .chatgpt else { throw CodexError.chatGPTLoginRequired }
                let inherited = await Task.detached { CodexProtocol.inheritedServers(environment: captured.variables) }.value
                guard !self.closed, !self.failed else { return }
                self.inheritedServers = inherited
                let result: CodexJSON
                if let id = request.resume?.sessionId {
                    do {
                        result = try await process.request("thread/resume", CodexProtocol.threadResume(request, threadId: id, inherited: inherited))
                    } catch CodexProcess.TransportError.server {
                        self.resumeId = nil
                        self.transcript.info(AgentChatStrings.historyUnavailable)
                        self.publish()
                        result = try await process.request("thread/start", CodexProtocol.threadStart(request, inherited: inherited))
                    }
                } else {
                    result = try await process.request("thread/start", CodexProtocol.threadStart(request, inherited: inherited))
                }
                guard !self.closed, !self.failed else { return }
                guard let id = result["thread"]["id"].string else { throw CodexError.invalidResponse }
                self.threadId = id
                self.transcript.ready()
                self.publish()
                self.send(text: request.prompt, attachments: request.attachments, mentions: request.mentions, sender: request.sender, clientId: nil)
            } catch { self?.fail(CodexStrings.launchFailed + "\n" + error.localizedDescription) }
        }
    }

    func send(text: String, attachments: [AgentAttachment] = [], mentions: [AgentTabMention] = []) {
        send(text: text, attachments: attachments, mentions: mentions, clientId: nil)
    }

    @discardableResult
    private func send(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention], sender: AgentMessageSender? = nil, clientId: String?) -> Bool {
        guard !closed, !failed, conversation.status == .idle, let threadId else { return false }
        let prompt = AgentMentionText(text: text, mentions: mentions).normalized
        let text = prompt.text, mentions = prompt.mentions
        stopping = false
        transcript.userSent(text: text, attachments: attachments, mentions: mentions, sender: sender)
        publish()
        let effort = effort, model = model
        Task { [weak self] in
            guard let self, !self.closed, !self.failed else { return }
            do {
                let expanded = AgentMentionText(text: text, mentions: mentions).agentText
                let result = try await self.clientRequest("turn/start", CodexProtocol.turnStart(threadId: threadId, text: sender?.agentText(self.agentTextTransform?(expanded) ?? expanded) ?? (self.agentTextTransform?(expanded) ?? expanded), attachments: attachments, effort: effort, model: model, clientUserMessageId: clientId))
                guard result["turn"]["id"].string != nil else { throw CodexError.invalidResponse }
                self.generateTitle(for: AgentMentionText(text: text, mentions: mentions).agentText)
            } catch { self.fail(error.localizedDescription) }
        }
        return true
    }

    private func generateTitle(for text: String) {
        guard !titleRequested, !closed, !failed, let process else { return }
        titleRequested = true
        titleTask = Task { [weak self] in
            do {
                let models = try await CodexModelCatalog.shared.load().models
                guard let self, !self.closed, !self.failed, !Task.isCancelled else { return }
                let choice = CodexProtocol.titleModel(models, fallback: self.model, effort: self.effort)
                let result = try await process.request("thread/start", CodexProtocol.titleThreadStart(self.request,
                    model: choice.model, inherited: self.inheritedServers))
                guard !self.closed, !Task.isCancelled, let id = result["thread"]["id"].string else { return }
                self.titleThread = CodexTitleThread(id: id)
                _ = try await process.request("turn/start", CodexProtocol.turnStart(threadId: id, text: CodexProtocol.titleInput(text),
                    attachments: [], effort: choice.effort, model: choice.model))
            } catch { /* Title generation is best effort and never retries. */ }
        }
    }

    func stop() {
        guard !closed, !failed, conversation.status == .running || conversation.status == .awaitingPermission else { return }
        queue.pause()
        pendingSendNow = nil
        publishQueue()
        stopping = true
        interruptIfReady()
    }

    private func interruptIfReady() {
        guard stopping, let threadId, let turnId else { return }
        Task { [weak self] in
            guard let self, !self.closed, !self.failed, self.turnId == turnId else { return }
            do { _ = try await self.clientRequest("turn/interrupt", .object(["threadId": .string(threadId), "turnId": .string(turnId)])) }
            catch { self.fail(error.localizedDescription) }
        }
    }

    private func clientRequest(_ method: String, _ params: CodexJSON) async throws -> CodexJSON {
        if let requestWriter { return try await requestWriter(method, params) }
        guard let process else { throw CodexError.invalidResponse }
        return try await process.request(method, params)
    }

    private func enqueue(_ message: AgentQueuedMessage) -> Bool {
        guard !closed, !failed, conversation.status == .running || conversation.status == .awaitingPermission else { return false }
        queue.enqueue(message)
        publishQueue()
        return true
    }

    private func removeQueued(_ id: String) {
        queue.remove(id)
        publishQueue()
    }

    private func sendQueuedNow(_ id: String) {
        guard !closed, !failed, pendingSendNow == nil,
              queue.messages.contains(where: { $0.id == id && !$0.delivering }) else { return }
        queue.resume()
        if conversation.status == .idle { sendQueued(id) }
        else if conversation.status == .running || conversation.status == .awaitingPermission {
            pendingSendNow = id
            queue.markDelivering(id)
            stopping = true
            interruptIfReady()
        }
        publishQueue()
    }

    private func sendQueued(_ id: String) {
        guard let message = queue.take(id) else { return }
        send(text: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender, clientId: message.id)
    }

    private func steerQueue() {
        guard !closed, !failed, !stopping, !queue.paused, let threadId, let turnId else { return }
        let messages = queue.messages.filter { !$0.delivering }
        guard !messages.isEmpty else { return }
        for message in messages { queue.markDelivering(message.id) }
        publishQueue()
        Task { [weak self] in
            guard let self else { return }
            for (index, message) in messages.enumerated() {
                guard !self.closed, !self.failed, self.turnId == turnId else { return }
                if self.queue.paused || self.stopping {
                    self.queue.returnDelivering(Set(messages[index...].map(\.id)))
                    self.publishQueue()
                    return
                }
                do {
                    _ = try await self.clientRequest("turn/steer", CodexProtocol.turnSteer(threadId: threadId, turnId: turnId, message: message, agentTextTransform: self.agentTextTransform))
                } catch {
                    guard self.turnId == turnId else { return }
                    self.queue.returnDelivering(Set(messages[index...].map(\.id)))
                    self.publishQueue()
                    return
                }
            }
        }
    }

    private func receiveQueueItem(_ message: CodexJSON) {
        let method = message["method"].string
        guard method == "item/started" || method == "item/completed" else { return }
        let item = message["params"]["item"]
        if item["type"].string == "userMessage", let id = item["clientId"].string, let taken = queue.take(id) {
            transcript.queuedMessageTaken(taken)
        }
        if method == "item/completed", let type = item["type"].string,
           !["userMessage", "agentMessage", "reasoning", "plan", "hookPrompt"].contains(type) { steerQueue() }
    }

    private func finishQueuedTurn() {
        queue.returnDelivering()
        let next = pendingSendNow ?? (queue.paused ? nil : queue.messages.first?.id)
        pendingSendNow = nil
        stopping = false
        if let next { sendQueued(next) }
        publishQueue()
    }

    private func publishQueue() { conversation.updateQueue(queue) }

    private func clearQueue() {
        queue = AgentMessageQueue()
        pendingSendNow = nil
        publishQueue()
    }

    func decidePermission(requestId: String, response: AgentPermissionResponse) {
        guard !closed, !failed, let pending = pending.removeValue(forKey: requestId) else { return }
        reply(id: pending.id, result: pending.reply(response))
        transcript.permissionDecided(requestId: requestId, response: response)
        publish()
    }

    func close() {
        guard !closed else { return }
        closed = true; startup?.cancel(); titleTask?.cancel(); pending.removeAll()
        clearQueue()
        onEnded?()
        if let process { process.terminate() }
        else { transcript.processExited(expected: true, stderr: ""); publish() }
    }

    func terminateNow() {
        closed = true; startup?.cancel(); titleTask?.cancel(); pending.removeAll()
        clearQueue()
        onEnded?()
        process?.terminateNow()
    }

    func receive(_ output: CodexProcess.Output) {
        switch output {
        case let .message(message):
            guard !closed, !failed else { return }
            if let incoming = CodexProtocol.threadID(in: message), incoming != threadId {
                if let request = CodexServerRequest(message) {
                    if request.hasKnownReply { reply(id: request.id, result: request.reply(.deny(message: nil))) }
                    else { process?.reject(id: request.id) }
                } else if let title = titleThread?.apply(message) { conversation.onTitleGenerated?(title) }
                return
            }
            if let serverRequest = CodexServerRequest(message) {
                if let permission = serverRequest.permission(items: transcript.items, allowedServers: request.inheritsCLIServers ? nil : Set(request.mcpServers.keys)) {
                    pending[serverRequest.key] = serverRequest
                    if automaticallyApproves(serverRequest, permission: permission) {
                        decidePermission(requestId: serverRequest.key, response: .allow)
                        return
                    }
                    transcript.permission(permission)
                } else if serverRequest.hasKnownReply {
                    reply(id: serverRequest.id, result: serverRequest.reply(.deny(message: nil)))
                } else { process?.reject(id: serverRequest.id) }
            } else {
                if message["method"].string == "thread/tokenUsage/updated" {
                    let usage = message["params"]["tokenUsage"]
                    conversation.contextTokens = usage["last"]["totalTokens"] == .null ? nil : usage["last"]["totalTokens"].integer
                    conversation.contextWindowSize = usage["modelContextWindow"] == .null ? nil : usage["modelContextWindow"].integer
                }
                if message["method"].string == "turn/started" {
                    if CodexProtocol.threadID(in: message) == threadId { resumeId = threadId }
                    turnId = message["params"]["turn"]["id"].string
                    interruptIfReady()
                }
                if message["method"].string == "turn/completed" {
                    guard let turnId, message["params"]["turn"]["id"].string == turnId else { return }
                    self.turnId = nil
                    pending.removeAll()
                }
                let item = message["params"]["item"]
                if ["item/started", "item/completed"].contains(message["method"].string ?? "") {
                    if item["type"].string == "commandExecution", let cwd = item["cwd"].string { onToolPaths?([cwd]) }
                    if item["type"].string == "fileChange" { onToolPaths?(item["changes"].array.compactMap { $0["path"].string }) }
                }
                transcript.apply(message)
                receiveQueueItem(message)
            }
            publish()
            if message["method"].string == "turn/completed" { finishQueuedTurn() }
        case let .exited(_, stderr):
            clearQueue()
            onEnded?()
            process = nil; pending.removeAll()
            if !failed || closed { transcript.processExited(expected: closed, stderr: stderr); publish() }
        case let .writeFailed(message): fail(message)
        }
    }

    private func fail(_ message: String) {
        guard !closed, !failed else { return }
        failed = true; pending.removeAll()
        clearQueue()
        onEnded?()
        transcript.fail(message); publish(); process?.terminate()
    }

    func backgroundTaskEnded(taskId: String, summary: String, status: AgentChatItem.TaskNotificationStatus) {
        transcript.backgroundTaskEnded(taskId: taskId, summary: summary, status: status)
        publish()
    }

    private func publish() {
        publishQueue()
        conversation.update(items: transcript.items, status: transcript.status,
                            turnStartedAt: transcript.turnStartedAt, outputTokens: transcript.outputTokens)
    }

    private func reply(id: CodexJSON, result: CodexJSON) {
        if let replyWriter { replyWriter(id, result) }
        else { process?.reply(id: id, result: result) }
    }

    func approvePendingBrowserTools() {
        for (id, request) in pending {
            if let permission = request.permission(items: transcript.items, allowedServers: self.request.inheritsCLIServers ? nil : Set(self.request.mcpServers.keys)),
               automaticallyApproves(request, permission: permission) {
                decidePermission(requestId: id, response: .allow)
            }
        }
    }

    private func automaticallyApproves(_ request: CodexServerRequest, permission: AgentChatItem.PermissionRequest) -> Bool {
        if request.method == "item/fileChange/requestApproval",
           allowsFileChange?(permission.input["changes"].array.map { $0.string ?? "" }) == true { return true }
        return automaticallyAllows?(permission.toolName, permission.requiresUserInteraction) == true
    }

    deinit { startup?.cancel(); titleTask?.cancel(); eventTask?.cancel(); process?.terminate() }
}
