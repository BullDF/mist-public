import AppKit
import Combine
import SwiftUI

/// A page's panel is a second view of a session owned by its separate chat tab.
final class MistChatPanelViewController: NSViewController {
    private weak var browserState: BrowserState?
    private(set) weak var associatedTab: Tab?
    private let store: AgentChatStore
    private let panelId = UUID()
    private var subscription: AnyCancellable?
    private var defaultsSubscription: AnyCancellable?
    private var launchFocusSubscription: AnyCancellable?
    private var launchInteractionMonitor: Any?
    private var launchFocusToken: UUID?
    /// Open as Tab waiting for New Chat's tab to arrive.
    private var tabSelection: AnyCancellable?
    private let saved: DrifterLaunchSettings
    private var expanded = false
    private var appeared = false
    private var shownId: UUID?
    private var launchHostId: Int?
    private let content = NSView()
    private var header: MistKitHostingView?
    private var emptyLogo: ThemedHostingView?
    let launchComposer = AgentChatComposer()
    private(set) var chatController: AgentChatViewController?
    var composer: AgentChatComposer { chatController?.composer ?? launchComposer }

    init(with state: BrowserState, tab: Tab? = nil, store: AgentChatStore? = nil,
         saved: DrifterLaunchSettings = .init()) {
        browserState = state
        associatedTab = tab
        self.store = store ?? .shared
        self.saved = saved
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let launchInteractionMonitor { NSEvent.removeMonitor(launchInteractionMonitor) }
        let store = store
        let panelId = panelId
        Task { @MainActor in store.setPanelVisible(nil, panelId: panelId) }
    }

