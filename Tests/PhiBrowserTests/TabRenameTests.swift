import XCTest
@testable import Phi

@MainActor
final class TabRenameTests: XCTestCase {
    func testPinnedSnapshotFollowsPageTitleUnlessNamed() throws {
        let model = TabDataModel(title: "Inbox (1)", guid: UUID().uuidString, index: 0,
                                 url: try XCTUnwrap(URL(string: "https://example.com")), favicon: nil,
                                 createdDate: Date(), updatedDate: Date())
        model.dataType = .pinnedTab
        let unnamed = Tab(with: model)
        XCTAssertNil(unnamed.storedTitle)
        unnamed.applyPageTitle("Inbox")
        XCTAssertEqual(unnamed.title, "Inbox")

        model.overrideTitle = "Mail"
        let named = Tab(with: model)
        XCTAssertEqual(named.storedTitle, "Mail")
        named.applyPageTitle("Inbox")
        XCTAssertEqual(named.title, "Mail")
    }

    func testPinnedRenameAndUnchangedEditPreserveSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        let model = TabDataModel(title: "Inbox (1)", guid: UUID().uuidString, index: 0,
                                 url: try XCTUnwrap(URL(string: "https://example.com")), favicon: nil,
                                 createdDate: Date(), updatedDate: Date())
        model.dataType = .pinnedTab
        context.insert(profile)
        context.insert(model)
        model.profile = profile
        try context.save()
        let guid = model.guid
        let state = BrowserState(windowId: 71005, localStore: store, profileId: "Default", spaceId: "space-a")
        let tab = try XCTUnwrap(state.pinnedTabs.first)

        Tab.applyPinnedTabEdit(targetTab: tab, url: "https://example.com/new", title: "Inbox (1)", in: state)
        await store.performBackgroundWriteAndWait { _ in }
        XCTAssertNil(store.getTab(by: guid)?.overrideTitle)

        state.renameTab(tab, to: "Mail")
        await store.performBackgroundWriteAndWait { _ in }
        XCTAssertEqual(store.getTab(by: guid)?.title, "Inbox (1)")
        XCTAssertEqual(store.getTab(by: guid)?.overrideTitle, "Mail")
        state.renameTab(tab, to: "")
        await store.performBackgroundWriteAndWait { _ in }
        XCTAssertEqual(store.getTab(by: guid)?.title, "Inbox (1)")
        XCTAssertNil(store.getTab(by: guid)?.overrideTitle)
        XCTAssertNil(tab.storedTitle)

        try await store.closeForAccountDirectoryRemoval()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: store.account.userDataStorage)
    }

    func testOpenPinnedRecordFollowsInPageTitleChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        let model = TabDataModel(title: "Inbox (1)", guid: UUID().uuidString, index: 0,
                                 url: try XCTUnwrap(URL(string: "https://example.com")), favicon: nil,
                                 createdDate: Date(), updatedDate: Date())
        model.dataType = .pinnedTab
        context.insert(profile)
        context.insert(model)
        model.profile = profile
        try context.save()
        let state = BrowserState(windowId: 71006, localStore: store, profileId: "Default", spaceId: "space-a")
        let record = try XCTUnwrap(state.pinnedTabs.first)
        let live = Tab(guid: 71006, url: "https://example.com", isActive: false, index: 0,
                       webContentView: PageColorTestWebContentWrapper(urlString: "https://example.com"))
        live.guidInLocalDB = model.guid
        record.isOpenned = true
        record.guid = live.guid
        state.tabs = [live]

        state.updateTabTitle(tabId: live.guid, newTitle: "Inbox")
        XCTAssertEqual(live.title, "Inbox")
        XCTAssertEqual(record.title, "Inbox")

        state.tabs = []
        try await store.closeForAccountDirectoryRemoval()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: store.account.userDataStorage)
    }

    func testNameSurvivesPageTitleChangeAndClearingRestoresCurrentTitle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 71001, localStore: store, profileId: "Default",
                                 spaceId: UUID().uuidString)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        wrapper.title = "Original page"
        let tab = Tab(guid: 71001, url: wrapper.urlString, isActive: false, index: 0,
                      webContentView: wrapper)
        state.tabs = [tab]

        state.renameTab(tab, to: "  My tab  ")
        XCTAssertEqual(tab.title, "My tab")
        wrapper.title = "New page title"
        XCTAssertEqual(tab.title, "My tab")
        state.updateTabTitle(tabId: tab.guid, newTitle: "Navigated page")
        XCTAssertEqual(tab.title, "My tab")
        state.renameTab(tab, to: " \n ")
        XCTAssertNil(tab.storedTitle)
        XCTAssertEqual(tab.title, "Navigated page")
        state.updateTabTitle(tabId: tab.guid, newTitle: "Later page")
        XCTAssertEqual(tab.title, "Later page")

        state.tabs = []
        try await store.closeForAccountDirectoryRemoval()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: store.account.userDataStorage)
    }

    func testTabsRestoredIntoANewGroupClaimTheirNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let names = TabNameStore(defaults: makeTestDefaults().defaults)
        let spaceId = UUID().uuidString
        let url = "https://example.com/grouped"
        func makeTab(_ guid: Int) -> Tab {
            Tab(guid: guid, url: url, isActive: false, index: 0,
                webContentView: PageColorTestWebContentWrapper(urlString: url))
        }

        let closedState = BrowserState(windowId: 71002, localStore: store, profileId: "Default", spaceId: spaceId)
        let closed = makeTab(71002)
        closedState.tabs = [closed]
        names.set("Grouped tab", for: closed, in: closedState)
        names.closing(tabId: closed.guid, in: closedState)

        // Reopen Closed Window brings grouped tabs back as background link
        // opens, then creates their group around them.
        let restoredState = BrowserState(windowId: 71003, localStore: store, profileId: "Default", spaceId: spaceId)
        restoredState.tabNameRestoreSourceWindowId = closedState.windowId
        let existing = makeTab(71003)
        let restored = makeTab(71004)
        restoredState.tabs = [existing, restored]
        names.arrived(restored, in: restoredState, restoring: false)
        XCTAssertNil(restored.storedTitle)

        names.groupCreated(tabIds: [existing.guid], in: restoredState)
        XCTAssertNil(existing.storedTitle)
        names.groupCreated(tabIds: [restored.guid], in: restoredState)
        XCTAssertEqual(restored.title, "Grouped tab")

        closedState.tabs = []
        restoredState.tabs = []
        try await store.closeForAccountDirectoryRemoval()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: store.account.userDataStorage)
    }
}
