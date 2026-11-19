import Foundation
import Security

struct SlackTokens: Codable, Equatable {
    var user: String?
    var bot: String?
    var app: String?

    static func isValid(_ value: String, kind: SlackTokenKind) -> Bool {
        value.hasPrefix(kind.prefix) && value.count > kind.prefix.count &&
            !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
    }
}

enum SlackTokenKind {
    case user, bot, app

    var prefix: String {
        switch self {
        case .user: return "xoxp-"
        case .bot: return "xoxb-"
        case .app: return "xapp-"
        }
    }
}

protocol SlackTokenStorage {
    func load() throws -> SlackTokens?
    func save(_ tokens: SlackTokens) throws
    func delete() throws
}

final class InMemorySlackTokenStorage: SlackTokenStorage {
    private(set) var tokens: SlackTokens?

    init(tokens: SlackTokens? = nil) { self.tokens = tokens }
    func load() throws -> SlackTokens? { tokens }
    func save(_ tokens: SlackTokens) throws { self.tokens = tokens }
    func delete() throws { tokens = nil }
}

struct SlackKeychain: SlackTokenStorage {
    let bundleID: String

    init(bundleID: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        self.bundleID = bundleID
    }

    static func service(bundleID: String) -> String {
        bundleID == "com.bulldf.mist" ? "Mist Slack" : "Mist Slack (\(bundleID))"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service(bundleID: bundleID),
         kSecAttrAccount as String: "tokens"]
    }

    func load() throws -> SlackTokens? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(SlackTokens.self, from: bytes)
    }

    func save(_ tokens: SlackTokens) throws {
        let bytes = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        var item = query
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
