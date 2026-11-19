// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SQLite3
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class SearchTabsDataTests: XCTestCase {
    func testAppResultsAndExecutor() throws {
        let state = try makeSearchTabsState()
        let controller = SearchTabsDataController(browserState: state, chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] }))
        let model = SearchTabsViewModel(dataController: controller)
        XCTAssertFalse(model.sections.contains { $0.kind == .apps })
        model.updateInputText("ma")
        model.flushPendingSearch()
        XCTAssertEqual(model.sections.first?.kind, .apps)
        XCTAssertEqual(model.sections.first?.items.first?.action, .openApp(.mail))
        XCTAssertEqual(model.selectedItem?.action, .openApp(.mail))
        XCTAssertEqual(controller.snapshot(query: "ma").items.first?.action, .openApp(.mail))
        XCTAssertFalse(controller.snapshot(query: "").items.contains { $0.kind == .app })
        XCTAssertFalse(controller.snapshot(query: "m").items.contains { $0.kind == .app })
        XCTAssertEqual(controller.snapshot(query: "ch").items.first?.action, .openApp(.drifter))
        let incognito = try makeSearchTabsState(isIncognito: true)
        XCTAssertTrue(SearchTabsDataController(browserState: incognito, chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] })).sources().apps.isEmpty)
        var opened: MistAppID?
        let executor = SearchTabsActionExecutor(browserState: state, activateChromiumTab: { _, _ in true }, restoreClosedTab: { _, _ in true }, openApp: { _, id in opened = id })
        XCTAssertTrue(executor.perform(.openApp(.mail)))
        XCTAssertEqual(opened, .mail)
    }
    func testDrifterChatsNeverShowButDrifterHomeAndAppDo() throws {
        let route = MistAppRoute.current
        let chat = route.url(.drifter, instance: UUID()).absoluteString
        let legacyChat = try XCTUnwrap(route.legacyURL(.drifter, instance: UUID())).absoluteString
        let home = route.url(.drifter).absoluteString
        let chromium = SearchTabsChromiumProvider(fetchData: { _ in
            [
                "openTabs": [
                    ["tabId": 1, "windowId": 7, "index": 0, "title": "Drifter", "url": chat],
                    ["tabId": 2, "windowId": 7, "index": 1, "title": "Drifter", "url": home],
                ],
                "recentlyClosedTabs": [
                    ["sessionId": 3, "title": "Drifter chat", "url": legacyChat],
                    ["sessionId": 4, "title": "Drifter docs", "url": "https://drifter.example"],
                ],
            ]
        })
        // The controller holds its state weakly.
        let state = try makeSearchTabsState()
        let controller = SearchTabsDataController(browserState: state, chromiumProvider: chromium, historySource: { _ in [] })
        XCTAssertEqual(controller.snapshot(query: "").items.map(\.id), ["openedtab:7:2", "closedtab:4"])
        XCTAssertEqual(controller.snapshot(query: "drift").items.map(\.id), ["app:drifter", "openedtab:7:2", "closedtab:4"])

        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(id: "pin:chat", guid: "chat", kind: .pin, title: "Drifter", url: chat, isOpen: true),
                nativeEntry(id: "pin:home", guid: "home", kind: .pin, title: "Drifter", url: home, isOpen: true),
            ],
            bookmarks: [nativeEntry(id: "bookmark:chat", guid: "saved", kind: .bookmark, title: "Drifter", url: legacyChat, isOpen: false)],
            bookmarkRoot: nil
        )
        let snapshot = SearchTabsAggregator.aggregate(
            query: "drift", profileId: "profile-1", windowId: 7,
            chromium: SearchTabsChromiumSnapshot(openTabs: [], closedTabs: []), native: native, appRoute: route
        )
        XCTAssertEqual(snapshot.items.map(\.id), ["pin:home"])
    }
    func testMeasuredHeightContainsLastRowAcrossSections() throws {
        let snapshot = SearchTabsAggregator.aggregate(
            query: "", profileId: "profile-1", windowId: 7,
            chromium: SearchTabsChromiumSnapshot(
                openTabs: [makeOpenTab(tabId: 1, windowId: 7, title: "Open", lastActiveElapsedMs: 1)],
                closedTabs: [makeClosedTab(sessionId: 2, title: "Closed", lastActiveTimeMs: 1, lastActiveElapsedMs: 1)]
            ),
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )
        let open = try XCTUnwrap(snapshot.items.first)
        let closed = try XCTUnwrap(snapshot.items.last)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SearchTabsResultsView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        window.contentView = view
        for sections in [
            [SearchTabsSectionSnapshot(kind: .openTabs, items: [open], isCollapsed: false),
             SearchTabsSectionSnapshot(kind: .recentlyClosed, items: [closed], isCollapsed: false)],
            [SearchTabsSectionSnapshot(kind: .bookmarks, items: [open], isCollapsed: false),
             SearchTabsSectionSnapshot(kind: .openTabs, items: [open], isCollapsed: false),
             SearchTabsSectionSnapshot(kind: .recentlyClosed, items: [closed], isCollapsed: false)],
        ] {
            view.updateSections(sections, profileId: "profile-1", selectedIndex: -1, query: "", dataSourceChanged: true)
            view.setFrameSize(NSSize(width: 500, height: view.measuredContentHeight()))
            view.layoutSubtreeIfNeeded()
            let last = try XCTUnwrap(view.anchorView(for: closed.id))
            let rect = view.convert(last.bounds, from: last)
            XCTAssertGreaterThanOrEqual(rect.minY, SearchTabsResultsView.bottomPadding)
            XCTAssertLessThanOrEqual(rect.maxY, view.bounds.maxY)
        }
    }
    func testHistoryFrecencyWeightsAndChromiumTimeConversion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(Double, Double)] = [
            (-1, 1), (0, 1), (4, 1), (4 + 1.0 / 86_400, 0.7),
            (14, 0.7), (15, 0.5), (31, 0.5), (32, 0.3), (90, 0.3), (91, 0.1),
        ]
        for (days, weight) in cases {
            XCTAssertEqual(
                BrowsingHistoryProvider.frecency(
                    visitCount: 10, typedCount: 2,
                    lastVisit: now.addingTimeInterval(-days * 86_400), now: now
                ),
                18 * weight, accuracy: 0.000_001
            )
        }
        XCTAssertEqual(BrowsingHistoryProvider.frecency(visitCount: 0, typedCount: 0, lastVisit: now, now: now), 1)
        XCTAssertEqual(BrowsingHistoryProvider.chromiumDate(11_644_473_600_000_000), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(BrowsingHistoryProvider.chromiumDate(13_444_473_600_000_000), now)
    }

    func testHistoryLoaderFiltersRowsAndLeavesOriginalUnchanged() throws {
        let file = try makeHistoryFixture(sql: """
            INSERT INTO urls VALUES ('https://docs.example', 'Docs', 10, 2, 13444473600000000, 0);
            INSERT INTO urls VALUES ('http://mail.example', '', 2, 0, 13444473600000000, 0);
            INSERT INTO urls VALUES ('https://hidden.example', 'Hidden', 100, 10, 13444473600000000, 1);
            INSERT INTO urls VALUES ('chrome://settings', 'Settings', 100, 10, 13444473600000000, 0);
            INSERT INTO urls VALUES ('file:///private/test', 'File', 100, 10, 13444473600000000, 0);
            """
        )
        let original = try Data(contentsOf: file)
        let entries = BrowsingHistoryProvider.load(historyFileURL: file, now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(entries.map(\.url), ["https://docs.example", "http://mail.example"])
        XCTAssertEqual(entries.first?.title, "Docs")
        XCTAssertEqual(entries.first?.visitCount, 10)
        XCTAssertEqual(entries.first?.typedCount, 2)
        XCTAssertEqual(entries.first?.frecency, 18)
        XCTAssertEqual(entries.first?.lastVisit, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["History"])
    }

    func testHistoryLoaderMissingFileAndUnexpectedSchemaReturnEmpty() throws {
        let file = try makeHistoryFixture(sql: "DROP TABLE urls;")
        XCTAssertTrue(BrowsingHistoryProvider.load(historyFileURL: file).isEmpty)
        XCTAssertTrue(BrowsingHistoryProvider.load(historyFileURL: file.appendingPathExtension("missing")).isEmpty)
    }

    func testHistoryLoaderCollapsesMatchingHostAndTitleUsingLatestVisit() throws {
        let file = try makeHistoryFixture(sql: """
            INSERT INTO urls VALUES ('https://DOCS.example/old', 'Docs', 10, 2, 13400000000000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/latest', 'Docs', 2, 1, 13444473600000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/middle', 'Docs', 3, 0, 13440000000000000, 0);
            INSERT INTO urls VALUES ('https://other.example', 'Docs', 1, 0, 13444473600000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/untitled-one', '', 1, 0, 13444473600000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/untitled-two', '', 1, 0, 13444473600000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/other-title', 'Other', 1, 0, 13444473600000000, 0);
            """
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = BrowsingHistoryProvider.load(historyFileURL: file, now: now)
        let group = try XCTUnwrap(entries.first)

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(group.url, "https://docs.example/latest")
        XCTAssertEqual(group.title, "Docs")
        XCTAssertEqual(group.visitCount, 15)
        XCTAssertEqual(group.typedCount, 3)
        XCTAssertEqual(group.lastVisit, now)
        XCTAssertEqual(group.frecency, 27)
        XCTAssertEqual(Set(group.urls), [
            "https://DOCS.example/old", "https://docs.example/latest", "https://docs.example/middle",
        ])
        XCTAssertEqual(entries.filter { $0.title.isEmpty }.count, 2)
        XCTAssertTrue(entries.contains { $0.url == "https://other.example" && $0.urls == [$0.url] })
    }

    func testHistoryLoaderRecoversHotJournalOnlyOnCopy() throws {
        let file = try makeHistoryFixture(sql: """
            WITH RECURSIVE counts(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM counts WHERE n < 1000)
            INSERT INTO urls SELECT 'https://docs.example/' || n, 'Docs ' || n, n, 0, 13444473600000000, 0 FROM counts;
            """
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE urls SET title='Uncommitted';", nil, nil, nil), SQLITE_OK)
        let journal = URL(fileURLWithPath: file.path + "-journal")
        let original = try Data(contentsOf: file)
        let originalJournal = try Data(contentsOf: journal)

        let entries = BrowsingHistoryProvider.load(historyFileURL: file)

        XCTAssertEqual(entries.count, 1_000)
        XCTAssertTrue(entries.allSatisfy { $0.title == "Docs " + URL(string: $0.url)!.lastPathComponent })
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: journal), originalJournal)
    }

    func testHistoryLoaderRejectsCopiedSymlink() throws {
        let file = try makeHistoryFixture(sql: "INSERT INTO urls VALUES ('https://docs.example', 'Docs', 1, 0, 13444473600000000, 0);")
        let link = file.deletingLastPathComponent().appendingPathComponent("HistoryLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(BrowsingHistoryProvider.load(historyFileURL: link).isEmpty)
    }

    func testHistoryLoaderKeepsTopFiveThousandByFrecency() throws {
        let file = try makeHistoryFixture(sql: """
            WITH RECURSIVE counts(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM counts WHERE n < 5002)
            INSERT INTO urls SELECT 'https://docs.example/' || n, 'Docs ' || n, n, 0, 13444473600000000, 0 FROM counts;
            INSERT INTO urls VALUES ('https://docs.example/repeated', 'Docs 1', 6000, 0, 13444473600000000, 0);
            """
        )
        let entries = BrowsingHistoryProvider.load(historyFileURL: file, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(entries.count, 5_000)
        XCTAssertEqual(entries.first?.visitCount, 6_001)
        XCTAssertEqual(entries.first?.urls.count, 2)
        XCTAssertEqual(entries.last?.visitCount, 4)
    }

    func testAggregatorHistoryIsExcludedForEmptyQuery() {
        XCTAssertTrue(historySnapshot(query: "  ", history: [historyEntry(url: "https://docs.example")]).items.isEmpty)
    }

    func testAggregatorHistoryRanksByMatchQualityThenFrecencyRecencyAndURL() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = historySnapshot(history: [
            historyEntry(url: "https://rare.example", frecency: 1),
            historyEntry(url: "https://frequent.example", frecency: 10),
            historyEntry(url: "https://contains.example", title: "My Docs", frecency: 12),
            historyEntry(url: "https://older.example", lastVisit: now.addingTimeInterval(-1), frecency: 1),
            historyEntry(url: "https://a.example", frecency: 1),
            historyEntry(url: "https://docs.example", title: "Other", frecency: 1_000),
            historyEntry(url: "https://path.example/docs", title: "Other", frecency: 10_000),
        ])
        XCTAssertEqual(snapshot.items.map(\.primary.url), [
            "https://frequent.example", "https://a.example", "https://rare.example",
            "https://older.example", "https://contains.example", "https://docs.example", "https://path.example/docs",
        ])
        XCTAssertEqual(snapshot.items.first?.id, "history:https://frequent.example")
        XCTAssertEqual(snapshot.items.first?.action, .openHistoryURL(url: "https://frequent.example"))
        XCTAssertFalse(snapshot.items.contains(where: \.isClosableOpenTab))
    }

    func testAggregatorHistoryDedupesOtherSectionsIncludingSecondaryBookmarkPane() throws {
        let bookmark = Bookmark(
            guid: "split-bookmark", title: "Docs", url: "https://bookmark.example",
            secondaryUrl: "https://secondary.example", secondaryTitle: "Calendar", profileId: "profile-1"
        )
        let native = SearchTabsNativeProvider(
            profileId: "profile-1", windowId: 7, bookmarks: [bookmark]
        ).snapshot(includeBookmarkRoot: false)
        let pin = nativeEntry(id: "pin:docs", guid: "docs", kind: .pin, title: "Docs", url: "https://pin.example", isOpen: false)
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [makeOpenTab(tabId: 1, windowId: 7, title: "Docs", url: "https://open.example", lastActiveElapsedMs: 0)],
            closedTabs: [makeClosedTab(sessionId: 2, title: "Docs", url: "https://closed.example", lastActiveTimeMs: 0, lastActiveElapsedMs: 0)]
        )
        let snapshot = historySnapshot(
            history: ["open", "closed", "pin", "bookmark", "secondary", "unique"].map {
                historyEntry(url: "https://\($0).example")
            } + [historyEntry(url: "https://open.example/")],
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [pin], bookmarks: native.bookmarks, bookmarkRoot: nil)
        )
        XCTAssertEqual(snapshot.items.filter { $0.kind == .history }.map(\.primary.url), [
            "https://open.example/", "https://unique.example",
        ])
        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .pin, .bookmark, .closedtab, .history, .history])
        XCTAssertEqual(SearchTabsSectionKind.allCases, [.apps, .bookmarks, .openTabs, .pinnedTabs, .recentlyClosed, .history])
    }

    func testAggregatorHistoryCapsResultsAtTwentyAfterRanking() {
        let snapshot = historySnapshot(history: (1...25).map {
            historyEntry(url: "https://docs.example/\($0)", frecency: Double($0))
        })
        XCTAssertEqual(snapshot.items.count, 20)
        XCTAssertEqual(snapshot.items.first?.primary.url, "https://docs.example/25")
        XCTAssertEqual(snapshot.items.last?.primary.url, "https://docs.example/6")
    }

    func testAggregatorHistoryDropsGroupWhenNonRepresentativeURLIsOpen() throws {
        let file = try makeHistoryFixture(sql: """
            INSERT INTO urls VALUES ('https://docs.example/old', 'Docs', 10, 0, 13400000000000000, 0);
            INSERT INTO urls VALUES ('https://docs.example/latest', 'Docs', 1, 0, 13444473600000000, 0);
            """
        )
        let history = BrowsingHistoryProvider.load(historyFileURL: file)
        XCTAssertEqual(history.first?.url, "https://docs.example/latest")
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [makeOpenTab(tabId: 1, windowId: 7, title: "Docs", url: "https://docs.example/old", lastActiveElapsedMs: 0)],
            closedTabs: []
        )
        let snapshot = historySnapshot(history: history, chromium: chromium)
        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab])
    }

    func testHistoryLoadUsesProfilePathOffMainThreadAndCachesAcrossResets() async throws {
        let state = try makeSearchTabsState()
        let loaded = expectation(description: "History source called once")
        loaded.assertForOverFulfill = true
        let entry = historyEntry(url: "https://docs.example")
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] }),
            historySource: { file in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(file.lastPathComponent, "History")
                XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "Default")
                loaded.fulfill()
                return [entry]
            }
        )
        let task = try XCTUnwrap(controller.reset {})
        await task.value
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(controller.snapshot(query: "doc").items.map(\.kind), [.history])
        XCTAssertEqual(controller.snapshot(query: "docs").items.map(\.kind), [.history])
        XCTAssertTrue(controller.snapshot(query: "").items.isEmpty)
        await controller.reset {}?.value
    }

    func testHistoryLoadSkipsIncognito() throws {
        let state = try makeSearchTabsState(isIncognito: true)
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] }),
            historySource: { _ in
                XCTFail("Incognito must not load history")
                return []
            }
        )
        XCTAssertNil(controller.reset { XCTFail("Incognito must not complete a history load") })
        XCTAssertTrue(controller.snapshot(query: "docs").items.isEmpty)
    }

    func testHistoryLoadCoalescesResetsAndIgnoresEarlierCallback() async throws {
        let state = try makeSearchTabsState()
        let started = expectation(description: "History load started")
        let gate = SearchTabsHistoryTestGate()
        defer { gate.release.signal() }
        let entry = historyEntry(url: "https://current.example")
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] }),
            historySource: { _ in
                XCTAssertEqual(gate.nextCall(), 1)
                started.fulfill()
                guard gate.release.wait(timeout: .now() + 5) == .success else { return [] }
                return [entry]
            }
        )
        let first = try XCTUnwrap(controller.reset { XCTFail("Earlier callback must be ignored") })
        await fulfillment(of: [started], timeout: 2)
        let second = try XCTUnwrap(controller.reset {})
        gate.release.signal()
        await second.value
        await first.value
        XCTAssertEqual(controller.snapshot(query: "docs").items.map(\.primary.url), [entry.url])
    }

    func testHistoryCacheFreshnessAndProfileIsolation() async {
        let gate = SearchTabsHistoryTestGate()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = historyEntry(url: "https://docs.example")
        let provider = BrowsingHistoryProvider(loader: { _ in
            _ = gate.nextCall()
            XCTAssertFalse(Thread.isMainThread)
            return [entry]
        }, now: { now })
        XCTAssertTrue(provider.entries(forProfileId: "Default").isEmpty)
        await provider.refresh(profileId: "Default") { XCTAssertTrue(Thread.isMainThread) }.value
        XCTAssertEqual(provider.entries(forProfileId: "Default"), [entry])
        XCTAssertTrue(provider.entries(forProfileId: "Other").isEmpty)
        now = now.addingTimeInterval(14)
        await provider.refresh(profileId: "Default") {}.value
        XCTAssertEqual(gate.callCount, 1)
        now = now.addingTimeInterval(1)
        await provider.refresh(profileId: "Default") {}.value
        XCTAssertEqual(gate.callCount, 2)
        await provider.refresh(profileId: "Other") {}.value
        XCTAssertEqual(gate.callCount, 3)
    }

    func testHistoryLoadRefreshesCurrentQueryAndPreservesSelectionAndCollapse() async throws {
        let state = try makeSearchTabsState()
        let gate = SearchTabsHistoryTestGate()
        defer { gate.release.signal() }
        let entry = historyEntry(url: "https://history.example")
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in
                ["openTabs": [
                    ["tabId": 1, "windowId": 7, "title": "Docs One", "url": "https://one.example"],
                    ["tabId": 2, "windowId": 7, "title": "Docs Two", "url": "https://two.example"],
                ]]
            }),
            historySource: { _ in
                guard gate.release.wait(timeout: .now() + 5) == .success else { return [] }
                return [entry]
            }
        )
        let viewModel = SearchTabsViewModel(dataController: controller)
        let refreshed = expectation(description: "Current query refreshed with history")
        let subscription = viewModel.$results.sink { results in
            if results.sections.contains(where: { $0.kind == .history }) { refreshed.fulfill() }
        }
        viewModel.reset()
        viewModel.updateInputText("docs")
        // ↓ acts on the typed query's results even before its search finishes.
        viewModel.selectNextItem()
        XCTAssertEqual(viewModel.results.query, "docs")
        XCTAssertEqual(viewModel.selectedIndex, 1)
        let selectedID = viewModel.selectedItem?.id
        gate.release.signal()
        await fulfillment(of: [refreshed], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(viewModel.snapshot.query, "docs")
        XCTAssertEqual(viewModel.selectedItem?.id, selectedID)
        XCTAssertEqual(viewModel.sections.map(\.kind), [.openTabs, .history])
        viewModel.toggleSection(.history)
        XCTAssertEqual(viewModel.items.count, 2)
        XCTAssertEqual(viewModel.selectedItem?.id, selectedID)
    }

    func testTypingRanksOffTheMainActorAndAppliesOnlyTheNewestQuery() async throws {
        let state = try makeSearchTabsState()
        let history = (0..<5_000).map { index in
            historyEntry(
                url: "https://site\(index).example/docs/page\(index)",
                title: "Docs page \(index)",
                frecency: Double(5_000 - index)
            )
        }
        let openTabs: [[String: Any]] = (0..<60).map { index in
            ["tabId": index + 1, "windowId": 7, "index": index, "title": "Docs tab \(index)",
             "url": "https://tab\(index).example"]
        }
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in ["openTabs": openTabs] }),
            historySource: { _ in history }
        )
        await controller.reset {}?.value
        let viewModel = SearchTabsViewModel(dataController: controller)
        var appliedQueries: [String] = []
        let applied = expectation(description: "Newest query applied")
        let subscription = viewModel.$results.dropFirst().sink { results in
            appliedQueries.append(results.query)
            if results.query == "docs page 4" { applied.fulfill() }
        }
        defer { subscription.cancel() }

        for length in 1..."docs page 4".count {
            viewModel.updateInputText(String("docs page 4".prefix(length)))
            // Keystrokes record the text; no ranking runs before the next one.
            XCTAssertEqual(viewModel.results.query, "")
        }
        XCTAssertEqual(viewModel.inputText, "docs page 4")

        await fulfillment(of: [applied], timeout: 5)
        XCTAssertEqual(appliedQueries, ["docs page 4"])
        XCTAssertEqual(viewModel.snapshot.items, controller.snapshot(query: "docs page 4").items)
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    func testReturnAfterTypingActsOnTheTypedQuery() throws {
        let state = try makeSearchTabsState()
        let controller = SearchTabsDataController(
            browserState: state,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in
                ["openTabs": [
                    ["tabId": 1, "windowId": 7, "title": "Alpha", "url": "https://alpha.example"],
                    ["tabId": 2, "windowId": 7, "title": "Beta", "url": "https://beta.example"],
                ]]
            })
        )
        let viewModel = SearchTabsViewModel(dataController: controller)
        viewModel.reset()
        viewModel.updateInputText("beta")
        viewModel.flushPendingSearch()
        XCTAssertEqual(viewModel.selectedItem?.primary.title, "Beta")
        XCTAssertEqual(viewModel.results.query, "beta")
    }

    func testResultCellBuildsCloseButtonOnlyWhenShown() throws {
        let item = SearchTabsItem(
            id: "openedtab:7:1",
            source: .chromium,
            kind: .openedtab,
            displayMode: .single,
            primary: SearchTabsPane(
                title: "Docs", url: "https://docs.example", faviconData: nil, faviconURL: nil,
                localGuid: nil, chromiumTabId: 1, windowId: 7
            ),
            secondary: nil,
            splitRelation: nil,
            state: SearchTabsItemState(
                isOpen: true, isActive: false, isHostWindow: true, isPinnedInChromium: false,
                isSplit: false, lastSeen: nil, lastActiveElapsedMs: 0, lastActiveElapsedText: "1 min"
            ),
            ranking: SearchTabsRankingMetadata(matchScore: 0, matchedFields: [], providerOrder: 0),
            action: .activateChromiumTab(tabId: 1, windowId: 7),
            secondaryAction: nil
        )
        func hostingViews(in view: NSView) -> Int {
            view.subviews.reduce(0) { count, subview in
                count + (subview is ZeroSafeAreaHostingView<AnyView> ? 1 : 0) + hostingViews(in: subview)
            }
        }

        let cell = SearchTabsResultCellView()
        XCTAssertEqual(cell.identifier, SearchTabsResultCellView.reuseIdentifier)
        cell.configure(with: item, profileId: "Default", selected: false, query: "docs")
        XCTAssertEqual(hostingViews(in: cell), 0)
        cell.updateSelected(true)
        XCTAssertEqual(hostingViews(in: cell), 1)
        cell.updateSelected(false)
        cell.updateSelected(true)
        XCTAssertEqual(hostingViews(in: cell), 1)
    }

    func testActionExecutorOpensHistoryInCurrentWindow() throws {
        let state = try makeSearchTabsState()
        var openedURL: String?
        var openedState: BrowserState?
        let executor = SearchTabsActionExecutor(
            browserState: state,
            activateChromiumTab: { _, _ in false },
            restoreClosedTab: { _, _ in false },
            createTab: { state, url in
                openedState = state
                openedURL = url
            }
        )
        XCTAssertTrue(executor.perform(.openHistoryURL(url: "https://docs.example")))
        XCTAssertEqual(openedURL, "https://docs.example")
        XCTAssertTrue(openedState === state)
    }

    func testQueryMatcherRanksTitlePrefixBeforeTitleContainsAndURLContains() {
        let prefix = SearchTabsQueryMatcher.match(
            query: "git",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let titleContains = SearchTabsQueryMatcher.match(
            query: "hub",
            primaryTitle: "GitHub",
            primaryURL: "https://example.com",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let hostContains = SearchTabsQueryMatcher.match(
            query: "github",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )
        let pathContains = SearchTabsQueryMatcher.match(
            query: "copilot",
            primaryTitle: "Docs",
            primaryURL: "https://github.com/features/copilot",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertGreaterThan(prefix?.score ?? 0, titleContains?.score ?? 0)
        XCTAssertGreaterThan(titleContains?.score ?? 0, hostContains?.score ?? 0)
        XCTAssertGreaterThan(hostContains?.score ?? 0, pathContains?.score ?? 0)
        XCTAssertEqual(prefix?.matchedFields, [.title])
        XCTAssertEqual(hostContains?.matchedFields, [.host])
        XCTAssertEqual(pathContains?.matchedFields, [.url])
    }

    func testQueryMatcherSearchesSecondaryPaneForNativeSplitEntries() {
        let match = SearchTabsQueryMatcher.match(
            query: "calendar",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: "Calendar",
            secondaryURL: "https://calendar.example"
        )

        XCTAssertEqual(match?.score, SearchTabsQueryMatcher.titlePrefixScore)
        XCTAssertEqual(match?.matchedFields, [.secondaryTitle])
    }

    func testQueryMatcherIgnoresURLParametersAndFragments() {
        let urls = [
            "https://example.com/logs?query=agent-har",
            "https://example.com/logs;query=agent-har/extra",
            "https://example.com/logs#agent-har",
            "chrome://settings/?query=agent-har",
        ]
        for url in urls {
            XCTAssertNil(SearchTabsQueryMatcher.match(
                query: "agent-har", primaryTitle: "Logs", primaryURL: url,
                secondaryTitle: nil, secondaryURL: nil
            ), url)
            XCTAssertNil(SearchTabsQueryMatcher.match(
                query: "agent-har", primaryTitle: "Mail", primaryURL: nil,
                secondaryTitle: "Logs", secondaryURL: url
            ), url)
        }
        for (url, score) in [
            ("https://agent-har.example/logs?noise=yes", 200),
            ("https://example.com/agent-har;query=noise", 100),
            ("chrome://settings/privacy?query=noise", 100),
            ("about:privacy?query=noise", 100),
        ] {
            let query = url.hasPrefix("https") ? "agent-har" : "privacy"
            XCTAssertEqual(SearchTabsQueryMatcher.match(
                query: query, primaryTitle: "Page", primaryURL: url,
                secondaryTitle: nil, secondaryURL: nil
            )?.score, score, url)
        }
    }

    func testQueryMatcherReturnsNilForNonMatchingQuery() {
        let match = SearchTabsQueryMatcher.match(
            query: "figma",
            primaryTitle: "Mail",
            primaryURL: "https://mail.example",
            secondaryTitle: nil,
            secondaryURL: nil
        )

        XCTAssertNil(match)
    }

    func testChromiumProviderParsesValidOpenAndRecentlyClosedTabs() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": NSNumber(value: 101),
                    "windowId": "42",
                    "index": NSNumber(value: 3),
                    "title": "Phi Browser",
                    "url": "https://phi.sh",
                    "groupIdHex": "ABCDEF",
                    "active": NSNumber(value: true),
                    "pinned": false,
                    "split": "true",
                    "hostWindow": "1",
                    "lastActiveElapsedMs": "2500",
                    "lastActiveElapsedText": "2 secs ago",
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": "777",
                    "sourceEntrySessionId": NSNumber(value: 700),
                    "sourceEntryType": "window",
                    "title": "Closed Docs",
                    "url": "https://docs.phi.sh",
                    "groupIdHex": "CLOSED",
                    "lastActiveTimeMs": NSNumber(value: 1_800_000),
                    "lastActiveElapsedMs": NSNumber(value: 9_000),
                    "lastActiveElapsedText": "9 secs ago",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 101,
                windowId: 42,
                index: 3,
                title: "Phi Browser",
                url: "https://phi.sh",
                groupIdHex: "ABCDEF",
                active: true,
                pinned: false,
                split: true,
                hostWindow: true,
                lastActiveElapsedMs: 2_500,
                lastActiveElapsedText: "2 secs ago"
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 777,
                sourceEntrySessionId: 700,
                sourceEntryType: "window",
                title: "Closed Docs",
                url: "https://docs.phi.sh",
                groupIdHex: "CLOSED",
                lastActiveTimeMs: 1_800_000,
                lastActiveElapsedMs: 9_000,
                lastActiveElapsedText: "9 secs ago",
                providerOrder: 0
            ),
        ])
    }

    func testChromiumProviderSkipsMalformedItemsWithoutDroppingValidSiblings() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": 0,
                    "windowId": 42,
                    "title": "Invalid Open Tab",
                ],
                "not a dictionary",
                [
                    "tabId": "202",
                    "windowId": NSNumber(value: 84),
                    "title": "Valid Open Tab",
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": -1,
                    "title": "Invalid Closed Tab",
                ],
                "not a dictionary",
                [
                    "sessionId": NSNumber(value: 303),
                    "title": "Valid Closed Tab",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 202,
                windowId: 84,
                index: 0,
                title: "Valid Open Tab",
                url: "about:blank",
                groupIdHex: "",
                active: false,
                pinned: false,
                split: false,
                hostWindow: false,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: ""
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 303,
                sourceEntrySessionId: 303,
                sourceEntryType: "unknown",
                title: "Valid Closed Tab",
                url: "",
                groupIdHex: "",
                lastActiveTimeMs: 0,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: "",
                providerOrder: 2
            ),
        ])
    }

    func testChromiumProviderRejectsBooleanAndFractionalNumberIDs() {
        let snapshot = SearchTabsChromiumProvider.parse(data: [
            "openTabs": [
                [
                    "tabId": NSNumber(value: true),
                    "windowId": NSNumber(value: 42),
                    "title": "Boolean Tab ID",
                ],
                [
                    "tabId": NSNumber(value: 1.9),
                    "windowId": NSNumber(value: 42),
                    "title": "Fractional Tab ID",
                ],
                [
                    "tabId": NSNumber(value: 404),
                    "windowId": NSNumber(value: 42),
                    "title": "Valid Open Tab",
                    "active": NSNumber(value: 2),
                    "pinned": NSNumber(value: 1),
                    "split": NSNumber(value: 0),
                    "hostWindow": NSNumber(value: 1.5),
                ],
            ],
            "recentlyClosedTabs": [
                [
                    "sessionId": NSNumber(value: true),
                    "title": "Boolean Session ID",
                ],
                [
                    "sessionId": NSNumber(value: 2.2),
                    "title": "Fractional Session ID",
                ],
                [
                    "sessionId": NSNumber(value: 505),
                    "title": "Valid Closed Tab",
                ],
            ],
        ])

        XCTAssertEqual(snapshot.openTabs, [
            ChromiumSearchOpenTab(
                tabId: 404,
                windowId: 42,
                index: 0,
                title: "Valid Open Tab",
                url: "about:blank",
                groupIdHex: "",
                active: false,
                pinned: true,
                split: false,
                hostWindow: false,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: ""
            ),
        ])
        XCTAssertEqual(snapshot.closedTabs, [
            ChromiumSearchClosedTab(
                sessionId: 505,
                sourceEntrySessionId: 505,
                sourceEntryType: "unknown",
                title: "Valid Closed Tab",
                url: "",
                groupIdHex: "",
                lastActiveTimeMs: 0,
                lastActiveElapsedMs: Int64.max,
                lastActiveElapsedText: "",
                providerOrder: 2
            ),
        ])
    }

    func testNativeProviderReturnsBookmarkRootOnlyForEmptyQuery() {
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Docs",
            url: "https://docs.example",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [bookmark]
        )

        let withRoot = provider.snapshot(includeBookmarkRoot: true)
        let withoutRoot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(withRoot.bookmarkRoot?.kind, .bookmarkRoot)
        XCTAssertEqual(withRoot.bookmarkRoot?.providerOrder, Int.max)
        XCTAssertEqual(withRoot.bookmarks.count, 1)
        XCTAssertEqual(withRoot.bookmarks.first?.guid, "bookmark-1")
        XCTAssertNil(withoutRoot.bookmarkRoot)
    }

    func testNativeProviderSkipsNativeResultsForIncognito() {
        let pinnedTab = Tab(
            guid: 100,
            url: "https://pinned.example",
            isActive: false,
            index: 0,
            title: "Pinned",
            customGuid: "pin-1"
        )
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Docs",
            url: "https://docs.example",
            profileId: "otr-profile"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "otr-profile",
            windowId: 42,
            isIncognito: true,
            pinnedTabs: [pinnedTab],
            bookmarks: [bookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: true)

        XCTAssertTrue(snapshot.pins.isEmpty)
        XCTAssertTrue(snapshot.bookmarks.isEmpty)
        XCTAssertNil(snapshot.bookmarkRoot)
    }

    func testNativeProviderBuildsPinnedSplitAsSingleEntry() throws {
        let left = Tab(
            guid: 101,
            url: "https://left.example",
            isActive: true,
            index: 0,
            title: "Left",
            customGuid: "pin-left"
        )
        let right = Tab(
            guid: 102,
            url: "https://right.example",
            isActive: false,
            index: 1,
            title: "Right",
            customGuid: "pin-right"
        )
        left.splitPartnerGuid = "pin-right"
        right.splitPartnerGuid = "pin-left"
        left.isOpenned = true
        right.isOpenned = true

        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            pinnedTabs: [left, right],
            focusingTab: left,
            pinnedSplitPair: { tab in
                switch tab.guidInLocalDB {
                case "pin-left", "pin-right":
                    return ("pin-left", "pin-right")
                default:
                    return nil
                }
            }
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.pins.count, 1)
        let entry = try XCTUnwrap(snapshot.pins.first)
        XCTAssertEqual(entry.kind, .pin)
        XCTAssertEqual(entry.primary.localGuid, "pin-left")
        XCTAssertEqual(entry.secondary?.localGuid, "pin-right")
        XCTAssertEqual(entry.displayMode, .split)
        XCTAssertTrue(entry.state.isSplit)
        XCTAssertTrue(entry.state.isOpen)
        XCTAssertTrue(entry.state.isActive)
    }

    func testNativeProviderBuildsSplitBookmarkAsSingleEntry() throws {
        let bookmark = Bookmark(
            guid: "bookmark-1",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example",
            secondaryTitle: "Calendar",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [bookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.bookmarks.count, 1)
        let entry = try XCTUnwrap(snapshot.bookmarks.first)
        XCTAssertEqual(entry.kind, .bookmark)
        XCTAssertEqual(entry.displayMode, .split)
        XCTAssertEqual(entry.primary.title, "Mail")
        XCTAssertEqual(entry.secondary?.title, "Calendar")
    }

    func testNativeProviderFallsBackToSecondaryURLWhenSplitBookmarkTitleIsBlank() throws {
        let nilTitleBookmark = Bookmark(
            guid: "bookmark-1",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example",
            secondaryTitle: nil,
            profileId: "profile-1"
        )
        let emptyTitleBookmark = Bookmark(
            guid: "bookmark-2",
            title: "Docs",
            url: "https://docs.example",
            secondaryUrl: "https://tasks.example",
            secondaryTitle: "",
            profileId: "profile-1"
        )
        let provider = SearchTabsNativeProvider(
            profileId: "profile-1",
            windowId: 42,
            bookmarks: [nilTitleBookmark, emptyTitleBookmark]
        )

        let snapshot = provider.snapshot(includeBookmarkRoot: false)

        XCTAssertEqual(snapshot.bookmarks.count, 2)
        XCTAssertEqual(try XCTUnwrap(snapshot.bookmarks.first).secondary?.title, "https://calendar.example")
        XCTAssertEqual(try XCTUnwrap(snapshot.bookmarks.last).secondary?.title, "https://tasks.example")
    }

    func testAggregatorKeepsOpenedTabAndMatchingNativePinAndRanksOpenedFirst() throws {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "GitHub",
                    url: "https://github.com",
                    active: false,
                    pinned: true,
                    hostWindow: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: []
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(
                    id: "pin:github",
                    guid: "github",
                    kind: .pin,
                    title: "GitHub",
                    url: "https://github.com",
                    isOpen: true
                ),
            ],
            bookmarks: [],
            bookmarkRoot: nil
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "git",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .pin])
        XCTAssertEqual(snapshot.items.first?.action, .activateChromiumTab(tabId: 42, windowId: 7))
        XCTAssertTrue(try XCTUnwrap(snapshot.items.last).state.isOpen)
    }

    func testAggregatorEmptyQueryShowsOnlyOpenAndRecentlyClosedItems() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "Open Tab",
                    active: true,
                    hostWindow: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: [
                makeClosedTab(
                    sessionId: 100,
                    title: "Closed Tab",
                    lastActiveTimeMs: 1_000,
                    lastActiveElapsedMs: 20
                ),
            ]
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(
                    id: "pin:open",
                    guid: "open",
                    kind: .pin,
                    title: "Pinned Tab",
                    url: "https://pin.example",
                    isOpen: true
                ),
            ],
            bookmarks: [
                nativeEntry(
                    id: "bookmark:closed",
                    guid: "closed",
                    kind: .bookmark,
                    title: "Closed Bookmark",
                    url: "https://closed.example",
                    isOpen: false
                ),
            ],
            bookmarkRoot: nativeEntry(
                id: "bookmark-root:profile-1",
                guid: nil,
                kind: .bookmarkRoot,
                title: "Bookmarks",
                url: nil,
                isOpen: false,
                displayMode: .bookmarkMenuRoot,
                action: .showBookmarkMenuRoot(profileId: "profile-1"),
                providerOrder: Int.max
            )
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertEqual(snapshot.items.map(\.kind), [.openedtab, .closedtab])
    }

    func testAggregatorSortsOpenedTabsByHostActiveThenElapsedAscending() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 1, windowId: 7, title: "Host Older", hostWindow: true, lastActiveElapsedMs: 500),
                makeOpenTab(tabId: 2, windowId: 8, title: "Other Recent", hostWindow: false, lastActiveElapsedMs: 1),
                makeOpenTab(tabId: 3, windowId: 7, title: "Host Active", active: true, hostWindow: true, lastActiveElapsedMs: 200),
                makeOpenTab(tabId: 4, windowId: 7, title: "Host Recent", hostWindow: true, lastActiveElapsedMs: 20),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.primary.chromiumTabId), [3, 4, 1, 2])
    }

    func testAggregatorSortsOpenedTabTieByChromiumIndex() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 2, windowId: 7, index: 2, title: "Docs Second", hostWindow: true, lastActiveElapsedMs: 10),
                makeOpenTab(tabId: 1, windowId: 7, index: 1, title: "Docs First", hostWindow: true, lastActiveElapsedMs: 10),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "docs",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.primary.chromiumTabId), [1, 2])
    }

    func testAggregatorSortsClosedTabsByElapsedBeforeTimestamp() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [],
            closedTabs: [
                makeClosedTab(
                    sessionId: 1,
                    title: "Docs Older Activity",
                    lastActiveTimeMs: 2_000,
                    lastActiveElapsedMs: 500,
                    providerOrder: 0
                ),
                makeClosedTab(
                    sessionId: 2,
                    title: "Docs Recent Activity",
                    lastActiveTimeMs: 1_000,
                    lastActiveElapsedMs: 10,
                    providerOrder: 1
                ),
            ]
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "docs",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )

        XCTAssertEqual(snapshot.items.map(\.action), [
            .restoreClosedTab(sessionId: 2, sourceEntrySessionId: 2, sourceEntryType: "tab"),
            .restoreClosedTab(sessionId: 1, sourceEntrySessionId: 1, sourceEntryType: "tab"),
        ])
    }

    func testAggregatorExcludesUnmatchedItemsForNonEmptyQuery() {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(tabId: 1, windowId: 7, title: "Mail", lastActiveElapsedMs: 10),
            ],
            closedTabs: [
                makeClosedTab(sessionId: 1, title: "Calendar", lastActiveTimeMs: 1_000, lastActiveElapsedMs: 20),
            ]
        )
        let native = SearchTabsNativeSnapshot(
            pins: [
                nativeEntry(id: "pin:notes", guid: "notes", kind: .pin, title: "Notes", url: "https://notes.example", isOpen: false),
            ],
            bookmarks: [
                nativeEntry(id: "bookmark:tasks", guid: "tasks", kind: .bookmark, title: "Tasks", url: "https://tasks.example", isOpen: true),
            ],
            bookmarkRoot: nativeEntry(
                id: "bookmark-root:profile-1",
                guid: nil,
                kind: .bookmarkRoot,
                title: "Bookmarks",
                url: nil,
                isOpen: false,
                displayMode: .bookmarkMenuRoot,
                action: .showBookmarkMenuRoot(profileId: "profile-1"),
                providerOrder: Int.max
            )
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "git",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: native
        )

        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testAggregatorKeepsLiveSplitOpenedTabsAsSingleDisplayItems() throws {
        let chromium = SearchTabsChromiumSnapshot(
            openTabs: [
                makeOpenTab(
                    tabId: 42,
                    windowId: 7,
                    title: "Split Docs",
                    split: true,
                    lastActiveElapsedMs: 10
                ),
            ],
            closedTabs: []
        )

        let snapshot = SearchTabsAggregator.aggregate(
            query: "",
            profileId: "profile-1",
            windowId: 7,
            chromium: chromium,
            native: SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
        )
        let item = try XCTUnwrap(snapshot.items.first)

        XCTAssertEqual(item.displayMode, .single)
        XCTAssertTrue(item.state.isSplit)
        XCTAssertNil(item.splitRelation)
    }

    func testDataControllerAttachesSplitRelationToOpenChromiumTab() throws {
        let state = try makeSearchTabsState()
        let mail = Tab(
            guid: 50,
            url: "https://mail.example",
            isActive: true,
            index: 0,
            title: "Mail"
        )
        let calendar = Tab(
            guid: 51,
            url: "https://calendar.example",
            isActive: false,
            index: 1,
            title: "Calendar"
        )
        state.tabs = [mail, calendar]
        state.splits = [
            SplitGroup(
                id: "split-50-51",
                primaryTabId: 50,
                secondaryTabId: 51,
                layout: .vertical,
                ratio: 0.5
            ),
        ]
        let chromium = SearchTabsChromiumProvider(fetchData: { _ in
            [
                "openTabs": [
                    [
                        "tabId": 50,
                        "windowId": 7,
                        "index": 0,
                        "title": "Mail",
                        "url": "https://mail.example",
                        "split": true,
                        "hostWindow": true,
                        "lastActiveElapsedMs": 10,
                    ],
                ],
            ]
        })
        let controller = SearchTabsDataController(browserState: state, chromiumProvider: chromium)

        let snapshot = controller.snapshot(query: "")
        let item = try XCTUnwrap(snapshot.items.first)
        let relation = try XCTUnwrap(item.splitRelation)

        XCTAssertEqual(item.displayMode, .single)
        XCTAssertTrue(item.state.isSplit)
        XCTAssertEqual(relation.splitId, "split-50-51")
        XCTAssertEqual(relation.role, .primary)
        XCTAssertEqual(relation.partnerTabId, 51)
        XCTAssertEqual(relation.partnerTitle, "Calendar")
        XCTAssertEqual(relation.partnerURL, "https://calendar.example")
    }

    func testDataControllerReleasedStateUsesDefaultProfileAndWindowZero() {
        let controller = SearchTabsDataController(
            browserState: nil,
            chromiumProvider: SearchTabsChromiumProvider(fetchData: { _ in [:] })
        )

        let snapshot = controller.snapshot(query: "git")

        XCTAssertEqual(snapshot.profileId, LocalStore.defaultProfileId)
        XCTAssertEqual(snapshot.windowId, 0)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testActionExecutorUsesCurrentWindowForChromiumActions() throws {
        let state = try makeSearchTabsState()
        var activated: (tabId: Int64, windowId: Int64)?
        var restored: (sessionId: Int64, windowId: Int64)?
        let executor = SearchTabsActionExecutor(
            browserState: state,
            activateChromiumTab: { tabId, windowId in
                activated = (tabId, windowId)
                return true
            },
            restoreClosedTab: { sessionId, windowId in
                restored = (sessionId, windowId)
                return true
            }
        )

        XCTAssertTrue(executor.perform(.activateChromiumTab(tabId: 101, windowId: 999)))
        XCTAssertTrue(executor.perform(.restoreClosedTab(sessionId: 202, sourceEntrySessionId: 303, sourceEntryType: "tab")))

        XCTAssertEqual(activated?.tabId, 101)
        XCTAssertEqual(activated?.windowId, Int64(state.windowId))
        XCTAssertEqual(restored?.sessionId, 202)
        XCTAssertEqual(restored?.windowId, Int64(state.windowId))
    }

    func testActionExecutorReleasedStateReturnsFalse() {
        let executor = SearchTabsActionExecutor(
            browserState: nil,
            activateChromiumTab: { _, _ in true },
            restoreClosedTab: { _, _ in true }
        )

        XCTAssertFalse(executor.perform(.activateChromiumTab(tabId: 101, windowId: 7)))
    }

    private func makeSearchTabsState(isIncognito: Bool = false) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default", isIncognito: isIncognito)
    }

    private func makeHistoryFixture(sql: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SearchTabsHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("History")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        let schema = "CREATE TABLE urls (url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);"
        XCTAssertEqual(sqlite3_exec(connection, schema + sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(connection)))
        return file
    }

    private func historyEntry(
        url: String,
        title: String = "Docs",
        lastVisit: Date = Date(timeIntervalSince1970: 1_800_000_000),
        frecency: Double = 1
    ) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(url: url, urls: [url], title: title, visitCount: 1, typedCount: 0, lastVisit: lastVisit, frecency: frecency)
    }

    private func historySnapshot(
        query: String = "docs",
        history: [BrowsingHistoryEntry],
        chromium: SearchTabsChromiumSnapshot = SearchTabsChromiumSnapshot(openTabs: [], closedTabs: []),
        native: SearchTabsNativeSnapshot = SearchTabsNativeSnapshot(pins: [], bookmarks: [], bookmarkRoot: nil)
    ) -> SearchTabsSnapshot {
        SearchTabsAggregator.aggregate(query: query, profileId: "profile-1", windowId: 7, chromium: chromium, native: native, history: history)
    }

    private func makeOpenTab(
        tabId: Int64,
        windowId: Int64,
        index: Int = 0,
        title: String,
        url: String = "https://example.com",
        active: Bool = false,
        pinned: Bool = false,
        split: Bool = false,
        hostWindow: Bool = false,
        lastActiveElapsedMs: Int64
    ) -> ChromiumSearchOpenTab {
        ChromiumSearchOpenTab(
            tabId: tabId,
            windowId: windowId,
            index: index,
            title: title,
            url: url,
            groupIdHex: "",
            active: active,
            pinned: pinned,
            split: split,
            hostWindow: hostWindow,
            lastActiveElapsedMs: lastActiveElapsedMs,
            lastActiveElapsedText: ""
        )
    }

    private func makeClosedTab(
        sessionId: Int64,
        sourceEntrySessionId: Int64? = nil,
        sourceEntryType: String = "tab",
        title: String,
        url: String = "https://example.com",
        lastActiveTimeMs: Int64,
        lastActiveElapsedMs: Int64,
        providerOrder: Int = 0
    ) -> ChromiumSearchClosedTab {
        ChromiumSearchClosedTab(
            sessionId: sessionId,
            sourceEntrySessionId: sourceEntrySessionId ?? sessionId,
            sourceEntryType: sourceEntryType,
            title: title,
            url: url,
            groupIdHex: "",
            lastActiveTimeMs: lastActiveTimeMs,
            lastActiveElapsedMs: lastActiveElapsedMs,
            lastActiveElapsedText: "",
            providerOrder: providerOrder
        )
    }

    private func nativeEntry(
        id: String,
        guid: String?,
        kind: SearchTabsKind,
        title: String,
        url: String?,
        isOpen: Bool,
        displayMode: SearchTabsDisplayMode = .single,
        action: SearchTabsActionTarget? = nil,
        providerOrder: Int = 0
    ) -> NativeSearchEntry {
        let localGuid = kind == .bookmarkRoot ? nil : guid
        let resolvedAction = action ?? {
            switch kind {
            case .pin:
                return .openPinned(localGuid: guid ?? "", preferredPaneGuid: nil)
            case .bookmark:
                return .openBookmark(localGuid: guid ?? "", preferredPaneGuid: nil)
            case .bookmarkRoot:
                return .showBookmarkMenuRoot(profileId: "profile-1")
            case .app, .openedtab, .closedtab, .history:
                return .showBookmarkMenuRoot(profileId: "profile-1")
            }
        }()

        return NativeSearchEntry(
            id: id,
            guid: guid,
            kind: kind,
            displayMode: displayMode,
            primary: SearchTabsPane(
                title: title,
                url: url,
                faviconData: nil,
                faviconURL: nil,
                localGuid: localGuid,
                chromiumTabId: nil,
                windowId: 7
            ),
            secondary: nil,
            state: SearchTabsItemState(
                isOpen: isOpen,
                isActive: false,
                isHostWindow: true,
                isPinnedInChromium: false,
                isSplit: false,
                lastSeen: nil,
                lastActiveElapsedMs: nil,
                lastActiveElapsedText: nil
            ),
            action: resolvedAction,
            secondaryAction: nil,
            providerOrder: providerOrder
        )
    }
}

private final class SearchTabsHistoryTestGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func nextCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls
    }
}
