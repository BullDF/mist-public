import Combine
import Foundation

struct SlackIdentity: Equatable {
    let team: String
    let teamID: String
    let url: String
    let user: String
    let userID: String
    let displayName: String
    var bot: String?
}

@MainActor final class MistSlackService: ObservableObject {
    @Published private(set) var tokens = SlackTokens()
    @Published private(set) var identity: SlackIdentity?
    @Published private(set) var lastError: Error?
    let api: SlackWebAPI
    private let storage: SlackTokenStorage
    private var identityRevision = 0

    init(storage: SlackTokenStorage, api: SlackWebAPI) {
        self.storage = storage
        self.api = api
        do { tokens = try storage.load() ?? SlackTokens() }
        catch { lastError = error }
    }

    var userToken: String? { tokens.user }
    var isConfigured: Bool { userToken?.isEmpty == false }

    func userCall(_ method: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        guard isConfigured, let token = userToken else { throw SlackAPIError(code: "not_configured") }
        return try await api.call(method, token: token, parameters)
    }

    func save(user: String, bot: String, app: String) async throws {
        var merged = tokens
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let bot = bot.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        for (value, kind) in [(user, SlackTokenKind.user), (bot, .bot), (app, .app)] where !value.isEmpty {
            guard SlackTokens.isValid(value, kind: kind) else { throw SlackAPIError(code: "invalid_token_format") }
        }
        if !user.isEmpty { merged.user = user }
        if !bot.isEmpty { merged.bot = bot }
        if !app.isEmpty { merged.app = app }
        guard let userToken = merged.user, !userToken.isEmpty else { throw SlackAPIError(code: "missing_user_token") }
        let result = try await api.call("auth.test", token: userToken)
        var botName = identity?.bot
        if !bot.isEmpty { botName = try await api.call("auth.test", token: bot)["user"] as? String }
        let displayName = await displayName(from: result, token: userToken)
        let validated = try Self.identity(from: result, bot: botName, displayName: displayName)
        identityRevision += 1
        identity = validated
        do {
            try storage.save(merged)
            tokens = merged
            lastError = nil
        } catch {
            lastError = error
            throw error
        }
    }

    func refreshIdentity() async {
        guard isConfigured, let userToken else { return }
        let revision = identityRevision
        let stored = tokens
        do {
            let result = try await api.call("auth.test", token: userToken)
            var botName: String?
            if let bot = stored.bot { botName = try await api.call("auth.test", token: bot)["user"] as? String }
            let displayName = await displayName(from: result, token: userToken)
            let refreshed = try Self.identity(from: result, bot: botName, displayName: displayName)
            guard revision == identityRevision else { return }
            identity = refreshed
            lastError = nil
        } catch {
            guard revision == identityRevision else { return }
            lastError = error
        }
    }

    func remove() throws {
        try storage.delete()
        identityRevision += 1
        tokens = SlackTokens()
        identity = nil
        lastError = nil
    }

    private func displayName(from result: [String: Any], token: String) async -> String {
        let handle = result["user"] as? String ?? ""
        guard let id = result["user_id"] as? String,
              let info = try? await api.call("users.info", token: token, ["user": id]),
              let user = info["user"] as? [String: Any] else { return handle }
        let profile = user["profile"] as? [String: Any] ?? [:]
        for candidate in [profile["display_name"], profile["real_name"], user["real_name"]] {
            if let name = candidate as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        }
        return handle
    }

    private static func identity(from result: [String: Any], bot: String?, displayName: String) throws -> SlackIdentity {
        guard let team = result["team"] as? String, let teamID = result["team_id"] as? String,
              let url = result["url"] as? String, let user = result["user"] as? String,
              let userID = result["user_id"] as? String else { throw SlackAPIError(code: "invalid_response") }
        return SlackIdentity(team: team, teamID: teamID, url: url, user: user, userID: userID, displayName: displayName, bot: bot)
    }
}
