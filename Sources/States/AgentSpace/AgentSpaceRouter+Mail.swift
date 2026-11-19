import Foundation

extension AgentSpaceRouter {
    static func handleMailAccounts(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "accounts") }
    static func handleMailList(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "list") }
    static func handleMailSearch(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "search") }
    static func handleMailRead(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "read") }
    static func handleMailDraft(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "draft") }
    static func handleMailSend(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "send") }
    static func handleMailUpdate(context: ExtensionMessageContext) -> String? { handleMail(context: context, operation: "update") }

    private static func handleMail(context: ExtensionMessageContext, operation: String) -> String? {
        MainActor.assumeIsolated {
            guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId),
                  AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId) != nil else { return failure("unknown_browser_agent") }
            guard let payload = json(context.payload) else { return invalid() }
            func string(_ key: String) -> Bool { payload[key] == nil || payload[key] is String }
            func strings(_ key: String) -> Bool { payload[key] == nil || payload[key] is [String] }
            func integer(_ key: String, range: ClosedRange<Int>) -> Bool {
                guard let value = payload[key] else { return true }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { return false }
                return range.contains(number.intValue)
            }
            guard ["mailbox", "account", "before", "id", "query", "replyTo", "forward", "draftId", "subject", "body", "action"].allSatisfy(string),
                  ["to", "cc", "bcc", "attachments", "ids"].allSatisfy(strings),
                  payload["replyAll"] == nil || (payload["replyAll"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
                  ["replyTo", "forward", "draftId"].allSatisfy({ payload[$0] == nil || (payload[$0] as? String).flatMap(UUID.init(uuidString:)) != nil }),
                  operation != "update" || ((payload["ids"] as? [String]).map { (1...100).contains($0.count) } == true && ["read", "unread", "flag", "unflag", "archive", "move", "trash"].contains(payload["action"] as? String ?? "") && ((payload["action"] as? String == "move") == (payload["mailbox"] != nil))),
                  integer("limit", range: 1...100), integer("maxChars", range: 1000...200000),
                  payload["server"] == nil || (payload["server"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true,
                  operation != "search" || (payload["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  operation != "read" || (payload["id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
                  payload["before"] == nil || (payload["before"] as? String).flatMap(UUID.init(uuidString:)) != nil else { return invalid() }
            let requestId = context.requestId
            Task { @MainActor in
                let response: String
                do {
                    let tools = MailAgentTools.shared
                    var value: [String: Any]
                    switch operation {
                    case "accounts": value = try await tools.accounts()
                    case "list": value = try await tools.list(mailbox: payload["mailbox"] as? String, account: payload["account"] as? String, before: (payload["before"] as? String).flatMap(UUID.init(uuidString:)), limit: payload["limit"] as? Int ?? 25)
                    case "search": value = try await tools.search(query: payload["query"] as! String, mailbox: payload["mailbox"] as? String, account: payload["account"] as? String, server: payload["server"] as? Bool ?? false, limit: payload["limit"] as? Int ?? 25)
                    case "read": value = try await tools.read(id: UUID(uuidString: payload["id"] as! String)!, maxChars: payload["maxChars"] as? Int ?? 20000)
                    case "draft": value = try await tools.writeDraft(payload)
                    case "send": value = try await tools.send(payload)
                    default: value = try await tools.update(ids: payload["ids"] as! [String], action: payload["action"] as! String, mailbox: payload["mailbox"] as? String)
                    }
                    value["ok"] = true; response = encode(value)
                } catch { response = failure(MailAgentTools.errorMessage(error)) }
                ExtensionMessaging.shared.sendResponse(response, requestId: requestId)
            }
            return nil
        }
    }
}
