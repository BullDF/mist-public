import Combine
import Foundation

@MainActor
final class TabNameStore {
    static let shared = TabNameStore()
    private var ledger: TabNameLedger
    private let defaults: UserDefaults
    private let key: String
    private var watches: [Int: AnyCancellable] = [:]
    private var arrivals: [Int: Int] = [:]
    private var pendingCloses: [Int: (windowId: Int, generation: Int)] = [:]
    private var unnamedArrivals: Set<Int> = []
    private var pendingWrite: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "MistTabNames@" + SpaceManager.slotsRestoreSnapshotDefaultsKey
        let entries = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([TabNameLedger.Entry].self, from: $0)
        } ?? []
        ledger = TabNameLedger(entries: entries, spaceIds: Set(SpaceManager.shared.spaces.map(\.spaceId)))
    }

    private func entry(for tab: Tab, in state: BrowserState) -> TabNameLedger.Entry {
        .init(spaceId: state.spaceId, windowId: state.windowId, url: tab.url ?? "",
              name: "", stripIndex: tab.index)
    }

    func set(_ name: String?, for tab: Tab, in state: BrowserState) {
        ledger.set(name, tabId: tab.guid, entry: entry(for: tab, in: state),
                   persists: !state.isIncognito && !state.isAgentSpace)
        if name == nil { watches[tab.guid] = nil }
        else { observe(tab) }
        persist()
    }

    func arrived(_ tab: Tab, in state: BrowserState, restoring: Bool, singleTabRestore: Bool = false) {
        if ledger.live[tab.guid] != nil { arrivals[tab.guid, default: 0] += 1 }
        // Undo may arrive before the delayed close check. Classify those
        // closes now, while a same-id move still wins by its generation.
        if restoring {
            for (tabId, close) in Array(pendingCloses) where tabId != tab.guid {
                settleClose(tabId: tabId, windowId: close.windowId, generation: close.generation)
            }
        }
        guard let name = ledger.arrive(tabId: tab.guid, entry: entry(for: tab, in: state),
                                      persists: !state.isIncognito && !state.isAgentSpace,
                                      restoreSource: state.tabNameRestoreSourceWindowId,
                                      restoring: restoring, singleTabRestore: singleTabRestore) else {
            if !restoring {
                let tabId = tab.guid
                unnamedArrivals.insert(tabId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.unnamedArrivals.remove(tabId)
                }
            }
            return
        }
        tab.applyStoredTitle(name)
        observe(tab)
        persist()
    }

    /// Chromium reports the grouped tabs that Reopen Closed Window or a closed
    /// group's restore brings back as background link opens, then creates
    /// their group around them; they claim their names here.
    func groupCreated(tabIds: [Int], in state: BrowserState) {
        for tabId in tabIds where unnamedArrivals.remove(tabId) != nil {
            guard let tab = state.tabs.first(where: { $0.guid == tabId }) else { continue }
            arrived(tab, in: state, restoring: true, singleTabRestore: true)
        }
    }

    private func observe(_ tab: Tab) {
        watches[tab.guid] = tab.$url
            .sink { [weak self, weak tab] url in
                guard let self, let tab else { return }
                self.ledger.update(tabId: tab.guid, url: url ?? "", stripIndex: tab.index)
                self.pendingWrite?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.persist() }
                self.pendingWrite = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
    }

    func reordered(_ tab: Tab) {
        guard ledger.live[tab.guid] != nil else { return }
        ledger.update(tabId: tab.guid, url: tab.url ?? "", stripIndex: tab.index)
        persist()
    }

    func closing(tabId: Int, in state: BrowserState) {
        guard ledger.live[tabId]?.entry.windowId == state.windowId else { return }
        let generation = arrivals[tabId, default: 0]
        let windowId = state.windowId
        pendingCloses[tabId] = (windowId, generation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.settleClose(tabId: tabId, windowId: windowId, generation: generation)
        }
    }

    private func settleClose(tabId: Int, windowId: Int, generation: Int) {
        guard !ledger.isFrozen, let close = pendingCloses[tabId],
              close.windowId == windowId, close.generation == generation else { return }
        pendingCloses[tabId] = nil
        let reappeared = arrivals[tabId, default: 0] != generation
        ledger.close(tabId: tabId, windowId: windowId,
                     windowStillOpen: SpaceSessionControllersManager.shared.controller(for: windowId) != nil,
                     reappeared: reappeared)
        if !reappeared {
            watches[tabId] = nil
            arrivals[tabId] = nil
        }
        persist()
    }

    func freeze() {
        guard !ledger.isFrozen else { return }
        persist()
        ledger.isFrozen = true
        pendingWrite?.cancel()
    }

    func unfreeze() {
        ledger.isFrozen = false
        for (tabId, close) in Array(pendingCloses) {
            settleClose(tabId: tabId, windowId: close.windowId, generation: close.generation)
        }
        persist()
    }

    private func persist() {
        guard let entries = ledger.persistedEntries,
              let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
