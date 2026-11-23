// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateHiddenOpenerInsertionTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalAutoPeek: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let key = PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue
        originalAutoPeek = UserDefaults.standard.object(forKey: key)
        // These cases test tab ordering, not automatic cross-site Peek diversion.
        UserDefaults.standard.set(false, forKey: key)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(originalAutoPeek,
                                  forKey: PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue)
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)

        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seedNormalTabs(_ state: BrowserState) {
        state.tabs = [
            Tab(guid: 1, url: "https://a.example", isActive: false, index: 0),
            Tab(guid: 2, url: "https://b.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://c.example", isActive: false, index: 2),
        ]
        state.updateNormalTabs()
    }

    func testNewTabsFromHiddenPinnedOpenerAppendToNormalTabs() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )
        state.handleNewTabFromChromium(
            Tab(guid: 11, url: "https://e.example", isActive: true, index: 5),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10, 11])
    }

    func testHiddenPinnedOpenerIgnoresInitialChromiumAdjacentOrderEcho() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        state.reorderTabs([
            9: 0,
            10: 1,
            1: 2,
            2: 3,
            3: 4,
        ])

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])
    }

    func testHiddenPinnedOpenerProtectionClearsAfterInitialEcho() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        state.reorderTabs([
            9: 0,
            10: 1,
            1: 2,
            2: 3,
            3: 4,
        ])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])

        state.reorderTabs([
            9: 0,
            10: 1,
            1: 2,
            2: 3,
            3: 4,
        ])

        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 1, 2, 3])
    }

    func testProtectedHiddenOpenerStillAcceptsOtherChromiumReorders() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        state.reorderTabs([
            9: 0,
            10: 1,
            3: 2,
            2: 3,
            1: 4,
        ])

        XCTAssertEqual(state.normalTabs.map(\.guid), [3, 2, 1, 10])
    }

    func testNewTabFromBookmarkLauncherAppendsToNormalTabs() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let bookmark = Bookmark(guid: "bookmark-p",
                                title: "Bookmark P",
                                url: "https://p.example")
        state.bookmarkManager.rootFolder.addChild(bookmark)

        let bookmarkLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: bookmark.guid)
        state.tabs.append(bookmarkLiveTab)
        state.updateNormalTabs()
        state.reorderTabs([1: 0, 9: 1, 2: 2, 3: 3])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 9, 2, 3])

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 9,
                sourceTabId: 9
            )
        )

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 9, 2, 3, 10])
    }

    func testVisibleOpenerAppendsAndSurvivesInitialChromiumEcho() throws {
        for kind in [NativeTabCreationKind.linkForeground, .linkBackground] {
            let state = try makeState()
            seedNormalTabs(state)

            state.handleNewTabFromChromium(
                Tab(guid: 10, url: "https://d.example", isActive: kind == .linkForeground, index: 1),
                context: NativeTabCreationContext(
                    isActiveAtCreation: kind == .linkForeground,
                    creationKind: kind,
                    openerTabId: 1,
                    insertAfterTabId: 1,
                    sourceTabId: 1
                )
            )
            XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])

            let chromiumOrder = [1: 0, 10: 1, 2: 2, 3: 3]
            state.reorderTabs(chromiumOrder)
            XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])

            state.reorderTabs(chromiumOrder)
            XCTAssertEqual(state.normalTabs.map(\.guid), [1, 10, 2, 3])
        }
    }

    /// Mail's links: Chromium reports the tab with no creation kind, at strip index 0.
    func testMailLinkTabAppendsAndSurvivesInitialChromiumEcho() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.openMailLink(URL(string: "https://d.example")!)
        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 0),
            context: NativeTabCreationContext(isActiveAtCreation: true, creationKind: .unknown)
        )
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])

        let chromiumOrder = [10: 0, 9: 1, 1: 2, 2: 3, 3: 4]
        state.reorderTabs(chromiumOrder)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 10])

        state.reorderTabs(chromiumOrder)
        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 1, 2, 3])
    }

    func testUnknownKindTabWithoutMailLinkKeepsChromiumSlot() throws {
        let state = try makeState()
        seedNormalTabs(state)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 0),
            context: NativeTabCreationContext(isActiveAtCreation: true, creationKind: .unknown)
        )
        state.reorderTabs([10: 0, 1: 1, 2: 2, 3: 3])
        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 1, 2, 3])
    }

    func testTypedTabCreatedInsideGroupKeepsChromiumSlot() throws {
        let state = try makeState()
        seedNormalTabs(state)
        state.tabs[0].groupToken = "g"
        state.tabs[1].groupToken = "g"

        let grouped = Tab(guid: 10, url: "https://d.example", isActive: true, index: 2)
        grouped.groupToken = "g"
        state.handleNewTabFromChromium(
            grouped,
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .typedNewTab,
                insertAfterTabId: 2,
                sourceTabId: 2
            )
        )

        state.reorderTabs([1: 0, 2: 1, 10: 2, 3: 3])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 10, 3])
    }

    func testToggleSplitPinStatusUnpinsOpenPinnedSplitOnce() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let leftPinned = Tab(guid: 100,
                             url: "https://left.example",
                             isActive: true,
                             index: 0,
                             customGuid: "pinned-left")
        let rightPinned = Tab(guid: 101,
                              url: "https://right.example",
                              isActive: false,
                              index: 1,
                              customGuid: "pinned-right")
        leftPinned.isOpenned = true
        rightPinned.isOpenned = true
        leftPinned.splitPartnerGuid = "pinned-right"
        rightPinned.splitPartnerGuid = "pinned-left"
        state.pinnedTabs = [leftPinned, rightPinned]

        let leftLive = Tab(guid: 100,
                           url: "https://left.example",
                           isActive: true,
                           index: 3,
                           customGuid: "pinned-left")
        let rightLive = Tab(guid: 101,
                            url: "https://right.example",
                            isActive: false,
                            index: 4,
                            customGuid: "pinned-right")
        leftLive.isPinned = true
        rightLive.isPinned = true
        state.tabs.append(contentsOf: [leftLive, rightLive])
        state.splits = [
            SplitGroup(id: "split-100-101",
                       primaryTabId: 100,
                       secondaryTabId: 101,
                       layout: .vertical,
                       ratio: 0.5,
                       isPinned: true)
        ]
        state.updateNormalTabs()

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3])

        state.toggleSplitPinStatus("split-100-101")

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 100, 101])
        XCTAssertEqual(state.splits.first?.primaryTabId, 100)
        XCTAssertEqual(state.splits.first?.secondaryTabId, 101)
        XCTAssertEqual(state.splits.first?.isPinned, false)
        XCTAssertNil(leftLive.guidInLocalDB)
        XCTAssertNil(rightLive.guidInLocalDB)
        XCTAssertFalse(leftLive.isPinned)
        XCTAssertFalse(rightLive.isPinned)
    }
}
