import Foundation

struct ClaudeCodeTranscript {
    var clock: () -> Date = Date.init
    private(set) var items: [AgentChatItem] = []
    private(set) var status: AgentConversationStatus = .starting
    private(set) var backgroundTasks: [AgentBackgroundTask] = []
    private var backgroundToolIds: [String: String] = [:]
    private var foregroundTaskIds: Set<String> = []
    private var foregroundTasks: [String: (toolId: String, description: String)] = [:]
    private(set) var resolvedModelId: String?
    private(set) var memoryFolders: [URL] = []
    private(set) var latestInputTokens: Int?
    private(set) var contextWindowSize: Int?
    private(set) var turnStartedAt: Date?
    private var finishedOutputTokens = 0
    private var thinkingTokens = 0
    private var streamedCharacters = 0
    private var hasOutputCount = false
    private var countedMessages: Set<String> = []
    var outputTokens: Int? { hasOutputCount ? finishedOutputTokens + thinkingTokens + streamedCharacters / 4 : nil }
    private var activeMessageId: String?
    private var messageItems: [String: Set<String>] = [:]
    private var toolInputs: [String: String] = [:]
    private var settledItems = Set<String>()
    private var pendingPermissions = Set<String>()
    private var permissionTools: [String: String] = [:]
    private var didRequestStop = false
    private var shownUsageLimits = Set<String>()

    init() {}
    /// A restored transcript waits for the message that launches its CLI.
    init(restoring items: [AgentChatItem]) {
        self.items = items
        status = .dormant
    }

    mutating func ready() { if status == .starting { status = .idle } }
    mutating func info(_ message: String) { append(.notice(text: message, level: .info)) }

    mutating func stopRequested() { didRequestStop = true }
    mutating func clearStopRequest() { didRequestStop = false }
    mutating func modelChanged(_ id: String) { resolvedModelId = id }

    /// Startup context usage; live message usage and the turn result take over once they arrive.
    mutating func seedContext(tokens: Int, windowSize: Int) {
        if latestInputTokens == nil, tokens > 0 { latestInputTokens = tokens }
        if contextWindowSize == nil, windowSize > 0 { contextWindowSize = windowSize }
    }
    mutating func settingFailed(_ message: String) { append(.notice(text: message, level: .error)) }

    var liveMCPRow: String? {
        items.last { if case let .mcpServers(status) = $0.kind { return status.live }; return false }?.id
    }

    mutating func updateMCP(row: String, status: ClaudeCodeMCPStatus) {
        guard let index = items.firstIndex(where: { $0.id == row }) else { return }
        var status = status
        if case let .mcpServers(old) = items[index].kind {
            guard old.live else { return }
            status.busy = old.busy
            status.actionErrors = old.actionErrors
        } else {
            guard case .commandOutput = items[index].kind else { return }
            endMCP()
        }
        items[index].kind = .mcpServers(status)
    }

