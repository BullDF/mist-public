import Combine
import Foundation

/// One-way projection of native bookmarks and pins into autocomplete's model.
@MainActor
final class MistChromiumBookmarkMirror {
    static let shared = MistChromiumBookmarkMirror()

    struct Entry: Hashable {
        let url: String
        let title: String
    }

    struct Source {
        let url: String?
        let title: String?
        let secondaryUrl: String?
        let secondaryTitle: String?
    }

    struct Node {
        let id: Int
        let entry: Entry
    }

    nonisolated static func desiredEntries(from sources: [Source]) -> [Entry] {
        sources.flatMap { source -> [Entry] in
            var entries: [Entry] = []
            if let url = source.url, !url.isEmpty {
                entries.append(Entry(url: url, title: source.title ?? ""))
            }
            if let url = source.secondaryUrl, !url.isEmpty {
                entries.append(Entry(url: url, title: source.secondaryTitle ?? source.title ?? ""))
            }
            return entries
        }
    }

    nonisolated static func currentNodes(from roots: [BookmarkWrapper]) -> (pages: [Node], folders: [Int]) {
        var pages: [Node] = []
        var folders: [Int] = []
        func visit(_ node: BookmarkWrapper, isRoot: Bool) {
            if node.isFolder {
                for child in node.children { visit(child, isRoot: false) }
                // Remove children before parents so no later removal uses a
                // folder ID already deleted as part of its ancestor.
                if !isRoot { folders.append(node.guid) }
            } else {
                pages.append(Node(id: node.guid,
                                  entry: Entry(url: node.urlString ?? "", title: node.title ?? "")))
            }
        }
        for root in roots { visit(root, isRoot: true) }
        return (pages, folders)
    }

    nonisolated static func plan(desired: [Entry], current: [Node]) -> (remove: [Int], add: [Entry]) {
        var available: [Entry: Int] = [:]
        for node in current { available[node.entry, default: 0] += 1 }
        var consumed: [Entry: Int] = [:]
        var add: [Entry] = []
        for entry in desired {
            if consumed[entry, default: 0] < available[entry, default: 0] {
                consumed[entry, default: 0] += 1
            } else {
                add.append(entry)
            }
        }
        var remove: [Int] = []
        for node in current {
            if consumed[node.entry, default: 0] > 0 {
                consumed[node.entry, default: 0] -= 1
            } else {
                remove.append(node.id)
            }
        }
        return (remove, add)
    }

    nonisolated static func bookmarkBarRoot(in roots: [BookmarkWrapper]) -> BookmarkWrapper? {
        roots.first { $0.indexInParent == 0 && $0.isFolder }
    }

    private struct WeakState {
        weak var value: BrowserState?
    }

    private final class Profile {
        weak var store: LocalStore?
        var states: [WeakState] = []
        var entries: [Entry]?
        var subscription: AnyCancellable?
        var closeSubscription: AnyCancellable?
        var retry: DispatchWorkItem?
        var loadAttempts = 0

        init(store: LocalStore) { self.store = store }

        deinit { retry?.cancel() }
    }

    private var profiles: [String: Profile] = [:]

