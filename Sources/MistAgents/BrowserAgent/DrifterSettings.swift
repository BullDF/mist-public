import Combine
import Foundation

extension Notification.Name {
    static let drifterLaunchSettingsDidChange = Notification.Name("DrifterLaunchSettingsDidChange")
}

enum DrifterConfirmation: String, Codable, CaseIterable {
    case ask, skip
    var title: String {
        switch self {
        case .ask: NSLocalizedString("browser.agent.confirmation.ask", value: "Ask before acting", comment: "Browser Agent - Confirm browser actions")
        case .skip: NSLocalizedString("browser.agent.confirmation.skip", value: "Skip confirmation", comment: "Browser Agent - Automatically approve browser actions")
        }
    }
    func automaticallyAllows(tool: String, requiresInteraction: Bool) -> Bool {
        if ["finish_task", "stop_task", "group_tabs", "hand_off", "notify", "stop_recording", "mount_to_tab", "unmount_from_tab"]
            .contains(where: { tool == "mcp__mistbrowser__" + $0 }) { return true }
        if tool == "mcp__mistbrowser__send_mail" || DrifterSlackTools.alwaysConfirm.contains(where: { tool == "mcp__mistbrowser__" + $0 }) { return false }
        // The claude.ai Artifact tools' publish consent is a yes or no, not an answer, so it follows the chat's mode.
        if DrifterLaunchRequest.artifactTools.contains(tool) { return self == .skip }
        guard !requiresInteraction else { return false }
        if ["Read", "Glob", "Grep"].contains(tool) { return true }
        if DrifterSlackTools.readOnly.contains(where: { tool == "mcp__mistbrowser__" + $0 }) { return true }
        if ["list_agents", "read_agent", "list_schedules", "list_mail_accounts", "list_mail", "search_mail", "read_mail"].map({ "mcp__mistbrowser__" + $0 }).contains(tool) { return true }
        return self == .skip
    }
}

struct DrifterConfig: Codable, Equatable {
    var engine: DrifterEngine = .claude
    var model = "opus"
    var effort = "xhigh"
    var confirmation: DrifterConfirmation = .skip
    var folder: URL = DrifterHome.current.folder
}

/// A new chat's settings, set only in Settings ▸ Drifter (Opus at xhigh, confirmation skipped, until
/// changed there). A pick in a chat's composer applies to that chat alone.
struct DrifterLaunchSettings {
    var defaults: UserDefaults = .standard
    private static let engineKey = "MistDrifter.defaultEngine", modelKey = "MistDrifter.defaultModel"
    private static let effortKey = "MistDrifter.defaultEffort", confirmationKey = "MistDrifter.defaultConfirmation"
    var config: DrifterConfig {
        removeLegacyKeys()
        let engine = defaults.string(forKey: Self.engineKey).flatMap(DrifterEngine.init(rawValue:)) ?? .claude
        let model = DrifterModel.offered(defaults.string(forKey: Self.modelKey) ?? "opus", engine: engine)
        let effort = defaults.string(forKey: Self.effortKey) ?? (engine == .gemini ? GeminiModelInfo.defaultEffort : "xhigh")
        return .init(engine: engine,
              model: model, effort: engine == .gemini ? DrifterModel.geminiModel(model).effort(effort) : effort,
              confirmation: defaults.string(forKey: Self.confirmationKey).flatMap(DrifterConfirmation.init(rawValue:)) ?? .skip)
    }

