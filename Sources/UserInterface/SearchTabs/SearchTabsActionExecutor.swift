// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@MainActor
final class SearchTabsActionExecutor {
    typealias ActivateChromiumTab = (Int64, Int64) -> Bool
    typealias RestoreClosedTab = (Int64, Int64) -> Bool
    typealias CreateTab = (BrowserState, String) -> Void

    private weak var browserState: BrowserState?
    private let activateChromiumTab: ActivateChromiumTab
    private let restoreClosedTab: RestoreClosedTab
    private let createTab: CreateTab
    private let openApp: @MainActor (BrowserState, MistAppID) -> Void

    init(browserState: BrowserState) {
        self.browserState = browserState
        self.activateChromiumTab = { tabId, windowId in
            ChromiumLauncher.sharedInstance().bridge?
                .activateSearchTab(withTabId: tabId, windowId: windowId) ?? false
        }
        self.restoreClosedTab = { [weak browserState] sessionId, _ in
            browserState?.reopenClosedTabAsNewRow(sessionId: sessionId) ?? false
        }
        self.createTab = { state, url in state.createTab(url) }
        self.openApp = { state, id in state.openApp(id) }
    }

    init(
        browserState: BrowserState?,
        activateChromiumTab: @escaping ActivateChromiumTab,
        restoreClosedTab: @escaping RestoreClosedTab,
        createTab: @escaping CreateTab = { state, url in state.createTab(url) },
        openApp: @escaping @MainActor (BrowserState, MistAppID) -> Void = { state, id in state.openApp(id) }
    ) {
        self.browserState = browserState
        self.activateChromiumTab = activateChromiumTab
        self.restoreClosedTab = restoreClosedTab
        self.createTab = createTab
        self.openApp = openApp
    }

    @discardableResult
    func perform(_ action: SearchTabsActionTarget) -> Bool {
        guard let state = browserState else {
            return false
        }

        switch action {
        case let .openApp(id):
            openApp(state, id)
            return true
        case let .activateChromiumTab(tabId, _):
            return activateChromiumTab(Int64(tabId), Int64(state.windowId))
        case let .restoreClosedTab(sessionId, _, _):
            return restoreClosedTab(Int64(sessionId), Int64(state.windowId))
        case let .openPinned(localGuid, preferredPaneGuid):
            return openPinned(localGuid: localGuid, preferredPaneGuid: preferredPaneGuid, in: state)
        case let .openBookmark(localGuid, _):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: localGuid) else {
                return false
            }
            state.openBookmark(bookmark)
            return true
        case .showBookmarkMenuRoot:
            return false
        case let .openHistoryURL(url):
            createTab(state, url)
            return true
        }
    }

    @discardableResult
    func close(_ item: SearchTabsItem) -> Bool {
        guard item.isClosableOpenTab,
              let tabId = item.primary.chromiumTabId,
              let state = browserState(for: item.primary.windowId),
              let tab = state.tabs.first(where: { $0.guid == tabId }) else {
            return false
        }

        tab.close()
        return true
    }

    private func openPinned(localGuid: String, preferredPaneGuid: String?, in state: BrowserState) -> Bool {
        let requestedGuid = preferredPaneGuid ?? localGuid
        let requestedTab = state.pinnedTabs.first { $0.guidInLocalDB == requestedGuid }
        let fallbackTab = state.pinnedTabs.first { $0.guidInLocalDB == localGuid }

        guard let tab = requestedTab ?? fallbackTab else {
            return false
        }

        state.openOrFocusPinnedTab(tab)
        return true
    }

    private func browserState(for windowId: Int?) -> BrowserState? {
        guard let windowId else {
            return browserState
        }

        if let browserState, browserState.windowId == windowId {
            return browserState
        }

        return SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
    }
}
