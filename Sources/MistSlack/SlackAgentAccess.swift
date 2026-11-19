import Foundation

@MainActor enum SlackAgentAccess {
    static let client = SlackMCPClient(transport: { try await APIClient.shared.slackMCP($0, token: $1, headers: $2) })
    static let directory = SlackDirectory(call: { try await MistSlackService.shared.userCall($0, $1) },
                                          account: { MistSlackService.shared.userToken })

    static func installChatHooks() {
        AgentChatStrings.slackChannelName = { directory.name(forChannel: $0) }
        AgentChatStrings.slackUserName = { directory.name(forUser: $0) }
    }
}
