// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

class APIClient {
    static let shared = APIClient()

    func slackSocket(_ url: URL) -> URLSessionWebSocketTask {
        URLSession.shared.webSocketTask(with: url)
    }

    func slackMCP(_ body: Data, token: String, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://mcp.slack.com/mcp")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    func slack(_ method: String, token: String, parameters: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://slack.com/api/")!.appendingPathComponent(method)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = parameters.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: unreserved)! + "=" +
                value.addingPercentEncoding(withAllowedCharacters: unreserved)!
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    func searchSuggestions(engine: SearchSuggestionsEngine, query: String) async -> SearchSuggestionsResult {
        guard let url = engine.suggestURL(query: query) else { return SearchSuggestionsResult() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                AppLogDebug("omni: search suggestions returned an invalid response")
                return SearchSuggestionsResult()
            }
            return SearchSuggestions.parse(data)
        } catch {
            AppLogDebug("omni: search suggestions failed: \(error)")
            return SearchSuggestionsResult()
        }
    }

}
