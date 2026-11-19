import XCTest
@testable import Phi

final class AccountUserDefaultsRollbackTests: XCTestCase {

    private var scratchAccounts: [Account] = []

    override func tearDown() {
        for account in scratchAccounts {
            try? Self.setDefaultsDirectoryWritable(true, for: account)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    private func makeAccount() -> Account {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        // userDefaults is lazy; this access creates the defaults/ directory.
        _ = account.userDefaults
        return account
    }

    private static func defaultsDirectory(for account: Account) -> URL {
        account.userDataStorage.appendingPathComponent("defaults", isDirectory: true)
    }

    private static func plistURL(for account: Account) -> URL {
        defaultsDirectory(for: account).appendingPathComponent("account_defaults.plist")
    }

    /// 0o500 allows reads and traversal but blocks the temporary file required by `.atomic` writes.
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500],
            ofItemAtPath: defaultsDirectory(for: account).path)
    }

    private func setWritable(_ writable: Bool, for account: Account) throws {
        try Self.setDefaultsDirectoryWritable(writable, for: account)
    }

    // MARK: - CASE 2a.1

    func testAFailedWriteRollsBackTheStringKeyFace() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        XCTAssertTrue(defaults.set("v1", forKey: "k"))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set("v2", forKey: "k"), "A failed disk write returns false")
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v1",
                       "Memory returns to the pre-write state and never gets ahead of disk")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set("v3", forKey: "k"))
        XCTAssertEqual(defaults.object(forKey: "k") as? String, "v3")
        XCTAssertEqual(AccountUserDefaults(account: account).string(forKey: "k"), "v3",
                       "A fresh instance for the same account reads the persisted value")
    }

    // MARK: - CASE 2a.2

    func testAFailedWriteRollsBackTheDefaultsKeyOverloadToo() throws {
        let account = makeAccount()
        let defaults = account.userDefaults
        let key = AccountUserDefaults.DefaultsKey.activeSpaceId
        XCTAssertTrue(defaults.set("v1", forKey: key))

        try setWritable(false, for: account)
        XCTAssertFalse(defaults.set("v2", forKey: key))
        XCTAssertEqual(defaults.string(forKey: key.rawValue), "v1")

        try setWritable(true, for: account)
        XCTAssertTrue(defaults.set("v3", forKey: key))
        XCTAssertEqual(defaults.string(forKey: key.rawValue), "v3")
        XCTAssertEqual(AccountUserDefaults(account: account).string(forKey: key.rawValue), "v3")
    }

    // MARK: - CASE 2a.3

    // MARK: - CASE 2a.4

    // MARK: - CASE 2a.5

    // MARK: - CASE 2a.6

}
