import AppKit

enum MistAppOpenAction {
    case none
    case focusPinned(Tab)
    case focusOpen(Tab, closing: Tab?)
    case navigate(Tab, URL)
    case create(URL)
}

extension BrowserState {
    @MainActor func appOpenAction(_ id: MistAppID, replacing blankTab: Tab? = nil) -> MistAppOpenAction {
        guard !isIncognito, MistApps.app(id) != nil else { return .none }
        let home = MistAppAddress(app: id, instance: nil)
        if let pin = pinnedTabs.first(where: { MistApps.address($0.pinnedUrl ?? $0.url) == home }) { return .focusPinned(pin) }
        if let tab = tabs.first(where: { MistApps.address($0.url) == home }) {
            return .focusOpen(tab, closing: blankTab.flatMap { $0 !== tab ? $0 : nil })
        }
        let url = MistAppRoute.current.url(id)
        if let tab = blankAppTab(replacing: blankTab) {
            return .navigate(tab, url)
        }
        return .create(url)
    }

    /// A supplied blank tab has already been checked for drafts by the caller.
    @MainActor func openApp(_ id: MistAppID, replacing blankTab: Tab? = nil) {
        switch appOpenAction(id, replacing: blankTab) {
        case .none: break
        case .focusPinned(let tab): openOrFocusPinnedTab(tab)
        case .focusOpen(let tab, let blank):
            // Close the blank tab first: closing the active tab closes Chromium's active tab,
            // which after the switch below would be the app's own.
            blank?.close()
            if let wrapper = tab.webContentWrapper { wrapper.setAsActiveTab() } else { focusTabWithTabId(tab.guid) }
        case .navigate(let tab, let url): navigateNativePage(url.absoluteString, replacing: tab)
        case .create(let url): createTab(url.absoluteString)
        }
    }

    @MainActor func openNewDrifterChat(replacing blankTab: Tab? = nil) {
        guard !isIncognito else { return }
        let store = AgentChatStore.shared
        let blank = blankAppTab(replacing: blankTab)
        do {
            let chat = try store.createEmpty(tabId: blank?.guid ?? -1)
            let url = store.route.placeholderURL(for: chat.id).absoluteString
            if let blank {
                navigateNativePage(url, replacing: blank) { store.bindNextTab(chat.id, in: self, url: url) }
            } else {
                store.bindNextTab(chat.id, in: self, url: url)
                createTab(url, focusAfterCreate: true)
            }
            MistSidebarAgentSections.setExpanded(true)
        } catch { NSLog("Couldn't open Drifter: %@", error.localizedDescription) }
    }

    @MainActor private func blankAppTab(replacing blankTab: Tab?) -> Tab? {
        blankTab ?? focusingTab.flatMap { $0.isNTP && !$0.canGoBack && !$0.isPinned && !newTabHasDraft($0) ? $0 : nil }
    }

    /// Both a native New Tab Page and an ordinary page can be replaced by a native app.
    @MainActor func navigateNativePage(_ url: String, replacing tab: Tab, beforeCreate: (() -> Void)? = nil) {
        if let wrapper = tab.webContentWrapper {
            wrapper.navigate(toURL: url)
        } else if tab.usesNativeNTP,
                  let wrapper = ChromiumLauncher.sharedInstance().bridge?.newWebContents(forUrl: url, windowId: windowId.int64Value) as? (WebContentWrapper & NSObject) {
            tab.setWebContentsWrapper(wrapper: wrapper)
        } else {
            beforeCreate?()
            createTab(url)
        }
    }

    @MainActor func newTabHasDraft(_ tab: Tab) -> Bool {
        windowController?.mainSplitViewController.webContentContainerViewController
            .findController(forTabId: tab.guid)?.newTabComposer?.hasDraft() == true
    }
}
