import Foundation

struct CodexModelInfo: Equatable, Sendable {
    let id: String
    let displayName: String
    let efforts: [String]
    let defaultEffort: String
    let inputModalities: [String]
    let isDefault: Bool
}

enum CodexAccount: Equatable, Sendable {
    case chatgpt, signedOut, other

    static func parse(_ result: CodexJSON) throws -> Self {
        guard case let .object(object) = result, object.keys.contains("account") else { throw CodexError.invalidResponse }
        if result["account"] == .null { return .signedOut }
        guard let type = result["account"]["type"].string else { throw CodexError.invalidResponse }
        return type == "chatgpt" ? .chatgpt : .other
    }
}

enum CodexError: LocalizedError {
    case missingExecutable, chatGPTLoginRequired, invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingExecutable: return CodexStrings.notFound
        case .chatGPTLoginRequired: return CodexStrings.loginRequired
        case .invalidResponse: return CodexStrings.invalidResponse
        }
    }
}

actor CodexModelCatalog {
    struct Snapshot: Equatable, Sendable {
        let models: [CodexModelInfo]
        let account: CodexAccount
    }

    static let shared = CodexModelCatalog()
    private let query: @Sendable () async throws -> Snapshot
    private let clock: @Sendable () -> Date
    private var cached: Task<Snapshot, Error>?
    private var fetchedAt: Date?
    private var refreshing = false

    init(clock: @escaping @Sendable () -> Date = { Date() },
         query: @escaping @Sendable () async throws -> Snapshot = { try await CodexModelCatalog.fetch() }) {
        self.clock = clock
        self.query = query
    }

    /// Coalesces concurrent queries and caches a successful result; a failed query is retried by the next load.
    /// A result over an hour old is still returned at once while a fresh one loads for the next call, so a
    /// model Codex releases while Mist runs reaches the picker without delaying a launch.
    func load() async throws -> Snapshot {
        if let cached {
            if let fetchedAt, clock().timeIntervalSince(fetchedAt) >= 3600, !refreshing { refresh() }
            return try await cached.value
        }
        let task = Task { try await query() }
        cached = task
        do {
            let snapshot = try await task.value
            if cached == task { fetchedAt = clock() }
            return snapshot
        } catch {
            if cached == task { cached = nil }
            throw error
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            defer { refreshing = false }
            guard let snapshot = try? await query() else { return }
            cached = Task { snapshot }
            fetchedAt = clock()
        }
    }

    static func parseModels(_ result: CodexJSON) throws -> [CodexModelInfo] {
        guard case let .array(entries) = result["data"] else { throw CodexError.invalidResponse }
        return try entries.map { value in
            guard let id = value["id"].string, !id.isEmpty,
                  let name = value["displayName"].string, !name.isEmpty,
                  let effort = value["defaultReasoningEffort"].string,
                  case let .array(options) = value["supportedReasoningEfforts"] else { throw CodexError.invalidResponse }
            let efforts = options.compactMap { $0["reasoningEffort"].string }
            guard efforts.count == options.count, !efforts.isEmpty else { throw CodexError.invalidResponse }
            return CodexModelInfo(id: id, displayName: name, efforts: efforts, defaultEffort: effort,
                                  inputModalities: value["inputModalities"].array.compactMap(\.string), isDefault: value["isDefault"].bool)
        }
    }

    private static func fetch() async throws -> Snapshot {
        let process = try await CodexProcess.launch(folder: FileManager.default.temporaryDirectory)
        defer { process.terminate() }
        try await process.initialize()
        let account = try CodexAccount.parse(await process.request("account/read", .object(["refreshToken": .bool(false)])))
        var models: [CodexModelInfo] = [], cursor: CodexJSON = .null
        repeat {
            let result = try await process.request("model/list", .object(["includeHidden": .bool(false), "cursor": cursor]))
            models += try parseModels(result)
            cursor = result["nextCursor"]
        } while cursor != .null
        return Snapshot(models: models, account: account)
    }
}

extension CodexProcess {
    static func launch(folder: URL, environment: ClaudeCodeEnvironment? = nil, request: CodexLaunchRequest? = nil) async throws -> CodexProcess {
        let captured: ClaudeCodeEnvironment
        if let environment { captured = environment }
        else { captured = await ClaudeCodeEnvironment.shared.value }
        return try await Task.detached {
            guard let executable = ClaudeCodeEnvironment.findExecutable(name: "codex", environment: captured.variables,
                home: FileManager.default.homeDirectoryForCurrentUser) else { throw CodexError.missingExecutable }
            return try CodexProcess(executable: executable, arguments: request.map { CodexProtocol.arguments(for: $0) } ?? CodexProtocol.arguments,
                                    folder: folder, environment: captured.variables)
        }.value
    }

    func initialize() async throws {
        _ = try await request("initialize", CodexProtocol.initialize)
        notify("initialized")
    }
}

enum CodexStrings {
    static var notFound: String { NSLocalizedString("browser.codex.notFound", value: "Codex wasn't found. Install it, then try again.", comment: "Codex - CLI not installed") }
    static var loginRequired: String { NSLocalizedString("browser.codex.loginRequired", value: "Log in to Codex with ChatGPT, then try again.", comment: "Codex - ChatGPT login required") }
    static var invalidResponse: String { NSLocalizedString("browser.codex.invalidResponse", value: "Codex returned an invalid response.", comment: "Codex - Invalid protocol response") }
    static var launchFailed: String { NSLocalizedString("browser.codex.launchFailed", value: "Codex couldn't start.", comment: "Codex - Process launch failed") }
    static var exited: String { NSLocalizedString("browser.codex.exited", value: "Codex stopped unexpectedly.", comment: "Codex - Unexpected process exit") }
    static var turnFailed: String { NSLocalizedString("browser.codex.turnFailed", value: "Codex couldn't complete this turn.", comment: "Codex - Failed turn") }
    static var image: String { NSLocalizedString("browser.codex.image", value: "[image]", comment: "Codex - Image tool output placeholder") }
    static var timedOut: String { NSLocalizedString("browser.codex.timedOut", value: "Codex took too long to respond.", comment: "Codex - App-server request timeout") }
}