    mutating func changeMCP(row: String, _ update: (inout ClaudeCodeMCPStatus) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == row }), case var .mcpServers(status) = items[index].kind, status.live else { return }
        update(&status)
        items[index].kind = .mcpServers(status)
    }

    mutating func endMCP() {
        for index in items.indices {
            if case .mcpServers = items[index].kind { items[index] = items[index].settled }
        }
    }

    mutating func userSent(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention] = [], sender: AgentMessageSender? = nil) {
        beginTurn()
        didRequestStop = false
        if sender?.kind == .checkIn { items += sender?.checkInItems ?? [] }
        else if sender?.kind != .task {
            append(sender.map { .peerMessage(name: $0.label, body: text) } ?? .userMessage(text: text, images: attachments.images))
            items[items.count - 1].mentions = mentions
            items[items.count - 1].files = attachments.files
        }
        status = .running
    }

    mutating func queuedMessageTaken(_ message: AgentQueuedMessage) {
        beginAutomaticTurnIfIdle()
        if message.sender?.kind == .checkIn { items += message.sender?.checkInItems ?? [] }
        guard message.sender?.kind != .task, message.sender?.kind != .checkIn else { return }
        append(message.sender.map { .peerMessage(name: $0.label, body: message.text) } ?? .userMessage(text: message.text, images: message.attachments.images))
        items[items.count - 1].mentions = message.mentions
        items[items.count - 1].files = message.attachments.files
    }

    mutating func permissionDecided(requestId: String, response: AgentPermissionResponse) {
        guard pendingPermissions.remove(requestId) != nil else { return }
        if !response.allows, let toolId = permissionTools[requestId] {
            updateTool(toolId) { $0.permissionDenied = true }
        }
        permissionTools[requestId] = nil
        for index in items.indices {
            if case var .permissionRequest(request) = items[index].kind, request.requestId == requestId {
                request.status = response.allows ? .allowed : .denied
                request.resolution = response
                items[index].kind = .permissionRequest(request)
            }
        }
        status = pendingPermissions.isEmpty ? .running : .awaitingPermission
    }

    mutating func permissionWithdrawn(requestId: String) {
        guard pendingPermissions.remove(requestId) != nil else { return }
        permissionTools[requestId] = nil
        items.removeAll {
            if case let .permissionRequest(request) = $0.kind { return request.requestId == requestId }
            return false
        }
        status = pendingPermissions.isEmpty ? .running : .awaitingPermission
    }

    mutating func processExited(expected: Bool, stderr: String) {
        endMCP()
        finishStreaming()
        settlePendingTools(endingSession: true)
        if expected { status = .ended }
        else {
            let message = NSLocalizedString("browser.claudeCode.exited", value: "Claude Code stopped unexpectedly.", comment: "Claude Code - Unexpected process exit")
            fail(stderr.isEmpty ? message : message + "\n" + stderr)
        }
    }

    mutating func fail(_ message: String) {
        endMCP()
        finishStreaming()
        settlePendingTools(endingSession: true)
        append(.notice(text: AgentChatStrings.failureNotice(message), level: .error))
        status = .failed(message)
    }

    mutating func restarting() {
        beginTurn()
        status = .starting
    }

    mutating func apply(_ event: ClaudeCodeEvent) {
        switch event {
        case let .system(value):
            if value["subtype"].string == "compact_boundary" {
                let metadata = value["compact_metadata"]
                let pre = metadata["pre_tokens"].double.map { _ in metadata["pre_tokens"].integer }
                let post = metadata["post_tokens"].double.map { _ in metadata["post_tokens"].integer }
                append(.compaction(trigger: ClaudeCodeCompactionTrigger(rawValue: metadata["trigger"].string ?? "") ?? .manual,
                    preTokens: pre, postTokens: post))
                if let post, post > 0 { latestInputTokens = post }
            }
            if value["subtype"].string == "peer_message_hold", let id = value["message_uuid"].string {
                let itemId = "peer-held:" + id
                let name = value["from_name"].string ?? ""
                switch value["state"].string {
                case "held": upsert(id: itemId, kind: .notice(text: AgentChatStrings.peerHeld(name), level: .info))
                case "dropped": upsert(id: itemId, kind: .notice(text: AgentChatStrings.peerDropped(name), level: .info))
                case "released": items.removeAll { $0.id == itemId }
                default: break
                }
            }
            if value["subtype"].string == "thinking_tokens" {
                beginAutomaticTurnIfIdle()
                thinkingTokens = max(0, value["estimated_tokens"].integer)
                hasOutputCount = true
            }
            if value["subtype"].string == "init" {
                beginAutomaticTurnIfIdle()
                resolvedModelId = value["model"].string
                memoryFolders = ["auto", "team"].compactMap { key in
                    guard let path = value["memory_paths"][key].string, !path.isEmpty else { return nil }
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            applyBackgroundEvent(value)
        case let .stream(value):
            beginAutomaticTurnIfIdle()
            stream(value)
        case let .assistant(value):
            beginAutomaticTurnIfIdle()
            if value["local_command_run"] != .null || value["local_command_source"] != .null {
                // Compaction re-sends the output it keeps, with its event uuid but a new message id and stale usage.
                let id = "command:" + (value["uuid"].string ?? value["message"]["id"].string ?? UUID().uuidString)
                if items.contains(where: { $0.id == id }) { return }
                if value["context_usage"] != .null {
                    let usage = ClaudeCodeContextUsage(value["context_usage"])
                    latestInputTokens = usage.totalTokens
                    contextWindowSize = usage.maxTokens
                    upsert(id: id, kind: .contextUsage(usage))
                } else {
                    upsert(id: id, kind: .commandOutput(command: value["local_command_run"]["command"].string ?? "",
                        text: value["message"]["content"].array.compactMap { $0["text"].string }.joined(separator: "\n"),
                        isError: value["local_command_source"].string?.hasPrefix("<local-command-stderr>") == true))
                }
            } else { assistant(value["message"]) }
        case let .user(value):
            if value["isReplay"].bool {
                switch value["origin"]["kind"].string {
                case "peer":
                    guard let body = value["origin"]["body"].string else { return }
                    beginAutomaticTurnIfIdle()
                    upsert(id: "peer:" + (value["origin"]["msg_id"].string ?? value["uuid"].string ?? UUID().uuidString),
                           kind: .peerMessage(name: value["origin"]["name"].string ?? "", body: body))
                // Typed through Remote Control; Mist's own stdin messages replay without an origin.
                case "human": remoteMessage(value)
                default: break
                }
                return
            }
            let results = value["message"]["content"].array.filter { $0["type"].string == "tool_result" }
            for block in results {
                guard let id = block["tool_use_id"].string else { continue }
                updateTool(id) { tool in
                    // The initial result acknowledges launch; completion arrives separately.
                    guard tool.background != .finished else { return }
                    tool.status = tool.background == .running ? .running : block["is_error"].bool ? .failed : .succeeded
                    tool.canBackground = false
                    tool.output = block["content"].string ?? block["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
                    tool.structuredResult = results.count == 1 ? value["tool_use_result"] : .null
                }
            }
        case let .permission(value):
            guard let id = value["request_id"].string else { return }
            let request = value["request"]
            let toolName = request["tool_name"].string ?? ""
            let relatedTool = items.compactMap { item -> AgentChatItem.ToolCall? in
                if case let .toolCall(tool) = item.kind, tool.toolUseId == request["tool_use_id"].string { return tool }
                return nil
            }.last
            permissionTools[id] = relatedTool?.toolUseId ?? items.compactMap { item -> AgentChatItem.ToolCall? in
                if case let .toolCall(tool) = item.kind, tool.status == .running, tool.name == toolName,
                   (try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8))) == request["input"] { return tool }
                return nil
            }.last?.toolUseId
            let relatedInput = relatedTool.flatMap { try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data($0.inputJSON.utf8)) }
            let plan = toolName == "ExitPlanMode" ? request["input"]["plan"].string ?? relatedInput?["plan"].string : nil
            let summaryInput = plan.map { ClaudeCodeJSON.object(["plan": .string($0)]) } ?? request["input"]
            pendingPermissions.insert(id)
            upsert(id: "permission:" + id, kind: .permissionRequest(.init(
                requestId: id, toolName: toolName,
                summary: ClaudeCodeProtocol.inputSummary(tool: toolName, input: summaryInput),
                input: request["input"], requiresUserInteraction: request["requires_user_interaction"].bool, plan: plan
            )))
            status = .awaitingPermission
        case let .result(value):
            let size = value["modelUsage"][resolvedModelId ?? ""]["contextWindow"].integer
            if size > 0 { contextWindowSize = size }
            finishStreaming()
            settlePendingTools()
            let stopped = value["is_error"].bool && didRequestStop
            if value["local_command"] == .null {
                append(.turnEnd(durationMilliseconds: value["duration_ms"].integer, finishedAt: clock(), stopped: stopped))
            }
            if value["is_error"].bool && !stopped {
                let fallback = NSLocalizedString("browser.claudeCode.turnFailed", value: "Claude Code couldn't complete this turn.", comment: "Claude Code - Failed turn")
                let detail = value["result"].string ?? value["errors"].array.compactMap(\.string).joined(separator: "\n")
                append(.notice(text: detail.isEmpty ? fallback : detail, level: .error))
            }
            didRequestStop = false
            status = .idle
        case let .rateLimit(value):
            usageLimitChanged(value["rate_limit_info"])
        case .permissionWithdrawn, .unsupportedControl, .controlResponse, .commandLifecycle: break
        }
    }

    private mutating func stream(_ value: ClaudeCodeJSON) {
        let event = value["event"]
        if event["type"].string == "message_start" {
            thinkingTokens = 0
            streamedCharacters = 0
            activeMessageId = event["message"]["id"].string ?? value["api_message_id"].string
        }
        guard let messageId = value["api_message_id"].string ?? activeMessageId else { return }
        if event["type"].string == "message_delta", event["usage"]["output_tokens"] != .null,
           countedMessages.insert(messageId).inserted {
            finishedOutputTokens += max(0, event["usage"]["output_tokens"].integer)
            thinkingTokens = 0
            streamedCharacters = 0
            hasOutputCount = true
        } else if event["type"].string == "content_block_delta", !countedMessages.contains(messageId) {
            let delta = event["delta"]
            if let text = delta["text"].string ?? delta["partial_json"].string {
                streamedCharacters += text.count
                hasOutputCount = true
            }
        }
        let id = messageId + ":" + String(event["index"].integer)
        guard !settledItems.contains(id) else { return }
        switch event["type"].string {
        case "content_block_start":
            setBlock(event["content_block"], id: id, messageId: messageId, streaming: true)
        case "content_block_delta":
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let delta = event["delta"]
            switch items[index].kind {
            case let .assistantText(text, _):
                items[index].kind = .assistantText(text: text + (delta["text"].string ?? ""), isStreaming: true)
            case var .toolCall(tool):
                toolInputs[id, default: ""] += delta["partial_json"].string ?? ""
                if let input = try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(toolInputs[id, default: ""].utf8)) {
                    tool.inputJSON = input.json(pretty: true)
                    tool.inputSummary = ClaudeCodeProtocol.inputSummary(tool: tool.name, input: input)
                    items[index].kind = .toolCall(tool)
                } else if Self.fileTools.contains(tool.name),
                          (try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8)))?["file_path"].string == nil,
                          let path = Self.streamedFilePath(toolInputs[id, default: ""]) {
                    // The row learns its file long before a Write's content ends, so memory's group can claim it.
                    let input = ClaudeCodeJSON.object(["file_path": .string(path)])
                    tool.inputJSON = input.json(pretty: true)
                    tool.inputSummary = ClaudeCodeProtocol.inputSummary(tool: tool.name, input: input)
                    items[index].kind = .toolCall(tool)
                }
            default: break
            }
        case "content_block_stop": finishStreaming(ids: [id])
        case "message_stop": finishStreaming(ids: messageItems[messageId] ?? [])
        default: break
        }
    }

    private static let fileTools: Set<String> = ["Write", "Edit", "MultiEdit"]

    /// A file tool's input opens with its `file_path`; this reads it from the streamed prefix once its string is complete.
    static func streamedFilePath(_ partial: String) -> String? {
        var rest = Substring(partial).drop(while: \.isWhitespace)
        guard rest.first == "{" else { return nil }
        rest = rest.dropFirst().drop(while: \.isWhitespace)
        guard rest.hasPrefix("\"file_path\"") else { return nil }
        rest = rest.dropFirst("\"file_path\"".count).drop(while: \.isWhitespace)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop(while: \.isWhitespace)
        guard rest.first == "\"" else { return nil }
        var escaped = false
        for index in rest.indices.dropFirst() {
            let character = rest[index]
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                let path = (try? JSONDecoder().decode([String].self, from: Data(("[" + rest[...index] + "]").utf8)))?.first
                return path?.isEmpty == false ? path : nil
            }
        }
        return nil
    }

    private mutating func assistant(_ message: ClaudeCodeJSON) {
        if message["model"].string != "<synthetic>", case .object = message["usage"] {
            let usage = message["usage"]
            latestInputTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + max(0, usage[$1].integer) }
        }
        guard let messageId = message["id"].string else { return }
        let blocks = message["content"].array
        for (index, block) in blocks.enumerated() where block["type"].string != "thinking" {
            // The CLI emits one authoritative assistant envelope per completed block,
            // often reusing the API message id (thinking, then text, then tools).
            let candidates = items.filter { item in
                guard messageItems[messageId]?.contains(item.id) == true else { return false }
                switch item.kind {
                case .assistantText: return block["type"].string == "text"
                case let .toolCall(tool): return block["id"].string == tool.toolUseId
                default: return false
                }
            }
            let matched = candidates.first { !settledItems.contains($0.id) } ?? candidates.last
            let id = blocks.count == 1
                ? matched?.id ?? messageId + ":" + String(messageItems[messageId]?.count ?? 0)
                : messageId + ":" + String(index)
            setBlock(block, id: id, messageId: messageId, streaming: false)
            settledItems.insert(id)
            toolInputs.removeValue(forKey: id)
        }
    }

    private mutating func setBlock(_ block: ClaudeCodeJSON, id: String, messageId: String, streaming: Bool) {
        let kind: AgentChatItem.Kind
        switch block["type"].string {
        case "text": kind = .assistantText(text: block["text"].string ?? "", isStreaming: streaming)
        case "tool_use":
            guard let toolId = block["id"].string else { return }
            let name = block["name"].string ?? ""
            var tool = AgentChatItem.ToolCall(toolUseId: toolId, name: name,
                inputSummary: ClaudeCodeProtocol.inputSummary(tool: name, input: block["input"]),
                inputJSON: block["input"].json(pretty: true))
            if let existing = items.first(where: { $0.id == id }), case let .toolCall(old) = existing.kind {
                tool.status = old.status
                tool.output = old.output
                tool.structuredResult = old.structuredResult
                tool.background = old.background
                tool.canBackground = old.canBackground
            }
            kind = .toolCall(tool)
        default: return
        }
        messageItems[messageId, default: []].insert(id)
        upsert(id: id, kind: kind)
    }

    private mutating func updateTool(_ id: String, update: (inout AgentChatItem.ToolCall) -> Void) {
        for index in items.indices {
            if case var .toolCall(tool) = items[index].kind, tool.toolUseId == id {
                update(&tool)
                items[index].kind = .toolCall(tool)
            }
        }
    }

    private mutating func finishStreaming(ids: Set<String>? = nil) {
        for index in items.indices where ids == nil || ids!.contains(items[index].id) {
            switch items[index].kind {
            case let .assistantText(text, _): items[index].kind = .assistantText(text: text, isStreaming: false)
            default: break
            }
        }
    }

    private mutating func remoteMessage(_ value: ClaudeCodeJSON) {
        let content = value["message"]["content"]
        let blocks = content.string.map { [ClaudeCodeJSON.object(["type": .string("text"), "text": .string($0)])] } ?? content.array
        let text = blocks.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined(separator: "\n\n")
        let images = blocks.compactMap { block -> AgentImageAttachment? in
            let source = block["source"]
            guard block["type"].string == "image", source["type"].string == "base64", let mediaType = source["media_type"].string,
                  let data = source["data"].string.flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return AgentImageAttachment(data: data, mediaType: mediaType)
        }
        guard !text.isEmpty || !images.isEmpty else { return }
        beginAutomaticTurnIfIdle()
        upsert(id: "remote:" + (value["uuid"].string ?? UUID().uuidString), kind: .userMessage(text: text, images: images))
    }

    private mutating func beginAutomaticTurnIfIdle() {
        if status == .idle || status == .starting { beginTurn(); status = .running }
    }

    private mutating func beginTurn() {
        turnStartedAt = clock()
        finishedOutputTokens = 0
        thinkingTokens = 0
        streamedCharacters = 0
        hasOutputCount = false
        countedMessages.removeAll()
        activeMessageId = nil
        didRequestStop = false
    }

    private mutating func applyBackgroundEvent(_ value: ClaudeCodeJSON) {
        switch value["subtype"].string {
        case "task_started":
            guard let id = value["task_id"].string else { return }
            if value["is_backgrounded"] == .bool(false) {
                foregroundTaskIds.insert(id)
                if let toolId = value["tool_use_id"].string {
                    foregroundTasks[id] = (toolId, value["description"].string ?? "")
                    updateTool(toolId) { tool in
                        if tool.name == "Bash", tool.status == .running, tool.background == nil {
                            tool.canBackground = true
                        }
                    }
                }
                backgroundTasks.removeAll { $0.id == id }
                return
            }
            foregroundTaskIds.remove(id)
            foregroundTasks[id] = nil
            guard let toolId = value["tool_use_id"].string else { return }
            backgroundToolIds[id] = toolId
            updateTool(toolId) { tool in
                tool.canBackground = false
                tool.background = .running
                tool.status = .running
            }
            if let index = backgroundTasks.firstIndex(where: { $0.id == id }) {
                backgroundTasks[index].kind = backgroundKind(toolId: toolId)
            }
        case "task_updated":
            guard let id = value["task_id"].string, value["patch"]["is_backgrounded"] == .bool(true),
                  let task = foregroundTasks.removeValue(forKey: id) else { return }
            foregroundTaskIds.remove(id)
            backgroundToolIds[id] = task.toolId
            updateTool(task.toolId) { tool in
                tool.canBackground = false
                tool.background = .running
                tool.status = .running
            }
            if !backgroundTasks.contains(where: { $0.id == id }) {
                backgroundTasks.append(.init(id: id, kind: backgroundKind(toolId: task.toolId), description: task.description))
            }
        case "background_tasks_changed":
            backgroundTasks = value["tasks"].array.compactMap { task in
                guard let id = task["task_id"].string else { return nil }
                if task["is_backgrounded"] == .bool(false) { foregroundTaskIds.insert(id) }
                guard !foregroundTaskIds.contains(id) else { return nil }
                return AgentBackgroundTask(id: id, kind: backgroundKind(toolId: backgroundToolIds[id]),
                    description: task["description"].string ?? "")
            }
        case "task_notification":
            if let id = value["task_id"].string,
               foregroundTaskIds.contains(id) || value["is_backgrounded"] == .bool(false) {
                if let toolId = value["tool_use_id"].string ?? foregroundTasks[id]?.toolId {
                    updateTool(toolId) { $0.canBackground = false }
                }
                foregroundTasks[id] = nil
                return
            }
            if let id = value["task_id"].string, !foregroundTaskIds.contains(id),
               value["is_backgrounded"] != .bool(false),
               let summary = value["summary"].string, !summary.isEmpty {
                let rawStatus = value["status"].string ?? ""
                let status: AgentChatItem.TaskNotificationStatus = rawStatus == "completed" ? .completed : rawStatus == "stopped" ? .stopped : .failed
                let eventId = value["uuid"].string ?? "\(id):\(value["run_id"].string ?? ""):\(rawStatus)"
                upsert(id: "task-notification:" + eventId,
                       kind: .taskNotification(summary: summary, status: status))
            }
            guard let id = value["task_id"].string, !foregroundTaskIds.contains(id),
                  value["is_backgrounded"] != .bool(false),
                  let toolId = value["tool_use_id"].string ?? backgroundToolIds[id] else { return }
            updateTool(toolId) { tool in
                tool.canBackground = false
                tool.background = .finished
                tool.status = value["status"].string == "completed" ? .succeeded : .failed
                tool.output = value["summary"].string ?? ""
                tool.structuredResult = .null
            }
        default: break
        }
    }

    /// The CLI repeats the event whenever a window's rounded percentage moves, so each limit state shows
    /// once until usage is back under every warning threshold.
    private mutating func usageLimitChanged(_ info: ClaudeCodeJSON) {
        let window = info["rateLimitType"].string
        let resetsAt = info["resetsAt"].double.map(Date.init(timeIntervalSince1970:))
        let key: String
        let text: String
        if info["isUsingOverage"].bool {
            let creditsResetAt = info["overageResetsAt"].double.map(Date.init(timeIntervalSince1970:))
            switch info["overageStatus"].string {
            case "rejected":
                key = "credits-reached"
                text = AgentChatStrings.usageLimitNotice([AgentChatStrings.usageLimitReached("overage")], resetsAt: creditsResetAt)
            case "allowed_warning":
                key = "credits-warning"
                text = AgentChatStrings.usageLimitNotice([AgentChatStrings.usageLimitNearlyReached("overage")], resetsAt: creditsResetAt)
            default:
                // An overage window's reset would read as the plan window's.
                let planWindow = window == "overage" ? nil : window
                key = "credits-\(planWindow ?? "")"
                text = AgentChatStrings.usageLimitNotice([AgentChatStrings.usageLimitReached(planWindow), AgentChatStrings.usingUsageCredits],
                    resetsAt: planWindow == nil ? nil : resetsAt)
            }
        } else {
            switch info["status"].string {
            case "rejected":
                key = "reached-\(window ?? "")"
                text = AgentChatStrings.usageLimitNotice([AgentChatStrings.usageLimitReached(window)], resetsAt: resetsAt)
            case "allowed_warning":
                key = "warning-\(window ?? "")-\(info["surpassedThreshold"].double.map { "\($0)" } ?? "")"
                // Rounded to basis points first, as the CLI does, so 0.29 reads 29% rather than 28%.
                let used = info["utilization"].double.map { Int(min(max(($0 * 10_000).rounded() / 100, 0), 100).rounded(.down)) }
                text = AgentChatStrings.usageLimitNotice([used.map { AgentChatStrings.usageLimitUsed(window, percent: $0) }
                    ?? AgentChatStrings.usageLimitNearlyReached(window)], resetsAt: resetsAt)
            case "allowed":
                shownUsageLimits.removeAll()
                return
            default:
                return
            }
        }
        if shownUsageLimits.insert(key).inserted { append(.notice(text: text, level: .info)) }
    }

    private func backgroundKind(toolId: String?) -> AgentBackgroundTask.Kind {
        for item in items {
            if case let .toolCall(tool) = item.kind, tool.toolUseId == toolId {
                return tool.name == "Monitor" ? .monitor : tool.name == "Bash" ? .shell : .task
            }
        }
        return .task
    }

    private mutating func settlePendingTools(endingSession: Bool = false) {
        if endingSession {
            backgroundTasks = []
            backgroundToolIds = [:]
            foregroundTaskIds = []
            foregroundTasks = [:]
        }
        pendingPermissions.removeAll()
        permissionTools.removeAll()
        for index in items.indices {
            switch items[index].kind {
            case var .shellCommand(command) where endingSession && command.status == .running:
                command.status = .stopped
                items[index].kind = .shellCommand(command)
            case var .toolCall(tool) where tool.status == .running && (endingSession || tool.background != .running):
                tool.canBackground = false
                tool.status = .failed
                if tool.background == .running { tool.background = .finished }
                items[index].kind = .toolCall(tool)
            case var .permissionRequest(request) where request.status == .pending:
                request.status = .denied
                items[index].kind = .permissionRequest(request)
            default: break
            }
        }
    }

    private mutating func append(_ kind: AgentChatItem.Kind) { items.append(.init(id: UUID().uuidString, kind: kind)) }

    private mutating func upsert(id: String, kind: AgentChatItem.Kind) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].kind = kind }
        else { items.append(.init(id: id, kind: kind)) }
    }
}
