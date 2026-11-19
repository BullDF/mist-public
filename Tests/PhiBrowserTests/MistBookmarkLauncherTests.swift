// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistBookmarkLauncherTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalLayoutRawValue: String?
    private let verticalLayouts: [LayoutMode] = [.balanced, .performance]

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLayoutRawValue = UserDefaults.standard.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(originalLayoutRawValue, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testOpeningSingleBookmarkAlwaysCreatesNewUnboundTab() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state)
            let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: bookmark.url)
            let stale = Tab(guid: 101, url: bookmark.url, isActive: false, index: 0,
                            webContentView: wrapper, customGuid: bookmark.guid)
            state.tabs = [stale]
            bookmark.isOpened = true
            bookmark.chromiumTabGuid = stale.guid
            bookmark.setWebContentWrapper(wrapper)

            state.openBookmark(bookmark)
            state.openBookmark(bookmark)

            XCTAssertEqual(state.createRequests.count, 2, "\(mode)")
            XCTAssertTrue(state.createRequests.allSatisfy { $0.customGuid == nil && $0.focus })
            XCTAssertEqual(state.createRequests.compactMap(\.url), [bookmark.url!, bookmark.url!])
            XCTAssertEqual(wrapper.activationCount, 0)
            XCTAssertNil(stale.guidInLocalDB)
            XCTAssertFalse(bookmark.isOpened)
        }
    }

    func testSplitSearchSecondaryActionCreatesUnboundSplitEveryTime() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state, secondaryURL: "https://secondary.example")
            let executor = SearchTabsActionExecutor(browserState: state)

            for _ in 0..<2 {
                XCTAssertTrue(executor.perform(.openBookmark(localGuid: bookmark.guid,
                                                             preferredPaneGuid: bookmark.guid)))
            }

            XCTAssertEqual(state.pendingPrimarySplitTargetByGuid.count, 2)
            XCTAssertTrue(state.pendingPrimarySplitTargetByGuid.values.allSatisfy {
                $0.boundBookmarkGuid == nil
            })
        }
    }

    func testArrivingBookmarkTabIsDetachedWithoutMovingOrUngrouping() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state)
            let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: bookmark.url)
            let tab = Tab(guid: 102, url: bookmark.url, isActive: false, index: 3,
                          webContentView: wrapper, customGuid: bookmark.guid)
            tab.groupToken = "group"
            state.tabs = [tab]

            XCTAssertNil(state.boundRecordURLString(for: tab))
            XCTAssertFalse(state.addressBarNavigationOpensNewTab(for: tab))
            state.handleBookmarkTabOpened(tab)
            state.updateNormalTabs()

            XCTAssertNil(tab.guidInLocalDB)
            XCTAssertEqual(wrapper.customValues.last, "")
            XCTAssertEqual(tab.groupToken, "group")
            XCTAssertEqual(tab.index, 3)
            XCTAssertEqual(state.normalTabs.map(\.guid), [102])
            XCTAssertFalse(bookmark.isOpened)
        }
    }

    func testStoreReconciliationDetachesStaleSplitAndPreservesPinnedTabs() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state, secondaryURL: "https://secondary.example")
            let primary = Tab(guid: 201, url: bookmark.url, isActive: false, index: 0)
            let secondary = Tab(guid: 202, url: bookmark.secondaryUrl, isActive: false, index: 1)
            let pinned = Tab(guid: 203, url: "https://pinned.example", isActive: false,
                             index: 2, customGuid: "pinned-guid")
            pinned.isPinned = true
            let split = SplitGroup(id: "restored-split", primaryTabId: 201, secondaryTabId: 202,
                                   layout: .vertical, ratio: 0.5)
            state.tabs = [primary, secondary, pinned]
            state.splits = [split]
            state.splitBookmarkBindings[bookmark.guid] = split.id

            state.syncAllBookmarksOpenedState()

            XCTAssertTrue(state.splitBookmarkBindings.isEmpty)
            XCTAssertEqual(state.splits, [split])
            XCTAssertEqual(state.normalTabs.map(\.guid), [201, 202])
            XCTAssertEqual(pinned.guidInLocalDB, "pinned-guid")
            XCTAssertTrue(pinned.isPinned)
            XCTAssertFalse(bookmark.isOpened)
        }
    }

    func testTabSwitchingSkipsVisibleBookmarks() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state)
            state.visibleBookmarkTabs = [bookmark]
            let firstWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://first.example")
            let secondWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://second.example")
            let first = Tab(guid: 301, url: firstWrapper.urlString, isActive: true, index: 0,
                            webContentView: firstWrapper)
            let second = Tab(guid: 302, url: secondWrapper.urlString, isActive: false, index: 1,
                             webContentView: secondWrapper)
            state.tabs = [first, second]
            state.updateNormalTabs()
            state.focuseTab(first)

            state.selectTabWithIndex(0)
            state.selectTabWithIndex(1)
            state.swicthTab(.back)
            state.swicthTab(.forward)
            state.swicthTab(.last)

            XCTAssertTrue(state.createRequests.isEmpty)
            XCTAssertEqual(firstWrapper.activationCount, 1)
            XCTAssertEqual(secondWrapper.activationCount, 4)
        }
    }

    func testDraggingGroupedTabIntoBookmarksLeavesTabInPlace() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://dragged.example")
            let tab = Tab(guid: 401, url: wrapper.urlString, isActive: false, index: 0,
                          webContentView: wrapper)
            state.tabs = [tab]
            state.handleTabGroupCreated(token: "group", title: "Group", color: .blue,
                                        isCollapsed: false, initialTabIds: [tab.guid])
            state.updateNormalTabs()

            XCTAssertTrue(state.moveNormalTab(tabId: tab.guid, toBookmark: nil, index: 0))
            XCTAssertTrue(waitUntil { state.bookmarkManager.getAllBookmarks().count == 1 })
            XCTAssertNil(tab.guidInLocalDB)
            XCTAssertEqual(tab.groupToken, "group")
            XCTAssertNotNil(state.groups["group"])
            XCTAssertEqual(state.normalTabs.map(\.guid), [401])
            XCTAssertTrue(wrapper.customValues.isEmpty)
        }
    }

    func testRestoreSnapshotAndReopenedTabClearBookmarkGuid() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let bookmark = try createBookmark(in: state)
            let restoredWrapper = BookmarkLayoutTestWebContentWrapper(urlString: bookmark.url)
            let restored = Tab(guid: 501, url: bookmark.url, isActive: false, index: 0,
                               webContentView: restoredWrapper, customGuid: bookmark.guid)
            let context = NativeTabCreationContext(isActiveAtCreation: false, creationKind: .restore)
            state.handleRestoredWindowSnapshot(.init(tabs: [(restored, context)],
                                                      activeTabId: restored.guid, splitActions: []))
            let reopenedWrapper = BookmarkLayoutTestWebContentWrapper(urlString: bookmark.url)
            let reopened = Tab(guid: 502, url: bookmark.url, isActive: false, index: 1,
                               webContentView: reopenedWrapper, customGuid: bookmark.guid)
            let reopenedContext = NativeTabCreationContext(isActiveAtCreation: false,
                                                            creationKind: .restore,
                                                            insertAfterTabId: restored.guid)
            state.handleNewTabFromChromium(reopened, context: reopenedContext)

            XCTAssertEqual(state.normalTabs.map(\.guid), [501, 502])
            XCTAssertTrue(state.tabs.allSatisfy { $0.guidInLocalDB == nil })
            XCTAssertEqual(restoredWrapper.customValues.last, "")
            XCTAssertEqual(reopenedWrapper.customValues.last, "")
            XCTAssertFalse(bookmark.isOpened)
        }
    }

    func testDraggingSplitIntoBookmarksLeavesUnboundSplitInPlace() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let primary = Tab(guid: 601, url: "https://primary.example", isActive: false, index: 0)
            let secondary = Tab(guid: 602, url: "https://secondary.example", isActive: false, index: 1)
            let split = SplitGroup(id: "saved-split", primaryTabId: 601, secondaryTabId: 602,
                                   layout: .horizontal, ratio: 0.5)
            state.tabs = [primary, secondary]
            state.splits = [split]
            state.updateNormalTabs()

            XCTAssertTrue(state.addSplitBookmarkFromTab(primary))
            XCTAssertTrue(waitUntil { state.bookmarkManager.getAllBookmarks().count == 1 })
            XCTAssertTrue(state.splitBookmarkBindings.isEmpty)
            XCTAssertEqual(state.splits, [split])
            XCTAssertEqual(state.normalTabs.map(\.guid), [601, 602])
        }
    }

    func testGroupConversionLeavesMembersInTheirOpenGroup() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            state.tabs = [Tab(guid: 701, url: "https://first.example", isActive: false, index: 0),
                          Tab(guid: 702, url: "https://second.example", isActive: false, index: 1)]
            state.handleTabGroupCreated(token: "group", title: "Group", color: .blue,
                                        isCollapsed: false, initialTabIds: [701, 702])
            state.updateNormalTabs()

            state.convertGroupToBookmarks(token: "group", parentFolder: nil, at: 0)

            XCTAssertTrue(waitUntil { state.bookmarkManager.getAllBookmarks().filter { !$0.isFolder }.count == 2 })
            XCTAssertEqual(state.normalTabs.map(\.guid), [701, 702])
            XCTAssertTrue(state.tabs.allSatisfy { $0.guidInLocalDB == nil && $0.groupToken == "group" })
            XCTAssertNotNil(state.groups["group"])
        }
    }

    func testPinnedTabsStillOpenWithTheirStoredGuid() throws {
        for mode in verticalLayouts {
            let state = try makeState(mode)
            let pinned = Tab(guid: -1, url: "https://pinned.example", isActive: false,
                             index: 0, customGuid: "pinned-guid")
            state.pinnedTabs = [pinned]

            state.openOrFocusPinnedTab(pinned)

            XCTAssertEqual(state.createRequests.count, 1)
            XCTAssertEqual(state.createRequests.first?.customGuid, "pinned-guid")
        }
    }

    private func makeState(_ mode: LayoutMode) throws -> MistBookmarkTestBrowserState {
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = MistBookmarkTestBrowserState(windowId: 7, localStore: store, profileId: "Default")
        state.layoutMode = mode
        return state
    }

    private func createBookmark(in state: BrowserState, secondaryURL: String? = nil) throws -> Bookmark {
        let guid = UUID().uuidString
        state.localStore.createBookmark(url: "https://bookmark.example", title: "Bookmark",
                                        profileId: state.profileId, parentId: nil, guid: guid,
                                        spaceId: state.spaceId, secondaryUrl: secondaryURL)
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid) != nil })
        return try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}

private final class MistBookmarkTestBrowserState: BrowserState {
    private(set) var createRequests: [(url: String?, customGuid: String?, focus: Bool)] = []

    override func createTab(_ url: String?, customGuid: String?, focusAfterCreate: Bool) {
        createRequests.append((url, customGuid, focusAfterCreate))
    }
}
