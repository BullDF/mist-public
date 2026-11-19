// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SearchTabsAppSource {
    let id: MistAppID
    let keywords: [String]
}

/// The browser data one tab search ranks; `chromium` and `native` are nil once the window is gone.
struct SearchTabsSources {
    let apps: [SearchTabsAppSource]
    let profileId: String
    let windowId: Int
    let chromium: SearchTabsChromiumSnapshot?
    let native: SearchTabsNativeSnapshot?
    let history: [BrowsingHistoryEntry]
    let splitRelations: [Int: SearchTabsSplitRelation]
    /// Recognizes Drifter chat URLs, which tab search never lists.
    let appRoute: MistAppRoute
}

@MainActor
final class SearchTabsDataController {
    typealias HistorySource = BrowsingHistoryProvider.Loader

    private weak var browserState: BrowserState?
    private let chromiumProvider: SearchTabsChromiumProvider
    private let historyProvider: BrowsingHistoryProvider
    private var historyGeneration = 0

    convenience init(browserState: BrowserState) {
        self.init(browserState: browserState, chromiumProvider: SearchTabsChromiumProvider())
    }

    init(
        browserState: BrowserState?,
        chromiumProvider: SearchTabsChromiumProvider,
        historySource: HistorySource? = nil
    ) {
        self.browserState = browserState
        self.chromiumProvider = chromiumProvider
        self.historyProvider = historySource.map { BrowsingHistoryProvider(loader: $0) } ?? .shared
    }

    @discardableResult
    func reset(onHistoryLoaded: @escaping () -> Void) -> Task<Void, Never>? {
        historyGeneration += 1
        guard let state = browserState, !state.isIncognito else { return nil }

        let generation = historyGeneration
        let profileId = state.profileId
        return historyProvider.refresh(profileId: profileId) { [weak self] in
            guard let self,
                  self.historyGeneration == generation,
                  self.browserState?.profileId == profileId,
                  self.browserState?.isIncognito == false else { return }
            onHistoryLoaded()
        }
    }

    func snapshot(query: String) -> SearchTabsSnapshot {
        Self.snapshot(query: query, sources: sources())
    }

    /// Everything a search reads from the browser, captured on the main actor so the
    /// ranking itself (`snapshot(query:sources:)`) can run off it.
    func sources() -> SearchTabsSources {
        guard let state = browserState else {
            return SearchTabsSources(
                apps: [],
                profileId: LocalStore.defaultProfileId,
                windowId: 0,
                chromium: nil,
                native: nil,
                history: [],
                splitRelations: [:],
                appRoute: .current
            )
        }

        let chromium = chromiumProvider.snapshot(windowId: state.windowId)
        var splitRelations: [Int: SearchTabsSplitRelation] = [:]
        for tab in chromium.openTabs {
            let tabId = Int(truncatingIfNeeded: tab.tabId)
            if splitRelations[tabId] == nil, let relation = Self.splitRelation(for: tabId, in: state) {
                splitRelations[tabId] = relation
            }
        }
        return SearchTabsSources(
            apps: state.isIncognito ? [] : MistApps.all.map { SearchTabsAppSource(id: $0.id, keywords: $0.keywords) },
            profileId: state.profileId,
            windowId: state.windowId,
            chromium: chromium,
            native: SearchTabsNativeProvider(browserState: state).snapshot(includeBookmarkRoot: false),
            history: state.isIncognito ? [] : historyProvider.entries(forProfileId: state.profileId),
            splitRelations: splitRelations,
            appRoute: .current
        )
    }

    nonisolated static func snapshot(query: String, sources: SearchTabsSources) -> SearchTabsSnapshot {
        guard let chromium = sources.chromium, let native = sources.native else {
            return SearchTabsSnapshot(
                query: query,
                profileId: sources.profileId,
                windowId: sources.windowId,
                generatedAt: Date(),
                items: []
            )
        }

        return SearchTabsAggregator.aggregate(
            query: query,
            profileId: sources.profileId,
            windowId: sources.windowId,
            chromium: chromium,
            native: native,
            apps: sources.apps,
            history: sources.history,
            appRoute: sources.appRoute,
            splitRelation: { sources.splitRelations[$0] }
        )
    }

    private static func splitRelation(for tabId: Int, in state: BrowserState) -> SearchTabsSplitRelation? {
        guard let group = state.splitGroup(forTabId: tabId),
              let partnerId = group.partnerTabId(of: tabId),
              let partner = state.tabs.first(where: { $0.guid == partnerId }) else {
            return nil
        }

        return SearchTabsSplitRelation(
            splitId: group.id,
            layout: group.layout,
            role: group.primaryTabId == tabId ? .primary : .secondary,
            partnerTabId: partnerId,
            partnerTitle: partner.title,
            partnerURL: partner.url
        )
    }
}
