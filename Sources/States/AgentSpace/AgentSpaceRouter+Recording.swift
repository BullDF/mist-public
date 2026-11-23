import Foundation

extension AgentSpaceRouter {
    static func handleSpacesRecord(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let chat = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let obj = json(context.payload), let action = obj["action"] as? String else { return invalid() }
            switch action {
            case "start":
                guard let windowId = obj["windowId"] as? Int, let tabId = obj["tabId"] as? Int,
                      let path = obj["path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0),
                      (path as NSString).pathExtension.lowercased() == "mp4" else { return invalid() }
                let overwrite = obj["overwrite"] as? Bool ?? false
                Task { @MainActor in
                    let reply: String
                    if let preview = AgentChatStore.shared.entry(for: chat)?.browserPreview,
                       preview.turnActive, preview.windowId == windowId, preview.tabId == tabId,
                       let tab = windowSpace(windowId: windowId)?.state?.tabs.first(where: { $0.guid == tabId }),
                       MistApps.address(tab.url) == nil, BrowserAgentTabPreview.hasLivePage(tab) {
                        do {
                            try await BrowserAgentRecordings.shared.start(chat: chat, tab: tab, windowId: windowId, path: path, overwrite: overwrite)
                            reply = encode(["ok": true])
                        } catch { reply = failure(error.localizedDescription) }
                    } else {
                        reply = failure("unknown_working_tab")
                    }
                    ExtensionMessaging.shared.sendResponse(reply, requestId: context.requestId)
                }
            case "stop":
                Task { @MainActor in
                    let reply: String
                    do { reply = encode(try await BrowserAgentRecordings.shared.stop(chat: chat)) }
                    catch { reply = failure(error.localizedDescription) }
                    ExtensionMessaging.shared.sendResponse(reply, requestId: context.requestId)
                }
            default:
                return invalid()
            }
            return nil
        }
    }

    static func handleSpacesRecordPointer(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            if AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
               let chat = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId),
               let obj = json(context.payload), let tabId = obj["tabId"] as? Int,
               let raw = obj["kind"] as? String, let kind = BrowserAgentRecordingTimeline.PointerKind(rawValue: raw),
               let x = obj["x"] as? Double, let y = obj["y"] as? Double, x.isFinite, y.isFinite {
                BrowserAgentRecordings.shared.pointer(chat: chat, tabId: tabId, kind: kind, point: CGPoint(x: x, y: y))
            }
            return encode(["ok": true])
        }
    }
}