    /// Removes only keys still there: every defaults write, even removing a missing key, posts
    /// `UserDefaults.didChangeNotification` to every observer in the app, and the Chat panel reads
    /// `config` on each chat store change, dozens of times a second while an agent streams.
    /// `MistDrifter.<field>` held the last pick, which new chats used before Settings ▸ Drifter.
    private func removeLegacyKeys() {
        for key in [
            "MistDrifter.engine", "MistDrifter.model", "MistDrifter.effort", "MistDrifter.confirmation",
            "MistBrowserAgent.engine", "MistBrowserAgent.model", "MistBrowserAgent.effort", "MistBrowserAgent.confirmation",
            "MistClaudeCode.folder", "MistClaudeCode.permissionMode", "MistClaudeCode.model", "MistClaudeCode.effort", "MistClaudeCode.recentFolders",
        ] where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    func save(_ config: DrifterConfig) {
        defaults.set(config.engine.rawValue, forKey: Self.engineKey)
        defaults.set(config.model, forKey: Self.modelKey)
        defaults.set(config.effort, forKey: Self.effortKey)
        defaults.set(config.confirmation.rawValue, forKey: Self.confirmationKey)
        NotificationCenter.default.post(name: .drifterLaunchSettingsDidChange, object: defaults)
    }
}

struct DrifterModel: Equatable, Identifiable {
    let engine: DrifterEngine
    let model: String
    let title: String
    let efforts: [String]
    let defaultEffort: String
    var id: String { engine.rawValue + ":" + model }
    func effort(_ saved: String) -> String { efforts.contains(saved) ? saved : defaultEffort }
    /// The GPT models offered outside the picker (spawn_agent, Slack prefixes, saved defaults): the
    /// picks Codex's catalog last gave (`DrifterCodexPicks`). A chat on a model not offered keeps
    /// running on it; a new chat's default falls back to an offered one (`offered`).
    static var codexPicks: [String] { DrifterCodexPicks.shared.ids }
    static var spawnModelIDs: [String] { ClaudeCodeModel.allCases.map(\.rawValue) + codexPicks + DrifterGeminiPicks.shared.ids }
    static func spawnModel(_ query: String) -> (engine: DrifterEngine, model: String)? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let model = ClaudeCodeModel.allCases.first(where: { $0.rawValue.lowercased() == query }) {
            return (.claude, model.rawValue)
        }
        if let pick = codexPicks.first(where: {
            $0.lowercased() == query || title($0, engine: .codex).lowercased() == query || codexFamily($0) == query
        }) { return (.codex, pick) }
        if let pick = DrifterGeminiPicks.shared.models.first(where: {
            $0.id == query || $0.displayName.lowercased() == query || GeminiModelInfo.family($0.id) == query
        }) { return (.gemini, pick.id) }
        return nil
    }

    static func forSpawn(_ config: DrifterConfig, models: [Self]) -> Self {
        if let model = models.first(where: { $0.engine == config.engine && $0.model == config.model }) { return model }
        if config.engine == .gemini { return geminiModel(config.model) }
        if config.engine == .codex, let cached = DrifterCodexPicks.shared.model(config.model) {
            return codexModel(cached)
        }
        let (efforts, fallback) = config.engine == .claude
            ? (ClaudeCodeEffort.allCases.map(\.rawValue), "xhigh") : (["low", "medium", "high", "xhigh"], "medium")
        return .init(engine: config.engine, model: config.model, title: title(config.model, engine: config.engine),
                     efforts: efforts, defaultEffort: fallback)
    }
    /// The children a chat may spawn (Johnny's rule): Opus and Fable chats any model at any effort,
    /// Astra chats any GPT model at any effort, every other chat only its own model and effort.
    /// Recognized by family, so a version bump keeps a model's rank.
    enum SpawnScope { case own, gpt, any }
    static func spawnScope(_ config: DrifterConfig) -> SpawnScope {
        switch config.engine {
        case .claude: return [.opus, .fable].contains(ClaudeCodeModel(rawValue: config.model.lowercased())) ? .any : .own
        case .codex: return codexFamily(config.model.lowercased()) == "astra" ? .gpt : .own
        case .gemini: return .own
        }
    }
    /// "GPT-6.1 Terra · low".
    static func label(_ config: DrifterConfig) -> String { title(config.model, engine: config.engine) + " · " + config.effort }
    /// The offered model a saved new-chat default resolves to: itself while offered, else the newest
    /// offered one of its family (`gpt-6-sol` → `gpt-6.2-sol`), else the engine's first.
    static func offered(_ model: String, engine: DrifterEngine) -> String {
        switch engine {
        case .claude:
            return (ClaudeCodeModel(rawValue: model) ?? ClaudeCodeModel.allCases[0]).rawValue
        case .codex:
            if codexPicks.contains(model) { return model }
            return codexPicks.first { codexFamily($0) == codexFamily(model) } ?? codexPicks[0]
        case .gemini:
            let picks = DrifterGeminiPicks.shared.ids
            return picks.first { GeminiModelInfo.family($0) == GeminiModelInfo.family(model) } ?? picks[0]
        }
    }
    /// A GPT model's label, made from its ID because Codex's own names mix hyphens and spaces:
    /// `gpt-6.2-sol` reads "GPT-6.2 Sol".
    static func title(_ model: String, engine: DrifterEngine) -> String {
        switch engine {
        case .claude:
            return ClaudeCodeModel(rawValue: model)?.title ?? model
        case .codex:
            let parts = model.split(separator: "-").map(String.init)
            guard parts.count > 1, parts[0].lowercased() == "gpt" else { return model }
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
        case .gemini:
            return DrifterGeminiPicks.shared.models.first { $0.id == model }?.displayName ?? GeminiModelInfo.title(model)
        }
    }
    private static func codexFamily(_ id: String) -> String { id.split(separator: "-").dropFirst(2).joined(separator: "-") }
    /// The picker catalogs and any messages explaining why an engine is unavailable.
    @MainActor static func load(lockedEngine: DrifterEngine? = nil) async
        -> (models: [Self], messages: [DrifterEngine: String]) {
        async let codex = loadCodex(included: lockedEngine == nil || lockedEngine == .codex)
        async let gemini = loadGemini(included: lockedEngine == nil || lockedEngine == .gemini)
        await ClaudeCodeModelCatalog.shared.refreshIfStale()
        let (gpt, gptMessage) = await codex
        let (google, googleMessage) = await gemini
        var messages: [DrifterEngine: String] = [:]
        messages[.codex] = gptMessage
        messages[.gemini] = googleMessage
        return (merged(claude: ClaudeCodeModelCatalog.shared.models, codex: gpt, gemini: google), messages)
    }
    private static func loadCodex(included: Bool) async -> ([CodexModelInfo], String?) {
        guard included else { return ([], nil) }
        do {
            let result = try await CodexModelCatalog.shared.load()
            guard result.account == .chatgpt else { return ([], CodexStrings.loginRequired) }
            DrifterCodexPicks.shared.update(from: result.models)
            return (result.models, nil)
        } catch { return ([], error.localizedDescription) }
    }
    private static func loadGemini(included: Bool) async -> ([GeminiModelInfo], String?) {
        guard included else { return ([], nil) }
        do { return (try await GeminiModelCatalog.shared.load(), nil) }
        catch { return ([], error.localizedDescription) }
    }
    static func geminiModel(_ id: String, displayName: String? = nil) -> Self {
        .init(engine: .gemini, model: id, title: displayName ?? title(id, engine: .gemini),
              efforts: GeminiModelInfo.efforts(id), defaultEffort: GeminiModelInfo.defaultEffort)
    }
    private static func codexModel(_ info: CodexModelInfo) -> Self {
        .init(engine: .codex, model: info.id, title: title(info.id, engine: .codex),
              efforts: info.efforts, defaultEffort: info.defaultEffort)
    }
    static func merged(claude: [String: ClaudeCodeModelInfo], codex: [CodexModelInfo], gemini: [GeminiModelInfo] = []) -> [Self] {
        ClaudeCodeModel.allCases.map {
            Self(engine: .claude, model: $0.rawValue, title: claude[$0.rawValue]?.displayName ?? $0.title,
                 efforts: ClaudeCodeEffort.allCases.map(\.rawValue), defaultEffort: "xhigh")
        } + DrifterCodexPicks.picks(from: codex.map(\.id)).compactMap { pick in
            codex.first { $0.id == pick }.map(codexModel)
        } + GeminiModelInfo.picks(from: gemini).map {
            geminiModel($0.id, displayName: $0.displayName)
        }
    }
}

