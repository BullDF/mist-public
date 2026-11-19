// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStoreProfileDeletionTests: XCTestCase {
    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> LocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStoreProfileDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return LocalStore(account: Account(userID: "test-user"), storeDirectoryURL: url,
                          presentsCompatibilityAlerts: false)
    }

    private func insertTab(_ guid: String, profileId: String, spaceId: String?,
                           in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let row = TabDataModel(title: guid, guid: guid, index: 0, url: URL(string: "https://example.com")!,
                                   favicon: nil, createdDate: Date(), updatedDate: Date())
            row.profileId = profileId
            row.spaceId = spaceId
            context.insert(row)
        }
    }

    func testTheCascadeRemovesProfilePinsAndProfileRowAndKeepsOtherProfiles() async throws {
        let store = try makeStore()
        try await insertTab("profile-pin", profileId: "P2", spaceId: nil, in: store)
        try await insertTab("other-pin", profileId: "P3", spaceId: nil, in: store)
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(ProfileModel(profileId: "P2"))
        }
        try await store.deleteProfileRowCascadeThrowing(profileId: "P2")
        try await store.deleteProfileRowCascadeThrowing(profileId: "P2")
        let (tabs, profiles) = try await store.performBackgroundWriteAndWaitThrowing { context in
            (try context.fetch(FetchDescriptor<TabDataModel>()).map(\.guid),
             try context.fetch(FetchDescriptor<ProfileModel>()).map(\.profileId))
        }
        XCTAssertEqual(tabs, ["other-pin"])
        XCTAssertFalse(profiles.contains("P2"))
    }

    /// A new Profile row records when it was created, which the Profile entity publishes as
    /// `created_at_ms`; an existing row without one is left alone (0 stays "unknown").
    func testANewProfileRowRecordsItsCreationDate() async throws {
        let store = try makeStore()
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(ProfileModel(profileId: "Old"))
        }
        let before = Date()

        let created = try XCTUnwrap(try store.profile(with: "New", createIfNeeded: true))
        let existing = try XCTUnwrap(try store.profile(with: "Old", createIfNeeded: true))

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(created.createdDate), before.addingTimeInterval(-1))
        XCTAssertNil(existing.createdDate)
    }
}
