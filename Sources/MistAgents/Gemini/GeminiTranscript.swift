import Foundation

struct GeminiTranscript {
    var rows: CodexTranscript
    private var assistantId: String?
    private var tools: [String: GeminiToolCall] = [:]
    private var denied = Set<String>()

    init(restoring items: [AgentChatItem] = []) { rows = .init(restoring: items) }

    mutating func apply(_ update: CodexJSON) -> [String]? {
        switch update["sessionUpdate"].string {
        case "agent_message_chunk":
            guard update["content"]["type"].string == "text", let text = update["content"]["text"].string, !text.isEmpty else { return nil }
            let id = assistantId ?? UUID().uuidString
            assistantId = id
            rows.assistantDelta(id: id, text: text)
            return []
        case "tool_call", "tool_call_update":
            if let assistantId { rows.endAssistant(id: assistantId); self.assistantId = nil }
            return updateTool(update)?.paths
        default:
            // Thought chunks, auto-generated slash commands and replayed history stay out of Mist's transcript.
            return nil
        }
    }

    mutating func updateTool(_ update: CodexJSON) -> GeminiToolCall? {
        guard let id = update["toolCallId"].string, let call = GeminiToolCall(update, previous: tools[id]) else { return nil }
        tools[id] = call
        let tool = call.item(update, denied: denied.contains(id))
        let startsTask = ["mcp__mistbrowser__run_in_background", "mcp__mistbrowser__monitor"].contains(tool.name)
        rows.updateTool(tool, backgroundTaskId: startsTask && tool.status == .succeeded ? tool.structuredResult["taskId"].string : nil)
        return call
    }

    mutating func permissionDecided(_ permission: GeminiPermission, response: AgentPermissionResponse) {
        if !response.allows { denied.insert(permission.tool.id) }
        rows.permissionDecided(requestId: permission.tool.id, response: response)
    }

    mutating func finish(_ result: CodexJSON, stopped: Bool, error: String? = nil) {
        assistantId = nil
        tools.removeAll()
        denied.removeAll()
        let output = result["usage"]["outputTokens"]
        rows.finishTurn(stopped: stopped, output: output == .null ? nil : output.integer, error: error)
    }
}
