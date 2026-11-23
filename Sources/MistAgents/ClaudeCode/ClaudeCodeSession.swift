import Combine
import Foundation
import OSLog

@MainActor
final class ClaudeCodeSession: ObservableObject, AgentChatSession {
    private static let logger = Logger(subsystem: "com.bulldf.mist", category: "ClaudeCode")
    var automaticallyAllows: ((String, Bool) -> Bool)?
    var onToolPaths: (([String]) -> Void)?
    var agentTextTransform: ((String) -> String)?
    var onStarted: ((Int32) -> Void)?
    var onEnded: (() -> Void)?
    private(set) var initializeRequestId: String?
    private var titleRequestId: String?
    private var contextRequestId: String?
    private var remoteControlRequestId: String?
    private var mcpRequest: (id: String, row: String)?
    private var mcpTarget: String?
    private var mcpRefreshPending = false
    private var mcpActions: [String: (row: String, name: String)] = [:]
    private var mcpPoll: Task<Void, Never>?
    var mcpClock: () -> Date = Date.init
    var mcpPollDelay: Duration = .seconds(1)
    var mcpStartupWindow: TimeInterval = 10
    private var mcpStarted = Date()
    private var settingsRequestIds: Set<String> = []
    private var models: [String: ClaudeCodeModelInfo] = [:]
    private var didRequestTitle = false
    private var hasWrittenUserMessage = false
    private(set) var sessionId: String
    private(set) var resumeId: String?
    private var unconfirmedResume = false
    /// The CLI reported the resumed session missing, so its exit starts a fresh one.
    private var resumeMissing = false
    private var launchRequest: ClaudeCodeLaunchRequest?
    private var launchEnvironment: (@Sendable () async -> ClaudeCodeEnvironment)?
    private var archiver: ClaudeCodeRemoteControlArchiver?
    let conversation: AgentConversation
    private(set) var transcript = ClaudeCodeTranscript()
    let settings: ClaudeCodeSessionSettings
    private var process: ClaudeCodeProcess?
    private var pendingPermissions: [String: ClaudeCodeJSON] = [:]
    private var closed = false
    private var failed = false
    private var startup: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var queue = AgentMessageQueue()
    private var writtenMessages: [String: AgentQueuedMessage] = [:]
    private var writtenRowIds: Set<String> = []
    private var queuedUUIDs: Set<String> = []
    private var rowUUIDs: [String: String] = [:]
    private var pendingSendNow: String?
    private var sendNowRequests: Set<String> = []
    /// An injected control transport keeps protocol/UI tests independent of a CLI process.
    init(config: ClaudeCodeLaunchConfig, conversation: AgentConversation, controlWriter: @escaping (String) -> Void) {
        sessionId = UUID().uuidString
        self.conversation = conversation
        settings = ClaudeCodeSessionSettings(config: config)
        settings.send = controlWriter
        settings.isEnabled = true
        conversation.onSend = { [weak self] text, attachments, mentions in self?.send(text: text, attachments: attachments, mentions: mentions) }
        conversation.onStopTask = { [weak self] id in self?.stopTask(id) }
        conversation.onBackgroundTool = { [weak self] id in self?.backgroundTool(id) }
        conversation.onMCPServerAction = { [weak self] name, action in self?.mcpAction(name, action) }
        conversation.onPermissionDecision = { [weak self] id, response in self?.decidePermission(requestId: id, response: response) }
        conversation.onClose = { [weak self] in self?.close() }
        connectQueue()
    }

