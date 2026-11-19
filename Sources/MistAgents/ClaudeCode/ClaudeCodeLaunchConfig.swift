import Foundation

struct ClaudeCodeLaunchConfig: Codable, Equatable {
    var folder: URL
    var model: ClaudeCodeModel = .opus
    var effort: ClaudeCodeEffort = .xhigh
}

enum ClaudeCodeModel: String, Codable, CaseIterable {
    case opus, fable, sonnet, haiku

    var title: String {
        switch self {
        case .opus: NSLocalizedString("browser.newTabPage.claudeCode.model.opus", value: "Opus", comment: "Claude Code - Model product name; do not translate")
        case .fable: NSLocalizedString("browser.newTabPage.claudeCode.model.fable", value: "Fable", comment: "Claude Code - Model product name; do not translate")
        case .sonnet: NSLocalizedString("browser.newTabPage.claudeCode.model.sonnet", value: "Sonnet", comment: "Claude Code - Model product name; do not translate")
        case .haiku: NSLocalizedString("browser.newTabPage.claudeCode.model.haiku", value: "Haiku", comment: "Claude Code - Model product name; do not translate")
        }
    }
}

enum ClaudeCodeEffort: String, Codable, CaseIterable {
    case low, medium, high, xhigh, max

    var title: String {
        switch self {
        case .low: NSLocalizedString("browser.newTabPage.claudeCode.effort.low", value: "Low", comment: "Claude Code - Low reasoning effort")
        case .medium: NSLocalizedString("browser.newTabPage.claudeCode.effort.medium", value: "Medium", comment: "Claude Code - Medium reasoning effort")
        case .high: NSLocalizedString("browser.newTabPage.claudeCode.effort.high", value: "High", comment: "Claude Code - High reasoning effort")
        case .xhigh: NSLocalizedString("browser.newTabPage.claudeCode.effort.xhigh", value: "Extra High", comment: "Claude Code - Extra high reasoning effort")
        case .max: NSLocalizedString("browser.newTabPage.claudeCode.effort.max", value: "Max", comment: "Claude Code - Maximum reasoning effort")
        }
    }
}