    override func loadView() { view = NSView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        content.wantsLayer = true
        content.layer?.cornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.phiLayer?.setBorderColor(.border)
        // Always opaque, including when a content surface is installed behind the page.
        content.phiLayer?.setBackgroundColor(.windowBackground)
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -CGFloat(WebContentConstant.contentEdgeSpacing)),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: CGFloat(WebContentConstant.contentEdgeSpacing)),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -CGFloat(WebContentConstant.contentEdgeSpacing)),
        ])
        launchComposer.onLaunch = { [weak self] in self?.launch(text: $0, attachments: $1, mentions: $2) ?? false }
        launchComposer.onClearWithoutChat = { [weak self] in self?.resetLaunchComposer() }
        observeFocus(in: launchComposer)
        launchComposer.editor.mentionTabs = { [weak self] in
            self?.browserState?.tabs.filter { MistApps.address($0.url) == nil } ?? []
        }
        launchComposer.editor.mentionGroups = { [weak self] in self?.browserState?.agentMentionGroups ?? [] }
        launchComposer.editor.currentTab = { [weak self] in self?.associatedTab }
        subscription = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }
        defaultsSubscription = NotificationCenter.default.publisher(for: .drifterLaunchSettingsDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func updateAssociatedTab(_ tab: Tab) {
        guard associatedTab !== tab else { return }
        cancelLaunchFocus()
        associatedTab = tab
        if isViewLoaded { refresh() }
    }

    func setExpanded(_ value: Bool) {
        if !value { cancelLaunchFocus() }
        let opening = value && !expanded
        expanded = value
        _ = view
        refresh()
        // Pick up Drifter defaults changed on a New Tab Page.
        if opening, shownId == nil { launchComposer.browserLaunchRow?.reload() }
        if opening { insertHostMention() }
        reportVisibility()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        setPresented(true)
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        setPresented(false)
    }
    func setPresented(_ value: Bool) {
        if !value { cancelLaunchFocus() }
        appeared = value
        reportVisibility()
    }
    private func reportVisibility() {
        store.setPanelVisible(expanded && appeared ? shownId : nil, panelId: panelId)
    }

    /// Only a new chat gets the host tab's mention: the launch composer, or a chat /clear started.
    /// An app tab (Mail) gets no mention: agents can't use app tabs.
    private func insertHostMention() {
        guard let tab = associatedTab, MistApps.address(tab.url) == nil,
              shownId.map({ store.conversation(for: $0)?.isNew == true }) ?? true else { return }
        composer.editor.insertMentionIfEmpty(for: tab)
    }

    func focusAIChat() {
        guard browserState?.windowController?.isPresentedOrLegacy ?? true else { return }
        // A chat shown this turn mounts its composer in the hosting view's next layout pass.
        if composer.editor.textView.window == nil { view.layoutSubtreeIfNeeded() }
        view.window?.makeFirstResponder(composer.editor.textView)
        associatedTab?.updateFocusTarget(.aiChat)
    }

    private func observeFocus(in composer: AgentChatComposer) {
        composer.editor.onFocusChange = { [weak self] focused in
            if focused { self?.associatedTab?.updateFocusTarget(.aiChat) }
        }
    }

    /// Shows a new empty chat with its own background tab, which has its ID before its first message; a draft on the
    /// new-chat screen moves into it.
    func newChat() {
        cancelLaunchFocus()
        guard let state = browserState, let tab = associatedTab, !state.isIncognito, !state.isAgentSpace else { return }
        let draft = shownId == nil
            ? AgentComposerDraft(text: launchComposer.editor.text, mentions: launchComposer.editor.mentions,
                                 attachments: launchComposer.attachments)
            : AgentComposerDraft()
        do {
            let chat = try store.createPanelChat(for: tab.guid)
            chat.setDraft(draft)
        } catch {
            NSLog("Couldn't create a panel chat: %@", error.localizedDescription)
            return
        }
        launchComposer.applyLaunchDraft(AgentComposerDraft())
        MistSidebarAgentSections.setExpanded(true)
        refresh()
        insertHostMention()
        focusAIChat()
    }

    /// `/clear` on the new-chat screen: the composer is already a new chat.
    private func resetLaunchComposer() {
        cancelLaunchFocus()
        insertHostMention()
        focusAIChat()
    }

    func closeChat() {
        cancelLaunchFocus()
        tabSelection = nil
        guard let id = shownId else { return }
        store.closeChat(id)
    }

    /// On the new-chat screen, New Chat first.
    func openAsTab() {
        tabSelection = nil
        if shownId == nil { newChat() }
        guard let id = shownId, let entry = store.entry(for: id) else { return }
        let tab = Self.tab(entry.tabId, in: browserState)
        guard let tab else {
            guard entry.tabId < 0, let state = browserState else { return }
            if store.isOpeningTab(for: id) {
                // New Chat's tab is on its way.
                tabSelection = store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
                    guard let self, let tabId = self.store.entry(for: id)?.tabId, tabId >= 0 else { return }
                    self.tabSelection = nil
                    Self.tab(tabId, in: self.browserState)?.makeSelfActive()
                }
                return
            }
            // Its own tab closed while this panel showed it.
            let url = store.route.placeholderURL(for: id).absoluteString
            store.bindNextTab(id, in: state, url: url)
            state.createTab(url)
            return
        }
        tab.makeSelfActive()
    }

    private static func tab(_ id: Int, in state: BrowserState?) -> Tab? {
        state?.tabs.first { $0.guid == id }
            ?? SpaceSessionControllersManager.shared.getAllWindows().flatMap { $0.browserState.tabs }.first { $0.guid == id }
    }

    private static var originPanelOpening: AnyCancellable?

    /// What Switch Between Chat Panel and Tab does in a window.
    enum PanelTabSwitch: Equatable {
        case showInPanel(chatId: UUID)
        case mountToTab(chatTabId: Int)
        case openAsTab(hostTabId: Int)
    }

    /// Pure decision, so a test can drive it with a store.
    static func panelTabSwitch(focusedTabId: Int?, focusedChatId: UUID?, panelOpen: Bool,
                               store: AgentChatStore) -> PanelTabSwitch? {
        if let id = focusedChatId, store.entry(for: id) != nil {
            if store.panelHost(of: id) != nil { return .showInPanel(chatId: id) }
            // A chat tab has no Chat panel of its own, so an unmounted one offers its Mount to Tab picker.
            if let tabId = focusedTabId { return .mountToTab(chatTabId: tabId) }
        }
        // On the new-chat screen, Open as Tab runs New Chat first.
        if let host = focusedTabId, panelOpen {
            return .openAsTab(hostTabId: host)
        }
        return nil
    }

    static func panelTabSwitch(in state: BrowserState, store: AgentChatStore? = nil) -> PanelTabSwitch? {
        let tab = state.focusingTab
        return panelTabSwitch(focusedTabId: tab?.guid, focusedChatId: tab?.appAddress?.chatId,
                              panelOpen: state.canShowChatPanel(for: tab) && tab?.aiChatCollapsed == false,
                              store: store ?? .shared)
    }

    @discardableResult
    static func performPanelTabSwitch(in controller: SpaceSessionController, store: AgentChatStore? = nil) -> Bool {
        switch panelTabSwitch(in: controller.browserState, store: store) {
        case let .showInPanel(id):
            showInOriginPanel(id, store: store)
        case let .mountToTab(chatTabId):
            let page = controller.mainSplitViewController.webContentContainerViewController
                .findController(forTabId: chatTabId)?.appPageController as? AgentChatViewController
            return page?.showMountPicker() == true
        case let .openAsTab(host):
            controller.mainSplitViewController.webContentContainerViewController
                .findController(forTabId: host)?.openPanelChatAsTab()
        case nil:
            return false
        }
        return true
    }

    /// The host of the panel View ▸ Close Chat acts on: the focused tab, while its Chat panel is open on a chat.
    static func closeChatHost(in state: BrowserState, store: AgentChatStore? = nil) -> Int? {
        guard let tab = state.focusingTab, state.canShowChatPanel(for: tab), !tab.aiChatCollapsed,
              (store ?? .shared).hasPanelChat(tab.guid) else { return nil }
        return tab.guid
    }

    @discardableResult
    static func performCloseChat(in controller: SpaceSessionController) -> Bool {
        guard let host = closeChatHost(in: controller.browserState) else { return false }
        controller.mainSplitViewController.webContentContainerViewController
            .findController(forTabId: host)?.closePanelChat()
        return true
    }

    /// The reverse of Open as Tab: selects the tab whose panel started a chat or that it was mounted to, in any window
    /// or Space, and opens its panel on that chat.
    static func showInOriginPanel(_ id: UUID, store: AgentChatStore? = nil) {
        let store = store ?? .shared
        guard let hostId = store.panelHost(of: id),
              let controller = SpaceSessionControllersManager.shared.getAllWindows()
                .first(where: { $0.browserState.tabs.contains { $0.guid == hostId } }),
              let tab = controller.browserState.tabs.first(where: { $0.guid == hostId }) else { return }
        store.setPanelChat(id, for: hostId)
        controller.selectTab(tab) { [weak state = controller.browserState] in
            guard let state else { return }
            // Chromium reports the selection later; the panel opens and takes focus once the tab is the window's.
            originPanelOpening = state.$focusingTab.first { $0 === tab }
                .timeout(.seconds(2), scheduler: DispatchQueue.main)
                .sink { _ in } receiveValue: { [state] _ in
                    DispatchQueue.main.async { [weak state] in
                        guard let state, state.focusingTab === tab else { return }
                        state.toggleAIChat(false)
                    }
                }
        }
    }

    func showChat(_ id: UUID) {
        guard let tab = associatedTab, store.panelChatHistory(for: tab.guid).contains(where: { $0.id == id }) else { return }
        store.setPanelChat(id, for: tab.guid)
        refresh()
        focusAIChat()
    }

    private func configureLaunchComposer() {
        launchComposer.configureLaunch(saved: saved)
        launchComposer.browserLaunchRow?.refreshModels()
    }

    private func headerContent(id: UUID?, host: Tab) -> MistChatPanelHeader {
        MistChatPanelHeader(conversation: id.flatMap { store.conversation(for: $0) },
            history: store.panelChatHistory(for: host.guid), select: { [weak self] in self?.showChat($0) },
            jump: { [weak self] in self?.chatController?.revealMarker($0) },
            open: { [weak self] in self?.openAsTab() }, closeChat: { [weak self] in self?.closeChat() },
            new: { [weak self] in self?.newChat() }, close: { [weak self] in
                guard let self, let tab = self.associatedTab else { return }
                self.browserState?.setAIChatCollapsed(for: tab, collapsed: true)
            })
    }

    private func launch(text: String, attachments: [AgentAttachment], mentions: [AgentTabMention]) -> Bool {
        guard let state = browserState, let tab = associatedTab,
              !state.isIncognito, !state.isAgentSpace else { return false }
        let start: () throws -> AgentConversation
        guard let settings = launchComposer.browserLaunchRow?.settings else { return false }
        start = { [store] in
            try store.launchBrowserChat(prompt: text, attachments: attachments, mentions: mentions,
                config: settings.config, in: state, tabId: -1, createBackgroundTab: true)
        }
        cancelLaunchFocus()
        let token = UUID()
        launchFocusToken = token
        // A deliberate click or keystroke after Submit ends this launch's
        // focus handoff, even if the background tab has not arrived yet.
        launchInteractionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            self?.cancelLaunchFocus()
            return event
        }
        do {
            let conversation = try start()
            store.setPanelChat(conversation.id, for: tab.guid)
            refresh()
            focusAIChat()
            launchFocusSubscription = state.$tabs.receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.launchFocusToken == token,
                      (self.store.entry(for: conversation.id)?.tabId ?? -1) >= 0 else { return }
                // Let the new tab's sidebar and content observers finish first.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.launchFocusToken == token else { return }
                    self.cancelLaunchFocus()
                    guard self.expanded, self.associatedTab === tab, self.shownId == conversation.id,
                          self.view.window?.isKeyWindow == true else { return }
                    self.focusAIChat()
                }
            }
            return true
        } catch {
            cancelLaunchFocus()
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
            return false
        }
    }

    private func cancelLaunchFocus() {
        launchFocusToken = nil
        launchFocusSubscription = nil
        if let launchInteractionMonitor { NSEvent.removeMonitor(launchInteractionMonitor) }
        launchInteractionMonitor = nil
    }

    private func refresh() {
        guard let tab = associatedTab else { return }
        let id = store.panelChat(for: tab.guid).flatMap { store.entry(for: $0) == nil ? nil : $0 }
        if shownId != id || launchHostId != tab.guid || header == nil {
            chatController?.view.removeFromSuperview()
            chatController?.removeFromParent()
            chatController = nil
            launchComposer.removeFromSuperview()
            emptyLogo?.removeFromSuperview(); emptyLogo = nil
            shownId = id
            let body: NSView
            if let id {
                let chat = AgentChatViewController(store: store, presentation: .panel)
                addChild(chat)
                chat.show(id)
                observeFocus(in: chat.composer)
                chat.composer.editor.mentionTabs = { [weak self] in
                    guard let self else { return [] }
                    let chatTabId = self.store.entry(for: id)?.tabId
                    return self.browserState?.tabs.filter { $0.guid != chatTabId } ?? []
                }
                chat.composer.editor.currentTab = { [weak self] in self?.associatedTab }
                chat.composer.editor.mentionGroups = { [weak self] in self?.browserState?.agentMentionGroups ?? [] }
                chatController = chat
                body = chat.view
            } else {
                configureLaunchComposer()
                body = launchComposer
            }
            launchHostId = tab.guid
            header?.removeFromSuperview()
            let header = MistKitHostingView(rootView: headerContent(id: id, host: tab))
            // Near the window's top, the titlebar's safe area pushed the header's content down onto its divider.
            header.safeAreaRegions = []
            self.header = header
            content.addSubview(header)
            content.addSubview(body)
            header.translatesAutoresizingMaskIntoConstraints = false
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                header.topAnchor.constraint(equalTo: content.topAnchor),
                // The chat page header's 14 pt above and below its title and info row.
                header.heightAnchor.constraint(equalToConstant: 64),
                body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: id == nil ? 16 : 0),
                body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: id == nil ? -16 : 0),
                body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: id == nil ? -16 : 0),
            ])
            if id != nil {
                body.topAnchor.constraint(equalTo: header.bottomAnchor).isActive = true
            } else {
                let logo = ThemedHostingView(rootView: DrifterEmptyState())
                logo.sizingOptions = []
                content.addSubview(logo)
                logo.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    logo.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    logo.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    logo.topAnchor.constraint(equalTo: header.bottomAnchor),
                    logo.bottomAnchor.constraint(equalTo: body.topAnchor),
                ])
                emptyLogo = logo
            }
            if expanded { insertHostMention() }
        } else {
            header?.setThemedContent(headerContent(id: id, host: tab))
        }
        if id == nil { launchComposer.browserLaunchRow?.settings.reloadSaved() }
        reportVisibility()
    }

}

