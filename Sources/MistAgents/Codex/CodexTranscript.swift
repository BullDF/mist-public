import Foundation

struct CodexTranscript {
    var clock: () -> Date = Date.init
    private(set) var items: [AgentChatItem] = []
    private(set) var status: AgentConversationStatus = .starting
    private var startedAt: Date?
    var turnStartedAt: Date? { startedAt }
    private(set) var outputTokens: Int?
    private var lastOutputTokens = 0
    private var outputBaseline = 0
    private var pendingPermissions = Set<String>()
    private var completedTurns = Set<String>()
    private var settledMessages = Set<String>()
    private var deniedTools = Set<String>()
    private var backgroundToolIds: [String: String] = [:]
    private var backgroundEnds: [String: (summary: String, status: AgentChatItem.TaskNotificationStatus)] = [:]

    init(restoring items: [AgentChatItem] = []) { self.items = items }

    mutating func info(_ message: String) { append(.notice(text: message, level: .info)) }

    mutating func ready() { status = .idle }

    mutating func assistantDelta(id: String, text: String) {
        guard !text.isEmpty, !settledMessages.contains(id) else { return }
        let old = items.first { $0.id == id }.flatMap { item -> String? in
            if case let .assistantText(text, _) = item.kind { return text }
            return nil
        } ?? ""
        upsert(id: id, kind: .assistantText(text: old + text, isStreaming: true))
    }

    mutating func endAssistant(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case let .assistantText(text, _) = items[index].kind else { return }
        items[index].kind = .assistantText(text: text, isStreaming: false)
    }

    mutating func updateTool(_ tool: AgentChatItem.ToolCall, backgroundTaskId: String? = nil) {
        var tool = tool
        if let backgroundTaskId {
            backgroundToolIds[backgroundTaskId] = tool.toolUseId
            tool.background = .running
            tool.status = .running
            if let end = backgroundEnds[backgroundTaskId] { finishBackground(&tool, end: end) }
        }
        upsert(id: tool.toolUseId, kind: .toolCall(tool))
    }

    mutating func finishTurn(stopped: Bool, duration: Int? = nil, output: Int? = nil, error: String? = nil) {
        settle()
        let elapsed = startedAt.map { max(0, Int(clock().timeIntervalSince($0) * 1000)) } ?? 0
        append(.turnEnd(durationMilliseconds: duration ?? elapsed, finishedAt: clock(), stopped: stopped))
        if let error { append(.notice(text: error, level: .error)) }
        if let output { outputTokens = output }
        startedAt = nil
        status = .idle
    }

    mutating func endSession() {
        settle(includingBackground: true)
        status = .ended
    }

    mutating func backgroundTaskEnded(taskId: String, summary: String, status: AgentChatItem.TaskNotificationStatus) {
        backgroundEnds[taskId] = (summary, status)
        if let id = backgroundToolIds[taskId], let index = items.firstIndex(where: { $0.id == id }),
           case var .toolCall(tool) = items[index].kind {
            finishBackground(&tool, end: (summary, status))
            items[index].kind = .toolCall(tool)
        }
        upsert(id: "task-notification:" + taskId, kind: .taskNotification(summary: summary, status: status))
    }

    private func finishBackground(_ tool: inout AgentChatItem.ToolCall, end: (summary: String, status: AgentChatItem.TaskNotificationStatus)) {
        tool.background = .finished
        tool.status = end.status == .completed ? .succeeded : .failed
        tool.output = end.summary
    }

    mutating func queuedMessageTaken(_ message: AgentQueuedMessage) {
        guard message.sender?.kind != .task else { return }
        append(message.sender.map { .peerMessage(name: $0.label, body: message.text) } ?? .userMessage(text: message.text, images: message.attachments.images))
        items[items.count - 1].mentions = message.mentions
        items[items.count - 1].files = message.attachments.files
    }

