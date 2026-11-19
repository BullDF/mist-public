// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

@MainActor
final class SearchTabsViewModel: ObservableObject {
    /// What the results list shows, published as one value so the list updates once per change.
    struct Results: Equatable {
        let sections: [SearchTabsSectionSnapshot]
        let selectedIndex: Int
        /// The query these sections matched, which can trail `inputText` while a search runs.
        let query: String
    }

    @Published private(set) var snapshot: SearchTabsSnapshot
    @Published private(set) var results: Results
    @Published private(set) var inputText: String = ""

    private let dataController: SearchTabsDataController
    private var collapsedSections = Set<SearchTabsSectionKind>()
    private var searchTask: Task<Void, Never>?
    private var searchPreservesSelection = false

    var sections: [SearchTabsSectionSnapshot] {
        results.sections
    }

    var selectedIndex: Int {
        results.selectedIndex
    }

    var items: [SearchTabsItem] {
        sections.flatMap(\.visibleItems)
    }

    var selectedItem: SearchTabsItem? {
        let items = items
        guard selectedIndex >= 0, selectedIndex < items.count else {
            return nil
        }
        return items[selectedIndex]
    }

    init(dataController: SearchTabsDataController) {
        self.dataController = dataController
        let snapshot = dataController.snapshot(query: "")
        self.snapshot = snapshot
        self.results = Self.makeResults(
            from: snapshot,
            collapsedSections: [],
            preservingSelectionOf: nil
        )
    }

    func reset() {
        dataController.reset { [weak self] in
            guard let self else { return }
            self.search(self.inputText, preservingSelection: true)
        }
        cancelSearch()
        inputText = ""
        apply(dataController.snapshot(query: ""), preservingSelection: false)
    }

    /// Typing only records the text and starts a search off the main actor; the newest
    /// search's results replace the list when it finishes, and older ones are dropped.
    func updateInputText(_ text: String) {
        inputText = text
        search(text, preservingSelection: false)
    }

    /// Applies the typed text's results now if its search is still running, so a key that
    /// acts on the selection (Return, arrows) never acts on an older query's list.
    func flushPendingSearch() {
        guard searchTask != nil else {
            return
        }
        let preservesSelection = searchPreservesSelection
        cancelSearch()
        apply(dataController.snapshot(query: inputText), preservingSelection: preservesSelection)
    }

    func selectNextItem() {
        flushPendingSearch()
        let count = items.count
        guard count > 0 else {
            setSelectedIndex(-1)
            return
        }
        setSelectedIndex(min(selectedIndex + 1, count - 1))
    }

    func selectPreviousItem() {
        flushPendingSearch()
        guard !items.isEmpty else {
            setSelectedIndex(-1)
            return
        }
        setSelectedIndex(max(selectedIndex - 1, 0))
    }

    func selectItem(at index: Int) {
        guard index >= 0, index < items.count else {
            return
        }
        setSelectedIndex(index)
    }

    func removeItem(withID itemID: String) {
        flushPendingSearch()
        let currentItems = items
        let selectedItemID = selectedItem?.id
        let removedVisibleIndex = currentItems.firstIndex { $0.id == itemID }
        let filteredItems = snapshot.items.filter { $0.id != itemID }
        guard filteredItems.count != snapshot.items.count else {
            return
        }

        snapshot = SearchTabsSnapshot(
            query: snapshot.query,
            profileId: snapshot.profileId,
            windowId: snapshot.windowId,
            generatedAt: Date(),
            items: filteredItems
        )
        let sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        let newItems = sections.flatMap(\.visibleItems)

        let newIndex: Int
        if let selectedItemID,
           selectedItemID != itemID,
           let preservedIndex = newItems.firstIndex(where: { $0.id == selectedItemID }) {
            newIndex = preservedIndex
        } else if let removedVisibleIndex, !newItems.isEmpty {
            newIndex = min(removedVisibleIndex, newItems.count - 1)
        } else {
            newIndex = newItems.isEmpty ? -1 : min(max(selectedIndex, 0), newItems.count - 1)
        }
        results = Results(sections: sections, selectedIndex: newIndex, query: snapshot.query)
    }

    func toggleSection(_ section: SearchTabsSectionKind) {
        flushPendingSearch()
        let selectedItemID = selectedItem?.id
        if collapsedSections.contains(section) {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }

        let sections = Self.makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        let newItems = sections.flatMap(\.visibleItems)
        let newIndex: Int
        if let selectedItemID,
           let preservedIndex = newItems.firstIndex(where: { $0.id == selectedItemID }) {
            newIndex = preservedIndex
        } else if newItems.isEmpty {
            newIndex = -1
        } else {
            newIndex = min(max(selectedIndex, 0), newItems.count - 1)
        }
        results = Results(sections: sections, selectedIndex: newIndex, query: snapshot.query)
    }

    private func search(_ query: String, preservingSelection: Bool) {
        cancelSearch()
        // Reading the browser stays on the main actor; matching and ranking don't.
        let sources = dataController.sources()
        searchPreservesSelection = preservingSelection
        searchTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                SearchTabsDataController.snapshot(query: query, sources: sources)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searchTask = nil
            self.apply(snapshot, preservingSelection: preservingSelection)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchPreservesSelection = false
    }

    private func apply(_ snapshot: SearchTabsSnapshot, preservingSelection: Bool) {
        let results = Self.makeResults(
            from: snapshot,
            collapsedSections: collapsedSections,
            preservingSelectionOf: preservingSelection ? selectedItem?.id : nil
        )
        self.snapshot = snapshot
        self.results = results
    }

    private func setSelectedIndex(_ index: Int) {
        guard index != selectedIndex else {
            return
        }
        results = Results(sections: results.sections, selectedIndex: index, query: results.query)
    }

    private static func makeResults(
        from snapshot: SearchTabsSnapshot,
        collapsedSections: Set<SearchTabsSectionKind>,
        preservingSelectionOf selectedItemID: String?
    ) -> Results {
        let sections = makeSections(from: snapshot.items, collapsedSections: collapsedSections)
        let items = sections.flatMap(\.visibleItems)
        var selectedIndex = items.isEmpty ? -1 : 0
        if let selectedItemID, let preservedIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            selectedIndex = preservedIndex
        }
        return Results(sections: sections, selectedIndex: selectedIndex, query: snapshot.query)
    }

    private static func makeSections(
        from items: [SearchTabsItem],
        collapsedSections: Set<SearchTabsSectionKind>
    ) -> [SearchTabsSectionSnapshot] {
        SearchTabsSectionKind.allCases.compactMap { section in
            let sectionItems = items.filter { SearchTabsSectionKind(item: $0) == section }
            guard !sectionItems.isEmpty else {
                return nil
            }
            return SearchTabsSectionSnapshot(
                kind: section,
                items: sectionItems,
                isCollapsed: collapsedSections.contains(section)
            )
        }
    }
}
