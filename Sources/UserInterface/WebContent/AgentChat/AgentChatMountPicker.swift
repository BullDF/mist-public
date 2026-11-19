import AppKit

@MainActor
final class AgentChatMountPicker: NSViewController, NSSearchFieldDelegate, NSPopoverDelegate {
    private static var shown: NSPopover?
    private let chatId: UUID
    private let store: AgentChatStore
    private let search = NSSearchField()
    private let list = MistTabMentionPopup()
    private let empty = MistPlaceholderView()
    private weak var popover: NSPopover?

    private init(chatId: UUID, store: AgentChatStore) {
        self.chatId = chatId
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show(chatId: UUID, store: AgentChatStore? = nil, relativeTo anchor: NSView) {
        shown?.close()
        let picker = AgentChatMountPicker(chatId: chatId, store: store ?? .shared)
        picker.loadViewIfNeeded()
        picker.view.subtreeThemeSource = anchor.themeStateProvider
        picker.refresh()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = picker
        popover.contentViewController = picker
        picker.popover = popover
        shown = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        picker.view.window?.makeFirstResponder(picker.search)
    }

    static func targets(in states: [BrowserState], first current: BrowserState?, store: AgentChatStore) -> [Tab] {
        let window = current?.windowController?.window
        let ordered = states.enumerated().sorted { lhs, rhs in
            @MainActor func rank(_ state: BrowserState) -> Int {
                if state === current { return 0 }
                if let window, state.windowController?.window === window { return 1 }
                return 2
            }
            let a = rank(lhs.element), b = rank(rhs.element)
            return a == b ? lhs.offset < rhs.offset : a < b
        }
        return ordered.flatMap { _, state in
            state.tabs.filter { state.canShowChatPanel(for: $0) && !store.hasPanelChat($0.guid) }
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 104))
        search.placeholderString = NSLocalizedString("searchTabs.searchField.placeholder", value: "Search Tabs", comment: "Search Tabs - Placeholder text for the native tab search field")
        search.delegate = self
        // The kit's search well; the rows below line up with its edges.
        let well = MistFieldWellView(search, shape: .capsule)
        for child in [well, list, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            well.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            well.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            list.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10)
        ])
        list.onHeightChange = { [weak self] in self?.updateSize() }
        list.onComplete = { [weak self] in self?.pick($0) }
    }

    private func refresh() {
        let states = SpaceSessionControllersManager.shared.getAllWindows().map(\.browserState)
        let tabId = store.entry(for: chatId)?.tabId
        let current = states.first { state in state.tabs.contains { $0.guid == tabId } }
        let tabs = Self.targets(in: states, first: current, store: store)
        let matches = AgentMentionText.matches(tabs.map { AgentTabMention(tab: $0, position: $0.index + 1) }, query: search.stringValue)
        list.update(matches, current: nil) { mention in
            guard let tab = tabs.first(where: { $0.guid == mention.tabId }), let data = tab.liveFaviconData ?? tab.cachedFaviconData else { return nil }
            return NSImage(data: data)
        }
        empty.show(message: tabs.isEmpty
            ? NSLocalizedString("browser.agentChat.mountToTab.empty", value: "No tabs with an empty Chat panel", comment: "Mount to Tab picker - Shown when no open tab's Chat panel is free for this chat")
            : NSLocalizedString("browser.agentChat.mountToTab.noResults", value: "No results", comment: "Mount to Tab picker - Shown when the search matches no tab"))
        empty.isHidden = !matches.isEmpty
        updateSize()
    }

    private func updateSize() { preferredContentSize = NSSize(width: 320, height: 44 + (list.listHeight == 0 ? 60 : list.listHeight)) }
    private func pick(_ mention: AgentTabMention) {
        let chatId = chatId, store = store
        popover?.close()
        if store.mount(chatId, to: mention.tabId) { MistChatPanelViewController.showInOriginPanel(chatId, store: store) }
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveUp(_:)) { list.move(-1); return true }
        if selector == #selector(NSResponder.moveDown(_:)) { list.move(1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { if let mention = list.selectedMention { pick(mention) }; return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { popover?.close(); return true }
        return false
    }
    func popoverDidClose(_ notification: Notification) { if Self.shown === notification.object as? NSPopover { Self.shown = nil } }
}
