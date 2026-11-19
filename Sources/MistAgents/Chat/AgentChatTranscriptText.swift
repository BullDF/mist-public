import Foundation

/// Rendered only on request, independent of transcript layout and AppKit.
enum AgentChatTranscriptText {
    /// A small plain-text preview, independent of transcript rendering.
    static func lastLine(_ items: [AgentChatItem]) -> String? {
        for item in items.reversed() {
            let text: String
            switch item.kind {
            case let .assistantText(value, _), let .userMessage(value, _), let .peerMessage(_, value): text = value
            default: continue
            }
            guard var line = text.components(separatedBy: .newlines).reversed()
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else { continue }
            line = line.replacingOccurrences(of: #"^(?:#+\s*|>\s*|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
            // A link shows its text, as the transcript renders it.
            line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)\s]*\)"#, with: "$1", options: .regularExpression)
            for marker in ["**", "__", "`"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return String(line.prefix(300)) }
        }
        return nil
    }

    /// A turn is Slack's when the last message Johnny sent into the chat came from Slack: turns
    /// woken by anything else (a child's report, a peer, a background task) don't change that.
    static func isSlackTurn(_ items: [AgentChatItem]) -> Bool {
        for item in items.reversed() {
            switch item.kind {
            case .userMessage: return false
            case let .peerMessage(name, _) where name == slackSender: return true
            default: continue
            }
        }
        return false
    }

    /// Whether a turn woken now would post to Slack, counting Johnny's queued messages as sent.
    static func wakePostsToSlack(_ items: [AgentChatItem], queued: [AgentQueuedMessage]) -> Bool {
        for message in queued.reversed() {
            guard let sender = message.sender else { return false }
            if sender.kind == .slack { return true }
        }
        return isSlackTurn(items)
    }

    /// The label of Johnny's Slack messages' sender, which names their peer rows.
    static let slackSender = "Slack"

    static func render(_ items: [AgentChatItem]) -> String {
        items.compactMap { item -> String? in
            switch item.kind {
            case let .userMessage(text, _): return "Johnny: " + text
            case let .peerMessage(name, body): return "Message from @\(name): \(body)"
            case let .assistantText(text, _): return text
            case let .toolCall(tool):
                let suffix = tool.status == .running ? " (running)" : tool.status == .failed ? " (failed)" : ""
                return "• \(AgentChatToolGroupKind.displayName(tool.name)) \(tool.inputSummary)" + suffix
            case let .shellCommand(command):
                return "$ " + command.command + (command.exitCode.flatMap { $0 == 0 ? nil : " (exit \($0))" } ?? "")
            case let .commandOutput(_, text, _): return text
            case let .permissionRequest(request):
                let suffix: String
                if request.status == .denied { suffix = " (denied)" }
                else if request.status == .allowed {
                    suffix = " (answered: " + request.answers.keys.sorted().compactMap { request.answers[$0]?.string }.joined(separator: "; ") + ")"
                } else { suffix = "" }
                return (["Asks: " + request.summary, questions(request)].filter { !$0.isEmpty }.joined(separator: "\n")) + suffix
            case let .notice(text, _): return "[\(text)]"
            case let .taskNotification(summary, _): return "[task] " + summary
            case let .turnEnd(_, _, stopped): return stopped ? "— turn stopped" : "— turn ended"
            case .contextUsage, .mcpServers, .compaction: return nil
            }
        }.joined(separator: "\n")
    }

    static func tail(_ items: [AgentChatItem], lines: Int) -> String {
        render(items).components(separatedBy: "\n").suffix(lines).joined(separator: "\n")
    }

    static func questions(_ request: AgentChatItem.PermissionRequest) -> String {
        request.questions.map { question in
            ([question.header, question.question].filter { !$0.isEmpty }
                + question.options.map { "- \($0.label): \($0.description)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// A turn starts at a message or, for one the engine started on its own (a background task or
    /// Monitor), right after the previous turn's end.
    static func lastTurnStopped(_ items: [AgentChatItem]) -> Bool {
        var stopped: Bool?
        var content = false
        for item in items.reversed() {
            switch item.kind {
            case .userMessage, .peerMessage:
                return stopped ?? false
            case .assistantText:
                content = true
            case let .turnEnd(_, _, value):
                if content { return stopped ?? false }
                if stopped == nil { stopped = value }
            case .notice, .contextUsage: break
            default: content = true
            }
        }
        return stopped ?? false
    }
}
