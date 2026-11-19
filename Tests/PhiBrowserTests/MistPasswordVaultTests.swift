import CryptoKit
import XCTest
@testable import Phi

final class MistPasswordVaultTests: XCTestCase {
    func testLegacyVaultWithoutEmailsOpens() throws {
        let key = SymmetricKey(size: .bits256)
        let json = Data(#"{"version":1,"logins":[],"neverSave":[]}"#.utf8)
        let encrypted = try XCTUnwrap(AES.GCM.seal(json, using: key).combined)
        let value = try MistPasswordCrypto.open(encrypted, key: key)
        XCTAssertEqual(value.version, 1)
        XCTAssertTrue(value.emails.isEmpty)
    }

    func testEmailValidationAndCaseInsensitiveIdentity() {
        XCTAssertEqual(MistEmailAddress.normalized(" \nJohnny@Example\t"), "Johnny@Example")
        for invalid in ["", "johnny", "a@@b", "@b", "a@", "a b@c", "a@b\nc", "a@b\tc"] {
            XCTAssertNil(MistEmailAddress.normalized(invalid), invalid)
        }
        var data = MistPasswordData()
        data.insertEmail("Johnny@Example")
        data.emails[0].lastUsed = Date(timeIntervalSince1970: 123)
        data.insertEmail("JOHNNY@example")
        XCTAssertEqual(data.emails, [MistEmail(address: "JOHNNY@example", lastUsed: Date(timeIntervalSince1970: 123))])
        data.removeEmail(id: "johnny@example")
        XCTAssertTrue(data.emails.isEmpty)
    }

    func testPreferredUsernameIsCaseInsensitiveAndStable() {
        let other = MistLogin(site: "https://example.com", username: "bob", password: "fixture")
        let first = MistLogin(site: "https://example.com", username: "Alice", password: "fixture")
        let another = MistLogin(site: "https://example.com", username: "carol", password: "fixture")
        let second = MistLogin(site: "https://example.com", username: "ALICE", password: "fixture")
        let logins = [other, first, another, second]
        XCTAssertEqual(MistPasswordMatching.preferring("aLiCe", in: logins).map(\.id),
                       [first.id, second.id, other.id, another.id])
        XCTAssertEqual(MistPasswordMatching.preferring("missing", in: logins).map(\.id), logins.map(\.id))
    }

    func testEncryptionRoundTripAndTamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        let value = MistPasswordData(logins: [MistLogin(site: "https://example.com", username: "alice", password: "test-secret")],
                                     neverSave: ["excluded.example"])
        let encrypted = try MistPasswordCrypto.seal(value, key: key)
        XCTAssertEqual(try MistPasswordCrypto.open(encrypted, key: key), value)
        XCTAssertNil(encrypted.range(of: Data("test-secret".utf8)))
        var tampered = encrypted
        tampered[tampered.count / 2] ^= 1
        XCTAssertThrowsError(try MistPasswordCrypto.open(tampered, key: key))
        XCTAssertThrowsError(try MistPasswordCrypto.open(encrypted, key: SymmetricKey(size: .bits256)))
    }

    @MainActor func testPersistenceAndFailedReadCannotOverwriteVault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("vault")
        let key = SymmetricKey(size: .bits256)
        let vault = MistPasswordVault(file: file, keyProvider: { _ in key })
        try vault.change { $0.neverSave.insert("example.com") }
        let reopened = MistPasswordVault(file: file, keyProvider: { _ in key })
        try reopened.load()
        XCTAssertEqual(reopened.data.neverSave, ["example.com"])
        let original = try Data(contentsOf: file)
        let wrong = MistPasswordVault(file: file, keyProvider: { _ in SymmetricKey(size: .bits256) })
        XCTAssertThrowsError(try wrong.change { $0.logins = [] })
        XCTAssertEqual(try Data(contentsOf: file), original)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRegistrableDomainOrderingAndDowngradeRefusal() {
        let exactOld = MistLogin(site: "https://login.example.co.uk", username: "old", password: "fixture", lastUsed: Date(timeIntervalSince1970: 1))
        let exactNew = MistLogin(site: "https://login.example.co.uk", username: "new", password: "fixture", lastUsed: Date(timeIntervalSince1970: 2))
        let sibling = MistLogin(site: "https://app.example.co.uk", username: "sibling", password: "fixture", lastUsed: Date())
        let unrelated = MistLogin(site: "https://example.co.uk.evil.com", username: "evil", password: "fixture")
        let insecure = MistLogin(site: "http://login.example.co.uk", username: "http", password: "fixture")
        let domain: (String) -> String = { url in
            let host = URL(string: url)?.host ?? ""
            return host == "example.co.uk" || host.hasSuffix(".example.co.uk") ? "example.co.uk" : "evil.com"
        }
        XCTAssertEqual(MistPasswordMatching.matches([sibling, exactOld, unrelated, exactNew],
            page: "https://login.example.co.uk/path", domain: domain).map(\.id), [exactNew.id, exactOld.id, sibling.id])
        XCTAssertEqual(MistPasswordMatching.matches([exactNew, insecure, sibling],
            page: "http://login.example.co.uk", domain: domain).map(\.id), [insecure.id])
        XCTAssertTrue(MistPasswordMatching.matches([exactNew], page: "file:///example", domain: domain).isEmpty)
        XCTAssertTrue(MistPasswordMatching.matches([exactNew], page: exactNew.site, domain: { _ in "" }).isEmpty)
        XCTAssertEqual(MistPasswordMatching.origin("https://user:secret@example.com/path?token=secret#fragment"), "https://example.com")
    }
}
