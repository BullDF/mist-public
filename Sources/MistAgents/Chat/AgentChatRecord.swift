import Foundation

struct AgentChatRecord: Codable {
    var title: String
    var background: String
    var drifter: DrifterConfig
    var sessionId: String?
    var items: [AgentChatItem]
    var markers: [AgentChatMarker]?
    var handOff: AgentHandOff?
    var queued: [String]
    var draft: String
    /// Shown until the restored chat's agent reports its own.
    var contextTokens: Int?
    var contextWindowSize: Int?
    var memoryFolders: [String]?
    var skillFolders: [String]?
    var autoTitle: String?
    var manualTitle: String?
    var pendingSessionTitle: String?

    private enum CodingKeys: String, CodingKey {
        case title, background, drifter, sessionId, items, queued, draft, contextTokens, contextWindowSize
        case memoryFolders, skillFolders, autoTitle, manualTitle, pendingSessionTitle, markers, handOff
    }
    private enum LegacyKeys: String, CodingKey { case claudeCode, browserAgent }
    private struct LegacyBrowser: Decodable {
        var engine: DrifterEngine
        var model: String
        var effort: String
        var confirmation: DrifterConfirmation
    }
    private struct LegacyClaude: Decodable {
        var folder: URL
        var permissionMode: String
        var model: String
        var effort: String
    }

    init(title: String, background: String, drifter: DrifterConfig, sessionId: String? = nil,
         items: [AgentChatItem] = [], queued: [String] = [], draft: String = "", contextTokens: Int? = nil,
         contextWindowSize: Int? = nil, memoryFolders: [String]? = nil, skillFolders: [String]? = nil,
         autoTitle: String? = nil, manualTitle: String? = nil, pendingSessionTitle: String? = nil,
         markers: [AgentChatMarker]? = nil, handOff: AgentHandOff? = nil) {
        self.title = title; self.background = background; self.drifter = drifter; self.sessionId = sessionId
        self.items = items; self.queued = queued; self.draft = draft; self.contextTokens = contextTokens
        self.contextWindowSize = contextWindowSize; self.memoryFolders = memoryFolders; self.skillFolders = skillFolders
        self.autoTitle = autoTitle; self.manualTitle = manualTitle; self.pendingSessionTitle = pendingSessionTitle
        self.markers = markers; self.handOff = handOff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let config = try c.decodeIfPresent(DrifterConfig.self, forKey: .drifter) { drifter = config }
        else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let config = try legacy.decodeIfPresent(LegacyBrowser.self, forKey: .browserAgent) {
                guard let folder = decoder.userInfo[.legacyBrowserAgentDirectory] as? URL else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Legacy Browser Agent cwd is required"))
                }
                drifter = .init(engine: config.engine, model: config.model, effort: config.effort,
                    confirmation: config.confirmation, folder: folder)
            } else {
                let config = try legacy.decode(LegacyClaude.self, forKey: .claudeCode)
                drifter = .init(engine: .claude, model: config.model, effort: config.effort,
                    confirmation: ["manual", "plan"].contains(config.permissionMode) ? .ask : .skip, folder: config.folder)
            }
        }
        title = try c.decode(String.self, forKey: .title)
        background = try c.decode(String.self, forKey: .background)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        items = try c.decode([AgentChatItem].self, forKey: .items)
        markers = try c.decodeIfPresent([AgentChatMarker].self, forKey: .markers)
        handOff = try c.decodeIfPresent(AgentHandOff.self, forKey: .handOff)
        queued = try c.decodeIfPresent([String].self, forKey: .queued) ?? []
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindowSize = try c.decodeIfPresent(Int.self, forKey: .contextWindowSize)
        memoryFolders = try c.decodeIfPresent([String].self, forKey: .memoryFolders)
        skillFolders = try c.decodeIfPresent([String].self, forKey: .skillFolders)
        autoTitle = try c.decodeIfPresent(String.self, forKey: .autoTitle)
        manualTitle = try c.decodeIfPresent(String.self, forKey: .manualTitle)
        pendingSessionTitle = try c.decodeIfPresent(String.self, forKey: .pendingSessionTitle)
    }

    var lastTurnEnd: Date? {
        items.lazy.reversed().compactMap { item -> Date? in
            if case let .turnEnd(_, finishedAt, _) = item.kind { return finishedAt }
            return nil
        }.first
    }
}

extension CodingUserInfoKey {
    static let legacyBrowserAgentDirectory = CodingUserInfoKey(rawValue: "legacyBrowserAgentDirectory")!
}