private struct MistChatPanelHeader: View {
    @Environment(\.displayScale) private var displayScale
    let conversation: AgentConversation?
    let history: [AgentConversation]
    let select: (UUID) -> Void
    let jump: (String) -> Void
    let open: () -> Void
    let closeChat: () -> Void
    let new: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MistChatPanelIcon()
            if let conversation { MistChatPanelTitle(conversation: conversation) }
            else { Text(Self.title).mistText(.rowHeadline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            if history.contains(where: { $0.id != conversation?.id }) {
                MistChatPanelHistoryButton(history: history, current: conversation?.id, select: select)
            }
            if conversation != nil {
                if let conversation { MistChatPanelMarkerButton(conversation: conversation, jump: jump).id(conversation.id) }
                button("arrow.up.forward.square", NSLocalizedString("browser.chatPanel.openAsTab", value: "Open as Tab", comment: "Chat panel - Open the current conversation as a full tab"), action: open)
                button("xmark.square", NSLocalizedString("browser.chatPanel.closeChat", value: "Close Chat", comment: "Chat panel - Close the shown chat by closing its tab; the panel closes too"), action: closeChat)
            }
            button("square.and.pencil", NSLocalizedString("browser.chatPanel.newChat", value: "New Chat", comment: "Start a new conversation: the Chat panel's and the Drifter home page's button, and the description of the /clear command in agent chats"), action: new)
            button("xmark", NSLocalizedString("browser.chatPanel.close", value: "Close Panel", comment: "Chat panel - Hide the panel without ending the conversation"), action: close)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().themedFill(.mistHairline).frame(height: 1 / displayScale) }
    }
    static var title: String { NSLocalizedString("sidebar.chatButton.title", value: "Chat", comment: "Sidebar bottom chat button title") }
    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.mistIcon).accessibilityLabel(title).customTooltip(title)
    }
}

