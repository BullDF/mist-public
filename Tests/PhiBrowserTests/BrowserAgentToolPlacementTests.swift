import XCTest
@testable import Phi

@MainActor
final class BrowserAgentToolPlacementTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    func testNewTabsAreClaimedByTheFolderOnlyForDefaultPlacement() throws {
        let state = try makeState()
        let tabs = seedTabs(in: state, titles: ["Folder member", "Group member", "After group", "Folder tab", "Group tab", "User tab", "Vanished group tab"])
        let folder = "folder", group = "group"
        state.handleTabGroupCreated(token: folder, title: "Agent tabs" + BrowserAgentFolderState.titleMarker,
                                    color: .grey, isCollapsed: false, initialTabIds: [tabs[0].guid])
        state.handleTabGroupCreated(token: group, title: "Reading", color: .blue,
                                    isCollapsed: false, initialTabIds: [tabs[1].guid])

        let chatId = UUID()
        var claimed: [Int] = []
        let registry = AgentUserSpaceDriveRegistry(browserChat: { $0 == "agent" ? chatId : nil }) { tabId, id, windowId in
            XCTAssertEqual(id, chatId)
            XCTAssertEqual(windowId, state.windowId)
            claimed.append(tabId)
            state.addTabsToGroupEnd([tabId], token: folder)
        }
        defer { registry.resetForTesting() }

        registry.agentWillOpenTab(inWindow: state.windowId, principalId: "agent", driverName: "Test")
        registry.noteTabCreated(tabId: tabs[3].guid, windowId: state.windowId, state: state)
        XCTAssertEqual(tabs[3].groupToken, folder)

        // User-group placement also works for an external agent with no chat ID.
        registry.agentWillOpenTab(inWindow: state.windowId, principalId: "external", driverName: "Test", placement: .group(token: group))
        registry.noteTabCreated(tabId: tabs[4].guid, windowId: state.windowId, state: state)
        XCTAssertEqual(tabs[4].groupToken, group)
        XCTAssertEqual(state.normalTabs.map(\.guid), [0, 3, 1, 4, 2, 5, 6].map { tabs[$0].guid })
        XCTAssertTrue(registry.isDriven(tabId: tabs[4].guid))

        registry.agentWillOpenTab(inWindow: state.windowId, principalId: "agent", driverName: "Test", placement: .tabList)
        registry.noteTabCreated(tabId: tabs[5].guid, windowId: state.windowId, state: state)
        XCTAssertNil(tabs[5].groupToken)
        XCTAssertTrue(registry.isDriven(tabId: tabs[5].guid))

