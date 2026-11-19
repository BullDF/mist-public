// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import Combine
import SwiftData
import Cocoa
@testable import Phi

@MainActor
final class LocalStoreProfileTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testMigratingLegacyStoreAssignsRowsToDefaultProfile() throws {
        let directory = try makeTemporaryStoreDirectory()
        try seedLegacyStore(at: directory)

        let store = LocalStore(
            account: Account(userID: "legacy-account"),
            storeDirectoryURL: directory
        )
        let context = try XCTUnwrap(store.getMainContext())

        let profiles: [ProfileModel] = try context.fetch(FetchDescriptor<ProfileModel>())
        XCTAssertEqual(profiles.map { $0.profileId }, ["Default"])

        let tabs: [TabDataModel] = try context.fetch(FetchDescriptor<TabDataModel>())
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.profile?.profileId, "Default")
        XCTAssertEqual(tabs.first?.pinLineageId, "legacy-guid")
        XCTAssertEqual(store.pinnedTabScope(), .profile)
    }

    func testGetAllPinnedTabsFiltersByProfileId() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultPinned = makeTab(guid: "default-pinned", title: "Default", url: "https://default.example")
        defaultPinned.dataType = TabDataType.pinnedTab
        context.insert(defaultPinned)
        defaultPinned.profile = defaultProfile

        let workPinned = makeTab(guid: "work-pinned", title: "Work", url: "https://work.example")
        workPinned.dataType = TabDataType.pinnedTab
        context.insert(workPinned)
        workPinned.profile = workProfile

        try context.save()

        XCTAssertEqual(store.getAllPinnedTabs(for: "Default").map { $0.guid }, ["default-pinned"])
        XCTAssertEqual(store.getAllPinnedTabs(for: "Work").map { $0.guid }, ["work-pinned"])
    }

    func testUpsertProfileDisplayNamesCreatesAndUpdatesProfileRows() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default", displayName: "Old Default")
        context.insert(defaultProfile)
        try context.save()

        store.upsertProfileDisplayNames([
            "Default": "Personal",
            "Profile 1": " Work "
        ])

        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        XCTAssertEqual(profiles.first(where: { $0.profileId == "Default" })?.displayName, "Personal")
        XCTAssertEqual(profiles.first(where: { $0.profileId == "Profile 1" })?.displayName, "Work")
    }

    func testFetchBookmarksAndDeleteProtectionRespectProfileRoot() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultRoot = makeFolder(guid: "root-default", title: "Bookmarks")
        context.insert(defaultRoot)
        defaultProfile.bookmarkRoot = defaultRoot
        defaultRoot.profile = defaultProfile

        let workRoot = makeFolder(guid: "root-work", title: "Bookmarks")
        context.insert(workRoot)
        workProfile.bookmarkRoot = workRoot
        workRoot.profile = workProfile

        let defaultBookmark = makeTab(guid: "bookmark-default", title: "Default Bookmark", url: "https://default.example")
        defaultBookmark.dataType = TabDataType.bookmark
        context.insert(defaultBookmark)
        defaultBookmark.profile = defaultProfile
        defaultBookmark.parent = defaultRoot

        let workBookmark = makeTab(guid: "bookmark-work", title: "Work Bookmark", url: "https://work.example")
        workBookmark.dataType = TabDataType.bookmark
        context.insert(workBookmark)
        workBookmark.profile = workProfile
        workBookmark.parent = workRoot

        try context.save()

        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Default").map { $0.guid }, ["bookmark-default"])
        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Work").map { $0.guid }, ["bookmark-work"])

        store.deleteBookmark("root-default", profileId: "Default")
        try waitForBackgroundWrite()

        let refreshedDefaultRoot: [TabDataModel] = try context.fetch(
            FetchDescriptor<TabDataModel>(predicate: #Predicate<TabDataModel> { $0.guid == "root-default" })
        )
        XCTAssertEqual(refreshedDefaultRoot.count, 1)
    }

    func testFetchBookmarkTabsReturnsFlatSpaceScopedRowsOrderedByLastSeen() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let selectedSpace = SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "Selected",
            colorHex: "#112233",
            iconName: "rectangle.stack",
            sortOrder: 0
        )
        let otherSpace = SpaceModel(
            spaceId: "space-b",
            profileId: "Work",
            name: "Other",
            colorHex: "#445566",
            iconName: "rectangle.stack",
            sortOrder: 1
        )
        context.insert(selectedSpace)
        context.insert(otherSpace)

        let folder = makeFolder(guid: "folder", title: "Folder")
        folder.profile = defaultProfile
        folder.profileId = defaultProfile.profileId
        folder.spaceId = selectedSpace.spaceId
        folder.lastSeen = Date(timeIntervalSince1970: 400)
        context.insert(folder)

        let recent = makeTab(guid: "recent", title: "Recent", url: "https://recent.example")
        recent.dataType = .bookmark
        recent.profile = defaultProfile
        recent.profileId = defaultProfile.profileId
        recent.spaceId = selectedSpace.spaceId
        recent.parent = folder
        recent.lastSeen = Date(timeIntervalSince1970: 300)
        context.insert(recent)

        let older = makeTab(guid: "older", title: "Older", url: "https://older.example")
        older.dataType = .bookmark
        older.profile = defaultProfile
        older.profileId = defaultProfile.profileId
        older.spaceId = selectedSpace.spaceId
        older.lastSeen = Date(timeIntervalSince1970: 100)
        context.insert(older)

        let neverOpened = makeTab(guid: "never", title: "Never", url: "https://never.example")
        neverOpened.dataType = .bookmark
        neverOpened.profile = defaultProfile
        neverOpened.profileId = defaultProfile.profileId
        neverOpened.spaceId = selectedSpace.spaceId
        context.insert(neverOpened)

        let otherSpaceBookmark = makeTab(
            guid: "other-space",
            title: "Other Space",
            url: "https://other.example"
        )
        otherSpaceBookmark.dataType = .bookmark
        otherSpaceBookmark.profile = workProfile
        otherSpaceBookmark.profileId = workProfile.profileId
        otherSpaceBookmark.spaceId = otherSpace.spaceId
        otherSpaceBookmark.lastSeen = Date(timeIntervalSince1970: 500)
        context.insert(otherSpaceBookmark)

        let normalTab = makeTab(guid: "normal", title: "Normal", url: "https://normal.example")
        normalTab.dataType = .tab
        normalTab.profile = defaultProfile
        normalTab.profileId = defaultProfile.profileId
        normalTab.spaceId = selectedSpace.spaceId
        normalTab.lastSeen = Date(timeIntervalSince1970: 600)
        context.insert(normalTab)

        try context.save()

        XCTAssertEqual(
            store.fetchBookmarkTabs(in: store.getAllSpaces().filter { $0.spaceId == selectedSpace.spaceId }).map(\.guid),
            ["recent", "older", "never"]
        )
    }

    func testBrowserStateStoresProfileId() throws {
        let store = try makeStore()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Work")

        XCTAssertEqual(state.profileId, "Work")
    }

    func testBrowserStateRefreshesPersistedPinnedTabURLWhenLocalStoreChanges() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)

        let pinnedModel = makeTab(guid: "pinned-guid", title: "Pinned", url: "https://163.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        context.insert(pinnedModel)
        pinnedModel.profile = profile
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        pinnedTab.isOpenned = true
        pinnedTab.url = "https://github.com/features/copilot"

        store.updateTabURL("pinned-guid", url: try XCTUnwrap(URL(string: "https://qq.com")))
        try waitUntil {
            pinnedTab.pinnedUrl == "https://qq.com"
        }

        XCTAssertTrue(
            state.pinnedTabs.first === pinnedTab,
            "BrowserState should keep the existing pinned tab runtime object so open state and wrapper bindings are preserved."
        )
        XCTAssertEqual(
            pinnedTab.pinnedUrl,
            "https://qq.com",
            "Persisted pinned-tab URL changes should refresh the in-memory pinnedUrl used when the tab is closed and reopened."
        )
        XCTAssertEqual(
            pinnedTab.url,
            "https://github.com/features/copilot",
            "Refreshing persisted pinned-tab metadata must not overwrite the currently opened page URL."
        )
    }

    func testBrowserStatePinnedTabEditingURLPrefersPersistedURLOverRuntimeNavigationURL() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)
        let pinnedModel = makeTab(guid: "github-pinned", title: "GitHub", url: "https://github.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        context.insert(pinnedModel)
        pinnedModel.profile = profile
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = Tab(
            guid: 42,
            url: "https://github.com/features/copilot",
            isActive: true,
            index: 0,
            title: "GitHub Copilot",
            customGuid: "github-pinned"
        )
        pinnedTab.isPinned = true
        pinnedTab.pinnedUrl = "https://stale.example"
        state.pinnedTabs = [pinnedTab]

        let editingURL = state.pinnedTabEditingURL(
            for: "github-pinned",
            fallbackURL: "https://github.com/features/copilot"
        )

        XCTAssertEqual(
            editingURL,
            "https://github.com",
            "Editing a pinned tab should show the persisted URL instead of the currently navigated page URL."
        )
    }

    func testUpdateLastSeenOnlyPersistsForPinnedTabsAndBookmarks() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)

        let root = makeFolder(guid: "root", title: "Bookmarks")
        root.profileId = "Default"
        context.insert(root)
        profile.bookmarkRoot = root
        root.profile = profile

        let pinned = makeTab(guid: "pinned", title: "Pinned", url: "https://pinned.example")
        pinned.dataType = TabDataType.pinnedTab
        pinned.profileId = "Default"
        context.insert(pinned)
        pinned.profile = profile

        let bookmark = makeTab(guid: "bookmark", title: "Bookmark", url: "https://bookmark.example")
        bookmark.dataType = TabDataType.bookmark
        bookmark.profileId = "Default"
        context.insert(bookmark)
        bookmark.parent = root
        bookmark.profile = profile

        let folder = makeFolder(guid: "folder", title: "Folder")
        folder.profileId = "Default"
        context.insert(folder)
        folder.parent = root
        folder.profile = profile

        let normal = makeTab(guid: "normal", title: "Normal", url: "https://normal.example")
        normal.dataType = TabDataType.tab
        normal.profileId = "Default"
        context.insert(normal)
        normal.profile = profile
        try context.save()

        let seenAt = Date(timeIntervalSince1970: 1_800_123_456)
        store.updateLastSeen("pinned", seenAt: seenAt)
        store.updateLastSeen("bookmark", seenAt: seenAt)
        store.updateLastSeen("folder", seenAt: seenAt)
        store.updateLastSeen("normal", seenAt: seenAt)

        try waitUntil {
            store.getTab(by: "pinned")?.lastSeen != nil &&
            store.getTab(by: "bookmark")?.lastSeen != nil
        }

        XCTAssertEqual(try XCTUnwrap(store.getTab(by: "pinned")?.lastSeen).timeIntervalSince1970,
                       seenAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.getTab(by: "bookmark")?.lastSeen).timeIntervalSince1970,
                       seenAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(store.getTab(by: "folder")?.lastSeen)
        XCTAssertNil(store.getTab(by: "normal")?.lastSeen)
    }

    func testBrowserDataImporterStoresTargetContext() {
        let importer = BrowserDataImporter(
            targetProfileId: "Work",
            targetSpaceId: "space-work",
            targetWindowId: 42
        )

        XCTAssertEqual(importer.targetProfileId, "Work")
        XCTAssertEqual(importer.targetSpaceId, "space-work")
        XCTAssertEqual(importer.targetWindowId, 42)

        // Omitting targetSpaceId must default to the default Space so existing
        // call sites (e.g. onboarding) keep their pre-Spaces behavior.
        let defaultImporter = BrowserDataImporter(targetProfileId: "Work")
        XCTAssertEqual(defaultImporter.targetSpaceId, LocalStore.defaultSpaceId)
    }

    func testSaveChromiumBookmarksAcceptsLocalizedBookmarkBarTitle() async throws {
        let store = try makeStore()
        let leaf = StubBookmarkWrapper(title: "Example", urlString: "https://example.com")
        let importFolder = StubBookmarkWrapper(
            title: "Aus Chrome importiert", isFolder: true, children: [leaf])
        let bookmarksBar = StubBookmarkWrapper(
            title: "Lesezeichenleiste", isFolder: true, children: [importFolder])
        let otherBookmarks = StubBookmarkWrapper(
            title: "Weitere Lesezeichen", isFolder: true, indexInParent: 1)

        await store.saveChromiumBookmarksToLocalStore(
            [bookmarksBar, otherBookmarks],
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )

        let top = store.fetchBookmarks(
            parentId: nil,
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )
        let folder = try XCTUnwrap(
            top.first { $0.title == "Aus Chrome importiert" },
            "The bookmark bar's children must land under the Space's root."
        )
        let children = store.fetchBookmarks(
            parentId: folder.guid,
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )
        XCTAssertEqual(children.map { $0.title }, ["Example"])
    }

    /// The bridge drops permanent nodes that are hidden while empty, so its
    /// payload is a filtered view of the model root. When the bookmark bar is
    /// not in it, the import must abort rather than treat the next permanent
    /// node — "Other Bookmarks" — as the bar and import its children.
    func testSaveChromiumBookmarksAbortsWhenBookmarkBarIsMissing() async throws {
        let store = try makeStore()
        let leaf = StubBookmarkWrapper(title: "Stray", urlString: "https://example.com")
        let otherBookmarks = StubBookmarkWrapper(
            title: "Weitere Lesezeichen", isFolder: true, indexInParent: 1, children: [leaf])

        await store.saveChromiumBookmarksToLocalStore(
            [otherBookmarks],
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )

        XCTAssertTrue(
            store.fetchBookmarks(
                parentId: nil,
                profileId: LocalStore.defaultProfileId,
                spaceId: LocalStore.defaultSpaceId
            ).isEmpty,
            "Without the bookmark bar node nothing may be imported."
        )
    }

    func testSaveChromiumBookmarksSkipsEmptyPayload() async throws {
        let store = try makeStore()

        await store.saveChromiumBookmarksToLocalStore(
            [],
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )

        XCTAssertTrue(
            store.fetchBookmarks(
                parentId: nil,
                profileId: LocalStore.defaultProfileId,
                spaceId: LocalStore.defaultSpaceId
            ).isEmpty,
            "An empty bridge payload must not create any bookmarks."
        )
    }

    /// The importer must resolve its store through the browser's local-data
    /// accessor rather than through the signed-in account: imports performed
    /// before sign-in (Guest Mode) used to resolve to nil, and every bookmark
    /// was dropped without a trace while the UI reported success.
    func testPersistImportedBookmarksWritesIntoTheResolvedStore() async throws {
        let store = try makeStore()
        let importer = BrowserDataImporter(
            targetProfileId: LocalStore.defaultProfileId,
            targetSpaceId: LocalStore.defaultSpaceId,
            localDataStoreProvider: { store }
        )
        let leaf = StubBookmarkWrapper(title: "Example", urlString: "https://example.com")
        let importFolder = StubBookmarkWrapper(
            title: "Aus Chrome importiert", isFolder: true, children: [leaf])
        let bookmarksBar = StubBookmarkWrapper(
            title: "Lesezeichenleiste", isFolder: true, children: [importFolder])

        let persisted = await importer.persistImportedBookmarks(
            [bookmarksBar]
        )

        XCTAssertTrue(persisted)
        let top = store.fetchBookmarks(
            parentId: nil,
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )
        XCTAssertEqual(top.map { $0.title }, ["Aus Chrome importiert"])
    }

    /// With no store to resolve, persistence has to return quietly. There is no
    /// observable state to assert on — the test guards against the path crashing
    /// or force-unwrapping its way to a store.
    func testPersistImportedBookmarksWithoutAStoreReturnsQuietly() async {
        let importer = BrowserDataImporter(
            targetProfileId: LocalStore.defaultProfileId,
            targetSpaceId: LocalStore.defaultSpaceId,
            localDataStoreProvider: { nil }
        )
        let bookmarksBar = StubBookmarkWrapper(
            title: "Lesezeichenleiste",
            isFolder: true,
            children: [StubBookmarkWrapper(title: "Example", urlString: "https://example.com")]
        )

        let persisted = await importer.persistImportedBookmarks(
            [bookmarksBar]
        )

        XCTAssertFalse(persisted)
    }

    func testImportTargetLockTracksImportingSpaces() {
        let lock = ImportTargetLock.shared
        let spaceId = "space-lock-\(UUID().uuidString)"

        XCTAssertFalse(lock.isImporting(into: spaceId))
        lock.begin(into: spaceId)
        XCTAssertTrue(lock.isImporting(into: spaceId))
        lock.end(into: spaceId)
        XCTAssertFalse(lock.isImporting(into: spaceId))
    }

    func testFormatImportTargetLabel() {
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: "Personal"),
            "Work (Personal)"
        )
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: nil),
            "Work"
        )
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: ""),
            "Work"
        )
    }

    /// The single import window is retargeted (not duplicated) when re-invoked
    /// from another Space. `updateTarget` is the seam that swaps the destination
    /// window/profile/Space — including across profiles — that `rebindTarget`
    /// drives once an import is no longer in flight.
    func testBrowserDataImporterUpdateTargetRetargetsDestination() {
        let importer = BrowserDataImporter(
            targetProfileId: "Default",
            targetSpaceId: "space-A",
            targetWindowId: 1
        )
        XCTAssertFalse(importer.isImporting)

        importer.updateTarget(profileId: "Work", spaceId: "space-B", windowId: 2)

        XCTAssertEqual(importer.targetProfileId, "Work")
        XCTAssertEqual(importer.targetSpaceId, "space-B")
        XCTAssertEqual(importer.targetWindowId, 2)
    }

    /// Each top-level imported-browser folder is tagged with where it came from
    /// (1 Chromium, 2 Safari). The tag is keyed off the folder's rank, so re-ranking the
    /// folders must not move Safari's tag.
    func testSaveChromiumBookmarksTagsImportedBrowserFoldersBySource() async throws {
        let store = try makeStore()
        let leaf = { StubBookmarkWrapper(title: "Example", urlString: "https://example.com") }
        let bookmarksBar = StubBookmarkWrapper(
            title: "Bookmarks Bar", isFolder: true,
            children: [
                StubBookmarkWrapper(title: "Imported From Chrome", isFolder: true, indexInParent: 0, children: [leaf()]),
                StubBookmarkWrapper(title: "Imported From Safari", isFolder: true, indexInParent: 2, children: [leaf()]),
            ])

        await store.saveChromiumBookmarksToLocalStore(
            [bookmarksBar],
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )

        let sourceByTitle = Dictionary(
            uniqueKeysWithValues: store.fetchBookmarks(
                parentId: nil,
                profileId: LocalStore.defaultProfileId,
                spaceId: LocalStore.defaultSpaceId
            ).map { ($0.title, $0.source) })
        XCTAssertEqual(
            sourceByTitle, ["Imported From Chrome": 1, "Imported From Safari": 2])
    }

    func testProjectDataTypesDropsEmptyBrowsersAndNilsWhenAllEmpty() {
        // Nothing selected anywhere → nil.
        XCTAssertNil(ImportFromOtherBrowserViewController.projectDataTypes([:]))
        XCTAssertNil(ImportFromOtherBrowserViewController.projectDataTypes([.chrome: [], .safari: []]))

        // Non-empty browsers project to sorted rawValue arrays; empty ones dropped.
        let result = ImportFromOtherBrowserViewController.projectDataTypes([
            .chrome: [.bookmarks, .history],
            .safari: [],
        ])
        XCTAssertEqual(result?[.chrome], ["favorites", "history"])  // bookmarks rawValue is "favorites", sorted
        XCTAssertNil(result?[.safari])  // empty set omitted
    }

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryStoreDirectory()
        return LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func seedLegacyStore(at directory: URL) throws {
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("LocalStore.sqlite"))
        let container = try ModelContainer(for: TabDataModelSchemaV2.TabDataModel.self, configurations: configuration)
        let context = container.mainContext

        let row = TabDataModelSchemaV2.TabDataModel(
            title: "Legacy Pinned",
            guid: "legacy-guid",
            index: 0,
            url: URL(string: "https://legacy.example")!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        row.type = TabDataType.pinnedTab.rawValue
        row.profileId = "legacy-account"
        context.insert(row)
        try context.save()
    }

    private func makeFolder(guid: String, title: String) -> TabDataModel {
        let folder = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: "https://bookmark.phi/folder")!,
            favicon: nil as Data?,
            createdDate: Date(),
            updatedDate: Date()
        )
        folder.dataType = TabDataType.bookmarkFolder
        return folder
    }

    private func makeTab(guid: String, title: String, url: String) -> TabDataModel {
        TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
    }

    private func waitForBackgroundWrite() throws {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
    }

    private func writeLocalState(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Local State")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testLoadChromiumProfilesFromInjectedLocalState() throws {
        let url = try writeLocalState("""
        {"profile":{"profiles_order":["Default","Profile 1"],
          "info_cache":{"Default":{"name":"Your Chrome","user_name":""},
                        "Profile 1":{"name":"aa","user_name":""}}}}
        """)

        let importer = BrowserDataImporter()
        let profiles = importer.loadChromiumProfiles(localStateURL: url)
        XCTAssertEqual(profiles.map { $0.directory }, ["Default", "Profile 1"])
        XCTAssertEqual(profiles.map { $0.name }, ["Your Chrome", "aa"])
    }

    func testLoadChromiumProfilesFallsBackToDirectoryWhenNameIsEmpty() throws {
        let url = try writeLocalState("""
        {"profile":{"profiles_order":["Profile 1"],
          "info_cache":{"Profile 1":{"name":"","user_name":""}}}}
        """)

        let profiles = BrowserDataImporter().loadChromiumProfiles(localStateURL: url)
        XCTAssertEqual(profiles.map { $0.name }, ["Profile 1"])
    }



}

/// Stand-in for the Chromium bridge's bookmark payload. The concrete
/// `BookmarkWrapper` class ships in the framework, but conforming to the
/// protocol is enough to drive the persist path from a unit test.
private final class StubBookmarkWrapper: NSObject, BookmarkWrapper {
    let title: String?
    let urlString: String?
    let favIconURL: String? = nil
    let guid = 0
    let isFolder: Bool
    let indexInParent: Int
    let children: [BookmarkWrapper]

    init(
        title: String?,
        urlString: String? = nil,
        isFolder: Bool = false,
        indexInParent: Int = 0,
        children: [BookmarkWrapper] = []
    ) {
        self.title = title
        self.urlString = urlString
        self.isFolder = isFolder
        self.indexInParent = indexInParent
        self.children = children
        super.init()
    }
}
