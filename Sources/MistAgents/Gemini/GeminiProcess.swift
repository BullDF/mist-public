import Foundation

/// JSON-RPC 2.0 over Gemini CLI's ACP stdio transport.
struct GeminiProcess: Sendable {
    let transport: CodexProcess
    private let cliHome: URL
    private let aliasedModels: Set<String>

    static func launch(_ request: GeminiLaunchRequest, environment: ClaudeCodeEnvironment,
                       readKey: @escaping @Sendable (URL) -> String? = { GeminiEnvironment.key(in: $0) }) async throws -> Self {
        try await Task.detached {
            guard let key = readKey(request.drifterHome) else {
                throw GeminiError.missingKey(GeminiEnvironment.envFile(in: request.drifterHome))
            }
            guard let executable = GeminiModelCatalog.executable(in: environment.variables) else { throw GeminiError.missingExecutable }
            do {
                let models = DrifterGeminiPicks.shared.ids + [request.model]
                try request.prepareHome(models: models)
                try GeminiLaunchRequest.writeSelection(model: request.model, effort: request.effort, in: request.cliHome)
                var variables = GeminiEnvironment.variables(environment.variables, key: key, cliHome: request.cliHome)
                variables["NODE_OPTIONS"] = [variables["NODE_OPTIONS"], "--import=" + request.preload.absoluteString]
                    .compactMap { $0 }.joined(separator: " ")
                let transport = try CodexProcess(executable: executable, arguments: [
                    "--acp", "--approval-mode", "default", "--extensions", "none",
                    "--allowed-mcp-server-names", GeminiProtocol.serverName,
                    "--include-directories", "/",
                    "--model", GeminiProtocol.alias(model: request.model, effort: request.effort),
                ], folder: request.cwd, environment: variables, wire: .acp)
                return Self(transport: transport, cliHome: request.cliHome, aliasedModels: Set(models))
            } catch { throw GeminiError.launchFailed }
        }.value
    }

    func initialize() async throws -> Bool {
        let info = try await transport.request("initialize", GeminiProtocol.initialize)
        guard info["protocolVersion"] == .number(1),
              info["authMethods"].array.contains(where: { $0["id"].string == GeminiProtocol.authMethod }) else {
            throw GeminiError.invalidResponse
        }
        _ = try await transport.request("authenticate", .object(["methodId": .string(GeminiProtocol.authMethod)]))
        return info["agentCapabilities"]["promptCapabilities"]["image"].bool
    }

    func open(_ request: GeminiLaunchRequest, resumeId: String?) async throws -> String {
        let params = GeminiProtocol.session(cwd: request.cwd, server: request.server, id: resumeId)
        let result = try await transport.request(resumeId == nil ? "session/new" : "session/load", params)
        guard let id = resumeId ?? result["sessionId"].string, !id.isEmpty else { throw GeminiError.invalidResponse }
        return id
    }

    func select(sessionId: String, model: String, effort: String) async throws {
        // A catalog refresh can offer a model that was released after this process started.
        let modelId = aliasedModels.contains(model) ? GeminiProtocol.alias(model: model, effort: effort) : model
        _ = try await transport.request("session/set_model", .object([
            "sessionId": .string(sessionId), "modelId": .string(modelId),
        ]))
        try GeminiLaunchRequest.writeSelection(model: model, effort: effort, in: cliHome)
    }

    func cancel(sessionId: String) {
        transport.notify("session/cancel", .object(["sessionId": .string(sessionId)]))
    }
}
