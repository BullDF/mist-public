// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class TabSwitchManagerTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var states: [BrowserState] = []
    private var stores: [LocalStore] = []

    override func tearDown() async throws {
        for state in states { state.tabSwitchManager.cancelSession() }
        states.removeAll()
        let drained = expectation(description: "Tab history fixture callbacks drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        await fulfillment(of: [drained], timeout: 2)
        for store in stores { try await store.closeForAccountDirectoryRemoval() }
        stores.removeAll()
        for directory in tempDirectories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState(recordInitialVisits: Bool = true) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        stores.append(store)
        tempDirectories.append(store.account.userDataStorage)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        states.append(state)
        state.tabs = [makeTab(1), makeTab(2)]
        state.updateNormalTabs()
        if recordInitialVisits {
            state.focuseTab(state.tabs[1])
            state.focuseTab(state.tabs[0])
        }
        return state
    }

    private func makeTab(_ id: Int) -> Tab {
        Tab(guid: id, url: "https://example.com/\(id)", isActive: false, index: id - 1)
    }

    private func openBackgroundTab(_ id: Int, in state: BrowserState) {
        state.handleNewTabFromChromium(
            makeTab(id),
            context: NativeTabCreationContext(creationKind: .linkBackground, openerTabId: 1)
        )
    }

    func testBackgroundLinkBecomesNextCandidateWithoutTakingFocus() throws {
        let state = try makeState()

        openBackgroundTab(3, in: state)

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 3, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2])
        XCTAssertEqual(state.focusingTab?.guid, 1)
        XCTAssertFalse(try XCTUnwrap(state.tabs.first { $0.guid == 3 }).isActive)
    }

    func testNewestBackgroundLinksTakePriorityWithoutBecomingVisits() throws {
        let state = try makeState()

        for id in 3...8 {
            openBackgroundTab(id, in: state)
        }

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 8, 7, 6, 5, 4, 3, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2],
                       "Background arrivals are not visits")
        XCTAssertEqual(state.focusingTab?.guid, 1)
    }

    func testSwitcherListsEveryTabWithNeverVisitedOnesLastInStripOrder() throws {
        let state = try makeState()
        state.tabs += (3...12).map(makeTab)
        openBackgroundTab(13, in: state)
        state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == 7 }))

        XCTAssertEqual(state.tabSwitchManager.buildCandidates(),
                       [7, 1, 13, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12])
    }

    func testPanelFitsItsWindowAndScrollsSelectionIntoView() throws {
        let state = try makeState()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let controller = TabSwitchWindowController(parentWindow: parent)
        defer { controller.dismiss() }
        let ids = Array(1...12)
        let items = ids.map {
            TabSwitchItem(tabID: $0, title: "Tab \($0)", snapshotImage: nil,
                          liveFaviconImage: nil, faviconPageURL: nil)
        }
        let metrics = TabSwitchMetrics.self
        let fitting = metrics.visibleCellCount(fittingPanelWidth: 900 - metrics.windowParentMargin * 2)

        controller.update(items: items, selectedTabID: 2, themeProvider: state.themeContext)
        XCTAssertEqual(controller.window?.frame.width, metrics.panelWidth(cellCount: fitting))
        XCTAssertEqual(controller.fullyVisibleTabIDs, Array(ids.prefix(fitting)))

        controller.updateSelection(selectedTabID: 12)
        XCTAssertEqual(controller.fullyVisibleTabIDs, Array(ids.suffix(fitting)))
        controller.updateSelection(selectedTabID: 12 - fitting)
        XCTAssertEqual(controller.fullyVisibleTabIDs, Array(ids.dropLast().suffix(fitting)))
        controller.updateSelection(selectedTabID: 1)
        XCTAssertEqual(controller.fullyVisibleTabIDs, Array(ids.prefix(fitting)))

        controller.update(items: Array(items.prefix(2)), selectedTabID: 2, themeProvider: state.themeContext)
        XCTAssertEqual(controller.window?.frame.width, metrics.panelWidth(cellCount: 2))
        XCTAssertEqual(controller.fullyVisibleTabIDs, [1, 2])
    }

    func testBackgroundArrivalsPreserveCompleteMediaVisitOrder() throws {
        let state = try makeState()
        for id in 3...8 {
            openBackgroundTab(id, in: state)
            state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == id }))
        }
        let manager = state.tabSwitchManager
        XCTAssertEqual(manager.visitedTabIDs, [8, 7, 6, 5, 4, 3, 1, 2])

        for id in 9...14 {
            openBackgroundTab(id, in: state)
        }

        XCTAssertEqual(manager.recentTabIDs, [8, 14, 13, 12, 11, 10, 9, 7, 6, 5, 4, 3, 1, 2])
        XCTAssertEqual(manager.visitedTabIDs, [8, 7, 6, 5, 4, 3, 1, 2])
    }

    func testBackgroundArrivalWithoutFocusDoesNotInventVisits() throws {
        let state = try makeState(recordInitialVisits: false)

        openBackgroundTab(3, in: state)
        state.tabSwitchManager.recordBackgroundTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3])
        XCTAssertTrue(state.tabSwitchManager.visitedTabIDs.isEmpty)
        XCTAssertNil(state.focusingTab)
    }

    func testStaleTabsArePrunedFromBothHistories() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        state.tabs.removeAll { $0.guid == 2 || $0.guid == 3 }

        openBackgroundTab(4, in: state)

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 4])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1])
    }

    func testVisitingBackgroundTabResumesMRUOrdering() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        openBackgroundTab(4, in: state)

        state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 4, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [3, 1, 2])
        state.tabSwitchManager.removeTab(tabID: 4)
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [3, 1, 2])
        state.tabSwitchManager.removeTab(tabID: 3)
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2])
    }

    func testOtherCreationKindsDoNotEnterHistoryBeforeActivation() throws {
        let state = try makeState()
        let kinds: [NativeTabCreationKind] = [
            .linkForeground, .typedNewTab, .typedNavigation, .explicitInsert,
            .moveFromOtherWindow, .restore, .bridgeCreate, .unknown,
        ]
        for (index, kind) in kinds.enumerated() {
            state.handleNewTabFromChromium(
                makeTab(index + 3),
                context: NativeTabCreationContext(creationKind: kind)
            )
        }
        state.handleNewTabFromChromium(makeTab(20))
        state.handleNewTabFromChromium(
            makeTab(21),
            context: NativeTabCreationContext(isActiveAtCreation: true, creationKind: .linkBackground)
        )

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 2])
    }

    func testBackgroundAdmissionIgnoresForeignTabsAndExistingHistory() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        openBackgroundTab(4, in: state)
        let manager = state.tabSwitchManager

        manager.recordBackgroundTab(makeTab(99))
        manager.recordBackgroundTab(state.tabs[0])
        manager.recordBackgroundTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(manager.recentTabIDs, [1, 4, 3, 2])
    }

}
