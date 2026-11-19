import Foundation

struct CodexMCPServer: Equatable, Sendable {
    let command: String
    var args: [String] = []
    var env: [String: String] = [:]
}

struct CodexLaunchRequest: Sendable {
    let prompt: String
    var attachments: [AgentAttachment] = []
    let model: String
    let effort: String
    let cwd: URL
    var developerInstructions = ""
    var mcpServers: [String: CodexMCPServer] = [:]
    var mentions: [AgentTabMention] = []
    var sender: AgentMessageSender? = nil
    var resume: AgentChatResume? = nil
    var inheritsCLIServers = false
}
