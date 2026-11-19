import Foundation

@MainActor final class SlackDirectory {
    private let call: (String, [String: String]) async throws -> [String: Any]
    private let account: () -> String?
    private let clock: () -> Date
    private var cachedAccount: String?
    private var refreshedAt: Date?
    private var names: [String: (name: String, isSelf: Bool)] = [:]
    private var userNames: [String: String] = [:]
    private var refreshing: String?

    init(call: @escaping (String, [String: String]) async throws -> [String: Any],
         account: @escaping () -> String?, clock: @escaping () -> Date = Date.init) {
        self.call = call
        self.account = account
        self.clock = clock
    }

    func name(forChannel id: String) -> (name: String, isSelf: Bool)? {
        guard account() == cachedAccount else { return nil }
        return names[id]
    }

    func name(forUser id: String) -> String? {
        guard account() == cachedAccount else { return nil }
        return userNames[id]
    }

    func refreshIfStale() async {
        let token = account()
        if token != cachedAccount {
            cachedAccount = token
            refreshedAt = nil
            names = [:]
            userNames = [:]
        }
        guard let token, !token.isEmpty, refreshing != token,
              refreshedAt.map({ clock().timeIntervalSince($0) >= 3600 }) ?? true else { return }
        refreshing = token
        refreshedAt = clock()
        defer { if refreshing == token { refreshing = nil } }
        do {
            let identity = try await call("auth.test", [:])
            guard let selfID = identity["user_id"] as? String else { throw SlackAPIError(code: "invalid_response") }
            let users = try await pages("users.list", key: "members", parameters: ["limit": "200"])
            var byID: [String: String] = [:]
            var byHandle: [String: String] = [:]
            var selfHandle: String?
            for user in users {
                let profile = user["profile"] as? [String: Any] ?? [:]
                let name = [user["real_name"], profile["display_name"], user["name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
                if let name, let id = user["id"] as? String { byID[id] = name }
                if let name, let handle = user["name"] as? String { byHandle[handle] = name }
                if user["id"] as? String == selfID { selfHandle = user["name"] as? String }
            }
            let channels = try await pages("users.conversations", key: "channels", parameters: [
                "types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200"
            ])
            var updated: [String: (name: String, isSelf: Bool)] = [:]
            for channel in channels {
                guard let id = channel["id"] as? String else { continue }
                if channel["is_im"] as? Bool == true, let user = channel["user"] as? String {
                    updated[id] = ("@" + (byID[user] ?? user), user == selfID)
                } else if channel["is_mpim"] as? Bool == true, let handle = channel["name"] as? String {
                    var handles = handle.hasPrefix("mpdm-") ? String(handle.dropFirst(5)) : handle
                    if let suffix = handles.range(of: "-", options: .backwards), Int(handles[suffix.upperBound...]) != nil {
                        handles = String(handles[..<suffix.lowerBound])
                    }
                    let members = handles.components(separatedBy: "--").filter { !$0.isEmpty && $0 != selfHandle }
                    updated[id] = (members.map { byHandle[$0] ?? $0 }.joined(separator: ", "), false)
                } else if let name = channel["name"] as? String {
                    updated[id] = ("#" + name, false)
                }
            }
            guard account() == token, cachedAccount == token else { return }
            names = updated
            userNames = byID
        } catch { /* Keep the previous directory if a refresh fails. */ }
    }

    private func pages(_ method: String, key: String, parameters: [String: String]) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var parameters = parameters
        var seen = Set<String>()
        while true {
            let result = try await call(method, parameters)
            guard let page = result[key] as? [[String: Any]] else { throw SlackAPIError(code: "invalid_response") }
            rows += page
            let cursor = (result["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            if cursor.isEmpty { return rows }
            guard seen.insert(cursor).inserted else { throw SlackAPIError(code: "invalid_response") }
            parameters["cursor"] = cursor
        }
    }
}
