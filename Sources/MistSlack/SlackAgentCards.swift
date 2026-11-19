import Foundation

/// Block Kit construction stays independent of the connection and conversation lifecycle.
enum SlackAgentCards {
    struct Value: Codable {
        var chat: UUID
        var request: String
        var q: Int?
        var o: Int?
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func title(_ request: AgentChatItem.PermissionRequest) -> String {
        if let question = request.questions.first { return question.header }
        return AgentChatStrings.browserPermission(request)?.title
            ?? String(format: AgentChatStrings.permission, AgentChatToolGroupKind.displayName(request.toolName))
    }

    static func context(_ text: String) -> [String: Any] {
        ["type": "context", "elements": [["type": "mrkdwn", "text": truncate(escape(text), to: 3000)]]]
    }

    static func blocks(_ request: AgentChatItem.PermissionRequest, chat: UUID, outcome: String? = nil) -> [[String: Any]] {
        func section(_ text: String) -> [String: Any] {
            ["type": "section", "text": ["type": "mrkdwn", "text": truncate(text, to: 3000)]]
        }
        func value(q: Int? = nil, o: Int? = nil) -> String {
            let data = try! JSONEncoder().encode(Value(chat: chat, request: request.requestId, q: q, o: o))
            return String(decoding: data, as: UTF8.self)
        }
        func button(_ label: String, id: String, style: String? = nil, q: Int? = nil, o: Int? = nil) -> [String: Any] {
            var result: [String: Any] = ["type": "button", "action_id": id, "text": ["type": "plain_text", "text": truncate(label, to: 75)], "value": value(q: q, o: o)]
            if let style { result["style"] = style }
            return result
        }
        var blocks: [[String: Any]] = []
        let questions = request.questions
        if questions.isEmpty {
            let browser = AgentChatStrings.browserPermission(request)
            let detail = browser?.detail ?? (browser == nil ? "`\(request.toolName)(\(request.summary))`" : nil)
            let lines = ["*\(escape(title(request)))*", browser?.message.map { SlackMrkdwn.convert($0) }, detail.map { escape($0) }]
            blocks.append(section(lines.compactMap { $0 }.joined(separator: "\n")))
            blocks.append(["type": "actions", "block_id": "drifter.permission", "elements": [
                button(AgentChatStrings.allow, id: "drifter.allow", style: "primary"),
                button(AgentChatStrings.deny, id: "drifter.deny", style: "danger")]])
        } else {
            for (index, question) in questions.enumerated() {
                blocks.append(section("*\(escape(question.header))*\n\(escape(question.question))"))
                if questions.count == 1 && !question.multiSelect {
                    blocks.append(["type": "actions", "block_id": "q0", "elements": question.options.enumerated().map {
                        button($0.element.label, id: "drifter.option.\($0.offset)", q: 0, o: $0.offset)
                    }])
                } else {
                    let options: [[String: Any]] = question.options.enumerated().map {
                        var option: [String: Any] = ["text": ["type": "plain_text", "text": truncate($0.element.label, to: 75)], "value": String($0.offset)]
                        if !$0.element.description.isEmpty {
                            option["description"] = ["type": "plain_text", "text": truncate($0.element.description, to: 75)]
                        }
                        return option
                    }
                    blocks.append(["type": "actions", "block_id": "q\(index)", "elements": [["type": question.multiSelect ? "checkboxes" : "radio_buttons", "action_id": "drifter.select", "options": options]]])
                }
            }
            if questions.count != 1 || questions[0].multiSelect {
                blocks.append(["type": "actions", "elements": [button(SlackAgentStrings.submit, id: "drifter.submit", style: "primary")]])
            }
        }
        if let outcome {
            return blocks.filter { $0["type"] as? String == "section" } + [context(outcome)]
        }
        if !questions.isEmpty { blocks.append(context(SlackAgentStrings.replyWithAnswer)) }
        return blocks
    }

    /// A `hand_off` card: the agent's message and the tab to use, with a Done button until an outcome replaces it.
    static func handOffBlocks(_ handOff: AgentHandOff, chat: UUID, outcome: String? = nil) -> [[String: Any]] {
        var text = "*\(escape(AgentChatStrings.handOffTitle))*\n\(escape(handOff.message))"
        if let tab = handOff.tab { text += "\n_" + escape(String(format: AgentChatStrings.handOffTab, tab)) + "_" }
        let section: [String: Any] = ["type": "section", "text": ["type": "mrkdwn", "text": truncate(text, to: 3000)]]
        if let outcome { return [section, context(outcome)] }
        let value = String(decoding: (try? JSONEncoder().encode(Value(chat: chat, request: handOff.id))) ?? Data(), as: UTF8.self)
        return [section, ["type": "actions", "block_id": "drifter.handOff", "elements": [["type": "button", "action_id": "drifter.handOffDone",
            "text": ["type": "plain_text", "text": truncate(AgentChatStrings.handOffDone, to: 75)], "style": "primary", "value": value]]]]
    }

    static func outcome(_ request: AgentChatItem.PermissionRequest) -> String {
        if request.status == .denied { return AgentChatStrings.denied }
        if request.questions.isEmpty { return AgentChatStrings.allowed }
        return AgentChatStrings.answered + ": " + request.questions.compactMap { request.answers[$0.question]?.string }.joined(separator: "; ")
    }
}