    mutating func userSent(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention] = [], sender: AgentMessageSender? = nil) {
        if sender?.kind != .task {
            append(sender.map { .peerMessage(name: $0.label, body: text) } ?? .userMessage(text: text, images: attachments.images))
            items[items.count - 1].mentions = mentions
            items[items.count - 1].files = attachments.files
        }
        startedAt = clock()
        outputTokens = nil
        status = .running
    }

    mutating func permission(_ request: AgentChatItem.PermissionRequest) {
        pendingPermissions.insert(request.requestId)
        upsert(id: "permission:" + request.requestId, kind: .permissionRequest(request))
        status = .awaitingPermission
    }

    mutating func permissionDecided(requestId: String, response: AgentPermissionResponse) {
        guard pendingPermissions.remove(requestId) != nil else { return }
        for index in items.indices {
            if case var .permissionRequest(request) = items[index].kind, request.requestId == requestId {
                if !response.allows, let tool = items.compactMap({ item -> AgentChatItem.ToolCall? in
                    if case let .toolCall(tool) = item.kind, tool.status == .running, tool.name == request.toolName,
                       tool.inputJSON == request.input.json() { return tool }
                    return nil
                }).last { deniedTools.insert(tool.toolUseId) }
                request.status = response.allows ? .allowed : .denied
                request.resolution = response
                items[index].kind = .permissionRequest(request)
            }
        }
        status = pendingPermissions.isEmpty ? .running : .awaitingPermission
    }

    /// Nested MCP calls have their own items in 0.164.0; exec/functionCallOutput wrappers stay hidden.
    mutating func apply(_ message: CodexJSON) {
        let params = message["params"]
        switch message["method"].string {
        case "turn/started":
            if startedAt == nil { startedAt = clock() }
            outputBaseline = lastOutputTokens
            outputTokens = nil
            status = pendingPermissions.isEmpty ? .running : .awaitingPermission
        case "thread/tokenUsage/updated":
            guard params["tokenUsage"]["total"]["outputTokens"] != .null else { return }
            lastOutputTokens = params["tokenUsage"]["total"]["outputTokens"].integer
            if status == .running || status == .awaitingPermission {
                outputTokens = max(0, lastOutputTokens - outputBaseline)
            }
        case "item/agentMessage/delta":
            guard let id = params["itemId"].string else { return }
            assistantDelta(id: id, text: params["delta"].string ?? "")
        case "item/started", "item/completed":
            let item = params["item"]
            guard let id = item["id"].string else { return }
            let completed = message["method"].string == "item/completed"
            switch item["type"].string {
            case "agentMessage":
                guard !settledMessages.contains(id) else { return }
                if completed { settledMessages.insert(id) }
                upsert(id: id, kind: .assistantText(text: item["text"].string ?? "", isStreaming: !completed))
            case "mcpToolCall":
                let name = "mcp__\(item["server"].string ?? "")__\(item["tool"].string ?? "")"
                let input = item["arguments"]
                let failed = item["status"].string == "failed" || item["result"]["isError"].bool
                var tool = AgentChatItem.ToolCall(toolUseId: id, name: name,
                    inputSummary: ClaudeCodeProtocol.inputSummary(tool: name, input: input), inputJSON: input.json(),
                    status: failed ? .failed : completed ? .succeeded : .running)
                tool.output = item["result"]["content"].array.compactMap { block in
                    block["type"].string == "image" ? CodexStrings.image : block["text"].string
                }.joined(separator: "\n")
                if let error = item["error"]["message"].string { tool.output += (tool.output.isEmpty ? "" : "\n") + error }
                tool.structuredResult = item["result"]["structuredContent"]
                tool.permissionDenied = deniedTools.contains(id)
                if !failed, ["mcp__mistbrowser__run_in_background", "mcp__mistbrowser__monitor"].contains(name) {
                    let taskId = item["result"]["content"].array.compactMap { block -> String? in
                        guard let text = block["text"].string, let data = text.data(using: .utf8),
                              let result = try? JSONDecoder().decode(CodexJSON.self, from: data) else { return nil }
                        return result["taskId"].string
                    }.first ?? backgroundToolIds.first(where: { $0.value == id })?.key
                    updateTool(tool, backgroundTaskId: taskId)
                } else { updateTool(tool) }
            case "commandExecution":
                let input = CodexJSON.object(["command": item["command"], "cwd": item["cwd"]])
                let failed = ["failed", "declined"].contains(item["status"].string ?? "") ||
                    (completed && item["exitCode"] != .null && item["exitCode"].integer != 0)
                var tool = AgentChatItem.ToolCall(toolUseId: id, name: "Bash",
                    inputSummary: ClaudeCodeProtocol.inputSummary(tool: "Bash", input: input), inputJSON: input.json(),
                    status: failed ? .failed : completed ? .succeeded : .running)
                tool.output = item["aggregatedOutput"].string ?? items.first(where: { $0.id == id }).flatMap {
                    if case let .toolCall(previous) = $0.kind { return previous.output }; return nil
                } ?? ""
                // Kept out of the input, which must equal the approval request's; they let a skill read show as a skill.
                if !item["commandActions"].array.isEmpty { tool.structuredResult = .object(["commandActions": item["commandActions"]]) }
                tool.permissionDenied = item["status"].string == "declined" || deniedTools.contains(id)
                upsert(id: id, kind: .toolCall(tool))
            case "webSearch", "imageView", "sleep", "imageGeneration":
                let name: String
                let input: CodexJSON
                var output = ""
                var result = CodexJSON.null
                var failed = false
                switch item["type"].string {
                case "webSearch":
                    let action = item["action"]
                    if ["openPage", "findInPage"].contains(action["type"].string ?? "") {
                        name = "WebFetch"
                        input = .object(["url": .string(action["url"].string ?? "")])
                    } else {
                        name = "WebSearch"
                        input = .object(["query": .string(action["query"].string ?? item["query"].string ?? "")])
                    }
                    output = item["results"].array.compactMap { $0["title"].string ?? $0["url"].string ?? $0["domain"].string }.joined(separator: "\n")
                case "imageView":
                    name = "Read"
                    input = .object(["file_path": item["path"]])
                    // Claude's image read reports the same type, so both rows summarize it as an image.
                    result = .object(["type": .string("image")])
                case "sleep":
                    name = "Sleep"
                    input = .object(["duration_ms": item["durationMs"]])
                default:
                    name = "ImageGeneration"
                    input = .object(["prompt": .string(item["revisedPrompt"].string ?? "")])
                    failed = item["failure"] != .null
                    output = failed ? (item["failure"]["message"].string ?? item["failure"].json()) : (item["savedPath"].string ?? "")
                    // The base64 result stays out of every persisted transcript field.
                }
                var tool = AgentChatItem.ToolCall(toolUseId: id, name: name,
                    inputSummary: ClaudeCodeProtocol.inputSummary(tool: name, input: input), inputJSON: input.json(),
                    status: failed ? .failed : completed ? .succeeded : .running)
                tool.output = output
                tool.structuredResult = result
                upsert(id: id, kind: .toolCall(tool))
            case "fileChange":
                for (index, change) in item["changes"].array.enumerated() {
                    let fileID = id + ":file:" + String(index)
                    let added = change["kind"]["type"].string == "add"
                    let name = added ? "Write" : "Edit"
                    let input = CodexJSON.object(["file_path": change["path"], "content": change["diff"]])
                    var tool = AgentChatItem.ToolCall(toolUseId: fileID, name: name,
                        inputSummary: change["path"].string ?? "", inputJSON: input.json(),
                        status: ["failed", "declined"].contains(item["status"].string ?? "") ? .failed : completed ? .succeeded : .running)
                    tool.output = change["diff"].string ?? ""
                    tool.structuredResult = added ? .object(["content": change["diff"]])
                        : .object(["structuredPatch": .array(Self.patches(tool.output))])
                    tool.permissionDenied = item["status"].string == "declined"
                    upsert(id: fileID, kind: .toolCall(tool))
                }
            default: break
            }
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"].string, let delta = params["delta"].string,
                  let index = items.firstIndex(where: { $0.id == id }), case var .toolCall(tool) = items[index].kind else { return }
            tool.output += delta
            items[index].kind = .toolCall(tool)
        case "item/mcpToolCall/progress":
            guard let id = params["itemId"].string, let progress = params["message"].string,
                  let index = items.firstIndex(where: { $0.id == id }), case var .toolCall(tool) = items[index].kind else { return }
            tool.output = progress
            items[index].kind = .toolCall(tool)
        case "turn/completed":
            let turn = params["turn"]
            guard let id = turn["id"].string, completedTurns.insert(id).inserted else { return }
            finishTurn(stopped: turn["status"].string == "interrupted",
                duration: turn["durationMs"] == .null ? nil : turn["durationMs"].integer,
                error: turn["status"].string == "failed" ? turn["error"]["message"].string ?? CodexStrings.turnFailed : nil)
        default: break
        }
    }

    mutating func processExited(expected: Bool, stderr: String) {
        if expected { endSession() }
        else { fail(CodexStrings.exited + (stderr.isEmpty ? "" : "\n" + stderr)) }
    }

    mutating func fail(_ message: String) {
        settle(includingBackground: true)
        append(.notice(text: AgentChatStrings.failureNotice(message), level: .error))
        status = .failed(message)
    }

    private mutating func settle(includingBackground: Bool = false) {
        pendingPermissions.removeAll()
        for index in items.indices {
            switch items[index].kind {
            case let .assistantText(text, _): items[index].kind = .assistantText(text: text, isStreaming: false)
            case var .toolCall(tool) where tool.status == .running:
                if tool.background == .running {
                    guard includingBackground else { continue }
                    tool.background = .finished
                }
                tool.status = .failed; items[index].kind = .toolCall(tool)
            case var .permissionRequest(request) where request.status == .pending:
                request.status = .denied; items[index].kind = .permissionRequest(request)
            default: break
            }
        }
    }

    private mutating func append(_ kind: AgentChatItem.Kind) { items.append(.init(id: UUID().uuidString, kind: kind)) }

    /// Translate unified hunks into the shared transcript's numbered diff rows.
    private static func patches(_ diff: String) -> [CodexJSON] {
        var patches: [CodexJSON] = [], lines: [CodexJSON] = []
        var old = 1, new = 1, inHunk = false
        func flush() {
            if inHunk { patches.append(.object(["oldStart": .number(Double(old)), "newStart": .number(Double(new)), "lines": .array(lines)])) }
            lines = []
        }
        for line in diff.components(separatedBy: .newlines) {
            if line.hasPrefix("@@ ") {
                flush()
                let fields = line.split(separator: " ")
                old = fields.count > 1 ? fields[1].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 1 : 1
                new = fields.count > 2 ? fields[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } ?? 1 : 1
                inHunk = true
            } else if inHunk, ["+", "-", " "].contains(line.first.map(String.init) ?? "") { lines.append(.string(line)) }
        }
        flush()
        return patches
    }
    private mutating func upsert(id: String, kind: AgentChatItem.Kind) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].kind = kind }
        else { items.append(.init(id: id, kind: kind)) }
    }
}
