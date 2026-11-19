import Foundation

@MainActor
final class MistMemoryBrowserDataStore: MistBrowserDataSyncStorage {
    var didChange: (() -> Void)?
    var data = MistBrowserSyncData()
    var beforeProfileWrite: (() async throws -> Void)?
    var failAfterBookmarkWrite = false
    func read() throws -> MistBrowserSyncData { data }
    func identify(kind: String, localID: String, syncID: String) throws {
        if kind == "profile", let i = data.profiles.firstIndex(where: { $0.localID == localID }) { data.profiles[i].syncID = syncID }
        if kind == "bookmark", let i = data.bookmarks.firstIndex(where: { $0.localID == localID }) { data.bookmarks[i].syncID = syncID }
    }
    func writeProfile(_ profile: MistBrowserSyncProfile) async throws -> String {
        try await beforeProfileWrite?()
        var profile = profile
        if profile.localID.isEmpty { profile.localID = UUID().uuidString }
        data.profiles.removeAll { $0.localID == profile.localID }
        data.profiles.append(profile)
        didChange?()
        return profile.localID
    }
    func writeSpace(_ space: MistBrowserSyncSpace) async throws {
        data.spaces.removeAll { $0.localID == space.localID }
        data.spaces.append(space)
        didChange?()
    }
    func writeBookmark(_ bookmark: MistBrowserSyncBookmark) async throws {
        data.bookmarks.removeAll { $0.localID == bookmark.localID }
        data.bookmarks.append(bookmark)
        var descendants: Set<String> = [bookmark.localID]
        var changed = true
        while changed {
            changed = false
            for i in data.bookmarks.indices where data.bookmarks[i].parent.map(descendants.contains) == true {
                if descendants.insert(data.bookmarks[i].localID).inserted { changed = true }
                data.bookmarks[i].space = bookmark.space
            }
        }
        didChange?()
        if failAfterBookmarkWrite {
            failAfterBookmarkWrite = false
            throw SyncTestFailure(description: "Injected failure after a bookmark commit")
        }
    }
    func delete(kind: String, localID: String) async throws {
        var removed: Set<String> = kind == "bookmark" ? [localID] : []
        if kind == "profile" {
            let spaces = Set(data.spaces.filter { $0.profile == localID }.map(\.localID))
            removed.formUnion(data.bookmarks.filter { spaces.contains($0.space) }.map(\.localID))
            data.spaces.removeAll { $0.profile == localID }
            data.profiles.removeAll { $0.localID == localID }
        }
        if kind == "space" {
            data.spaces.removeAll { $0.localID == localID }
            removed.formUnion(data.bookmarks.filter { $0.space == localID }.map(\.localID))
        }
        var count = -1
        while count != removed.count {
            count = removed.count
            removed.formUnion(data.bookmarks.filter { $0.parent.map(removed.contains) == true }.map(\.localID))
        }
        data.bookmarks.removeAll { removed.contains($0.localID) }
        didChange?()
    }
    func reorderSpaces(_ localIDs: [String]) async throws {
        for (index, id) in localIDs.enumerated() {
            if let i = data.spaces.firstIndex(where: { $0.localID == id }) { data.spaces[i].order = index }
        }
        didChange?()
    }
    func reorderBookmarks(_ localIDs: [String]) async throws {
        for (index, id) in localIDs.enumerated() {
            if let i = data.bookmarks.firstIndex(where: { $0.localID == id }) { data.bookmarks[i].index = index }
        }
        didChange?()
    }
}
