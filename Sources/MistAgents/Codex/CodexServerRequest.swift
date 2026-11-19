import Foundation

struct CodexServerRequest: Sendable {
    let id: CodexJSON
    let method: String
    let params: CodexJSON
    var key: String { id.json() }

    init?(_ message: CodexJSON) {
        guard let method = message["method"].string, message["id"] != .null else { return nil }
        id = message["id"]; self.method = method; params = message["params"]
    }

    func permission(items: [AgentChatItem], allowedServers: Set<String>?) -> AgentChatItem.PermissionRequest? {
        if method == "item/commandExecution/requestApproval" {
            guard params["command"].string != nil else { return nil }
            let actions = params["commandActions"].array
            if !actions.isEmpty, actions.allSatisfy({ ["read", "search", "listFiles"].contains($0["type"].string ?? "") }),
               Self.isSimpleReadCommand(params["command"].string ?? "") {
                let input = CodexJSON.object(["file_path": .string(actions.compactMap { $0["path"].string }.joined(separator: "\n")),
                    "command": params["command"]])
                return .init(requestId: key, toolName: "Read", summary: params["command"].string ?? "", input: input)
            }
            let input = CodexJSON.object(["command": params["command"], "cwd": params["cwd"]])
            return .init(requestId: key, toolName: "Bash",
                summary: ClaudeCodeProtocol.inputSummary(tool: "Bash", input: input), input: input)
        }
        if method == "item/fileChange/requestApproval" {
            guard let itemId = params["itemId"].string else { return nil }
            let changes = items.compactMap { item -> AgentChatItem.ToolCall? in
                guard case let .toolCall(tool) = item.kind,
                      tool.toolUseId.hasPrefix(itemId + ":file:") else { return nil }
                return tool
            }
            guard let first = changes.first else { return nil }
            let input = CodexJSON.object(["file_path": .string(changes.map(\.inputSummary).joined(separator: "\n")),
                "changes": .array(changes.map { .string($0.inputSummary) })])
            return .init(requestId: key, toolName: first.name, summary: changes.map(\.inputSummary).joined(separator: "\n"), input: input)
        }
        if method == "item/tool/requestUserInput" {
            let questions = params["questions"].array.map { value -> CodexJSON in
                .object(["header": value["header"], "question": value["question"], "options": value["options"], "multiSelect": .bool(false)])
            }
            let input = CodexJSON.object(["questions": .array(questions)])
            return .init(requestId: key, toolName: "AskUserQuestion",
                summary: ClaudeCodeProtocol.inputSummary(tool: "AskUserQuestion", input: input), input: input, requiresUserInteraction: true)
        }
        guard method == "mcpServer/elicitation/request", params["_meta"]["codex_approval_kind"].string == "mcp_tool_call",
              let server = params["serverName"].string, allowedServers?.contains(server) ?? true else { return nil }
        // 0.164.0 provides arguments in _meta, but the tool name only in the prior mcpToolCall item.
        let input = params["_meta"]["tool_params"]
        let message = params["message"].string ?? ""
        let marker = "run tool \""
        let reportedTool = message.range(of: marker).flatMap { message[$0.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init) }
        let expectedName = reportedTool.map { "mcp__" + server + "__" + $0 }
        let name = items.reversed().compactMap { item -> String? in
            guard case let .toolCall(tool) = item.kind, tool.status == .running,
                  tool.name.hasPrefix("mcp__" + server + "__"), tool.inputJSON == input.json(),
                  expectedName == nil || tool.name == expectedName else { return nil }
            return tool.name
        }.first
        guard let name else { return nil } // Fail closed rather than approve an unidentified tool.
        return .init(requestId: key, toolName: name, summary: ClaudeCodeProtocol.inputSummary(tool: name, input: input), input: input)
    }

    func reply(_ response: AgentPermissionResponse) -> CodexJSON {
        if method == "item/tool/requestUserInput" {
            let input: CodexJSON
            if case let .allowWithInput(value) = response { input = value } else { input = .null }
            var answers: [String: CodexJSON] = [:]
            for question in params["questions"].array {
                guard let id = question["id"].string else { continue }
                let text = input["answers"][question["question"].string ?? ""].string
                answers[id] = .object(["answers": .array(text.map { [.string($0)] } ?? [])])
            }
            return .object(["answers": .object(answers)])
        }
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            return .object(["decision": .string(response.allows ? "accept" : "decline")])
        }
        return .object(["action": .string(response.allows ? "accept" : "decline"), "content": .null, "_meta": .null])
    }

    var hasKnownReply: Bool {
        ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "mcpServer/elicitation/request"].contains(method)
    }

    /// commandActions describes presentation, not shell safety. Only skip the
    /// card for a single known reader with no redirection, expansion, pipeline,
    /// or command-executing option. Everything else remains a Bash approval.
    static func isSimpleReadCommand(_ command: String) -> Bool {
        func tokens(_ text: String) -> [String]? {
            var result: [String] = [], token = "", quote: Character?, escaped = false, started = false
            for char in text {
                if escaped { token.append(char); escaped = false; started = true; continue }
                if char == "\\", quote != "'" { escaped = true; started = true; continue }
                if let active = quote {
                    if char == active { quote = nil } else { token.append(char) }
                    started = true
                } else if char == "'" || char == "\"" { quote = char; started = true }
                else if char.isWhitespace {
                    if started { result.append(token); token = ""; started = false }
                } else { token.append(char); started = true }
            }
            guard quote == nil, !escaped else { return nil }
            if started { result.append(token) }
            return result
        }
        guard var words = tokens(command), !words.isEmpty else { return false }
        var script = command
        if ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(words[0]) {
            guard words.count == 3, ["-c", "-lc"].contains(words[1]) else { return false }
            script = words[2]
            guard let inner = tokens(script) else { return false }
            words = inner
        }
        guard !script.contains(where: { ";|&<>$`\n\r".contains($0) }), let executable = words.first else { return false }
        let readers = ["cat", "head", "tail", "ls", "pwd", "grep", "rg"]
        guard readers.contains(executable) || readers.contains(where: { executable == "/bin/" + $0 || executable == "/usr/bin/" + $0 || executable == "/opt/homebrew/bin/" + $0 }) else { return false }
        return !words.dropFirst().contains { $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") }
    }
}
