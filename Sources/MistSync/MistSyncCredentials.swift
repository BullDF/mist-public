import CryptoKit
import Foundation
import Security

struct MistSyncCredentials: Codable, Equatable {
    let serverURL: String
    let groupKey: Data

    init(serverURL: String, groupKey: Data) throws {
        guard let parts = URLComponents(string: serverURL), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              groupKey.count == 32, parts.url != nil else { throw MistSyncError.invalidConfiguration }
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.groupKey = groupKey
    }

    static func create(serverURL: String) throws -> Self {
        try Self(serverURL: serverURL, groupKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    var pairingCode: String {
        // Both values are strings; encoding cannot fail.
        let json = try! JSONEncoder().encode(["u": serverURL, "k": MistSyncBase64.encode(groupKey)])
        return "mist-sync:" + MistSyncBase64.encode(json)
    }

    static func parse(_ code: String) throws -> Self {
        guard code.hasPrefix("mist-sync:"), code.utf8.count < 16_384 else { throw MistSyncError.invalidConfiguration }
        let bytes = try MistSyncBase64.decode(String(code.dropFirst("mist-sync:".count)))
        let fields = try JSONDecoder().decode([String: String].self, from: bytes)
        guard fields.count == 2, let url = fields["u"], let key = fields["k"] else {
            throw MistSyncError.invalidConfiguration
        }
        return try Self(serverURL: url, groupKey: MistSyncBase64.decode(key))
    }

    var webSocketURL: URL {
        var parts = URLComponents(string: serverURL)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/connect"
        return parts.url!
    }
}

protocol MistSyncKeyStorage {
    func load() throws -> MistSyncCredentials?
    func save(_ credentials: MistSyncCredentials) throws
    func delete() throws
}

struct MistSyncKeychain: MistSyncKeyStorage {
    let bundleID: String
    init(bundleID: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        self.bundleID = bundleID
    }

    static func service(bundleID: String) -> String {
        bundleID == "com.bulldf.mist" ? "Mist Sync" : "Mist Sync (\(bundleID))"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service(bundleID: bundleID),
         kSecAttrAccount as String: "sync-group"]
    }

    func load() throws -> MistSyncCredentials? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw keychainError(status) }
        let saved = try JSONDecoder().decode(MistSyncCredentials.self, from: bytes)
        return try MistSyncCredentials(serverURL: saved.serverURL, groupKey: saved.groupKey)
    }

    func save(_ credentials: MistSyncCredentials) throws {
        let bytes = try JSONEncoder().encode(credentials)
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
