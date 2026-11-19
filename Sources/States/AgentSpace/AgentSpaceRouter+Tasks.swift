import Foundation

extension AgentSpaceRouter {
    static func handleTasksStart(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let runner = AgentChatStore.shared.backgroundTasks(for: caller) else {
                return failure("Background tasks are available only in Codex chats.")
            }
            guard let payload = json(context.payload), let rawKind = payload["kind"] as? String,
                  let kind = DrifterBackgroundTasks.Kind(rawValue: rawKind), let command = payload["command"] as? String else { return invalid() }
            if let description = payload["description"], !(description is String) { return invalid() }
            if kind == .monitor && payload["description"] == nil { return invalid() }
            var timeout: TimeInterval?
            if let value = payload["timeoutMs"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue) else { return invalid() }
                timeout = number.doubleValue / 1000
            }
            do {
                let result = try runner.start(kind: kind, command: command, description: payload["description"] as? String, timeout: timeout)
                return encode(["ok": true, "taskId": result.taskId, "outputFile": result.outputFile,
                    "message": kind == .command
                        ? "Running in the background. Mist sends you a message when it exits; end your turn instead of waiting."
                        : "Watching. Mist sends you its new output lines as messages; end your turn instead of waiting."])
            } catch { return failure(error.localizedDescription) }
        }
    }

    static func handleTasksStop(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  let caller = AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) else {
                return failure("unknown_browser_agent")
            }
            guard let runner = AgentChatStore.shared.backgroundTasks(for: caller) else {
                return failure("Background tasks are available only in Codex chats.")
            }
            guard let payload = json(context.payload), let id = payload["taskId"] as? String else { return invalid() }
            guard runner.stop(id) else { return failure("No running background task \(id) in this chat.") }
            return encode(["ok": true, "taskId": id, "stopped": true])
        }
    }
}
