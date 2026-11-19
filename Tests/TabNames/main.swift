import Foundation

func entry(_ name: String = "Name", space: String = "s", window: Int = 1,
           url: String = "https://example.com", index: Int = 0) -> TabNameLedger.Entry {
    .init(spaceId: space, windowId: window, url: url, name: name, stripIndex: index)
}

var ledger = TabNameLedger(spaceIds: ["s"])
ledger.set("Name", tabId: 1, entry: entry(), persists: true)
assert(ledger.live[1]?.entry.name == "Name")
ledger.update(tabId: 1, url: "https://next.example", stripIndex: 3)
assert(ledger.persistedEntries?.first?.url == "https://next.example")
assert(ledger.arrive(tabId: 1, entry: entry(space: "other", window: 2), persists: true,
                     restoreSource: 0, restoring: false, singleTabRestore: false) == "Name")
assert(ledger.live[1]?.entry.spaceId == "other" && ledger.live[1]?.entry.windowId == 2)
ledger.set(nil, tabId: 1, entry: entry(), persists: true)
assert(ledger.persistedEntries?.isEmpty == true)

ledger = TabNameLedger(entries: [entry("First"), entry("Second", index: 1), entry(space: "deleted")], spaceIds: ["s"])
assert(ledger.unclaimed.count == 2)
assert(ledger.arrive(tabId: 2, entry: entry(space: "wrong"), persists: true,
                     restoreSource: 1, restoring: true, singleTabRestore: false) == nil)
assert(ledger.arrive(tabId: 2, entry: entry(), persists: true,
                     restoreSource: 9, restoring: true, singleTabRestore: false) == nil)
assert(ledger.arrive(tabId: 2, entry: entry(url: "https://wrong.example"), persists: true,
                     restoreSource: 1, restoring: true, singleTabRestore: false) == nil)
for (id, name) in [(2, "First"), (3, "Second")] {
    assert(ledger.arrive(tabId: id, entry: entry(window: 10, index: id), persists: true,
                         restoreSource: 1, restoring: true, singleTabRestore: false) == name)
}
ledger.close(tabId: 2, windowId: 10, windowStillOpen: true, reappeared: true)
assert(ledger.live[2] != nil)
ledger.close(tabId: 2, windowId: 10, windowStillOpen: true, reappeared: false)
assert(ledger.persistedEntries?.count == 1 && ledger.recentlyClosed.count == 1)
assert(ledger.arrive(tabId: 4, entry: entry(window: 10), persists: true,
                     restoreSource: 0, restoring: true, singleTabRestore: true) == "First")
ledger.close(tabId: 3, windowId: 10, windowStillOpen: false, reappeared: false)
assert(ledger.persistedEntries?.count == 2 && ledger.unclaimed.count == 1)
ledger.set("Private", tabId: 5, entry: entry(), persists: false)
assert(ledger.persistedEntries?.count == 2)
ledger.isFrozen = true
ledger.close(tabId: 4, windowId: 10, windowStillOpen: true, reappeared: false)
assert(ledger.persistedEntries == nil && ledger.live[4] != nil)
ledger.isFrozen = false
assert(ledger.persistedEntries?.count == 2)

ledger = TabNameLedger(entries: [entry("Later", index: 4), entry("Earlier", index: 1)], spaceIds: ["s"])
assert(ledger.arrive(tabId: 6, entry: entry(window: 2), persists: true,
                     restoreSource: 1, restoring: true, singleTabRestore: false) == "Earlier")
ledger.set("Older close", tabId: 7, entry: entry(window: 2), persists: true)
ledger.close(tabId: 7, windowId: 2, windowStillOpen: true, reappeared: false)
ledger.set("Newest close", tabId: 8, entry: entry(window: 2), persists: true)
ledger.close(tabId: 8, windowId: 2, windowStillOpen: true, reappeared: false)
assert(ledger.arrive(tabId: 9, entry: entry(window: 2), persists: true,
                     restoreSource: 0, restoring: true, singleTabRestore: true) == "Newest close")
ledger.set("Private close", tabId: 10, entry: entry(), persists: false)
ledger.close(tabId: 10, windowId: 1, windowStillOpen: true, reappeared: false)
assert(ledger.arrive(tabId: 11, entry: entry(), persists: true,
                     restoreSource: 0, restoring: true, singleTabRestore: true) == "Older close")
assert(ledger.arrive(tabId: 12, entry: entry(), persists: false,
                     restoreSource: 0, restoring: true, singleTabRestore: true) == "Private close")
print("Tab name ledger checks passed")