    init(request: ClaudeCodeLaunchRequest, conversation: AgentConversation,
                     environment: @escaping @Sendable () async -> ClaudeCodeEnvironment = { await ClaudeCodeEnvironment.shared.value },
                     archiver: ClaudeCodeRemoteControlArchiver? = nil) {
        sessionId = request.resume?.sessionId ?? UUID().uuidString
        resumeId = request.resume?.sessionId
        unconfirmedResume = resumeId != nil
        launchRequest = request
        launchEnvironment = environment
        self.archiver = archiver
        didRequestTitle = request.resume.map { $0.sessionId != nil || !$0.items.isEmpty } ?? false
        self.conversation = conversation
        settings = ClaudeCodeSessionSettings(config: request.config)
        if let resume = request.resume {
            transcript = ClaudeCodeTranscript(restoring: resume.items)
            // The chat's last context usage stands until the CLI reports its own.
            if let tokens = conversation.contextTokens, let size = conversation.contextWindowSize {
                transcript.seedContext(tokens: tokens, windowSize: size)
            }
            // A Browser Agent restart resumes with its message; a restored chat waits for one.
            if !request.prompt.isEmpty || !request.attachments.isEmpty { transcript.restarting() }
            conversation.update(items: transcript.items, status: transcript.status)
        }
        settings.send = { [weak self] line in self?.process?.write(line) }
        conversation.onSend = { [weak self] text, attachments, mentions in self?.send(text: text, attachments: attachments, mentions: mentions) }
        conversation.onPermissionDecision = { [weak self] id, response in self?.decidePermission(requestId: id, response: response) }
        conversation.onStop = { [weak self] in self?.stop() }
        conversation.onStopTask = { [weak self] id in self?.stopTask(id) }
        conversation.onBackgroundTool = { [weak self] id in self?.backgroundTool(id) }
        conversation.onMCPServerAction = { [weak self] name, action in self?.mcpAction(name, action) }
        conversation.onClose = { [weak self] in self?.close() }
        connectQueue()
        launch()
    }

