import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor final class DrifterHomeTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        DrifterHomeModel.draft = AgentComposerDraft()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(url)
        return url
    }

    private func state() -> BrowserState {
        BrowserState(windowId: 84001,
                     localStore: LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory()),
                     profileId: "Default")
    }

    func testFactoryDistinguishesHomeAndChatAndShowingHomeCreatesNoChat() throws {
        let root = directory()
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in false })
        defer { store.terminate() }
        let app = DrifterApp(store: store)
        let home = MistAppAddress(app: .drifter, instance: nil)
        let page = try XCTUnwrap(app.makePage(home) as? DrifterHomeViewController)
        XCTAssertTrue(app.makePage(.init(app: .drifter, instance: UUID())) is AgentChatViewController)
        let tab = Tab(guid: 84002, url: MistAppRoute.current.url(.drifter).absoluteString, isActive: true, index: 0)
        page.show(home, tab: tab, state: state())
        _ = page.view
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.route.directory.path))
        XCTAssertTrue(store.agentChats().isEmpty)
        XCTAssertNil(page.pageZoom)
        XCTAssertTrue(page.performPageCommand(.IDC_FIND))
        XCTAssertTrue(page.model.focusSearch)
        XCTAssertFalse(page.performPageCommand(.IDC_ZOOM_PLUS))
    }

    func testPageFactoryRecreatesControllerBetweenHomeAndChat() throws {
        let store = AgentChatStore(route: .init(baseDirectory: directory()), tabExists: { _ in true })
        defer { store.terminate() }
        let chat = try store.createEmpty(tabId: 84002)
        let state = state()
        let tab = Tab(guid: 84002, url: MistAppRoute.current.url(.drifter).absoluteString, isActive: true, index: 0)
        let controller = WebContentViewController(state: state, tab: tab, appPageFactory: { DrifterApp(store: store).makePage($0) })
        _ = controller.splitPaneContentView()
        let home = try XCTUnwrap(controller.appPageController)
        XCTAssertTrue(home is DrifterHomeViewController)
        tab.url = MistAppRoute.current.url(.drifter, instance: chat.id).absoluteString
        _ = controller.splitPaneContentView()
        XCTAssertTrue(controller.appPageController is AgentChatViewController)
        XCTAssertFalse(controller.appPageController === home)
        tab.url = MistAppRoute.current.url(.drifter).absoluteString
        _ = controller.splitPaneContentView()
        XCTAssertTrue(controller.appPageController is DrifterHomeViewController)
    }

    func testModelGroupsOpenFamiliesOmitsEmptyAndExcludesOngoingFromHistory() async throws {
        let root = directory()
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { [10, 20, 30].contains($0) },
            windowId: { _ in 84001 }, browserSessionFactory: { request, conversation, _ in
                conversation.update(items: [.init(id: "user", kind: .userMessage(text: request.prompt, images: []))], status: .idle)
                return NSObject()
            })
        defer { store.terminate() }
        let open = try store.create(request: .init(prompt: "Open", config: .init(folder: root), windowId: 84001), tabId: 10)
        let parent = try store.create(request: .init(prompt: "Parent", config: .init(folder: root), windowId: 84001), tabId: 20)
        let empty = try store.createEmpty(tabId: 30)
        _ = try store.spawnAgentChat(from: parent.id, brief: "Child brief", title: "Child").get()
        let child = try XCTUnwrap(store.parent.first { $0.value == parent.id }?.key)
        let closed = try store.create(request: .init(prompt: "Earlier", config: .init(folder: root), windowId: 84001), tabId: 99)
        store.saveRecord(closed.id, synchronously: true)
        let model = DrifterHomeModel(store: store)
        let loaded = expectation(description: "Background history loaded")
        let subscription = model.$history.filter { $0.map(\.id) == [closed.id] }.first().sink { _ in loaded.fulfill() }
        defer { subscription.cancel(); model.disappear() }
        model.appear()
        XCTAssertEqual(Set(model.ongoing.map(\.id)), [open.id, parent.id])
        XCTAssertEqual(model.ongoing.first { $0.id == parent.id }?.children.map(\.id), [child])
        XCTAssertFalse(model.ongoing.contains { $0.id == empty.id })
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(model.history.map(\.id), [closed.id])
        let nonempty = expectation(description: "First message adds an empty chat")
        let changes = model.$ongoing.filter { $0.contains { $0.id == empty.id } }.first().sink { _ in nonempty.fulfill() }
        defer { changes.cancel() }
        empty.update(items: [.init(id: "first", kind: .userMessage(text: "Now open", images: []))], status: .running)
        await fulfillment(of: [nonempty], timeout: 5)
        model.historyLimit = 40
        model.query = "Earlier"
        XCTAssertEqual(model.historyLimit, 20)
    }

    /// Only one absence of a minute or more clears the search; a quicker return keeps it and restarts the count.
    func testSearchClearsAfterAMinuteAwayFromThePage() throws {
        let store = AgentChatStore(route: .init(baseDirectory: directory()), tabExists: { _ in false })
        defer { store.terminate() }
        let model = DrifterHomeModel(store: store)
        let start = Date()
        model.query = "carbon"
        model.pageWillShow(at: start)
        model.pageDidHide(at: start)
        model.pageWillShow(at: start + 40)
        XCTAssertEqual(model.query, "carbon")
        model.pageDidHide(at: start + 50)
        model.pageWillShow(at: start + 50 + 59)
        XCTAssertEqual(model.query, "carbon")
        model.pageDidHide(at: start + 120)
        model.pageWillShow(at: start + 120 + DrifterHomeModel.searchResetDelay)
        XCTAssertEqual(model.query, "")
    }

    func testFailedLaunchKeepsSharedHomeDraftAndComposerText() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("blocked")
        try Data("file, not a directory".utf8).write(to: blocked)
        let store = AgentChatStore(route: .init(baseDirectory: blocked), tabExists: { _ in false },
                                   browserSessionFactory: { _, _, _ in XCTFail("Failed launch must not reach the engine"); return NSObject() })
        defer { store.terminate() }
        let state = state()
        let tab = Tab(guid: 84002, url: MistAppRoute.current.url(.drifter).absoluteString, isActive: true, index: 0)
        let page = DrifterHomeViewController(store: store)
        page.show(.init(app: .drifter, instance: nil), tab: tab, state: state)
        _ = page.view
        page.composer.editor.text = "Keep this message"
        XCTAssertEqual(DrifterHomeModel.draft.text, "Keep this message")
        page.composer.send()
        XCTAssertEqual(page.composer.editor.text, "Keep this message")
        XCTAssertEqual(DrifterHomeModel.draft.text, "Keep this message")
        XCTAssertTrue(store.agentChats().isEmpty)
        let other = DrifterHomeViewController(store: store)
        _ = other.view
        XCTAssertEqual(other.composer.editor.text, "Keep this message")
    }
}