        registry.agentWillOpenTab(inWindow: state.windowId, principalId: "agent", driverName: "Test", placement: .group(token: "missing"))
        registry.noteTabCreated(tabId: tabs[6].guid, windowId: state.windowId, state: state)
        XCTAssertNil(tabs[6].groupToken)
        XCTAssertEqual(state.normalTabs.last?.guid, tabs[6].guid)
        XCTAssertEqual(claimed, [tabs[3].guid])
    }

    func testMountRefusalsMountStatusAndUnmountUseTheCallerOnly() throws {
        let state = try makeState()
        let tabs = seedTabs(in: state, titles: ["Focused tab", "Example", "Ineligible", "Occupied"])
        tabs[2].url = MistAppRoute.current.url(.clipboard).absoluteString
        tabs[2].aiChatEnabled = false
        let store = try makeChatStore(for: state)
        defer { store.terminate() }
        let caller = try store.createEmpty(tabId: tabs[0].guid)
        let peer = try store.createEmpty(tabId: tabs[3].guid)
        XCTAssertTrue(store.mount(peer.id, to: tabs[3].guid))
        let findTab = { (id: Int) in state.tabs.first { $0.guid == id } }
        func mount(_ tabId: Int) throws -> [String: Any] {
            try reply(AgentSpaceRouter.mountAgentChat(caller.id, to: tabId, in: state, store: store, findTab: findTab))
        }

        XCTAssertNotNil(try mount(-1)["error"])
        XCTAssertEqual(try mount(tabs[2].guid)["error"] as? String, "That tab can't show a Chat panel.")
        XCTAssertEqual(try mount(tabs[3].guid)["error"] as? String, "That tab's Chat panel already shows another chat.")
        let host = ["tabId": tabs[1].guid, "title": "Example"] as [String: AnyHashable]
        XCTAssertEqual(try mount(tabs[1].guid)["mountedTo"] as? [String: AnyHashable], host)
        XCTAssertEqual(store.panelHost(of: caller.id), tabs[1].guid)
        XCTAssertTrue(state.focusingTab === tabs[0])
        XCTAssertTrue(tabs[0].aiChatCollapsed)
        XCTAssertFalse(tabs[1].aiChatCollapsed)
        XCTAssertEqual(try mount(tabs[0].guid)["error"] as? String,
                       "This chat is mounted to Example (tab \(tabs[1].guid)). Call unmount_from_tab first.")

        let listing = try reply(AgentSpaceRouter.listAgentChats(caller: caller.id, store: store, findTab: findTab))
        let agents = try XCTUnwrap(listing["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(agents.first { $0["self"] as? Bool == true }?["mountedTo"] as? [String: AnyHashable], host)
        XCTAssertNil(agents.first { $0["self"] == nil }?["mountedTo"])

        let unmounted = try reply(AgentSpaceRouter.unmountAgentChat(caller.id, store: store, findTab: findTab))
        XCTAssertEqual(unmounted["unmountedFrom"] as? [String: AnyHashable], host)
        XCTAssertNil(store.panelHost(of: caller.id))
        XCTAssertNil(store.panelChat(for: tabs[1].guid))
        XCTAssertNotNil(store.entry(for: caller.id))
        XCTAssertEqual(store.panelHost(of: peer.id), tabs[3].guid)
        XCTAssertTrue(state.focusingTab === tabs[0])
        XCTAssertEqual(try reply(AgentSpaceRouter.unmountAgentChat(caller.id, store: store, findTab: findTab))["error"] as? String,
                       "This chat isn't mounted to a tab.")
    }

    func testMountLeavesFocusedAndExtensionPanelsAlone() throws {
        let state = try makeState()
        let tabs = seedTabs(in: state, titles: ["Focused", "Split partner", "Background"])
        let store = try makeChatStore(for: state)
        defer { store.terminate() }
        let caller = try store.createEmpty(tabId: tabs[0].guid)
        state.splits = [.init(id: "split", primaryTabId: tabs[0].guid, secondaryTabId: tabs[1].guid,
                              layout: .vertical, ratio: 0.5)]
        state.updateExtensionSidePanel(.init(extensionId: "test", displayName: "Test Panel",
                                            iconPNG: nil, wrapper: PageColorTestWebContentWrapper(urlString: nil)))
        state.extensionSidePanelCloseRequestOverrideForTesting = { XCTFail("Mount asked the extension panel to close") }
        for tab in [tabs[2], tabs[1], tabs[0]] {
            let result = try reply(AgentSpaceRouter.mountAgentChat(caller.id, to: tab.guid, in: state,
                                                                 store: store, findTab: { _ in nil }))
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertTrue(tabs.allSatisfy(\.aiChatCollapsed))
            XCTAssertTrue(state.focusingTab === tabs[0])
            XCTAssertEqual(store.panelHost(of: caller.id), tab.guid)
            store.unmount(caller.id)
            state.updateExtensionSidePanel(nil)
        }
    }

    func testExportCreatesParentsWritesCountsAndHonorsOverwrite() async throws {
        let state = try makeState()
        // The store's first (empty) delivery replaces the tree; seed it only after that, or an await below lets it wipe the folder.
        let deadline = Date().addingTimeInterval(5)
        while !state.bookmarkManager.didApplyFirstStoreDelivery, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(state.bookmarkManager.didApplyFirstStoreDelivery)
        let folder = Bookmark(title: "Reading", isFolder: true)
        folder.addChild(Bookmark(title: "Example", url: "https://example.com/", secondaryUrl: "https://example.com/split"))
        state.bookmarkManager.rootFolder.addChild(folder)
        state.pinnedTabs = [Tab(url: "https://example.com/pinned", isActive: false, index: 0, title: "Pinned")]
        let path = try directory().appendingPathComponent("exports/bookmarks.html")

        let counts = try await export(state, to: path, overwrite: false)
        XCTAssertEqual(counts.bookmarks, 1)
        XCTAssertEqual(counts.pinnedTabs, 1)
        let html = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        for url in ["https://example.com/", "https://example.com/split", "https://example.com/pinned"] {
            XCTAssertTrue(html.contains("HREF=\"\(url)\""))
        }
        try Data("original".utf8).write(to: path)
        do {
            _ = try await export(state, to: path, overwrite: false)
            XCTFail("An existing file was accepted")
        } catch BookmarkHTMLExporter.ExportError.destinationExists {
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original")
        }
        _ = try await export(state, to: path, overwrite: true)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), html)
    }

    func testExportRefusesAnEmptySpace() throws {
        let state = try makeState()
        let path = try directory().appendingPathComponent("bookmarks.html")
        XCTAssertThrowsError(try BookmarkHTMLExporter.export(from: state, to: path, overwrite: false) { _ in
            XCTFail("Empty export started a write")
        }) { error in
            XCTAssertEqual(error as? BookmarkHTMLExporter.ExportError, .emptySpace)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func export(_ state: BrowserState, to path: URL, overwrite: Bool) async throws -> BookmarkHTMLExporter.Counts {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try BookmarkHTMLExporter.export(from: state, to: path, overwrite: overwrite, createParentDirectories: true) {
                    continuation.resume(with: $0)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func reply(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func makeChatStore(for state: BrowserState) throws -> AgentChatStore {
        AgentChatStore(route: .init(baseDirectory: try directory()), launchSettings: .init(defaults: makeTestDefaults().defaults),
                       tabExists: { id in state.tabs.contains { $0.guid == id } })
    }

    private func makeState() throws -> BrowserState {
        BrowserState(windowId: 88001, localStore: LocalStore(account: Account(userID: UUID().uuidString),
                     storeDirectoryURL: try directory()), profileId: LocalStore.defaultProfileId)
    }

    private func seedTabs(in state: BrowserState, titles: [String]) -> [Tab] {
        let tabs = titles.enumerated().map { index, title in
            let tab = Tab(guid: 88100 + index, url: "https://example.com/\(index)", isActive: index == 0,
                          index: index, title: title, windowId: state.windowId)
            tab.aiChatEnabled = true
            return tab
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs.first
        return tabs
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }
}
