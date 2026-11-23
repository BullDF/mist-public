import Foundation

struct GeminiModelInfo: Equatable, Sendable {
    let id: String
    let displayName: String

    static let families = ["neon", "carbon", "argon", "hydrogen", "flash"]
    private static let excluded = ["image", "tts", "live", "transcribe", "embedding", "customtools",
                                   "audio", "video", "computer-use", "robotics", "omni", "nano-banana"]
    static let defaultEffort = "high"
    static func family(_ id: String) -> String {
        let family = id.split(separator: "-").dropFirst(2).joined(separator: "-")
        return family.hasSuffix("-preview") ? String(family.dropLast("-preview".count)) : family
    }
    static func efforts(_ id: String) -> [String] {
        switch family(id) {
        case "neon", "hydrogen": ["low", "medium", "high", "xhigh", "max"]
        case "carbon", "argon", "flash": ["low", "medium", "high", "max"]
        default: ["low", "medium", "high"]
        }
    }
    static func title(_ id: String) -> String {
        id.hasPrefix("gemini-") ? id.split(separator: "-").map(\.capitalized).joined(separator: " ") : id
    }
    static func picks(from catalog: [Self]) -> [Self] {
        var newest: [String: (model: Self, version: [Int])] = [:]
        var order: [String] = []
        for model in catalog {
            let parts = model.id.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "gemini", !excluded.contains(where: model.id.contains) else { continue }
            let version = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            var numbers = version.compactMap { part in
                part.utf8.allSatisfy { (48...57).contains($0) } ? Int(part) : nil
            }
            let family = Self.family(model.id)
            guard !numbers.isEmpty, version.count == numbers.count, !family.isEmpty else { continue }
            while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
            if let existing = newest[family] {
                let replacesPreview = numbers == existing.version && existing.model.id.hasSuffix("-preview") && !model.id.hasSuffix("-preview")
                guard replacesPreview || existing.version.lexicographicallyPrecedes(numbers) else { continue }
            } else { order.append(family) }
            newest[family] = (model, numbers)
        }
        let extraFamilies = order.filter { !families.contains($0) && (newest[$0]?.version.first ?? 0) >= 4 }
        return (families + extraFamilies).compactMap { newest[$0]?.model }
    }
}

final class DrifterGeminiPicks: @unchecked Sendable {
    static let seed = ["gemini-4-neon", "gemini-4-carbon", "gemini-4-argon", "gemini-4-hydrogen", "gemini-3.8-flash"]
    static let defaultsKey = "MistDrifter.geminiPicks"
    static let shared = DrifterGeminiPicks(defaults: .standard, updatesFromCatalog: !DrifterCodexPicks.isTestRun)

    private let defaults: UserDefaults
    private let updatesFromCatalog: Bool
    private let lock = NSLock()
    private var stored: [GeminiModelInfo]

    init(defaults: UserDefaults, updatesFromCatalog: Bool = true) {
        self.defaults = defaults
        self.updatesFromCatalog = updatesFromCatalog
        let saved = updatesFromCatalog ? defaults.stringArray(forKey: Self.defaultsKey) ?? [] : []
        let usable = GeminiModelInfo.picks(from: saved.map { .init(id: $0, displayName: GeminiModelInfo.title($0)) })
        stored = usable.isEmpty ? Self.seed.map { .init(id: $0, displayName: GeminiModelInfo.title($0)) } : usable
    }

    var models: [GeminiModelInfo] { lock.withLock { stored } }
    var ids: [String] { models.map(\.id) }

    func update(from catalog: [GeminiModelInfo]) {
        let next = GeminiModelInfo.picks(from: catalog)
        guard updatesFromCatalog, !next.isEmpty else { return }
        let ids = next.map(\.id)
        let changed = lock.withLock {
            let changed = stored.map(\.id) != ids
            stored = next
            return changed
        }
        if changed { defaults.set(ids, forKey: Self.defaultsKey) }
    }

    static func preload() {
        guard !DrifterCodexPicks.isTestRun else { return }
        Task { _ = try? await GeminiModelCatalog.shared.load() }
    }
}

