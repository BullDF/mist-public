import AppKit

extension SlackAgentBridge {
    static let shared = SlackAgentBridge(store: .shared, threads: SlackAgentConnection.shared.threads,
        call: { try await SlackAgentConnection.shared.botCall($0, $1) },
        startChat: { prompt, sender, config in
            guard let controller = AgentChatStore.externalChatWindow() else { throw StartError.noWindow }
            return try AgentChatStore.shared.launchBrowserChat(prompt: prompt, attachments: [], mentions: [],
                config: config, in: controller.browserState, tabId: -1, createBackgroundTab: true, sender: sender).id
        }, models: { await DrifterModel.load().models }, launchConfig: { DrifterLaunchSettings().config },
        reopenChat: { id in
            guard let controller = AgentChatStore.externalChatWindow() else { return false }
            return await withCheckedContinuation { continuation in
                AgentChatStore.shared.openChatInBackground(id, in: controller.browserState) { opened, _ in
                    continuation.resume(returning: opened)
                }
            }
        }, channelName: { SlackAgentAccess.directory.name(forChannel: $0)?.name },
        owner: { SlackAgentConnection.shared.owner }, botUserID: { SlackAgentConnection.shared.botUserID },
        workspaceURL: { SlackAgentConnection.shared.workspaceURL },
        log: { AppLogInfo($0) })

    func start() {
        SlackAgentConnection.shared.onInbound = { [weak self] in self?.receive($0) }
        SlackAgentConnection.shared.onConnected = { [weak self] in
            let previous = SlackAgentConnection.shared.previousConnectedAt
            Task { [weak self] in await self?.catchUp(since: previous) }
        }
        AgentChatStore.shared.onChatReplaced = { [weak self] in self?.chatReplaced($0, with: $1) }
    }
}
