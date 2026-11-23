import Foundation

struct GeminiToolCall {
    let id: String
    let name: String
    let title: String
    let input: CodexJSON
    let paths: [String]
    let hasRawInput: Bool

    init?(_ call: CodexJSON, previous: Self? = nil) {
        guard let id = call["toolCallId"].string, !id.isEmpty else { return nil }
        self.id = id
        let meta = call["_meta"]["gemini-cli"]["mcp"]
        let name = Self.mcpName(meta) ?? previous?.name ?? Self.name(id: id)
        guard let name else { return nil }
        self.name = name
        title = call["title"].string ?? previous?.title ?? name
        let diff = call["content"].array.first { $0["type"].string == "diff" }
        let locations = call["locations"].array.compactMap { $0["path"].string }
        let path = diff?["path"].string ?? locations.first
        paths = locations.isEmpty ? path.map { [$0] } ?? previous?.paths ?? [] : locations
        if case .object = call["rawInput"] {
            hasRawInput = true
            input = call["rawInput"]
        }
        else if let previous, previous.hasRawInput {
            hasRawInput = true
            input = previous.input
        }
        else {
            hasRawInput = false
            switch name {
            case "Bash", "mcp__mistbrowser__run_in_background", "mcp__mistbrowser__monitor":
                input = .object(["command": .string(title)])
            case "Read", "Edit", "Write":
                if let path {
                    var fields: [String: CodexJSON] = ["file_path": .string(path)]
                    // Only a Write's row reads the new text; an edit's would carry the whole file for nothing.
                    if name == "Write", let diff, let changed = diff["newText"].string { fields["content"] = .string(changed) }
                    input = .object(fields)
                } else { input = previous?.input ?? .object(["file_path": .string(title)]) }
            case "Grep", "Glob":
                input = previous?.input ?? .object(["pattern": .string(title)])
            case "WebSearch":
                input = previous?.input ?? .object(["query": .string(title)])
            case "WebFetch":
                input = previous?.input ?? .object(["url": .string(title)])
            default:
                // ACP v1 sends a human-readable title for MCP calls. Preserve it verbatim.
                input = previous?.input ?? .object(["description": .string(title)])
            }
        }
    }

    private static func mcpName(_ metadata: CodexJSON) -> String? {
        if let server = metadata["server_name"].string, let tool = metadata["tool_name"].string,
           !server.isEmpty, !tool.isEmpty { return "mcp__\(server)__\(tool)" }
        return nil
    }

    static func name(id: String) -> String? {
        // Gemini CLI prefixes call IDs with the registered tool name. Its own synthetic IDs
        // use <name>-<time>-<counter> instead, for example on an @file read.
        let raw = id.range(of: "__").map { String(id[..<$0.lowerBound]) }
            ?? id.range(of: #"-[0-9]+-[0-9]+$"#, options: .regularExpression).map { String(id[..<$0.lowerBound]) }
        guard let raw else { return nil }
        if raw.hasPrefix("mcp_mistbrowser_") { return "mcp__mistbrowser__" + raw.dropFirst("mcp_mistbrowser_".count) }
        return GeminiProtocol.builtInNames[raw]
    }

    func item(_ update: CodexJSON, denied: Bool) -> AgentChatItem.ToolCall {
        var item = AgentChatItem.ToolCall(toolUseId: id, name: name, inputSummary: title, inputJSON: input.json())
        switch update["status"].string {
        case "completed": item.status = .succeeded
        case "failed": item.status = .failed
        default: break
        }
        item.permissionDenied = denied
        let content = update["content"].array
        if item.status != .running {
            item.output = content.compactMap { block in
                let value = block["content"]
                return value["type"].string == "image" ? CodexStrings.image : value["text"].string
            }.joined(separator: "\n")
            item.structuredResult = (try? JSONDecoder().decode(CodexJSON.self, from: Data(item.output.utf8))) ?? .null
            if let diff = content.first(where: { $0["type"].string == "diff" }), let changed = diff["newText"].string {
                let original = diff["oldText"].string ?? ""
                if original.isEmpty && name == "Write" {
                    item.structuredResult = .object(["content": .string(changed)])
                } else {
                    item.structuredResult = Self.patch(from: original, to: changed)
                }
            }
        }
        return item
    }

    private static func patch(from original: String, to changed: String) -> CodexJSON {
        let old = original.isEmpty ? [] : original.components(separatedBy: "\n")
        let new = changed.isEmpty ? [] : changed.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [String] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) { lines.append("-" + old[i]); i += 1 }
            else if inserted.contains(j) { lines.append("+" + new[j]); j += 1 }
            else {
                guard i < old.count, j < new.count else { break }
                lines.append(" " + old[i]); i += 1; j += 1
            }
        }
        // Gemini sends both whole files; keep only the changes and their context, as Claude's hunks do.
        let hunks = ClaudeCodeToolSummary.hunks(lines, oldStart: 1, newStart: 1)
        return .object(["type": .string("update"), "structuredPatch": .array((hunks.isEmpty ? [.init(oldStart: 1, newStart: 1, lines: [])] : hunks).map {
            .object(["oldStart": .number(Double($0.oldStart)), "newStart": .number(Double($0.newStart)), "lines": .array($0.lines.map { .string($0) })])
        })])
    }
}

struct GeminiPermission {
    let rpcId: CodexJSON
    let tool: GeminiToolCall
    let options: [CodexJSON]

    var card: AgentChatItem.PermissionRequest {
        let input = tool.name.hasPrefix("mcp__") && !tool.hasRawInput ? .null : tool.input
        return .init(requestId: tool.id, toolName: tool.name, summary: tool.title, input: input)
    }

    func reply(allows: Bool) -> CodexJSON {
        let kind = allows ? "allow_once" : "reject_once"
        guard let option = options.first(where: { $0["kind"].string == kind })?["optionId"].string else {
            return Self.cancelled
        }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])])
    }

    static let cancelled: CodexJSON = .object(["outcome": .object(["outcome": .string("cancelled")])])
}
