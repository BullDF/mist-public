import Foundation
import Combine

extension Notification.Name {
    /// Sent after a chat's working-tab state changes, scoped to its original window.
    static let browserAgentPreviewDidChange = Notification.Name("BrowserAgentPreviewDidChange")
}
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
import AppKit

extension AgentChatRoute {
    static var current: AgentChatRoute {
        AgentChatRoute(baseDirectory: URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true))
    }
}
#endif

struct AgentChatPlaceholderStyle {
    let background: String
    let iconPNGBase64: String?
}

/// Owns sessions, not window state. A tab's stable identity survives native view teardown.
@MainActor
final class AgentChatStore: ObservableObject {
    var onChatReplaced: ((_ old: UUID, _ new: UUID) -> Void)?
    var now: () -> Date = Date.init
    private var browserPreviewExpiryTimer: Timer?
    private(set) var browserPreviewExpiryDeadline: Date?
    typealias BrowserSessionFactory = @MainActor (DrifterLaunchRequest, AgentConversation, URL) -> AnyObject
    @MainActor struct Entry {
        let conversation: AgentConversation
        let settings: DrifterSettings
        var config: DrifterConfig { settings.config }
        var tabId: Int
        /// A restored Browser Agent chat gets its session from its first message.
        let session: AnyObject?
        var browserPreview: BrowserAgentPreviewState? = nil
        var browserFolder: BrowserAgentFolderState? = nil
        /// The saved session that first message resumes.
        var restoredSessionId: String? = nil
    }

    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    private var tabBindings: [UUID: AnyCancellable] = [:]
    private var pendingFolderCreations: [Int: Set<Int>] = [:]
    private lazy var closedFolders = BrowserAgentClosedFolders(
        url: route.directory.deletingLastPathComponent().appendingPathComponent("AgentFolders.json"))

    /// ⌘⇧T never reopens agent tabs: closing a chat closes its folder after the
    /// chat's own tab, and a reopened folder is swept at once. Returns false to
    /// leave the restore to Chromium.
    func restoreClosedTabSkippingAgentFolders(windowId: Int) -> Bool {
        let tabs = SearchTabsChromiumProvider().snapshot(windowId: windowId).closedTabs
            .map { (entry: $0.sourceEntrySessionId, group: $0.groupIdHex) }
        switch closedFolders.pick(tabs) {
        case .chromium:
            return false
        case .nothing:
            return true
        case let .entry(sessionId):
            _ = ChromiumLauncher.sharedInstance().bridge?
                .openRecentlyClosedSearchEntry(withSessionId: sessionId, windowId: Int64(windowId))
            return true
        }
    }

    /// Whether a recently-closed tab was closed from an agent folder.
    func isAgentFolder(token: String) -> Bool { closedFolders.contains(token) }

    private func folderWindow(_ windowId: Int) -> BrowserState? {
        SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
    }

    func browserFolder(for id: UUID) -> BrowserAgentFolderState? { entries[id]?.browserFolder }

    private func ownsBrowserFolder(token: String, windowId: Int) -> Bool {
        entries.values.contains { $0.browserFolder?.token == token && $0.browserFolder?.windowId == windowId }
    }

    private func visibleFolderTabs(windowId: Int) -> Set<Int> {
        guard let state = folderWindow(windowId), let active = state.focusingTab else { return [] }
        return Set(state.tabs.filter {
            $0.guid == active.guid || state.splitGroup(forTabId: active.guid)?.contains(tabId: $0.guid) == true
        }.map(\.guid))
    }

    /// Called after the authenticated open expectation is claimed and the tab is mirrored.
    func groupBrowserAgentTab(_ tabId: Int, chatId: UUID, windowId: Int) {
        groupBrowserAgentTab(tabId, chatId: chatId, windowId: windowId, workingTab: true)
    }