    private func launch() {
        guard let request = launchRequest, let environment = launchEnvironment else { return }
        mcpStarted = mcpClock()
        hasWrittenUserMessage = false
        startup?.cancel()
        let config = settings.config, sessionId = sessionId, resume = unconfirmedResume
        startup = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let resolved = await environment()
            guard !Task.isCancelled else { return }
            guard let executable = resolved.executable else {
                self?.fail(NSLocalizedString("browser.claudeCode.notFound", value: "Claude Code wasn't found. Install it, then try again.", comment: "Claude Code - CLI executable not installed"))
                return
            }
            let archiver = self?.archiver
            let log = await archiver?.prepareLaunch(sessionId: sessionId, folder: config.folder)
            if Task.isCancelled { archiver?.exited(sessionId); return }
            var arguments = ClaudeCodeProtocol.arguments(sessionId: sessionId, resume: resume, launchArguments: request.launchArguments)
            if let log { arguments += ["--debug=remote-bridge,code-session", "--debug-file", log.path] }
            // Process.run and login-shell capture never block the main actor.
            let launch = Task.detached {
                return try ClaudeCodeProcess(executable: executable,
                    arguments: arguments, folder: config.folder, environment: resolved.variables,
                    onTermination: { Task { @MainActor in archiver?.exited(sessionId) } })
            }
            do {
                let process = try await launch.value
                archiver?.retain(process, sessionId: sessionId)
                guard let self, !self.closed, !Task.isCancelled else { process.terminate(); return }
                self.process = process
                self.onStarted?(process.processIdentifier)
                self.initialize()
                self.settings.isEnabled = true
                self.eventTask = Task { [weak self] in
                    for await output in process.output {
                        guard !Task.isCancelled else { break }
                        self?.receive(output)
                    }
                }
                if request.resume == nil { self.send(text: request.prompt, attachments: request.attachments, mentions: request.mentions, sender: request.sender, initial: true) }
                else if !self.unconfirmedResume { self.resumed() }
            } catch {
                archiver?.exited(sessionId)
                self?.fail(NSLocalizedString("browser.claudeCode.launchFailed", value: "Claude Code couldn't start.", comment: "Claude Code - Process launch failed") + "\n" + error.localizedDescription)
            }
        }
    }

    /// A resumed session is ready once its CLI answers; a restart's message goes out then.
    private func resumed() {
        transcript.ready()
        publish()
        guard let request = launchRequest else { return }
        send(text: request.prompt, attachments: request.attachments, mentions: request.mentions, sender: request.sender, initial: false)
    }

    func send(text: String, attachments: [AgentAttachment] = [], mentions: [AgentTabMention] = []) {
        send(text: text, attachments: attachments, mentions: mentions, initial: false)
    }

    func initialize() {
        guard initializeRequestId == nil else { return }
        let id = UUID().uuidString
        initializeRequestId = id
        settings.send?(ClaudeCodeProtocol.initialize(requestId: id, perTaskStopAffordance: true))
        // The window size otherwise arrives only with the first turn's result.
        let contextId = UUID().uuidString
        contextRequestId = contextId
        settings.send?(ClaudeCodeProtocol.contextUsage(requestId: contextId))
    }

    @discardableResult
    private func send(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention], sender: AgentMessageSender? = nil, initial: Bool) -> Bool {
        guard !closed, !failed, settings.isEnabled,
              initial || conversation.status == .idle else { return false }
        let prompt = AgentMentionText(text: text, mentions: mentions).normalized
        let text = prompt.text, mentions = prompt.mentions
        transcript.userSent(text: text, attachments: attachments, mentions: mentions, sender: sender)
        publish()
        settings.send?(ClaudeCodeProtocol.user(text: sender?.agentText(agentText(text, mentions: mentions)) ?? agentText(text, mentions: mentions), attachments: attachments))
        userMessageWritten()
        requestTitle(text)
        return true
    }

    private func userMessageWritten() {
        hasWrittenUserMessage = true
        sendPendingTitle()
    }

    func sendPendingTitle() {
        guard !closed, !failed, settings.isEnabled, hasWrittenUserMessage,
              let title = conversation.pendingSessionTitle, let send = settings.send else { return }
        send(ClaudeCodeProtocol.renameSession(title, requestId: UUID().uuidString))
        conversation.pendingSessionTitle = nil
        conversation.onSessionTitleSent?()
    }

    private func agentText(_ text: String, mentions: [AgentTabMention]) -> String {
        let expanded = AgentMentionText(text: text, mentions: mentions).agentText(tabIds: true)
        return agentTextTransform?(expanded) ?? expanded
    }

    private func requestTitle(_ text: String) {
        if !didRequestTitle {
            didRequestTitle = true
            let id = UUID().uuidString
            titleRequestId = id
            settings.send?(ClaudeCodeProtocol.generateTitle(text, requestId: id))
        }
    }

    func decidePermission(requestId: String, response: AgentPermissionResponse) {
        guard !closed, !failed, let request = pendingPermissions.removeValue(forKey: requestId) else { return }
        var input = request["input"]
        var message: String?
        switch response {
        case let .allowWithInput(updated): input = updated
        case let .deny(feedback): message = feedback
        case .allow: break
        }
        settings.send?(ClaudeCodeProtocol.permission(requestId: requestId, allow: response.allows, input: input, denyMessage: message))
        transcript.permissionDecided(requestId: requestId, response: response)
        publish()
    }

    func approvePendingBrowserTools() {
        for (id, request) in pendingPermissions {
            if automaticallyAllows?(request["tool_name"].string ?? "", request["requires_user_interaction"].bool) == true {
                decidePermission(requestId: id, response: .allow)
            }
        }
    }

    func stop() {
        guard !closed, !failed, conversation.status == .running || conversation.status == .awaitingPermission else { return }
        queue.pause()
        interruptTurn()
        publishQueue()
    }

    private func interruptTurn() {
        let cancelQueued = !rowUUIDs.isEmpty
        queue.returnDelivering()
        rowUUIDs.removeAll()
        pendingSendNow = nil
        sendNowRequests.removeAll()
        transcript.stopRequested()
        settings.send?(ClaudeCodeProtocol.interrupt(cancelQueued: cancelQueued ? true : nil))
    }

    private func connectQueue() {
        conversation.onDeliver = { [weak self] message in
            guard let self else { return false }
            switch self.conversation.status {
            case .idle: return self.send(text: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender, initial: false)
            case .running, .awaitingPermission: return self.enqueue(message)
            default: return false
            }
        }
        conversation.onStop = { [weak self] in self?.stop() }
        conversation.onQueue = { [weak self] text, attachments, mentions in _ = self?.enqueue(AgentQueuedMessage(text: text, attachments: attachments, mentions: mentions)) }
        conversation.onRemoveQueued = { [weak self] id in self?.removeQueued(id) }
        conversation.onSendQueuedNow = { [weak self] id in self?.sendQueuedNow(id) }
    }

    private func enqueue(_ message: AgentQueuedMessage) -> Bool {
        guard !closed, !failed, settings.isEnabled,
              conversation.status == .running || conversation.status == .awaitingPermission else { return false }
        queue.enqueue(message)
        flushQueue()
        return true
    }

    private func writeQueued(_ message: AgentQueuedMessage) {
        let uuid = writtenRowIds.insert(message.id).inserted ? message.id : UUID().uuidString.lowercased()
        writtenMessages[uuid] = message
        rowUUIDs[message.id] = uuid
        settings.send?(ClaudeCodeProtocol.user(text: message.sender?.agentText(agentText(message.text, mentions: message.mentions)) ?? agentText(message.text, mentions: message.mentions),
                                             attachments: message.attachments, uuid: uuid))
        userMessageWritten()
    }

    private func resumeQueue() {
        queue.resume()
        flushQueue()
    }

    private func flushQueue() {
        defer { publishQueue() }
        guard !closed, !failed, !queue.paused else { return }
        for message in queue.messages {
            if rowUUIDs[message.id] == nil { writeQueued(message) }
        }
    }

    private func removeQueued(_ id: String) {
        guard queue.remove(id) != nil else { return }
        if let uuid = rowUUIDs.removeValue(forKey: id) { settings.send?(ClaudeCodeProtocol.cancelAsyncMessage(uuid)) }
        flushQueue()
    }

    private func sendQueuedNow(_ id: String) {
        guard !closed, !failed, let message = queue.messages.first(where: { $0.id == id && !$0.delivering }) else { return }
        if conversation.status == .idle {
            queue.take(id)
            if let uuid = rowUUIDs.removeValue(forKey: id) { settings.send?(ClaudeCodeProtocol.cancelAsyncMessage(uuid)) }
            send(text: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender, initial: false)
            resumeQueue()
        } else if conversation.status == .running || conversation.status == .awaitingPermission {
            guard pendingSendNow == nil, sendNowRequests.isEmpty else { return }
            if rowUUIDs[id] == nil {
                queue.moveToFront(id)
                writeQueued(message)
            }
            resumeQueue()
            queue.markDelivering(id)
            pendingSendNow = rowUUIDs[id]
            transcript.stopRequested()
            sendNowIfQueued()
        }
        publishQueue()
    }

    private func sendNowIfQueued() {
        guard let uuid = pendingSendNow, queuedUUIDs.contains(uuid) else { return }
        pendingSendNow = nil
        let requestId = UUID().uuidString
        sendNowRequests.insert(requestId)
        settings.send?(ClaudeCodeProtocol.interrupt(requestId: requestId, sendNow: true, messageUUID: uuid))
    }

    private func receiveQueueEvent(_ event: ClaudeCodeEvent) {
        switch event {
        case let .user(value) where value["isReplay"].bool:
            guard let uuid = value["uuid"].string, let message = writtenMessages.removeValue(forKey: uuid) else { return }
            queue.take(message.id)
            if let current = rowUUIDs.removeValue(forKey: message.id), current != uuid {
                settings.send?(ClaudeCodeProtocol.cancelAsyncMessage(current))
            }
            queuedUUIDs.remove(uuid)
            if pendingSendNow == uuid { pendingSendNow = nil; transcript.clearStopRequest() }
            transcript.queuedMessageTaken(message)
        case let .commandLifecycle(value):
            guard let uuid = value["command_uuid"].string else { return }
            switch value["state"].string {
            case "queued":
                queuedUUIDs.insert(uuid)
                sendNowIfQueued()
            case "completed", "cancelled":
                if let message = writtenMessages.removeValue(forKey: uuid), rowUUIDs[message.id] == uuid {
                    rowUUIDs[message.id] = nil
                }
                queuedUUIDs.remove(uuid)
            default: break
            }
        case let .controlResponse(value):
            if let id = value["response"]["request_id"].string, sendNowRequests.remove(id) != nil,
               value["response"]["response"]["send_now"].string != "stopped" {
                transcript.clearStopRequest()
            }
        default: break
        }
    }

    private func publishQueue() { conversation.updateQueue(queue) }

    private func clearQueue() {
        queue = AgentMessageQueue()
        writtenMessages.removeAll()
        writtenRowIds.removeAll()
        rowUUIDs.removeAll()
        queuedUUIDs.removeAll()
        pendingSendNow = nil
        sendNowRequests.removeAll()
        publishQueue()
    }

    func stopTask(_ id: String) {
        guard !closed, !failed, transcript.backgroundTasks.contains(where: { $0.id == id }) else { return }
        settings.send?(ClaudeCodeProtocol.stopTask(id))
    }

    func backgroundTool(_ toolUseId: String) {
        guard !closed, !failed, transcript.items.contains(where: {
            if case let .toolCall(tool) = $0.kind { return tool.toolUseId == toolUseId && tool.canBackground }
            return false
        }) else { return }
        settings.send?(ClaudeCodeProtocol.backgroundTask(toolUseId: toolUseId))
    }

    private func cancelMCP() {
        mcpPoll?.cancel()
        mcpPoll = nil
        mcpRequest = nil
        mcpTarget = nil
        mcpRefreshPending = false
        mcpActions.removeAll()
        transcript.endMCP()
    }

    private func requestMCP(_ row: String) {
        guard !closed, !failed else { return }
        mcpTarget = row
        mcpPoll?.cancel()
        mcpPoll = nil
        guard mcpRequest == nil else { mcpRefreshPending = true; return }
        guard let send = settings.send else { return }
        mcpRefreshPending = false
        let id = UUID().uuidString
        mcpRequest = (id, row)
        send(ClaudeCodeProtocol.mcpStatus(requestId: id))
    }

    private func mcpAction(_ name: String, _ action: ClaudeCodeMCPServerAction) {
        guard !closed, !failed, let row = transcript.liveMCPRow,
              let item = transcript.items.first(where: { $0.id == row }),
              case let .mcpServers(status) = item.kind,
              status.servers.contains(where: { $0.name == name }), !status.busy.contains(name), let send = settings.send else { return }
        transcript.changeMCP(row: row) { $0.busy.insert(name); $0.actionErrors[name] = nil }
        publish()
        let id = UUID().uuidString
        mcpActions[id] = (row, name)
        switch action {
        case .reconnect: send(ClaudeCodeProtocol.mcpReconnect(name, requestId: id))
        case .enable, .disable: send(ClaudeCodeProtocol.mcpToggle(name, enabled: action == .enable, requestId: id))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancelMCP()
        clearQueue()
        onEnded?()
        settings.end()
        startup?.cancel()
        pendingPermissions.removeAll()
        if let process { process.terminate() }
        else { transcript.processExited(expected: true, stderr: ""); publish() }
    }

    /// App termination: stop the process now rather than after `close()`'s grace period.
    func terminateNow() {
        closed = true
        cancelMCP()
        clearQueue()
        onEnded?()
        settings.end()
        startup?.cancel()
        process?.terminateNow()
    }

    func receive(_ output: ClaudeCodeProcess.Output) {
        switch output {
        case let .event(event):
            guard !closed, !failed else { return }
            if case let .system(value) = event, value["subtype"].string == "session_title_changed" { return }
            if unconfirmedResume {
                if case .result = event { resumeMissing = true; return }
                unconfirmedResume = false
                resumed()
            }
            if case let .assistant(value) = event {
                for block in value["message"]["content"].array where block["type"].string == "tool_use" {
                    guard ["Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "NotebookEdit"].contains(block["name"].string ?? "") else { continue }
                    onToolPaths?(["file_path", "path", "notebook_path"].compactMap { block["input"][$0].string })
                }
            }
            receiveQueueEvent(event)
            switch event {
            case let .permission(value):
                if let id = value["request_id"].string { pendingPermissions[id] = value["request"] }
                let request = value["request"]
                if let id = value["request_id"].string,
                   automaticallyAllows?(request["tool_name"].string ?? "", request["requires_user_interaction"].bool) == true {
                    decidePermission(requestId: id, response: .allow)
                    return
                }
            case let .permissionWithdrawn(id):
                pendingPermissions.removeValue(forKey: id)
                transcript.permissionWithdrawn(requestId: id)
            case let .unsupportedControl(id): process?.write(ClaudeCodeProtocol.unsupported(requestId: id))
            case let .system(value):
                if let id = value["session_id"].string { sessionId = id }
                if value["subtype"].string == "init" { resumeId = sessionId }
            case let .controlResponse(value):
                let response = value["response"]
                if let id = response["request_id"].string, let request = mcpRequest, id == request.id {
                    mcpRequest = nil
                    if mcpTarget != request.row || mcpRefreshPending {
                        if let target = mcpTarget { requestMCP(target) }
                    } else if response["subtype"].string == "success", let status = ClaudeCodeMCPStatus(reply: response["response"]) {
                        transcript.updateMCP(row: request.row, status: status)
                        if transcript.liveMCPRow == request.row,
                           status.servers.contains(where: { $0.status == "pending" }) || mcpClock().timeIntervalSince(mcpStarted) < mcpStartupWindow {
                            mcpPoll = Task { [weak self] in
                                guard let self else { return }
                                try? await Task.sleep(for: self.mcpPollDelay)
                                guard !Task.isCancelled, self.transcript.liveMCPRow == request.row else { return }
                                self.requestMCP(request.row)
                            }
                        }
                    } else {
                        mcpTarget = transcript.liveMCPRow
                    }
                    break
                }
                if let id = response["request_id"].string, let action = mcpActions.removeValue(forKey: id) {
                    transcript.changeMCP(row: action.row) {
                        $0.busy.remove(action.name)
                        $0.actionErrors[action.name] = response["subtype"].string == "error" ? response["error"].string : nil
                    }
                    if transcript.liveMCPRow == action.row, mcpTarget == action.row { requestMCP(action.row) }
                    break
                }
                if let id = value["response"]["request_id"].string, settingsRequestIds.remove(id) != nil {
                    if value["response"]["subtype"].string == "success" {
                        let applied = value["response"]["response"]["applied"]
                        settings.followAppliedSettings(applied, models: models)
                        if let model = applied["model"].string { transcript.modelChanged(model) }
                    }
                    break
                }
                if let id = titleRequestId, value["response"]["request_id"].string == id {
                    titleRequestId = nil
                    if value["response"]["subtype"].string == "success",
                       let title = value["response"]["response"]["title"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !title.isEmpty {
                        conversation.onTitleGenerated?(title)
                    }
                    break
                }
                if let id = contextRequestId, value["response"]["request_id"].string == id {
                    contextRequestId = nil
                    let usage = value["response"]["response"]
                    if value["response"]["subtype"].string == "success" {
                        transcript.seedContext(tokens: usage["totalTokens"].integer, windowSize: usage["maxTokens"].integer)
                    }
                    break
                }
                if let id = initializeRequestId, value["response"]["request_id"].string == id {
                    let reply = value["response"]
                    if reply["subtype"].string == "success", reply["response"]["remote_control_available"].bool {
                        let requestId = UUID().uuidString
                        remoteControlRequestId = requestId
                        settings.send?(ClaudeCodeProtocol.remoteControl(enabled: true, requestId: requestId))
                    }
                    models = (try? ClaudeCodeProtocol.models(from: value["response"]["response"])) ?? [:]
                    break
                }
                if let id = remoteControlRequestId, value["response"]["request_id"].string == id {
                    remoteControlRequestId = nil
                    if value["response"]["subtype"].string == "success" {
                        Self.logger.notice("Remote Control enabled")
                    } else {
                        Self.logger.error("Remote Control failed: \(value["response"]["error"].string ?? "unknown error", privacy: .public)")
                    }
                    break
                }
                switch settings.receive(value) {
                case let .confirmed(model):
                    if let model { transcript.modelChanged(model) }
                case let .failed(message): transcript.settingFailed(message)
                case nil: break
                }
            case let .result(value):
                pendingPermissions.removeAll()
                if ["model", "effort"].contains(value["local_command"].string ?? "") {
                    let id = UUID().uuidString
                    settingsRequestIds.insert(id)
                    settings.send?(ClaudeCodeProtocol.control(requestId: id, request: .object(["subtype": .string("get_settings")])))
                }
            default: break
            }
            var newMCPRow: String?
            if case let .assistant(value) = event, value["local_command_run"]["command"].string == "mcp",
               (value["local_command_run"]["args"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let uuid = value["uuid"].string ?? value["message"]["id"].string {
                let row = "command:" + uuid
                if !transcript.items.contains(where: { $0.id == row }) { newMCPRow = row }
            }
            transcript.apply(event)
            if let row = newMCPRow, transcript.items.contains(where: { $0.id == row }) { requestMCP(row) }
            publish()
            flushQueue()
        case let .exited(_, stderr):
            cancelMCP()
            if unconfirmedResume, resumeMissing, !closed {
                unconfirmedResume = false
                resumeMissing = false
                resumeId = nil
                sessionId = UUID().uuidString
                process = nil
                initializeRequestId = nil
                contextRequestId = nil
                remoteControlRequestId = nil
                titleRequestId = nil
                transcript.info(AgentChatStrings.historyUnavailable)
                publish()
                launch()
                return
            }
            clearQueue()
            onEnded?()
            settings.end()
            process = nil
            pendingPermissions.removeAll()
            if !failed || closed { transcript.processExited(expected: closed, stderr: stderr); publish() }
        case let .writeFailed(detail):
            // A resume whose session is gone exits at once, and its exit starts a fresh session.
            if !closed, !failed, !unconfirmedResume {
                fail(NSLocalizedString("browser.claudeCode.writeFailed", value: "Couldn't send the message to Claude Code.", comment: "Claude Code - Standard input write failed") + "\n" + detail)
                process?.terminate()
            }
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        failed = true
        cancelMCP()
        clearQueue()
        onEnded?()
        settings.end()
        transcript.fail(message)
        publish()
    }

    private func publish() {
        publishQueue()
        if !transcript.memoryFolders.isEmpty { conversation.memoryFolders = transcript.memoryFolders }
        conversation.contextTokens = transcript.latestInputTokens
        conversation.contextWindowSize = transcript.contextWindowSize
        conversation.update(items: transcript.items, status: transcript.status, backgroundTasks: transcript.backgroundTasks,
                            turnStartedAt: transcript.turnStartedAt, outputTokens: transcript.outputTokens)
    }

    deinit {
        mcpPoll?.cancel()
        startup?.cancel()
        eventTask?.cancel()
        process?.terminate()
    }
}
