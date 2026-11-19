import AppKit
import ObjectiveC

/// Opens the History menu's single pages as new rows, like tab search: a
/// plain tab at the end of the current Space's list, active unless ⌘ alone
/// asks for a background tab. Chromium's `HistoryMenuCocoaController` would
/// load a visited page into the current tab and restore a closed tab into its
/// old window, group and slot. A closed window or group's Restore All Tabs,
/// and a visited page's ⇧ (new window) and ⌥ (download), keep Chromium's
/// handling. The menu's recent agent chats open the same way, or switch to
/// the chat's tab while it is open.
enum MistHistoryMenuReopen {
    /// `HistoryMenuBridge::kVisited`, the Recently Visited section's items.
    private static let visitedTag = 460

    @MainActor private static let chatHistory = AgentChatHistory(route: AgentChatStore.shared.route)
    @MainActor private static let chatTarget = ChatTarget()

    /// Replaces the controller's `openHistoryMenuItem:`, which every History
    /// menu page item targets, and adds the chat sections in its
    /// `menuWillOpen:`. Call once.
    static func install() {
        let selector = NSSelectorFromString("openHistoryMenuItem:")
        guard let controllerClass = NSClassFromString("HistoryMenuCocoaController"),
              let method = class_getInstanceMethod(controllerClass, selector) else {
            AppLogWarn("[HistoryMenu] HistoryMenuCocoaController.openHistoryMenuItem: not found; History menu keeps Chromium's behavior")
            return
        }
        typealias OpenItem = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: OpenItem.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { controller, sender in
            let handled = MainActor.assumeIsolated {
                (sender as? NSMenuItem).map(open) ?? false
            }
            if !handled { original(controller, selector, sender) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))

        let willOpen = NSSelectorFromString("menuWillOpen:")
        guard let willOpenMethod = class_getInstanceMethod(controllerClass, willOpen) else {
            AppLogWarn("[HistoryMenu] HistoryMenuCocoaController.menuWillOpen: not found; History menu keeps Chromium's sections")
            return
        }
        typealias WillOpen = @convention(c) (AnyObject, Selector, NSMenu) -> Void
        let originalWillOpen = unsafeBitCast(method_getImplementation(willOpenMethod), to: WillOpen.self)
        let willOpenReplacement: @convention(block) (AnyObject, NSMenu) -> Void = { controller, menu in
            // Chromium first marks the menu open, which holds its rebuilds.
            originalWillOpen(controller, willOpen, menu)
            MainActor.assumeIsolated { layOut(menu) }
        }
        method_setImplementation(willOpenMethod, imp_implementationWithBlock(willOpenReplacement))
    }

    /// Returns false to leave the item to Chromium.
    @MainActor
    private static func open(_ item: NSMenuItem) -> Bool {
        // A single page's item carries "title\nURL" as its tooltip, or just the
        // URL when untitled; Restore All Tabs carries none.
        guard let url = item.toolTip?.components(separatedBy: "\n").last,
              URL(string: url)?.scheme != nil,
              let state = SpaceSessionControllersManager.shared.getActiveWindowState(),
              !state.isIncognito else { return false }
        let activate = activatesOpenedTab()
        if item.tag == visitedTag {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if !flags.contains(.command), !flags.isDisjoint(with: [.shift, .option]) { return false }
            state.createTab(url, focusAfterCreate: activate)
            return true
        }
        // The item doesn't expose its entry's id; tab search lists the same
        // entries with theirs.
        guard let entry = SearchTabsChromiumProvider().snapshot(windowId: state.windowId)
            .closedTabs.first(where: { $0.url == url }) else { return false }
        return state.reopenClosedTabAsNewRow(sessionId: entry.sessionId, activate: activate)
    }

    /// Chromium's macOS click rule: ⌘ opens a tab, in the background unless
    /// ⇧ is held too.
    private static func activatesOpenedTab() -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        return !flags.contains(.command) || flags.contains(.shift)
    }

    @MainActor
    private static func layOut(_ menu: NSMenu) {
        let store = AgentChatStore.shared
        let chats = chatHistory.chats()
        let sections = [MistHistoryMenuChats.Section(title: MistAppID.drifter.name, chats: chats
            .prefix(MistHistoryMenuChats.rowLimit)
            .map { ($0.id, store.conversation(for: $0.id)?.title ?? $0.title) })]
        // A row matches its entry by URL, as `open` does; a closed folder keeps its marked title.
        let closed = SpaceSessionControllersManager.shared.getActiveWindowState()
            .map { SearchTabsChromiumProvider().snapshot(windowId: $0.windowId).closedTabs } ?? []
        MistHistoryMenuChats.update(menu, sections: sections, isChat: { store.route.conversationId(for: $0) != nil },
                                    isAgentFolderRow: { url, title in
                                        guard let url else { return title.contains(BrowserAgentFolderState.titleMarker) }
                                        return closed.first { $0.url == url }.map { store.isAgentFolder(token: $0.groupIdHex) } ?? false
                                    },
                                    target: chatTarget, action: #selector(ChatTarget.openChat(_:)))
    }

    /// The window and tab showing a chat, in any Space.
    @MainActor
    private static func chatTab(_ id: UUID) -> (controller: SpaceSessionController, tab: Tab)? {
        let route = AgentChatStore.shared.route
        for controller in SpaceSessionControllersManager.shared.getAllWindows() where controller.browserType == .normal {
            if let tab = controller.browserState.tabs.first(where: { route.conversationId(for: $0.url) == id }) {
                return (controller, tab)
            }
        }
        return nil
    }

    @MainActor
    private final class ChatTarget: NSObject, NSMenuItemValidation {
        @objc func openChat(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            if let target = chatTab(id) {
                target.controller.selectTab(target.tab)
                return
            }
            guard let state = SpaceSessionControllersManager.shared.getActiveWindowState(), !state.isIncognito else { return }
            state.createTab(AgentChatStore.shared.route.placeholderURL(for: id).absoluteString, focusAfterCreate: activatesOpenedTab())
        }

        /// A closed chat can't open in an incognito window.
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard let id = item.representedObject as? UUID else { return false }
            return chatTab(id) != nil || SpaceSessionControllersManager.shared.getActiveWindowState()?.isIncognito == false
        }
    }
}
