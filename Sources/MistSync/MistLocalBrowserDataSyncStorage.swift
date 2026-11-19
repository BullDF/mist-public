#if !MIST_SYNC_HOSTLESS_TESTS
import Combine
import CoreData
import Foundation
import SwiftData

@MainActor
final class MistLocalBrowserDataSyncStorage: MistBrowserDataSyncStorage {
    var didChange: (() -> Void)?
    private let storeProvider: () -> LocalStore?
    private let spaces: SpaceManager
    private let profiles: ProfileManager
    private let profileList: () -> [PhiBrowserProfile]
    private var subscriptions = Set<AnyCancellable>()

    init(store: @escaping () -> LocalStore? = { AccountController.shared.localDataAccount.localStorage },
         spaces: SpaceManager = .shared, profiles: ProfileManager = .shared,
         profileList: (() -> [PhiBrowserProfile])? = nil) {
        storeProvider = store
        self.spaces = spaces
        self.profiles = profiles
        self.profileList = profileList ?? { profiles.profiles }
        NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .filter { notification in
                LocalStore.notificationContainsChanges(notification, matching: {
                    if $0.entity.name == SpaceModel.entityName { return true }
                    guard $0.entity.name == TabDataModel.entityName,
                          let type = LocalStore.tabType(from: $0) else { return false }
                    return type == TabDataType.bookmark.rawValue || type == TabDataType.bookmarkFolder.rawValue
                })
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.didChange?() }.store(in: &subscriptions)
        profiles.$profiles.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.didChange?() }.store(in: &subscriptions)
    }

    private func store() throws -> LocalStore {
        guard let store = storeProvider(), store.mainContext != nil,
              !store.isClosedForAccountDirectoryRemoval,
              spaces.acceptsStoreAction(from: store.identifier) else { throw LocalStoreWriteError.storeUnavailable }
        return store
    }

    func read() throws -> MistBrowserSyncData {
        let store = try store()
        let context = store.mainContext!
        let list = profileList()
        // A bridge that has not initialized is not an empty user profile list.
        guard !list.isEmpty else { throw LocalStoreWriteError.storeUnavailable }
        let spaceRows = try context.fetch(FetchDescriptor<SpaceModel>())
        let excludedSpaces = Set(spaceRows.filter {
            SpaceManager.isIncognitoSpaceId($0.spaceId)
                || AgentSpaceManager.shared.isAgentSpace($0.spaceId)
                || AgentSpaceManager.shared.isAgentOwned($0.spaceId)
                || AgentSpaceManager.isAgentSpaceModel(name: $0.name, iconName: $0.iconName, colorHex: $0.colorHex)
                || AgentSpaceManager.isPersistentAgentSpaceModel(iconName: $0.iconName, colorHex: $0.colorHex)
        }.map(\.spaceId))
        let profileRows = try context.fetch(FetchDescriptor<ProfileModel>())
        let roots = Set(spaceRows.compactMap { $0.bookmarkRoot?.guid } + profileRows.compactMap { $0.bookmarkRoot?.guid })
        let profiles = list.map { profile in
            MistBrowserSyncProfile(localID: profile.profileId,
                syncID: profileRows.first { $0.profileId == profile.profileId }?.syncId,
                name: profile.displayName,
                excluded: false)
        }
        let spaces = spaceRows.map {
            MistBrowserSyncSpace(localID: $0.spaceId, profile: $0.profileId, name: $0.name,
                color: $0.colorHex, icon: $0.iconName, order: $0.sortOrder, excluded: excludedSpaces.contains($0.spaceId))
        }
        let bookmark = TabDataType.bookmark.rawValue, folder = TabDataType.bookmarkFolder.rawValue
        let rows = try context.fetch(FetchDescriptor<TabDataModel>(predicate: #Predicate { $0.type == bookmark || $0.type == folder }))
        let bookmarks = rows.filter { !roots.contains($0.guid) }.map {
            MistBrowserSyncBookmark(localID: $0.guid, syncID: $0.syncId, space: $0.spaceId ?? LocalStore.defaultSpaceId,
                parent: $0.parent.flatMap { roots.contains($0.guid) ? nil : $0.guid }, index: $0.index,
                folder: $0.dataType == .bookmarkFolder, title: $0.title, url: $0.url.absoluteString,
                secondaryURL: $0.secondaryUrl?.absoluteString, secondaryTitle: $0.secondaryTitle, layout: $0.layout)
        }
        return MistBrowserSyncData(profiles: profiles, spaces: spaces, bookmarks: bookmarks)
    }

    func identify(kind: String, localID: String, syncID: String) throws {
        let store = try store()
        let context = store.mainContext!
        if kind == "profile" {
            guard let row = try store.profile(with: localID) else { throw MistSyncError.invalidRecord }
            row.syncId = syncID
        } else {
            guard let row = store.fetchBookmark(with: localID) else { throw MistSyncError.invalidRecord }
            row.syncId = syncID
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func writeProfile(_ value: MistBrowserSyncProfile) async throws -> String {
        let store = try store()
        var id = value.localID
        if id.isEmpty {
            let created: String? = await withCheckedContinuation { continuation in
                profiles.createProfile(displayName: value.name, allowsDuplicateDisplayName: true) { continuation.resume(returning: $0) }
            }
            guard let created else { throw MistSyncError.invalidRecord }
            id = created
        } else if profileList().first(where: { $0.profileId == id })?.displayName != value.name {
            let success: Bool = await withCheckedContinuation { continuation in
                profiles.renameProfile(id, to: value.name, allowsDuplicateDisplayName: true) { ok, _ in continuation.resume(returning: ok) }
            }
            guard success else { throw MistSyncError.invalidRecord }
        }
        guard storeProvider() === store else { throw LocalStoreWriteError.storeUnavailable }
        try identify(kind: "profile", localID: id, syncID: value.syncID!)
        return id
    }

    func writeSpace(_ value: MistBrowserSyncSpace) async throws {
        let store = try store()
        guard !ImportTargetLock.shared.isImporting(into: value.localID) else { throw LocalStoreWriteError.targetNotWritable }
        if let old = store.getAllSpaces().first(where: { $0.spaceId == value.localID }) {
            if old.profileId != value.profile {
                spaces.changeProfile(spaceId: value.localID, toProfileId: value.profile,
                    expectedStoreIdentifier: store.identifier, allowsDefaultSpace: true)
            }
            spaces.renameSpace(spaceId: value.localID, to: value.name, expectedStoreIdentifier: store.identifier)
            spaces.recolorSpace(spaceId: value.localID, colorHex: value.color, expectedStoreIdentifier: store.identifier)
            spaces.changeIcon(spaceId: value.localID, iconName: value.icon, expectedStoreIdentifier: store.identifier)
        } else {
            guard spaces.createSpace(name: value.name, colorHex: value.color, iconName: value.icon,
                profileId: value.profile, makeDefaultActive: false, spaceId: value.localID) != nil else { throw MistSyncError.invalidRecord }
        }
        try await store.performBackgroundWriteAndWaitThrowing { _ in }
        guard store.getAllSpaces().contains(where: { $0.spaceId == value.localID && $0.profileId == value.profile }) else {
            throw MistSyncError.invalidRecord
        }
    }

    func writeBookmark(_ value: MistBrowserSyncBookmark) async throws {
        let store = try store()
        guard let space = store.getAllSpaces().first(where: { $0.spaceId == value.space }) else { throw MistSyncError.invalidRecord }
        try await store.applyMistSyncBookmark(value, profileId: space.profileId)
    }

    func delete(kind: String, localID: String) async throws {
        let store = try store()
        switch kind {
        case "bookmark":
            guard let row = store.fetchBookmark(with: localID) else { return }
            try await store.deleteMistSyncBookmark(localID, profileId: row.profileId ?? row.profile!.profileId)
        case "space":
            guard !ImportTargetLock.shared.isImporting(into: localID) else { throw LocalStoreWriteError.targetNotWritable }
            spaces.deleteSpace(spaceId: localID, expectedStoreIdentifier: store.identifier)
            // Deletion can await window retirement before enqueuing its cascade.
            let deadline = Date().addingTimeInterval(15)
            while store.getAllSpaces().contains(where: { $0.spaceId == localID }) {
                guard Date() < deadline, storeProvider() === store else { throw MistSyncError.invalidRecord }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        case "profile":
            guard localID != LocalStore.defaultProfileId else { return }
            guard !spaces.isProfileInUse(localID) else { throw MistSyncError.invalidRecord }
            let success: Bool = await withCheckedContinuation { continuation in
                profiles.deleteProfile(localID) {
                    ok, _ in continuation.resume(returning: ok)
                }
            }
            guard success else { throw MistSyncError.invalidRecord }
        default: throw MistSyncError.unknownKind
        }
    }

    func reorderSpaces(_ localIDs: [String]) async throws {
        let store = try store()
        let existing = store.getAllSpaces().sorted { $0.sortOrder < $1.sortOrder }.map(\.spaceId)
        // Preserve the relative order of excluded Spaces after normal ones.
        spaces.reorder(spaceIds: localIDs + existing.filter { !localIDs.contains($0) }, expectedStoreIdentifier: store.identifier)
        try await store.performBackgroundWriteAndWaitThrowing { _ in }
    }

    func reorderBookmarks(_ localIDs: [String]) async throws {
        try await store().reorderMistSyncBookmarks(localIDs)
    }
}
#endif
