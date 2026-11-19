import Combine
import Foundation
import OSLog

@MainActor
final class ClaudeCodeModelCatalog: ObservableObject {
    static let shared = ClaudeCodeModelCatalog()
    private static let cacheKey = "MistClaudeCode.modelCatalog"
    private static let logger = Logger(subsystem: "com.bulldf.mist", category: "ClaudeCodeModelCatalog")

    @Published private(set) var models: [String: ClaudeCodeModelInfo]
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let query: () async throws -> [String: ClaudeCodeModelInfo]
    private var lastAttempt: Date?
    private var refreshing = false

    private struct Cache: Codable {
        let models: [String: ClaudeCodeModelInfo]
        let fetchedAt: Date
    }

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         query: @escaping () async throws -> [String: ClaudeCodeModelInfo] = ClaudeCodeModelCatalog.fetch) {
        self.defaults = defaults
        self.clock = clock
        self.query = query
        models = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }?.models ?? [:]
    }

    func displayName(for model: ClaudeCodeModel) -> String {
        models[model.rawValue]?.displayName ?? model.title
    }

    func refreshIfStale() async {
        let now = clock()
        // An in-memory attempt date guarantees one refresh per run, even with a fresh cache.
        guard !refreshing, lastAttempt.map({ now.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        refreshing = true
        lastAttempt = now
        defer { refreshing = false }
        do {
            let result = try await query()
            guard !result.isEmpty else { throw QueryError.invalidResponse }
            let cache = try JSONEncoder().encode(Cache(models: result, fetchedAt: clock()))
            defaults.set(cache, forKey: Self.cacheKey)
            models = result
        } catch {
            Self.logger.debug("Could not refresh Claude Code models: \(error.localizedDescription, privacy: .public)")
        }
    }

    private enum QueryError: Error { case invalidResponse }

    nonisolated private static func fetch() async throws -> [String: ClaudeCodeModelInfo] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mist-model-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try ClaudeCodeProtocol.models(from: await ClaudeCodeInitializeProbe.fetch(folder: folder))
    }
}
