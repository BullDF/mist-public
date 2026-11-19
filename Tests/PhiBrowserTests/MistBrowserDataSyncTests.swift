import Combine
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class MistBrowserDataSyncTests: XCTestCase {
    func testApplyCreateMoveReorderDeleteAndReadSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mist-browser-data-\(UUID())")
        let account = Account(userID: "mist-browser-data-test-\(UUID())")
        let previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
        let store = LocalStore(account: account, storeDirectoryURL: directory.appendingPathComponent("store"),
                               presentsCompatibilityAlerts: false)
        account.localStorage = store
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: account.userDataStorage)
            UserDefaults.standard.set(previousBoundAccount, forKey: SpaceManager.lastBoundAccountUserIDKey)
        }
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: "Default", displayName: "Default"))
        context.insert(SpaceModel(spaceId: "default-space", profileId: "Default", name: "Default",
            colorHex: "#123456", iconName: "star", sortOrder: 0))
        try context.save()
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: account)
        defer { manager.discardSpacePrewarm() }
        let storage = MistLocalBrowserDataSyncStorage(store: { store }, spaces: manager, profileList: {
            [PhiBrowserProfile(profileId: "Default", displayName: "Default", isLoaded: true, isInUse: true)]
        })
        let source = MistBrowserDataSyncSource(store: storage, directory: directory.appendingPathComponent("sync"))
        var changes: [MistSyncRecord] = []
        source.onChange = { changes += $0 }
        _ = try source.snapshot()
        try await source.apply(MistSyncRecord(kind: "profile", id: "default", payload: ["name": .string("Default")]))
        try await source.apply(space("one", order: 1))
        try await source.apply(space("two", order: 2))
        try await source.apply(bookmark("folder", folder: true))
        try await source.apply(bookmark("first", parent: "folder", index: 0))
        var second = bookmark("second", parent: "folder", index: 1)
        second.payload["secondaryUrl"] = .string("https://secondary.example/")
        second.payload["secondaryTitle"] = .string("Secondary")
        second.payload["layout"] = .string("horizontal")
        try await source.apply(second)
        var data = try storage.read().eligible
        XCTAssertEqual(data.bookmarks.count, 3)
        let first = try XCTUnwrap(data.bookmarks.first { $0.syncID == "first" })
        XCTAssertNotEqual(first.localID, "first", "Remote rows get fresh physical GUIDs")
        XCTAssertTrue(try XCTUnwrap(store.fetchBookmark(with: first.localID)).needUpdateMetaData)
        XCTAssertEqual(data.bookmarks.first { $0.syncID == "second" }?.secondaryURL, "https://secondary.example/")
        XCTAssertEqual(data.bookmarks.first { $0.syncID == "second" }?.layout, "horizontal")

        // Deliver a reorder as two independent LWW records.
        second.payload["index"] = .number(0)
        try await source.apply(second)
        try await source.apply(bookmark("first", parent: "folder", index: 1))
        data = try storage.read().eligible
        XCTAssertEqual(data.bookmarks.filter { !$0.folder }.sorted { $0.index < $1.index }.compactMap(\.syncID), ["second", "first"])
        try await source.apply(bookmark("first", space: "two"))
        data = try storage.read().eligible
        XCTAssertEqual(data.bookmarks.first { $0.syncID == "first" }?.space, "two")
        XCTAssertNil(data.bookmarks.first { $0.syncID == "first" }?.parent)
        try await source.apply(space("two", order: 0))
        try await source.apply(space("default-space", order: 1))
        try await source.apply(space("one", order: 2))
        XCTAssertEqual(try storage.read().spaces.sorted { $0.order < $1.order }.map(\.localID), ["two", "default-space", "one"])

        try await source.apply(MistSyncRecord(kind: "bookmark", id: "folder", deleted: true))
        let snapshot = try source.snapshot()
        XCTAssertEqual(snapshot.filter { $0.kind == "bookmark" }.map(\.id), ["first"])
        try await source.apply(MistSyncRecord(kind: "bookmark", id: "second", deleted: true))
        try source.flushLocalChanges()
        XCTAssertTrue(changes.isEmpty, "Remote writes and normalization never echo")

        // The save observer must report local changes while ignoring metadata.
        let node = try XCTUnwrap(store.fetchBookmark(with: first.localID))
        node.favicon = Data([1, 2, 3])
        try context.save()
        try source.flushLocalChanges()
        XCTAssertTrue(changes.isEmpty)
        node.title = "Locally renamed"
        let reported = expectation(description: "the save observer reports the rename")
        source.onChange = { changes += $0; reported.fulfill() }
        try context.save()
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(changes.map(\.id), ["first"])
        XCTAssertEqual(changes.first?.payload["title"], .string("Locally renamed"))
        try await store.closeForAccountDirectoryRemoval()
    }

    private func space(_ id: String, order: Int) -> MistSyncRecord {
        MistSyncRecord(kind: "space", id: id, payload: ["name": .string(id), "profile": .string("default"),
            "color": .string("#123456"), "icon": .string("star"), "order": .number(Double(order))])
    }

    private func bookmark(_ id: String, space: String = "one", parent: String? = nil,
                          index: Int = 0, folder: Bool = false) -> MistSyncRecord {
        MistSyncRecord(kind: "bookmark", id: id, payload: ["space": .string(space), "parent": parent.map(MistSyncValue.string) ?? .null,
            "index": .number(Double(index)), "folder": .bool(folder), "title": .string(id),
            "url": .string(folder ? "https://bookmark.phi/folder" : "https://\(id).example/"),
            "secondaryUrl": .null, "secondaryTitle": .null, "layout": .null])
    }
}
