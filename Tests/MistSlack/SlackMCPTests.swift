import Foundation

@MainActor private final class MCPFake {
    struct Call { let body: [String: Any]; let token: String; let headers: [String: String] }
    var calls: [Call] = []
    var replies: [(Int, [String: String], [String: Any])] = []
    var delays: [UInt64] = []
    var date = Date(timeIntervalSince1970: 0)
    var sse = false
    var error: Error?
    lazy var client = SlackMCPClient(transport: { data, token, headers in
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        self.calls.append(Call(body: body, token: token, headers: headers))
        if let error = self.error { throw error }
        precondition(!self.replies.isEmpty, "Unexpected MCP call")
        let (status, suppliedHeaders, result) = self.replies.removeFirst()
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": body["id"] ?? 0]
        envelope[result["error"] == nil ? "result" : "error"] = result["error"] ?? result
        let json = try JSONSerialization.data(withJSONObject: envelope)
        let bytes = status == 202 ? Data() : self.sse ? Data(("event: message\r\ndata: {\"id\":-1,\"result\":{}}\r\n\r\ndata: " + String(decoding: json, as: UTF8.self) + "\r\n\r\n").utf8) : json
        var responseHeaders = suppliedHeaders
        responseHeaders["Content-Type"] = self.sse ? "text/event-stream" : "application/json"
        return (bytes, HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: status,
                                      httpVersion: nil, headerFields: responseHeaders)!)
    }, sleep: { self.delays.append($0) }, clock: { self.date })

    func reply(_ result: [String: Any] = [:], status: Int = 200, headers: [String: String] = [:]) {
        replies.append((status, headers, result))
    }
    func initialize(_ session: String = "session") {
        reply(["protocolVersion": "2025-06-18"], headers: ["Mcp-Session-Id": session])
        reply(status: 202)
    }
}

@MainActor enum SlackMCPTests {
    static func expectError(_ expected: SlackAPIError, _ action: () async throws -> Void) async {
        do { try await action(); fatalError("Expected \(expected)") }
        catch { precondition(error as? SlackAPIError == expected, "Unexpected error \(error)") }
    }

    static func run() async throws {
        let tool: [String: Any] = ["name": "slack_read_channel", "description": "Read", "inputSchema": ["type": "object"],
                                   "annotations": ["readOnlyHint": true], "ignored": true]
        let f = MCPFake()
        f.initialize()
        f.reply(["tools": [tool], "nextCursor": "next"])
        f.reply(["tools": [tool]])
        let tools = try await f.client.tools(token: "fake-a")
        precondition(tools.count == 2 && tools[0]["ignored"] == nil && tools[0].count == 4)
        precondition(f.calls.map { $0.body["method"] as! String } == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        precondition((f.calls[0].body["params"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        precondition(f.calls[0].headers.isEmpty)
        precondition(f.calls.dropFirst().allSatisfy { $0.headers == ["Mcp-Session-Id": "session", "MCP-Protocol-Version": "2025-06-18"] })
        precondition((f.calls.last?.body["params"] as? [String: String])?["cursor"] == "next")
        _ = try await f.client.tools(token: "fake-a")
        precondition(f.calls.count == 4)
        f.date += 3600
        f.reply(["tools": []])
        _ = try await f.client.tools(token: "fake-a")
        precondition(f.calls.count == 5)
        f.initialize("new")
        f.reply(["tools": [tool]])
        _ = try await f.client.tools(token: "fake-b")
        precondition(f.calls.count == 8 && f.calls.suffix(3).allSatisfy { $0.token == "fake-b" })
        f.sse = true
        f.reply(["content": [["type": "text", "text": "hello"]], "isError": true, "structuredContent": ["secret": "ignored"]])
        let result = try await f.client.call("slack_read_channel", arguments: ["channel_id": "C1"], token: "fake-b")
        precondition(result.count == 2 && result["isError"] as? Bool == true)
        let params = f.calls.last!.body["params"] as! [String: Any]
        precondition(params["name"] as? String == "slack_read_channel" && (params["arguments"] as? [String: String]) == ["channel_id": "C1"])

        let expired = MCPFake()
        expired.initialize()
        expired.reply(status: 404)
        expired.initialize("replacement")
        expired.reply(["content": []])
        _ = try await expired.client.call("slack_read_channel", arguments: [:], token: "fake")
        precondition(expired.calls.count == 6 && expired.calls.last?.headers["Mcp-Session-Id"] == "replacement")
        expired.reply(status: 404)
        expired.initialize()
        expired.reply(status: 404)
        await expectError(SlackAPIError(code: "http_404")) { _ = try await expired.client.call("slack_read_channel", arguments: [:], token: "fake") }

        let notificationExpired = MCPFake()
        notificationExpired.reply(["protocolVersion": "2025-06-18"], headers: ["Mcp-Session-Id": "expired"])
        notificationExpired.reply(status: 404)
        notificationExpired.initialize("replacement")
        notificationExpired.reply(["tools": []])
        _ = try await notificationExpired.client.tools(token: "fake")
        precondition(notificationExpired.calls.map { $0.body["method"] as! String } == [
            "initialize", "notifications/initialized", "initialize", "notifications/initialized", "tools/list"])
        let missing = MCPFake()
        missing.reply(status: 404)
        await expectError(SlackAPIError(code: "http_404")) { _ = try await missing.client.tools(token: "fake") }
        precondition(missing.calls.count == 1)

        let sseInitialize = MCPFake()
        sseInitialize.sse = true
        sseInitialize.initialize()
        sseInitialize.reply(["tools": []])
        _ = try await sseInitialize.client.tools(token: "fake")

        for status in [401, 403, 500] {
            let error = MCPFake()
            error.reply(status: status)
            await expectError(SlackAPIError(code: status == 500 ? "http_500" : "invalid_auth")) { _ = try await error.client.tools(token: "fake") }
        }
        let retry = MCPFake()
        retry.reply(status: 429, headers: ["Retry-After": "2"])
        retry.initialize()
        retry.reply(["tools": []])
        _ = try await retry.client.tools(token: "fake")
        precondition(retry.delays == [2_000_000_000])
        for seconds in [3, 31] {
            let rate = MCPFake()
            rate.reply(status: 429, headers: ["Retry-After": String(seconds)])
            if seconds == 3 { rate.reply(status: 429, headers: ["Retry-After": "3"]) }
            await expectError(SlackAPIError(code: "ratelimited", retryAfter: seconds)) { _ = try await rate.client.tools(token: "fake") }
            precondition(rate.delays.count == (seconds == 3 ? 1 : 0))
        }
        let rpc = MCPFake()
        rpc.initialize()
        rpc.reply(["error": ["code": -1, "message": "Access denied"]])
        do { _ = try await rpc.client.tools(token: "fake"); fatalError("Expected RPC error") }
        catch let error as SlackMCPError { precondition(error.agentMessage == "Slack: Access denied") }
        let network = MCPFake()
        network.error = URLError(.notConnectedToInternet)
        await expectError(SlackAPIError(code: "network")) { _ = try await network.client.tools(token: "fake") }

        let concurrent = MCPFake()
        concurrent.initialize()
        concurrent.reply(["tools": [tool]])
        async let first = concurrent.client.tools(token: "fake")
        async let second = concurrent.client.tools(token: "fake")
        _ = try await (first, second)
        precondition(concurrent.calls.count == 3)
    }
}
