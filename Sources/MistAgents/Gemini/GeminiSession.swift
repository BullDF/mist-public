import Foundation

@MainActor
final class GeminiSession: AgentChatSession, DrifterBackgroundTaskSession {
    var automaticallyAllows: ((String, Bool) -> Bool)?
    var onToolPaths: (([String]) -> Void)?
    var agentTextTransform: ((String) -> String)?
    var allowsFileChange: (([String]) -> Bool)?
    var onStarted: ((Int32) -> Void)?
    var onEnded: (() -> Void)?
    var model: String
    var effort: String
    private(set) var resumeId: String?

    private let conversation: AgentConversation
    private let request: GeminiLaunchRequest
    private var transcript: GeminiTranscript
    private var process: GeminiProcess?
    private var startup: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var titleRequested: Bool
    private var sessionId: String?
    private var lastModelAlias: String?
    private var supportsImages = false
    private var turnId: String?
    private var promptSent = false
    private var stopping = false
    private var closed = false
    private var failed = false
    private var permissions: [String: GeminiPermission] = [:]
    private var queue = AgentMessageQueue()
    private var pendingSendNow: String?

    init(request: GeminiLaunchRequest, conversation: AgentConversation,
         environment: @escaping @Sendable () async -> ClaudeCodeEnvironment) {
        self.request = request
        self.conversation = conversation
        model = request.model; effort = request.effort
        resumeId = request.resume?.sessionId
        titleRequested = request.resume?.sessionId != nil || !(request.resume?.items.isEmpty ?? true)
        transcript = GeminiTranscript(restoring: request.resume?.items ?? [])
        conversation.onSend = { [weak self] text, attachments, mentions in
            _ = self?.send(.init(text: text, attachments: attachments, mentions: mentions))
        }
        conversation.onDeliver = { [weak self] message in
            guard let self else { return false }
            return self.conversation.status == .idle ? self.send(message) : self.enqueue(message)
        }
        conversation.onStop = { [weak self] in self?.stop() }
        conversation.onPermissionDecision = { [weak self] id, response in self?.decidePermission(id, response) }
        conversation.onClose = { [weak self] in self?.close() }
        conversation.onQueue = { [weak self] text, attachments, mentions in
            _ = self?.enqueue(.init(text: text, attachments: attachments, mentions: mentions))
        }
        conversation.onRemoveQueued = { [weak self] id in
            self?.queue.remove(id)
            self?.publishQueue()
        }
        conversation.onSendQueuedNow = { [weak self] id in self?.sendQueuedNow(id) }
        startup = Task { [weak self] in
            let captured = await environment()
            guard !Task.isCancelled, let self else { return }
            await self.start(environment: captured)
        }
    }

    private func start(environment: ClaudeCodeEnvironment) async {
        do {
            let process = try await GeminiProcess.launch(request, environment: environment)
            guard !closed, !Task.isCancelled else { process.transport.terminate(); return }
            self.process = process
            onStarted?(process.transport.processIdentifier)
            events = Task { [weak self] in
                for await output in process.transport.output { self?.receive(output) }
            }
            supportsImages = try await process.initialize()
            let id: String
            if let resumeId {
                do {
                    id = try await process.open(request, resumeId: resumeId)
                } catch CodexProcess.TransportError.server {
                    self.resumeId = nil
                    transcript.rows.info(AgentChatStrings.historyUnavailable)
                    id = try await process.open(request, resumeId: nil)
                }
            } else { id = try await process.open(request, resumeId: nil) }
            guard !closed, !failed else { return }
            sessionId = id
            transcript.rows.ready()
            publish()
            _ = send(.init(text: request.prompt, attachments: request.attachments, mentions: request.mentions, sender: request.sender))
        } catch {
            fail(error as? GeminiError ?? .launchFailed)
        }
    }

