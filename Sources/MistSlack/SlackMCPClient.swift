import Foundation

struct SlackMCPError: Error, Equatable {
    let message: String
    var agentMessage: String { "Slack: \(message)" }
}

private enum SlackMCPTransportError: Error { case expiredSession }

/// Serializes requests so concurrent tools share one initialized session.
@MainActor final class SlackMCPClient {
    typealias Transport = (Data, String, [String: String]) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let sleep: (UInt64) async throws -> Void
    private let clock: () -> Date
    private var token: String?
    private var session: String?
    private var cachedTools: [[String: Any]]?
    private var cachedAt: Date?
    private var nextID = 0
    private var pending: Task<Void, Never>?
    private let protocolVersion = "2025-06-18"

    init(transport: @escaping Transport,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.sleep = sleep
        self.clock = clock
    }

    func tools(token: String) async throws -> [[String: Any]] {
        try await serialized {
            self.use(token)
            if let tools = self.cachedTools, let date = self.cachedAt, self.clock().timeIntervalSince(date) < 3600 { return tools }
            var tools: [[String: Any]] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let result = try await self.request("tools/list", parameters: cursor.map { ["cursor": $0] } ?? [:], token: token)
                guard let page = result["tools"] as? [[String: Any]] else { throw SlackAPIError(code: "invalid_response") }
                tools += page.map { $0.filter { ["name", "description", "inputSchema", "annotations"].contains($0.key) } }
                cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let cursor, !seen.insert(cursor).inserted { throw SlackAPIError(code: "invalid_response") }
            } while cursor != nil
            self.cachedTools = tools
            self.cachedAt = self.clock()
            return tools
        }
    }

    func call(_ name: String, arguments: [String: Any], token: String) async throws -> [String: Any] {
        try await serialized {
            self.use(token)
            let result = try await self.request("tools/call", parameters: ["name": name, "arguments": arguments], token: token)
            guard result["content"] is [[String: Any]] else { throw SlackAPIError(code: "invalid_response") }
            return result.filter { $0.key == "content" || $0.key == "isError" }
        }
    }

    private func serialized<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        pending = Task { _ = await task.result }
        return try await task.value
    }

    private func use(_ token: String) {
        guard self.token != token else { return }
        self.token = token
        session = nil
        cachedTools = nil
        cachedAt = nil
    }

    private func initialize(token: String) async throws {
        nextID += 1
        let id = nextID
        let (data, response) = try await send(["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": protocolVersion, "capabilities": [:], "clientInfo": ["name": "Mist", "version": "1.0"]
        ]], token: token, headers: [:])
        _ = try result(data, id: id, response: response)
        guard let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty else {
            throw SlackAPIError(code: "invalid_response")
        }
        // Publish the session only after the notification succeeds.
        _ = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token,
                           headers: ["Mcp-Session-Id": session, "MCP-Protocol-Version": protocolVersion])
        self.session = session
    }

    private func request(_ method: String, parameters: [String: Any], token: String) async throws -> [String: Any] {
        for attempt in 0...1 {
            do {
                if session == nil { try await initialize(token: token) }
                nextID += 1
                let id = nextID
                let (data, response) = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters], token: token,
                    headers: ["Mcp-Session-Id": session!, "MCP-Protocol-Version": protocolVersion])
                return try result(data, id: id, response: response)
            } catch SlackMCPTransportError.expiredSession {
                session = nil
                guard attempt == 0 else { throw SlackAPIError(code: "http_404") }
            }
        }
        throw SlackAPIError(code: "invalid_response")
    }

    private func send(_ body: [String: Any], token: String, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let bytes = try JSONSerialization.data(withJSONObject: body)
        do {
            for attempt in 0...1 {
                let (data, response) = try await transport(bytes, token, headers)
                switch response.statusCode {
                case 401, 403: throw SlackAPIError(code: "invalid_auth")
                case 404 where headers["Mcp-Session-Id"] != nil: throw SlackMCPTransportError.expiredSession
                case 429:
                    let seconds = max(0, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
                    guard attempt == 0, seconds <= 30 else { throw SlackAPIError(code: "ratelimited", retryAfter: seconds) }
                    try await sleep(UInt64(seconds) * 1_000_000_000)
                case 200...299: return (data, response)
                default: throw SlackAPIError(code: "http_\(response.statusCode)")
                }
            }
        } catch is URLError { throw SlackAPIError(code: "network") }
        throw SlackAPIError(code: "ratelimited")
    }

    private func result(_ data: Data, id: Int, response: HTTPURLResponse) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            for event in text.components(separatedBy: "\n\n") {
                let payload = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                    .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                if let message = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] { messages.append(message) }
            }
        } else if let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { messages.append(message) }
        guard let message = messages.first(where: { ($0["id"] as? Int) == id }) else { throw SlackAPIError(code: "invalid_response") }
        if let error = message["error"] as? [String: Any] {
            throw SlackMCPError(message: error["message"] as? String ?? "Unknown MCP error")
        }
        guard let result = message["result"] as? [String: Any] else { throw SlackAPIError(code: "invalid_response") }
        return result
    }
}
