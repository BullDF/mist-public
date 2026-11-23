import Foundation

extension AgentSpaceRouter {
    static func handleAgentsFinish(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let rawStatus = payload["status"] as? String,
                  let status = AgentTaskFinishStatus(rawValue: rawStatus), let message = payload["message"] as? String else { return invalid() }
            switch AgentChatStore.shared.finishTask(caller, status: status, message: message) {
            case let .success(note): return encode(["ok": true, "status": status.rawValue, "note": note])
            case let .failure(error): return failure(error.message)
            }
        }
    }

    static func handleAgentsHandOff(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let message = payload["message"] as? String,
                  payload["tab"] == nil || payload["tab"] is String else { return invalid() }
            guard let note = AgentChatStore.shared.handOff(caller, message: message, tab: payload["tab"] as? String) else {
                return failure("hand_off needs a non-empty message.")
            }
            return encode(["ok": true, "note": note])
        }
    }

    static func handleAgentsList(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            return listAgentChats(caller: caller, store: .shared, findTab: liveAgentHostTab)
        }
    }

    @MainActor
    static func listAgentChats(caller: UUID, store: AgentChatStore, findTab: (Int) -> Tab?) -> String {
        let listing = store.agentListing(caller: caller)
        let agents: [[String: Any]] = listing.map { chat in
            var value: [String: Any] = ["id": chat.id, "title": chat.title, "engine": chat.engine,
                                        "model": chat.model, "status": chat.status]
            if chat.isCaller {
                value["self"] = true
                if let host = store.panelHost(of: caller), let tab = findTab(host) {
                    value["mountedTo"] = agentHostDescription(tabId: host, tab: tab)
                }
            }
            if let parent = chat.parent { value["parent"] = parent }
            if !chat.children.isEmpty { value["children"] = chat.children }
            return value
        }
        return encode(["ok": true, "self": listing.first { $0.isCaller }?.id ?? AgentChatShortID.short(caller), "agents": agents])
    }

    static func handleAgentsMount(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let windowId = payload["windowId"] as? Int,
                  let tabId = payload["tabId"] as? Int else { return invalid() }
            guard let state = windowSpace(windowId: windowId)?.state else {
                return failure("This window is no longer open.")
            }
            return mountAgentChat(caller, to: tabId, in: state, store: .shared, findTab: liveAgentHostTab)
        }
    }

    @MainActor
    static func mountAgentChat(_ caller: UUID, to tabId: Int, in state: BrowserState,
                               store: AgentChatStore, findTab: (Int) -> Tab?) -> String {
        if let host = store.panelHost(of: caller) {
            let title = agentHostTitle(tabId: host, tab: findTab(host))
            return failure("This chat is mounted to \(title) (tab \(host)). Call unmount_from_tab first.")
        }
        guard let tab = state.tabs.first(where: { $0.guid == tabId }) else {
            return failure("No tab with ID \(tabId) in this window. Call list_tabs.")
        }
        guard state.canShowChatPanel(for: tab) else {
            return failure("That tab can't show a Chat panel.")
        }
        guard !store.hasPanelChat(tabId) else {
            return failure("That tab's Chat panel already shows another chat.")
        }
        guard store.mount(caller, to: tabId) else { return failure("Could not mount this chat to that tab.") }
        let focusedTabId = state.focusingTab?.guid
        let splitPartner = state.splitGroup(forTabId: tabId)?.partnerTabId(of: tabId)
        // Expanding mirrors to the split partner and closes a window's extension side panel.
        if tab.aiChatCollapsed, focusedTabId != tabId, splitPartner == nil || splitPartner != focusedTabId,
           state.extensionSidePanel == nil {
            state.setAIChatCollapsed(for: tab, collapsed: false)
        }
        return encode(["ok": true, "mountedTo": agentHostDescription(tabId: tabId, tab: tab)])
    }

    static func handleAgentsUnmount(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            return unmountAgentChat(caller, store: .shared, findTab: liveAgentHostTab)
        }
    }

    @MainActor
    static func unmountAgentChat(_ caller: UUID, store: AgentChatStore, findTab: (Int) -> Tab?) -> String {
        guard let host = store.panelHost(of: caller) else { return failure("This chat isn't mounted to a tab.") }
        let description = agentHostDescription(tabId: host, tab: findTab(host))
        store.unmount(caller)
        return encode(["ok": true, "unmountedFrom": description])
    }

    private static func agentHostDescription(tabId: Int, tab: Tab?) -> [String: Any] {
        ["tabId": tabId, "title": agentHostTitle(tabId: tabId, tab: tab)]
    }

    private static func agentHostTitle(tabId: Int, tab: Tab?) -> String {
        if let title = tab?.title, !title.isEmpty { return title }
        if let url = tab?.url, !url.isEmpty { return url }
        return "Tab \(tabId)"
    }

    @MainActor
    private static func liveAgentHostTab(_ tabId: Int) -> Tab? {
        for controller in SpaceSessionControllersManager.shared.getAllWindows() {
            if let tab = controller.browserState.tabs.first(where: { $0.guid == tabId }) { return tab }
        }
        return nil
    }

    static func handleAgentsSpawn(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let brief = payload["brief"] as? String,
                  let title = payload["title"] as? String else { return invalid() }
            switch AgentChatStore.shared.spawnAgentChat(from: caller, brief: brief, title: title,
                                                       model: payload["model"] as? String, effort: payload["effort"] as? String) {
            case let .success(child):
                return encode(["ok": true, "id": child.id, "title": child.title, "engine": child.engine, "model": child.model, "effort": child.effort])
            case let .failure(error): return failure(error.message)
            }
        }
    }

    static func handleAgentsRead(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) != nil else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let id = payload["id"] as? String else { return invalid() }
            if let lines = payload["lines"] {
                guard let number = lines as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue) else { return invalid() }
            }
            switch AgentChatStore.shared.readAgent(id, lines: payload["lines"] as? Int ?? 60) {
            case let .success(chat): return encode(["ok": true, "id": chat.id, "title": chat.title, "status": chat.status, "text": chat.text])
            case let .failure(error): return failure(error.message)
            }
        }
    }

    static func handleAgentsStop(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let id = payload["id"] as? String else { return invalid() }
            switch AgentChatStore.shared.stopAgent(id, from: caller) {
            case let .success(chat):
                var value: [String: Any] = ["ok": true, "id": chat.id, "stopped": chat.stopped]
                if !chat.stopped { value["status"] = chat.status }
                return encode(value)
            case let .failure(error): return failure(error.message)
            }
        }
    }

    static func handleAgentsClose(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let id = payload["id"] as? String else { return invalid() }
            switch AgentChatStore.shared.closeAgent(id, from: caller) {
            case let .success(id): return encode(["ok": true, "id": id, "closed": true])
            case let .failure(error): return failure(error.message)
            }
        }
    }

    static func handleAgentsMessage(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let payload = json(context.payload), let id = payload["id"] as? String,
                  let text = payload["text"] as? String else { return invalid() }
            let requestId = context.requestId
            Task { @MainActor in
                let response: String
                switch await AgentChatStore.shared.deliverAgentMessage(text, to: id, from: caller) {
                case let .success(result):
                    response = encode(["ok": true, "id": result.listedId, "title": result.title, "delivery": result.delivery])
                case let .failure(error): response = failure(error.message)
                }
                ExtensionMessaging.shared.sendResponse(response, requestId: requestId)
            }
            return nil
        }
    }
}
