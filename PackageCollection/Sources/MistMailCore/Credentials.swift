import Foundation
import Security

public protocol MailCredentialStore: Sendable {
    func load(accountID: UUID) throws -> String?
    func save(_ password: String, accountID: UUID) throws
    func delete(accountID: UUID) throws
}

public struct KeychainMailCredentialStore: MailCredentialStore {
    public let service: String
    public init(service: String) { self.service = service }
    public static func service(bundleID: String) -> String {
        bundleID == "com.bulldf.mist" ? "Mist Mail" : "Mist Mail (\(bundleID))"
    }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public func load(accountID: UUID) throws -> String? {
        var lookup = query(accountID)
        lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    public func save(_ password: String, accountID: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(accountID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var item = query(accountID); item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }
    public func delete(accountID: UUID) throws {
        let status = SecItemDelete(query(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}

public final class InMemoryMailCredentialStore: MailCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]
    public init() {}
    public func load(accountID: UUID) throws -> String? { lock.lock(); defer { lock.unlock() }; return passwords[accountID] }
    public func save(_ password: String, accountID: UUID) throws { lock.lock(); defer { lock.unlock() }; passwords[accountID] = password }
    public func delete(accountID: UUID) throws { lock.lock(); defer { lock.unlock() }; passwords.removeValue(forKey: accountID) }
}
