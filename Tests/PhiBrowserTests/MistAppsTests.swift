import AppKit
import XCTest
@testable import Phi

@MainActor final class MistAppsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func state(incognito: Bool = false) -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let account = Account(userID: UUID().uuidString)
        let store = LocalStore(account: account, storeDirectoryURL: directory)
        return BrowserState(windowId: 812001, localStore: store, profileId: "Default", isIncognito: incognito)
    }

    private func tab(_ url: URL, id: Int = 812002) -> Tab {
        Tab(guid: id, url: url.absoluteString, isActive: false, index: 0, windowId: 812001)
    }

    func testPinnedMailWinsOverOpenMailForBothURLs() {
        for url in [MistAppRoute.current.url(.mail), MistAppRoute.current.legacyURL(.mail)!] {
            let state = state(), pin = tab(url), open = tab(MistAppRoute.current.url(.mail), id: 812003)
            pin.pinnedUrl = url.absoluteString
            state.pinnedTabs = [pin]; state.tabs = [open]
            guard case .focusPinned(let found) = state.appOpenAction(.mail) else { return XCTFail("Expected pinned Mail") }
            XCTAssertTrue(found === pin)
        }
    }

    func testOpenMailWinsAndClosesOnlyReplacement() {
        let state = state(), mail = tab(MistAppRoute.current.legacyURL(.mail)!), blank = tab(URL(string: "chrome://newtab")!, id: 812003)
        state.tabs = [mail, blank]
        guard case .focusOpen(let found, let closing) = state.appOpenAction(.mail, replacing: blank) else { return XCTFail("Expected open Mail") }
        XCTAssertTrue(found === mail); XCTAssertTrue(closing === blank)
        guard case .focusOpen(_, let same) = state.appOpenAction(.mail, replacing: mail) else { return XCTFail("Expected open Mail") }
        XCTAssertNil(same)
    }

    func testBlankFocusedNewTabIsNavigated() {
        let state = state(), blank = tab(URL(string: "chrome://newtab")!)
        state.tabs = [blank]; state.focusingTab = blank
        guard case .navigate(let found, let url) = state.appOpenAction(.mail) else { return XCTFail("Expected NTP reuse") }
        XCTAssertTrue(found === blank); XCTAssertEqual(url, MistAppRoute.current.url(.mail))
    }

    func testOrdinaryTabCreatesAppHomes() {
        let state = state(), page = tab(URL(string: "https://example.com")!)
        state.tabs = [page]; state.focusingTab = page
        guard case .create(let url) = state.appOpenAction(.mail) else { return XCTFail("Expected new Mail tab") }
        XCTAssertEqual(url, MistAppRoute.current.url(.mail))
        guard case .create(let drifterURL) = state.appOpenAction(.drifter) else { return XCTFail("Expected a new Drifter home") }
        XCTAssertEqual(drifterURL, MistAppRoute.current.url(.drifter))
        guard case .create(let clipboardURL) = state.appOpenAction(.clipboard) else { return XCTFail("Expected new Clipboard tab") }
        XCTAssertEqual(clipboardURL, MistAppRoute.current.url(.clipboard))
    }

    func testClipboardFocusesOpenTabAndReusesBlankNewTab() {
        let state = state(), clipboard = tab(MistAppRoute.current.url(.clipboard))
        let blank = tab(URL(string: "chrome://newtab")!, id: 812003)
        state.tabs = [clipboard, blank]; state.focusingTab = blank
        guard case .focusOpen(let found, _) = state.appOpenAction(.clipboard) else { return XCTFail("Expected open Clipboard") }
        XCTAssertTrue(found === clipboard)
        state.tabs = [blank]
        guard case .navigate(let reused, let url) = state.appOpenAction(.clipboard) else { return XCTFail("Expected NTP reuse") }
        XCTAssertTrue(reused === blank)
        XCTAssertEqual(url, MistAppRoute.current.url(.clipboard))
    }

    func testClipboardTitleIconAndAddressDisplay() throws {
        let tab = tab(MistAppRoute.current.url(.clipboard))
        tab.applyPageTitle("Chromium placeholder")
        XCTAssertEqual(tab.title, "Clipboard")
        XCTAssertEqual(tab.appAddress, MistAppAddress(app: .clipboard, instance: nil))
        let display = try XCTUnwrap(MistAppAddressDisplay.resolve(tab))
        XCTAssertEqual(display.name, "Clipboard"); XCTAssertNil(display.title)
        XCTAssertEqual(display.icon, MistAppIcon(asset: "clipboard-favicon", isTemplate: true))
        XCTAssertTrue(display.attributedString(primary: .labelColor, separator: .separatorColor).string.contains("Clipboard"))
        let model = WebContentAddressBarViewModel(browserState: nil, currentTab: tab)
        XCTAssertEqual(model.appDisplay, display)
    }

    func testIncognitoCannotOpenApps() {
        guard case .none = state(incognito: true).appOpenAction(.mail) else { return XCTFail("Incognito must refuse apps") }
        guard case .none = state(incognito: true).appOpenAction(.drifter) else { return XCTFail("Incognito must refuse Drifter") }
    }

    func testDrifterReusesBlankNewTab() {
        let state = state(), blank = tab(URL(string: "chrome://newtab")!)
        state.tabs = [blank]; state.focusingTab = blank
        guard case .navigate(let found, let url) = state.appOpenAction(.drifter) else { return XCTFail("Expected blank reuse") }
        XCTAssertTrue(found === blank)
        XCTAssertEqual(url, MistAppRoute.current.url(.drifter))
    }

    func testDrifterFocusesOnlyHomeAndPrefersPinnedHome() {
        let state = state(), home = tab(MistAppRoute.current.url(.drifter))
        let chat = tab(MistAppRoute.current.url(.drifter, instance: UUID()), id: 812003)
        state.tabs = [chat]; state.pinnedTabs = [chat]
        chat.pinnedUrl = chat.url
        guard case .create = state.appOpenAction(.drifter) else { return XCTFail("A pinned chat is not the home") }
        state.tabs = [chat, home]
        guard case .focusOpen(let open, _) = state.appOpenAction(.drifter) else { return XCTFail("Expected open home") }
        XCTAssertTrue(open === home)
        let pin = tab(MistAppRoute.current.url(.drifter), id: 812004)
        pin.pinnedUrl = pin.url
        state.pinnedTabs.append(pin)
        guard case .focusPinned(let pinned) = state.appOpenAction(.drifter) else { return XCTFail("Expected pinned home") }
        XCTAssertTrue(pinned === pin)
    }

    func testOpenNewDrifterChatRegistersEmptyChatAndNavigatesBlank() throws {
        let state = state()
        let wrapper = AgentChatNavigationSpy(urlString: "chrome://newtab/", title: "New Tab")
        let blank = Tab(guid: 812002, url: "chrome://newtab/", isActive: true, index: 0, webContentView: wrapper, windowId: state.windowId)
        state.tabs = [blank]; state.focusingTab = blank
        state.openNewDrifterChat()
        let url = try XCTUnwrap(wrapper.navigatedURLs.last)
        let address = try XCTUnwrap(MistApps.address(url))
        let id = try XCTUnwrap(address.chatId)
        let store = AgentChatStore.shared
        defer { store.closeIfTabIsGone(blank.guid) }
        XCTAssertEqual(url, store.route.canonicalURL(for: id).absoluteString)
        XCTAssertTrue(store.isEmpty(id))
        XCTAssertEqual(store.entry(for: id)?.tabId, blank.guid)
    }

    func testFindAndZoomDispatchToChatPage() throws {
        let state = state(), root = directories.last!
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in true })
        defer { store.terminate() }
        let chat = try store.createEmpty(tabId: 812002)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, browserState: state, dormant: true)
        defer { controller.discardDormant(); window.close() }
        let page = AgentChatViewController(store: store)
        page.show(chat.id)
        window.contentViewController = page
        // The composer joins the window only once the page's hosting view lays out.
        page.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(page.composer.editor.textView))
        for command in [CommandWrapper.IDC_FIND, .IDC_ZOOM_PLUS] {
            let item = NSMenuItem(); item.tag = command.rawValue
            XCTAssertTrue(CommandDispatcher.dispatchCommand(item, window: window))
        }
        XCTAssertGreaterThan(page.textScale, 1)
    }

    func testClearMovesPinnedChatURLAndPreservesItsNames() async throws {
        let state = state()
        // The shared store finds tabs through live windows only; this one routes to the state as that closure does.
        let store = AgentChatStore(route: .init(baseDirectory: directories.last!), tabExists: { $0 == 812002 },
            navigateTab: { [weak state] id, url in
                guard let state, let tab = state.tabs.first(where: { $0.guid == id }) else { return }
                state.navigateChatTab(tab, to: url)
            })
        defer { store.terminate() }
        let chat = try store.createEmpty(tabId: 812002)
        let originalURL = store.route.placeholderURL(for: chat.id)
        let context = try XCTUnwrap(state.localStore.getMainContext())
        let profile = ProfileModel(profileId: state.profileId)
        let model = TabDataModel(title: "Captured title", guid: UUID().uuidString, index: 0,
            url: originalURL, favicon: nil, createdDate: Date(), updatedDate: Date())
        model.dataType = .pinnedTab; model.overrideTitle = "My chat"
        context.insert(profile); context.insert(model); model.profile = profile
        try context.save()
        let pin = Tab(with: model)
        let wrapper = AgentChatNavigationSpy(urlString: originalURL.absoluteString, title: "Captured title")
        let live = Tab(guid: 812002, url: originalURL.absoluteString, isActive: true, index: 0, webContentView: wrapper, windowId: state.windowId)
        live.guidInLocalDB = model.guid
        state.pinnedTabs = [pin]; state.tabs = [live]; state.focusingTab = live
        defer { state.tabs = [] }
        try store.clear(chat.id)
        let next = try XCTUnwrap(wrapper.navigatedURLs.last)
        let replacement = try XCTUnwrap(store.route.conversationId(for: next))
        XCTAssertNotEqual(replacement, chat.id)
        XCTAssertEqual(pin.pinnedUrl, next)
        XCTAssertEqual(live.pinnedUrl, next)
        await state.localStore.performBackgroundWriteAndWait { _ in }
        XCTAssertEqual(state.localStore.getTab(by: model.guid)?.url.absoluteString, next)
        XCTAssertEqual(state.localStore.getTab(by: model.guid)?.title, "Captured title")
        XCTAssertEqual(state.localStore.getTab(by: model.guid)?.overrideTitle, "My chat")
    }

    func testDrifterPresentationUsesProvider() throws {
        let id = UUID(), url = MistAppRoute.current.url(.drifter, instance: UUID())
        let store = AgentChatStore.shared
        let chat = try store.createEmpty(config: .init(engine: .codex), tabId: -812002, id: id)
        defer {
            store.closeIfTabIsGone(-812002)
            try? FileManager.default.removeItem(at: store.route.chatDirectory(for: id))
            try? FileManager.default.removeItem(at: store.route.placeholderURL(for: id))
        }
        let page = tab(store.route.placeholderURL(for: chat.id))
        page.applyPageTitle("Chromium placeholder")
        XCTAssertEqual(page.title, MistAppID.drifter.name)
        XCTAssertEqual(page.appAddress?.chatId, id)
        let display = try XCTUnwrap(MistAppAddressDisplay.resolve(page))
        XCTAssertEqual(display.name, MistAppID.drifter.name)
        XCTAssertEqual(display.title, chat.title)
        XCTAssertEqual(display.icon.asset, DrifterApp.logo)
        let model = TabViewModel(); model.configure(with: page, in: state())
        XCTAssertEqual(model.appIcon?.asset, AgentChatIcon.openai.rawValue)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Drifter")
    }

    func testGeminiPlaceholderAndTabUseGeminiIcon() throws {
        let id = UUID(), store = AgentChatStore.shared
        let chat = try store.createEmpty(config: .init(engine: .gemini, model: "gemini-3.8-flash"), tabId: -812003, id: id)
        let url = store.route.placeholderURL(for: chat.id)
        defer { store.closeIfTabIsGone(-812003) }
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("name=\"mist-agent\" content=\"drifter gemini\""))
        XCTAssertEqual(store.route.storedAgent(for: id), .gemini)
        XCTAssertFalse(AgentChatIcon.gemini.isTemplate)
        let model = TabViewModel()
        model.configure(with: tab(url), in: state())
        XCTAssertEqual(model.appIcon?.asset, AgentChatIcon.gemini.rawValue)
    }

    func testMailTitleIconAndAddressDisplay() throws {
        for url in [MistAppRoute.current.url(.mail), MistAppRoute.current.legacyURL(.mail)!] {
            let tab = tab(url)
            tab.applyPageTitle("Chromium placeholder")
            XCTAssertEqual(tab.title, "Mail")
            XCTAssertEqual(tab.appAddress, MistAppAddress(app: .mail, instance: nil))
            let display = try XCTUnwrap(MistAppAddressDisplay.resolve(tab))
            XCTAssertEqual(display.name, "Mail"); XCTAssertNil(display.title)
            XCTAssertEqual(display.icon, MistAppIcon(asset: "mail-favicon", isTemplate: true))
            XCTAssertTrue(display.attributedString(primary: .labelColor, separator: .separatorColor).string.contains("Mail"))
            let model = WebContentAddressBarViewModel(browserState: nil, currentTab: tab)
            XCTAssertEqual(model.appDisplay, display)
        }
    }

    func testMailURLInIncognitoUsesChromiumPresentation() throws {
        let state = state(incognito: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId, browserType: .incognito,
            profileId: state.profileId, spaceId: state.spaceId, browserState: state, dormant: true)
        defer { controller.discardDormant(); window.close() }
        let tab = tab(MistAppRoute.current.url(.mail))
        tab.applyPageTitle("Chromium file title")
        XCTAssertNil(tab.appAddress)
        XCTAssertEqual(tab.title, "Chromium file title")
        XCTAssertNil(MistAppAddressDisplay.resolve(tab))
        XCTAssertNil(WebContentAddressBarViewModel(browserState: state, currentTab: tab).appDisplay)
        let favicon = TabViewModel(); favicon.configure(with: tab, in: state)
        XCTAssertNil(favicon.appIcon)
    }
}
