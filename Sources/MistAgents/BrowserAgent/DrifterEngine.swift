import AppKit

enum DrifterEngine: String, Codable, CaseIterable, Sendable {
    case claude, codex
}

enum AgentChatIcon: String {
    case claude = "agent-claude", openai = "agent-openai"
    var isTemplate: Bool { self == .openai }
    /// At the same size the OpenAI mark reads smaller than Claude's and than site favicons.
    var scale: CGFloat { self == .openai ? 8.0 / 7 : 1 }
    static func resolve(engine: DrifterEngine) -> Self {
        engine == .codex ? .openai : .claude
    }
}

