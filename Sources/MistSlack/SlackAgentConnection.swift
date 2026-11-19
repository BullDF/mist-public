import Combine
import Foundation

enum SlackAgentConnectionStatus: Equatable {
    case off, missingTokens, connecting, connected(connections: Int), failed(String)
}

@MainActor final class SlackAgentConnection: ObservableObject {
    static let answerKey = "MistSlack.answerInSlack"
    @Published var answerInSlack: Bool {
        didSet {
            defaults.set(answerInSlack, forKey: Self.answerKey)
            if started { reconcile(service.tokens) }
        }
    }
    @Published private(set) var status: SlackAgentConnectionStatus = .off
    let threads: SlackThreadStore
    private(set) var previousConnectedAt: Date?
    private(set) var owner = ""
    private(set) var botUserID = ""
    /// The workspace's own URL from `auth.test`, like `https://example.slack.com/`.
    private(set) var workspaceURL: String?
    var botToken: String? { activeTokens?.bot }
    var onInbound: ((SlackInbound) -> Void)?
    var onConnected: (() -> Void)?

    private let service: MistSlackService
    private let defaults: UserDefaults
    private let connect: (URL) -> SlackSocketConnection
    private let sleep: (UInt64) async throws -> Void
    private let log: (String) -> Void
    private let terminationNotification: Notification.Name?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var activeTokens: SlackTokens?
    private var cachedTokens: SlackTokens?
    private var cachedIdentity: (owner: String, bot: String, team: String, url: String?)?
    private var setup: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var client: SlackSocketModeClient?
    private var revision = UUID()

    init(service: MistSlackService, defaults: UserDefaults, bundleID: String,
         threads: SlackThreadStore, connect: @escaping (URL) -> SlackSocketConnection,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         terminationNotification: Notification.Name? = nil,
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.service = service
        self.defaults = defaults
        self.threads = threads
        self.connect = connect
        self.sleep = sleep
        self.terminationNotification = terminationNotification
        self.log = log
        answerInSlack = Self.defaultAnswer(defaults: defaults, bundleID: bundleID)
    }

    static func defaultAnswer(defaults: UserDefaults, bundleID: String) -> Bool {
        defaults.object(forKey: answerKey) == nil ? bundleID == "com.bulldf.mist" : defaults.bool(forKey: answerKey)
    }

    func start() {
        guard !started else { return }
        started = true
        service.$tokens.removeDuplicates().sink { [weak self] tokens in self?.reconcile(tokens) }.store(in: &subscriptions)
        if let terminationNotification {
            NotificationCenter.default.publisher(for: terminationNotification).sink { [weak self] _ in self?.stop() }.store(in: &subscriptions)
        }
    }

    func stop() {
        started = false
        subscriptions.removeAll()
        disconnect()
        status = .off
    }

    func botCall(_ method: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        guard let botToken, !botToken.isEmpty else { throw SlackAPIError(code: "not_configured") }
        return try await service.api.call(method, token: botToken, parameters)
    }

    private func disconnect() {
        revision = UUID()
        setup?.cancel(); setup = nil
        clock?.cancel(); clock = nil
        client?.stop(); client = nil
        activeTokens = nil
        owner = ""; botUserID = ""; workspaceURL = nil
    }

    private func reconcile(_ tokens: SlackTokens) {
        if answerInSlack, activeTokens == tokens { return }
        disconnect()
        guard answerInSlack else { status = .off; return }
        guard let user = tokens.user, !user.isEmpty, let bot = tokens.bot, !bot.isEmpty,
              let app = tokens.app, !app.isEmpty else { status = .missingTokens; return }
        activeTokens = tokens
        let id = revision
        status = .connecting
        setup = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.revision == id {
                do {
                    let identity: (owner: String, bot: String, team: String, url: String?)
                    if self.cachedTokens == tokens, let cached = self.cachedIdentity { identity = cached }
                    else {
                        let userResult = try await self.service.api.call("auth.test", token: user)
                        let botResult = try await self.service.api.call("auth.test", token: bot)
                        guard let owner = userResult["user_id"] as? String, !owner.isEmpty,
                              let botID = botResult["user_id"] as? String, !botID.isEmpty,
                              let team = userResult["team_id"] as? String, !team.isEmpty else { throw SlackAPIError(code: "invalid_response") }
                        identity = (owner, botID, team, (userResult["url"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil })
                    }
                    guard !Task.isCancelled, self.revision == id else { return }
                    self.cachedTokens = tokens; self.cachedIdentity = identity
                    self.owner = identity.owner; self.botUserID = identity.bot; self.workspaceURL = identity.url
                    let router = SlackEventRouter(owner: identity.owner, botUserID: identity.bot, teamID: identity.team)
                    let client = SlackSocketModeClient(open: {
                        let result = try await self.service.api.call("apps.connections.open", token: app)
                        guard let raw = result["url"] as? String, let url = URL(string: raw), url.scheme == "wss" else { throw SlackAPIError(code: "invalid_response") }
                        return url
                    }, connect: self.connect, sleep: self.sleep, onEnvelope: { [weak self] envelope in
                        guard let self, self.revision == id else { return }
                        let routed = router.route(envelope)
                        let payload = envelope["payload"] as? [String: Any]
                        let kind = (payload?["event"] as? [String: Any])?["type"] as? String ?? payload?["type"] as? String ?? "?"
                        self.log("slack: \(envelope["type"] as? String ?? "?") \(kind) routed \(routed.map(\.logKind))")
                        for inbound in routed {
                            self.threads.lastConnectedAt = Date()
                            if let handler = self.onInbound { handler(inbound) }
                            else { self.log("slack: dropped inbound \(inbound.logKind)") }
                        }
                    })
                    client.onState = { [weak self] state in
                        guard let self, self.revision == id else { return }
                        self.socketStateChanged(state)
                    }
                    self.client = client
                    client.start()
                    return
                } catch {
                    guard !Task.isCancelled, self.revision == id else { return }
                    let code = (error as? SlackAPIError)?.code ?? "network"
                    self.status = .failed(code)
                    self.log("slack: identity failed \(code)")
                    do { try await self.sleep(60_000_000_000) } catch { return }
                    guard !Task.isCancelled, self.revision == id else { return }
                    self.status = .connecting
                }
            }
        }
    }

    private func socketStateChanged(_ state: SlackSocketState) {
        log("slack: socket \(state)")
        clock?.cancel(); clock = nil
        switch state {
        case .off: status = .off
        case .connecting: status = .connecting
        case .failed(let code): status = .failed(code)
        case .connected(let count):
            previousConnectedAt = threads.lastConnectedAt
            threads.lastConnectedAt = Date()
            status = .connected(connections: count)
            clock = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled {
                        try await self.sleep(60_000_000_000)
                        try Task.checkCancellation()
                        self.threads.lastConnectedAt = Date()
                    }
                } catch {}
            }
            onConnected?()
        }
    }
}
