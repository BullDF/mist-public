import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistChatPanelTests: XCTestCase {
    func testPanelTabSwitchUsesFocusedTabAndPrefersItsMountedChat() throws {
        let store = AgentChatStore(route: .init(baseDirectory: directory),
            tabExists: { [7, 42, 43].contains($0) },
            browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        func create(_ tabId: Int) throws -> UUID {
            try store.create(request: .init(prompt: "Chat", attachments: [], config: .init(folder: directory), windowId: 1),
                             tabId: tabId).id
        }
        let mounted = try create(42)
        let unmounted = try create(43)
        XCTAssertTrue(store.mount(mounted, to: 7))
        XCTAssertEqual(MistChatPanelViewController.panelTabSwitch(focusedTabId: 42, focusedChatId: mounted,
            panelOpen: false, store: store), .showInPanel(chatId: mounted))
        XCTAssertEqual(MistChatPanelViewController.panelTabSwitch(focusedTabId: 7, focusedChatId: nil,
            panelOpen: true, store: store), .openAsTab(hostTabId: 7))
        XCTAssertNil(MistChatPanelViewController.panelTabSwitch(focusedTabId: 7, focusedChatId: nil,
            panelOpen: false, store: store))
        XCTAssertEqual(MistChatPanelViewController.panelTabSwitch(focusedTabId: 8, focusedChatId: nil,
            panelOpen: true, store: store), .openAsTab(hostTabId: 8), "An open panel's new-chat screen")
        XCTAssertEqual(MistChatPanelViewController.panelTabSwitch(focusedTabId: 43, focusedChatId: unmounted,
            panelOpen: false, store: store), .mountToTab(chatTabId: 43))
        XCTAssertTrue(store.mount(unmounted, to: 42))
        XCTAssertEqual(MistChatPanelViewController.panelTabSwitch(focusedTabId: 42, focusedChatId: mounted,
            panelOpen: true, store: store), .showInPanel(chatId: mounted))
        XCTAssertNil(MistChatPanelViewController.panelTabSwitch(focusedTabId: nil, focusedChatId: nil,
            panelOpen: false, store: store))
    }

    func testCloseChatTargetsTheFocusedTabsOpenPanelChat() throws {
        let state = state()
        let tab = host(in: state)
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { $0 == tab.guid },
            browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        tab.aiChatCollapsed = false
        XCTAssertNil(MistChatPanelViewController.closeChatHost(in: state, store: store), "The new-chat screen")
        let chat = try store.create(request: .init(prompt: "Chat", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 72)
        store.setPanelChat(chat.id, for: tab.guid)
        XCTAssertEqual(MistChatPanelViewController.closeChatHost(in: state, store: store), tab.guid)
        tab.aiChatCollapsed = true
        XCTAssertNil(MistChatPanelViewController.closeChatHost(in: state, store: store), "A closed panel")
        tab.aiChatCollapsed = false
        state.focusingTab = nil
        XCTAssertNil(MistChatPanelViewController.closeChatHost(in: state, store: store))
    }

    func testClearRebindsPanelAndInsertsHostMentionIntoFreshComposer() async throws {
        let state = state()
        let tab = host(in: state)
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { $0 == tab.guid },
            browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        let chat = try store.create(request: .init(prompt: "Old chat", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 72)
        chat.update(items: [.init(id: "user", kind: .userMessage(text: "Old chat", images: []))], status: .idle)
        store.setPanelChat(chat.id, for: tab.guid)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        panel.composer.editor.text = "/clear"
        panel.composer.send()
        try await Task.sleep(nanoseconds: 20_000_000)
        let freshId = try XCTUnwrap(store.panelChat(for: tab.guid))
        XCTAssertNotEqual(freshId, chat.id)
        XCTAssertEqual(panel.chatController?.conversation?.id, freshId)
        XCTAssertEqual(panel.chatController?.conversation?.status, .dormant)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])
        XCTAssertEqual(panel.composer.editor.text, "@Example ")
        XCTAssertEqual(store.entry(for: freshId)?.tabId, 72)
    }

    func testClearOnTheNewChatScreenStartsNothing() throws {
        let state = state()
        let tab = host(in: state)
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { $0 == tab.guid },
            browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        panel.composer.editor.text = "/clear"
        panel.composer.send()
        XCTAssertNil(store.panelChat(for: tab.guid))
        XCTAssertTrue(store.agentChats().isEmpty)
        XCTAssertNil(panel.chatController)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid], "Back to the new-chat screen's host mention")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: store.route.directory.path)) ?? []).isEmpty)
    }

    func testLastActiveWebTabFollowsFocusAndChecksCurrentURLs() {
        let state = state()
        let first = host(in: state)
        let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1)
        let ntp = Tab(guid: 73, url: "chrome://newtab", isActive: false, index: 2)
        let chat = Tab(guid: 74, url: AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, isActive: false, index: 3)
        let empty = Tab(guid: 75, url: "", isActive: false, index: 4)
        state.tabs += [second, ntp, chat, empty]
        XCTAssertTrue(state.lastActiveWebTab === first)
        state.focusingTab = second
        XCTAssertTrue(state.lastActiveWebTab === second)
        state.focusingTab = ntp
        state.focusingTab = chat
        state.focusingTab = empty
        XCTAssertTrue(state.lastActiveWebTab === second)
        second.url = "chrome://newtab"
        XCTAssertTrue(state.lastActiveWebTab === first)
        state.tabs.removeAll { $0.guid == first.guid }
        XCTAssertNil(state.lastActiveWebTab)
    }

    func testLastActiveWebTabIsNilWhenOnlyChatWasFocused() {
        let state = state()
        let chat = Tab(guid: 71, url: AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, isActive: true, index: 0)
        state.tabs = [chat]
        state.focusingTab = chat
        XCTAssertNil(state.lastActiveWebTab)
    }

    func testPanelCollapseMirrorsBothDirectionsAcrossSplitPartners() {
        let state = state()
        let first = host(in: state)
        let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1)
        let unrelated = Tab(guid: 73, url: "https://third.test", isActive: false, index: 2)
        state.tabs += [second, unrelated]
        state.splits = [.init(id: "split", primaryTabId: first.guid,
                             secondaryTabId: second.guid, layout: .vertical, ratio: 0.5)]

        state.setAIChatCollapsed(for: first, collapsed: false)
        XCTAssertFalse(first.aiChatCollapsed)
        XCTAssertFalse(second.aiChatCollapsed)
        XCTAssertTrue(unrelated.aiChatCollapsed)

        state.setAIChatCollapsed(for: second, collapsed: true)
        XCTAssertTrue(first.aiChatCollapsed)
        XCTAssertTrue(second.aiChatCollapsed)
        XCTAssertTrue(unrelated.aiChatCollapsed)
    }

    func testCreatingSplitKeepsEitherPanesExpandedPanelOpen() {
        for expandedId in [71, 72] {
            let state = state()
            let first = host(in: state)
            let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1)
            state.tabs.append(second)
            state.tabs.first { $0.guid == expandedId }?.toggleAIChat(false)

            state.handleSplitCreated(splitId: "split", primaryTabId: first.guid,
                                     secondaryTabId: second.guid, layout: .vertical, ratio: 0.5)

            XCTAssertFalse(first.aiChatCollapsed)
            XCTAssertFalse(second.aiChatCollapsed)
        }
    }

    func testLinkStatusAcceptsOnlyDisplayedTabsAndClearsWhenTheDisplayChanges() {
        let state = state()
        let first = host(in: state)
        let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1)
        let preview = Tab(guid: 73, url: "https://preview.test", isActive: false, index: 2)
        state.tabs += [second, preview]
        state.updateTargetURL("https://link.test/one", from: first.guid)
        XCTAssertEqual(state.targetURL, "https://link.test/one")
        state.updateTargetURL("https://leaked.test", from: preview.guid)
        state.updateTargetURL("", from: preview.guid)
        XCTAssertEqual(state.targetURL, "https://link.test/one")
        state.splits = [.init(id: "split", primaryTabId: first.guid, secondaryTabId: second.guid, layout: .vertical, ratio: 0.5)]
        XCTAssertEqual(state.targetURL, "")
        state.updateTargetURL("https://split-link.test", from: second.guid)
        XCTAssertEqual(state.targetURL, "https://split-link.test")
        state.splits = []
        XCTAssertEqual(state.targetURL, "")
        state.updateTargetURL("https://link.test", from: first.guid)
        state.focusingTab = second
        XCTAssertEqual(state.targetURL, "")
        state.updateTargetURL("https://old-tab.test", from: first.guid)
        XCTAssertEqual(state.targetURL, "")
        state.updateTargetURL("chrome://settings", from: second.guid)
        XCTAssertEqual(state.targetURL, "")
    }

    func testLaunchMenusAlignTheirCheckedItemOrFirstEnabledItem() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let first = NSMenuItem(title: "First", action: nil, keyEquivalent: "")
        let checked = NSMenuItem(title: "Checked", action: nil, keyEquivalent: "")
        [heading, .separator(), first, checked].forEach(menu.addItem)
        XCTAssertTrue(menu.mistPositioningItem === first)
        checked.state = .on
        XCTAssertTrue(menu.mistPositioningItem === checked)
    }

    private var directory: URL!
    private var localStores: [LocalStore] = []
    private var chatStores: [AgentChatStore] = []
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = makeTestDefaults().defaults
    }

    override func tearDown() async throws {
        chatStores.forEach { $0.terminate() }
        chatStores.removeAll()
        for store in localStores { try await store.closeForAccountDirectoryRemoval() }
        localStores.removeAll()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func state(incognito: Bool = false, agentSpace: Bool = false) -> PanelBrowserState {
        let local = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory.appendingPathComponent(UUID().uuidString))
        localStores.append(local)
        return PanelBrowserState(windowId: 771, localStore: local, profileId: "Default",
                                 isIncognito: incognito, isAgentSpace: agentSpace)
    }

    private func store(onLaunch: ((DrifterLaunchRequest, AgentConversation) -> Void)? = nil,
                       tabExists: @escaping (Int) -> Bool = { _ in false }, windowId: @escaping (Int) -> Int? = { _ in nil },
                       openChatTab: @escaping (UUID, Int) -> Void = { _, _ in },
                       closeChatTab: @escaping (Int) -> Void = { _ in }, collapsePanel: @escaping (Int) -> Void = { _ in },
                       chatTabs: @escaping () -> [(chatId: UUID, tabId: Int)] = { [] }) -> AgentChatStore {
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: tabExists, windowId: windowId,
            openChatTab: openChatTab, closeChatTab: closeChatTab, collapsePanel: collapsePanel, chatTabs: chatTabs,
            browserSessionFactory: { request, conversation, _ in
                onLaunch?(request, conversation)
                return NSObject()
            })
        chatStores.append(store)
        return store
    }

    private func host(in state: BrowserState, id: Int = 71) -> Tab {
        let tab = Tab(guid: id, url: "https://example.com", isActive: true, index: 0, title: "Example")
        tab.aiChatEnabled = Tab.supportsAIChat(urlString: tab.url)
        state.tabs = [tab]
        state.focusingTab = tab
        state.updateNormalTabs()
        return tab
    }

    func testMailHostGetsPanelButNoHostMention() {
        let state = state()
        let tab = Tab(guid: 72, url: MistAppRoute.current.url(.mail).absoluteString, isActive: true, index: 0, title: "Mail")
        tab.aiChatEnabled = Tab.supportsAIChat(urlString: tab.url)
        state.tabs = [tab]; state.focusingTab = tab; state.updateNormalTabs()
        XCTAssertTrue(state.canShowChatPanel(for: tab))
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store())
        panel.setExpanded(true)
        XCTAssertTrue(panel.composer.editor.mentions.isEmpty)
        XCTAssertEqual(panel.composer.editor.text, "")
    }

    func testAutoMentionIsAtomicAndOnlyInsertedIntoEmptyEditorOnExpand() {
        let state = state()
        let tab = host(in: state)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store())
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])
        XCTAssertEqual(panel.composer.editor.text, "@Example ")
        XCTAssertEqual(panel.composer.editor.mentionBanner.mentions.map(\.tabId), [tab.guid])
        XCTAssertFalse(panel.composer.editor.mentionBanner.isHidden)
        let original = panel.composer.editor.text
        panel.setExpanded(false)
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.editor.text, original)
        panel.composer.editor.text = "A draft"
        panel.setExpanded(false)
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.editor.text, "A draft")
        XCTAssertTrue(panel.composer.editor.mentions.isEmpty)
        panel.composer.editor.text = ""
        panel.setExpanded(false)
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])
        guard let token = panel.composer.editor.mentions.first else { return XCTFail("Mention lost after a cleared draft") }
        XCTAssertEqual((panel.composer.editor.text as NSString).substring(with: token.range), token.tokenText)
    }

    func testStartedChatGetsNoHostMentionOnReopenTabSwitchOrMount() throws {
        let state = state()
        let tab = host(in: state)
        let other = Tab(guid: 72, url: "https://other.test", isActive: false, index: 1, title: "Other")
        state.tabs.append(other)
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { [tab.guid, other.guid].contains($0) },
            browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        func started(_ prompt: String, tabId: Int) throws -> AgentConversation {
            let chat = try store.create(request: DrifterLaunchRequest(prompt: prompt, config: .init(), windowId: 771),
                                        tabId: tabId)
            chat.update(items: [.init(id: "user", kind: .userMessage(text: prompt, images: []))], status: .idle)
            return chat
        }
        let chat = try started("Read", tabId: 73)
        store.setPanelChat(chat.id, for: tab.guid)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        XCTAssertTrue(panel.chatController?.conversation === chat)
        XCTAssertEqual(panel.composer.editor.text, "")
        panel.setExpanded(false)
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.editor.text, "", "Reopening a started chat's panel adds no mention")
        panel.updateAssociatedTab(other)
        XCTAssertNil(panel.chatController)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [other.guid], "A new chat still gets its tab's mention")
        panel.updateAssociatedTab(tab)
        XCTAssertTrue(panel.chatController?.conversation === chat)
        XCTAssertEqual(chat.draft, AgentComposerDraft(), "Switching back to a started chat adds no mention")
        let mounted = try started("Summarize", tabId: 74)
        XCTAssertTrue(store.mount(mounted.id, to: other.guid))
        panel.updateAssociatedTab(other)
        XCTAssertTrue(panel.chatController?.conversation === mounted)
        XCTAssertEqual(mounted.draft, AgentComposerDraft(), "Mounting a started chat adds no mention")
    }

    func testLaunchCreatesUnfocusedSidebarChatAndNewChatKeepsSessionAlive() async throws {
        let state = state()
        let tab = host(in: state)
        var request: DrifterLaunchRequest?
        var conversation: AgentConversation?
        var closes = 0
        let store = store(onLaunch: { launch, chat in
            request = launch
            conversation = chat
            chat.onClose = { closes += 1 }
        }, tabExists: { id in state.tabs.contains { $0.guid == id } })
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = panel
        panel.setExpanded(true)
        panel.setPresented(true)
        panel.composer.send()
        let chat = try XCTUnwrap(conversation)
        await Task.yield()
        // bindNextTab deliberately delivers on the main queue.
        try await Task.sleep(nanoseconds: 20_000_000)
        let chatTab = try XCTUnwrap(state.tabs.first { $0 !== tab })
        XCTAssertEqual(state.created.map(\.focused), [false])
        XCTAssertTrue(state.focusingTab === tab)
        XCTAssertFalse(chatTab.isActive)
        XCTAssertEqual(store.entry(for: chat.id)?.tabId, chatTab.guid)
        XCTAssertEqual(store.panelChat(for: tab.guid), chat.id)
        XCTAssertTrue(panel.chatController?.conversation === chat)
        XCTAssertNil(panel.chatController?.previewStack)
        XCTAssertEqual(request?.mentions.map(\.tabId), [tab.guid])
        XCTAssertEqual(request?.mentions.first?.closed, false)
        XCTAssertTrue(panel.composer.editor.mentions.isEmpty, "Launching does not attach the host to later replies")
        XCTAssertTrue(window.firstResponder === panel.composer.editor.textView, "Launching hands focus to the new chat composer")
        XCTAssertTrue(MistSidebarAgentSections.isMember(chatTab, splits: [], isIncognito: false, route: store.route))
        XCTAssertEqual(MistSidebarAgentSections.members(in: state.tabs, splits: [], isIncognito: false,
            route: store.route).map(\.guid), [chatTab.guid])
        panel.newChat()
        let fresh = try XCTUnwrap(store.panelChat(for: tab.guid))
        XCTAssertNotEqual(fresh, chat.id)
        XCTAssertEqual(panel.chatController?.conversation?.id, fresh)
        XCTAssertTrue(store.conversation(for: chat.id) === chat)
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])
        XCTAssertTrue(state.tabs.contains { $0 === chatTab })
    }


    func testClosingChatReturnsPanelToLaunchStateWhileClosingHostKeepsChat() async throws {
        let state = state()
        let tab = host(in: state)
        let store = store()
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 771),
                                    tabId: 72)
        store.setPanelChat(chat.id, for: tab.guid)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        XCTAssertTrue(panel.chatController?.conversation === chat)
        store.closeIfTabIsGone(72)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(store.panelChat(for: tab.guid))
        XCTAssertNil(panel.chatController)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])
        let next = try store.create(request: DrifterLaunchRequest(prompt: "Next", config: .init(), windowId: 771),
                                    tabId: 73)
        store.setPanelChat(next.id, for: tab.guid)
        store.tabDidClose(tab.guid)
        XCTAssertNil(store.panelChat(for: tab.guid))
        XCTAssertNotNil(store.conversation(for: next.id))
    }

    func testPanelHistorySelectionAndClosingShownChatRestoreTheNewestRemainingChat() async throws {
        let state = state()
        let host = host(in: state)
        let store = store(tabExists: { $0 == host.guid })
        let first = try store.create(request: DrifterLaunchRequest(prompt: "First", config: .init(), windowId: 771), tabId: 72)
        let second = try store.create(request: DrifterLaunchRequest(prompt: "Second", config: .init(), windowId: 771), tabId: 73)
        store.setPanelChat(first.id, for: host.guid)
        store.setPanelChat(second.id, for: host.guid)
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)
        panel.showChat(first.id)
        XCTAssertTrue(panel.chatController?.conversation === first)
        store.closeIfTabIsGone(72)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(panel.chatController?.conversation === second)
        panel.newChat()
        let fresh = try XCTUnwrap(panel.chatController?.conversation)
        XCTAssertTrue(fresh.isNew)
        XCTAssertEqual(store.panelChatHistory(for: host.guid).map(\.id), [fresh.id, second.id])
        panel.showChat(second.id)
        XCTAssertTrue(panel.chatController?.conversation === second)
        XCTAssertNil(store.conversation(for: fresh.id), "An empty chat goes once no panel shows it")
        XCTAssertEqual(store.panelChatHistory(for: host.guid).map(\.id), [second.id])
    }

    /// A store whose `openChatTab` and `closeChatTab` open a background tab in `state` and close one, like the shared
    /// store's.
    private func tabOpeningStore(_ state: PanelBrowserState, onLaunch: ((DrifterLaunchRequest, AgentConversation) -> Void)? = nil,
                                 deferTabCreation: Bool = false, collapsePanel: @escaping (Int) -> Void = { _ in }) -> AgentChatStore {
        let route = AgentChatRoute(baseDirectory: directory)
        var opener: AgentChatStore?
        let store = store(onLaunch: onLaunch, tabExists: { id in state.tabs.contains { $0.guid == id } }, windowId: { _ in 771 },
                          openChatTab: { id, _ in
                              guard let opener else { return }
                              let url = route.placeholderURL(for: id).absoluteString
                              opener.bindNextTab(id, in: state, url: url)
                              if !deferTabCreation { state.createTab(url, focusAfterCreate: false) }
                          }, closeChatTab: { id in state.tabs.removeAll { $0.guid == id } }, collapsePanel: collapsePanel,
                          chatTabs: {
                              state.tabs.compactMap { tab in
                                  route.conversationId(for: tab.url).map { (chatId: $0, tabId: tab.guid) }
                              }
                          })
        opener = store
        return store
    }

    private func recordExists(_ id: UUID, in store: AgentChatStore) -> Bool {
        FileManager.default.fileExists(atPath: store.route.recordURL(for: id).path)
    }

    func testCloseChatClosesTabAndPanelAndKeepsRecord() throws {
        let state = state()
        let host = host(in: state)
        var collapsed: [Int] = []
        let store = tabOpeningStore(state, collapsePanel: { collapsed.append($0) })
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 771), tabId: 901)
        chat.update(items: [.init(id: "user", kind: .userMessage(text: "Read", images: []))], status: .running)
        var closes = 0
        chat.onClose = { closes += 1 }
        state.createTab(store.route.placeholderURL(for: chat.id).absoluteString, focusAfterCreate: false)
        store.setPanelChat(chat.id, for: host.guid)
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)

        panel.closeChat()

        XCTAssertEqual(state.tabs.map(\.guid), [host.guid])
        XCTAssertNil(store.conversation(for: chat.id))
        XCTAssertTrue(recordExists(chat.id, in: store))
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(collapsed, [host.guid])
        XCTAssertNil(store.panelChat(for: host.guid))
    }

    func testCloseChatClosesDuplicateTabs() throws {
        let state = state()
        let host = host(in: state)
        var collapsed: [Int] = []
        let store = tabOpeningStore(state, collapsePanel: { collapsed.append($0) })
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 771), tabId: 901)
        chat.update(items: [.init(id: "user", kind: .userMessage(text: "Read", images: []))], status: .idle)
        let url = store.route.placeholderURL(for: chat.id).absoluteString
        state.createTab(url, focusAfterCreate: false)
        state.createTab(url, focusAfterCreate: false)
        store.setPanelChat(chat.id, for: host.guid)
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)

        panel.closeChat()

        XCTAssertEqual(state.tabs.map(\.guid), [host.guid])
        XCTAssertNil(store.conversation(for: chat.id))
        XCTAssertTrue(recordExists(chat.id, in: store))
        XCTAssertEqual(collapsed, [host.guid])
        XCTAssertNil(store.panelChat(for: host.guid))
    }

    func testCloseChatDeletesEmptyChatAfterTabArrives() async throws {
        let state = state()
        let host = host(in: state)
        var collapsed: [Int] = []
        let store = tabOpeningStore(state, collapsePanel: { collapsed.append($0) })
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)
        panel.newChat()
        let chat = try XCTUnwrap(panel.chatController?.conversation)
        try await Task.sleep(nanoseconds: 20_000_000)
        let chatTab = try XCTUnwrap(state.tabs.first { $0 !== host })
        XCTAssertEqual(store.entry(for: chat.id)?.tabId, chatTab.guid)
        XCTAssertTrue(recordExists(chat.id, in: store))

        panel.closeChat()

        XCTAssertEqual(state.tabs.map(\.guid), [host.guid])
        XCTAssertEqual(collapsed, [host.guid])
        XCTAssertFalse(recordExists(chat.id, in: store))
    }

    func testCloseChatDeletesEmptyChatBeforeTabArrives() async throws {
        let state = state()
        let host = host(in: state)
        var collapsed: [Int] = []
        let store = tabOpeningStore(state, deferTabCreation: true, collapsePanel: { collapsed.append($0) })
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)
        panel.newChat()
        let chat = try XCTUnwrap(panel.chatController?.conversation)
        let url = store.route.placeholderURL(for: chat.id)
        XCTAssertTrue(store.isOpeningTab(for: chat.id))
        XCTAssertEqual(state.tabs.map(\.guid), [host.guid])

        panel.closeChat()

        XCTAssertEqual(collapsed, [host.guid])
        XCTAssertFalse(recordExists(chat.id, in: store))
        state.createTab(url.absoluteString, focusAfterCreate: false)
        let chatTab = try XCTUnwrap(state.tabs.first { $0 !== host })
        XCTAssertFalse(store.restoreIfNeeded(chat.id, tabId: chatTab.guid))
        XCTAssertFalse(store.recreate(chat.id, tabId: chatTab.guid, at: url))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.tabs.map(\.guid), [host.guid])
        XCTAssertFalse(store.isOpeningTab(for: chat.id))
        XCTAssertNil(store.conversation(for: chat.id))
        XCTAssertFalse(recordExists(chat.id, in: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCloseChatKeepsEarlierPanelHistoryAndCollapsesPanel() throws {
        let state = state()
        let host = host(in: state)
        var collapsed: [Int] = []
        let store = tabOpeningStore(state, collapsePanel: { collapsed.append($0) })
        let first = try store.create(request: DrifterLaunchRequest(prompt: "First", config: .init(), windowId: 771), tabId: 901)
        state.createTab(store.route.placeholderURL(for: first.id).absoluteString, focusAfterCreate: false)
        store.setPanelChat(first.id, for: host.guid)
        let panel = MistChatPanelViewController(with: state, tab: host, store: store)
        panel.setExpanded(true)
        panel.newChat()
        let second = try XCTUnwrap(panel.chatController?.conversation)

        panel.closeChat()

        XCTAssertEqual(store.panelChat(for: host.guid), first.id)
        XCTAssertEqual(store.panelChatHistory(for: host.guid).map(\.id), [first.id])
        XCTAssertNil(store.conversation(for: second.id))
        XCTAssertEqual(collapsed, [host.guid])
    }

    func testNewChatOpensAnEmptyChatInItsOwnBackgroundTab() async throws {
        let state = state()
        let tab = host(in: state)
        var requests: [DrifterLaunchRequest] = []
        let store = tabOpeningStore(state, onLaunch: { request, _ in requests.append(request) })
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        panel.launchComposer.applyLaunchDraft(AgentComposerDraft(text: "Summarize this"))
        panel.newChat()
        let first = try XCTUnwrap(panel.chatController?.conversation)
        XCTAssertEqual(store.panelChat(for: tab.guid), first.id)
        XCTAssertTrue(store.isEmpty(first.id))
        XCTAssertTrue(store.agentChats().contains(first.id), "Other chats can message it")
        XCTAssertTrue(recordExists(first.id, in: store))
        XCTAssertEqual(panel.composer.editor.text, "Summarize this", "The new-chat screen's draft moves into the chat")
        XCTAssertEqual(panel.launchComposer.editor.text, "")
        XCTAssertEqual(state.created.map(\.focused), [false])
        // bindNextTab deliberately delivers on the main queue.
        try await Task.sleep(nanoseconds: 20_000_000)
        let firstTab = try XCTUnwrap(state.tabs.last)
        XCTAssertEqual(store.entry(for: first.id)?.tabId, firstTab.guid)
        XCTAssertTrue(state.focusingTab === tab)

        panel.newChat()
        let second = try XCTUnwrap(panel.chatController?.conversation)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(store.conversation(for: first.id), "The next New Chat closes the empty one")
        XCTAssertFalse(recordExists(first.id, in: store))
        XCTAssertFalse(state.tabs.contains { $0 === firstTab }, "Its tab closes too")
        try await Task.sleep(nanoseconds: 20_000_000)
        let secondTab = try XCTUnwrap(state.tabs.last)
        XCTAssertEqual(store.entry(for: second.id)?.tabId, secondTab.guid)
        XCTAssertEqual(panel.composer.editor.mentions.map(\.tabId), [tab.guid])

        panel.composer.send()
        XCTAssertEqual(requests.map(\.windowId), [771])
        XCTAssertEqual(requests.first?.mentions.map(\.tabId), [tab.guid])
        XCTAssertEqual(state.created.count, 2, "Its launch opens no other tab")
        panel.newChat()
        XCTAssertNotNil(store.conversation(for: second.id), "A chat with a message stays")
        XCTAssertTrue(state.tabs.contains { $0 === secondTab })
    }

    func testOpenAsTabOnTheNewChatScreenStartsANewChatInItsOwnTab() async throws {
        let state = state()
        let tab = host(in: state)
        let store = tabOpeningStore(state)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        panel.launchComposer.applyLaunchDraft(AgentComposerDraft(text: "Summarize this"))
        panel.openAsTab()
        let chat = try XCTUnwrap(panel.chatController?.conversation)
        XCTAssertEqual(panel.composer.editor.text, "Summarize this")
        XCTAssertTrue(store.isOpeningTab(for: chat.id))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(state.created.count, 1, "It waits for New Chat's tab instead of opening another")
        XCTAssertEqual(store.entry(for: chat.id)?.tabId, state.tabs.last?.guid)
    }

    func testPanelAndPageShareConversationAndOnlyPageCreatesPreview() throws {
        let store = store()
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 771),
                                    tabId: 72)
        let panel = AgentChatViewController(store: store, presentation: .panel)
        let page = AgentChatViewController(store: store)
        panel.show(chat.id)
        page.show(chat.id)
        XCTAssertTrue(panel.conversation === page.conversation)
        XCTAssertNil(panel.previewStack)
        XCTAssertNotNil(page.previewStack)
        var messages: [String] = []
        var stops = 0
        chat.onSend = { text, _, _ in messages.append(text) }
        chat.onStop = { stops += 1 }
        chat.update(items: [], status: .idle)
        panel.composer.editor.text = "From panel"
        panel.composer.send()
        page.composer.editor.text = "From page"
        page.composer.send()
        XCTAssertEqual(messages, ["From panel", "From page"])
        chat.update(items: [], status: .running)
        panel.composer.stopButton.performClick(nil)
        page.composer.stopButton.performClick(nil)
        XCTAssertEqual(stops, 2)
        XCTAssertNil(panel.previewStack, "Working in another page never creates a panel preview")
    }

    func testPanelAndPageShareHostMentionAndDraft() throws {
        let state = state()
        let tab = host(in: state)
        let store = store()
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: .init(), windowId: 771),
                                    tabId: 72)
        chat.update(items: [], status: .dormant)
        let page = AgentChatViewController(store: store)
        page.show(chat.id)
        store.setPanelChat(chat.id, for: tab.guid)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        XCTAssertEqual(page.composer.editor.mentions.map(\.tabId), [tab.guid])
        XCTAssertEqual(page.composer.editor.text, "@Example ")
        // A page shown after the mention was drafted gets the styled token too.
        let later = AgentChatViewController(store: store)
        later.show(chat.id)
        XCTAssertEqual(later.composer.editor.mentions.map(\.tabId), [tab.guid])
        page.composer.editor.text = "From page"
        XCTAssertEqual(panel.composer.editor.text, "From page")
    }

    func testLaunchComposerUsesSavedDefaultsAndAcceptsTextOrImages() throws {
        let saved = DrifterLaunchSettings(defaults: defaults)
        saved.save(.init(engine: .claude, model: "sonnet", effort: "high", confirmation: .ask))
        let composer = AgentChatComposer()
        var sent: [(String, Int)] = []
        composer.onLaunch = { text, images, _ in sent.append((text, images.count)); return true }
        composer.configureLaunch(saved: saved)
        XCTAssertTrue(composer.editor.textView.isEditable)
        XCTAssertFalse(composer.sendButton.isEnabled)
        let settings = try XCTUnwrap(composer.browserLaunchRow?.settings)
        XCTAssertEqual(settings.config, saved.config)
        XCTAssertEqual(settings.config.model, "sonnet")
        // A pick applies to the chat it launches; only Settings ▸ Drifter changes the defaults.
        settings.selectConfirmation(.skip)
        settings.selectEffort("low")
        XCTAssertEqual(saved.config.confirmation, .ask)
        XCTAssertEqual(saved.config.effort, "high")
        composer.editor.text = "Hello"
        XCTAssertTrue(composer.sendButton.isEnabled)
        composer.send()
        XCTAssertEqual(sent.first?.0, "Hello")
        XCTAssertEqual(composer.editor.text, "")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        XCTAssertTrue(composer.addAttachments(from: pasteboard))
        XCTAssertTrue(composer.sendButton.isEnabled)
        composer.send()
        XCTAssertEqual(sent.last?.0, "")
        XCTAssertEqual(sent.last?.1, 1)
        XCTAssertTrue(composer.attachments.isEmpty)
    }

    func testLaunchDefaultsReloadWhileVisibleAndOnReopenWithoutLosingDraft() async throws {
        let saved = DrifterLaunchSettings(defaults: defaults)
        let state = state()
        let tab = host(in: state)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store(), saved: saved)
        panel.setExpanded(true)
        panel.composer.editor.textView.insertText("Read this", replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = panel.composer.editor.text
        let mentions = panel.composer.editor.mentions
        let settings = try XCTUnwrap(panel.composer.browserLaunchRow?.settings)
        // The composer's own pick survives reopening until the defaults change.
        settings.selectEffort("high")
        panel.setExpanded(false)
        panel.setExpanded(true)
        XCTAssertEqual(settings.config.effort, "high")
        let next = DrifterConfig(engine: .codex, model: "gpt-6.1-terra", effort: "high", confirmation: .ask)
        saved.save(next)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(settings.config, next)
        XCTAssertEqual(panel.composer.editor.text, text)
        XCTAssertEqual(panel.composer.editor.mentions, mentions)
        panel.setExpanded(false)
        saved.save(.init(model: "sonnet", effort: "low"))
        panel.setExpanded(true)
        XCTAssertEqual(panel.composer.browserLaunchRow?.settings.config, saved.config)
        XCTAssertEqual(panel.composer.editor.text, text)
        XCTAssertEqual(panel.composer.editor.mentions, mentions)
    }

    func testRunningPanelSettingsDoNotSaveLaunchDefaults() async throws {
        let saved = DrifterLaunchSettings()
        let original = saved.config
        defer { saved.save(original) }
        let state = state()
        let tab = host(in: state)
        let store = store()
        let chat = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: original, windowId: 771),
                                    tabId: 72)
        store.setPanelChat(chat.id, for: tab.guid)
        let panel = MistChatPanelViewController(with: state, tab: tab, store: store)
        panel.setExpanded(true)
        let settings = try XCTUnwrap(panel.composer.browserLaunchRow?.settings)
        settings.selectConfirmation(original.confirmation == .ask ? .skip : .ask)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotEqual(settings.config, original)
        XCTAssertEqual(saved.config, original)
    }

    func testMountTargetsListTabsWithAnEmptyPanelCurrentWindowFirst() throws {
        let current = state(), other = state(), incognito = state(incognito: true)
        func tab(_ id: Int, _ url: String, _ index: Int) -> Tab {
            let tab = Tab(guid: id, url: url, isActive: false, index: index, title: "Tab \(id)")
            tab.aiChatEnabled = Tab.supportsAIChat(urlString: tab.url)
            return tab
        }
        let first = tab(1, "https://example.com", 0), occupied = tab(2, "https://example.org", 1)
        let chrome = tab(3, "chrome://newtab/", 2)
        let chat = tab(4, AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, 3)
        let second = tab(5, "https://example.net", 0), privateTab = tab(6, "https://example.com", 0)
        current.tabs = [first, occupied, chrome, chat]
        other.tabs = [second]
        incognito.tabs = [privateTab]
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { (1...6).contains($0) },
                                   browserSessionFactory: { _, _, _ in NSObject() })
        chatStores.append(store)
        let conversation = try store.create(request: DrifterLaunchRequest(prompt: "Read", config: DrifterLaunchSettings().config, windowId: 771),
                                            tabId: 4)
        store.setPanelChat(conversation.id, for: occupied.guid)
        XCTAssertEqual(AgentChatMountPicker.targets(in: [other, incognito, current], first: current, store: store).map(\.guid), [1, 5])
    }

    func testAvailabilityAndToggleRespectWindowContext() {
        let state = state()
        let tab = host(in: state)
        XCTAssertTrue(state.canShowChatPanel(for: tab))
        state.toggleAIChat()
        XCTAssertFalse(tab.aiChatCollapsed)
        state.toggleAIChat()
        XCTAssertTrue(tab.aiChatCollapsed)
        for unavailable in [self.state(incognito: true), self.state(agentSpace: true)] {
            let page = host(in: unavailable)
            XCTAssertFalse(unavailable.canShowChatPanel(for: page))
            unavailable.toggleAIChat()
            XCTAssertTrue(page.aiChatCollapsed)
        }
        state.enterPlaceholderMode(wrapper: BookmarkLayoutTestWebContentWrapper(urlString: "chrome://dino"))
        XCTAssertFalse(state.canShowChatPanel(for: tab))
        state.toggleAIChat()
        XCTAssertTrue(tab.aiChatCollapsed)
        let chatURL = AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString
        XCTAssertFalse(Tab.supportsAIChat(urlString: chatURL))
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: chatURL)
        let chatTab = Tab(url: chatURL, isActive: false, index: 0, webContentView: wrapper)
        XCTAssertFalse(chatTab.aiChatEnabled)
        XCTAssertFalse(state.canShowChatPanel(for: chatTab))
        XCTAssertFalse(Tab.supportsAIChat(urlString: "chrome://newtab/"))
        XCTAssertTrue(Tab.supportsAIChat(urlString: "https://example.com"))
        XCTAssertFalse(Tab.supportsAIChat(urlString: MistAppRoute.current.url(.drifter).absoluteString))
        XCTAssertFalse(Tab.supportsAIChat(urlString: MistAppRoute.current.url(.clipboard).absoluteString))
        XCTAssertTrue(Tab.supportsAIChat(urlString: MistAppRoute.current.url(.mail).absoluteString))
    }
}

/// Exercises the real binding path while replacing only the framework's tab creation.
private final class PanelBrowserState: BrowserState {
    var created: [(url: String?, focused: Bool)] = []
    override func createTab(_ url: String?, customGuid: String? = nil, focusAfterCreate: Bool = true) {
        created.append((url, focusAfterCreate))
        let tab = Tab(guid: 900 + created.count, url: url, isActive: focusAfterCreate, index: tabs.count)
        tabs.append(tab)
        if focusAfterCreate { focusingTab = tab }
        updateNormalTabs()
    }
}
