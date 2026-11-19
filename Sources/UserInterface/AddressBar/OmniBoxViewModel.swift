// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit
@MainActor
class OmniBoxViewModel: ObservableObject {
    @Published private(set) var state = OmniBoxState()
    
    weak var delegate: OmniBoxActionDelegate?
    
    private let configuration: OmniBoxConfiguration
    private var cancellables = Set<AnyCancellable>()
    private let chromiumBridge = ChromiumLauncher.sharedInstance().bridge
    private let browserState: BrowserState
    private let openApp: (MistAppID, Tab?) -> Void
    private let searchCoordinator = OmniBoxSearchCoordinator()
    private var lastChromiumResults: (query: String, profileId: String, suggestions: [OmniBoxSuggestion])?
    private var historyRefreshProfileId: String?
    private var searchEnginesByProfile: [String: SearchSuggestionsEngine] = [:]
    private var engineRefreshRequests: [String: UUID] = [:]
    private var loadedEngineProfiles = Set<String>()
    private var searchSuggestionsTask: Task<Void, Never>?
    private struct SearchSuggestionsKey: Hashable {
        let engine: SearchSuggestionsEngine
        let query: String
    }
    private var searchSuggestionsCache: [SearchSuggestionsKey: SearchSuggestionsResult] = [:]
    private var searchSuggestionsCacheOrder: [SearchSuggestionsKey] = []
    private var remoteSuggestions: (profileId: String, engine: SearchSuggestionsEngine, result: SearchSuggestionsResult)?
    private(set) var preventInlineCompletion: Bool = false
    
    @Published private(set) var canUseTemporaryText = false
    
    var opennedFromCurrentTab = false
    /// A bookmark's tab and a pinned tab stand for their stored URL: an
    /// address-bar submission there opens a NEW tab rather than navigating
    /// the row in place (which bounces the bookmark tab into a Peek and
    /// re-points the pinned row and its icon). Tracked separately from
    /// `opennedFromCurrentTab`, which still describes where the omnibox was
    /// opened from — the Cmd+L toggle reads that.
    private(set) var opensSubmissionInNewTab = false
    var currentTab: Tab?
    private(set) var openTraceSession: OmniBoxTraceSession?

    /// The submission target: the focused tab itself, or a fresh tab.
    private var navigatesCurrentTab: Bool {
        opennedFromCurrentTab && !opensSubmissionInNewTab
    }

    /// Opened for a new tab (Cmd+T's floating omnibox or the New Tab page's
    /// composer): an open-tab match switches to that tab unless Cmd is held.
    /// Everywhere else Cmd is what switches.
    var switchesToOpenTabByDefault: Bool {
        !opennedFromCurrentTab || currentTab.map { $0.isNTP || $0.url == "about:blank" } == true
    }

    private func switchesToOpenTab(_ suggestion: OmniBoxSuggestion, commandKeyPressed: Bool) -> Bool {
        suggestion.hasTabMatch && commandKeyPressed != switchesToOpenTabByDefault
    }

    /// Claims the tab this submission is about to spawn so the Peek pipeline
    /// leaves it alone. Chromium parents an omnibox-opened foreground tab to
    /// whatever is focused and reports it as a link-foreground child, which on
    /// a bookmark/pinned-bound row is indistinguishable from a link click —
    /// and would become a Peek. An omnibox submission never means "peek this".
    ///
    /// Keyed off `focusingTab` rather than `currentTab`: the standalone
    /// omnibox (Cmd+T / Cmd+L overlay) never sets `currentTab`, and a stale
    /// one can outlive the address-bar open that set it.
    private func claimUpcomingNewTab() {
        guard let opener = browserState.focusingTab,
              browserState.addressBarNavigationOpensNewTab(for: opener) else { return }
        browserState.noteAddressBarWillOpenNewTab(openerTabId: opener.guid)
    }

    // MARK: - Initialization
    
    init(configuration: OmniBoxConfiguration = .default, windowState: BrowserState, openApp: ((MistAppID, Tab?) -> Void)? = nil) {
        self.configuration = configuration
        self.browserState = windowState
        self.openApp = openApp ?? { [weak windowState] id, tab in windowState?.openApp(id, replacing: tab) }
        setupBindings()
    }
    
    deinit {
        searchSuggestionsTask?.cancel()
    }
    
    // MARK: - Private Setup

