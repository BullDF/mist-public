import Foundation

private final class FakeTransport {
    struct Call { let method: String; let token: String; let parameters: [String: String] }
    var calls: [Call] = []
    var replies: [(String, Int, [String: String])] = []
    var error: Error?
    var delays: [UInt64] = []
    lazy var api = SlackWebAPI(transport: { method, token, parameters in
        self.calls.append(Call(method: method, token: token, parameters: parameters))
        if let error = self.error { throw error }
        if method == "users.info" {
            return (Data(#"{"ok":true,"user":{}}"#.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        precondition(!self.replies.isEmpty, "Unexpected request")
        let (body, status, headers) = self.replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid")!,
                                               statusCode: status, httpVersion: nil, headerFields: headers)!)
    }, sleep: { self.delays.append($0) })

    func reply(_ body: String = #"{"ok":true}"#, status: Int = 200, headers: [String: String] = [:]) {
        replies.append((body, status, headers))
    }

    func identity(user: String = "johnny") {
        reply(#"{"ok":true,"team":"Acme","team_id":"T1","url":"https://example.invalid/","user":"\#(user)","user_id":"U1"}"#)
    }
}

private final class FailingStorage: SlackTokenStorage {
    var failLoad = false
    func load() throws -> SlackTokens? {
        if failLoad { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
        return nil
    }
    func save(_ tokens: SlackTokens) throws { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
    func delete() throws { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
}

@main private struct MistSlackTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String = #function) {
        precondition(value(), message)
    }

    @MainActor static func apiError(_ expected: SlackAPIError, _ action: () async throws -> Void) async {
        do { try await action(); fatalError("Expected \(expected)") }
        catch { expect(error as? SlackAPIError == expected, "Unexpected error: \(error)") }
    }

    @MainActor static func main() async throws {
        SlackMrkdwnTests.run()
        try SlackEventTests.run()
        try await SlackSocketTests.run()
        try await SlackConnectionTests.run()
        try await SlackDisplayNameTests.run()
        try await SlackMCPTests.run()
        await SlackDirectoryTests.run()
        for kind in [SlackTokenKind.user, .bot, .app] {
            expect(SlackTokens.isValid(kind.prefix + "abc", kind: kind))
            for value in [kind.prefix, "wrong-abc", kind.prefix + "a b", kind.prefix + "a\nb", kind.prefix + "a\u{00a0}b"] {
                expect(!SlackTokens.isValid(value, kind: kind))
            }
            let other: SlackTokenKind = kind == .user ? .bot : .user
            expect(!SlackTokens.isValid(other.prefix + "abc", kind: kind))
        }
        expect(SlackKeychain.service(bundleID: "com.bulldf.mist") == "Mist Slack")
        expect(SlackKeychain.service(bundleID: "com.bulldf.mist.dev") == "Mist Slack (com.bulldf.mist.dev)")

        for (body, status, code) in [(#"{"ok":false,"error":"missing_scope"}"#, 200, "missing_scope"),
                                     (#"{"ok":false}"#, 200, "unknown_error"),
                                     ("oops", 503, "http_503"), ("oops", 200, "invalid_response"),
                                     ("[]", 200, "invalid_response")] {
            let fake = FakeTransport()
            fake.reply(body, status: status)
            await apiError(SlackAPIError(code: code)) { _ = try await fake.api.call("test", token: "fake") }
        }
        let network = FakeTransport()
        network.error = URLError(.notConnectedToInternet)
        await apiError(SlackAPIError(code: "network")) { _ = try await network.api.call("test", token: "fake") }
        network.error = CancellationError()
        do { _ = try await network.api.call("test", token: "fake"); fatalError("Expected cancellation") }
        catch is CancellationError {} catch { fatalError("Cancellation was changed") }

        let retry = FakeTransport()
        retry.reply(status: 429, headers: ["Retry-After": "2"])
        retry.reply()
        _ = try await retry.api.call("test", token: "fake", ["cursor": "next"])
        expect(retry.delays == [2_000_000_000] && retry.calls.count == 2)
        expect(retry.calls.allSatisfy { $0.method == "test" && $0.token == "fake" && $0.parameters == ["cursor": "next"] })
        let twice = FakeTransport()
        twice.reply(status: 429, headers: ["Retry-After": "2"])
        twice.reply(status: 429, headers: ["Retry-After": "3"])
        await apiError(SlackAPIError(code: "ratelimited", retryAfter: 3)) { _ = try await twice.api.call("test", token: "fake") }
        expect(twice.delays == [2_000_000_000] && twice.calls.count == 2)
        let long = FakeTransport()
        long.reply(status: 429, headers: ["Retry-After": "120"])
        await apiError(SlackAPIError(code: "ratelimited", retryAfter: 120)) { _ = try await long.api.call("test", token: "fake") }
        expect(long.delays.isEmpty && long.calls.count == 1)
        let defaultDelay = FakeTransport()
        defaultDelay.reply(status: 429)
        defaultDelay.reply()
        _ = try await defaultDelay.api.call("test", token: "fake")
        expect(defaultDelay.delays == [5_000_000_000])

        let fake = FakeTransport()
        let storage = InMemorySlackTokenStorage()
        let service = MistSlackService(storage: storage, api: fake.api)
        expect(fake.calls.isEmpty && !service.isConfigured)
        await apiError(SlackAPIError(code: "not_configured")) { _ = try await service.userCall("test") }
        await apiError(SlackAPIError(code: "invalid_token_format")) { try await service.save(user: "xoxb-wrong", bot: "", app: "") }
        await apiError(SlackAPIError(code: "missing_user_token")) { try await service.save(user: "", bot: "xoxb-test", app: "") }
        expect(fake.calls.isEmpty && storage.tokens == nil)
        fake.reply(#"{"ok":false,"error":"invalid_auth"}"#)
        await apiError(SlackAPIError(code: "invalid_auth")) { try await service.save(user: "xoxp-test", bot: "", app: "") }
        expect(storage.tokens == nil && service.identity == nil)
        fake.identity()
        fake.reply(#"{"ok":false,"error":"invalid_auth"}"#)
        await apiError(SlackAPIError(code: "invalid_auth")) { try await service.save(user: "xoxp-test", bot: "xoxb-test", app: "") }
        expect(storage.tokens == nil && service.identity == nil)
        fake.identity()
        fake.identity(user: "drifter")
        try await service.save(user: " xoxp-test\n", bot: "xoxb-test", app: "xapp-test")
        expect(storage.tokens == SlackTokens(user: "xoxp-test", bot: "xoxb-test", app: "xapp-test"))
        expect(service.identity == SlackIdentity(team: "Acme", teamID: "T1", url: "https://example.invalid/", user: "johnny", userID: "U1", displayName: "johnny", bot: "drifter"))
        expect(fake.calls.filter { $0.method == "auth.test" }.suffix(2).map(\.token) == ["xoxp-test", "xoxb-test"])
        expect(fake.calls.allSatisfy { ["auth.test", "users.info"].contains($0.method) })
        let before = fake.calls.count
        fake.identity()
        try await service.save(user: "", bot: "  ", app: "")
        expect(fake.calls.count == before + 2 && storage.tokens == service.tokens && service.tokens.app == "xapp-test")
        fake.reply()
        _ = try await service.userCall("conversations.list", ["limit": "10"])
        expect(fake.calls.last?.token == "xoxp-test" && fake.calls.last?.parameters == ["limit": "10"])
        fake.identity()
        fake.identity(user: "drifter")
        await service.refreshIdentity()
        expect(service.identity?.bot == "drifter" && service.lastError == nil)
        try service.remove()
        expect(storage.tokens == nil && service.tokens == SlackTokens() && service.identity == nil && service.lastError == nil)
        let removedCount = fake.calls.count
        await service.refreshIdentity()
        expect(fake.calls.count == removedCount)

        let broken = FailingStorage()
        broken.failLoad = true
        let failed = MistSlackService(storage: broken, api: fake.api)
        expect(!failed.isConfigured && failed.lastError != nil)
        fake.identity()
        do { try await failed.save(user: "xoxp-test", bot: "", app: ""); fatalError("Expected storage error") }
        catch { expect((error as NSError).domain == NSOSStatusErrorDomain) }
        expect(failed.identity?.team == "Acme" && !failed.isConfigured && failed.lastError != nil)

        for code in ["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"] {
            expect(SlackWebAPI.message(SlackAPIError(code: code)) == "Slack rejected Mist's token. Johnny can check Settings ▸ Slack.")
        }
        for (error, message) in [
            (SlackAPIError(code: "missing_scope"), "The Drifter Slack app lacks a permission this needs (missing_scope)."),
            (SlackAPIError(code: "ratelimited", retryAfter: 2), "Slack is rate-limiting Mist; try again in 2 seconds."),
            (SlackAPIError(code: "ratelimited"), "Slack is rate-limiting Mist; try again in a minute."),
            (SlackAPIError(code: "network"), "Mist can't reach Slack."),
            (SlackAPIError(code: "not_configured"), "Slack isn't set up in Mist. Johnny adds the tokens in Settings ▸ Slack."),
            (SlackAPIError(code: "other"), "Slack error: other")
        ] { expect(SlackWebAPI.message(error) == message) }
        print("Mist Slack tests passed")
    }
}
