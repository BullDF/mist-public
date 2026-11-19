// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStoreURLRuleThrowingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testReleasedV10StoreRetainsIconsAndLayoutsAfterSyncMigration() throws {
        let directory = try makeTemporaryDirectory()
        try seedReleasedV10Store(at: directory)

        let container = try openWithProductionMigrationPlan(at: directory)
        let tabs = try container.mainContext.fetch(FetchDescriptor<TabDataModel>())
        let tab = try XCTUnwrap(tabs.first)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tab.guid, "dev-tab")
        XCTAssertEqual(tab.icon, "folder.work")
        XCTAssertEqual(tab.layout, "horizontal")
        XCTAssertEqual(tab.secondaryUrl, URL(string: "https://second.example"))
        XCTAssertNil(tab.syncId)
        let rules = try container.mainContext.fetch(FetchDescriptor<SpaceURLRule>())
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.host, "dev.example")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(rule.syncId)))
    }

    private func seedReleasedV10Store(at directory: URL) throws {
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("LocalStore.sqlite"))
        let container = try ModelContainer(
            for: TabDataModelSchemaV10.ProfileModel.self,
            TabDataModelSchemaV10.TabDataModel.self,
            TabDataModelSchemaV10.SpaceModel.self,
            TabDataModelSchemaV10.SpaceURLRule.self,
            TabDataModelSchemaV10.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let tab = TabDataModelSchemaV10.TabDataModel(
            title: "Dev tab", guid: "dev-tab", index: 0,
            url: try XCTUnwrap(URL(string: "https://dev.example")),
            favicon: nil, createdDate: Date(), updatedDate: Date()
        )
        tab.icon = "folder.work"
        tab.layout = "horizontal"
        tab.secondaryUrl = URL(string: "https://second.example")
        container.mainContext.insert(tab)
        container.mainContext.insert(TabDataModelSchemaV10.SpaceURLRule(
            id: "dev-rule", spaceId: "dev-space", host: "dev.example", sortOrder: 0
        ))
        try container.mainContext.save()
    }

    // MARK: - CASE C-1: Real-store V11-to-V12 migration

    // Detects an omitted model among the five, a mistyped column that prevents lightweight
    // migration, and uppercase UUIDs minted by backfill.
    func testV11StoreMigratesToV12PreservingEveryRuleAndBackfillingSyncId() throws {
        let directory = try makeTemporaryDirectory()
        let seeded = try seedV11Store(at: directory, rules: Self.fourRules)

        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext

        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>(
            sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
        ))

        // Preserve the row count for every model type.
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(spaces.count, 3)
        XCTAssertEqual(tabs.count, seeded.tabCount)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(Set(profiles.map(\.profileId)), Set(seeded.profileIds))
        XCTAssertEqual(Set(spaces.map(\.spaceId)), Set(seeded.spaceIds))
        XCTAssertEqual(Set(tabs.map(\.guid)), Set(seeded.tabGuids))

        // Preserve all seven V11 rule fields exactly, including the nil pathPrefix.
        let byId = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        XCTAssertEqual(Set(byId.keys), Set(Self.fourRules.map(\.id)))
        for seed in Self.fourRules {
            let row = try XCTUnwrap(byId[seed.id], "rule \(seed.id) vanished in the migration")
            XCTAssertEqual(row.spaceId, seed.spaceId)
            XCTAssertEqual(row.host, seed.host)
            XCTAssertEqual(row.pathPrefix, seed.pathPrefix)
            XCTAssertEqual(row.askBeforeRouting, seed.askBeforeRouting)
            XCTAssertEqual(row.sortOrder, seed.sortOrder)
            XCTAssertEqual(row.createdDate, seed.createdDate)
        }
        XCTAssertTrue(Self.fourRules.contains { $0.pathPrefix == nil })

        let syncIds = try rules.map { try XCTUnwrap($0.syncId, "rule \($0.id) has no syncId after migration") }
        XCTAssertEqual(Set(syncIds).count, 4)
        for syncId in syncIds {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // The other five columns retain their defaults.
        for row in rules {
            XCTAssertNil(row.contentUpdatedDate)
            XCTAssertNil(row.targetUpdatedDate)
            XCTAssertNil(row.deletedDate)
            XCTAssertFalse(row.pendingLocalEdit)
            XCTAssertNil(row.mergePartnerSyncId)
        }

        for profile in profiles {
            XCTAssertNil(profile.syncId)
            XCTAssertNil(profile.createdDate)
        }
    }

    // MARK: - CASE C-1b: Real-store V12-to-V13 migration

    func testV12StoreMigratesToV13LeavingLocationUpdatedDateNil() throws {
        let directory = try makeTemporaryDirectory()
        let seeded = try seedV12Store(at: directory, rules: Self.fourRules)

        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext

        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>())
        XCTAssertEqual(tabs.count, seeded.tabCount)
        XCTAssertEqual(Set(tabs.map(\.guid)), Set(seeded.tabGuids))
        XCTAssertEqual(rules.count, 4)

        for tab in tabs {
            XCTAssertNil(tab.locationUpdatedDate, "the new column is not backfilled")
        }
        // The V11/V12 columns seeded above survive the upgrade untouched.
        let byGuid = Dictionary(uniqueKeysWithValues: tabs.map { ($0.guid, $0) })
        XCTAssertEqual(try XCTUnwrap(byGuid["tab-0"]).syncId, "tab-0-identity")
        XCTAssertEqual(try XCTUnwrap(byGuid["tab-0"]).contentUpdatedDate,
                       Self.seededContentEditDate)
        XCTAssertEqual(Set(rules.compactMap(\.syncId)).count, 4)
    }

    // MARK: - CASE C-2: Migration-plan structure assertions

    // If migrateV11toV12 or migrateV12toV13 is omitted from stages, schemas and the typealias
    // still name the newest schema, so SwiftData can infer a lightweight migration while skipping
    // didMigrate's syncId backfill entirely. This is the only detector of that omission.
    func testMigrationPlanEndsAtV13WithOneStagePerUpgrade() throws {
        let schemas = TabDataModelMigrationPlan.schemas
        let stages = TabDataModelMigrationPlan.stages

        XCTAssertEqual(schemas.count, 13)
        XCTAssertEqual(stages.count, schemas.count - 1)
        let last = try XCTUnwrap(schemas.last)
        XCTAssertEqual(ObjectIdentifier(last), ObjectIdentifier(TabDataModelSchemaV13.self))
        XCTAssertEqual(TabDataModelSchemaV12.versionIdentifier, Schema.Version(12, 0, 0))
        XCTAssertEqual(TabDataModelSchemaV13.versionIdentifier, Schema.Version(13, 0, 0))
        XCTAssertEqual(TabDataModelSchemaV13.models.count, 5)
        // The compatibility manifest gates the downgrade path and must move with the schema.
        XCTAssertEqual(LocalStore.compatibilityConfiguration.currentStoreFormatVersion, 13)
        XCTAssertTrue(LocalStore.compatibilityConfiguration.canReadStoreFormatVersion(13))
    }


    // Including soft-deleted rows in default reads includes them in dense sortOrder
    // normalization. The deleting device retains those indexes, while the follower hard-deletes
    // inbound tombstones; indexes then differ by the number of preceding deleted rows,
    // changing cross-Space tie winners. An unfiltered publisher also keeps deleted rules
    // visible in the editor and active in Chromium routing.
    func testDefaultReadPathsHideSoftDeletedRules() throws {
        let directory = try makeTemporaryDirectory()
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())

        // Subscribe and receive the initial empty-store value before inserting and saving rows.
        var emissions: [[SpaceRoutingRule]] = []
        let postSave = expectation(description: "urlRulesPublisher re-emits after the save")
        let cancellable = store.urlRulesPublisher()
            .sink { rules in
                emissions.append(rules)
                if emissions.count == 2 { postSave.fulfill() }
            }
        defer { cancellable.cancel() }
        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions.first?.count, 0)

        let softDeletedId = "a-1"
        context.insert(SpaceURLRule(id: "a-0", spaceId: "space-a", host: "a.example", sortOrder: 0))
        context.insert(SpaceURLRule(id: softDeletedId, spaceId: "space-a", host: "b.example", sortOrder: 1,
                                    deletedDate: Date()))
        context.insert(SpaceURLRule(id: "a-2", spaceId: "space-a", host: "c.example", sortOrder: 2))
        context.insert(SpaceURLRule(id: "b-0", spaceId: "space-b", host: "d.example", sortOrder: 0))
        try context.save()

        // ① Read all rules.
        let all = store.getAllURLRules()
        XCTAssertEqual(all.map(\.id), ["a-0", "a-2", "b-0"])
        XCTAssertFalse(all.contains { $0.id == softDeletedId })

        // ② Read by Space without renumbering: sortOrder remains [0, 2].
        let spaceA = store.getURLRules(forSpaceId: "space-a")
        XCTAssertEqual(spaceA.map(\.id), ["a-0", "a-2"])
        XCTAssertEqual(spaceA.map(\.sortOrder), [0, 2])

        // ③ The publisher value emitted after NSManagedObjectContextDidSave.
        wait(for: [postSave], timeout: 5)
        XCTAssertEqual(emissions.count, 2)
        let published = try XCTUnwrap(emissions.last)
        XCTAssertEqual(published.map(\.id), all.map(\.id))
        XCTAssertEqual(published.map(\.spaceId), all.map(\.spaceId))
        XCTAssertEqual(published.map(\.sortOrder), all.map(\.sortOrder))
        XCTAssertFalse(published.contains { $0.id == softDeletedId })
    }


    // Without lowercased(), local identities differ from other devices' lowercase UUIDs and
    // per-row syncId addressing can split one rule into two. Without the syncId == nil guard,
    // a repeat backfill remints published identities, orphaning account entities and leaving
    // two rules with the old one permanently unclaimed.
    func testSyncIdBackfillMintsDistinctLowercaseUUIDsAndIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        _ = try seedV11Store(at: directory, rules: Self.sixRules)

        // ① First open: run production migrateV11toV12 and record the six syncIds.
        let firstOpen = try readSyncIdsAfterProductionOpen(at: directory)
        XCTAssertEqual(firstOpen.count, 6)
        XCTAssertEqual(Set(firstOpen.values).count, 6)
        for syncId in firstOpen.values {
            XCTAssertEqual(syncId, syncId.lowercased())
            XCTAssertNotNil(UUID(uuidString: syncId))
        }

        // ② Reopen the V12 store, which skips didMigrate; manually repeat equivalent backfill
        // reads and writes in this context to prove the closure itself is idempotent.
        let container = try openWithProductionMigrationPlan(at: directory)
        let context = container.mainContext
        let rules = try context.fetch(FetchDescriptor<SpaceURLRule>())
        for rule in rules where rule.syncId == nil {
            rule.syncId = UUID().uuidString.lowercased()
        }
        try context.save()

        let reread = try context.fetch(FetchDescriptor<SpaceURLRule>())
        XCTAssertEqual(reread.count, 6)
        for rule in reread {
            XCTAssertEqual(rule.syncId, firstOpen[rule.id], "rule \(rule.id) was re-minted")
        }
    }

    // MARK: - Fixtures

    private struct SeedRule {
        let id: String
        let spaceId: String
        let host: String
        let pathPrefix: String?
        let askBeforeRouting: Bool
        let sortOrder: Int
        let createdDate: Date
    }

    private struct SeededV11Store {
        let profileIds: [String]
        let spaceIds: [String]
        let tabGuids: [String]
        var tabCount: Int { tabGuids.count }
    }

    // Four rows in two Space buckets with dense sortOrder; one has nil pathPrefix.
    private static let fourRules: [SeedRule] = [
        SeedRule(id: "rule-a-0", spaceId: "space-a", host: "a.example", pathPrefix: "/docs",
                 askBeforeRouting: false, sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1_700_000_001)),
        SeedRule(id: "rule-a-1", spaceId: "space-a", host: "b.example", pathPrefix: nil,
                 askBeforeRouting: true, sortOrder: 1, createdDate: Date(timeIntervalSince1970: 1_700_000_002)),
        SeedRule(id: "rule-a-2", spaceId: "space-a", host: "c.example", pathPrefix: "/x/y",
                 askBeforeRouting: false, sortOrder: 2, createdDate: Date(timeIntervalSince1970: 1_700_000_003)),
        SeedRule(id: "rule-b-0", spaceId: "space-b", host: "d.example", pathPrefix: "/z",
                 askBeforeRouting: true, sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1_700_000_004)),
    ]

    private static let sixRules: [SeedRule] = fourRules + [
        SeedRule(id: "rule-b-1", spaceId: "space-b", host: "e.example", pathPrefix: nil,
                 askBeforeRouting: false, sortOrder: 1, createdDate: Date(timeIntervalSince1970: 1_700_000_005)),
        SeedRule(id: "rule-b-2", spaceId: "space-b", host: "f.example", pathPrefix: "/q",
                 askBeforeRouting: false, sortOrder: 2, createdDate: Date(timeIntervalSince1970: 1_700_000_006)),
    ]

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    /// Create a real ModelContainer with explicit V11 model types, following
    /// PinnedTabScopeTests.seedV8Store(at:). Write two Profiles, three Spaces, the rules,
    /// and three tabs; save and release the container.
    @discardableResult
    private func seedV11Store(at directory: URL, rules: [SeedRule]) throws -> SeededV11Store {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        let container = try ModelContainer(
            for: TabDataModelSchemaV11.ProfileModel.self,
            TabDataModelSchemaV11.TabDataModel.self,
            TabDataModelSchemaV11.SpaceModel.self,
            TabDataModelSchemaV11.SpaceURLRule.self,
            TabDataModelSchemaV11.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let context = container.mainContext

        let profileIds = ["Default", "Work"]
        for profileId in profileIds {
            context.insert(TabDataModelSchemaV11.ProfileModel(profileId: profileId))
        }

        let spaceIds = ["space-a", "space-b", "space-c"]
        for (index, spaceId) in spaceIds.enumerated() {
            context.insert(TabDataModelSchemaV11.SpaceModel(
                spaceId: spaceId,
                profileId: index < 2 ? "Default" : "Work",
                name: "Space \(index)",
                colorHex: "#000000",
                iconName: "globe",
                sortOrder: index,
                createdDate: Date(timeIntervalSince1970: 1_700_000_100),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        }

        let tabGuids = ["tab-0", "tab-1", "tab-2"]
        for (index, guid) in tabGuids.enumerated() {
            let tab = TabDataModelSchemaV11.TabDataModel(
                title: "Tab \(index)",
                guid: guid,
                index: index,
                url: try XCTUnwrap(URL(string: "https://tab\(index).example")),
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 1_700_000_200),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_200)
            )
            tab.profileId = "Default"
            context.insert(tab)
        }

        for seed in rules {
            context.insert(TabDataModelSchemaV11.SpaceURLRule(
                id: seed.id,
                spaceId: seed.spaceId,
                host: seed.host,
                pathPrefix: seed.pathPrefix,
                askBeforeRouting: seed.askBeforeRouting,
                sortOrder: seed.sortOrder,
                createdDate: seed.createdDate
            ))
        }
        try context.save()
        return SeededV11Store(profileIds: profileIds, spaceIds: spaceIds, tabGuids: tabGuids)
    }

    /// Reopen the store with production TabDataModelMigrationPlan and V12 aliases, using
    /// the exact model list from LocalStore.swift's ModelContainer(for:).
    private func openWithProductionMigrationPlan(at directory: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        return try ModelContainer(
            for: TabDataModel.self,
            ProfileModel.self,
            SpaceModel.self,
            SpaceURLRule.self,
            BrowserDataSettingsModel.self,
            migrationPlan: TabDataModelMigrationPlan.self,
            configurations: configuration
        )
    }

    private nonisolated static let seededContentEditDate = Date(timeIntervalSince1970: 1_700_000_300)

    @discardableResult
    private func seedV12Store(at directory: URL, rules: [SeedRule]) throws -> SeededV11Store {
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("LocalStore.sqlite")
        )
        let container = try ModelContainer(
            for: TabDataModelSchemaV12.ProfileModel.self,
            TabDataModelSchemaV12.TabDataModel.self,
            TabDataModelSchemaV12.SpaceModel.self,
            TabDataModelSchemaV12.SpaceURLRule.self,
            TabDataModelSchemaV12.BrowserDataSettingsModel.self,
            configurations: configuration
        )
        let context = container.mainContext

        let profileIds = ["Default", "Work"]
        for profileId in profileIds {
            context.insert(TabDataModelSchemaV12.ProfileModel(profileId: profileId))
        }

        let spaceIds = ["space-a", "space-b", "space-c"]
        for (index, spaceId) in spaceIds.enumerated() {
            context.insert(TabDataModelSchemaV12.SpaceModel(
                spaceId: spaceId,
                profileId: index < 2 ? "Default" : "Work",
                name: "Space \(index)",
                colorHex: "#000000",
                iconName: "globe",
                sortOrder: index,
                createdDate: Date(timeIntervalSince1970: 1_700_000_100),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_100)
            ))
        }

        let tabGuids = ["tab-0", "tab-1", "tab-2"]
        for (index, guid) in tabGuids.enumerated() {
            let tab = TabDataModelSchemaV12.TabDataModel(
                title: "Tab \(index)",
                guid: guid,
                index: index,
                url: try XCTUnwrap(URL(string: "https://tab\(index).example")),
                favicon: nil,
                createdDate: Date(timeIntervalSince1970: 1_700_000_200),
                updatedDate: Date(timeIntervalSince1970: 1_700_000_200)
            )
            tab.profileId = "Default"
            if guid == "tab-0" {
                tab.syncId = "tab-0-identity"
                tab.contentUpdatedDate = Self.seededContentEditDate
            }
            context.insert(tab)
        }

        for seed in rules {
            context.insert(TabDataModelSchemaV12.SpaceURLRule(
                id: seed.id,
                spaceId: seed.spaceId,
                host: seed.host,
                pathPrefix: seed.pathPrefix,
                askBeforeRouting: seed.askBeforeRouting,
                sortOrder: seed.sortOrder,
                createdDate: seed.createdDate,
                syncId: UUID().uuidString.lowercased()
            ))
        }
        try context.save()
        return SeededV11Store(profileIds: profileIds, spaceIds: spaceIds, tabGuids: tabGuids)
    }

    /// Open once and read each rule's syncId by id; release the container before returning.
    private func readSyncIdsAfterProductionOpen(at directory: URL) throws -> [String: String] {
        let container = try openWithProductionMigrationPlan(at: directory)
        let rules = try container.mainContext.fetch(FetchDescriptor<SpaceURLRule>())
        var byId: [String: String] = [:]
        for rule in rules {
            byId[rule.id] = try XCTUnwrap(rule.syncId, "rule \(rule.id) has no syncId after migration")
        }
        return byId
    }

    // MARK: - Task 5: Write APIs, per-row primitives, normalization, and cascade origin

    private static let spaceOne = "space-1"
    private static let spaceTwo = "space-2"
    private static let spaceThree = "space-3"
    // nonisolated: landing's default arguments are evaluated outside actor isolation.
    // Referencing a main-actor static there warns; this immutable Sendable constant is safe to isolate independently.
    private nonisolated static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let t1 = Date(timeIntervalSince1970: 1_700_000_500)


    // The old replace paths used performBackgroundWrite, returned silently for nil writeActor,
    // and swallowed body errors in catch { AppLogError... }. Callers could not distinguish
    // failure from persistence; retaining a nonthrowing API would let them return to that path.
    func testApplyURLRuleEditsThrowsStoreUnavailableWhenTheStoreNeverOpened() async throws {
        // (a) Occupy the store directory path with a regular file. LocalStore.init's try?
        // createDirectory fails, then prepareStore's createDirectory throws: failed state, nil writeActor.
        let parent = try makeTemporaryDirectory()
        let blocked = parent.appendingPathComponent("localDB", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked.path, contents: Data()))
        let store = LocalStore(account: Account(userID: "test-user"),
                               storeDirectoryURL: blocked,
                               presentsCompatibilityAlerts: false)
        if case .failed = store.compatibilityStatus {
            // expected
        } else {
            XCTFail("store on a blocked path should be .failed, got \(store.compatibilityStatus)")
        }
        XCTAssertNil(store.getMainContext())

        await assertThrows(.storeUnavailable) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(host: "a.example", spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
    }

    // MARK: CASE C-7: Change only the named rows and fields

    // Delete-then-insert used to remint every id in the bucket on save. Marking soft-deleted
    // rows would let them yield to inbound tombstones; failing to renumber r2 leaves indexes
    // 0/2. Part (b) prevents the insert branch from replacing nil cells with defaults and
    // letting empty host or spaceId values enter routing, snapshots, and the account.
    func testApplyURLRuleEditsTouchesOnlyTheNamedRowsAndFields() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "r0", spaceId: Self.spaceOne, host: "r0.example", pathPrefix: "/r0",
                     sortOrder: 0, syncId: "R0", contentUpdatedDate: Self.t0),
            RuleSeed(id: "r1", spaceId: Self.spaceOne, host: "r1.example", sortOrder: 1,
                     syncId: "R1", contentUpdatedDate: Self.t0),
            RuleSeed(id: "r2", spaceId: Self.spaceOne, host: "r2.example", pathPrefix: "/r2",
                     askBeforeRouting: true, sortOrder: 2, syncId: "R2", contentUpdatedDate: Self.t0),
        ], in: store)
        let before = try allRows(in: store)
        let r0Before = try XCTUnwrap(before["r0"])

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0",
                                              host: "changed.example",
                                              pathPrefix: r0Before.pathPrefix,
                                              askBeforeRouting: r0Before.askBeforeRouting,
                                              spaceId: Self.spaceOne,
                                              sortOrder: 0)],
            deletedIds: ["r1"]
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 2)

        let r0 = try XCTUnwrap(after["r0"])
        XCTAssertEqual(r0.id, "r0")
        XCTAssertEqual(r0.syncId, "R0")
        XCTAssertEqual(r0.host, "changed.example")
        XCTAssertEqual(r0.pathPrefix, "/r0")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertNil(r0.targetUpdatedDate)
        XCTAssertNil(r0.deletedDate)
        XCTAssertFalse(r0.pendingLocalEdit)
        XCTAssertEqual(r0.sortOrder, 0)

        XCTAssertNil(after["r1"])

        // r2 remains unchanged except sortOrder becomes 1 to close the soft-deletion gap (ruling 4).
        var r2Expected = try XCTUnwrap(before["r2"])
        r2Expected.sortOrder = 1
        XCTAssertEqual(after["r2"], r2Expected)
    }

    func testInsertBranchRefusesADraftMissingAUnit() async throws {
        let store = try makeStore()
        try await seed([
            RuleSeed(id: "r0", spaceId: Self.spaceOne, host: "r0.example", sortOrder: 0, syncId: "R0"),
        ], in: store)
        let before = try allRows(in: store)

        // Nonnil content, nil spaceId.
        await assertThrows(.noCandidateSurvived) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(
                    id: "fresh-1",
                    content: LocalStore.URLRuleDraft.ContentUnit(host: "x.example"),
                    spaceId: nil
                )],
                deletedIds: []
            )
        }
        // Conversely: nonnil spaceId, nil content.
        await assertThrows(.noCandidateSurvived) {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "fresh-2", content: nil, spaceId: Self.spaceOne)],
                deletedIds: []
            )
        }
        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.count, 1)
    }


    // A per-target-Space index mistakes this move for a caller error and throws rowAlreadyMapped.
    // Inserting on lookup failure instead creates two rules sharing one syncId. Normalizing
    // only the target bucket leaves indexes 0/2 in S1.
    func testRetargetKeepsIdentityAndRedensifiesBothBuckets() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "s1-1", content: nil,
                                              spaceId: Self.spaceTwo, sortOrder: 2)],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.syncId, "R-s1-1")
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        XCTAssertEqual(moved.host, before["s1-1"]?.host)
        XCTAssertFalse(moved.pendingLocalEdit)
        XCTAssertEqual(moved.sortOrder, 2)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
        XCTAssertEqual(Set(after.values.compactMap(\.syncId)), Set(before.values.compactMap(\.syncId)))
    }

    func testRetargetAndAContentEditInOneBatchEachLandInTheirOwnBucket() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds + [
            RuleSeed(id: "s3-0", spaceId: Self.spaceThree, host: "s3.example", sortOrder: 0,
                     syncId: "R-s3-0", contentUpdatedDate: Self.t0),
        ], in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [
                LocalStore.URLRuleDraft(id: "s1-1", content: nil,
                                        spaceId: Self.spaceTwo, sortOrder: 2),
                LocalStore.URLRuleDraft(id: "s3-0",
                                        content: LocalStore.URLRuleDraft.ContentUnit(host: "s3-new.example"),
                                        spaceId: nil),
            ],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 6)
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(moved.syncId, "R-s1-1")
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        let edited = try XCTUnwrap(after["s3-0"])
        XCTAssertEqual(edited.host, "s3-new.example")
        XCTAssertEqual(edited.spaceId, Self.spaceThree)
        assertStampedNow(edited.contentUpdatedDate, between: start, and: end)
        XCTAssertNil(edited.targetUpdatedDate)
        XCTAssertFalse(edited.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
        XCTAssertEqual(bucketOrder(Self.spaceThree, in: after), [0])
    }




    // An in-place upsert ignoring deletedDate writes the edit into an invisible row, then
    // tombstone acceptance hard-deletes it: a successful save loses the rule. Resurrecting
    // the row is also wrong; only 3b does that. Reusing draft.id violates Attribute.unique.
    // Variant ② keeps the APIs distinct: the per-row primitive in C-9 ① must address the
    // soft-deleted row and clear deletedDate.
    private static let softDeletedHitSeeds: [RuleSeed] = [
        RuleSeed(id: "I", spaceId: spaceOne, host: "old.example", sortOrder: 0, syncId: "R1",
                 contentUpdatedDate: t0, deletedDate: t1, pendingLocalEdit: false, mergePartnerSyncId: "R9"),
        RuleSeed(id: "J", spaceId: spaceOne, host: "j.example", sortOrder: 1, syncId: "RJ",
                 contentUpdatedDate: t0),
    ]

    private static func recoveryDraft() -> LocalStore.URLRuleDraft {
        LocalStore.URLRuleDraft(
            id: "I",

            content: LocalStore.URLRuleDraft.ContentUnit(host: "new.example", pathPrefix: "/p",
                                                         askBeforeRouting: true),
            spaceId: spaceOne,
            sortOrder: 0
        )
    }

    func testEditorDraftHittingASoftDeletedRowInsertsAFreshIdentity() async throws {
        let store = try makeStore()
        try await seed(Self.softDeletedHitSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(upserts: [Self.recoveryDraft()], deletedIds: [])

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after["I"], before["I"], "the soft-deleted row is not touched")
        XCTAssertEqual(after["J"], before["J"])

        let fresh = try XCTUnwrap(after.values.first { $0.id != "I" && $0.id != "J" })
        XCTAssertNotNil(UUID(uuidString: fresh.id))
        XCTAssertNil(fresh.syncId)
        XCTAssertEqual(fresh.host, "new.example")
        XCTAssertEqual(fresh.pathPrefix, "/p")
        XCTAssertTrue(fresh.askBeforeRouting)
        XCTAssertEqual(fresh.spaceId, Self.spaceOne)
        XCTAssertNil(fresh.deletedDate)
        XCTAssertNil(fresh.mergePartnerSyncId)
        XCTAssertFalse(fresh.pendingLocalEdit)
        XCTAssertNil(fresh.contentUpdatedDate, "a new row does not mint a content stamp (ruling 5)")
        XCTAssertNil(fresh.targetUpdatedDate)
        XCTAssertEqual(fresh.sortOrder, 0)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
    }

    func testEditorDraftHittingALiveRowIsAnOrdinaryUpsert() async throws {
        let store = try makeStore()
        var seeds = Self.softDeletedHitSeeds
        seeds[0].deletedDate = nil
        try await seed(seeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(upserts: [Self.recoveryDraft()], deletedIds: [])
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 2, "no new row")
        let row = try XCTUnwrap(after["I"])
        XCTAssertEqual(row.syncId, "R1")
        XCTAssertEqual(row.host, "new.example")
        assertStampedNow(row.contentUpdatedDate, between: start, and: end)
        XCTAssertFalse(row.pendingLocalEdit)
    }


    // Stripping trailing slashes before decoding makes f("/%2F") == "//", silently widening
    // semantics. Stripping dots before trimming maps host "a. ." to "a.". Without a fixed
    // point, every normalization triggers mustRepublish and another commit, preventing convergence.
    func testNormalizationIsAFixedPoint() {
        let hosts = ["GitHub.COM", "github.com.", "github.com..", "github.com .", "github.com ..",
                     "github.com . .", "a. .", "a. . .", " github.com. ", " *.Figma.com "]
        let paths: [String?] = ["/foo/", "/", "/foo%2F", "/%2F", "%2F", "/a%252F",
                                "/r%C3%A9sum%C3%A9", "/100%complete"]
        for host in hosts {
            for path in paths {
                assertFixedPoint(host: host, pathPrefix: path)
            }
        }

        // Two hundred randomly generated inputs with a deterministic seed.
        var generator = SeededGenerator(seed: 0x5EED_5EED)
        let atoms = ["a", "Z", "7", ".", " ", "\n", "/", "%", "2F", "é", "\u{4e2d}", "-"]
        for _ in 0..<200 {
            let host = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            let path = (0..<Int.random(in: 0...8, using: &generator))
                .map { _ in atoms[Int.random(in: 0..<atoms.count, using: &generator)] }
                .joined()
            assertFixedPoint(host: host, pathPrefix: path)
        }

        // Concrete expected values.
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/%2F"), "/")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/foo%2F"), "/foo")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/a%252F"), "/a%252F")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("/"), "/")
        XCTAssertEqual(LocalStore.normalizedPathPrefix("///"), "/")
        XCTAssertNil(LocalStore.normalizedPathPrefix(""))
        XCTAssertNil(LocalStore.normalizedPathPrefix(nil))
        XCTAssertEqual(LocalStore.normalizedHost("a. ."), "a")
        XCTAssertEqual(LocalStore.normalizedHost("a. . ."), "a")
        XCTAssertEqual(LocalStore.normalizedHost("github.com .."), "github.com")
        XCTAssertEqual(LocalStore.normalizedHost(" GitHub.COM. "), "github.com")
    }


    // Covers C-8 plus implementations that split retargeting into delete and insert:
    // changing syncId severs the account rule's history, including both timestamps.
    func testSingleRetargetUpsertMovesTheRowBetweenBuckets() async throws {
        let store = try makeStore()
        try await seed(Self.twoBucketSeeds, in: store)
        let before = try allRows(in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "s1-1", content: nil,
                                              spaceId: Self.spaceTwo, sortOrder: 2)],
            deletedIds: []
        )
        let end = Date()

        let after = try allRows(in: store)
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        let moved = try XCTUnwrap(after["s1-1"])
        XCTAssertEqual(moved.syncId, before["s1-1"]?.syncId)
        XCTAssertEqual(moved.spaceId, Self.spaceTwo)
        XCTAssertEqual(moved.contentUpdatedDate, Self.t0)
        assertStampedNow(moved.targetUpdatedDate, between: start, and: end)
        XCTAssertFalse(moved.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: after), [0, 1])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: after), [0, 1, 2])
    }


    // Stamping both groups on any row change advances targetUpdatedDate for a rename (⑤).
    // Treating nil cells as explicit nil/default writes clears spaceId in ① and host in ②.
    // Flagging every upsert makes no-ops ④/⑥ leave quiescence; not flagging drag operations
    // lets convergence overwrite the user's ordering intent with machine writes.
    private static let stampTableSeeds: [RuleSeed] = [
        RuleSeed(id: "r0", spaceId: spaceOne, host: "r0.example", pathPrefix: "/r0", sortOrder: 0,
                 syncId: "R0", contentUpdatedDate: t0, targetUpdatedDate: t0),
        RuleSeed(id: "r1", spaceId: spaceOne, host: "r1.example", pathPrefix: "/r1", sortOrder: 1,
                 syncId: "R1", contentUpdatedDate: t0, targetUpdatedDate: t0),
    ]

    private static let changedContent = LocalStore.URLRuleDraft.ContentUnit(
        host: "r0-changed.example", pathPrefix: "/r0", askBeforeRouting: false
    )

    func testStampTableContentOnlyWritesTheContentStamp() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: Self.changedContent, spaceId: nil)],
            deletedIds: []
        )
        let end = Date()

        let r0 = try row("r0", in: store)
        XCTAssertEqual(r0.host, "r0-changed.example")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t0)
        XCTAssertEqual(r0.spaceId, Self.spaceOne)
        XCTAssertFalse(r0.pendingLocalEdit)
    }

    func testStampTableTargetOnlyWritesTheTargetStamp() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: nil, spaceId: Self.spaceTwo)],
            deletedIds: []
        )
        let end = Date()

        let rows = try allRows(in: store)
        let r0 = try XCTUnwrap(rows["r0"])
        assertStampedNow(r0.targetUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r0.host, "r0.example")
        XCTAssertEqual(r0.pathPrefix, "/r0")
        XCTAssertFalse(r0.askBeforeRouting)
        XCTAssertEqual(r0.spaceId, Self.spaceTwo)
        XCTAssertFalse(r0.pendingLocalEdit)
        XCTAssertEqual(bucketOrder(Self.spaceOne, in: rows), [0])
        XCTAssertEqual(bucketOrder(Self.spaceTwo, in: rows), [0])
    }

    func testStampTableReorderWritesNoStampOrPendingFlag() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [
                LocalStore.URLRuleDraft(id: "r0", content: nil, spaceId: nil, sortOrder: 1),
                LocalStore.URLRuleDraft(id: "r1", content: nil, spaceId: nil, sortOrder: 0),
            ],
            deletedIds: []
        )

        let rows = try allRows(in: store)
        let r0 = try XCTUnwrap(rows["r0"])
        let r1 = try XCTUnwrap(rows["r1"])
        XCTAssertEqual(r0.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t0)
        XCTAssertEqual(r1.contentUpdatedDate, Self.t0)
        XCTAssertEqual(r1.targetUpdatedDate, Self.t0)
        XCTAssertFalse(r0.pendingLocalEdit)
        XCTAssertFalse(r1.pendingLocalEdit)
        XCTAssertEqual(r0.sortOrder, 1)
        XCTAssertEqual(r1.sortOrder, 0)
    }

    func testStampTableUnchangedUnitsAreAZeroWrite() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(
                id: "r0",
                content: LocalStore.URLRuleDraft.ContentUnit(host: "r0.example", pathPrefix: "/r0",
                                                             askBeforeRouting: false),
                spaceId: Self.spaceOne,
                sortOrder: 0
            )],
            deletedIds: []
        )

        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertFalse(try XCTUnwrap(after["r0"]).pendingLocalEdit)
    }

    func testStampTableContentOnlySaveDoesNotEatARemoteRetarget() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        // Simulate a remote retarget applied while the sheet is open.
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let rows = try context.fetch(FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.id == "r0" }
            ))
            for row in rows {
                row.spaceId = Self.spaceTwo
                row.targetUpdatedDate = Self.t1
            }
        }

        let start = Date()
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0", content: Self.changedContent, spaceId: nil)],
            deletedIds: []
        )
        let end = Date()

        let r0 = try row("r0", in: store)
        XCTAssertEqual(r0.host, "r0-changed.example")
        assertStampedNow(r0.contentUpdatedDate, between: start, and: end)
        XCTAssertEqual(r0.spaceId, Self.spaceTwo)
        XCTAssertEqual(r0.targetUpdatedDate, Self.t1)
        XCTAssertFalse(r0.pendingLocalEdit)
    }

    func testStampTableAnEmptyUpsertIsAZeroWrite() async throws {
        let store = try makeStore()
        try await seed(Self.stampTableSeeds, in: store)
        let before = try allRows(in: store)

        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "r0")],
            deletedIds: []
        )

        let after = try allRows(in: store)
        XCTAssertEqual(after, before)
        XCTAssertFalse(try XCTUnwrap(after["r0"]).pendingLocalEdit)
    }



    func testSpaceCascadeHardDeletesRulesIncludingPreviouslyDeletedRows() async throws {
        let store = try makeStore()
        try await seedCascadeFixture(in: store, preSoftDeletedRuleId: "s1-2")

        try await store.deleteSpaceCascadeThrowing(spaceId: Self.spaceOne)

        try assertSpaceAndTabsGone(in: store)
        let rows = try allRows(in: store)
        XCTAssertEqual(Array(rows.keys), ["s2-0"])
        XCTAssertNil(rows["s2-0"]?.deletedDate)
    }


    // MARK: - Task 5 fixtures

    /// The thirteen row columns; construct SpaceURLRule inside the write block so Model instances never cross contexts.
    private struct RuleSeed {
        var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String? = nil
        var askBeforeRouting: Bool = false
        var sortOrder: Int
        var createdDate: Date = Date(timeIntervalSince1970: 1_690_000_000)
        var syncId: String? = nil
        var contentUpdatedDate: Date? = nil
        var targetUpdatedDate: Date? = nil
        var deletedDate: Date? = nil
        var pendingLocalEdit: Bool = false
        var mergePartnerSyncId: String? = nil
    }

    /// Value snapshot of all thirteen columns, fetched from the main context including soft-deleted rows.
    private struct RuleRow: Equatable {
        var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String?
        var askBeforeRouting: Bool
        var sortOrder: Int
        var createdDate: Date
        var syncId: String?
        var contentUpdatedDate: Date?
        var targetUpdatedDate: Date?
        var deletedDate: Date?
        var pendingLocalEdit: Bool
        var mergePartnerSyncId: String?

        init(_ rule: SpaceURLRule) {
            id = rule.id
            spaceId = rule.spaceId
            host = rule.host
            pathPrefix = rule.pathPrefix
            askBeforeRouting = rule.askBeforeRouting
            sortOrder = rule.sortOrder
            createdDate = rule.createdDate
            syncId = rule.syncId
            contentUpdatedDate = rule.contentUpdatedDate
            targetUpdatedDate = rule.targetUpdatedDate
            deletedDate = rule.deletedDate
            pendingLocalEdit = rule.pendingLocalEdit
            mergePartnerSyncId = rule.mergePartnerSyncId
        }
    }

    // Three S1 rows (0/1/2) and two S2 rows (0/1), all with syncId and a fixed contentUpdatedDate.
    private static let twoBucketSeeds: [RuleSeed] = [
        RuleSeed(id: "s1-0", spaceId: spaceOne, host: "s1-0.example", sortOrder: 0, syncId: "R-s1-0",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s1-1", spaceId: spaceOne, host: "s1-1.example", sortOrder: 1, syncId: "R-s1-1",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s1-2", spaceId: spaceOne, host: "s1-2.example", sortOrder: 2, syncId: "R-s1-2",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s2-0", spaceId: spaceTwo, host: "s2-0.example", sortOrder: 0, syncId: "R-s2-0",
                 contentUpdatedDate: t0),
        RuleSeed(id: "s2-1", spaceId: spaceTwo, host: "s2-1.example", sortOrder: 1, syncId: "R-s2-1",
                 contentUpdatedDate: t0),
    ]

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryDirectory()
        return LocalStore(account: Account(userID: "test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func seed(_ seeds: [RuleSeed], in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for seed in seeds {
                context.insert(SpaceURLRule(
                    id: seed.id,
                    spaceId: seed.spaceId,
                    host: seed.host,
                    pathPrefix: seed.pathPrefix,
                    askBeforeRouting: seed.askBeforeRouting,
                    sortOrder: seed.sortOrder,
                    createdDate: seed.createdDate,
                    syncId: seed.syncId,
                    contentUpdatedDate: seed.contentUpdatedDate,
                    targetUpdatedDate: seed.targetUpdatedDate,
                    deletedDate: seed.deletedDate,
                    pendingLocalEdit: seed.pendingLocalEdit,
                    mergePartnerSyncId: seed.mergePartnerSyncId
                ))
            }
        }
    }

    /// U-13/U-13c fixture: one S1 SpaceModel, two S1 tabs and an S2 control tab, three
    /// S1 rules with pendingLocalEdit = false, and one S2 control rule.
    private func seedCascadeFixture(in store: LocalStore, preSoftDeletedRuleId: String?) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            context.insert(SpaceModel(spaceId: Self.spaceOne, profileId: "Default", name: "One",
                                      colorHex: "#000000", iconName: "globe", sortOrder: 0))
            for (index, spaceId) in [Self.spaceOne, Self.spaceOne, Self.spaceTwo].enumerated() {
                let tab = TabDataModel(title: "Tab \(index)", guid: "tab-\(index)", index: index,
                                       url: URL(string: "https://tab\(index).example")!, favicon: nil,
                                       createdDate: Self.t0, updatedDate: Self.t0)
                tab.profileId = "Default"
                tab.spaceId = spaceId
                context.insert(tab)
            }
        }
        var seeds: [RuleSeed] = [
            RuleSeed(id: "s1-0", spaceId: Self.spaceOne, host: "s1-0.example", sortOrder: 0, syncId: "R-s1-0"),
            RuleSeed(id: "s1-1", spaceId: Self.spaceOne, host: "s1-1.example", sortOrder: 1, syncId: "R-s1-1"),
            RuleSeed(id: "s1-2", spaceId: Self.spaceOne, host: "s1-2.example", sortOrder: 2, syncId: "R-s1-2"),
            RuleSeed(id: "s2-0", spaceId: Self.spaceTwo, host: "s2-0.example", sortOrder: 0, syncId: "R-s2-0"),
        ]
        if let preSoftDeletedRuleId {
            for index in seeds.indices where seeds[index].id == preSoftDeletedRuleId {
                seeds[index].deletedDate = Self.t1
            }
        }
        try await seed(seeds, in: store)
    }

    private func assertSpaceAndTabsGone(in store: LocalStore,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let spaceOne = Self.spaceOne
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceOne }
        ))
        XCTAssertTrue(spaces.isEmpty, "SpaceModel row survived the cascade", file: file, line: line)
        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        XCTAssertEqual(tabs.map(\.guid), ["tab-2"], "only the S2 tab survives", file: file, line: line)
    }

    private func allRows(in store: LocalStore) throws -> [String: RuleRow] {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, RuleRow($0)) })
    }

    private func row(_ id: String, in store: LocalStore,
                     file: StaticString = #filePath, line: UInt = #line) throws -> RuleRow {
        try XCTUnwrap(try allRows(in: store)[id], "rule \(id) is missing", file: file, line: line)
    }

    /// Ascending sortOrder values for live rows in the bucket, excluding soft-deleted rows.
    private func bucketOrder(_ spaceId: String, in rows: [String: RuleRow]) -> [Int] {
        rows.values
            .filter { $0.spaceId == spaceId && $0.deletedDate == nil }
            .map(\.sortOrder)
            .sorted()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Assert now falls between timestamps taken immediately before and after the call.
    private func assertStampedNow(_ stamp: Date?, between start: Date, and end: Date,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let stamp else {
            XCTFail("expected a `now` stamp, got nil", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(stamp, start, file: file, line: line)
        XCTAssertLessThanOrEqual(stamp, end, file: file, line: line)
    }

    private func assertFixedPoint(host: String, pathPrefix: String?,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let once = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        let twice = LocalStore.normalizedRule(host: once.host, pathPrefix: once.pathPrefix)
        XCTAssertEqual(twice.host, once.host, "host not a fixed point for \(host.debugDescription)",
                       file: file, line: line)
        XCTAssertEqual(twice.pathPrefix, once.pathPrefix,
                       "path not a fixed point for \(String(describing: pathPrefix).debugDescription)",
                       file: file, line: line)
    }

    // Assertions use autoclosures; read values before asserting.
    private func assertThrows(_ expected: LocalStoreWriteError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown.", file: file, line: line)
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// A source file relative to the repository root; #filePath is Tests/PhiBrowserTests/<this>.swift.
    private static func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// Deterministic SplitMix64 random source keeps U-6's 200 generated inputs reproducible.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
