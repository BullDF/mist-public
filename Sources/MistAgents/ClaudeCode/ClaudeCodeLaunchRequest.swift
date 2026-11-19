import Foundation

struct ClaudeCodeLaunchRequest: Equatable {
    let prompt: String
    var attachments: [AgentAttachment]
    let config: ClaudeCodeLaunchConfig
    let launchArguments: [String]
    var mentions: [AgentTabMention] = []
    var sender: AgentMessageSender? = nil
    var resume: AgentChatResume? = nil
}
