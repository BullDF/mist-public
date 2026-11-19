// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum OmniBoxHistoryMerger {
    static let maxAppRows = 2
    static let maxBookmarkRows = 2
    static let maxPastSearchRows = 2
    static let maxHistoryRows = 4
    /// Past searches and search-engine suggestions share this many rows; past searches come first.
    static let maxSearchRows = 5

    static func merge(
        chromium: [OmniBoxSuggestion], history: [BrowsingHistoryEntry], query: String,
        openTabURLs: Set<String>, isIncognito: Bool, searchSuggestions: [OmniBoxSuggestion] = [],
        answer: OmniBoxSuggestion? = nil, apps: [MistAppID] = []
    ) -> [OmniBoxSuggestion] {
        let chromium = chromium.filter { MistApps.address($0.url) == nil }
        guard !isIncognito else { return chromium }
        let appRows = apps.prefix(maxAppRows).map { id in
            var row = OmniBoxSuggestion(type: .app, title: id.name, url: "", index: -1, stringToFill: id.name, swapContentsAndDescription: false, matchType: "mist-app")
            row.allowedToBeDefault = false
            row.app = id
            return row
        }
        guard let first = chromium.first else { return appRows }
        let remaining = chromium.dropFirst().filter { !$0.matchType.hasPrefix("history-") }
        let bookmarks = remaining.filter { $0.matchType == "bookmark-title" }.prefix(maxBookmarkRows)
        let pastSearches = remaining.filter { $0.matchType == "search-history" }.prefix(maxPastSearchRows)
        let others = remaining.filter { $0.matchType != "bookmark-title" && $0.matchType != "search-history" }
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var excludedTexts = Set(([first.title, query] + pastSearches.map(\.title)).map(normalized))
        let suggestions = searchSuggestions.filter {
            excludedTexts.insert(normalized($0.title)).inserted
        }.prefix(maxSearchRows - pastSearches.count)
        let kept: [OmniBoxSuggestion] = [first] + Array(bookmarks) + Array(pastSearches) + Array(suggestions) + others
        let excludedURLs = Set(kept.map(\.url))
        let native = BrowsingHistoryProvider.rank(
            history, query: query, excludingURLs: excludedURLs, limit: maxHistoryRows
        )
            .map { result in
                let entry = result.entry
                let openURL = openTabURLs.contains(entry.url) ? entry.url : entry.urls.first(where: openTabURLs.contains)
                let url = openURL ?? entry.url
                let components = URLComponents(string: url)
                let host = components?.host ?? url
                let path = components?.percentEncodedPath.prefix { !";?#".contains($0) } ?? ""
                var suggestion = OmniBoxSuggestion(
                    type: .history, title: entry.title.isEmpty ? host : entry.title,
                    subtitle: host + path, url: url, index: -1,
                    stringToFill: url, swapContentsAndDescription: false,
                    hasTabMatch: openURL != nil
                )
                suggestion.allowedToBeDefault = false
                return suggestion
            }
        let rest: [OmniBoxSuggestion] = Array(pastSearches) + Array(suggestions) + others + native
        return appRows + (answer.map { [$0] } ?? []) + [first] + Array(bookmarks)
            + rest.filter(\.hasTabMatch) + rest.filter { !$0.hasTabMatch }
    }

    static func selectedIndex(
        in suggestions: [OmniBoxSuggestion], preserving selected: OmniBoxSuggestion?
    ) -> Int {
        if let selected, let index = suggestions.firstIndex(where: { $0 == selected })
            ?? (selected.url.isEmpty ? nil : suggestions.firstIndex(where: { $0.url == selected.url })) {
            return index
        }
        let index = suggestions.prefix { $0.type == .app }.count
        return index < suggestions.count && suggestions[index].allowedToBeDefault ? index : -1
    }
}