    private func groupBrowserAgentTab(_ tabId: Int, chatId: UUID, windowId: Int, workingTab: Bool) {
        let rootId = familyRoot(of: chatId)
        guard !terminated, let entry = entries[chatId], let root = entries[rootId],
              !workingTab || entry.browserPreview?.windowId == windowId,
              let state = folderWindow(windowId),
              let chatTab = state.tabs.first(where: { $0.guid == root.tabId }),
              state.tabs.contains(where: { $0.guid == tabId }),
              let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let ids = [NSNumber(value: tabId)]
        if let folder = root.browserFolder, folder.windowId == windowId, state.groups[folder.token] != nil {
            trackBrowserFolderTab(tabId, chatId: workingTab ? chatId : rootId, rootId: rootId, folder: folder)
            bridge.addTabsToGroup(withWindowId: Int64(windowId), tabIds: ids, tokenHex: folder.token)
        } else {
            pendingFolderCreations[windowId, default: []].insert(tabId)
            defer { pendingFolderCreations[windowId]?.remove(tabId) }
            let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId), tabIds: ids,
                title: AgentChatStrings.agentTabs + BrowserAgentFolderState.titleMarker, color: "grey")
            guard !token.isEmpty else { return }
            closedFolders.insert(token)
            let folder = BrowserAgentFolderState(windowId: windowId, token: token)
            entries[rootId]?.browserFolder = folder
            initializeBrowserFolderTurn(rootId)
            trackBrowserFolderTab(tabId, chatId: workingTab ? chatId : rootId, rootId: rootId, folder: folder)
            bridge.updateTabGroupCollapsed(withWindowId: Int64(windowId), tokenHex: token, isCollapsed: false)
            // Land after the chat's whole split: a group between its panes dissolves the split.
            let splitEnd = state.splitGroup(forTabId: chatTab.guid)?.partnerTabId(of: chatTab.guid)
                .flatMap { id in state.tabs.first { $0.guid == id }?.index } ?? chatTab.index
            bridge.moveGroup(withWindowId: Int64(windowId), tokenHex: token, to: max(chatTab.index, splitEnd) + 1)
        }
        objectWillChange.send()
        notifyBrowserPreviewChanged(windowId: windowId)
        armBrowserPreviewExpiry()
    }

    private func initializeBrowserFolderTurn(_ id: UUID) {
        guard let preview = entries[id]?.browserPreview else { return }
        entries[id]?.browserFolder?.setTurnActive(preview.turnActive, now: now())
        if preview.workedThisTurn { entries[id]?.browserFolder?.report(tabId: preview.tabId, now: now()) }
    }

    private func trackBrowserFolderTab(_ tabId: Int, chatId: UUID, rootId: UUID, folder: BrowserAgentFolderState) {
        for id in Array(entries.keys) where id != chatId && entries[id]?.browserFolder?.token == folder.token
            && entries[id]?.browserFolder?.windowId == folder.windowId {
            entries[id]?.browserFolder?.remove(tabId)
        }
        if entries[chatId]?.browserFolder?.token != folder.token {
            entries[chatId]?.browserFolder = BrowserAgentFolderState(windowId: folder.windowId,
                token: folder.token, borrowed: chatId != rootId)
            initializeBrowserFolderTurn(chatId)
        }
        entries[chatId]?.browserFolder?.join(tabId, now: now())
    }

    private func joinUntrackedFolderTab(_ tabId: Int, token: String, windowId: Int) {
        let sharers = entries.keys.filter { entries[$0]?.browserFolder?.token == token
            && entries[$0]?.browserFolder?.windowId == windowId }
        guard !sharers.contains(where: { entries[$0]?.browserFolder?.members[tabId] != nil }),
              let owner = sharers.first(where: { entries[$0]?.browserFolder?.borrowed == false }) else { return }
        entries[owner]?.browserFolder?.join(tabId, now: now())
    }

    func browserFolderGroupEvent(_ event: TabGroupEvent) {
        guard !terminated, let windowId = event.browserId else { return }
        let token: String
        switch event.action {
        case let .groupCreated(value, title, _, _, initialTabIds):
            token = value
            sweepBrowserFolder(token: token, title: title, windowId: windowId)
            for tabId in initialTabIds { joinUntrackedFolderTab(tabId, token: token, windowId: windowId) }
        case let .groupVisualDataChanged(value, title, _, _):
            token = value
            sweepBrowserFolder(token: token, title: title, windowId: windowId)
        case let .tabJoinedGroup(tabId, value):
            token = value
            joinUntrackedFolderTab(tabId, token: token, windowId: windowId)
        case let .tabLeftGroup(tabId, value):
            token = value
            for id in Array(entries.keys) where entries[id]?.browserFolder?.token == token
                && entries[id]?.browserFolder?.windowId == windowId {
                entries[id]?.browserFolder?.remove(tabId)
            }
        case let .groupClosed(value):
            token = value
            for id in Array(entries.keys) where entries[id]?.browserFolder?.token == token
                && entries[id]?.browserFolder?.windowId == windowId {
                entries[id]?.browserFolder = nil
            }
        }
        objectWillChange.send()
        notifyBrowserPreviewChanged(windowId: windowId)
        armBrowserPreviewExpiry()
    }

    private func sweepBrowserFolder(token: String, title: String, windowId: Int) {
        guard BrowserAgentFolderState.isAgentFolderTitle(title) else { return }
        closedFolders.insert(token)
        guard !ownsBrowserFolder(token: token, windowId: windowId) else { return }
        // Restore callbacks must never reenter Chromium. Recheck ownership after creation returns its token.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminated, !self.ownsBrowserFolder(token: token, windowId: windowId),
                  self.pendingFolderCreations[windowId]?.isEmpty != false,
                  let state = self.folderWindow(windowId), let group = state.groups[token],
                  BrowserAgentFolderState.isAgentFolderTitle(group.title) else { return }
            // Child chats outlive the folder: their tabs leave it as ordinary tabs, and only working tabs close.
            let members = state.normalTabs.filter { $0.groupToken == token }
            let chatTabs = members.filter { self.route.conversationId(for: $0.url) != nil }
            guard !chatTabs.isEmpty, let bridge = ChromiumLauncher.sharedInstance().bridge else {
                return state.closeTabGroup(token: token, intent: .tabDriven)
            }
            bridge.removeTabsFromGroup(withWindowId: Int64(windowId), tabIds: chatTabs.map { NSNumber(value: $0.guid) })
            // The group dissolves on its own once its last tab leaves.
            if chatTabs.count < members.count { bridge.closeGroup(withWindowId: Int64(windowId), tokenHex: token) }
        }
    }

    /// Selection and split changes also retry tabs whose deadline passed while visible.
    func browserFolderVisibilityChanged() {
        guard !terminated else { return }
        expireBrowserFolderTabs()
        armBrowserPreviewExpiry()
        scheduleIdleTabRefresh()
    }

    /// An idle-closing chat's tab that comes back unshown (session restore, ⌘⇧T) gets its chat restored, so its
    /// idle clock runs.
    func chatTabOpened(_ tab: Tab) {
        guard !terminated, !idleClosingChats.isEmpty else { return }
        // Never reenter the store from Chromium's creation callback; the URL is mirrored by then.
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, !self.terminated, let id = self.route.conversationId(for: tab.url),
                  self.idleClosingChats.contains(id), self.entries[id] == nil else { return }
            self.restoreIfNeeded(id, tabId: tab.guid)
        }
    }

    private func isTabShown(_ tabId: Int) -> Bool {
        if isTabActive(tabId) { return true }
        guard let windowId = windowOfTab(tabId) else { return false }
        return visibleFolderTabs(windowId: windowId).contains(tabId)
    }

    private func expireBrowserFolderTabs() {
        for entry in Array(entries.values) {
            guard let folder = entry.browserFolder else { continue }
            guard let state = folderWindow(folder.windowId) else {
                entries[entry.conversation.id]?.browserFolder = nil
                continue
            }
            let visible = visibleFolderTabs(windowId: folder.windowId)
            for tabId in folder.dueTabIds(now: now()).subtracting(visible) {
                guard let tab = state.tabs.first(where: { $0.guid == tabId }), tab.groupToken == folder.token else {
                    entries[entry.conversation.id]?.browserFolder?.remove(tabId)
                    continue
                }
                entries[entry.conversation.id]?.browserFolder?.remove(tabId)
                if MistApps.address(tab.url)?.chatId != nil { continue }
                tab.close()
            }
        }
    }

    func openAttachment(_ attachment: AgentAttachment, chatId: UUID, sourceTabId: Int? = nil) {
        guard let tabId = sourceTabId ?? entries[chatId]?.tabId,
              let state = SpaceSessionControllersManager.shared.getAllWindows().map(\.browserState)
                .first(where: { $0.tabs.contains { $0.guid == tabId } }),
              let url = attachmentURL(attachment, chatId: chatId) else { return }
        state.openLinkAsPeek(urlString: url.absoluteString, sourceTabId: tabId)
    }

    private func attachmentURL(_ attachment: AgentAttachment, chatId: UUID) -> URL? {
        switch attachment {
        case let .image(image): return try? route.imageURL(image, for: chatId)
        case let .file(file): return file.url
        }
    }

    /// Switches to a tab already showing the link, in the current window first, then in another window of its
    /// Space. ⌘-click always opens a new tab.
    func openLink(_ url: URL, chatId: UUID) {
        let url = AgentChatLink.target(url, folder: entries[chatId]?.config.folder)
        let manager = SpaceSessionControllersManager.shared
        let windows = manager.getAllWindows()
        guard let current = windows.first(where: { $0 === manager.activeWindowController })
                ?? windows.first(where: { window in window.browserState.tabs.contains { $0.guid == entries[chatId]?.tabId } })
        else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) != true, let key = AgentChatLink.matchKey(url.absoluteString) {
            let candidates = [current] + windows.filter { $0 !== current && $0.browserType == .normal && $0.spaceId == current.spaceId }
            for window in candidates {
                let state = window.browserState
                if let tab = ([state.focusingTab].compactMap { $0 } + state.tabs)
                    .first(where: { $0.url.flatMap(AgentChatLink.matchKey) == key }) {
                    window.selectTab(tab)
                    return
                }
            }
        }
        current.browserState.createTab(url.absoluteString, focusAfterCreate: true)
    }

    /// A tab for the chat was requested and hasn't arrived yet.
    func isOpeningTab(for id: UUID) -> Bool { tabBindings[id] != nil }

    func bindNextTab(_ id: UUID, in state: BrowserState, url: String, completion: ((Int) -> Void)? = nil) {
        tabBindings[id] = state.$tabs.receive(on: DispatchQueue.main).sink { [weak self] tabs in
            guard let self, let tab = tabs.first(where: { $0.url == url }) else { return }
            self.assign(id, to: tab.guid)
            if let title = self.conversation(for: id)?.title { tab.title = title }
            self.tabBindings[id] = nil
            completion?(tab.guid)
        }
    }

    static let shared: AgentChatStore = {
        let store = AgentChatStore(route: .current, placeholderStyle: { engine in
            let writer = MistAppPlaceholders.shared
            return .init(background: writer.background, iconPNGBase64: writer.iconPNGBase64(AgentChatIcon.resolve(engine: engine).rawValue))
        }, tabExists: { id in
            SpaceSessionControllersManager.shared.getAllWindows().contains { $0.browserState.tabs.contains { $0.guid == id } }
        }, isTabActive: { id in
            SpaceSessionControllersManager.shared.getAllWindows().contains { $0.browserState.focusingTab?.guid == id }
        }, windowId: { id in
            SpaceSessionControllersManager.shared.getAllWindows().first { $0.browserState.tabs.contains { $0.guid == id } }?.browserState.windowId
        }, reloadTab: { id, title in
            for window in SpaceSessionControllersManager.shared.getAllWindows() {
                if let tab = window.browserState.tabs.first(where: { $0.guid == id }) {
                    tab.title = title
                    // Reload the same file URL: the native overlay remains mounted by conversation ID.
                    tab.reloadPage()
                    break
                }
            }
        }, navigateTab: { id, url in
            for window in SpaceSessionControllersManager.shared.getAllWindows() {
                if let tab = window.browserState.tabs.first(where: { $0.guid == id }) {
                    window.browserState.navigateChatTab(tab, to: url)
                    break
                }
            }
        }, openChatTab: { id, windowId in
            guard let state = SpaceSessionControllersManager.shared.getBrowserState(for: windowId) else { return }
            AgentChatStore.shared.openBackgroundTab(for: id, in: state)
        }, closeChatTab: { id in
            for window in SpaceSessionControllersManager.shared.getAllWindows() {
                if let tab = window.browserState.tabs.first(where: { $0.guid == id }) { tab.close(); break }
            }
        }, collapsePanel: { id in
            for window in SpaceSessionControllersManager.shared.getAllWindows() {
                if let tab = window.browserState.tabs.first(where: { $0.guid == id }) {
                    window.browserState.setAIChatCollapsed(for: tab, collapsed: true)
                    break
                }
            }
        }, tabIsKept: { id in
            SpaceSessionControllersManager.shared.getAllWindows().lazy
                .compactMap { $0.browserState.tabs.first { $0.guid == id } }.first
                .map { $0.isPinned || $0.groupToken != nil } ?? false
        }, tabIsInFolder: { id, folder in
            guard let folder, let state = SpaceSessionControllersManager.shared.getBrowserState(for: folder.windowId) else { return false }
            return state.tabs.first { $0.guid == id }?.groupToken == folder.token
        }, chatTabs: {
            SpaceSessionControllersManager.shared.getAllWindows().flatMap { window in
                window.browserState.tabs.compactMap { tab in
                    tab.url.flatMap { MistApps.address($0)?.chatId }.map { (chatId: $0, tabId: tab.guid) }
                }
            }
        })
        store.observers.append(NotificationCenter.default.addObserver(forName: .browserTabDidClose, object: nil, queue: .main) { [weak store] notification in
            guard let id = notification.userInfo?[BrowserTabCloseInfoKey.tabId] as? Int else { return }
            let url = notification.userInfo?[BrowserTabCloseInfoKey.url] as? String
            Task { @MainActor in store?.tabDidClose(id, url: url) }
        })
        store.observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak store] _ in
            MainActor.assumeIsolated { store?.windowWillClose() }
        })
        store.observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak store] _ in
            MainActor.assumeIsolated { store?.terminate() }
        })
        return store
    }()
    #endif

    let route: AgentChatRoute
    @Published private(set) var unseenCompletions: Set<UUID> = []
    private var entries: [UUID: Entry] = [:]
    private(set) var parent: [UUID: UUID] = [:]
    private var closing: Set<UUID> = []
    private var reportedQuestions: [UUID: Set<String>] = [:]
    private var taskFinishes: [UUID: AgentTaskFinish] = [:]
    /// Set by the Slack bridge.
    var isSlackThreadChat: ((UUID) -> Bool)?
    /// Set by the Slack bridge.
    var onSlackTaskFinished: ((UUID, AgentTaskFinish, [AgentChatItem]) -> Void)?
    private var workingTabReportOrder: UInt64 = 0
    private var storedAgents: [UUID: DrifterEngine] = [:]
    private var panelChats: [Int: UUID] = [:]
    private var panelHistory: [Int: [UUID]] = [:]
    private var visiblePanels: [UUID: UUID] = [:]
    /// Empty chats with no tab of their own that only a panel shows: their own tab closed while a panel showed them, or
    /// the panel's New Chat created them. Panel links don't survive a relaunch.
    private var detached: Set<UUID> = []
    /// Chats the Chat panel's New Chat created.
    private var panelNewChats: Set<UUID> = []

    func panelChat(for hostTabId: Int) -> UUID? { panelChats[hostTabId] }
    func hasPanelChat(_ hostTabId: Int) -> Bool {
        panelChat(for: hostTabId).flatMap { entry(for: $0) } != nil
    }
    func panelChatHistory(for hostTabId: Int) -> [AgentConversation] {
        (panelHistory[hostTabId] ?? []).reversed().compactMap { entries[$0]?.conversation }
    }
    /// The live tab whose Chat panel started a chat, or that it was mounted to.
    func panelHost(of chatId: UUID) -> Int? {
        panelHistory.first { $0.value.contains(chatId) && tabExists($0.key) }?.key
    }

    /// Links a chat with no linked tab to an open tab whose Chat panel is empty, as if that panel had started it.
    @discardableResult
    func mount(_ chatId: UUID, to hostTabId: Int) -> Bool {
        guard entry(for: chatId) != nil, panelHost(of: chatId) == nil,
              tabExists(hostTabId), !hasPanelChat(hostTabId) else { return false }
        setPanelChat(chatId, for: hostTabId)
        return true
    }

    /// The Chat panel's New Chat: an empty chat shown by `hostTabId`'s panel that opens its own background tab, so
    /// other chats can message it before its first message. Only the panel holds it until that tab arrives. The
    /// previous New Chat's chat, still empty, closes with its tab unless the user pinned or grouped it.
    func createPanelChat(for hostTabId: Int) throws -> AgentConversation {
        let previous = panelChats[hostTabId]
        let chat = try createEmpty(tabId: -1)
        detached.insert(chat.id)
        panelNewChats.insert(chat.id)
        setPanelChat(chat.id, for: hostTabId)
        if let previous, panelNewChats.contains(previous), isEmpty(previous),
           let tabId = entries[previous]?.tabId, tabId >= 0, !tabIsKept(tabId) {
            closeWithTab(previous)
        }
        if entries[chat.id] != nil, let window = windowOfTab(hostTabId) { openChatTab(chat.id, window) }
        return chat
    }

    /// Undoes `mount` or a panel start: the chat keeps running in its own tab, and a host panel showing it goes empty.
    /// A new chat's draft that is only the host-tab mention the panel inserted goes too.
    func unmount(_ chatId: UUID) {
        let hosts = Set(panelHistory.filter { $0.value.contains(chatId) }.keys)
        guard !hosts.isEmpty else { return }
        for host in hosts {
            panelHistory[host]?.removeAll { $0 == chatId }
            if panelChats[host] == chatId { panelChats[host] = nil }
        }
        if let conversation = entries[chatId]?.conversation, conversation.isNew, conversation.draft.isOnlyMention(of: hosts) {
            conversation.setDraft(AgentComposerDraft())
        }
        releaseDetachedChats()
        scheduleIdleTabRefresh()
        objectWillChange.send()
    }

    func setPanelChat(_ chatId: UUID?, for hostTabId: Int) {
        if let chatId {
            guard entries[chatId] != nil else { return }
            if !(panelHistory[hostTabId] ?? []).contains(chatId) { panelHistory[hostTabId, default: []].append(chatId) }
        }
        guard panelChats[hostTabId] != chatId else { return }
        panelChats[hostTabId] = chatId
        releaseDetachedChats()
        scheduleIdleTabRefresh()
        objectWillChange.send()
    }

    func setPanelVisible(_ chatId: UUID?, panelId: UUID) {
        guard visiblePanels[panelId] != chatId else { return }
        visiblePanels[panelId] = chatId
        if let chatId { unseenCompletions.remove(chatId) }
    }
    private var statusBindings: [UUID: AnyCancellable] = [:]
    private var engineBindings: [UUID: AnyCancellable] = [:]
    private let launchSettings: DrifterLaunchSettings
    private let placeholderStyle: (DrifterEngine) -> AgentChatPlaceholderStyle
    private var recordBindings: [UUID: AnyCancellable] = [:]
    private let recordQueue = DispatchQueue(label: "Mist.AgentChatRecords")
    private let browserFactory: BrowserSessionFactory?
    private let chatTabs: () -> [(chatId: UUID, tabId: Int)]
    private let tabExists: (Int) -> Bool
    private let isTabActive: (Int) -> Bool
    private let windowOfTab: (Int) -> Int?
    private let reloadTab: (Int, String) -> Void
    private let navigateTab: (Int, URL) -> Void
    private let openChatTab: (UUID, Int) -> Void
    private let closeChatTab: (Int) -> Void
    /// Closes a host tab's Chat panel.
    private let collapsePanel: (Int) -> Void
    /// Pinned, or in a tab group: the user moved the tab.
    private let tabIsKept: (Int) -> Bool
    /// Whether the tab sits in that agent folder; no folder means no.
    private let tabIsInFolder: (Int, BrowserAgentFolderState?) -> Bool
    /// Chats whose own tab closes once idle (Slack threads' chats), until the user keeps the tab.
    private var idleClosingChats: Set<UUID> = []
    private var idleTabs: [UUID: AgentChatIdleTab] = [:]
    private var idleTabRefreshScheduled = false
    private let closeDelay: UInt64
    private var pendingCloses: [Int: Task<Void, Never>] = [:]
    private var pendingWindowClose: Task<Void, Never>?
    private var terminated = false
    private var observers: [NSObjectProtocol] = []

    init(route: AgentChatRoute, launchSettings: DrifterLaunchSettings = .init(),
         placeholderStyle: @escaping (DrifterEngine) -> AgentChatPlaceholderStyle = { _ in .init(background: "#FFFFFF", iconPNGBase64: nil) },
         closeDelay: UInt64 = 2_000_000_000,
         tabExists: @escaping (Int) -> Bool,
         isTabActive: @escaping (Int) -> Bool = { _ in false },
         windowId: @escaping (Int) -> Int? = { _ in nil },
         reloadTab: @escaping (Int, String) -> Void = { _, _ in },
         navigateTab: @escaping (Int, URL) -> Void = { _, _ in },
         openChatTab: @escaping (UUID, Int) -> Void = { _, _ in },
         closeChatTab: @escaping (Int) -> Void = { _ in },
         collapsePanel: @escaping (Int) -> Void = { _ in },
         tabIsKept: @escaping (Int) -> Bool = { _ in false },
         tabIsInFolder: @escaping (Int, BrowserAgentFolderState?) -> Bool = { _, _ in true },
         chatTabs: @escaping () -> [(chatId: UUID, tabId: Int)] = { [] },
         browserSessionFactory: BrowserSessionFactory? = nil) {
        self.route = route
        self.launchSettings = launchSettings
        self.placeholderStyle = placeholderStyle
        self.tabIsKept = tabIsKept
        self.tabIsInFolder = tabIsInFolder
        self.chatTabs = chatTabs
        self.tabExists = tabExists
        self.isTabActive = isTabActive
        windowOfTab = windowId
        self.reloadTab = reloadTab
        self.navigateTab = navigateTab
        self.openChatTab = openChatTab
        self.closeChatTab = closeChatTab
        self.collapsePanel = collapsePanel
        self.closeDelay = closeDelay
        browserFactory = browserSessionFactory
    }

    #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
    func launchBrowserChat(prompt: String, attachments: [AgentAttachment], mentions: [AgentTabMention],
                           config: DrifterConfig, in state: BrowserState, tabId: Int,
                           createBackgroundTab: Bool = false, sender: AgentMessageSender? = nil) throws -> AgentConversation {
        let request = DrifterLaunchRequest(prompt: prompt, attachments: attachments, config: config,
                                               windowId: state.windowId, mentions: mentions, sender: sender,
                                               slackThread: sender?.kind == .slack)
        let conversation = try create(request: request, tabId: tabId)
        MistSidebarAgentSections.setExpanded(true)
        if createBackgroundTab { openBackgroundTab(for: conversation.id, in: state) }
        return conversation
    }

    private func openBackgroundTab(for id: UUID, in state: BrowserState) {
        let url = route.placeholderURL(for: id).absoluteString
        bindNextTab(id, in: state, url: url) { [weak self] tabId in
            guard let self, self.parent[id] != nil else { return }
            self.groupBrowserAgentTab(tabId, chatId: id, windowId: state.windowId, workingTab: false)
        }
        state.createTab(url, focusAfterCreate: false)
    }

    /// A chat whose tab just closed (still within `closeDelay`) moves to the new tab instead of closing.
    func openChatInBackground(_ id: UUID, in state: BrowserState, completion: @escaping (Bool) -> Void) {
        func isOpen() -> Bool { entries[id].map { $0.tabId < 0 || tabExists($0.tabId) } ?? false }
        if isOpen() { completion(true); return }
        _ = agentChats()
        if isOpen() { completion(true); return }
        guard entries[id] != nil || canRestore(id) else { completion(false); return }
        let url = route.placeholderURL(for: id).absoluteString
        bindNextTab(id, in: state, url: url) { [weak self] tabId in
            completion(self?.restoreIfNeeded(id, tabId: tabId) == true)
        }
        state.createTab(url, focusAfterCreate: false)
    }
    #endif

    func create(request: DrifterLaunchRequest, tabId: Int) throws -> AgentConversation {
        var request = request
        if request.parent == nil, ClaudeCodeClearCommand.matches(request.prompt) {
            return try createEmpty(config: request.config, tabId: tabId)
        }
        let (conversation, imported) = try prepare(engine: request.config.engine, prompt: request.prompt, attachments: request.attachments,
                                       mentions: request.mentions)
        request.attachments = imported
        register(try browserEntry(request: request, conversation: conversation, tabId: tabId))
        return conversation
    }

    private func browserEntry(request: DrifterLaunchRequest, conversation: AgentConversation, tabId: Int,
                              settings existing: DrifterSettings? = nil) throws -> Entry {
        existing?.beginSession()
        var request = request
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: request.config.folder.path, isDirectory: &directory) || !directory.boolValue {
            request.config.folder = DrifterHome.current.folder
        }
        let folder = request.config.folder
        let session: AnyObject
        var preview: BrowserAgentPreviewState?
        if let browserFactory { session = browserFactory(request, conversation, folder) }
        else {
            #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
            let registry = AgentDriverSessionRegistry.shared
            let driver = registry.mintBrowserAgent()
            let capability = driver.capability
            preview = BrowserAgentPreviewState(principalId: driver.principalId, windowId: request.windowId)
            session = DrifterSession(request: request, conversation: conversation, folder: folder,
                tasksFolder: route.chatDirectory(for: conversation.id).appendingPathComponent("Tasks", isDirectory: true),
                resources: Bundle.main.resourceURL!, bundleId: Bundle.main.bundleIdentifier!, capability: capability, settings: existing,
                bindProcess: { registry.bindBrowserAgent(capability: capability, pid: $0) },
                invalidate: { [weak self] in
                    AgentUserSpaceDriveRegistry.shared.release(principalId: driver.principalId)
                    registry.invalidateBrowserAgent(capability: capability)
                    self?.invalidateBrowserPreview(principalId: driver.principalId)
                })
            #else
            preconditionFailure("Hostless Browser Agent tests must inject a session factory")
            #endif
        }
        (session as? DrifterSession)?.onWake = { [weak self] message in
            await self?.deliverExternalMessage(message, to: conversation.id) ?? false
        }
        let settings = (session as? DrifterSession)?.settings ?? existing ?? DrifterSettings(config: request.config, running: true)
        return Entry(conversation: conversation, settings: settings,
                     tabId: tabId, session: session, browserPreview: preview)
    }

    func backgroundTasks(for id: UUID) -> DrifterBackgroundTasks? {
        (entries[id]?.session as? DrifterSession)?.backgroundTasks
    }

    private func prepare(engine: DrifterEngine, prompt: String, attachments: [AgentAttachment], mentions: [AgentTabMention]) throws -> (AgentConversation, [AgentAttachment]) {
        let prompt = AgentMentionText(text: prompt, mentions: mentions).normalized.text
        let conversation = AgentConversation(firstPrompt: prompt)
        let imported: [AgentAttachment]
        do { imported = try attachments.imported(into: route.attachmentsDirectory(for: conversation.id)) }
        catch {
            try? FileManager.default.removeItem(at: route.chatDirectory(for: conversation.id))
            throw error
        }
        conversation.title = AgentChatRoute.title(for: prompt, attachments: imported)
        conversation.autoTitle = conversation.title
        try writePlaceholder(conversation.id, title: conversation.title, engine: engine)
        connectTitle(conversation)
        return (conversation, imported)
    }

    private func writePlaceholder(_ id: UUID, title: String, engine: DrifterEngine, at url: URL? = nil) throws {
        let style = placeholderStyle(engine)
        let html = AgentChatRoute.html(title: title, background: style.background, engine: engine, iconPNGBase64: style.iconPNGBase64)
        let url = url ?? route.placeholderURL(for: id)
        guard (try? String(contentsOf: url, encoding: .utf8)) != html else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    func rewriteLivePlaceholders() {
        for (id, entry) in entries where tabExists(entry.tabId) {
            try? writePlaceholder(id, title: entry.conversation.title, engine: entry.config.engine)
        }
    }

    func createEmpty(config: DrifterConfig? = nil, tabId: Int, id: UUID? = nil, placeholderAt: URL? = nil) throws -> AgentConversation {
        let provided = config
        var config = config ?? launchSettings.config
        if provided == nil { config.folder = DrifterHome.current.folder }
        let conversation = AgentConversation(id: id ?? UUID())
        conversation.title = MistAppID.drifter.name
        conversation.autoTitle = conversation.title
        conversation.update(items: [], status: .dormant)
        try writePlaceholder(conversation.id, title: conversation.title, engine: config.engine, at: placeholderAt)
        connectTitle(conversation)
        register(Entry(conversation: conversation, settings: DrifterSettings(config: config), tabId: tabId, session: nil))
        saveRecord(conversation.id, synchronously: true)
        return conversation
    }

    /// No message was sent, queued or received, and no session exists. The composer's draft never counts.
    func isEmpty(_ id: UUID) -> Bool {
        guard let entry = entries[id] else { return false }
        let chat = entry.conversation
        return chat.items.isEmpty && chat.queue.isEmpty && chat.unsent == nil
            && entry.session == nil && resumeId(of: entry) == nil
    }

    private func shownByPanel(_ id: UUID) -> Bool {
        panelChats.contains { $0.value == id && tabExists($0.key) }
    }

    /// An open tab other than `tabId` showing the chat: a duplicated tab, or its file opened again.
    private func otherTab(showing id: UUID, besides tabId: Int) -> Int? {
        chatTabs().first { $0.chatId == id && $0.tabId != tabId && tabExists($0.tabId) }?.tabId
    }

    /// Chats kept open only by a panel showing them, after their own tab closed, close once no panel does.
    private func releaseDetachedChats() {
        for id in detached where !shownByPanel(id) { close(id) }
    }

    func recreate(_ id: UUID, tabId: Int, at url: URL) -> Bool {
        guard !terminated, route.canRecreate(id),
              url.path == route.canonicalURL(for: id).path || url.path == route.legacyURL(for: id).path else { return false }
        do {
            let chat = try createEmpty(tabId: tabId, id: id, placeholderAt: url)
            reloadTab(tabId, chat.title)
            return true
        } catch { return false }
    }

    private func connectTitle(_ conversation: AgentConversation) {
        let conversationId = conversation.id
        conversation.onTitleGenerated = { [weak self, weak conversation] title in
            guard let conversation, conversation.manualTitle == nil else { return }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            conversation.autoTitle = title
            _ = try? self?.updateTitle(title, for: conversationId)
        }
    }

    func register(_ entry: Entry) {
        let conversation = entry.conversation
        let id = conversation.id
        conversation.attachmentsFolder = route.attachmentsDirectory(for: id)
        entries[id] = entry
        engineBindings[id] = entry.settings.$config.map(\.engine).removeDuplicates().dropFirst()
            .sink { [weak self, weak conversation] engine in
                guard let self, let conversation else { return }
                try? self.writePlaceholder(id, title: conversation.title, engine: engine)
                self.storedAgents[id] = nil
                self.objectWillChange.send()
            }
        armBrowserPreviewExpiry()
        do {
            conversation.onClear = { [weak self] in
                do { try self?.clear(id) }
                catch { NSLog("Couldn't clear agent chat %@: %@", id.uuidString, error.localizedDescription) }
            }
        }
        conversation.onSessionTitleSent = { [weak self] in self?.saveRecord(id, synchronously: true) }
        let drafts = PassthroughSubject<Void, Never>()
        conversation.onDraftChange = { drafts.send() }
        var changes = [conversation.objectWillChange.eraseToAnyPublisher(), drafts.eraseToAnyPublisher()]
        changes.append(entry.settings.objectWillChange.eraseToAnyPublisher())
        recordBindings[id] = Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.saveRecord(id)
                // Queue, draft and background task changes can hold or release an idle-closing tab.
                self?.scheduleIdleTabRefresh()
            }
        saveRecord(id)
        conversation.onRestart = { [weak self] message in
            self?.restart(id, prompt: message.text, attachments: message.attachments, mentions: message.mentions, sender: message.sender)
        }
        #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
        conversation.onOpenAttachment = { [weak self] image in self?.openAttachment(image, chatId: id) }
        conversation.onOpenLink = { [weak self] url in self?.openLink(url, chatId: id) }
        #endif
        var previousStatus = conversation.status
        #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
        let principalId = entry.browserPreview?.principalId
        #endif
        statusBindings[conversation.id] = conversation.$status.sink { [weak self] status in
            guard let self, let entry = self.entries[conversation.id] else { return }
            let turnActive: Bool?
            switch status {
            case .running, .awaitingPermission: turnActive = true
            case .idle, .ended, .failed: turnActive = false
            case .starting, .dormant: turnActive = nil
            }
            if let turnActive {
                self.entries[conversation.id]?.browserFolder?.setTurnActive(turnActive, now: self.now())
            }
            if let turnActive, var preview = entry.browserPreview, preview.turnActive != turnActive {
                #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
                if !turnActive { BrowserAgentScrollRestore.shared.endTurn(chat: conversation.id) }
                #endif
                preview.setTurnActive(turnActive, now: self.now())
                self.entries[conversation.id]?.browserPreview = preview
                self.notifyBrowserPreviewChanged(windowId: preview.windowId)
            }
            self.updateParentPreview(for: conversation.id, status: status,
                insertIfMissing: ![.starting, .running, .awaitingPermission].contains(previousStatus)
                    && [.starting, .running, .awaitingPermission].contains(status))
            self.armBrowserPreviewExpiry()
            self.scheduleIdleTabRefresh()
            #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
            if let principalId {
                switch status {
                case .running, .awaitingPermission:
                    AgentDriverSessionRegistry.shared.setBrowserTurnActive(true, principalId: principalId)
                case .idle, .ended, .failed:
                    AgentDriverSessionRegistry.shared.setBrowserTurnActive(false, principalId: principalId)
                    AgentUserSpaceDriveRegistry.shared.release(principalId: principalId)
                case .starting, .dormant: break
                }
            }
            #endif
            if previousStatus == .running, status == .idle, !self.isTabActive(entry.tabId),
               !self.visiblePanels.values.contains(conversation.id) {
                self.unseenCompletions.insert(conversation.id)
            } else if status != .idle, self.unseenCompletions.contains(conversation.id) {
                // A running agent republishes its status with every streamed update, and any write to this
                // published set, even removing a missing id, refreshes every store observer.
                self.unseenCompletions.remove(conversation.id)
            }
            let previous = previousStatus
            previousStatus = status
            let endedTurn = [.running, .awaitingPermission].contains(previous)
                && ![.running, .awaitingPermission].contains(status)
            let finish = endedTurn ? self.taskFinishes.removeValue(forKey: id) : nil
            if endedTurn || (self.parent[id] != nil && (previous != status || status == .awaitingPermission)) {
                // A queued next turn can start before the deferred report runs.
                let items = conversation.items
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminated, self.entries[id] != nil, !self.closing.contains(id) else { return }
                    if self.parent[id] != nil {
                        self.reportChild(id, previous: previous, status: status, items: items, finish: finish)
                    } else if status == .idle, let finish, !AgentChatTranscriptText.lastTurnStopped(items) {
                        self.onSlackTaskFinished?(id, finish, items)
                    }
                }
            }
        }
        objectWillChange.send()
    }

    func entry(for id: UUID) -> Entry? { entries[id] }

    func agentChats() -> [UUID] {
        for tab in chatTabs() where entries[tab.chatId] == nil {
            _ = restoreIfNeeded(tab.chatId, tabId: tab.tabId)
        }
        let panels = Set(panelChats.values)
        return entries.compactMap { id, entry in
            tabExists(entry.tabId) || panels.contains(id) || parent[id] != nil ? id : nil
        }
    }

    func agentListing(caller: UUID) -> [AgentChatListing] {
        let chats = agentChats()
        let ids = AgentChatShortID.listedIds(chats)
        return chats.compactMap { id -> AgentChatListing? in
            guard let entry = entries[id], let listedId = ids[id] else { return nil }
            let status: String
            switch entry.conversation.status {
            case .starting, .running: status = "working"
            case .awaitingPermission: status = "asking"
            case .idle: status = "idle"
            case .dormant: status = "dormant"
            case .failed: status = "failed"
            case .ended: status = "ended"
            }
            return .init(chatId: id, id: listedId, title: entry.conversation.title,
                         engine: entry.config.engine.rawValue, model: entry.settings.modelTitle,
                         status: status, isCaller: id == caller, parent: parent[id].flatMap { ids[$0] },
                         children: parent.compactMap { $0.value == id ? ids[$0.key] : nil }.sorted())
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func deliverAgentMessage(_ text: String, to query: String, from caller: UUID) async
        -> Result<(listedId: String, title: String, delivery: String), AgentDeliveryError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptyText) }
        let target: UUID
        switch resolveAgent(query) {
        case let .success(id): target = id
        case let .failure(error): return .failure(error)
        }
        guard target != caller else { return .failure(.ownChat) }
        let listedId = listedID(target)
        guard let sendingChat = entries[caller]?.conversation else { return .failure(.notTaken(listedId)) }
        let sender = AgentMessageSender(id: AgentChatShortID.short(caller), title: sendingChat.title,
                                        kind: parent[target] == caller ? .parent : .peer)
        if parent[target] == caller, answerPendingQuestion(text, in: target) {
            return .success((listedId, entries[target]!.conversation.title, "answered"))
        }
        return await deliverMessage(.init(text: text, sender: sender), to: target)
    }

    func deliverExternalMessage(_ message: AgentQueuedMessage, to id: UUID) async -> Bool {
        if case .success = await deliverMessage(message, to: id) { return true }
        return false
    }

    @discardableResult
    func answerPendingQuestion(_ text: String, in id: UUID) -> Bool {
        guard let chat = entries[id]?.conversation, chat.status == .awaitingPermission,
              let request = pendingQuestion(chat.items), let decide = chat.onPermissionDecision,
              case var .object(input) = request.input else { return false }
        input["answers"] = .object(Dictionary(request.questions.map { ($0.question, .string(text)) }, uniquingKeysWith: { _, last in last }))
        decide(request.requestId, .allowWithInput(.object(input)))
        return true
    }

    private func deliverMessage(_ messageToDeliver: AgentQueuedMessage, to target: UUID,
                                prepare: (() -> AgentQueuedMessage?)? = nil) async
        -> Result<(listedId: String, title: String, delivery: String), AgentDeliveryError> {
        let listedId = listedID(target)
        let deadline = Date().addingTimeInterval(20)
        while entries[target]?.conversation.status == .starting, Date() < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return .failure(.notTaken(listedId)) }
        }
        guard let entry = entries[target], agentChats().contains(target) else {
            return .failure(.notTaken(listedId))
        }
        let status = entry.conversation.status
        if status == .starting { return .failure(.starting(listedId)) }
        if status == .ended { return .failure(.ended(listedId)) }
        var message: AgentQueuedMessage
        if let prepare {
            guard let prepared = prepare() else { return .failure(.notTaken(listedId)) }
            message = prepared
        } else { message = messageToDeliver }
        // A message that wakes a Slack thread's chat says that the turn's final reply posts there.
        if let sender = message.sender, sender.kind != .slack,
           AgentChatTranscriptText.wakePostsToSlack(entry.conversation.items,
                                                    queued: [entry.conversation.unsent].compactMap { $0 } + entry.conversation.queue) {
            message.sender?.postsToSlack = true
        }
        guard entry.conversation.deliver(message) else { return .failure(.notTaken(listedId)) }
        return .success((listedId, entry.conversation.title,
                         status == .running || status == .awaitingPermission ? "queued" : "started"))
    }
    func conversation(for id: UUID) -> AgentConversation? { entries[id]?.conversation }
    func drifterConfig(for id: UUID) -> DrifterConfig? { entries[id]?.settings.config }

    enum ModelSwitch: Equatable { case switched, unchanged, otherEngine, unavailable }
    /// Switches a chat's model and effort as its picker would, once its agent has started.
    func switchModel(of id: UUID, engine: DrifterEngine, model: String, effort: String) async -> ModelSwitch {
        let deadline = Date().addingTimeInterval(20)
        while entries[id]?.conversation.status == .starting, Date() < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return .unavailable }
        }
        guard let settings = entries[id]?.settings, entries[id]?.conversation.status != .starting else { return .unavailable }
        let config = settings.config
        if config.engine == engine, config.model == model, config.effort == effort { return .unchanged }
        return settings.select(engine: engine, model: model, effort: effort) ? .switched : .otherEngine
    }

    private func listedID(_ id: UUID) -> String {
        AgentChatShortID.listedIds(agentChats())[id] ?? AgentChatShortID.short(id)
    }

    private func resolveAgent(_ query: String) -> Result<UUID, AgentDeliveryError> {
        let chats = agentChats()
        switch AgentChatShortID.resolve(query, among: chats) {
        case .none: return .failure(.unknown(query))
        case let .match(id): return .success(id)
        case let .ambiguous(matches):
            let ids = AgentChatShortID.listedIds(chats)
            let candidates = matches.compactMap { id -> String? in
                guard let chat = entries[id]?.conversation, let listed = ids[id] else { return nil }
                return "\(listed) (\(chat.title))"
            }.sorted().joined(separator: ", ")
            return .failure(.ambiguous(query, candidates))
        }
    }

    private func sender(for id: UUID, kind: AgentMessageSender.Kind) -> AgentMessageSender? {
        entries[id].map { .init(id: AgentChatShortID.short(id), title: $0.conversation.title, kind: kind) }
    }

    func spawnAgentChat(from caller: UUID, brief: String, title: String, model: String? = nil, effort: String? = nil)
        -> Result<AgentSpawnResult, AgentSpawnError> {
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptyBrief) }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.emptyTitle) }
        guard !terminated, let entry = entries[caller], !closing.contains(caller) else { return .failure(.noWindow) }
        var ancestor = caller, depth = 0
        while let next = parent[ancestor] { depth += 1; ancestor = next }
        guard depth < 2 else { return .failure(.depth) }
        let parentConfig = entry.settings.config
        var config = parentConfig
        let scope = DrifterModel.spawnScope(parentConfig)
        if let model {
            guard let resolved = DrifterModel.spawnModel(model) else { return .failure(.unknownModel) }
            let allowed = switch scope {
            case .any: true
            case .gpt: resolved.engine == .codex
            case .own: resolved.engine == parentConfig.engine && resolved.model == parentConfig.model
            }
            guard allowed else { return .failure(.restricted(parentConfig)) }
            config.engine = resolved.engine; config.model = resolved.model
        }
        if let effort, scope == .own, effort != parentConfig.effort { return .failure(.restricted(parentConfig)) }
        let efforts = config.engine == .claude ? ClaudeCodeEffort.allCases.map(\.rawValue) : ["low", "medium", "high", "xhigh"]
        if let effort {
            guard efforts.contains(effort) else { return .failure(.invalidEffort(efforts)) }
            config.effort = effort
        } else if !efforts.contains(config.effort) {
            config.effort = config.engine == .claude ? "xhigh" : "medium"
        }
        config.folder = DrifterHome.current.folder
        guard let window = windowOfTab(entry.tabId) ?? entry.browserPreview?.windowId else { return .failure(.noWindow) }
        let parentSender = sender(for: caller, kind: .parent)
        var created: UUID?
        do {
            let child = try create(request: .init(prompt: brief, config: config, windowId: window,
                                                  sender: parentSender, parent: parentSender), tabId: -1)
            created = child.id
            parent[child.id] = caller
            child.manualTitle = title
            _ = try updateTitle(title, for: child.id)
            saveRecord(child.id)
            openChatTab(child.id, window)
            return .success(.init(id: listedID(child.id), title: child.title, engine: config.engine.rawValue,
                                  model: config.model, effort: config.effort))
        } catch {
            if let created { close(created) }
            return .failure(.creation(error.localizedDescription))
        }
    }

    func readAgent(_ query: String, lines: Int = 60) -> Result<(id: String, title: String, status: String, text: String), AgentDeliveryError> {
        guard (1...500).contains(lines) else { return .failure(.invalidLines) }
        return resolveAgent(query).map { id in
            let chat = entries[id]!.conversation
            let listing = agentListing(caller: id).first { $0.chatId == id }!
            return (listing.id, chat.title, listing.status, AgentChatTranscriptText.tail(chat.items, lines: lines))
        }
    }

    /// The nearest ancestor still open owns the family's folder: a child that outlived its parent starts its own.
    private func familyRoot(of id: UUID) -> UUID {
        var root = id
        while let ancestor = parent[root], entries[ancestor] != nil { root = ancestor }
        return root
    }

    /// A child Johnny took out of the family's folder outlives its parent's close and keeps its parent link.
    private func staysInFamilyFolder(_ id: UUID) -> Bool {
        guard let tabId = entries[id]?.tabId, tabId >= 0, tabExists(tabId) else { return true }
        return tabIsInFolder(tabId, entries[familyRoot(of: id)]?.browserFolder)
    }

    private func isDescendant(_ target: UUID, of caller: UUID) -> Bool {
        var id = target
        while let next = parent[id] {
            if next == caller { return true }
            id = next
        }
        return false
    }

    func stopAgent(_ query: String, from caller: UUID) -> Result<(id: String, stopped: Bool, status: String), AgentDeliveryError> {
        resolveAgent(query).flatMap { id in
            guard isDescendant(id, of: caller) else { return .failure(.descendantsOnly("stopped")) }
            let chat = entries[id]!.conversation
            let active = [.starting, .running, .awaitingPermission].contains(chat.status)
            let listing = agentListing(caller: caller).first { $0.chatId == id }!
            if active { chat.onStop?() }
            return .success((listing.id, active, listing.status))
        }
    }

    func closeAgent(_ query: String, from caller: UUID) -> Result<String, AgentDeliveryError> {
        resolveAgent(query).flatMap { id in
            guard isDescendant(id, of: caller) else { return .failure(.descendantsOnly("closed")) }
            let listed = listedID(id)
            closeWithTab(id)
            return .success(listed)
        }
    }

    private func pendingQuestion(_ items: [AgentChatItem]) -> AgentChatItem.PermissionRequest? {
        for item in items.reversed() {
            if case .userMessage = item.kind { break }
            if case .peerMessage = item.kind { break }
            if case let .permissionRequest(request) = item.kind, request.status == .pending, !request.questions.isEmpty { return request }
        }
        return nil
    }

    /// `hand_off`: the agent asks Johnny to do a step himself. The card shows above the composer (and in the Slack
    /// thread a Slack turn answers) until he presses Done or sends any message, which replaces it.
    func handOff(_ caller: UUID, message: String, tab: String?) -> String? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let conversation = entries[caller]?.conversation else { return nil }
        let tab = tab?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.setHandOff(.init(message: message, tab: tab?.isEmpty == false ? tab : nil))
        return "Johnny sees your message with a Done button. End your turn now: his “Done.” wakes you when he presses it, and if he sends a message instead, follow that."
    }

    func finishTask(_ caller: UUID, status: AgentTaskFinishStatus, message: String) -> Result<String, AgentFinishError> {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .failure(.emptyMessage) }
        let child = parent[caller] != nil
        guard child || isSlackThreadChat?(caller) == true else { return .failure(.notEligible) }
        if !child, !AgentChatTranscriptText.isSlackTurn(entries[caller]?.conversation.items ?? []) {
            return .failure(.notSlackTurn)
        }
        taskFinishes[caller] = .init(status: status, message: message)
        return .success(child
            ? "Mist sends this to your parent chat when this turn ends. End your turn now."
            : "Mist posts this to the Slack thread when this turn ends. End your turn now.")
    }

    private func reportChild(_ id: UUID, previous: AgentConversationStatus, status: AgentConversationStatus, items: [AgentChatItem], finish: AgentTaskFinish?) {
        guard !terminated, !closing.contains(id), let parentId = parent[id],
              entries[id] != nil, entries[parentId] != nil, !closing.contains(parentId) else { return }
        let body: String
        var kind = AgentMessageSender.Kind.report
        if status == .idle, previous == .running || previous == .awaitingPermission {
            guard let finish, !AgentChatTranscriptText.lastTurnStopped(items) else { return }
            body = finish.message
        } else if case let .failed(message) = status, [.starting, .running, .awaitingPermission].contains(previous) {
            body = "It stopped with an error: " + message
        } else if status == .awaitingPermission, let request = pendingQuestion(items),
                  reportedQuestions[id, default: []].insert(request.requestId).inserted {
            body = AgentChatTranscriptText.questions(request)
            kind = .question
        } else { return }
        deliverChildReport(id, parentId: parentId, body: body, kind: kind, taskStatus: status == .idle ? finish?.status : nil)
    }

    private func deliverChildReport(_ id: UUID, parentId: UUID, body: String, kind: AgentMessageSender.Kind, taskStatus: AgentTaskFinishStatus?) {
        guard var source = sender(for: id, kind: kind) else { return }
        source.taskStatus = taskStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.deliverMessage(.init(text: body, sender: source), to: parentId, prepare: {
                guard !self.terminated, self.parent[id] == parentId, !self.closing.contains(id),
                      self.entries[id] != nil, !self.closing.contains(parentId), let target = self.entries[parentId]?.conversation else { return nil }
                var count = 0
                for item in target.items.reversed() {
                    if case .userMessage = item.kind { break }
                    if case let .peerMessage(name, _) = item.kind,
                       name == source.label || name.hasPrefix(source.id + " ") { count += 1 }
                }
                guard count < 20 else { return nil }
                var sender = source
                if count == 19 { sender.kind = .report; sender.reportsPaused = true }
                return .init(text: body, sender: sender)
            })
        }
    }

    private func closeWithTab(_ id: UUID) {
        guard let entry = entries[id], !closing.contains(id) else { return }
        // Mark before calling Chromium: a synchronous close callback must not reenter the cascade.
        closing.insert(id)
        if entry.tabId >= 0 {
            closeChatTab(entry.tabId)
            collapsePanels(showing: id)
        }
        closing.remove(id)
        close(id)
    }

    /// A chat's own tab closed: the Chat panels showing it close too.
    private func collapsePanels(showing id: UUID) {
        for (host, chat) in panelChats where chat == id && tabExists(host) { collapsePanel(host) }
    }

    private func resumeId(of entry: Entry) -> String? {
        if let session = entry.session as? any AgentChatSession { return session.resumeId }
        if let session = entry.session as? DrifterSession { return session.resumeId }
        return entry.restoredSessionId
    }

    func saveRecord(_ id: UUID, synchronously: Bool = false) {
        guard let entry = entries[id] else { return }
        let conversation = entry.conversation
        let record = AgentChatRecord(title: conversation.title, background: placeholderStyle(entry.config.engine).background,
            drifter: entry.settings.config, sessionId: resumeId(of: entry),
            items: conversation.items, queued: ([conversation.unsent].compactMap { $0 } + conversation.queue).map(\.draftText), draft: conversation.draft.text,
            contextTokens: conversation.contextTokens, contextWindowSize: conversation.contextWindowSize,
            memoryFolders: conversation.memoryFolders.map(\.path), skillFolders: conversation.skillFolders.map(\.path), autoTitle: conversation.autoTitle,
            manualTitle: conversation.manualTitle, pendingSessionTitle: conversation.pendingSessionTitle,
            markers: conversation.markers, handOff: conversation.handOff)
        let write = { [route] in
            do { try route.writeRecord(record, for: id) }
            catch { NSLog("Couldn't save agent chat %@: %@", id.uuidString, error.localizedDescription) }
        }
        if synchronously { recordQueue.sync(execute: write) }
        else { recordQueue.async(execute: DispatchWorkItem(block: write)) }
    }

    func canRestore(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: route.recordURL(for: id).path) }

    /// Rebuilds a chat from its file without launching its agent; its first message does, through `restart`.
    @discardableResult
    func restoreIfNeeded(_ id: UUID, tabId: Int) -> Bool {
        if let entry = entries[id] {
            if entry.tabId != tabId, !tabExists(entry.tabId) { assign(id, to: tabId) }
            return true
        }
        guard !terminated, let record = route.readRecord(for: id) else { return false }
        let conversation = AgentConversation(id: id)
        conversation.autoTitle = record.autoTitle ?? record.title
        conversation.manualTitle = record.manualTitle
        conversation.title = conversation.manualTitle ?? conversation.autoTitle
        conversation.pendingSessionTitle = record.pendingSessionTitle
        conversation.setDraft(.init(text: (record.queued + [record.draft]).filter { !$0.isEmpty }.joined(separator: "\n")))
        conversation.contextTokens = record.contextTokens
        conversation.contextWindowSize = record.contextWindowSize
        conversation.memoryFolders = (record.memoryFolders ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        conversation.skillFolders = (record.skillFolders ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        connectTitle(conversation)
        let resume = AgentChatResume(sessionId: record.sessionId, items: record.items.map(\.settled))
        conversation.update(items: resume.items, status: .dormant)
        conversation.restoreMarkers(record.markers ?? [])
        conversation.setHandOff(record.handOff)
        register(Entry(conversation: conversation,
                       settings: DrifterSettings(config: record.drifter, running: !record.items.isEmpty || record.sessionId != nil), tabId: tabId,
                       session: nil, restoredSessionId: record.sessionId))
        return true
    }

    /// A failed or restored chat's next message launches its agent on the saved session, then sends it.
    /// The chat keeps its conversation and settings objects, which its views stay bound to.
    func restart(_ id: UUID, prompt: String, attachments: [AgentAttachment], mentions: [AgentTabMention], sender: AgentMessageSender? = nil) {
        guard !terminated, let entry = entries[id], entry.conversation.status.launchesOnSend else { return }
        if entry.conversation.items.isEmpty, resumeId(of: entry) == nil {
            let title = AgentChatRoute.title(for: AgentMentionText(text: prompt, mentions: mentions).normalized.text, attachments: attachments)
            entry.conversation.autoTitle = title
            if entry.conversation.manualTitle == nil { _ = try? updateTitle(title, for: id) }
        }
        let settings = entry.settings
        // A chat only a panel shows launches in its host's window.
        let panelWindow = panelChats.first { $0.value == id }.flatMap { windowOfTab($0.key) }
        guard let windowId = windowOfTab(entry.tabId) ?? panelWindow ?? (entry.session as? DrifterSession)?.windowId else { return }
        let request = DrifterLaunchRequest(prompt: prompt, attachments: attachments, config: settings.config, windowId: windowId,
            mentions: mentions, sender: sender, parent: parent[id].flatMap { self.sender(for: $0, kind: .parent) },
            slackThread: isSlackThreadChat?(id) == true,
            resume: .init(sessionId: resumeId(of: entry), items: entry.conversation.items.map(\.settled)))
        guard var replacement = try? browserEntry(request: request, conversation: entry.conversation, tabId: entry.tabId,
                                                  settings: settings) else { return }
        replacement.browserFolder = entry.browserFolder
        withExtendedLifetime(entry.session) { register(replacement) }
        // A chat only a panel showed gets its own tab once it runs, like one the panel's composer launched.
        if detached.remove(id) != nil { openChatTab(id, windowId) }
    }

    func agent(for id: UUID) -> DrifterEngine {
        if let entry = entries[id] { return entry.settings.config.engine }
        if let stored = storedAgents[id] { return stored }
        let stored = route.storedAgent(for: id) ?? .claude
        storedAgents[id] = stored
        return stored
    }

    func browserChat(principalId: String?) -> UUID? {
        guard let principalId else { return nil }
        return entries.first { $0.value.browserPreview?.principalId == principalId }?.key
    }

    /// A turn holds only a tab its agent has reported in that turn: a tab from
    /// an earlier turn may have sat in the background for hours.
    func activeBrowserPreviews(windowId: Int) -> [BrowserAgentPreviewState] {
        entries.values.compactMap(\.browserPreview)
            .filter { $0.windowId == windowId && $0.turnActive && $0.workedThisTurn && $0.tabId != nil }
            .sorted { $0.reportOrder < $1.reportOrder }
    }

    @discardableResult
    func reportWorkingTab(principalId: String?, tabId: Int?, live: Bool) -> Bool {
        guard let id = browserChat(principalId: principalId),
              var preview = entries[id]?.browserPreview,
              preview.report(principal: principalId, tabId: tabId, live: live, now: now()) else { return false }
        workingTabReportOrder &+= 1
        preview.reportOrder = workingTabReportOrder
        objectWillChange.send()
        entries[id]?.browserPreview = preview
        entries[id]?.browserFolder?.report(tabId: tabId, now: now())
        armBrowserPreviewExpiry()
        notifyBrowserPreviewChanged(windowId: preview.windowId)
        return true
    }

    /// A presentation choice, recorded without refreshing every chat observer.
    func setBrowserPreviewCardAspect(_ id: UUID, aspect: CGFloat) {
        guard entries[id]?.browserPreview?.cardAspect == nil else { return }
        entries[id]?.browserPreview?.cardAspect = aspect
    }

    func dismissBrowserPreview(_ id: UUID, tabId: Int) {
        guard var preview = entries[id]?.browserPreview else { return }
        preview.dismiss(tabId: tabId)
        guard entries[id]?.browserPreview != preview else { return }
        objectWillChange.send()
        entries[id]?.browserPreview = preview
        armBrowserPreviewExpiry()
        notifyBrowserPreviewChanged(windowId: preview.windowId)
    }

    func browserPreviewCardTabs(windowId: Int) -> Set<Int> {
        Set(entries.values.compactMap(\.browserPreview).filter { $0.windowId == windowId }
            .flatMap { $0.cards.map(\.tabId) })
    }

    /// Closes each chat's own tab once the chat has sat idle and unattended for `idleLifetime`, like a folder tab.
    /// Closing keeps the chat's files: a later message restores it like any closed chat.
    func closeTabsWhenIdle(_ ids: [UUID]) {
        guard !terminated else { return }
        idleClosingChats.formUnion(ids)
        if ids.contains(where: { entries[$0] == nil }) {
            for tab in chatTabs() where ids.contains(tab.chatId) && entries[tab.chatId] == nil {
                restoreIfNeeded(tab.chatId, tabId: tab.tabId)
            }
        }
        scheduleIdleTabRefresh()
    }

    func idleTab(for id: UUID) -> AgentChatIdleTab? { idleTabs[id] }

    #if MIST_CLAUDE_CODE_HOSTLESS_TESTS
    private func isTabShown(_ tabId: Int) -> Bool { isTabActive(tabId) }
    #endif

    private static func isWorking(_ status: AgentConversationStatus) -> Bool {
        status == .starting || status == .running || status == .awaitingPermission
    }

    private func hasWorkingChild(_ id: UUID) -> Bool {
        parent.contains { child, owner in
            owner == id && (entries[child].map { Self.isWorking($0.conversation.status) } == true || hasWorkingChild(child))
        }
    }

    /// A turn, a card or question, a hand-off waiting for Done, queued messages, a background task or a working child holds the chat; the user
    /// holds its tab by showing it, drafting in it or mounting the chat in a tab's Chat panel.
    private func isIdleTabHeld(_ id: UUID, entry: Entry) -> Bool {
        let chat = entry.conversation
        return Self.isWorking(chat.status) || !chat.queue.isEmpty || chat.unsent != nil || !chat.backgroundTasks.isEmpty || chat.handOff != nil
            || !chat.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.draft.attachments.isEmpty
            || isTabShown(entry.tabId) || panelHost(of: id) != nil || hasWorkingChild(id)
    }

    private func refreshIdleTabs() {
        let date = now()
        for id in idleClosingChats {
            guard let entry = entries[id], entry.tabId >= 0, tabExists(entry.tabId) else { idleTabs[id] = nil; continue }
            guard !tabIsKept(entry.tabId) else {
                idleClosingChats.remove(id); idleTabs[id] = nil
                continue
            }
            idleTabs[id, default: .init()].update(held: isIdleTabHeld(id, entry: entry), now: date)
        }
    }

    /// `$status` publishes before it stores the value, so the clocks read every chat once the change has landed.
    private func scheduleIdleTabRefresh() {
        guard !terminated, !idleClosingChats.isEmpty, !idleTabRefreshScheduled else { return }
        idleTabRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.idleTabRefreshScheduled = false
            guard !self.terminated else { return }
            self.refreshIdleTabs()
            self.armBrowserPreviewExpiry()
        }
    }

    private func closeIdleTabs() {
        refreshIdleTabs()
        let date = now()
        for (id, idle) in idleTabs {
            guard let deadline = idle.deadline, date >= deadline, let tabId = entries[id]?.tabId else { continue }
            idleTabs[id] = nil
            closeChatTab(tabId)
        }
    }

    private func armBrowserPreviewExpiry() {
        browserPreviewExpiryTimer?.invalidate()
        browserPreviewExpiryTimer = nil
        guard !terminated else { browserPreviewExpiryDeadline = nil; return }
        var deadlines = entries.values.compactMap { $0.browserPreview?.nextExpiry }
        deadlines += idleTabs.values.compactMap(\.deadline)
        for entry in entries.values {
            guard let folder = entry.browserFolder else { continue }
            #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
            let excluded = visibleFolderTabs(windowId: folder.windowId)
            #else
            let excluded = Set<Int>()
            #endif
            if let deadline = folder.nextExpiry(excluding: excluded) { deadlines.append(deadline) }
        }
        browserPreviewExpiryDeadline = deadlines.min()
        guard let deadline = browserPreviewExpiryDeadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireBrowserPreviewCards() }
        }
        timer.tolerance = 3
        browserPreviewExpiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func expireBrowserPreviewCards() {
        let date = now()
        var windows = Set<Int>()
        for id in Array(entries.keys) {
            guard var preview = entries[id]?.browserPreview, preview.expire(now: date) else { continue }
            entries[id]?.browserPreview = preview
            windows.insert(preview.windowId)
        }
        if !windows.isEmpty { objectWillChange.send() }
        windows.forEach { notifyBrowserPreviewChanged(windowId: $0) }
        #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
        expireBrowserFolderTabs()
        #endif
        closeIdleTabs()
        armBrowserPreviewExpiry()
    }

    private func invalidateBrowserPreview(principalId: String) {
        guard let id = browserChat(principalId: principalId), let preview = entries[id]?.browserPreview else { return }
        objectWillChange.send()
        entries[id]?.browserPreview = nil
        armBrowserPreviewExpiry()
        notifyBrowserPreviewChanged(windowId: preview.windowId)
    }

    private func notifyBrowserPreviewChanged(windowId: Int) {
        NotificationCenter.default.post(name: .browserAgentPreviewDidChange, object: self,
                                        userInfo: ["windowId": windowId])
    }

    @discardableResult
    func updateTitle(_ title: String, for id: UUID) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let entry = entries[id], entry.conversation.title != title else { return false }
        try writePlaceholder(id, title: title, engine: entry.config.engine)
        entry.conversation.title = title
        reloadTab(entry.tabId, title)
        return true
    }

    func rename(_ id: UUID, to rawName: String, tabId: Int) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard restoreIfNeeded(id, tabId: tabId), let entry = entries[id] else {
            guard route.storedTitle(for: id) != nil else { return }
            do {
                try writePlaceholder(id, title: name, engine: agent(for: id))
                reloadTab(tabId, name)
            } catch { NSLog("Couldn't rename agent chat %@: %@", id.uuidString, error.localizedDescription) }
            return
        }
        let conversation = entry.conversation
        conversation.manualTitle = name.isEmpty ? nil : name
        let title = conversation.manualTitle ?? conversation.autoTitle
        do { _ = try updateTitle(title, for: id) }
        catch { NSLog("Couldn't rename agent chat %@: %@", id.uuidString, error.localizedDescription) }
        if entry.settings.config.engine == .claude {
            conversation.pendingSessionTitle = title
            let session = (entry.session as? ClaudeCodeSession)
                ?? (entry.session as? DrifterSession)?.engine as? ClaudeCodeSession
            session?.sendPendingTitle()
        }
        saveRecord(id, synchronously: true)
    }

    func assign(_ id: UUID, to tabId: Int) {
        let changed = entries[id].map { $0.tabId != tabId } ?? false
        entries[id]?.tabId = tabId
        if tabId >= 0 { detached.remove(id) }
        if let status = entries[id]?.conversation.status { updateParentPreview(for: id, status: status) }
        scheduleIdleTabRefresh()
        if changed { objectWillChange.send() }
    }

    private func updateParentPreview(for id: UUID, status: AgentConversationStatus, insertIfMissing: Bool = true) {
        guard let parentId = parent[id], let entry = entries[id], entry.tabId >= 0,
              var preview = entries[parentId]?.browserPreview else { return }
        preview.upsertChild(id, tabId: entry.tabId,
            working: [.starting, .running, .awaitingPermission].contains(status), now: now(), insertIfMissing: insertIfMissing)
        guard preview != entries[parentId]?.browserPreview else { return }
        objectWillChange.send()
        entries[parentId]?.browserPreview = preview
        notifyBrowserPreviewChanged(windowId: preview.windowId)
        armBrowserPreviewExpiry()
    }

    func markSeen(tabId: Int) {
        for (id, entry) in entries where entry.tabId == tabId {
            unseenCompletions.remove(id)
        }
    }

    /// `url` is the closed tab's: a chat tab a relaunch restored has no entry until it shows.
    func tabDidClose(_ tabId: Int, url: String? = nil) {
        guard !terminated else { return }
        if let id = route.conversationId(for: url), entries[id] == nil { deleteUnloadedChatIfEmpty(id) }
        setPanelChat(nil, for: tabId)
        if panelHistory.removeValue(forKey: tabId) != nil { objectWillChange.send() }
        var previewWindows = Set<Int>()
        for id in Array(entries.keys) {
            entries[id]?.browserFolder?.remove(tabId)
            guard var preview = entries[id]?.browserPreview,
                  preview.tabId == tabId || preview.cards.contains(where: { $0.tabId == tabId }) else { continue }
            preview.removeTab(tabId)
            entries[id]?.browserPreview = preview
            previewWindows.insert(preview.windowId)
        }
        if !previewWindows.isEmpty { objectWillChange.send() }
        previewWindows.forEach { notifyBrowserPreviewChanged(windowId: $0) }
        armBrowserPreviewExpiry()
        guard entries.values.contains(where: { $0.tabId == tabId }) else { return }
        pendingCloses[tabId]?.cancel()
        pendingCloses[tabId] = Task { [weak self, closeDelay] in
            do { try await Task.sleep(nanoseconds: closeDelay) } catch { return }
            self?.closeIfTabIsGone(tabId)
            self?.pendingCloses[tabId] = nil
        }
    }

    /// An empty chat closed unshown goes once no tab shows it after the close delay (⌘⇧T brings it
    /// back). The record on disk decides emptiness, so a chat with messages is never deleted.
    private func deleteUnloadedChatIfEmpty(_ id: UUID) {
        Task { [weak self, closeDelay] in
            do { try await Task.sleep(nanoseconds: closeDelay) } catch { return }
            guard let self, !self.terminated, self.entries[id] == nil,
                  !self.chatTabs().contains(where: { $0.chatId == id }) else { return }
            if self.recordQueue.sync(execute: { self.route.deleteEmptyChat(id) }) { self.storedAgents[id] = nil }
        }
    }

    func windowWillClose() {
        guard !terminated else { return }
        pendingWindowClose?.cancel()
        pendingWindowClose = Task { [weak self, closeDelay] in
            do { try await Task.sleep(nanoseconds: closeDelay) } catch { return }
            guard let self else { return }
            for tabId in Set(self.entries.values.map(\.tabId).filter { $0 >= 0 }) { self.closeIfTabIsGone(tabId) }
            for host in self.panelHistory.keys where !self.tabExists(host) { self.tabDidClose(host) }
            self.pendingWindowClose = nil
        }
    }

    func clear(_ id: UUID) throws {
        guard !terminated, let entry = entries[id] else { return }
        let config = entry.config
        let fresh = try createEmpty(config: config, tabId: entry.tabId)
        fresh.memoryFolders = entry.conversation.memoryFolders
        fresh.skillFolders = entry.conversation.skillFolders
        parent[fresh.id] = parent[id]
        if detached.contains(id) { detached.insert(fresh.id) }
        if let host = panelHost(of: id) { setPanelChat(fresh.id, for: host) }
        navigateTab(entry.tabId, route.placeholderURL(for: fresh.id))
        close(id)
        assign(fresh.id, to: entry.tabId)
        onChatReplaced?(id, fresh.id)
    }

    func closeIfTabIsGone(_ tabId: Int) {
        guard !terminated, !tabExists(tabId) else { return }
        for id in entries.keys.filter({ entries[$0]?.tabId == tabId }) {
            // Another tab still showing the chat (Duplicate Tab) becomes its own.
            if let other = otherTab(showing: id, besides: tabId) {
                assign(id, to: other)
                continue
            }
            collapsePanels(showing: id)
            if isEmpty(id), shownByPanel(id) {
                // An empty chat stays while a panel still shows it.
                entries[id]?.tabId = -1
                detached.insert(id)
                scheduleIdleTabRefresh()
            } else { close(id) }
        }
    }

    private func close(_ id: UUID) {
        guard entries[id] != nil, closing.insert(id).inserted else { return }
        defer { closing.remove(id) }
        // A panel or another tab still showing the chat holds it; `/clear` there has already moved the panel to the fresh chat.
        let deletes = !terminated && isEmpty(id) && !shownByPanel(id)
            && otherTab(showing: id, besides: entries[id]?.tabId ?? -1) == nil
        detached.remove(id)
        panelNewChats.remove(id)
        for child in parent.compactMap({ $0.value == id ? $0.key : nil }) where staysInFamilyFolder(child) { closeWithTab(child) }
        if let parentId = parent[id], let tabId = entries[id]?.tabId {
            dismissBrowserPreview(parentId, tabId: tabId)
        }
        parent[id] = nil
        reportedQuestions[id] = nil
        taskFinishes[id] = nil
        saveRecord(id, synchronously: true)
        recordBindings[id] = nil
        engineBindings[id] = nil
        entries[id]?.conversation.onDraftChange = nil
        entries[id]?.conversation.onClear = nil
        for host in Array(panelHistory.keys) {
            panelHistory[host]?.removeAll { $0 == id }
            if panelChats[host] == id { panelChats[host] = panelHistory[host]?.last }
        }
        visiblePanels = visiblePanels.filter { $0.value != id }
        statusBindings[id] = nil
        idleTabs[id] = nil
        unseenCompletions.remove(id)
        if let entry = entries.removeValue(forKey: id) {
            #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
            if let folder = entry.browserFolder, let state = folderWindow(folder.windowId),
               state.groups[folder.token] != nil {
                if folder.borrowed {
                    for tab in state.tabs where folder.members[tab.guid] != nil && tab.groupToken == folder.token {
                        tab.close()
                    }
                } else {
                    state.closeTabGroup(token: folder.token, intent: .tabDriven)
                }
            }
            #endif
            withExtendedLifetime(entry.session) { entry.conversation.onClose?() }
            if let preview = entry.browserPreview { notifyBrowserPreviewChanged(windowId: preview.windowId) }
        }
        if deletes {
            if !recordQueue.sync(execute: { route.deleteEmptyChat(id) }) {
                NSLog("Refused to delete empty agent chat %@", id.uuidString)
            }
            storedAgents[id] = nil
        }
        armBrowserPreviewExpiry()
        scheduleIdleTabRefresh()
        objectWillChange.send()
    }

    func terminate() {
        terminated = true
        browserPreviewExpiryTimer?.invalidate()
        browserPreviewExpiryTimer = nil
        browserPreviewExpiryDeadline = nil
        for id in entries.keys { saveRecord(id, synchronously: true) }
        // Panel links don't survive a relaunch, so nothing would show these again.
        for id in detached where isEmpty(id) {
            if !recordQueue.sync(execute: { route.deleteEmptyChat(id) }) {
                NSLog("Refused to delete empty agent chat %@", id.uuidString)
            }
        }
        detached.removeAll()
        recordBindings.removeAll()
        engineBindings.removeAll()
        for entry in entries.values { entry.conversation.onDraftChange = nil }
        pendingWindowClose?.cancel()
        pendingWindowClose = nil
        let previewWindows = Set(entries.values.compactMap { $0.browserPreview?.windowId })
        #if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
        tabBindings.removeAll()
        #endif
        pendingCloses.values.forEach { $0.cancel() }
        pendingCloses.removeAll()
        for entry in entries.values {
            if let session = entry.session as? any AgentChatSession { session.terminateNow() }
            else if let session = entry.session as? DrifterSession { session.terminateNow() }
            else { entry.conversation.onClose?() }
        }
        entries.removeAll()
        idleClosingChats.removeAll()
        idleTabs.removeAll()
        parent.removeAll()
        reportedQuestions.removeAll()
        taskFinishes.removeAll()
        panelChats.removeAll()
        panelHistory.removeAll()
        visiblePanels.removeAll()
        objectWillChange.send()
        previewWindows.forEach { notifyBrowserPreviewChanged(windowId: $0) }
        statusBindings.removeAll()
        unseenCompletions.removeAll()
    }

    deinit {
        browserPreviewExpiryTimer?.invalidate()
        pendingWindowClose?.cancel()
        pendingCloses.values.forEach { $0.cancel() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
