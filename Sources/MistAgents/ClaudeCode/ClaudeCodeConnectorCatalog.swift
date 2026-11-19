import Foundation

@MainActor
final class ClaudeCodeConnectorCatalog {
    static let shared = ClaudeCodeConnectorCatalog()
    private static let cacheKey = "MistClaudeCode.connectorCatalog"
    private struct Cache: Codable {
        let connectors: [String: ClaudeCodeConnector]
        let fetchedAt: Date
    }
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let query: (ClaudeCodeEnvironment) async throws -> [String: ClaudeCodeConnector]
    private var cache: Cache?
    private var lastAttempt: Date?
    private var refresh: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         query: @escaping (ClaudeCodeEnvironment) async throws -> [String: ClaudeCodeConnector] = ClaudeCodeConnectorCatalog.fetch) {
        self.defaults = defaults; self.clock = clock; self.query = query
        cache = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
    }

    func load(environment: ClaudeCodeEnvironment) async -> [String: ClaudeCodeConnector] {
        let hadCache = cache != nil
        if refresh == nil, lastAttempt.map({ clock().timeIntervalSince($0) >= 3600 }) ?? true {
            lastAttempt = clock()
            refresh = Task {
                defer { refresh = nil }
                do {
                    let result = try await query(environment)
                    let fetched = Cache(connectors: result, fetchedAt: clock())
                    defaults.set(try JSONEncoder().encode(fetched), forKey: Self.cacheKey)
                    cache = fetched
                } catch { /* A failed discovery retains the previous cache. */ }
            }
        }
        if !hadCache { await refresh?.value }
        return cache?.connectors ?? [:]
    }

    nonisolated private static func fetch(environment: ClaudeCodeEnvironment) async throws -> [String: ClaudeCodeConnector] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mist-connector-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try ClaudeCodeProtocol.connectors(from: await ClaudeCodeInitializeProbe.fetch(folder: folder, connectors: true, environment: environment))
    }
}
