import Combine
import SwiftData
import XCTest
@testable import Phi

final class MistChromiumBookmarkMirrorTests: XCTestCase {
    private typealias Mirror = MistChromiumBookmarkMirror
    private typealias Entry = Mirror.Entry

    func testDesiredEntriesSkipsEmptyURLsAndPreservesOrder() {
        let entries = Mirror.desiredEntries(from: [
            .init(url: nil, title: "Missing", secondaryUrl: nil, secondaryTitle: nil),
            .init(url: "", title: "Empty", secondaryUrl: "", secondaryTitle: nil),
            .init(url: "https://first.example", title: "First", secondaryUrl: "https://second.example", secondaryTitle: "Second"),
            .init(url: "https://third.example", title: "Third", secondaryUrl: nil, secondaryTitle: nil)
        ])
        XCTAssertEqual(entries, [entry("first", "First"), entry("second", "Second"), entry("third", "Third")])
    }

    func testSecondaryTitleFallsBackToPrimaryTitle() {
        XCTAssertEqual(Mirror.desiredEntries(from: [
            .init(url: "https://first.example", title: "Shared", secondaryUrl: "https://second.example", secondaryTitle: nil)
        ]), [entry("first", "Shared"), entry("second", "Shared")])
    }

    func testSecondaryURLSurvivesMissingPrimaryAndNilTitlesBecomeEmpty() {
        XCTAssertEqual(Mirror.desiredEntries(from: [
            .init(url: nil, title: nil, secondaryUrl: "https://second.example", secondaryTitle: nil)
        ]), [entry("second", "")])
    }

    func testCurrentNodesFlattensAllRootsAndExcludesRootFolderIDs() {
        let first = FakeBookmark(id: 10, title: "First", url: "https://first.example")
        let second = FakeBookmark(id: 11, title: "Second", url: "https://second.example")
        let missingFields = FakeBookmark(id: 12)
        let nested = FakeBookmark(id: 4, folder: true, children: [second])
        let folder = FakeBookmark(id: 3, folder: true, children: [first, nested])
        let roots: [BookmarkWrapper] = [
            FakeBookmark(id: 1, folder: true, children: [folder]),
            FakeBookmark(id: 2, folder: true, index: 1, children: [missingFields])
        ]

        let current = Mirror.currentNodes(from: roots)
        XCTAssertEqual(current.pages.map(\.id), [10, 11, 12])
        XCTAssertEqual(current.pages.map(\.entry), [entry("first", "First"), entry("second", "Second"), Entry(url: "", title: "")])
        XCTAssertEqual(current.folders, [4, 3])
    }

    func testPlanIgnoresOrdering() {
        let first = entry("first", "First")
        let second = entry("second", "Second")
        let plan = Mirror.plan(desired: [second, first], current: [.init(id: 1, entry: first), .init(id: 2, entry: second)])
        XCTAssertTrue(plan.remove.isEmpty)
        XCTAssertTrue(plan.add.isEmpty)
    }

    func testPlanAddsMissingEntriesInDesiredOrder() {
        let first = entry("first", "First")
        let second = entry("second", "Second")
        let third = entry("third", "Third")
        let plan = Mirror.plan(desired: [third, first, second], current: [.init(id: 1, entry: first)])
        XCTAssertTrue(plan.remove.isEmpty)
        XCTAssertEqual(plan.add, [third, second])
    }

    func testPlanRemovesExtraNodeByID() {
        let first = entry("first", "First")
        let plan = Mirror.plan(desired: [first], current: [.init(id: 1, entry: first), .init(id: 42, entry: entry("extra", "Extra"))])
        XCTAssertEqual(plan.remove, [42])
        XCTAssertTrue(plan.add.isEmpty)
    }

    func testRetitleRemovesAndAddsEntry() {
        let updated = entry("first", "New")
        let plan = Mirror.plan(desired: [updated], current: [.init(id: 7, entry: entry("first", "Old"))])
        XCTAssertEqual(plan.remove, [7])
        XCTAssertEqual(plan.add, [updated])
    }

    func testPlanRemovesOnlyExtraDuplicate() {
        let first = entry("first", "First")
        let plan = Mirror.plan(desired: [first], current: [.init(id: 1, entry: first), .init(id: 2, entry: first)])
        XCTAssertEqual(plan.remove, [2])
        XCTAssertTrue(plan.add.isEmpty)
    }

