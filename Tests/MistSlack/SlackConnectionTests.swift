import Foundation

enum SlackConnectionTests {
    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = directory.appendingPathComponent("defaults").path
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        for (bundle, expected) in [("com.bulldf.mist", true), ("com.bulldf.mist.dev", false), ("com.bulldf.mist.tests", false), ("other", false)] {
            precondition(SlackAgentConnection.defaultAnswer(defaults: defaults, bundleID: bundle) == expected)
        }
        defaults.setVolatileDomain([SlackAgentConnection.answerKey: true], forName: UserDefaults.argumentDomain)
        precondition(SlackAgentConnection.defaultAnswer(defaults: defaults, bundleID: "com.bulldf.mist.dev"))
        defaults.setVolatileDomain([SlackAgentConnection.answerKey: false], forName: UserDefaults.argumentDomain)
        precondition(!SlackAgentConnection.defaultAnswer(defaults: defaults, bundleID: "com.bulldf.mist"))
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)

        let store = SlackThreadStore(url: directory.appendingPathComponent("threads.json"), log: { _ in })
        let earlier = Date(timeIntervalSince1970: 100)
        store.lastConnectedAt = earlier
        var methods: [String] = []
        let api = SlackWebAPI(transport: { method, token, _ in
            methods.append(method)
            let json: String
            switch method {
            case "auth.test": json = #"{"ok":true,"user_id":"\#(token.hasPrefix("xoxp-") ? "U1" : "B1")","team_id":"T1","team":"Team","user":"handle","url":"https://example.invalid/"}"#
            case "apps.connections.open":
                precondition(token.hasPrefix("xapp-"))
                json = #"{"ok":true,"url":"wss://example.invalid"}"#
            default: json = #"{"ok":true}"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let service = MistSlackService(storage: InMemorySlackTokenStorage(tokens: .init(user: "xoxp-fake", bot: "xoxb-fake", app: "xapp-fake")), api: api)
        let socket = FakeSlackSocket()
        var sockets = [socket]
        let termination = Notification.Name("SlackHostlessTerminate-\(UUID())")
        let owner = SlackAgentConnection(service: service, defaults: defaults, bundleID: "com.bulldf.mist", threads: store, connect: { _ in
            if sockets.last!.closed { sockets.append(FakeSlackSocket()) }
            return sockets.last!
        }, terminationNotification: termination, log: { _ in })
        var connected = 0, inbounds: [SlackInbound] = []
        owner.onConnected = { connected += 1 }
        owner.onInbound = { inbounds.append($0) }
        owner.start()
        await SlackSocketTests.until { methods.contains("apps.connections.open") }
        socket.push(#"{"type":"hello","num_connections":2}"#)
        await SlackSocketTests.until { connected == 1 }
        precondition(owner.status == .connected(connections: 2) && owner.previousConnectedAt == earlier)
        precondition(owner.owner == "U1" && owner.botUserID == "B1" && owner.workspaceURL == "https://example.invalid/")
        socket.push(#"{"type":"events_api","envelope_id":"msg","payload":{"team_id":"T1","event_id":"Ev1","event":{"type":"message","user":"U1","channel":"D1","channel_type":"im","ts":"10","text":"hi"}}}"#)
        await SlackSocketTests.until { inbounds.count == 1 }
        precondition(store.lastConnectedAt! > earlier)
        _ = try await owner.botCall("test")
        owner.answerInSlack = false
        precondition(owner.status == .off && socket.closed && owner.workspaceURL == nil)
        precondition(!SlackAgentConnection.defaultAnswer(defaults: defaults, bundleID: "com.bulldf.mist"))
        owner.answerInSlack = true
        await SlackSocketTests.until { sockets.count == 2 }
        precondition(methods.filter { $0 == "auth.test" }.count == 2)
        try service.remove()
        precondition(owner.status == .missingTokens && sockets[1].closed)
        try await service.save(user: "xoxp-new", bot: "xoxb-new", app: "xapp-new")
        await SlackSocketTests.until { sockets.count == 3 }
        precondition(owner.botToken == "xoxb-new")
        NotificationCenter.default.post(name: termination, object: nil)
        precondition(owner.status == .off && sockets.allSatisfy(\.closed))
        precondition(methods.filter { $0 == "auth.test" }.count == 6)
        let missing = SlackAgentConnection(service: MistSlackService(storage: InMemorySlackTokenStorage(), api: api), defaults: defaults, bundleID: "com.bulldf.mist", threads: store, connect: { _ in fatalError() })
        missing.start(); precondition(missing.status == .missingTokens); missing.stop()
    }
}
