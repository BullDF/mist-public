import Foundation

struct TabNameLedger {
    struct Entry: Codable, Equatable {
        var spaceId: String
        var windowId: Int
        var url: String
        var name: String
        var stripIndex: Int
    }

    struct Live {
        var entry: Entry
        var persists: Bool
    }

    private(set) var live: [Int: Live] = [:]
    private(set) var unclaimed: [Entry]
    private(set) var recentlyClosed: [Live] = []
    var isFrozen = false

    init(entries: [Entry] = [], spaceIds: Set<String>) {
        unclaimed = entries.filter { spaceIds.contains($0.spaceId) }
    }

    var persistedEntries: [Entry]? {
        guard !isFrozen else { return nil }
        return (unclaimed + live.values.filter(\.persists).map(\.entry)).sorted {
            if $0.spaceId != $1.spaceId { return $0.spaceId < $1.spaceId }
            if $0.windowId != $1.windowId { return $0.windowId < $1.windowId }
            return $0.stripIndex < $1.stripIndex
        }
    }

    mutating func set(_ name: String?, tabId: Int, entry: Entry, persists: Bool) {
        guard let name, !name.isEmpty else { live[tabId] = nil; return }
        var entry = entry
        entry.name = name
        live[tabId] = Live(entry: entry, persists: persists)
    }

    mutating func arrive(tabId: Int, entry: Entry, persists: Bool,
                         restoreSource: Int, restoring: Bool, singleTabRestore: Bool) -> String? {
        var claimed = live[tabId]
        if claimed == nil, singleTabRestore,
           let index = recentlyClosed.lastIndex(where: {
               $0.entry.spaceId == entry.spaceId && $0.entry.url == entry.url && $0.persists == persists
           }) {
            claimed = recentlyClosed.remove(at: index)
        }
        if claimed == nil, persists, restoring, restoreSource != 0,
           let index = unclaimed.indices.filter({
               unclaimed[$0].spaceId == entry.spaceId && unclaimed[$0].windowId == restoreSource
                   && unclaimed[$0].url == entry.url
           }).min(by: { unclaimed[$0].stripIndex < unclaimed[$1].stripIndex }) {
            claimed = Live(entry: unclaimed.remove(at: index), persists: persists)
        }
        guard let name = claimed?.entry.name else { return nil }
        set(name, tabId: tabId, entry: entry, persists: persists)
        return name
    }

    mutating func update(tabId: Int, url: String, stripIndex: Int) {
        live[tabId]?.entry.url = url
        live[tabId]?.entry.stripIndex = stripIndex
    }

    mutating func close(tabId: Int, windowId: Int, windowStillOpen: Bool, reappeared: Bool) {
        guard !isFrozen, !reappeared, let value = live[tabId],
              value.entry.windowId == windowId else { return }
        live[tabId] = nil
        if windowStillOpen { recentlyClosed.append(value) }
        else if value.persists { unclaimed.append(value.entry) }
    }
}