    func register(_ state: BrowserState) {
        guard !state.isIncognito, !state.isAgentSpace else { return }
        let profileId = state.profileId
        let profile: Profile
        if let existing = profiles[profileId], existing.store === state.localStore {
            profile = existing
        } else {
            profile = Profile(store: state.localStore)
            profiles[profileId] = profile
            profile.closeSubscription = NotificationCenter.default
                .publisher(for: LocalStore.willCloseNotification, object: state.localStore)
                .sink { [weak self, weak profile] _ in
                    MainActor.assumeIsolated {
                        guard let self, let profile, self.profiles[profileId] === profile else { return }
                        self.profiles.removeValue(forKey: profileId)
                    }
                }
            profile.subscription = state.localStore.mistSuggestionSourcesPublisher(profileId: profileId)
                // Snapshot values before debounce: SwiftData objects may be
                // refreshed or deleted while waiting for the next delivery.
                .map { rows in
                    Self.desiredEntries(from: rows.map { row in
                        let title = row.dataType == .bookmark
                            ? row.overrideTitle.flatMap { $0.isEmpty ? nil : $0 } ?? row.title
                            : row.title
                        return Source(url: row.url.absoluteString, title: title,
                                      secondaryUrl: row.secondaryUrl?.absoluteString,
                                      secondaryTitle: row.secondaryTitle)
                    })
                }
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self, weak profile] entries in
                    guard let self, let profile, self.profiles[profileId] === profile else { return }
                    profile.entries = entries
                    profile.loadAttempts = 0
                    self.scheduleSync(profileId: profileId)
                }
        }
        profile.states.removeAll { $0.value == nil }
        if !profile.states.contains(where: { $0.value === state }) {
            profile.states.append(WeakState(value: state))
        }
        profile.loadAttempts = 0
        scheduleSync(profileId: profileId)
    }

    private func scheduleSync(profileId: String, after delay: TimeInterval = 0) {
        guard let profile = profiles[profileId] else { return }
        profile.retry?.cancel()
        let work = DispatchWorkItem { [weak self, weak profile] in
            MainActor.assumeIsolated {
                guard let self, let profile, self.profiles[profileId] === profile else { return }
                profile.retry = nil
                self.sync(profileId: profileId)
            }
        }
        profile.retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func retryLoading(profileId: String) {
        guard let profile = profiles[profileId], profile.loadAttempts < 15 else { return }
        profile.loadAttempts += 1
        scheduleSync(profileId: profileId, after: 2)
    }

    private func sync(profileId: String) {
        guard let profile = profiles[profileId], let desired = profile.entries,
              let state = profile.states.compactMap(\.value).first(where: {
                  !$0.isIncognito && !$0.isAgentSpace && $0.profileId == profileId
                      && $0.localStore === profile.store
                      && SpaceSessionControllersManager.shared.getBrowserState(for: $0.windowId) === $0
              }) else { return }

        let spaceIds = state.localStore.getAllSpaces(profileId: profileId).map(\.spaceId)
            + [LocalStore.defaultSpaceId]
        guard !spaceIds.contains(where: { ImportTargetLock.shared.isImporting(into: $0) }) else {
            scheduleSync(profileId: profileId, after: 5)
            return
        }
        let windowId = Int64(state.windowId)
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            retryLoading(profileId: profileId)
            return
        }
        let roots = bridge.getAllBookmarks(withWindowId: windowId)
        guard let bar = Self.bookmarkBarRoot(in: roots) else {
            retryLoading(profileId: profileId)
            return
        }
        profile.loadAttempts = 0
        let initial = Self.currentNodes(from: roots)
        for id in initial.folders { bridge.removeBookmark(withId: id, windowId: windowId) }
        // Entries under another permanent root must move to the bar even if
        // their URL and title already match. Permanent roots themselves stay.
        let misplaced = roots.filter { $0.guid != bar.guid }.flatMap { root in
            root.children.filter { !$0.isFolder }.map(\.guid)
        }
        for id in misplaced { bridge.removeBookmark(withId: id, windowId: windowId) }
        var currentRoots = roots
        if !initial.folders.isEmpty || !misplaced.isEmpty {
            currentRoots = bridge.getAllBookmarks(withWindowId: windowId)
        }
        guard let currentBar = Self.bookmarkBarRoot(in: currentRoots) else {
            retryLoading(profileId: profileId)
            return
        }
        let current = Self.currentNodes(from: currentRoots)
        let changes = Self.plan(desired: desired, current: current.pages)
        let changedStructure = !initial.folders.isEmpty || !misplaced.isEmpty
        guard changedStructure || !changes.remove.isEmpty || !changes.add.isEmpty else { return }
        for id in changes.remove { bridge.removeBookmark(withId: id, windowId: windowId) }
        for entry in changes.add {
            bridge.addBookmark(withURL: entry.url, title: entry.title, parent: currentBar.guid, windowId: windowId)
        }

        let removed = initial.pages.count - current.pages.count + changes.remove.count
        AppLogInfo("[MistBookmarkMirror] Removed \(removed), added \(changes.add.count), total \(desired.count) for \(profileId)")
        let verifiedRoots = bridge.getAllBookmarks(withWindowId: windowId)
        let remaining = Self.plan(desired: desired, current: Self.currentNodes(from: verifiedRoots).pages)
        if !remaining.remove.isEmpty || !remaining.add.isEmpty {
            AppLogError("[MistBookmarkMirror] Verification failed for \(profileId): remove \(remaining.remove.count), add \(remaining.add.count)")
        }
    }
}
