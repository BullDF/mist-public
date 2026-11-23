import XCTest
@testable import Phi

@MainActor
final class StartPageCommandTests: XCTestCase {
    private var directory: URL!
    private var localStores: [LocalStore] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for store in localStores { try await store.closeForAccountDirectoryRemoval() }
        localStores.removeAll()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCommandsFollowTheFocusedGroupedTabInSidebarLayouts() {
        let local = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory.appendingPathComponent(UUID().uuidString))
        localStores.append(local)
        let state = BrowserState(windowId: 772, localStore: local, profileId: "Default")
        state.layoutMode = .performance
        let tab = Tab(guid: 81, url: "https://example.com", isActive: true, index: 0, title: "Example")
        state.tabs = [tab]
        state.focusingTab = tab
        XCTAssertNil(state.startPageCommandTab(.PHI_SET_START_PAGE), "An ungrouped tab has no start page")

        tab.updateGroupMembership("group", title: "Work")
        XCTAssertNil(state.startPageCommandTab(.PHI_SET_START_PAGE), "Already on its start page")
        XCTAssertNil(state.startPageCommandTab(.PHI_RETURN_TO_START_PAGE))

        tab.url = "https://example.com/next"
        XCTAssertTrue(state.startPageCommandTab(.PHI_SET_START_PAGE) === tab)
        XCTAssertTrue(state.startPageCommandTab(.PHI_RETURN_TO_START_PAGE) === tab)
        XCTAssertNil(state.startPageCommandTab(.PHI_COPY_URL))

        state.layoutMode = .comfortable
        XCTAssertNil(state.startPageCommandTab(.PHI_RETURN_TO_START_PAGE), "The horizontal strip shows no start page")
        XCTAssertFalse(state.performStartPageCommand(.PHI_SET_START_PAGE))
        XCTAssertEqual(tab.groupStartPage, "https://example.com")

        state.layoutMode = .performance
        XCTAssertTrue(state.performStartPageCommand(.PHI_SET_START_PAGE))
        XCTAssertEqual(tab.groupStartPage, "https://example.com/next")
        XCTAssertNil(state.startPageCommandTab(.PHI_RETURN_TO_START_PAGE))

        state.focusingTab = nil
        XCTAssertNil(state.startPageCommandTab(.PHI_SET_START_PAGE))
    }
}