/// The GPT models Drifter offers, derived from Codex's catalog rather than kept by hand: the newest
/// version of each family (`gpt-6.2-sol` over `gpt-6.1-sol`), Sol, Terra, Astra and Luna first, any
/// other family after them in catalog order. The last list Codex gave is saved, so code that can't
/// wait for the catalog (spawn_agent, Slack prefixes, saved defaults) has it from launch.
final class DrifterCodexPicks: @unchecked Sendable {
    static let familyOrder = ["sol", "terra", "astra", "luna"]
    /// Only until Codex first answers on this Mac, and in tests.
    static let seed = ["gpt-6.2-sol", "gpt-6.1-terra", "gpt-6.2-astra", "gpt-6-luna"]
    static let defaultsKey = "MistDrifter.codexPicks"
    /// Tests keep the seed: a catalog a test loads must not change what later tests see.
    static let shared = DrifterCodexPicks(defaults: .standard, updatesFromCatalog: !isTestRun)
    static var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    private let defaults: UserDefaults
    private let updatesFromCatalog: Bool
    private let lock = NSLock()
    private var stored: [String]
    private var catalog: [CodexModelInfo] = []

    init(defaults: UserDefaults, updatesFromCatalog: Bool = true) {
        self.defaults = defaults
        self.updatesFromCatalog = updatesFromCatalog
        let saved = updatesFromCatalog ? defaults.stringArray(forKey: Self.defaultsKey) ?? [] : []
        stored = saved.isEmpty ? Self.seed : saved
    }

    var ids: [String] { lock.withLock { stored } }
    func model(_ id: String) -> CodexModelInfo? { lock.withLock { catalog.first { $0.id == id } } }