    @discardableResult
    private func send(_ message: AgentQueuedMessage) -> Bool {
        guard !closed, !failed, conversation.status == .idle, let sessionId, let process else { return false }
        let id = UUID().uuidString
        turnId = id
        promptSent = false
        stopping = false
        let selectedModel = model, selectedEffort = effort
        transcript.rows.userSent(text: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender)
        publish()
        Task { [weak self] in
            guard let self, self.turnId == id, !self.closed, !self.failed else { return }
            do {
                let alias = GeminiProtocol.alias(model: selectedModel, effort: selectedEffort)
                if self.lastModelAlias != alias {
                    try await process.select(sessionId: sessionId, model: selectedModel, effort: selectedEffort)
                    self.lastModelAlias = alias
                }
                guard self.turnId == id, !self.closed, !self.failed else { return }
                if self.stopping { self.finish(.null); return }
                let expanded = AgentMentionText(text: message.text, mentions: message.mentions).agentText
                let transformed = self.agentTextTransform?(expanded) ?? expanded
                let text = message.sender?.agentText(transformed) ?? transformed
                self.resumeId = sessionId
                self.promptSent = true
                process.transport.requestInStream(id: id, method: "session/prompt",
                    params: GeminiProtocol.prompt(sessionId: sessionId, text: text, attachments: message.attachments, supportsImages: self.supportsImages))
                self.generateTitle(for: expanded)
            } catch { self.fail(.turnFailed) }
        }
        return true
    }

    private func generateTitle(for text: String) {
        guard !titleRequested else { return }
        titleRequested = true
        guard conversation.manualTitle == nil else { return }
        titleTask = Task { [weak self] in
            guard let title = await CodexMarkerNamer.title(text: text), !Task.isCancelled else { return }
            self?.conversation.onTitleGenerated?(title)
        }
    }

    private func receive(_ output: CodexProcess.Output) {
        switch output {
        case .exited:
            process = nil
            if !closed { fail(.exited) }
        case .writeFailed:
            fail(promptSent ? .turnFailed : .launchFailed)
        case let .message(message):
            receive(message)
        }
    }

    private func receive(_ message: CodexJSON) {
        let method = message["method"].string
        let params = message["params"]
        if method == "session/request_permission" {
            receivePermission(id: message["id"], params: params)
        } else if method != nil, message["id"] != .null {
            process?.transport.reject(id: message["id"])
        } else if !closed, !failed, promptSent {
            if method == "session/update", params["sessionId"].string == sessionId {
                let update = params["update"]
                if update["sessionUpdate"].string == "usage_update" {
                    // ACP's live update carries context totals. Actual output tokens come with the prompt reply.
                    conversation.contextTokens = update["used"] == .null ? nil : update["used"].integer
                    conversation.contextWindowSize = update["size"] == .null ? nil : update["size"].integer
                } else if let paths = transcript.apply(update) {
                    if !paths.isEmpty { onToolPaths?(paths) }
                    publish()
                }
            } else if method == nil, let id = message["id"].string, id == turnId {
                if message["error"] != .null, !stopping { fail(.turnFailed) }
                else { finish(message["result"]) }
            }
        }
    }

    private func receivePermission(id: CodexJSON, params: CodexJSON) {
        guard id != .null else { return }
        guard !closed, !failed, !stopping, promptSent, params["sessionId"].string == sessionId,
              let tool = transcript.updateTool(params["toolCall"]),
              !tool.name.hasPrefix("mcp__") || tool.name.hasPrefix("mcp__mistbrowser__") else {
            process?.transport.reply(id: id, result: GeminiPermission.cancelled)
            return
        }
        if !tool.paths.isEmpty { onToolPaths?(tool.paths) }
        let permission = GeminiPermission(rpcId: id, tool: tool, options: params["options"].array)
        if automaticallyApproves(permission) {
            process?.transport.reply(id: id, result: permission.reply(allows: true))
        } else {
            permissions[tool.id] = permission
            transcript.rows.permission(permission.card)
        }
        publish()
    }

    private func automaticallyApproves(_ permission: GeminiPermission) -> Bool {
        let tool = permission.tool
        if ["Edit", "Write"].contains(tool.name), allowsFileChange?(tool.paths) == true { return true }
        // Every Gemini call asks Mist, so the read-only browser tools Claude allows outright
        // (`--allowedTools`) and Codex never asks about (approval mode `writes`) are allowed here.
        if DrifterLaunchRequest.readOnlyTools.contains(where: { tool.name == "mcp__mistbrowser__" + $0 }),
           !permission.card.requiresUserInteraction { return true }
        return automaticallyAllows?(tool.name, permission.card.requiresUserInteraction) == true
    }

