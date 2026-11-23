// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftData
import XCTest
@testable import Phi

/// `BrowserState.opensAutoPeek(forLinkFrom:urlString:)` answers Chromium's
/// question about a link's new tab before the tab exists: whether it opens in
/// the Peek panel on its own. It must give the answer the Peek pipeline gives
/// when the tab arrives.
@MainActor
final class BrowserStateAutoPeekLinkTests: XCTestCase {
    private let peekKey = PhiPreferences.GeneralSettings.peekViewEnabled.rawValue
    private let autoPeekKey = PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue
    private var originalPeek: Any?
    private var originalAutoPeek: Any?
    private var tempDirectories: [URL] = []
    private var stores: [LocalStore] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalPeek = UserDefaults.standard.object(forKey: peekKey)
        originalAutoPeek = UserDefaults.standard.object(forKey: autoPeekKey)
        UserDefaults.standard.set(true, forKey: peekKey)
        UserDefaults.standard.set(true, forKey: autoPeekKey)
    }

    override func tearDown() async throws {
        restore(originalPeek, forKey: peekKey)
        restore(originalAutoPeek, forKey: autoPeekKey)
        for store in stores {
            await store.performBackgroundWriteAndWait { _ in }
        }
        stores.removeAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testCrossSiteLinkOfAPinnedTabOpensAPeek() throws {
        let state = try makeStateWithPinnedTab()

        XCTAssertTrue(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                          urlString: "https://other.test/page"))
    }

    func testSameSiteLinkOfAPinnedTabDoesNot() throws {
        let state = try makeStateWithPinnedTab()

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://www.example.com/next"))
    }

    func testLinkToAPageThatIsNotOnTheWebDoesNot() throws {
        let state = try makeStateWithPinnedTab()

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "mailto:someone@other.test"))
    }

    /// Bookmarks are launchers in Mist, so a bookmark's tab never peeks.
    func testCrossSiteLinkOfABookmarkTabDoesNot() throws {
        let state = try makeState()
        let guid = "auto-peek-bookmark"
        state.localStore.createBookmark(url: "https://example.com/",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: guid,
                                        spaceId: state.spaceId,
                                        secondaryUrl: nil,
                                        layout: nil)
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid) != nil })
        state.tabs = [makeTab(customGuid: guid)]

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://other.test/page"))
    }

    func testLinkOfATabThatIsNotBoundDoesNot() throws {
        let state = try makeState()
        state.tabs = [makeTab(customGuid: nil)]

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://other.test/page"))
    }

    func testLinkOfATabThatIsGoneDoesNot() throws {
        let state = try makeStateWithPinnedTab()

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId + 1,
                                           urlString: "https://other.test/page"))
    }

    func testAutomaticPeekOffDoesNot() throws {
        let state = try makeStateWithPinnedTab()
        UserDefaults.standard.set(false, forKey: autoPeekKey)

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://other.test/page"))
    }

    func testPeekOffDoesNot() throws {
        let state = try makeStateWithPinnedTab()
        UserDefaults.standard.set(false, forKey: peekKey)

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://other.test/page"))
    }

    func testComfortableLayoutDoesNot() throws {
        let state = try makeStateWithPinnedTab()
        state.layoutMode = .comfortable

        XCTAssertFalse(state.opensAutoPeek(forLinkFrom: Self.openerId,
                                           urlString: "https://other.test/page"))
    }

    // MARK: - Helpers

    private static let openerId = 301
    private static let pinnedGuid = "auto-peek-pinned"

    private func makeState(seedingPinnedTab: Bool = false) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory,
                               presentsCompatibilityAlerts: false)
        stores.append(store)
        if seedingPinnedTab {
            try seedPinnedTab(in: store)
        }
        let state = BrowserState(windowId: 7, localStore: store,
                                 profileId: "Default", spaceId: "space-a")
        state.layoutMode = .balanced
        return state
    }

    /// A state whose tab `openerId` is the open tab of a pinned tab of
    /// https://example.com/.
    private func makeStateWithPinnedTab() throws -> BrowserState {
        let state = try makeState(seedingPinnedTab: true)
        XCTAssertEqual(state.pinnedTabs.first?.guidInLocalDB, Self.pinnedGuid)
        state.tabs = [makeTab(customGuid: Self.pinnedGuid)]
        return state
    }

    private func seedPinnedTab(in store: LocalStore) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)
        let pinnedModel = TabDataModel(
            title: "Pinned",
            guid: Self.pinnedGuid,
            index: 0,
            url: URL(string: "https://example.com/")!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        pinnedModel.dataType = TabDataType.pinnedTab
        context.insert(pinnedModel)
        pinnedModel.profile = profile
        try context.save()
    }

    private func makeTab(customGuid: String?) -> Tab {
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://example.com/")
        return Tab(guid: Self.openerId, url: wrapper.urlString, isActive: true, index: 0,
                   webContentView: wrapper, customGuid: customGuid)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}
