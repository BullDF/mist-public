import Foundation

extension AgentSpaceRouter {
    static func handleSlackTools(context: ExtensionMessageContext) -> String? { handleSlack(context: context, tools: true) }
    static func handleSlackCall(context: ExtensionMessageContext) -> String? { handleSlack(context: context, tools: false) }

    private static func handleSlack(context: ExtensionMessageContext, tools: Bool) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) != nil else { return failure("unknown_browser_agent") }
            guard let payload = json(context.payload) else { return invalid() }
            let tool = payload["tool"] as? String ?? ""
            guard tools || (tool.range(of: "^slack_[a-z0-9_]+$", options: .regularExpression) != nil && payload["arguments"] is [String: Any]) else { return invalid() }
            let requestId = context.requestId
            Task { @MainActor in
                let response: String
                do {
                    guard let token = MistSlackService.shared.userToken, !token.isEmpty else {
                        if tools { ExtensionMessaging.shared.sendResponse(encode(["ok": true, "tools": []]), requestId: requestId); return }
                        throw SlackAPIError(code: "not_configured")
                    }
                    if tools {
                        let listed = try await SlackAgentAccess.client.tools(token: token)
                        Task { await SlackAgentAccess.directory.refreshIfStale() }
                        response = encode(["ok": true, "tools": listed])
                    } else {
                        let result = try await SlackAgentAccess.client.call(tool, arguments: payload["arguments"] as! [String: Any], token: token)
                        if tool == "slack_send_message", result["isError"] as? Bool != true {
                            Task { await SlackAgentAccess.directory.refreshIfStale() }
                        }
                        response = encode(["ok": true, "result": result])
                    }
                } catch let error as SlackMCPError { response = failure(error.agentMessage) }
                catch { response = failure(SlackWebAPI.message(error)) }
                ExtensionMessaging.shared.sendResponse(response, requestId: requestId)
            }
            return nil
        }
    }
}