private struct MistChatPanelMarkerButton: View {
    let conversation: AgentConversation
    let jump: (String) -> Void
    @StateObject private var state: AgentChatMarkerListState
    init(conversation: AgentConversation, jump: @escaping (String) -> Void) {
        self.conversation = conversation
        self.jump = jump
        _state = StateObject(wrappedValue: AgentChatMarkerListState(conversation))
    }
    var body: some View {
        AgentChatMarkerListButton(markers: state.markers, conversation: conversation, jump: jump).equatable()
    }
}

private struct MistChatPanelIcon: View {
    var body: some View {
        MistIconTile(content: .logo(NSImage(named: DrifterApp.logo) ?? NSImage()), side: 28)
            .customTooltip(MistAppID.drifter.name)
    }
}

/// Earlier chats started from this tab, in a menu under a kit icon button like the header's others; the shown chat is
/// checked.
private struct MistChatPanelHistoryButton: View {
    private final class Anchor: NSObject {
        weak var view: NSView?
        var select: (UUID) -> Void = { _ in }
        @objc func pick(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { select(id) } }
    }
    let history: [AgentConversation]
    let current: UUID?
    let select: (UUID) -> Void
    @State private var anchor = Anchor()

    var body: some View {
        Button(action: show) { Image(systemName: "clock.arrow.circlepath") }
            .buttonStyle(.mistIcon).customTooltip(Self.title).accessibilityLabel(Self.title)
            .background(HeaderControlAnchorView { anchor.view = $0 })
    }

    private func show() {
        guard let view = anchor.view else { return }
        anchor.select = select
        let menu = NSMenu()
        for chat in history {
            let item = NSMenuItem(title: chat.title, action: #selector(Anchor.pick(_:)), keyEquivalent: "")
            item.target = anchor
            item.representedObject = chat.id
            item.state = chat.id == current ? .on : .off
            menu.addItem(item)
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: view)
        }
    }
    private static var title: String {
        NSLocalizedString("browser.chatPanel.recentChats", value: "Recent Chats", comment: "Chat panel - Menu of earlier chats started from this tab")
    }
}

private struct MistChatPanelTitle: View {
    @ObservedObject var conversation: AgentConversation
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title).mistText(.rowHeadline).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                AgentChatIDButton(id: conversation.id).fixedSize()
                if let context = ClaudeCodeSessionMetadata.context(tokens: conversation.contextTokens, size: conversation.contextWindowSize) {
                    AgentChatContextUsage(context: context).fixedSize()
                }
            }.mistText(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
