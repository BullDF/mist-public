import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeModelCatalogTests: XCTestCase {
    func testMCPStatusParsesConnectorsRegardlessOfAuthenticationStatus() throws {
        let request = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(ClaudeCodeProtocol.mcpStatus(requestId: "status").utf8))
        XCTAssertEqual(request["request"]["subtype"].string, "mcp_status")
        let line = Data(#"{"type":"control_response","response":{"request_id":"status","subtype":"success","response":{"mcpServers":[{"name":"claude.ai Slack","status":"needs-auth","config":{"type":"claudeai-proxy","url":"https://mcp.slack.com/mcp","id":"account-id"}},{"name":"local","config":{"type":"stdio"}}]}}}"#.utf8)
        let response = try XCTUnwrap(ClaudeCodeProtocol.controlResponse(from: line, requestId: "status"))
        XCTAssertEqual(ClaudeCodeProtocol.connectors(from: response["response"]), ["claude.ai Slack": .init(url: "https://mcp.slack.com/mcp", id: "account-id")])
        XCTAssertNil(try ClaudeCodeProtocol.controlResponse(from: line, requestId: "unrelated"))
    }

    @MainActor
    func testConnectorCacheAcceptsEmptyFetchAndKeepsCacheOnFailure() async throws {
        let environment = ClaudeCodeEnvironment(variables: [:], executable: nil)
        var calls = 0
        var now = Date()
        let catalog = ClaudeCodeConnectorCatalog(defaults: defaults, clock: { now }, query: { _ in
            calls += 1
            if calls > 1 { throw CocoaError(.fileNoSuchFile) }
            return [:]
        })
        let first = await catalog.load(environment: environment)
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(calls, 1)
        let data = try XCTUnwrap(defaults.data(forKey: "MistClaudeCode.connectorCatalog"))
        _ = await catalog.load(environment: environment)
        XCTAssertEqual(calls, 1)
        now.addTimeInterval(3600)
        _ = await catalog.load(environment: environment)
        for _ in 0..<100 where calls < 2 { await Task.yield() }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.connectorCatalog"), data)
    }

    @MainActor
    func testConnectorFirstLoadWaitsAndCachedLoadReturnsImmediately() async throws {
        let environment = ClaudeCodeEnvironment(variables: [:], executable: nil)
        let connectors = ["claude.ai Slack": ClaudeCodeConnector(url: "https://mcp.slack.com/mcp", id: "id")]
        var finish: CheckedContinuation<[String: ClaudeCodeConnector], Error>?
        let catalog = ClaudeCodeConnectorCatalog(defaults: defaults, query: { _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        })
        let first = Task { await catalog.load(environment: environment) }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        try XCTUnwrap(finish).resume(returning: connectors)
        let fetched = await first.value
        XCTAssertEqual(fetched, connectors)
        var refresh: CheckedContinuation<[String: ClaudeCodeConnector], Error>?
        let reloaded = ClaudeCodeConnectorCatalog(defaults: defaults, query: { _ in
            try await withCheckedThrowingContinuation { refresh = $0 }
        })
        let cached = await reloaded.load(environment: environment)
        XCTAssertEqual(cached, connectors)
        for _ in 0..<100 where refresh == nil { await Task.yield() }
        try XCTUnwrap(refresh).resume(throwing: CocoaError(.fileNoSuchFile))
    }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        (defaults, suite) = makeTestDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func fixture() throws -> (data: Data, requestId: String) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeCode/initialize.jsonl")
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(ClaudeCodeJSON.self, from: data)
        return (data, try XCTUnwrap(value["response"]["request_id"].string))
    }

    private func fixtureModels() throws -> [String: ClaudeCodeModelInfo] {
        let fixture = try fixture()
        return try XCTUnwrap(ClaudeCodeProtocol.modelCatalog(from: fixture.data, requestId: fixture.requestId))
    }

    func testInitializeRequestEncoding() throws {
        let line = ClaudeCodeProtocol.initialize(requestId: "initialize-test")
        let value = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(line.utf8))
        XCTAssertEqual(value, .object([
            "type": .string("control_request"), "request_id": .string("initialize-test"),
            "request": .object(["subtype": .string("initialize")]),
        ]))
    }

    func testRealInitializeFixtureResolvesOnlyLaunchAliases() throws {
        let models = try fixtureModels()
        XCTAssertEqual(Set(models.keys), Set(ClaudeCodeModel.allCases.map(\.rawValue)))
        for (alias, resolved, title) in [
            ("opus", "claude-opus-5-5", "Opus 5.5"),
            ("fable", "claude-fable-5-1", "Fable 5.1"),
            ("sonnet", "claude-sonnet-5-5", "Sonnet 5.5"),
        ] {
            XCTAssertEqual(models[alias], ClaudeCodeModelInfo(resolvedModel: resolved, displayName: title))
        }
    }

    func testUnknownModelsAndUnrelatedResponsesAreIgnored() throws {
        let fixture = try fixture()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.data) as? [String: Any])
        var response = try XCTUnwrap(envelope["response"] as? [String: Any])
        var payload = try XCTUnwrap(response["response"] as? [String: Any])
        var entries = try XCTUnwrap(payload["models"] as? [[String: Any]])
        // Unknown entries need not have the fields required for supported aliases.
        entries.append(["value": "future-model"])
        entries.append(["value": "claude-opus-99", "displayName": "Opus 99"])
        payload["models"] = entries
        response["response"] = payload
        envelope["response"] = response
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertEqual(try ClaudeCodeProtocol.modelCatalog(from: data, requestId: fixture.requestId), try fixtureModels())
        XCTAssertNil(try ClaudeCodeProtocol.modelCatalog(from: data, requestId: "another-request"))
        XCTAssertNil(try ClaudeCodeProtocol.modelCatalog(from: Data(#"{"type":"system","subtype":"init"}"#.utf8), requestId: fixture.requestId))
    }

    func testInvalidInitializeRepliesFail() throws {
        for reply in [
            "not json",
            #"{"type":"control_response","response":{"request_id":"test","subtype":"error","error":"failed"}}"#,
            #"{"type":"control_response","response":{"request_id":"test","subtype":"success","response":{}}}"#,
            #"{"type":"control_response","response":{"request_id":"test","subtype":"success","response":{"models":[]}}}"#,
            #"{"type":"control_response","response":{"request_id":"test","subtype":"success","response":{"models":[{"value":"opus","displayName":"Opus"}]}}}"#,
            #"{"type":"control_response","response":{"request_id":"test","subtype":"success","response":{"models":[{"value":"opus","resolvedModel":"id","displayName":" "}]}}}"#,
        ] {
            XCTAssertThrowsError(try ClaudeCodeProtocol.modelCatalog(from: Data(reply.utf8), requestId: "test"), reply)
        }
    }

    @MainActor
    func testDisplayNamesFallBackUntilAnAliasIsAvailable() async throws {
        let opus = try XCTUnwrap(fixtureModels()["opus"])
        let catalog = ClaudeCodeModelCatalog(defaults: defaults, query: { ["opus": opus] })
        for model in ClaudeCodeModel.allCases { XCTAssertEqual(catalog.displayName(for: model), model.title) }
        await catalog.refreshIfStale()
        XCTAssertEqual(catalog.displayName(for: .opus), "Opus 5.5")
        XCTAssertEqual(catalog.displayName(for: .fable), ClaudeCodeModel.fable.title)
        XCTAssertEqual(catalog.displayName(for: .sonnet), ClaudeCodeModel.sonnet.title)
    }

    @MainActor
    func testCacheRoundTripLoadsImmediatelyAndRefreshesOncePerRun() async throws {
        let models = try fixtureModels()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let first = ClaudeCodeModelCatalog(defaults: defaults, clock: { date }, query: { models })
        await first.refreshIfStale()

        struct CachedResult: Decodable {
            let models: [String: ClaudeCodeModelInfo]
            let fetchedAt: Date
        }
        let data = try XCTUnwrap(defaults.data(forKey: "MistClaudeCode.modelCatalog"))
        let cached = try JSONDecoder().decode(CachedResult.self, from: data)
        XCTAssertEqual(cached.models, models)
        XCTAssertEqual(cached.fetchedAt, date)
        var calls = 0
        let reloaded = ClaudeCodeModelCatalog(defaults: UserDefaults(suiteName: suite)!, clock: { date }, query: {
            calls += 1
            return models
        })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(reloaded.models, models)
        XCTAssertEqual(reloaded.displayName(for: .sonnet), "Sonnet 5.5")
        await reloaded.refreshIfStale()
        await reloaded.refreshIfStale()
        XCTAssertEqual(calls, 1, "A fresh cache still refreshes once in a new app run")
    }

    @MainActor
    func testRefreshIsThrottledToOneAttemptPerHour() async throws {
        let models = try fixtureModels()
        var now = Date(timeIntervalSince1970: 1_000_000)
        var calls = 0
        let catalog = ClaudeCodeModelCatalog(defaults: defaults, clock: { now }, query: {
            calls += 1
            return models
        })
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 1)
        now.addTimeInterval(3599)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 1)
        now.addTimeInterval(1)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 2)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testConcurrentRefreshesShareOneQuery() async throws {
        let models = try fixtureModels()
        var calls = 0
        var finish: CheckedContinuation<[String: ClaudeCodeModelInfo], Error>?
        let catalog = ClaudeCodeModelCatalog(defaults: defaults, query: {
            calls += 1
            return try await withCheckedThrowingContinuation { finish = $0 }
        })
        let first = Task { await catalog.refreshIfStale() }
        for _ in 0..<100 where finish == nil { await Task.yield() }
        let continuation = try XCTUnwrap(finish)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 1)
        continuation.resume(returning: models)
        await first.value
        XCTAssertEqual(catalog.models, models)
    }

    @MainActor
    func testFailedQueryKeepsCacheAndIsThrottled() async throws {
        let models = try fixtureModels()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let seeded = ClaudeCodeModelCatalog(defaults: defaults, clock: { now }, query: { models })
        await seeded.refreshIfStale()
        let original = defaults.data(forKey: "MistClaudeCode.modelCatalog")
        var calls = 0
        let catalog = ClaudeCodeModelCatalog(defaults: defaults, clock: { now }, query: {
            calls += 1
            throw CocoaError(.fileNoSuchFile)
        })
        await catalog.refreshIfStale()
        XCTAssertEqual(catalog.models, models)
        XCTAssertEqual(catalog.displayName(for: .fable), "Fable 5.1")
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.modelCatalog"), original)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 1)
        now.addTimeInterval(3600)
        await catalog.refreshIfStale()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(catalog.models, models)
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.modelCatalog"), original)
    }

    @MainActor
    func testCorruptCacheAndEmptyQueryUseFallback() async {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "MistClaudeCode.modelCatalog")
        let catalog = ClaudeCodeModelCatalog(defaults: defaults, query: { [:] })
        await catalog.refreshIfStale()
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertEqual(catalog.displayName(for: .opus), ClaudeCodeModel.opus.title)
        XCTAssertEqual(defaults.data(forKey: "MistClaudeCode.modelCatalog"), corrupt)
    }
}
