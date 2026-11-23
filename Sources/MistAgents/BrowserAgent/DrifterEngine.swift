import AppKit

enum DrifterEngine: String, Codable, CaseIterable, Sendable {
    case claude, codex, gemini

    var pickerTitle: String {
        switch self {
        case .claude: "Claude"
        case .codex: "GPT"
        case .gemini: "Gemini"
        }
    }
}

enum AgentChatIcon: String {
    case claude = "agent-claude", openai = "agent-openai", gemini = "agent-gemini"
    var isTemplate: Bool { self == .openai }
    /// At the same size the OpenAI mark reads smaller than Claude's and than site favicons.
    var scale: CGFloat { self == .openai ? 8.0 / 7 : 1 }
    /// Evens out the marks at a tile's size (the Drifter home's rows): Gemini's artwork spans 0.93 of its canvas where
    /// Claude's spans 0.78, and there the OpenAI knot reads heavier than both.
    var tileScale: CGFloat {
        switch self {
        case .claude: 1
        case .openai: 0.9
        case .gemini: 0.88
        }
    }
    static func resolve(engine: DrifterEngine) -> Self {
        switch engine {
        case .claude: .claude
        case .codex: .openai
        case .gemini: .gemini
        }
    }
}

