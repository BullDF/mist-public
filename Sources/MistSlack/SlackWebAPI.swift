import Foundation

struct SlackAPIError: Error, Equatable {
    let code: String
    var retryAfter: Int? = nil
}

final class SlackWebAPI {
    typealias Transport = (_ method: String, _ token: String, _ parameters: [String: String]) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport
    private let sleep: (UInt64) async throws -> Void

    init(transport: @escaping Transport,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.transport = transport
        self.sleep = sleep
    }

    func call(_ method: String, token: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        do {
            for attempt in 0...1 {
                let (data, response) = try await transport(method, token, parameters)
                if response.statusCode == 429 {
                    let seconds = max(0, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
                    guard attempt == 0, seconds <= 30 else {
                        throw SlackAPIError(code: "ratelimited", retryAfter: seconds)
                    }
                    try await sleep(UInt64(seconds) * 1_000_000_000)
                    continue
                }
                guard (200...299).contains(response.statusCode) else {
                    throw SlackAPIError(code: "http_\(response.statusCode)")
                }
                guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw SlackAPIError(code: "invalid_response")
                }
                if body["ok"] as? Bool == false {
                    throw SlackAPIError(code: body["error"] as? String ?? "unknown_error")
                }
                return body
            }
            throw SlackAPIError(code: "ratelimited")
        } catch is URLError {
            throw SlackAPIError(code: "network")
        }
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? SlackAPIError else { return "Slack error: \((error as NSError).code)" }
        switch error.code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive":
            return "Slack rejected Mist's token. Johnny can check Settings ▸ Slack."
        case "missing_scope": return "The Drifter Slack app lacks a permission this needs (missing_scope)."
        case "ratelimited":
            if let seconds = error.retryAfter { return "Slack is rate-limiting Mist; try again in \(seconds) seconds." }
            return "Slack is rate-limiting Mist; try again in a minute."
        case "network": return "Mist can't reach Slack."
        case "not_configured": return "Slack isn't set up in Mist. Johnny adds the tokens in Settings ▸ Slack."
        default: return "Slack error: \(error.code)"
        }
    }
}
