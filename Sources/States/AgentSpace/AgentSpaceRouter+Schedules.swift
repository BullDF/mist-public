import Foundation

extension AgentSpaceRouter {
    @MainActor
    private static func scheduleCaller(_ context: ExtensionMessageContext) -> UUID? {
        guard AgentDriverSessionRegistry.shared.isLiveBrowserAgent(principalId: context.driverPrincipalId) else { return nil }
        return AgentChatStore.shared.browserChat(principalId: context.driverPrincipalId)
    }

    static func handleScheduleCreate(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard let caller = scheduleCaller(context) else { return failure("unknown_browser_agent") }
            guard let payload = json(context.payload), let rawTitle = payload["title"] as? String,
                  let prompt = payload["prompt"] as? String,
                  ["cron", "at", "target", "model", "effort"].allSatisfy({ payload[$0] == nil || payload[$0] is String })
            else { return invalid() }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure("schedule_prompt needs a non-empty title and prompt.")
            }
            var delayMinutes: Int?
            if let value = payload["delay_minutes"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(number.intValue) else {
                    return failure(DrifterScheduleError.invalidDelay.localizedDescription)
                }
                delayMinutes = number.intValue
            }
            let target: DrifterSchedule.Target
            let model = payload["model"] as? String, effort = payload["effort"] as? String
            switch payload["target"] as? String ?? "this_chat" {
            case "this_chat":
                guard model == nil, effort == nil else { return failure("model and effort apply only to new_chat") }
                target = .thisChat
            case "new_chat":
                guard let entry = AgentChatStore.shared.entry(for: caller) else { return failure("unknown_browser_agent") }
                switch DrifterModel.resolveSpawnConfig(from: entry.settings.config, models: entry.settings.models, model: model, effort: effort) {
                case let .success(config): target = .newChat(config)
                case let .failure(error): return failure(error.message)
                }
            default: return invalid()
            }
            do {
                let schedule = try DrifterScheduleStore.shared.create(title: title, prompt: prompt, cron: payload["cron"] as? String,
                    at: payload["at"] as? String, delayMinutes: delayMinutes, target: target, owner: caller)
                return encode(["ok": true, "id": schedule.id, "nextRun": scheduleDateFormatter().string(from: schedule.nextRun),
                               "target": schedule.target.name])
            } catch { return failure(error.localizedDescription) }
        }
    }

    static func handleScheduleList(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard let caller = scheduleCaller(context) else { return failure("unknown_browser_agent") }
            let formatter = scheduleDateFormatter()
            do {
                let rows = try DrifterScheduleStore.shared.list().map { schedule -> [String: Any] in
                    let owner = AgentChatStore.shared.chatReferenceTitle(for: schedule.owner)
                    let creator: [String: Any] = ["chatId": schedule.owner.uuidString.lowercased(), "title": owner]
                    var target: [String: Any] = ["kind": schedule.target.name]
                    switch schedule.target {
                    case .thisChat:
                        target.merge(creator) { _, title in title }
                    case let .newChat(config):
                        target["model"] = config.model
                        target["engine"] = config.engine.rawValue
                        target["effort"] = config.effort
                    }
                    var row: [String: Any] = [
                        "id": schedule.id, "title": schedule.title, "prompt": schedule.prompt, "target": target,
                        "createdBy": creator, "isCreator": schedule.owner == caller,
                        "nextRun": formatter.string(from: schedule.nextRun),
                        "lastRun": schedule.lastRun.map { formatter.string(from: $0) } as Any? ?? NSNull(),
                    ]
                    switch schedule.timing {
                    case let .cron(expression): row["cron"] = expression
                    case let .at(time): row["at"] = formatter.string(from: time)
                    }
                    return row
                }
                return encode(["ok": true, "schedules": rows])
            } catch { return failure(error.localizedDescription) }
        }
    }

    static func handleScheduleCancel(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard let caller = scheduleCaller(context) else { return failure("unknown_browser_agent") }
            guard let payload = json(context.payload), let id = payload["schedule_id"] as? String else { return invalid() }
            do {
                try DrifterScheduleStore.shared.cancel(id, from: caller)
                return encode(["ok": true, "id": id, "cancelled": true])
            } catch { return failure(error.localizedDescription) }
        }
    }

    static func handleNotify(context: ExtensionMessageContext) -> String? {
        MainActor.assumeIsolated {
            guard let caller = scheduleCaller(context) else { return failure("unknown_browser_agent") }
            guard let payload = json(context.payload), let message = payload["message"] as? String,
                  payload["title"] == nil || payload["title"] is String else { return invalid() }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure("notify needs a non-empty message.")
            }
            let customTitle = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? AgentChatStore.shared.chatReferenceTitle(for: caller)
            let requestId = context.requestId
            Task { @MainActor in
                let response: String
                do {
                    let posted = try await DrifterNotifier.post(chat: caller, title: title, message: message)
                    response = posted ? encode(["ok": true, "posted": true]) : failure("macOS notifications are not authorized for Mist.")
                } catch { response = failure(error.localizedDescription) }
                ExtensionMessaging.shared.sendResponse(response, requestId: requestId)
            }
            return nil
        }
    }

    private static func scheduleDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }
}
