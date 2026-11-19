import AppKit

extension SlackAgentBridge {
    private static func window() -> SpaceSessionController? {
        let manager = SpaceSessionControllersManager.shared
        func eligible(_ controller: SpaceSessionController) -> Bool {
            controller.browserType == .normal && !controller.isDormant
                && !controller.browserState.isIncognito && !controller.browserState.isAgentSpace
        }
        if let active = manager.activeWindowController, eligible(active) { return active }
        return manager.getAllWindows().first(where: eligible)
    }

    static let shared = SlackAgentBridge(store: .shared, threads: SlackAgentConnection.shared.threads,
        call: { try await SlackAgentConnection.shared.botCall($0, $1) },
        startChat: { prompt, sender, config in
            guard let controller = window() else { throw StartError.noWindow }
            return try AgentChatStore.shared.launchBrowserChat(prompt: prompt, attachments: [], mentions: [],
                config: config, in: controller.browserState, tabId: -1, createBackgroundTab: true, sender: sender).id
        }, models: { await DrifterModel.load().models }, launchConfig: { DrifterLaunchSettings().config },
        reopenChat: { id in
            guard let controller = window() else { return false }
            return await withCheckedContinuation { continuation in
                AgentChatStore.shared.openChatInBackground(id, in: controller.browserState) { continuation.resume(returning: $0) }
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
