import XCTest
@testable import MistMailCore

final class AccountSyncTests: XCTestCase {
    func testOfflineUpsertPreservesIdentityAndPasswordAndEmitsChanges() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        let events = await engine.events()
        var iterator = events.makeAsyncIterator()
        var config = testConfig()
        config.sortOrder = 4
        let account = MailAccount(id: UUID(), config: config, isGmail: true)
        await engine.networkBecameUnavailable()
        try await engine.applySyncedAccount(account, password: "secret")
        let stored = try await engine.accounts(), password = try await engine.storedPassword(accountID: account.id)
        XCTAssertEqual(stored, [account]); XCTAssertEqual(password, "secret")
        guard case .accountStatusChanged(account.id, .disconnected) = await iterator.next() else {
            return XCTFail("Missing disconnected event")
        }
        guard case .accountsChanged = await iterator.next() else { return XCTFail("Missing accounts event") }
        try await engine.applySyncedAccount(account, password: nil)
        try await engine.applySyncedAccount(account, password: "")
        let preserved = try await engine.storedPassword(accountID: account.id), calls = await fixture.server.connectCount
        XCTAssertEqual(preserved, "secret"); XCTAssertEqual(calls, 0)
    }

    func testPasswordRestoresMissingCredentialsAndConfigOnlyEditsPreserveStatus() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        var account = MailAccount(config: testConfig())
        try await engine.applySyncedAccount(account, password: nil)
        await engine.failed(account.id, MailError.missingCredentials)
        let failed = await engine.accountStatuses()[account.id]
        XCTAssertEqual(failed, .authFailed)
        try await engine.applySyncedAccount(account, password: "new")
        let recovered = await engine.accountStatuses()[account.id]
        XCTAssertEqual(recovered, .disconnected)
        await engine.setStatus(account.id, .connected)
        account.config.displayName = "Renamed"; account.config.sortOrder = 8; account.isGmail = true
        try await engine.applySyncedAccount(account, password: "new")
        let unchanged = await engine.accountStatuses()[account.id], saved = try await engine.accounts()
        XCTAssertEqual(unchanged, .connected); XCTAssertEqual(saved, [account])
        try await engine.applySyncedAccount(account, password: "replacement")
        let password = try await engine.storedPassword(accountID: account.id), reset = await engine.accountStatuses()[account.id]
        XCTAssertEqual(password, "replacement"); XCTAssertEqual(reset, .disconnected)
        await engine.setStatus(account.id, .connected)
        account.config.username = "other"
        try await engine.applySyncedAccount(account, password: nil)
        let reconfigured = await engine.accountStatuses()[account.id], calls = await fixture.server.connectCount
        XCTAssertEqual(reconfigured, .disconnected); XCTAssertEqual(calls, 0)
    }

    func testReorderMovesEveryAccountAboveTheOldPositionsInOneChange() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        for (index, position) in [0, 5, 5].enumerated() {
            var config = testConfig(); config.displayName = "Account \(index)"; config.sortOrder = position
            try await engine.applySyncedAccount(MailAccount(config: config), password: nil)
        }
        let before = try await engine.accounts(), first = before[0], second = before[1], third = before[2]
        let events = await engine.events()
        var iterator = events.makeAsyncIterator()
        try await engine.reorderAccounts([third.id, UUID(), third.id, first.id])
        let after = try await engine.accounts()
        XCTAssertEqual(after.map(\.id), [third.id, first.id, second.id], "Listed accounts first, the rest after in their order")
        XCTAssertEqual(after.map(\.config.sortOrder), [6, 7, 8], "Every account moves above the old positions")
        guard case .accountsChanged = await iterator.next() else { return XCTFail("Missing accounts event") }
        try await engine.reorderAccounts([third.id, first.id, second.id])
        let unchanged = try await engine.accounts()
        XCTAssertEqual(unchanged, after)
        await engine.setStatus(first.id, .connected)
        guard case .accountStatusChanged(first.id, .connected) = await iterator.next() else {
            return XCTFail("Reordering into the current order emitted a change")
        }
        var stale = first.config; stale.displayName = "Renamed"
        try await engine.updateAccount(first.id, config: stale)
        let edited = try await engine.accounts()
        XCTAssertEqual(edited.map(\.id), after.map(\.id)); XCTAssertEqual(edited[1].config.sortOrder, 7, "An edit keeps the current position")
        XCTAssertEqual(edited[1].config.displayName, "Renamed")
    }

    func testInvalidConfigurationStoresNeitherAccountNorPassword() async throws {
        let fixture = EngineFixture(), engine = try fixture.engine()
        var account = MailAccount(config: testConfig())
        account.config.imap.host = "remote.example"
        do {
            try await engine.applySyncedAccount(account, password: "secret")
            XCTFail("Accepted insecure remote host")
        } catch { XCTAssertEqual(error as? MailError, .invalidConfiguration) }
        let accounts = try await engine.accounts(), password = try await engine.storedPassword(accountID: account.id)
        XCTAssertTrue(accounts.isEmpty); XCTAssertNil(password)
    }
}
