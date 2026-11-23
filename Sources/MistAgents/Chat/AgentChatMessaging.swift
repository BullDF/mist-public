import Foundation

struct AgentTaskFinish: Equatable, Sendable {
    let status: AgentTaskFinishStatus
    let message: String
}

enum AgentFinishError: Error {
    case emptyMessage, notEligible, notSlackTurn

    var message: String {
        switch self {
        case .emptyMessage: return "finish_task needs a non-empty message."
        case .notEligible: return "finish_task is only for child chats and chats answering a Slack thread. This chat answers Johnny directly, so reply here."
        case .notSlackTurn: return "This turn answers Johnny in Mist, not in Slack, so nothing would post: reply here instead."
        }
    }
}

enum AgentChatShortID {
    enum Resolution: Equatable {
        case none, match(UUID), ambiguous([UUID])
    }

    static func full(_ id: UUID) -> String {
        var uuid = id.uuid
        var value = withUnsafeBytes(of: &uuid) { bytes in
            bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<12).map { _ in
            let digit = alphabet[Int(value % 36)]
            value /= 36
            return digit
        })
    }

    static func short(_ id: UUID) -> String { String(full(id).prefix(4)) }

    static func resolve(_ query: String, among ids: [UUID]) -> Resolution {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 4, query.allSatisfy({ "0123456789abcdefghijklmnopqrstuvwxyz".contains($0) }) else { return .none }
        let matches = ids.filter { full($0).hasPrefix(query) }
        if matches.count == 1 { return .match(matches[0]) }
        return matches.isEmpty ? .none : .ambiguous(matches)
    }

    static func listedIds(_ ids: [UUID]) -> [UUID: String] {
        let ids = Array(Set(ids))
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            let full = full(id)
            let length = (4...12).first { length in
                !ids.contains { $0 != id && Self.full($0).hasPrefix(String(full.prefix(length))) }
            } ?? 12
            return (id, String(full.prefix(length)))
        })
    }
}

struct AgentChatListing {
    let chatId: UUID
    let id: String
    let title: String
    let engine: String
    let model: String
    let status: String
    let isCaller: Bool
    var parent: String? = nil
    var children: [String] = []
}

enum AgentDeliveryError: Error {
    case unknown(String), ambiguous(String, String), ownChat, ended(String), starting(String), notTaken(String), emptyText
    case descendantsOnly(String), invalidLines

    var message: String {
        switch self {
        case let .unknown(query): return "No open chat has ID “\(query)”. Call list_agents for the open chats."
        case let .ambiguous(query, candidates): return "ID “\(query)” matches several open chats: \(candidates). Use the longer ID."
        case .ownChat: return "That ID is this chat. Pick another chat from list_agents."
        case let .ended(id): return "Chat \(id) has ended and can't take messages."
        case let .starting(id): return "Chat \(id) is still starting. Try again in a moment."
        case let .notTaken(id): return "Chat \(id) couldn't take the message right now. Try again in a moment."
        case .emptyText: return "message_agent needs non-empty text."
        case let .descendantsOnly(action): return "Only your own child chats can be \(action)."
        case .invalidLines: return "read_agent lines must be an integer from 1 to 500."
        }
    }
}

enum AgentSpawnError: Error {
    case emptyBrief, emptyTitle, depth, noWindow, unknownModel, invalidEffort([String]), restricted(DrifterConfig), creation(String)
    var message: String {
        switch self {
        case let .restricted(config):
            let label = DrifterModel.label(config)
            if DrifterModel.spawnScope(config) == .gpt {
                return "This chat runs \(label), so its children run on GPT models only, at any effort: \(DrifterModel.codexPicks.joined(separator: ", "))."
            }
            return "This chat runs \(label), so its children run on \(label); omit model and effort."
        case .emptyBrief: return "spawn_agent needs a non-empty brief."
        case .emptyTitle: return "spawn_agent needs a non-empty title."
        case .depth: return "Chats nest at most three levels: top chat, child, grandchild."
        case .noWindow: return "Couldn't find this chat's window."
        case .unknownModel: return "Unknown model. Valid model IDs: \(DrifterModel.spawnModelIDs.joined(separator: ", "))."
        case let .invalidEffort(values): return "Invalid effort. Valid values: \(values.joined(separator: ", "))."
        case let .creation(message): return "Couldn't create the chat: \(message)"
        }
    }
}

struct AgentSpawnResult {
    let id: String
    let title: String
    let engine: String
    let model: String
    let effort: String
}

extension DrifterModel {
    static func resolveSpawnConfig(from parent: DrifterConfig, models: [Self], model: String?, effort: String?)
        -> Result<DrifterConfig, AgentSpawnError> {
        var config = parent
        let scope = spawnScope(parent)
        if let model {
            guard let resolved = spawnModel(model) else { return .failure(.unknownModel) }
            let allowed = switch scope {
            case .any: true
            case .gpt: resolved.engine == .codex
            case .own: resolved.engine == parent.engine && resolved.model == parent.model
            }
            guard allowed else { return .failure(.restricted(parent)) }
            config.engine = resolved.engine
            config.model = resolved.model
        }
        if let effort, scope == .own, effort != parent.effort { return .failure(.restricted(parent)) }
        let picked = forSpawn(config, models: models)
        if let effort {
            guard picked.efforts.contains(effort) else { return .failure(.invalidEffort(picked.efforts)) }
            config.effort = effort
        } else {
            config.effort = picked.effort(config.effort)
        }
        config.folder = DrifterHome.current.folder
        return .success(config)
    }
}
