import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor
final class MistSidebarAgentSectionTests: XCTestCase {
    private var directories: [URL] = []
    private var oldExpandedValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let key = MistSidebarAgentSections.expandedKey()
        oldExpandedValues[key] = UserDefaults.standard.object(forKey: key)
        MistSidebarAgentSections.setExpanded(true)
    }

    override func tearDown() {
        let key = MistSidebarAgentSections.expandedKey()
        MistSidebarAgentSections.setExpanded(oldExpandedValues[key] as? Bool ?? true)
        if oldExpandedValues[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func testMembershipKeepsNormalTabOrder() {
        let first = chat(1)
        let second = chat(2)
        let browser = chat(3)
        let web = Tab(guid: 4, url: "https://example.com", isActive: false, index: 0)
        let tabs = [second, web, browser, first]
        XCTAssertEqual(MistSidebarAgentSections.members(in: tabs, splits: [], isIncognito: false).map(\.guid), [2, 3, 1])
    }

    func testGroupedAndSplitChatsStayInTabSection() throws {
        let standalone = chat(1)
        let grouped = chat(2)
        grouped.groupToken = "group"
        let splitChat = chat(3)
        let partner = Tab(guid: 4, url: "https://example.com", isActive: false, index: 3)
        let split = SplitGroup(id: "split", primaryTabId: 3, secondaryTabId: 4, layout: .vertical, ratio: 0.5)
        let tabs = [standalone, grouped, splitChat, partner]
        XCTAssertEqual(MistSidebarAgentSections.members(in: tabs, splits: [split], isIncognito: false).map(\.guid), [1])
        let state = try makeState(tabs: tabs)
        state.splits = [split]
        let controller = TabSectionController()
        controller.browserState = state
        XCTAssertFalse(controller.tabItems.contains { $0.id == standalone.id })
        XCTAssertTrue(controller.tabItems.contains { $0.id == grouped.id })
        XCTAssertTrue(controller.tabItems.contains { ($0 as? SplitPairSidebarItem)?.leftTab === splitChat })
    }

    func testCollapsedSectionRetainsOnlyItsActiveMemberAndEmptySectionsAreHidden() {
        let members = [chat(1), chat(2)]
        let header = MistSidebarAgentHeaderItem()
        let expanded = MistSidebarAgentSections.outlineItems(members: members, header: header, isExpanded: true, activeTabId: 2)
        XCTAssertEqual(expanded.map(\.id), [header.id] + members.map(\.id))
        let collapsed = MistSidebarAgentSections.outlineItems(members: members, header: header, isExpanded: false, activeTabId: 2)
        XCTAssertEqual(collapsed.map(\.id), [header.id, members[1].id])
        XCTAssertEqual(MistSidebarAgentSections.outlineItems(members: members, header: header, isExpanded: false, activeTabId: 99).map(\.id), [header.id])
        XCTAssertTrue(MistSidebarAgentSections.outlineItems(members: [], header: header, isExpanded: true, activeTabId: 2).isEmpty)
        XCTAssertTrue(MistSidebarAgentSections.members(in: members, splits: [], isIncognito: true).isEmpty)
    }

    func testExpansionFlagIsPublishedAppWide() {
        var observed: [Bool] = []
        let subscription = MistSidebarAgentSections.expandedPublisher().sink { observed.append($0) }
        MistSidebarAgentSections.setExpanded(false)
        XCTAssertFalse(MistSidebarAgentSections.isExpanded())
        XCTAssertEqual(observed, [true, false])
        withExtendedLifetime(subscription) {}
    }

    func testBrowserFolderFollowsChatAndCollapsedSectionShowsOnlyActiveFolderTab() throws {
        let conversation = AgentConversation()
        let chatTab = Tab(guid: 900_001, url: AgentChatRoute.current.placeholderURL(for: conversation.id).absoluteString,
                          isActive: false, index: 0)
        let first = Tab(guid: 900_002, url: "https://first.example", isActive: false, index: 1)
        let second = Tab(guid: 900_003, url: "https://second.example", isActive: true, index: 2)
        let web = Tab(guid: 900_004, url: "https://user.example", isActive: false, index: 3)
        first.groupToken = "folder"
        second.groupToken = "folder"
        let state = try makeState(tabs: [chatTab, first, second, web])
        state.focusingTab = second
        state.groups["folder"] = WebContentGroupInfo(token: "folder", title: "Agent tabs", color: .grey, isCollapsed: true)
        AgentChatStore.shared.register(.init(conversation: conversation, settings: DrifterSettings(config: .init()),
            tabId: chatTab.guid, session: NSObject(),
            browserPreview: .init(principalId: "sidebar-folder-test", windowId: state.windowId),
            browserFolder: .init(windowId: state.windowId, token: "folder")))
        defer { AgentChatStore.shared.closeIfTabIsGone(chatTab.guid) }
        let section = TabSectionController()
        section.browserState = state
        XCTAssertEqual(section.tabItems.map(\.itemType), [.newTabButton, .tab])
        let sidebar = SidebarTabListViewController(state: state)
        sidebar.loadViewIfNeeded()
        sidebar.setActive(true)
        defer { sidebar.setActive(false) }
        let scroll = try XCTUnwrap(sidebar.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? SideBarOutlineView)
        XCTAssertEqual(rootItems(sidebar, outline).map(\.itemType), [.agentHeader, .tab, .tabGroup, .separator, .newTabButton, .tab])
        let folder = try XCTUnwrap(rootItems(sidebar, outline).compactMap { $0 as? TabGroupSidebarItem }.first)
        XCTAssertTrue(folder.isCollapsed)
        XCTAssertEqual(folder.childrenItems.map(\.id), [first.id, second.id])
        MistSidebarAgentSections.setExpanded(false)
        waitUntil { self.rootItems(sidebar, outline).map(\.itemType) == [.agentHeader, .tabGroup, .separator, .newTabButton, .tab] }
        XCTAssertEqual(folder.childrenItems.map(\.id), [second.id])
        XCTAssertFalse(folder.isCollapsed)
        XCTAssertTrue(state.groups["folder"]!.isCollapsed, "Section visibility does not rewrite Chromium's collapse state")
        XCTAssertEqual(Set(MistSidebarAgentSections.membersIncludingFolders(in: state).map(\.guid)),
                       [chatTab.guid, first.guid, second.guid])
        chatTab.groupToken = "user-group"
        waitUntil { section.tabItems.contains { ($0 as? TabGroupSidebarItem)?.group.token == "folder" } }
        XCTAssertTrue(MistSidebarAgentSections.folderTokens(in: state).isEmpty)
    }

    func testURLChangesMoveExistingRowAndCollapsedFocusChangesStayVisible() throws {
        let first = Tab(guid: 1, url: "chrome://newtab", isActive: true, index: 0)
        let second = chat(2)
        let web = Tab(guid: 3, url: "https://example.com", isActive: false, index: 2)
        let state = try makeState(tabs: [first, second, web])
        state.focusingTab = first
        let section = TabSectionController()
        section.browserState = state
        let sidebar = SidebarTabListViewController(state: state)
        sidebar.loadViewIfNeeded()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        sidebar.setActive(true)
        defer { sidebar.setActive(false) }
        let scroll = try XCTUnwrap(sidebar.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? SideBarOutlineView)
        first.url = AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString
        waitUntil { !section.tabItems.contains { $0.id == first.id } && self.rootItems(sidebar, outline).first?.itemType == .agentHeader }
        XCTAssertEqual(rootItems(sidebar, outline).map(\.itemType), [.agentHeader, .tab, .tab, .separator, .newTabButton, .tab])
        XCTAssertNil(sidebar.outlineView(outline, pasteboardWriterForItem: first))
        XCTAssertNotNil(sidebar.outlineView(outline, pasteboardWriterForItem: web))
        MistSidebarAgentSections.setExpanded(false)
        waitUntil { self.rootItems(sidebar, outline).filter { $0 is Tab }.map(\.id) == [first.id, web.id] }
        state.focusingTab = second
        waitUntil { self.rootItems(sidebar, outline).filter { $0 is Tab }.map(\.id) == [second.id, web.id] }
        first.url = "https://returned.example"
        waitUntil { section.tabItems.contains { $0.id == first.id } }
    }

    func testRestoredRowDimsAndNavigationClearsStatusWithoutReconfiguring() throws {
        let tab = chat(1)
        let model = TabViewModel()
        model.configure(with: tab)
        waitUntil { model.isEndedAgentChat }
        XCTAssertEqual(model.agentSidebarStatus, .none)
        tab.url = "https://example.com"
        waitUntil { !model.isEndedAgentChat }
        model.prepareForReuse()
    }

    func testLiveRowStatusTracksCompletionSeenNewTurnAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { _, _, _ in NSObject() })
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 42)
        let tab = Tab(guid: 42, url: store.route.placeholderURL(for: conversation.id).absoluteString, isActive: false, index: 0)
        var marker = AgentSidebarStatus.none
        var ended = false
        let subscription = TabViewModel.agentSidebarStatusPublisher(for: tab, store: store).sink { marker = $0; ended = $1 }
        waitUntil { marker == .running }
        conversation.update(items: [], status: .running)
        conversation.update(items: [], status: .idle)
        waitUntil { marker == .done }
        store.markSeen(tabId: 42)
        waitUntil { marker == .none }
        conversation.update(items: [], status: .awaitingPermission)
        waitUntil { marker == .needsInput }
        conversation.update(items: [], status: .failed("Failed"))
        waitUntil { marker == .failed }
        store.closeIfTabIsGone(42)
        waitUntil { marker == .none && !ended }
        try FileManager.default.removeItem(at: store.route.recordURL(for: conversation.id))
        store.objectWillChange.send()
        waitUntil { marker == .none && ended }
        withExtendedLifetime(subscription) {}
    }

    func testCollapsingFocusesNearestVisibleTabRightThenLeft() {
        let left = Tab(guid: 1, url: "https://left.example", isActive: false, index: 0)
        let focused = chat(2)
        let hiddenRight = chat(3)
        let right = Tab(guid: 4, url: "https://right.example", isActive: false, index: 3)
        let tabs = [left, focused, hiddenRight, right]
        XCTAssertTrue(MistSidebarAgentSections.focusTarget(after: focused, in: tabs, hiding: [2, 3]) === right)
        XCTAssertTrue(MistSidebarAgentSections.focusTarget(after: focused, in: tabs, hiding: [2, 3, 4]) === left)
        XCTAssertNil(MistSidebarAgentSections.focusTarget(after: focused, in: tabs, hiding: [1, 2, 3, 4]))
    }

    private func chat(_ id: Int) -> Tab {
        Tab(guid: id, url: AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, isActive: false, index: id, title: "Chat \(id)")
    }

    private func makeState(tabs: [Tab]) throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        state.tabs = tabs
        state.normalTabs = tabs
        return state
    }

    private func rootItems(_ sidebar: SidebarTabListViewController, _ outline: NSOutlineView) -> [SidebarItem] {
        (0..<sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).compactMap {
            sidebar.outlineView(outline, child: $0, ofItem: nil) as? SidebarItem
        }
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
}