    private func decidePermission(_ id: String, _ response: AgentPermissionResponse) {
        guard let permission = permissions.removeValue(forKey: id) else { return }
        process?.transport.reply(id: permission.rpcId, result: permission.reply(allows: response.allows))
        transcript.permissionDecided(permission, response: response)
        publish()
    }

    func approvePendingBrowserTools() {
        for (id, permission) in permissions where automaticallyApproves(permission) { decidePermission(id, .allow) }
    }

    private func cancelPermissions() {
        for permission in permissions.values {
            process?.transport.reply(id: permission.rpcId, result: GeminiPermission.cancelled)
            transcript.permissionDecided(permission, response: .deny(message: nil))
        }
        permissions.removeAll()
    }

    private func enqueue(_ message: AgentQueuedMessage) -> Bool {
        guard !closed, !failed, [.starting, .running, .awaitingPermission].contains(conversation.status) else { return false }
        queue.enqueue(message)
        publishQueue()
        return true
    }

    private func sendQueuedNow(_ id: String) {
        guard !closed, !failed, pendingSendNow == nil,
              queue.messages.contains(where: { $0.id == id && !$0.delivering }) else { return }
        queue.resume()
        if conversation.status == .idle { sendQueued(id) }
        else if turnId != nil {
            pendingSendNow = id
            queue.markDelivering(id)
            interrupt()
        }
        publishQueue()
    }

    private func sendQueued(_ id: String) {
        if let message = queue.take(id) { send(message) }
    }

    private func stop() {
        guard turnId != nil, !closed, !failed else { return }
        queue.returnDelivering()
        queue.pause()
        pendingSendNow = nil
        publishQueue()
        interrupt()
    }

    private func interrupt() {
        guard !stopping else { return }
        stopping = true
        if let sessionId, promptSent { process?.cancel(sessionId: sessionId) }
        cancelPermissions()
        publish()
    }

    private func finish(_ result: CodexJSON) {
        let reason = result["stopReason"].string
        cancelPermissions()
        transcript.finish(result, stopped: stopping || reason == "cancelled")
        turnId = nil; promptSent = false; stopping = false
        publish()
        queue.returnDelivering()
        let next = pendingSendNow ?? (queue.paused ? nil : queue.messages.first?.id)
        pendingSendNow = nil
        if let next { sendQueued(next) }
        publishQueue()
    }

    func backgroundTaskEnded(taskId: String, summary: String, status: AgentChatItem.TaskNotificationStatus) {
        transcript.rows.backgroundTaskEnded(taskId: taskId, summary: summary, status: status)
        publish()
    }

    private func fail(_ error: GeminiError) {
        guard !closed, !failed else { return }
        failed = true
        titleTask?.cancel()
        cancelPermissions()
        queue = AgentMessageQueue()
        onEnded?()
        transcript.rows.fail(error.localizedDescription)
        publish()
        process?.transport.terminate()
    }

    func close() { shutDown(immediately: false) }
    func terminateNow() { shutDown(immediately: true) }

    private func shutDown(immediately: Bool) {
        guard !closed else { return }
        closed = true
        startup?.cancel()
        titleTask?.cancel()
        if let sessionId, promptSent { process?.cancel(sessionId: sessionId) }
        cancelPermissions()
        queue = AgentMessageQueue()
        onEnded?()
        transcript.rows.endSession()
        publish()
        if immediately { process?.transport.terminateNow() }
        else { process?.transport.terminate() }
    }

    private func publish() {
        let rows = transcript.rows
        conversation.update(items: rows.items, status: rows.status, turnStartedAt: rows.turnStartedAt, outputTokens: rows.outputTokens)
        publishQueue()
    }

    private func publishQueue() { conversation.updateQueue(queue) }
    deinit { startup?.cancel(); events?.cancel(); titleTask?.cancel(); process?.transport.terminate() }
}