    func testPlanAddsMissingDuplicate() {
        let first = entry("first", "First")
        let plan = Mirror.plan(desired: [first, first], current: [.init(id: 1, entry: first)])
        XCTAssertTrue(plan.remove.isEmpty)
        XCTAssertEqual(plan.add, [first])
    }

    func testBookmarkBarRootUsesIndexInsteadOfArrayOrder() {
        let other = FakeBookmark(id: 2, folder: true, index: 1)
        let bar = FakeBookmark(id: 1, folder: true)
        XCTAssertEqual(Mirror.bookmarkBarRoot(in: [other, bar])?.guid, 1)
    }

    func testBookmarkBarRootRequiresFolder() {
        XCTAssertNil(Mirror.bookmarkBarRoot(in: [FakeBookmark(id: 1), FakeBookmark(id: 2, folder: true, index: 1)]))
        XCTAssertNil(Mirror.bookmarkBarRoot(in: []))
    }

    @MainActor
    func testProfilePublisherIncludesAllSpacesAndOnlyActiveOwnedPins() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        let work = ProfileModel(profileId: "Work")
        let settings = BrowserDataSettingsModel()
        context.insert(profile)
        context.insert(work)
        context.insert(settings)

        @discardableResult
        func insert(_ id: String, type: TabDataType, owner: ProfileModel? = nil,
                    profileId: String? = nil, space: String? = nil, dormant: Bool = false) -> TabDataModel {
            let row = TabDataModel(title: id, guid: id, index: 0,
                                   url: URL(string: "https://\(id).example")!, favicon: nil,
                                   createdDate: Date(), updatedDate: Date())
            row.dataType = type
            row.profileId = profileId
            row.spaceId = space
            row.isPinnedTabDormant = dormant
            context.insert(row)
            row.profile = owner
            return row
        }
        insert("bookmark-a", type: .bookmark, owner: profile, space: "a")
        insert("bookmark-b", type: .bookmark, owner: profile, space: "b")
        insert("work-bookmark", type: .bookmark, owner: work, space: "c")
        insert("folder", type: .bookmarkFolder, owner: profile)
        insert("tab", type: .tab, owner: profile)
        insert("pin-field", type: .pinnedTab, profileId: "Default")
        insert("pin-relationship", type: .pinnedTab, owner: profile)
        insert("pin-work", type: .pinnedTab, owner: work, profileId: "Work")
        insert("pin-space-a", type: .pinnedTab, profileId: "Default", space: "a")
        insert("pin-space-b", type: .pinnedTab, owner: profile, space: "b")
        insert("pin-dormant", type: .pinnedTab, profileId: "Default", dormant: true)
        insert("pin-app", type: .pinnedTab)
        try context.save()

        for (scope, pins) in [(PinnedTabScope.profile, ["pin-field", "pin-relationship"]),
                              (.space, ["pin-space-a", "pin-space-b"]),
                              // Like pinnedTabs(...), app scope uses the scalar
                              // owner fields even on legacy relationship-only rows.
                              (.app, ["pin-app", "pin-relationship"])] {
            settings.pinnedTabScopeRawValue = scope.rawValue
            try context.save()
            var received: [String]?
            let subscription = store.mistSuggestionSourcesPublisher(profileId: "Default")
                .sink { received = $0.map(\.guid) }
            XCTAssertEqual(Set(try XCTUnwrap(received)), Set(["bookmark-a", "bookmark-b"] + pins), "\(scope)")
            subscription.cancel()
        }
    }

    private func entry(_ host: String, _ title: String) -> Entry {
        Entry(url: "https://\(host).example", title: title)
    }
}

private final class FakeBookmark: NSObject, BookmarkWrapper {
    let guid: Int
    let title: String?
    let urlString: String?
    let favIconURL: String? = nil
    let isFolder: Bool
    let indexInParent: Int
    let children: [BookmarkWrapper]

    init(id: Int, title: String? = nil, url: String? = nil, folder: Bool = false,
         index: Int = 0, children: [BookmarkWrapper] = []) {
        guid = id
        self.title = title
        urlString = url
        isFolder = folder
        indexInParent = index
        self.children = children
        super.init()
    }
}
