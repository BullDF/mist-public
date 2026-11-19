import Foundation

struct MistBrowserSyncProfile: Equatable {
    var localID: String
    var syncID: String?
    var name: String
    var excluded = false
}

struct MistBrowserSyncSpace: Equatable {
    var localID: String
    var profile: String
    var name: String
    var color = "#3A6FF8"
    var icon = "default"
    var order = 0
    var excluded = false
}

struct MistBrowserSyncBookmark: Equatable {
    var localID: String
    var syncID: String?
    var space: String
    var parent: String?
    var index = 0
    var folder = false
    var title: String
    var url: String
    var secondaryURL: String?
    var secondaryTitle: String?
    var layout: String?
    var excluded = false
}

struct MistBrowserSyncData {
    var profiles: [MistBrowserSyncProfile] = []
    var spaces: [MistBrowserSyncSpace] = []
    var bookmarks: [MistBrowserSyncBookmark] = []

    var eligible: Self {
        // An agent-owned profile and every Space using it stay local.
        let profiles = profiles.filter { !$0.excluded }
        let profileIDs = Set(profiles.map(\.localID))
        let spaces = spaces.filter { !$0.excluded && profileIDs.contains($0.profile) }
        let spaceIDs = Set(spaces.map(\.localID))
        return Self(profiles: profiles, spaces: spaces,
                    bookmarks: bookmarks.filter { !$0.excluded && spaceIDs.contains($0.space) })
    }
}

@MainActor
protocol MistBrowserDataSyncStorage: AnyObject {
    var didChange: (() -> Void)? { get set }
    func read() throws -> MistBrowserSyncData
    func identify(kind: String, localID: String, syncID: String) throws
    func writeProfile(_ profile: MistBrowserSyncProfile) async throws -> String
    func writeSpace(_ space: MistBrowserSyncSpace) async throws
    func writeBookmark(_ bookmark: MistBrowserSyncBookmark) async throws
    func delete(kind: String, localID: String) async throws
    func reorderSpaces(_ localIDs: [String]) async throws
    func reorderBookmarks(_ localIDs: [String]) async throws
}
