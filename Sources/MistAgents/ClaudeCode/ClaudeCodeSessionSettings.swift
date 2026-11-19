import Combine
import Foundation

/// Confirmed per-chat settings. This never writes the New Tab Page's saved defaults.
@MainActor
final class ClaudeCodeSessionSettings: ObservableObject {
    enum Change: Equatable {
        case model(ClaudeCodeModel), effort(ClaudeCodeEffort)

        var request: ClaudeCodeJSON {
            switch self {
            case let .model(model): return .object(["subtype": .string("set_model"), "model": .string(model.rawValue)])
            case let .effort(effort): return .object(["subtype": .string("apply_flag_settings"), "settings": .object(["effortLevel": .string(effort.rawValue)])])
            }
        }
    }
    enum Outcome: Equatable {
        case confirmed(resolvedModel: String?)
        case failed(String)
    }

    @Published private(set) var config: ClaudeCodeLaunchConfig
    @Published var isEnabled = false
    var send: ((String) -> Void)?
    private var pending: [String: Change] = [:]

    init(config: ClaudeCodeLaunchConfig) { self.config = config }

    func followAppliedSettings(_ applied: ClaudeCodeJSON, models: [String: ClaudeCodeModelInfo]) {
        var updated = config
        if let raw = applied["model"].string,
           let model = ClaudeCodeModel.allCases.first(where: { models[$0.rawValue]?.resolvedModel == raw })
                ?? ClaudeCodeModel(rawValue: raw) { updated.model = model }
        if let effort = applied["effort"].string.flatMap(ClaudeCodeEffort.init(rawValue:)) { updated.effort = effort }
        config = updated
    }

    @discardableResult
    func change(_ change: Change, requestId: String = UUID().uuidString) -> String? {
        guard isEnabled else { return nil }
        guard let send else { return nil }
        pending[requestId] = change
        send(ClaudeCodeProtocol.control(requestId: requestId, request: change.request))
        return requestId
    }

    func receive(_ value: ClaudeCodeJSON) -> Outcome? {
        let response = value["response"]
        guard let id = response["request_id"].string, let change = pending.removeValue(forKey: id) else { return nil }
        guard response["subtype"].string == "success" else {
            return .failed(response["error"].string ?? AgentChatStrings.settingFailed)
        }
        var updated = config
        var model: String?
        switch change {
        case let .model(alias):
            updated.model = alias
            model = response["response"]["model"].string ?? alias.rawValue
        case let .effort(effort): updated.effort = effort
        }
        config = updated
        return .confirmed(resolvedModel: model)
    }

    func end() {
        isEnabled = false
        pending.removeAll()
    }
}
