import Foundation

enum DrifterBackgroundTools {
    static func nativeName(_ name: String) -> String {
        switch name {
        case "mcp__mistbrowser__run_in_background": "Bash"
        case "mcp__mistbrowser__monitor": "Monitor"
        case "mcp__mistbrowser__stop_task": "TaskStop"
        default: name
        }
    }
}

struct ClaudeCodeModelInfo: Codable, Equatable, Sendable {
    let resolvedModel: String
    let displayName: String
}

// A value representation keeps arbitrary tool inputs intact across queues.
enum ClaudeCodeJSON: Codable, Equatable, Sendable {
    case object([String: ClaudeCodeJSON]), array([ClaudeCodeJSON]), string(String)
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Self {
        guard case let .object(object) = self else { return .null }
        return object[key] ?? .null
    }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var array: [Self] { if case let .array(value) = self { return value }; return [] }
    var bool: Bool { if case let .bool(value) = self { return value }; return false }
    var integer: Int {
        if case let .number(value) = self, value >= Double(Int.min), value < Double(Int.max) { return Int(value) }
        return 0
    }
    var double: Double? { if case let .number(value) = self { return value }; return nil }

    func json(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
}

enum ClaudeCodeEvent: Equatable, Sendable {
    case system(ClaudeCodeJSON)
    case stream(ClaudeCodeJSON)
    case assistant(ClaudeCodeJSON)
    case user(ClaudeCodeJSON)
    case permission(ClaudeCodeJSON)
    case permissionWithdrawn(requestId: String)
    case unsupportedControl(requestId: String)
    case controlResponse(ClaudeCodeJSON)
    case commandLifecycle(ClaudeCodeJSON)
    case rateLimit(ClaudeCodeJSON)
    case result(ClaudeCodeJSON)
}

struct ClaudeCodeConnector: Codable, Equatable, Sendable {
    let url: String
    let id: String
}

enum ClaudeCodeProtocol {
    static func mcpStatus(requestId: String) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("mcp_status")]))
    }

    static func mcpReconnect(_ name: String, requestId: String) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("mcp_reconnect"), "serverName": .string(name)]))
    }

    static func mcpToggle(_ name: String, enabled: Bool, requestId: String) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("mcp_toggle"), "serverName": .string(name), "enabled": .bool(enabled)]))
    }

    static func connectors(from reply: ClaudeCodeJSON) -> [String: ClaudeCodeConnector] {
        var result: [String: ClaudeCodeConnector] = [:]
        for entry in reply["mcpServers"].array {
            guard entry["config"]["type"].string == "claudeai-proxy",
                  let name = entry["name"].string, let url = entry["config"]["url"].string,
                  let id = entry["config"]["id"].string else { continue }
            result[name] = .init(url: url, id: id)
        }
        return result
    }
    static func control(requestId: String, request: ClaudeCodeJSON) -> String {
        ClaudeCodeJSON.object(["type": .string("control_request"), "request_id": .string(requestId), "request": request]).json()
    }
    static func remoteControl(enabled: Bool, requestId: String) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("remote_control"), "enabled": .bool(enabled)]))
    }
    static func initialize(requestId: String, perTaskStopAffordance: Bool = false) -> String {
        var request: [String: ClaudeCodeJSON] = ["subtype": .string("initialize")]
        if perTaskStopAffordance { request["perTaskStopAffordance"] = .bool(true) }
        return control(requestId: requestId, request: .object(request))
    }



    static func stopTask(_ id: String, requestId: String = UUID().uuidString) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("stop_task"), "task_id": .string(id)]))
    }

    static func backgroundTask(toolUseId: String, requestId: String = UUID().uuidString) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("background_tasks"), "tool_use_id": .string(toolUseId)]))
    }

    /// Answered locally (no API call), even before the first turn.
    static func contextUsage(requestId: String) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("get_context_usage")]))
    }

    static func generateTitle(_ description: String, requestId: String) -> String {
        control(requestId: requestId, request: .object([
            "subtype": .string("generate_session_title"), "description": .string(description), "persist": .bool(true)
        ]))
    }

    static func renameSession(_ title: String, requestId: String) -> String {
        control(requestId: requestId, request: .object([
            "subtype": .string("rename_session"), "title": .string(title), "source": .string("host")
        ]))
    }

    /// Unrelated stdout events and model entries are ignored; a matching invalid reply fails the query.
    static func modelCatalog(from line: Data, requestId: String) throws -> [String: ClaudeCodeModelInfo]? {
        guard let reply = try initializeReply(from: line, requestId: requestId) else { return nil }
        return try models(from: reply)
    }

    static func initializeReply(from line: Data, requestId: String) throws -> ClaudeCodeJSON? {
        guard let response = try controlResponse(from: line, requestId: requestId) else { return nil }
        guard response["subtype"].string == "success", case .object = response["response"] else {
            throw InitializationError.invalidModels
        }
        return response["response"]
    }

    static func controlResponse(from line: Data, requestId: String) throws -> ClaudeCodeJSON? {
        let value = try JSONDecoder().decode(ClaudeCodeJSON.self, from: line)
        guard value["type"].string == "control_response",
              value["response"]["request_id"].string == requestId else { return nil }
        return value["response"]
    }

    static func models(from reply: ClaudeCodeJSON) throws -> [String: ClaudeCodeModelInfo] {
        guard case let .array(entries) = reply["models"] else { throw InitializationError.invalidModels }
        var models: [String: ClaudeCodeModelInfo] = [:]
        for entry in entries {
            guard let alias = entry["value"].string, ClaudeCodeModel(rawValue: alias) != nil else { continue }
            guard let resolvedModel = entry["resolvedModel"].string, !resolvedModel.isEmpty,
                  let displayName = entry["displayName"].string,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InitializationError.invalidModels
            }
            models[alias] = ClaudeCodeModelInfo(resolvedModel: resolvedModel, displayName: displayName)
        }
        guard !models.isEmpty else { throw InitializationError.invalidModels }
        return models
    }

    private enum InitializationError: Error { case invalidModels }

    static func arguments(sessionId: String, resume: Bool = false, launchArguments: [String]) -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
         "--include-partial-messages", "--replay-user-messages", "--verbose", "--permission-prompt-tool", "stdio", "--allow-dangerously-skip-permissions",
         resume ? "--resume" : "--session-id", sessionId] + launchArguments
    }

    private static func imageBlocks(_ attachments: [AgentImageAttachment]) -> [ClaudeCodeJSON] {
        attachments.map {
            .object(["type": .string("image"), "source": .object([
                "type": .string("base64"), "media_type": .string($0.mediaType),
                "data": .string($0.data.base64EncodedString()),
            ])])
        }
    }

    static func user(text: String, attachments: [AgentAttachment], uuid: String? = nil) -> String {
        var blocks = imageBlocks(attachments.images)
        blocks.append(.object(["type": .string("text"), "text": .string(attachments.agentText(text))]))
        var value: [String: ClaudeCodeJSON] = ["type": .string("user"), "message": .object([
            "role": .string("user"), "content": .array(blocks),
        ])]
        if let uuid { value["uuid"] = .string(uuid) }
        return ClaudeCodeJSON.object(value).json()
    }



    static func permission(requestId: String, allow: Bool, input: ClaudeCodeJSON, denyMessage: String? = nil) -> String {
        let answer: ClaudeCodeJSON = allow
            ? .object(["behavior": .string("allow"), "updatedInput": input])
            : .object(["behavior": .string("deny"), "message": .string(denyMessage ?? "The user denied this action.")])
        return ClaudeCodeJSON.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string(requestId), "response": answer,
        ])]).json()
    }

    static func interrupt(requestId: String = UUID().uuidString, sendNow: Bool? = nil, messageUUID: String? = nil, cancelQueued: Bool? = nil) -> String {
        var request: [String: ClaudeCodeJSON] = ["subtype": .string("interrupt")]
        if let sendNow { request["send_now"] = .bool(sendNow) }
        if let messageUUID { request["message_uuid"] = .string(messageUUID) }
        if let cancelQueued { request["cancel_queued"] = .bool(cancelQueued) }
        return control(requestId: requestId, request: .object(request))
    }

    static func cancelAsyncMessage(_ uuid: String, requestId: String = UUID().uuidString) -> String {
        control(requestId: requestId, request: .object(["subtype": .string("cancel_async_message"), "message_uuid": .string(uuid)]))
    }

    static func unsupported(requestId: String) -> String {
        ClaudeCodeJSON.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("error"), "request_id": .string(requestId), "error": .string("Unsupported by Mist"),
        ])]).json()
    }

    // Logging belongs to the process adapter; nil means malformed or unknown input.
    static func decode(_ line: Data) -> ClaudeCodeEvent? {
        guard let value = try? JSONDecoder().decode(ClaudeCodeJSON.self, from: line),
              let type = value["type"].string else { return nil }
        // Control requests must always be answered.
        if type == "control_request" {
            guard let id = value["request_id"].string else { return nil }
            if value["request"]["subtype"].string == "can_use_tool" { return .permission(value) }
            return .unsupportedControl(requestId: id)
        }
        if type == "control_cancel_request" {
            guard let id = value["request_id"].string else { return nil }
            return .permissionWithdrawn(requestId: id)
        }
        if type == "user", value["isReplay"].bool { return .user(value) }
        switch type {
        case "system": return .system(value)
        case "stream_event": return .stream(value)
        case "assistant": return .assistant(value)
        case "user": return .user(value)
        case "control_response": return .controlResponse(value)
        case "command_lifecycle": return .commandLifecycle(value)
        case "rate_limit_event": return .rateLimit(value)
        case "result": return .result(value)
        default: return nil
        }
    }

    static func inputSummary(tool: String, input: ClaudeCodeJSON) -> String {
        let tool = DrifterBackgroundTools.nativeName(tool)
        if tool == "AskUserQuestion" {
            let questions = input["questions"].array
            return (questions.first?["question"].string ?? "") + (questions.count > 1 ? " +\(questions.count - 1)" : "")
        }
        if tool == "ExitPlanMode" {
            let line = (input["plan"].string ?? "").components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return String(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(200))
        }
        if tool == "Sleep" { return AgentChatStrings.elapsed((Double(input["duration_ms"].integer) / 1000).rounded(.up)) }
        let key: String?
        switch tool {
        case "Bash": key = "command"
        case "ImageGeneration": key = "prompt"
        case "Monitor": key = input["description"].string?.isEmpty == false ? "description" : "command"
        case "Read", "Edit", "Write", "NotebookEdit": key = "file_path"
        case "WebFetch": key = "url"
        case "WebSearch": key = "query"
        case "Grep", "Glob": key = "pattern"
        default: key = nil
        }
        let text = key.flatMap { input[$0].string } ?? (tool == "Monitor" ? "" : input.json())
        return String(text.components(separatedBy: .newlines).joined(separator: " ").prefix(200))
    }
}
