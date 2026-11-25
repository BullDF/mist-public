// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import SwiftData
import Combine

@ModelActor
actor LocalStoreActor {
    func perform(_ block: (ModelContext) -> Void) {
        block(modelContext)
        do {
            try modelContext.save()
        } catch {
            AppLogError("[LocalStore] save error: \(error)")
            modelContext.rollback()
        }
    }

    func performThrowing<Result: Sendable>(
        _ block: (ModelContext) throws -> Result
    ) throws -> Result {
        do {
            let result = try block(modelContext)
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

class LocalStore {
    /// Sent synchronously on the main actor before the terminal FIFO operation.
    static let willCloseNotification = Notification.Name("LocalStore.willClose")
    static let defaultProfileId = "Default"
    static let compatibilityConfiguration = LocalStoreCompatibilityConfiguration(
        currentStoreFormatVersion: 13,
        readableStoreFormatVersions: 1...13,
        storeFilename: "LocalStore.sqlite"
    )

    private(set) var container: ModelContainer?
    let account: Account
    /// Unique per open store, including a reopened account after rollback.
    let identifier = UUID()
    private let userStorageURL: URL
    private var cancellable: AnyCancellable?
    private var writeActor: LocalStoreActor?
    /// True only after an explicitly requested terminal migration barrier.
    /// A store that merely failed to open must not be mistaken for a sealed
    /// source that can resume from its durable migration snapshot.
    @MainActor private(set) var isClosedForAccountDirectoryRemoval = false

    /// Serial FIFO queue for background writes. `writeActor` serializes write
    /// *execution*, but `performBackgroundWrite` previously dispatched each
    /// write as an independent `Task`, and unstructured tasks carry no
    /// guarantee of reaching the actor in submission order. A "create record"
    /// write could therefore land after a follow-up "update field" write that
    /// targets it, and the update would silently no-op (its fetch finds no
    /// row). This broke pinned-split pairing: the `splitPartnerGuid` set right
    /// after the two pinned rows were created would sometimes apply before the
    /// rows existed, leaving the pair unlinked and rendering as two cells once
    /// the live SplitGroup went away (e.g. on close). Funnelling every write
    /// through this stream restores submit-order == apply-order, which every
    /// caller already assumes.
    private var writeJobContinuation: AsyncStream<() async -> Void>.Continuation?
    private(set) var compatibilityStatus: LocalStoreCompatibilityStatus = .notChecked

    @MainActor var mainContext: ModelContext? {
        container?.mainContext
    }
    
    init(
        account: Account,
        storeDirectoryURL: URL? = nil,
        presentsCompatibilityAlerts: Bool = true
    ) {
        self.account = account
        
        let userDir = account.userDataStorage
        let storeURL = storeDirectoryURL ?? userDir.appendingPathComponent("localDB")
        userStorageURL = storeURL
        if storeDirectoryURL == nil {
            Self.migrateOldDatabaseIfNeeded(from: userDir, to: storeURL)
        }
        
        try? FileManager.default.createDirectory(at: userStorageURL,
                                                 withIntermediateDirectories: true)

        let compatibilityController = LocalStoreCompatibilityController(
            configuration: Self.compatibilityConfiguration
        )
        let compatibilityResult: LocalStoreCompatibilityResult
        do {
            compatibilityResult = try compatibilityController.prepareStore(at: userStorageURL)
        } catch {
            AppLogError("[LocalStore] Failed to prepare local store compatibility state: \(error)")
            compatibilityStatus = .failed(error.localizedDescription)
            container = nil
            writeActor = nil
            writeJobContinuation = nil
            return
        }

        let openPlan: LocalStoreOpenPlan
        switch compatibilityResult {
        case .ready(let plan):
            compatibilityStatus = .ready(plan)
            openPlan = plan
        case .requiresNewerApp(let issue):
            AppLogError(
                "[LocalStore] Store format \(issue.activeStoreFormatVersion) requires a newer app. Current readable range: \(issue.readableStoreFormatVersions)"
            )
            compatibilityStatus = .requiresNewerApp(issue)
            container = nil
            writeActor = nil
            writeJobContinuation = nil
            if presentsCompatibilityAlerts {
                Self.runRequiresNewerAppAlert()
            }
            return
        }
        
        let configuration = ModelConfiguration(url: userStorageURL.appendingPathComponent("LocalStore.sqlite"))
        
        do {
            let modelContainer = try ModelContainer(
                for: TabDataModel.self,
                ProfileModel.self,
                SpaceModel.self,
                SpaceURLRule.self,
                BrowserDataSettingsModel.self,
                migrationPlan: TabDataModelMigrationPlan.self,
                configurations: configuration
            )
            container = modelContainer
            let actor = LocalStoreActor(modelContainer: modelContainer)
            writeActor = actor
            // Drain queued writes one at a time, in submission order. Buffering
            // is unbounded so no write is ever dropped, and yields made before
            // this consumer starts are replayed in order.
            let (stream, continuation) = AsyncStream<() async -> Void>.makeStream()
            writeJobContinuation = continuation
            Task {
                for await job in stream {
                    await job()
                }
            }
            do {
                try compatibilityController.markStoreOpenedSuccessfully(openPlan, at: userStorageURL)
            } catch {
                AppLogError("[LocalStore] Failed to record opened local store format: \(error)")
            }
            // Queue one-time duplicate-pin repair first: GUID-indexed readers can trap on existing duplicate
            // rows. Since repair is fire-and-forget, readers must also tolerate duplicate keys; both
            // protections are necessary (see healDuplicatePinnedTabRows).
            healDuplicatePinnedTabRows()
        } catch {
            AppLogError("Failed to create ModelContainer: \(error)")
            container = nil
            writeActor = nil
            writeJobContinuation = nil
        }
    }

    private static func runRequiresNewerAppAlert() {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("localData.compatibilityAlert.updateRequiredTitle", value: "Update Phi to Open Local Data",
                comment: "Local store compatibility alert - title when the local database was opened by a newer app version"
            )
            alert.informativeText = NSLocalizedString("localData.compatibilityAlert.newerVersionMessage", value: "This version of Phi cannot open local browser data that was updated by a newer version. Install the latest Phi version and try again.",
                comment: "Local store compatibility alert - body when a newer app is required to read local data"
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("localData.compatibilityAlert.dismissButton", value: "OK", comment: "Local data compatibility alert - Dismiss button"))
            alert.runModal()
        }
    }
}

// MARK: - Database Migration
extension LocalStore {
    private static func migrateOldDatabaseIfNeeded(from oldDir: URL, to newDir: URL) {
        let fileManager = FileManager.default
        let oldDBFile = oldDir.appendingPathComponent("LocalStore.sqlite")
        
        guard fileManager.fileExists(atPath: oldDBFile.path) else {
            AppLogDebug("No old database found, skipping migration")
            return
        }
        
        let newDBFile = newDir.appendingPathComponent("LocalStore.sqlite")
        if fileManager.fileExists(atPath: newDBFile.path) {
            AppLogDebug("New database already exists, skipping migration")
            return
        }
        
        AppLogInfo("Migrating database from \(oldDir.path) to \(newDir.path)")
        
        do {
            try fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)
            
            let filesToMigrate = [
                "LocalStore.sqlite",
                "LocalStore.sqlite-shm",
                "LocalStore.sqlite-wal",
            ]
            
            for fileName in filesToMigrate {
                let oldFile = oldDir.appendingPathComponent(fileName)
                let newFile = newDir.appendingPathComponent(fileName)
                
                if fileManager.fileExists(atPath: oldFile.path) {
                    try fileManager.moveItem(at: oldFile, to: newFile)
                    AppLogDebug("Migrated: \(fileName)")
                }
            }
            
            AppLogInfo("Database migration completed successfully")
        } catch {
            AppLogError("Failed to migrate database: \(error)")
        }
    }
}

// MARK: - Database Utilities

extension LocalStore {
    @MainActor
    func getAllPinnedTabs(
        for profileId: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            return try pinnedTabs(
                profileId: profileId,
                spaceId: spaceId,
                scope: pinnedTabScope(in: context),
                in: context
            )
        } catch {
            AppLogError("Failed to fetch pinned tabs for profile \(profileId), Space \(spaceId): \(error)")
            return []
        }
    }

    // Read operations use the main context.
    @MainActor
    func getAllTabs() -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
            let descriptor = FetchDescriptor<TabDataModel>(sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            AppLogError("Failed to fetch tabs: \(error)")
            return []
        }
    }
    
    @MainActor
    func getTab(by guid: String) -> TabDataModel? {
        guard let context = mainContext else { return nil }
        do {
            let predicate = #Predicate<TabDataModel> { $0.guid == guid }
            let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
            return try context.fetch(descriptor).first
        } catch {
            AppLogError("Failed to fetch tab with guid \(guid): \(error)")
            return nil
        }
    }
    
    func updateTabURL(_ guid: String, url: URL) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
                    tab.url = url
                    tab.needUpdateMetaData = true
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab URL: \(error)")
            }
        }
    }

    func updateTabTitle(_ guid: String, title: String) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
                    tab.title = title
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab title: \(error)")
            }
        }
    }

    /// Sets the persisted split-partner guid on a pinned tab record. Pass nil
    /// to clear it (called when a split is unpinned or one half is destroyed).
    /// Writes happen on the background actor, same as the other tab updates.
    func updateTabSplitPartner(_ guid: String, partnerGuid: String?) {
        performBackgroundWrite { context in
            do {
                try self.updateTabSplitPartnerBody(guid, partnerGuid: partnerGuid, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to update split partner: \(error)")
            }
        }
    }

    /// Persists both directions of a pinned split and its layout in one store
    /// transaction so subscribers never observe a paired row without the
    /// orientation that belongs to it.
    func updatePinnedSplitPair(primaryGuid: String,
                               secondaryGuid: String,
                               layout: String) {
        performBackgroundWrite { context in
            do {
                let primaryPredicate = #Predicate<TabDataModel> { $0.guid == primaryGuid }
                let secondaryPredicate = #Predicate<TabDataModel> { $0.guid == secondaryGuid }
                guard let primary = try context.fetch(
                    FetchDescriptor<TabDataModel>(predicate: primaryPredicate)
                ).first,
                let secondary = try context.fetch(
                    FetchDescriptor<TabDataModel>(predicate: secondaryPredicate)
                ).first,
                primary.dataType == .pinnedTab,
                secondary.dataType == .pinnedTab else {
                    AppLogWarn("[LocalStore] Pinned split pair not found for update")
                    return
                }
                let now = Date()
                primary.splitPartnerGuid = secondaryGuid
                primary.layout = layout
                primary.updatedDate = now
                secondary.splitPartnerGuid = primaryGuid
                secondary.layout = layout
                secondary.updatedDate = now
            } catch {
                AppLogError("[LocalStore] Failed to update pinned split pair: \(error)")
            }
        }
    }

    /// Updates the layout of an existing pinned split without changing its
    /// persisted partner linkage.
    func updatePinnedSplitLayout(firstGuid: String,
                                 secondGuid: String,
                                 layout: String) {
        performBackgroundWrite { context in
            do {
                let firstPredicate = #Predicate<TabDataModel> { $0.guid == firstGuid }
                let secondPredicate = #Predicate<TabDataModel> { $0.guid == secondGuid }
                guard let first = try context.fetch(
                    FetchDescriptor<TabDataModel>(predicate: firstPredicate)
                ).first,
                let second = try context.fetch(
                    FetchDescriptor<TabDataModel>(predicate: secondPredicate)
                ).first,
                first.dataType == .pinnedTab,
                second.dataType == .pinnedTab else {
                    AppLogWarn("[LocalStore] Pinned split rows not found for layout update")
                    return
                }
                guard first.layout != layout || second.layout != layout else { return }
                let now = Date()
                first.layout = layout
                first.updatedDate = now
                second.layout = layout
                second.updatedDate = now
            } catch {
                AppLogError("[LocalStore] Failed to update pinned split layout: \(error)")
            }
        }
    }

    func updateLastSeen(_ guid: String, seenAt: Date = Date()) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                guard let tab = try context.fetch(descriptor).first else {
                    return
                }
                switch tab.dataType {
                case .pinnedTab, .bookmark:
                    tab.lastSeen = seenAt
                    tab.updatedDate = seenAt
                case .tab, .bookmarkFolder:
                    return
                }
            } catch {
                AppLogError("[LocalStore] Failed to update last seen date: \(error)")
            }
        }
    }

    /// `sourceURLString` names the page the bytes were fetched for: a row
    /// whose URL is no longer that page is left alone. `onlyIfMissing`
    /// leaves a row that already holds bytes alone. The favicon backfill
    /// writes with both: a fetched icon must never replace one a visit put
    /// on the row first, nor land on a row the user re-pointed while the
    /// fetch was out, and deciding that on the serial writer is what keeps
    /// a live-path write queued ahead of it from being overwritten.
    func updateTabFavicon(_ guid: String,
                          favicon: Data,
                          sourceURLString: String? = nil,
                          onlyIfMissing: Bool = false) {
        updateTabFavicon(
            guid,
            favicon: favicon,
            sourceURLString: sourceURLString,
            pinnedOnly: false,
            onlyIfMissing: onlyIfMissing
        )
    }

    func updatePinnedTabFavicon(_ guid: String,
                                favicon: Data,
                                sourceURLString: String) {
        updateTabFavicon(
            guid,
            favicon: favicon,
            sourceURLString: sourceURLString,
            pinnedOnly: true,
            onlyIfMissing: false
        )
    }

    private func updateTabFavicon(_ guid: String,
                                  favicon: Data,
                                  sourceURLString: String?,
                                  pinnedOnly: Bool,
                                  onlyIfMissing: Bool) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
                    if pinnedOnly, tab.dataType != .pinnedTab {
                        return
                    }
                    if let sourceURLString {
                        guard let persistedURLString = canonicalFaviconURLString(tab.url.absoluteString),
                              canonicalFaviconURLString(sourceURLString) == persistedURLString else {
                            return
                        }
                    }
                    if onlyIfMissing, tab.favicon != nil {
                        return
                    }
                    if tab.favicon == favicon {
                        return
                    }
                    tab.favicon = favicon
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab favicon: \(error)")
            }
        }
    }

    func performBackgroundWrite(_ block: @escaping (ModelContext) -> Void) {
        guard let writeActor, let writeJobContinuation else { return }
        writeJobContinuation.yield {
            await writeActor.perform(block)
        }
    }

    func performBackgroundWriteAndWait(_ block: @escaping (ModelContext) -> Void) async {
        guard let writeActor, let writeJobContinuation else { return }
        // Enqueue through the same FIFO stream so ordering relative to async
        // writes is preserved, then await this job's completion.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeJobContinuation.yield {
                await writeActor.perform(block)
                continuation.resume()
            }
        }
    }

    func performBackgroundWriteAndWaitThrowing<Result: Sendable>(
        _ block: @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        guard let writeActor, let writeJobContinuation else {
            throw LocalStoreWriteError.storeUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            writeJobContinuation.yield {
                do {
                    let result = try await writeActor.performThrowing(block)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs one final FIFO-ordered store operation and then makes this
    /// LocalStore terminal before returning its result.
    ///
    /// The continuation is detached before the final job is enqueued, so a
    /// caller cannot submit a write between a cleanup snapshot and container
    /// release. Existing queued writes still run before the final operation.
    @MainActor
    func performFinalBackgroundOperationAndClose<Result: Sendable>(
        _ block: @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        guard let writeActor, let continuation = writeJobContinuation else {
            throw LocalStoreWriteError.storeUnavailable
        }

        writeJobContinuation = nil
        NotificationCenter.default.post(name: Self.willCloseNotification, object: self)
        let result: Result
        do {
            result = try await withCheckedThrowingContinuation {
                (resultContinuation: CheckedContinuation<Result, Error>) in
                continuation.yield {
                    do {
                        let value = try await writeActor.performThrowing(block)
                        resultContinuation.resume(returning: value)
                    } catch {
                        resultContinuation.resume(throwing: error)
                    }
                }
                continuation.finish()
            }
        } catch {
            releaseStoreForAccountDirectoryRemoval()
            throw error
        }

        releaseStoreForAccountDirectoryRemoval()
        return result
    }

    /// Drains all submitted writes and releases the SwiftData container before
    /// a verified account migration removes this store's directory.
    ///
    /// This is intentionally a terminal operation. Callers must freeze every
    /// consumer before closing and rebind them to another LocalStore before
    /// restoring interaction.
    @MainActor
    func closeForAccountDirectoryRemoval() async throws {
        guard writeActor != nil else { return }
        _ = try await performFinalBackgroundOperationAndClose { _ in () }
    }

    @MainActor
    private func releaseStoreForAccountDirectoryRemoval() {
        if let continuation = writeJobContinuation {
            continuation.finish()
        }
        writeJobContinuation = nil
        writeActor = nil
        cancellable?.cancel()
        cancellable = nil
        container = nil
        isClosedForAccountDirectoryRemoval = true
    }
    
    // Exposes the main context for UI-bound consumers.
    @MainActor
    func getMainContext() -> ModelContext? {
        return mainContext
    }
    
    /// Checks whether a `NSManagedObjectContextDidSave` notification contains
    /// any inserted/updated/deleted object satisfying `predicate`.
    static func notificationContainsChanges(
        _ notification: Notification,
        matching predicate: (NSManagedObject) -> Bool
    ) -> Bool {
        guard let userInfo = notification.userInfo else { return false }
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            if let objects = userInfo[key] as? Set<NSManagedObject>,
               objects.contains(where: predicate) {
                return true
            }
        }
        return false
    }

    static func tabType(from object: NSManagedObject) -> Int? {
        guard object.entity.attributesByName["type"] != nil else {
            return nil
        }
        return object.value(forKey: "type") as? Int
    }

    @MainActor
    func pinnedTabsPublisher(
        for profileID: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[TabDataModel], Never>([])

        let fetchPinnedTabs = {
            self.getAllPinnedTabs(for: profileID, spaceId: spaceId)
        }

        // Dedup must compare value snapshots, not the fetched objects: a
        // refetch returns the same registered instances refreshed in place by
        // the saving context, so an object-based `removeDuplicates` compared
        // every object against itself and swallowed field edits — pinned
        // URL/title edits never reached the per-space subscribers.
        var lastSnapshot: [PinnedTabSnapshot] = []

        // Subscribe before the first fetch, so a save between them still refetches.
        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: {
                        if $0.entity.name == BrowserDataSettingsModel.entityName {
                            return true
                        }
                        return $0.entity.name == TabDataModel.entityName &&
                            Self.tabType(from: $0) == TabDataType.pinnedTab.rawValue
                    }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let updatedTabs = fetchPinnedTabs()
                let snapshot = updatedTabs.map(PinnedTabSnapshot.init)
                guard snapshot != lastSnapshot else { return }
                lastSnapshot = snapshot
                subject.send(updatedTabs)
            }
        let initialTabs = fetchPinnedTabs()
        lastSnapshot = initialTabs.map(PinnedTabSnapshot.init)
        subject.send(initialTabs)

        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }

}

/// Value snapshot of a pinned-tab row used by `pinnedTabsPublisher` for
/// change detection across saves.
private struct PinnedTabSnapshot: Equatable {
    let guid: String
    let title: String
    let url: URL
    let index: Int
    let lastSeen: Date?
    let updatedDate: Date
    let splitPartnerGuid: String?
    let layout: String?
    let lineageId: String?
    let profileId: String?
    let spaceId: String?

    init(_ model: TabDataModel) {
        guid = model.guid
        title = model.title
        url = model.url
        index = model.index
        lastSeen = model.lastSeen
        updatedDate = model.updatedDate
        splitPartnerGuid = model.splitPartnerGuid
        layout = model.layout
        lineageId = model.pinLineageId
        profileId = model.profileId
        spaceId = model.spaceId
    }
}

extension LocalStore {
    func deleteProfileRowCascadeThrowing(profileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            let owner: String? = profileId
            for row in try context.fetch(FetchDescriptor<TabDataModel>(
                predicate: #Predicate { $0.profileId == owner && $0.spaceId == nil }
            )) {
                context.delete(row)
            }
            for profile in try context.fetch(FetchDescriptor<ProfileModel>(
                predicate: #Predicate { $0.profileId == profileId }
            )) {
                context.delete(profile)
            }
        }
    }

    @MainActor
    func profile(with profileId: String, createIfNeeded: Bool = true) throws -> ProfileModel? {
        guard let context = mainContext else { return nil }
        return try profile(with: profileId, in: context, createIfNeeded: createIfNeeded)
    }

    @MainActor
    func upsertProfileDisplayNames(_ displayNamesByProfileId: [String: String]) {
        guard let context = mainContext, !displayNamesByProfileId.isEmpty else { return }

        do {
            var didChange = false
            for (profileId, rawDisplayName) in displayNamesByProfileId {
                let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !profileId.isEmpty, !displayName.isEmpty,
                      let profile = try profile(with: profileId, in: context, createIfNeeded: true) else {
                    continue
                }
                if profile.displayName != displayName {
                    profile.displayName = displayName
                    didChange = true
                }
            }
            if didChange {
                try context.save()
            }
        } catch {
            AppLogError("[LocalStore] Failed to upsert profile display names: \(error)")
        }
    }

    func removePinnedTab(
        _ tab: Tab,
        profileId: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) {
        guard let guid = tab.guidInLocalDB else { return }
        performBackgroundWrite { context in
            do {
                guard let activeTab = try self.activePinnedTab(
                    resolving: guid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                ) else {
                    AppLogWarn("[LocalStore] Active pinned tab not found for removal: \(guid)")
                    return
                }
                context.delete(activeTab)
            } catch {
                AppLogError("[LocalStore] Failed to remove pinned tab: \(error)")
            }
        }
    }
    
    /// Creates a pinned-tab record directly from a URL — the headless
    /// counterpart of `moveOrCreatePinnedTab`, which needs a live `Tab`.
    /// The record lands at `index` (clamped; appended when nil) in the active
    /// pinned-tab scope and reaches every covered window through
    /// `pinnedTabsPublisher`, where it shows as a closed pinned tab.
    ///
    /// A caller that writes one source entry once per owner passes the same
    /// `lineageId` for every copy, so widening the scope later collapses them
    /// back into one entry; the row's own guid is its lineage when it is nil.
    ///
    /// Returns false when the URL cannot be parsed, in which case no row was
    /// created. True means the write was accepted onto the store's queue; it
    /// runs asynchronously from there and logs its own failures.
    @discardableResult
    func createPinnedTab(guid: String,
                         url: String,
                         title: String,
                         profileId: String,
                         spaceId: String = LocalStore.defaultSpaceId,
                         index: Int? = nil,
                         lineageId: String? = nil) -> Bool {
        guard let parsedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            AppLogWarn("[LocalStore] createPinnedTab: invalid URL \(url)")
            return false
        }
        performBackgroundWrite { context in
            do {
                try self.createPinnedTabBody(guid: guid,
                                             url: parsedURL,
                                             title: title,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             index: index,
                                             lineageId: lineageId,
                                             in: context)
            } catch {
                AppLogError("[LocalStore] Failed to create pinned tab: \(error)")
            }
        }
        return true
    }

    func moveOrCreatePinnedTab(_ tab: Tab,
                               after afterGuid: String?,
                               profileId: String,
                               spaceId: String = LocalStore.defaultSpaceId,
                               newGuid: String? = nil) {
        let tabGuid = tab.guidInLocalDB ?? UUID().uuidString
        let tabLineageId = tab.pinnedLineageId
        let tabTitle = tab.pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        let overrideTitle = tab.storedTitle.flatMap { $0.isEmpty ? nil : $0 }
        // Keep URL validation on the shared body's create branch: moving an existing row must still succeed
        // with an invalid URL. This conversion has no side effects.
        let tabURL = tab.url.flatMap { URL(string: $0) }
        performBackgroundWrite { context in
            do {
                try self.moveOrCreatePinnedTabBody(guid: tabGuid,
                                                   lineageId: tabLineageId,
                                                   title: tabTitle,
                                                   overrideTitle: overrideTitle,
                                                   url: tabURL,
                                                   after: afterGuid,
                                                   profileId: profileId,
                                                   spaceId: spaceId,
                                                   newGuid: newGuid,
                                                   in: context)
            } catch {
                AppLogError("[LocalStore] Failed to move tab: \(error)")
            }
        }
    }

    func profile(with profileId: String, in context: ModelContext, createIfNeeded: Bool) throws -> ProfileModel? {
        let descriptor = FetchDescriptor<ProfileModel>(
            predicate: #Predicate<ProfileModel> { $0.profileId == profileId }
        )
        let profiles: [ProfileModel] = try context.fetch(descriptor)
        if let existingProfile = profiles.first {
            return existingProfile
        }
        guard createIfNeeded else {
            return nil
        }
        let profile = ProfileModel(profileId: profileId)
        profile.createdDate = Date()
        context.insert(profile)
        return profile
    }
}