    private func setupBindings() {
        state.$inputText
            .sink { [weak self] text in
                self?.handleInputChanged(text)
            }
            .store(in: &cancellables)

        // Persistent subscription so every Chromium suggestion update for the current query
        // is applied. Chromium emits multiple `OnResultChanged` callbacks per request as
        // providers respond at different speeds; the previous per-request `await` model only
        // consumed the first one, which made the on-screen suggestions diverge from
        // AutocompleteController state and caused selectSuggestion line mismatches.
        browserState.searchSuggestionChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions, originalString in
                self?.handleIncomingSuggestions(suggestions, for: originalString)
            }
            .store(in: &cancellables)
    }

    private func handleIncomingSuggestions(_ results: [[String: Any]], for query: String) {
        guard query == state.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
              searchCoordinator.shouldAcceptResponse(forQuery: query) else {
            logOpenTrace(stage: "response-ignored", details: "query=\(query) reason=stale")
            return
        }
        logOpenTrace(stage: "response-received", details: "query=\(query) resultCount=\(results.count)")
        handleSearchResults(results: results)
    }
    
    func beginOpenTrace(trigger: String, addressViewPresent: Bool) {
        let session = OmniBoxTraceSession(trigger: trigger)
        openTraceSession = session
        session.log(stage: "open-trigger", details: "addressViewPresent=\(addressViewPresent)")
    }

    func logOpenTrace(stage: String, details: String? = nil, once: Bool = false) {
        if once {
            openTraceSession?.logOnce(stage: stage, details: details)
        } else {
            openTraceSession?.log(stage: stage, details: details)
        }
    }

    func updateStatus(with tab: Tab?, suppressAutomaticSearch: Bool = false) {
        guard let tab else {
            return
        }
        currentTab = tab
        // Opening the omnibox via the address bar (sidebar or webcontent) always represents
        // the current tab as the navigation target, including NTP — typing a URL should
        // replace the blank NTP rather than spawn a new tab.
        opennedFromCurrentTab = true
        opensSubmissionInNewTab = browserState.addressBarNavigationOpensNewTab(for: tab)
            || MistApps.address(tab.url) != nil
        if tab.isNTP || tab.url == "about:blank" || MistApps.address(tab.url) != nil {
            logOpenTrace(
                stage: "prefill-current-tab",
                details: "suppressAutomaticSearch=\(suppressAutomaticSearch) urlLength=0 isBlank=true"
            )
            state.inputText = ""
            return
        }
        // A reader page stands in for its article: edit (and re-submit) the
        // article's URL rather than the extension page's.
        let rawURL = tab.url ?? ""
        let prefilledText = URLProcessor.phiBrandEnsuredUrlString(
            ReaderExtensionBridge.sourceURLString(fromReaderPageURL: rawURL) ?? rawURL)
        if suppressAutomaticSearch {
            searchCoordinator.prepareForPrefilledOpen(
                text: prefilledText,
                minInputLength: configuration.minInputLength
            )
        }
        logOpenTrace(
            stage: "prefill-current-tab",
            details: "suppressAutomaticSearch=\(suppressAutomaticSearch) urlLength=\(prefilledText.count)"
        )
        state.inputText = prefilledText
    }

    func setCurrentTab(_ tab: Tab?) {
        currentTab = tab
        opensSubmissionInNewTab = tab.map {
            browserState.addressBarNavigationOpensNewTab(for: $0) || MistApps.address($0.url) != nil
        } ?? false
        if tab?.isNTP == true || tab?.url == "about:blank" || MistApps.address(tab?.url) != nil {
            state.inputText = ""
            opennedFromCurrentTab = true
        } else {
            opennedFromCurrentTab = tab != nil
        }
    }
    
    func updateInputText(_ text: String, suppressAutoComplete: Bool = false) {
        preventInlineCompletion = suppressAutoComplete
        state.inputText = text
    }
    
    func setFocused(_ focused: Bool) {
        state.isFocused = focused
        if focused {
            refreshHistoryIfNeeded()
            refreshSearchEngine()
        } else {
            historyRefreshProfileId = nil
        }
    }
    
    func clickSuggestionAtIndex(_ index: Int) {
        if index >= 0, index < state.suggestions.count {
            let suggestion = state.suggestions[index]
            if suggestion.answer != nil { state.selectedIndex = index }
            handleNavigationAction(for: suggestion, commandKeyPressed: isCommandKeyPressed)
        }
    }
    
    func selectNextSuggestion() {
        canUseTemporaryText = true
        state.selectNextSuggestion()
    }
    
    func selectPreviousSuggestion() {
        canUseTemporaryText = true
        state.selectPreviousSuggestion()
    }
    
    func handleEnterPressed(commandKeyPressed: Bool = false) {
        if let selected = state.selectedSuggestion {
            handleNavigationAction(for: selected, commandKeyPressed: commandKeyPressed)
        } else if !state.inputText.isEmpty {
            let url = URLProcessor.processUserInput(state.inputText)
            openURL(url)
        }
    }

    private func handleNavigationAction(for suggeston: OmniBoxSuggestion, commandKeyPressed: Bool = false) {
        if let id = suggeston.app {
            let blank = opennedFromCurrentTab ? currentTab.flatMap { $0.isNTP && !$0.canGoBack && !$0.isPinned && !newTabHasDraft($0) ? $0 : nil } : nil
            openApp(id, blank)
            finishNavigationAction()
            return
        }
        if let answer = suggeston.answer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer.value, forType: .string)
            OverlayToastCenter.shared.showSearchAnswerCopyConfirmation(in: browserState)
            return
        }
        AppLogDebug("omni: handleNavigationAction suggeston: \(suggeston)")
        // A fresh New Tab page that switches to an open tab has nothing left to show, so it closes,
        // unless its composer holds a draft.
        let switchesToOpenTab = switchesToOpenTab(suggeston, commandKeyPressed: commandKeyPressed)
        let emptyNewTab = switchesToOpenTab && opennedFromCurrentTab
            ? currentTab.flatMap { $0.isNTP && !$0.canGoBack && !$0.isPinned && !newTabHasDraft($0) ? $0 : nil } : nil
        if switchesToOpenTab, let pin = pinnedTab(for: suggeston) {
            browserState.openOrFocusPinnedTab(pin)
            finishNavigationAction()
        } else if suggeston.index >= 0 {
            selectSuggestion(suggeston, commandKeyPressed: commandKeyPressed)
        } else if !suggeston.url.isEmpty {
            openURL(suggeston.url, switchToTab: suggeston.hasTabMatch, switchesToOpenTab: switchesToOpenTab)
        } else {
            return
        }
        if let emptyNewTab {
            DispatchQueue.main.async { emptyNewTab.close() }
        }
    }

    private func newTabHasDraft(_ tab: Tab) -> Bool {
        browserState.windowController?.mainSplitViewController.webContentContainerViewController
            .findController(forTabId: tab.guid)?.newTabComposer?.hasDraft(navigatingFrom: self) == true
    }

    /// The pin behind a bookmark row. `MistChromiumBookmarkMirror` projects
    /// pins into Chromium's bookmarks, so an unloaded pin comes back as a
    /// bookmark row with no tab match; it switches to the pin like an
    /// open-tab row.
    private func pinnedTab(for suggestion: OmniBoxSuggestion) -> Tab? {
        guard suggestion.type == .bookmark else { return nil }
        return browserState.pinnedTab(matchingURL: suggestion.url)
    }

    private func markingPinnedTabMatch(_ suggestion: OmniBoxSuggestion) -> OmniBoxSuggestion {
        guard !suggestion.hasTabMatch, pinnedTab(for: suggestion) != nil else { return suggestion }
        var marked = suggestion
        marked.hasTabMatch = true
        return marked
    }

    private func selectSuggestion(_ suggestion: OmniBoxSuggestion, commandKeyPressed: Bool) {
        let disposition = suggestionDisposition(for: suggestion, commandKeyPressed: commandKeyPressed)
        AppLogDebug("omni: select suggestion line: \(suggestion.index), disposition: \(disposition.rawValue)")
        if disposition == .currentTab, let currentTab {
            browserState.closePeekForAddressBarNavigation(openerTabId: currentTab.guid)
            browserState.closeReaderOverlayForAddressBarNavigation(originTabId: currentTab.guid)
        }
        // Chromium hands the tab this disposition spawns to the Mac side as a
        // link-foreground child of `currentTab`; on a bound row that would be
        // diverted straight into a Peek. Claim it as an address-bar tab first.
        if disposition == .newForegroundTab {
            claimUpcomingNewTab()
        }
        chromiumBridge?.selectSuggestion(atLine: suggestion.index,
                                         windowId: browserState.windowId.int64Value,
                                         disposition: disposition)
        finishNavigationAction()
    }

    private func suggestionDisposition(
        for suggestion: OmniBoxSuggestion,
        commandKeyPressed: Bool
    ) -> PhiOmniboxSuggestionDisposition {
        if switchesToOpenTab(suggestion, commandKeyPressed: commandKeyPressed) {
            return .switchToTab
        }
        if navigatesCurrentTab {
            return .currentTab
        }
        return .newForegroundTab
    }
    
    private func openURL(_ url: String, switchToTab: Bool = false, switchesToOpenTab: Bool = false) {
        AppLogDebug("omni: open url: \(url)")
        if switchToTab {
            if switchesToOpenTab {
                browserState.openTab(url)
            } else {
                browserState.createTab(url)
            }
        } else if navigatesCurrentTab {
            navigateCurrentTab(to: url)
        } else {
            // A new tab: the omnibox was opened outside the address bar, this
            // Space has no tab, or the focused row is bookmark/pinned-bound.
            // Opening the URL in the current window goes via a fresh
            // WebContents, which the Space-routing throttle would route —
            // except an "ask" rule's prompt gets suppressed on redirects here.
            // Resolve the rule up front so both ask and auto-route behave like
            // the live-tab path.
            claimUpcomingNewTab()
            if !routeIfSpaceRuleMatches(url) {
                browserState.createTab(url)
            }
        }
        finishNavigationAction()
    }

    /// Asks Chromium whether a Space URL rule routes `url` away from this
    /// window's Space; if so, Chromium performs the hand-off (prompt / spawn /
    /// open-in-window) and this returns `true`, meaning the caller must not open
    /// the URL locally. Needed for the empty-Space paths (native NTP / no tab),
    /// whose navigation runs on a detached WebContents the throttle can't see.
    private func routeIfSpaceRuleMatches(_ url: String) -> Bool {
        chromiumBridge?.routeURLIfSpaceRuleMatches(url, windowId: browserState.windowId.int64Value) ?? false
    }

    private func navigateCurrentTab(to url: String) {
        if let currentTab, let wrapper = currentTab.webContentWrapper {
            browserState.closePeekForAddressBarNavigation(openerTabId: currentTab.guid)
            browserState.closeReaderOverlayForAddressBarNavigation(originTabId: currentTab.guid)
            wrapper.navigate(toURL: url)
            return
        }

        // No live web contents in this tab (native NTP / empty Space). The
        // Space-routing throttle can't attribute the detached NTP WebContents to
        // a Browser, so resolve the rule up front and hand off if it matches.
        if routeIfSpaceRuleMatches(url) {
            return
        }

        guard let currentTab, currentTab.usesNativeNTP else {
            browserState.createTab(url)
            return
        }

        guard let wrapper = chromiumBridge?.newWebContents(
            forUrl: url,
            windowId: browserState.windowId.int64Value
        ) as? (WebContentWrapper & NSObject) else {
            browserState.createTab(url)
            return
        }
        currentTab.setWebContentsWrapper(wrapper: wrapper)
    }

    private func finishNavigationAction() {
        opennedFromCurrentTab = false
        opensSubmissionInNewTab = false
        delegate?.omniBoxDidClear()
        
        // Leave time for the hide animation to finish before resetting state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.state.reset()
        }
    }

    private var isCommandKeyPressed: Bool {
        NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
    }
    
    func reset() {
        clearSearchSuggestions()
        opennedFromCurrentTab = false
        opensSubmissionInNewTab = false
        searchCoordinator.reset()
        lastChromiumResults = nil
        historyRefreshProfileId = nil
        openTraceSession = nil
        state.reset()
    }
    
    func deleteSuggestion(at index: Int) {
        guard index >= 0 && index < state.suggestions.count else { return }
        let suggestion = state.suggestions[index]
        guard suggestion.canDelete, suggestion.index >= 0 else { return }
        AppLogDebug("omni: delete suggestion at index: \(suggestion.index) original text:\(state.inputText)")
        // Chromium will emit a refreshed `searchSuggestionChanged` event for the same query
        // after the entry is removed; the persistent subscription in `setupBindings`
        // will pick it up.
        chromiumBridge?.deleteSuggestion(atLine: suggestion.index, windowId: browserState.windowId.int64Value)
    }
    
    // MARK: - Private Methods
    
    private func handleInputChanged(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.count < configuration.minInputLength {
            clearSearchSuggestions()
            searchCoordinator.reset()
            lastChromiumResults = nil
            historyRefreshProfileId = nil
            browserState.stopAutoCompletion()
            state.clearSuggestions()
            return
        }

        guard searchCoordinator.shouldPerformAutomaticSearch(for: text, minInputLength: configuration.minInputLength) else {
            logOpenTrace(stage: "skip-automatic-search", details: "reason=prefill queryLength=\(trimmedText.count)")
            return
        }

        performSearch(for: trimmedText, source: .inputChange)
    }
    
    func performSearchAtonce(source: OmniBoxSearchRequestSource = .manualRefresh) {
        performSearch(for: state.inputText, source: source)
    }
    
    private func performSearch(for query: String, source: OmniBoxSearchRequestSource) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= configuration.minInputLength else {
            clearSearchSuggestions()
            state.clearSuggestions()
            return
        }

        if lastChromiumResults?.query != trimmedQuery, state.suggestions.contains(where: { $0.answer != nil }) {
            state.suggestions.removeAll { $0.answer != nil }
            state.selectedIndex = OmniBoxHistoryMerger.selectedIndex(in: state.suggestions, preserving: nil)
        }

        browserState.stopAutoCompletion()

        let request = searchCoordinator.beginRequest(query: trimmedQuery, source: source)
        refreshHistoryIfNeeded()
        fetchSearchSuggestions(for: trimmedQuery)
        logOpenTrace(
            stage: "request-start",
            details: "request=\(request.id) source=\(request.source.rawValue) queryLength=\(trimmedQuery.count)"
        )

        canUseTemporaryText = false
        chromiumBridge?.requestAutoCompleteSuggestions(
            forText: trimmedQuery,
            preventInlineAutoComplete: preventInlineCompletion,
            windowId: browserState.windowId.int64Value
        )
        AppLogDebug("omni: requestSuggestions for text:\(trimmedQuery), inlineCompletion: \(!preventInlineCompletion)")
    }
    
    private func handleSearchResults(results: [[String: Any]]) {
        guard let query = searchCoordinator.currentQuery else { return }
        lastChromiumResults = (
            query, browserState.profileId,
            results.map { OmniBoxSuggestion(chromiumDic: $0) }
                .filter { !$0.isEmpty && $0.isSupportedType }
        )
        mergeHistoryResults()
    }

    private func refreshHistoryIfNeeded() {
        guard !browserState.isIncognito, historyRefreshProfileId != browserState.profileId else { return }
        let profileId = browserState.profileId
        historyRefreshProfileId = profileId
        BrowsingHistoryProvider.shared.refresh(profileId: profileId) { [weak self] in
            guard let self, self.browserState.profileId == profileId else { return }
            self.mergeHistoryResults()
        }
    }

    private func refreshSearchEngine() {
        guard !browserState.isIncognito else { return }
        let profileId = browserState.profileId
        let requestId = UUID()
        engineRefreshRequests[profileId] = requestId
        ProfileManager.shared.searchEngines(forProfile: profileId) { [weak self] engines in
            guard let self, self.engineRefreshRequests[profileId] == requestId else { return }
            self.engineRefreshRequests[profileId] = nil
            self.loadedEngineProfiles.insert(profileId)
            self.searchEnginesByProfile[profileId] = engines.first(where: \.isDefault)
                .flatMap { SearchSuggestionsEngine(keyword: $0.keyword) }
            guard self.browserState.profileId == profileId,
                  let query = self.searchCoordinator.currentQuery,
                  query == self.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.fetchSearchSuggestions(for: query)
            self.mergeHistoryResults()
        }
    }

    private func clearSearchSuggestions() {
        searchSuggestionsTask?.cancel()
        searchSuggestionsTask = nil
        remoteSuggestions = nil
        searchSuggestionsCache.removeAll()
        searchSuggestionsCacheOrder.removeAll()
    }

    private func fetchSearchSuggestions(for query: String) {
        searchSuggestionsTask?.cancel()
        searchSuggestionsTask = nil
        let profileId = browserState.profileId
        guard !browserState.isIncognito else {
            remoteSuggestions = nil
            return
        }
        guard loadedEngineProfiles.contains(profileId) else {
            remoteSuggestions = nil
            if engineRefreshRequests[profileId] == nil { refreshSearchEngine() }
            return
        }
        guard let engine = searchEnginesByProfile[profileId] else {
            remoteSuggestions = nil
            return
        }
        let key = SearchSuggestionsKey(engine: engine, query: query)
        if let cached = searchSuggestionsCache[key] {
            remoteSuggestions = (profileId, engine, cached)
            return
        }
        if let previous = remoteSuggestions, previous.profileId == profileId, previous.engine == engine {
            remoteSuggestions = (profileId, engine, SearchSuggestionsResult(
                texts: previous.result.texts.filter { $0.lowercased().hasPrefix(query.lowercased()) }
            ))
        } else {
            remoteSuggestions = nil
        }
        searchSuggestionsTask = Task { [weak self] in
            let result = await APIClient.shared.searchSuggestions(engine: engine, query: query)
            guard !Task.isCancelled, let self,
                  !self.browserState.isIncognito, self.browserState.profileId == profileId,
                  self.searchEnginesByProfile[profileId] == engine,
                  self.searchCoordinator.currentQuery == query,
                  self.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchSuggestionsCache[key] = result
            self.searchSuggestionsCacheOrder.append(key)
            if self.searchSuggestionsCacheOrder.count > 50 {
                self.searchSuggestionsCache.removeValue(forKey: self.searchSuggestionsCacheOrder.removeFirst())
            }
            self.remoteSuggestions = (profileId, engine, result)
            self.mergeHistoryResults()
        }
    }

    private func searchSuggestionRows() -> [OmniBoxSuggestion] {
        guard !browserState.isIncognito, let remoteSuggestions,
              remoteSuggestions.profileId == browserState.profileId,
              remoteSuggestions.engine == searchEnginesByProfile[browserState.profileId] else { return [] }
        return remoteSuggestions.result.texts.compactMap { text in
            guard let url = remoteSuggestions.engine.resultsURL(query: text) else { return nil }
            var row = OmniBoxSuggestion(
                type: .searchSuggest, title: text, subtitle: nil, url: url.absoluteString, index: -1,
                stringToFill: text, swapContentsAndDescription: false, matchType: "mist-search-suggest"
            )
            row.allowedToBeDefault = false
            return row
        }
    }

    private func searchAnswerRow() -> OmniBoxSuggestion? {
        guard !browserState.isIncognito, let remoteSuggestions,
              remoteSuggestions.profileId == browserState.profileId,
              remoteSuggestions.engine == searchEnginesByProfile[browserState.profileId],
              let answer = remoteSuggestions.result.answer,
              let query = searchCoordinator.currentQuery else { return nil }
        var row = OmniBoxSuggestion(
            type: .answer, title: answer.text, url: "",
            iconName: answer.kind == .calculation ? "plus.forwardslash.minus" : "arrow.left.arrow.right",
            index: -1, stringToFill: query, swapContentsAndDescription: false, matchType: "mist-search-answer"
        )
        row.answer = answer
        return row
    }

    private func mergeHistoryResults() {
        guard let results = lastChromiumResults,
              results.profileId == browserState.profileId,
              results.query == searchCoordinator.currentQuery,
              results.query == state.inputText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let finalSuggestions = OmniBoxHistoryMerger.merge(
            chromium: results.suggestions.map(markingPinnedTabMatch),
            history: browserState.isIncognito ? [] : BrowsingHistoryProvider.shared.entries(forProfileId: results.profileId),
            query: results.query, openTabURLs: Set(browserState.tabs.compactMap(\.url)),
            isIncognito: browserState.isIncognito, searchSuggestions: searchSuggestionRows(), answer: searchAnswerRow(),
            apps: browserState.isIncognito ? [] : MistAppMatcher.matches(results.query, in: MistApps.all.map { ($0.id, $0.keywords) })
        )
        let newSelectedIndex = OmniBoxHistoryMerger.selectedIndex(
            in: finalSuggestions, preserving: canUseTemporaryText ? state.selectedSuggestion : nil
        )

        let suggestionsChanged = state.suggestions != finalSuggestions
        if suggestionsChanged {
            state.suggestions = finalSuggestions
        }
        if suggestionsChanged || state.selectedIndex != newSelectedIndex {
            state.selectedIndex = newSelectedIndex
        }

        logOpenTrace(
            stage: "results-applied",
            details: "query=\(searchCoordinator.currentQuery ?? "") suggestionCount=\(finalSuggestions.count) selectedIndex=\(state.selectedIndex)"
        )
    }
}
