import Combine
import CryptoKit
import Foundation
import Security

struct MistLogin: Codable, Identifiable, Equatable {
    var id = UUID()
    var site: String
    var username: String
    var password: String
    var lastUsed = Date.distantPast

    var host: String { URL(string: site)?.host?.lowercased() ?? "" }
}

struct MistEmail: Codable, Identifiable, Equatable {
    var address: String
    var lastUsed = Date.distantPast
    var id: String { address.lowercased() }
}

enum MistEmailAddress {
    static func normalized(_ text: String) -> String? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return address
    }
}

struct MistPasswordData: Codable, Equatable {
    var version = 1
    var logins: [MistLogin] = []
    var neverSave: Set<String> = []
    var emails: [MistEmail] = []

    init(version: Int = 1, logins: [MistLogin] = [], neverSave: Set<String> = [], emails: [MistEmail] = []) {
        self.version = version
        self.logins = logins
        self.neverSave = neverSave
        self.emails = emails
    }

    private enum CodingKeys: String, CodingKey { case version, logins, neverSave, emails }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        logins = try values.decode([MistLogin].self, forKey: .logins)
        neverSave = try values.decode(Set<String>.self, forKey: .neverSave)
        emails = try values.decodeIfPresent([MistEmail].self, forKey: .emails) ?? []
    }

    mutating func insertEmail(_ address: String) {
        guard let address = MistEmailAddress.normalized(address) else { return }
        if let index = emails.firstIndex(where: { $0.id == address.lowercased() }) {
            emails[index].address = address
        } else {
            emails.append(MistEmail(address: address))
        }
    }

    mutating func removeEmail(id: String) {
        emails.removeAll { $0.id == id }
    }
}

enum MistPasswordError: Error {
    case unavailable, invalidVault, invalidCSV
}

enum MistPasswordPreferences {
    static let offerToSaveKey = "mist.passwords.offerToSave"
    static let autofillKey = "mist.passwords.autofill"
    static var offerToSave: Bool { UserDefaults.standard.object(forKey: offerToSaveKey) as? Bool ?? true }
    static var autofill: Bool { UserDefaults.standard.object(forKey: autofillKey) as? Bool ?? true }
}

enum MistPasswordMatching {
    static func preferring(_ username: String, in logins: [MistLogin]) -> [MistLogin] {
        let preferred = logins.filter { $0.username.caseInsensitiveCompare(username) == .orderedSame }
        let remaining = logins.filter { $0.username.caseInsensitiveCompare(username) != .orderedSame }
        return preferred + remaining
    }

    /// Store only the origin; URLs can contain credentials in their path or query.
    static func origin(_ value: String) -> String? {
        guard let url = URL(string: value), let host = url.host?.lowercased(), !host.isEmpty,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        return parts.string
    }

    static func matches(_ logins: [MistLogin], page: String,
                        domain: (String) -> String) -> [MistLogin] {
        guard let origin = origin(page), let host = URL(string: origin)?.host else { return [] }
        let site = domain(origin)
        guard !site.isEmpty else { return [] }
        return logins.filter {
            domain($0.site) == site && !(origin.hasPrefix("http:") && $0.site.hasPrefix("https:"))
        }.sorted {
            if ($0.host == host) != ($1.host == host) { return $0.host == host }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

enum MistPasswordCrypto {
    static func seal(_ value: MistPasswordData, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(JSONEncoder().encode(value), using: key).combined else {
            throw MistPasswordError.invalidVault
        }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> MistPasswordData {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        let value = try JSONDecoder().decode(MistPasswordData.self, from: plain)
        guard value.version == 1 else { throw MistPasswordError.invalidVault }
        return value
    }
}

enum MistPasswordKey {
    static func service(bundleIdentifier: String) -> String {
        bundleIdentifier == "com.bulldf.mist"
            ? "Mist Password Vault" : "Mist Password Vault (\(bundleIdentifier))"
    }

    static func load(allowCreation: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service(bundleIdentifier:
                                       Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName),
                                   kSecAttrAccount as String: "vault-key"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound, allowCreation else { throw MistPasswordError.unavailable }
        let key = SymmetricKey(size: .bits256)
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try load(allowCreation: false) }
        guard added == errSecSuccess else { throw MistPasswordError.unavailable }
        return key
    }
}

/// The shared local repository owns persistence only; browser interaction stays window-scoped.
/// Failed reads never become an empty vault, and published state changes only after an atomic write.
@MainActor
final class MistPasswordVault: ObservableObject {
    static let shared = MistPasswordVault()
    @Published private(set) var data = MistPasswordData()
    var syncDidCommit: ((MistPasswordData, MistPasswordData) throws -> Void)?
    private var key: SymmetricKey?
    private var loaded = false
    private let file: URL
    private let keyProvider: (Bool) throws -> SymmetricKey

    init(file: URL? = nil, keyProvider: @escaping (Bool) throws -> SymmetricKey = MistPasswordKey.load) {
        self.file = file ?? URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
            .appendingPathComponent("MistPasswords", isDirectory: true).appendingPathComponent("vault")
        self.keyProvider = keyProvider
    }

    func load() throws {
        guard !loaded else { return }
        let exists = FileManager.default.fileExists(atPath: file.path)
        let key = try keyProvider(!exists)
        let value = exists ? try MistPasswordCrypto.open(Data(contentsOf: file), key: key) : MistPasswordData()
        self.key = key
        data = value
        loaded = true
    }

    func change(_ edit: (inout MistPasswordData) -> Void, reportingLocalChanges: Bool = true) throws {
        try load()
        guard let key else { throw MistPasswordError.unavailable }
        var next = data
        edit(&next)
        let encrypted = try MistPasswordCrypto.seal(next, key: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encrypted.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let old = data
        data = next
        if reportingLocalChanges { try syncDidCommit?(old, next) }
    }

    func importCSV(_ text: String, domain: (String) -> String) throws -> MistPasswordCSV.Counts {
        let rows = try MistPasswordCSV.logins(text)
        var counts = MistPasswordCSV.Counts(skipped: rows.skipped)
        try change { value in
            counts = MistPasswordCSV.merge(rows.logins, into: &value.logins, domain: domain, counts: counts)
        }
        return counts
    }
}
