import Foundation

struct SlackThreadKey: Codable, Hashable {
    let channel: String
    let threadTs: String
}

enum SlackThreadKind: String, Codable { case dm, channel }

struct SlackIncomingMessage: Equatable {
    let key: SlackThreadKey
    let kind: SlackThreadKind
    let ts: String
    let text: String
}

struct SlackBlockAction: Equatable {
    let user: String
    let channel: String
    let messageTs: String
    let threadTs: String?
    let actionId: String
    let blockId: String
    let value: String
    let selections: [String: [String]]
}

enum SlackInbound: Equatable {
    case threadStarted(SlackThreadKey, context: String?)
    case contextChanged(SlackThreadKey, context: String?)
    case message(SlackIncomingMessage)
    case action(SlackBlockAction)
    /// Slack's stop button on a working agent session.
    case stopped(SlackThreadKey)

    var logKind: String {
        switch self {
        case .threadStarted: return "threadStarted"
        case .contextChanged: return "contextChanged"
        case .message: return "message"
        case .action: return "action"
        case .stopped: return "stopped"
        }
    }
}

/// In channels only messages that @mention Drifter reach it (`app_mention`): Johnny's other
/// messages there are for his colleagues. Every message in Drifter's DM reaches it.
struct SlackEventRouter {
    let owner: String
    let botUserID: String
    let teamID: String?

    func route(_ envelope: [String: Any]) -> [SlackInbound] {
        guard !owner.isEmpty, let payload = envelope["payload"] as? [String: Any] else { return [] }
        switch envelope["type"] as? String {
        case "events_api":
            if let teamID, payload["team_id"] as? String != teamID { return [] }
            guard let event = payload["event"] as? [String: Any], let type = event["type"] as? String else { return [] }
            if type == "assistant_thread_started" || type == "assistant_thread_context_changed" {
                guard let thread = event["assistant_thread"] as? [String: Any],
                      thread["user_id"] as? String == owner,
                      let channel = nonempty(thread["channel_id"]), let ts = nonempty(thread["thread_ts"]) else { return [] }
                let key = SlackThreadKey(channel: channel, threadTs: ts)
                let context = nonempty((thread["context"] as? [String: Any])?["channel_id"])
                return [type == "assistant_thread_started" ? .threadStarted(key, context: context) : .contextChanged(key, context: context)]
            }
            if type == "agent_session_stopped" {
                guard event["user"] as? String == owner, let channel = nonempty(event["channel"]),
                      let ts = nonempty(event["thread_ts"]) else { return [] }
                return [.stopped(SlackThreadKey(channel: channel, threadTs: ts))]
            }
            guard type == "message" || type == "app_mention", event["user"] as? String == owner,
                  event["user"] as? String != botUserID, event["bot_id"] == nil,
                  let channel = nonempty(event["channel"]), let ts = nonempty(event["ts"]),
                  let raw = event["text"] as? String else { return [] }
            if let subtype = event["subtype"] as? String, !["file_share", "thread_broadcast"].contains(subtype) { return [] }
            let mention = "<@\(botUserID)>"
            let text = raw.replacingOccurrences(of: mention, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let thread = nonempty(event["thread_ts"])
            let key = SlackThreadKey(channel: channel, threadTs: thread ?? ts)
            if type == "app_mention" { guard !channel.hasPrefix("D") else { return [] } }
            else { guard event["channel_type"] as? String == "im" else { return [] } }
            return [.message(SlackIncomingMessage(key: key, kind: type == "app_mention" ? .channel : .dm, ts: ts, text: text))]
        case "interactive":
            guard payload["type"] as? String == "block_actions",
                  let user = payload["user"] as? [String: Any], user["id"] as? String == owner else { return [] }
            if let teamID, let team = payload["team"] as? [String: Any], team["id"] as? String != teamID { return [] }
            let container = payload["container"] as? [String: Any] ?? [:]
            guard let channel = nonempty((payload["channel"] as? [String: Any])?["id"]) ?? nonempty(container["channel_id"]),
                  let ts = nonempty(container["message_ts"]) else { return [] }
            let thread = nonempty(container["thread_ts"]) ?? nonempty((payload["message"] as? [String: Any])?["thread_ts"])
            let values = (payload["state"] as? [String: Any])?["values"] as? [String: [String: [String: Any]]] ?? [:]
            var selections: [String: [String]] = [:]
            for (block, elements) in values {
                let selected = elements.keys.sorted().flatMap { id -> [String] in
                    let element = elements[id]!
                    if let option = element["selected_option"] as? [String: Any], let value = option["value"] as? String { return [value] }
                    return (element["selected_options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
                }
                if !selected.isEmpty { selections[block] = selected }
            }
            return (payload["actions"] as? [[String: Any]] ?? []).compactMap { action in
                guard let id = action["action_id"] as? String, let block = action["block_id"] as? String else { return nil }
                let value = action["value"] as? String ?? (action["selected_option"] as? [String: Any])?["value"] as? String ?? ""
                return .action(SlackBlockAction(user: owner, channel: channel, messageTs: ts, threadTs: thread,
                                                actionId: id, blockId: block, value: value, selections: selections))
            }
        default: return []
        }
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

/// Selects only unanswered owner messages, independent of transport and chat state.
enum SlackCatchUp {
    static func message(_ messages: [[String: Any]], key: SlackThreadKey, since: String,
                        owner: String, botUserID: String, isHandled: (String) -> Bool) -> SlackIncomingMessage? {
        let ordered = messages.filter { $0["ts"] is String }.sorted {
            SlackThreadStore.compare($0["ts"] as! String, $1["ts"] as! String) == .orderedAscending
        }
        let lastReply = ordered.last { $0["bot_id"] != nil || $0["user"] as? String == botUserID }?["ts"] as? String
        var selected: [(ts: String, text: String)] = []
        for message in ordered {
            guard let ts = message["ts"] as? String, SlackThreadStore.compare(ts, since) == .orderedDescending,
                  lastReply.map({ SlackThreadStore.compare(ts, $0) == .orderedDescending }) ?? true,
                  !isHandled(ts), message["user"] as? String == owner, message["bot_id"] == nil,
                  let raw = message["text"] as? String else { continue }
            if let subtype = message["subtype"] as? String, !["file_share", "thread_broadcast"].contains(subtype) { continue }
            let text = raw.replacingOccurrences(of: "<@\(botUserID)>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { selected.append((ts, text)) }
        }
        guard let newest = selected.last else { return nil }
        return .init(key: key, kind: .dm, ts: newest.ts, text: selected.map(\.text).joined(separator: "\n\n"))
    }
}
