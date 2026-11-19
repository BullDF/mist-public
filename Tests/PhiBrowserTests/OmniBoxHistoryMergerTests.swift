// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class OmniBoxHistoryMergerTests: XCTestCase {
    func testAppRowsPrecedeResultsAndDoNotStealDefault() {
        let first = row("search-what-you-typed", line: 0)
        let answer = answerSuggestion()
        let apps: [MistAppID] = [.mail, .clipboard, .drifter]
        let result = OmniBoxHistoryMerger.merge(chromium: [first], history: [], query: "ma", openTabURLs: [], isIncognito: false, answer: answer, apps: apps)
        XCTAssertEqual(result.prefix(2).compactMap(\.app), [.mail, .clipboard])
        XCTAssertEqual(result[2], answer)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: result, preserving: nil), 2)
        let withoutAnswer = OmniBoxHistoryMerger.merge(chromium: [first], history: [], query: "ma", openTabURLs: [], isIncognito: false, apps: apps)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: withoutAnswer, preserving: answer), 2)
        var nonDefault = first
        nonDefault.allowedToBeDefault = false
        let noDefault = OmniBoxHistoryMerger.merge(chromium: [nonDefault], history: [], query: "ma", openTabURLs: [], isIncognito: false, apps: apps)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: noDefault, preserving: nil), -1)
        XCTAssertEqual(OmniBoxHistoryMerger.merge(chromium: [first], history: [], query: "ma", openTabURLs: [], isIncognito: true, apps: apps), [first])
        let placeholder = row("history-url", line: 1, url: MistAppRoute.current.url(.mail).absoluteString)
        XCTAssertFalse(OmniBoxHistoryMerger.merge(chromium: [placeholder, first], history: [], query: "ma", openTabURLs: [], isIncognito: false, apps: apps).contains(placeholder))
    }
    func testAnswerPrecedesChromiumDefaultAndBecomesDefaultSelection() {
        let first = row("search-what-you-typed", line: 0)
        let answer = answerSuggestion()
        let bookmark = row("bookmark-title", line: 1)
        let result = OmniBoxHistoryMerger.merge(
            chromium: [first, bookmark], history: [], query: "12*7",
            openTabURLs: [], isIncognito: false, answer: answer
        )
        XCTAssertEqual(result, [answer, first, bookmark])
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: result, preserving: nil), 0)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: result, preserving: first), 1)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: result, preserving: bookmark), 2)
    }

    func testIncognitoAndEmptyChromiumIgnoreAnswer() {
        let rows = [row("search-what-you-typed", line: 0)]
        let answer = answerSuggestion()
        XCTAssertEqual(OmniBoxHistoryMerger.merge(
            chromium: rows, history: [], query: "12*7", openTabURLs: [], isIncognito: true, answer: answer
        ), rows)
        XCTAssertEqual(OmniBoxHistoryMerger.merge(
            chromium: [], history: [], query: "12*7", openTabURLs: [], isIncognito: false, answer: answer
        ), [])
    }

    private func answerSuggestion() -> OmniBoxSuggestion {
        var suggestion = OmniBoxSuggestion(
            type: .answer, title: "= 84", url: "", iconName: "plus.forwardslash.minus", index: -1,
            stringToFill: "12*7", swapContentsAndDescription: false, matchType: "mist-search-answer"
        )
        suggestion.answer = SearchAnswer(text: "= 84")
        return suggestion
    }

    func testSearchSuggestionsFollowPastSearchesWithinFiveSearchRows() {
        let first = row("search-what-you-typed", line: 0)
        let past = row("search-history", line: 1)
        let other = row("url-what-you-typed", line: 2)
        let suggestions = (1...6).map { searchSuggestion("suggestion \($0)") }
        let result = OmniBoxHistoryMerger.merge(
            chromium: [first, other, past], history: [entry("https://native.example")], query: "docs",
            openTabURLs: [], isIncognito: false, searchSuggestions: suggestions
        )
        XCTAssertEqual(Array(result.prefix(6)), [first, past] + Array(suggestions.prefix(4)))
        XCTAssertEqual(result[6], other)
        XCTAssertEqual(result.last?.url, "https://native.example")
        XCTAssertTrue(result.filter { $0.matchType == "mist-search-suggest" }.allSatisfy { !$0.hasTabMatch })
    }

    func testPastSearchesTakeAtMostTwoSearchRowsAndSuggestionsFillTheRest() {
        let first = row("search-what-you-typed", line: 0)
        let searches = (1...4).map { row("search-history", line: $0) }
        let suggestions = (1...6).map { searchSuggestion("suggestion \($0)") }
        let crowded = OmniBoxHistoryMerger.merge(
            chromium: [first] + searches, history: [], query: "docs", openTabURLs: [], isIncognito: false,
            searchSuggestions: suggestions
        )
        XCTAssertEqual(crowded, [first] + searches.prefix(2) + suggestions.prefix(3))
        let noPastSearches = OmniBoxHistoryMerger.merge(
            chromium: [first], history: [], query: "docs", openTabURLs: [], isIncognito: false,
            searchSuggestions: suggestions
        )
        XCTAssertEqual(noPastSearches, [first] + suggestions.prefix(5))
    }

    func testSearchSuggestionsDeduplicateQueryFirstAndKeptPastSearches() {
        let first = row("search-what-you-typed", line: 0)
        let searches = (1...4).map { row("search-history", line: $0) }
        let suggestions = [" DOCS ", " CHROMIUM 0 ", "Chromium 1", " chromium 2 ", "CHROMIUM 3",
                           "Chromium 4", "unique", " UNIQUE "].map(searchSuggestion)
        let result = OmniBoxHistoryMerger.merge(
            chromium: [first] + searches, history: [], query: "docs", openTabURLs: [], isIncognito: false,
            searchSuggestions: suggestions
        )
        XCTAssertEqual(result.filter { $0.matchType == "mist-search-suggest" }.map(\.title),
                       ["CHROMIUM 3", "Chromium 4", "unique"])
    }

    func testIncognitoDoesNotMergeSearchSuggestions() {
        let rows = [row("history-url", line: 0), row("history-title", line: 1)]
        XCTAssertEqual(OmniBoxHistoryMerger.merge(
            chromium: rows, history: [], query: "docs", openTabURLs: [], isIncognito: true,
            searchSuggestions: [searchSuggestion("docs search")]
        ), rows)
    }

    private func searchSuggestion(_ text: String) -> OmniBoxSuggestion {
        var suggestion = OmniBoxSuggestion(
            type: .searchSuggest, title: text, subtitle: nil,
            url: SearchSuggestionsEngine.google.resultsURL(query: text)!.absoluteString,
            index: -1, stringToFill: text, swapContentsAndDescription: false, matchType: "mist-search-suggest"
        )
        suggestion.allowedToBeDefault = false
        return suggestion
    }

    func testKeepsDefaultHistoryRowAndChromiumLinesWhileReplacingOtherHistory() {
        let rows = [row("history-url", line: 0), row("history-title", line: 1),
                    row("search-history", line: 2), row("history-body", line: 3),
                    row("bookmark-title", line: 4), row("history-cluster", line: 5),
                    row("search-suggest", line: 6), row("history-embeddings", line: 7),
                    row("url-what-you-typed", line: 8)]
        let result = merge(rows, history: [entry("https://native.example/docs")])
        XCTAssertEqual(result.first, rows.first)
        XCTAssertEqual(result.first?.inlineCompletionString, "completion")
        XCTAssertEqual(result.map(\.index), [0, 4, 2, 6, 8, -1])
        XCTAssertEqual(Array(result[1..<5]), [rows[4], rows[2], rows[6], rows[8]])
    }

    func testHistoryRanksTitleBeforeURLCapsAtFourAndExcludesKeptURLs() {
        let rows = [row("search-what-you-typed", line: 0), row("bookmark-title", line: 8)]
        let history = [entry(rows[0].url), entry(rows[1].url),
                       entry("https://url.example/docs", title: "Other", frecency: 1000),
                       entry("https://best.example", frecency: 10),
                       entry("https://second.example", frecency: 9),
                       entry("https://third.example", frecency: 8),
                       entry("https://fourth.example", frecency: 7)]
        let result = merge(rows, history: history)
        XCTAssertEqual(result.map(\.url), [rows[0].url, rows[1].url, "https://best.example", "https://second.example",
                                           "https://third.example", "https://fourth.example"])
        let urlMatch = merge(rows, history: Array(history.prefix(4)))
        XCTAssertEqual(urlMatch[2].url, "https://best.example")
        XCTAssertEqual(urlMatch[3].url, "https://url.example/docs")
    }

    func testCapsBookmarksPastSearchesAndHistoryInOrder() {
        let bookmarks = (1...4).map { row("bookmark-title", line: $0) }
        let searches = (5...8).map { row("search-history", line: $0) }
        let rows = [row("search-what-you-typed", line: 0)] + searches + bookmarks
        let history = (1...5).map { entry("https://native\($0).example", frecency: Double(10 - $0)) }
        let result = merge(rows, history: history)
        XCTAssertEqual(result.map(\.index), [0, 1, 2, 5, 6, -1, -1, -1, -1])
        XCTAssertEqual(result.suffix(4).map(\.url), (1...4).map { "https://native\($0).example" })
    }

    func testNativeFieldsTabMatchAndEmptyTitleFallback() {
        let url = "https://docs.example/path;ignored=1?query=2#fragment"
        let result = OmniBoxHistoryMerger.merge(
            chromium: [row("search-what-you-typed", line: 0)],
            history: [entry(url, title: "")], query: "docs",
            openTabURLs: [url], isIncognito: false
        )
        let native = result[1]
        XCTAssertEqual(native.type, .history)
        XCTAssertEqual(native.title, "docs.example")
        XCTAssertEqual(native.subtitle, "docs.example/path")
        XCTAssertEqual(native.url, url)
        XCTAssertEqual(native.fillIntoEdit, url)
        XCTAssertEqual(native.matchType, "")
        XCTAssertEqual(native.index, -1)
        XCTAssertTrue(native.hasTabMatch)
        XCTAssertFalse(native.canDelete)
        XCTAssertFalse(native.allowedToBeDefault)
        XCTAssertFalse(native.swapContentsAndDescription)
        XCTAssertFalse(merge([row("search-suggest", line: 0)], history: [entry(url)])[1].hasTabMatch)
    }

    func testDropsGroupWhenAnyURLIsAlreadyKeptAndIgnoresQueryOnlyMatches() {
        let first = row("search-suggest", line: 0)
        let grouped = BrowsingHistoryEntry(url: "https://group.example", urls: ["https://group.example", first.url],
                                           title: "Docs", visitCount: 2, typedCount: 0, lastVisit: .now, frecency: 100)
        XCTAssertEqual(merge([first], history: [grouped, entry("https://other.example/?q=docs", title: "Other")]), [first])
    }

    func testEmptyHistoryAndIncognito() {
        let rows = [row("history-url", line: 0), row("history-title", line: 1), row("search-history", line: 2)]
        XCTAssertEqual(merge(rows, history: []), [rows[0], rows[2]])
        XCTAssertEqual(OmniBoxHistoryMerger.merge(chromium: rows, history: [entry("https://native.example")],
                                                query: "docs", openTabURLs: [], isIncognito: true), rows)
        XCTAssertEqual(merge([], history: [entry("https://native.example")]), [])
    }

    func testSelectionFollowsIdentityOrURLAcrossRemerges() {
        let selected = row("bookmark-title", line: 2)
        let first = row("search-suggest", line: 0)
        let merged = merge([first, selected], history: [entry("https://native.example")])
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: merged, preserving: selected), 1)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: [first, row("bookmark-title", line: 9, url: selected.url)],
                                                        preserving: selected), 1)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: merged, preserving: nil), 0)
        XCTAssertEqual(OmniBoxHistoryMerger.selectedIndex(in: [], preserving: selected), -1)
    }

    func testOpenTabRowsComeRightAfterBookmarks() {
        let first = row("search-what-you-typed", line: 0)
        let bookmark = row("bookmark-title", line: 1)
        var openSearch = row("search-history", line: 2)
        openSearch = OmniBoxSuggestion(chromiumDic: ["type": "search-history", "line": 2, "contents": "Chromium 2",
                                                     "destinationUrl": openSearch.url, "hasTabMatch": true])
        let history = [entry("https://closed.example", frecency: 9), entry("https://open.example", frecency: 1)]
        let result = OmniBoxHistoryMerger.merge(
            chromium: [first, bookmark, openSearch], history: history, query: "docs",
            openTabURLs: ["https://open.example"], isIncognito: false
        )
        XCTAssertEqual(result.map(\.url), [first.url, bookmark.url, openSearch.url, "https://open.example",
                                           "https://closed.example"])
    }

    func testGroupedHistoryRowPointsAtWhicheverURLIsOpen() {
        let grouped = BrowsingHistoryEntry(url: "https://docs.example/latest", urls: ["https://docs.example/latest",
                                                                                      "https://docs.example/older"],
                                           title: "Docs", visitCount: 2, typedCount: 0, lastVisit: .now, frecency: 2)
        let result = OmniBoxHistoryMerger.merge(
            chromium: [row("search-what-you-typed", line: 0)], history: [grouped], query: "docs",
            openTabURLs: ["https://docs.example/older"], isIncognito: false
        )
        XCTAssertTrue(result[1].hasTabMatch)
        XCTAssertEqual(result[1].url, "https://docs.example/older")
        XCTAssertEqual(result[1].fillIntoEdit, "https://docs.example/older")
    }

    private func merge(_ rows: [OmniBoxSuggestion], history: [BrowsingHistoryEntry]) -> [OmniBoxSuggestion] {
        OmniBoxHistoryMerger.merge(chromium: rows, history: history, query: "docs", openTabURLs: [], isIncognito: false)
    }

    private func row(_ type: String, line: Int, url: String? = nil) -> OmniBoxSuggestion {
        OmniBoxSuggestion(chromiumDic: ["type": type, "line": line, "contents": "Chromium \(line)",
                                       "destinationUrl": url ?? "https://chromium.example/\(line)",
                                       "inlineAutocompletion": "completion", "allowedToBeDefaultMatch": true])
    }

    private func entry(_ url: String, title: String = "Docs", frecency: Double = 1) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(url: url, urls: [url], title: title, visitCount: 1, typedCount: 0,
                             lastVisit: Date(timeIntervalSince1970: 1_800_000_000), frecency: frecency)
    }
}