    /// Saves the catalog's picks, writing defaults only when they changed.
    func update(from catalog: [CodexModelInfo]) {
        let next = Self.picks(from: catalog.map(\.id))
        guard updatesFromCatalog, !next.isEmpty else { return }
        let changed = lock.withLock {
            self.catalog = catalog
            guard stored != next else { return false }
            stored = next
            return true
        }
        if changed { defaults.set(next, forKey: Self.defaultsKey) }
    }

    /// Fetches Codex's catalog once at launch, so the saved picks follow a release made while Mist was quit.
    static func preload() {
        guard !isTestRun else { return }
        Task {
            guard let snapshot = try? await CodexModelCatalog.shared.load(), snapshot.account == .chatgpt else { return }
            shared.update(from: snapshot.models)
        }
    }

    /// The newest `gpt-<version>-<family>` of each family, in `familyOrder`, then other families in catalog order.
    static func picks(from catalog: [String]) -> [String] {
        var newest: [String: (id: String, version: [Int])] = [:], families: [String] = []
        for id in catalog {
            let parts = id.split(separator: "-").map(String.init)
            guard parts.count > 2, parts[0] == "gpt" else { continue }
            let version = parts[1].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !version.isEmpty, !version.contains(nil) else { continue }
            let family = parts.dropFirst(2).joined(separator: "-"), numbers = version.compactMap { $0 }
            if let current = newest[family] {
                if current.version.lexicographicallyPrecedes(numbers) { newest[family] = (id, numbers) }
            } else {
                newest[family] = (id, numbers)
                families.append(family)
            }
        }
        let ordered = familyOrder.filter { newest[$0] != nil } + families.filter { !familyOrder.contains($0) }
        return ordered.compactMap { newest[$0]?.id }
    }
}

@MainActor
final class DrifterSettings: ObservableObject {
    @Published private(set) var config: DrifterConfig
    @Published var isEnabled = true
    @Published private(set) var models: [DrifterModel] = []
    @Published private(set) var modelMessages: [DrifterEngine: String] = [:]
    var onChange: ((DrifterConfig) -> Void)?
    /// A launch composer's new-chat defaults, and the defaults it last took.
    private let saved: DrifterLaunchSettings?
    private var savedConfig: DrifterConfig?
    private(set) var lockedEngine: DrifterEngine?

    init(config: DrifterConfig, saved: DrifterLaunchSettings? = nil, running: Bool = false) {
        self.config = config; self.saved = saved
        savedConfig = saved?.config
        lockedEngine = running ? config.engine : nil
        models = DrifterModel.merged(claude: ClaudeCodeModelCatalog.shared.models, codex: [])
    }

    func beginSession() { lockedEngine = config.engine }

    var selectedModel: DrifterModel? { models.first { $0.engine == config.engine && $0.model == config.model } }
    var modelTitle: String { selectedModel?.title ?? DrifterModel.title(config.model, engine: config.engine) }
    var efforts: [String] {
        selectedModel?.efforts ?? (config.engine == .gemini ? GeminiModelInfo.efforts(config.model) : [config.effort])
    }

    /// Takes defaults changed in Settings ▸ Drifter; until they change, this composer's own pick stays.
    func reloadSaved() {
        guard let next = saved?.config, next != savedConfig else { return }
        savedConfig = next
        if config != next { config = next }
    }
    /// A launch composer after its launch: back to the new-chat defaults.
    func resetToSaved() {
        guard let next = saved?.config else { return }
        savedConfig = next
        if config != next { config = next }
    }

    func refreshModels() async {
        let loaded = await DrifterModel.load(lockedEngine: lockedEngine)
        modelMessages = loaded.messages
        models = loaded.models
        if let selectedModel { selectModel(selectedModel) }
    }

    func selectModel(_ model: DrifterModel) {
        guard lockedEngine == nil || lockedEngine == model.engine else { return }
        var next = config
        next.engine = model.engine; next.model = model.model; next.effort = model.effort(config.effort)
        update(next)
    }
    /// Switches like the picker, to a model and effort already checked against the catalog;
    /// false when a running chat's engine is another.
    @discardableResult func select(engine: DrifterEngine, model: String, effort: String) -> Bool {
        guard lockedEngine == nil || lockedEngine == engine else { return false }
        var next = config
        next.engine = engine; next.model = model; next.effort = effort
        update(next)
        return true
    }
    func selectEffort(_ effort: String) {
        guard efforts.contains(effort) else { return }
        var next = config; next.effort = effort; update(next)
    }
    func selectConfirmation(_ confirmation: DrifterConfirmation) {
        var next = config; next.confirmation = confirmation; update(next)
    }
    private func update(_ next: DrifterConfig) {
        guard config != next else { return }
        config = next; onChange?(next)
    }
}