actor GeminiModelCatalog {
    static let shared = GeminiModelCatalog()
    private var currentKey: String?
    private var cached: Task<[GeminiModelInfo], Error>?
    private var fetchedAt: Date?
    private var refresh: Task<Void, Never>?

    func load() async throws -> [GeminiModelInfo] {
        let environment = await ClaudeCodeEnvironment.shared.value
        let home = DrifterHome.current.folder
        guard let key = GeminiEnvironment.key(in: home) else {
            reset(key: nil)
            throw GeminiError.missingKey(GeminiEnvironment.envFile(in: home))
        }
        guard Self.executable(in: environment.variables) != nil else { throw GeminiError.missingExecutable }
        if currentKey != key { reset(key: key) }
        if let cached {
            if let fetchedAt, Date().timeIntervalSince(fetchedAt) >= 3600, refresh == nil {
                refresh = Task {
                    let models = try? await Self.fetch(key: key)
                    guard !Task.isCancelled else { return }
                    defer { refresh = nil }
                    guard let models else { return }
                    self.cached = Task { models }
                    self.fetchedAt = Date()
                    DrifterGeminiPicks.shared.update(from: models)
                }
            }
            if let models = try? await cached.value { return models }
            return DrifterGeminiPicks.shared.models
        }
        let task = Task { try await Self.fetch(key: key) }
        cached = task
        do {
            let models = try await task.value
            if cached == task {
                fetchedAt = Date()
                DrifterGeminiPicks.shared.update(from: models)
            }
            return models
        } catch {
            if cached == task { cached = nil }
            // An offline picker can still use the last offered models.
            return DrifterGeminiPicks.shared.models
        }
    }

    private func reset(key: String?) {
        currentKey = key
        cached?.cancel()
        refresh?.cancel()
        cached = nil; fetchedAt = nil; refresh = nil
    }

    static func executable(in environment: [String: String]) -> URL? {
        ClaudeCodeEnvironment.findExecutable(name: "gemini", environment: environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func parse(_ data: Data) throws -> [GeminiModelInfo] {
        struct Page: Decodable {
            struct Model: Decodable {
                let name: String
                let displayName: String?
                let thinking: Bool?
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]
        }
        return try JSONDecoder().decode(Page.self, from: data).models.compactMap { model in
            guard model.name.hasPrefix("models/"), model.thinking == true,
                  model.supportedGenerationMethods?.contains("generateContent") == true else { return nil }
            let id = String(model.name.dropFirst("models/".count))
            return .init(id: id, displayName: model.displayName ?? GeminiModelInfo.title(id))
        }
    }

    private static func fetch(key: String) async throws -> [GeminiModelInfo] {
        let models = GeminiModelInfo.picks(from: try parse(await APIClient.shared.geminiModels(key: key)))
        return models.isEmpty ? DrifterGeminiPicks.shared.models : models
    }
}

enum GeminiError: LocalizedError {
    case missingKey(URL), missingExecutable, launchFailed, invalidResponse, turnFailed, exited

    var errorDescription: String? {
        switch self {
        case let .missingKey(file):
            String(format: NSLocalizedString("browser.gemini.missingKey", value: "Add GEMINI_API_KEY= to %@.",
                comment: "Gemini - API key required, %@ is the path to the .env file"), file.path)
        case .missingExecutable:
            NSLocalizedString("browser.gemini.notFound", value: "Gemini CLI wasn't found. Install it with brew install gemini-cli.",
                comment: "Gemini - CLI not installed, keep the terminal command in English")
        case .launchFailed:
            NSLocalizedString("browser.gemini.launchFailed", value: "Gemini couldn't start.", comment: "Gemini - Process launch failed")
        case .invalidResponse:
            NSLocalizedString("browser.gemini.invalidResponse", value: "Gemini returned an invalid response.", comment: "Gemini - Invalid protocol response")
        case .turnFailed:
            NSLocalizedString("browser.gemini.turnFailed", value: "Gemini couldn't complete this turn.", comment: "Gemini - Failed turn")
        case .exited:
            NSLocalizedString("browser.gemini.exited", value: "Gemini stopped unexpectedly.", comment: "Gemini - Unexpected process exit")
        }
    }
}
