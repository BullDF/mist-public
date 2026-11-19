// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum PinnedTabScope: String, CaseIterable, Identifiable {
    case space
    case profile
    case app

    var id: String { rawValue }

    var hierarchyLevel: Int {
        switch self {
        case .space: 0
        case .profile: 1
        case .app: 2
        }
    }
}

enum LocalStoreWriteError: LocalizedError, Equatable {
    case storeUnavailable
    case rowAlreadyMapped
    case rowNotFound, rowIsRoot, invalidURL, targetNotWritable, noCandidateSurvived, rowNotInActiveScope
    /// A Space create named a `spaceId` a row already has; inserting it would overwrite that row.
    case spaceAlreadyExists
    var errorDescription: String? {
        switch self {
        case .rowNotFound, .rowIsRoot, .invalidURL, .targetNotWritable, .noCandidateSurvived, .rowNotInActiveScope, .rowAlreadyMapped, .spaceAlreadyExists:
            return nil
        case .storeUnavailable:
            return NSLocalizedString("localData.pinnedTabScope.unavailableError", value: "Local browser data is unavailable.",
                comment: "Pinned-tab scope migration error when the local store cannot be opened"
            )
        }
    }
}

private struct PinnedTabOwner: Hashable {
    let profileId: String?
    let spaceId: String?

    var sortKey: String {
        "\(profileId ?? "")\u{0}\(spaceId ?? "")"
    }
}

private struct PinnedTabContentSignature: Hashable {
    // Only fields that define the user-visible pinned item participate in
    // variant identity. Bookmark provenance/secondary fields are preserved on
    // the selected row but must not create indistinguishable pinned variants.
    let title: String
    let url: URL
}

private struct PinnedTabVariantSignature: Hashable {
    let content: PinnedTabContentSignature
    let splitPartnerLineageId: String?
    let splitPartnerContent: PinnedTabContentSignature?
    let layout: String?
}

private struct PinnedTabMergeCandidate {
    let source: TabDataModel
    let lineageId: String
    let signature: PinnedTabVariantSignature
    var sourceGuids: [String]
    var lastSeen: Date?
    /// Latest content-edit timestamp across merged copies, like `lastSeen`. Copies merge only when content
    /// signatures match, so any copy supplies identical content but their edit times can differ. Taking the
    /// maximum is order-independent and converges; taking only `source` could publish different stamps and
    /// cause repeated overwrites.
    var contentUpdatedDate: Date?
}

extension LocalStore {
    @MainActor
    func pinnedTabScope() -> PinnedTabScope {
        pinnedTabScopeIfReadable() ?? .profile
    }

    @MainActor
    func pinnedTabScopeIfReadable() -> PinnedTabScope? {
        guard let context = mainContext else { return nil }
        do {
            return try pinnedTabScope(in: context)
        } catch {
            AppLogError("[LocalStore] Failed to read pinned-tab scope: \(error)")
            return nil
        }
    }

    /// Changes the store-wide pinned-tab scope and migrates all currently
    /// active collections in the same save. Moving to a narrower scope copies
    /// each parent collection to its existing children. Moving to a broader
    /// scope merges child collections, collapsing unchanged copies by lineage
    /// while preserving divergent variants as separate pinned tabs.
    func changePinnedTabScope(
        to newScope: PinnedTabScope,
        preferredProfileId: String? = nil,
        preferredSpaceId: String? = nil
    ) async throws {
        try await changePinnedTabScopeJob(to: newScope, preferredProfileId: preferredProfileId,
                                          preferredSpaceId: preferredSpaceId)
    }

    /// The store transaction for `changePinnedTabScope`.
    private func changePinnedTabScopeJob(
        to newScope: PinnedTabScope,
        preferredProfileId: String?,
        preferredSpaceId: String?
    ) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            let currentScope = try self.pinnedTabScope(in: context)
            guard currentScope != newScope else { return }

            try self.migratePinnedTabs(
                from: currentScope,
                to: newScope,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId,
                in: context
            )
            let settings = try self.browserDataSettings(in: context, createIfNeeded: true)
            settings?.pinnedTabScopeRawValue = newScope.rawValue
        }
    }

    func pinnedTabScope(in context: ModelContext) throws -> PinnedTabScope {
        let settings = try browserDataSettings(in: context, createIfNeeded: false)
        return settings.flatMap { PinnedTabScope(rawValue: $0.pinnedTabScopeRawValue) } ?? .profile
    }

    func pinnedTabs(
        profileId: String,
        spaceId: String,
        scope: PinnedTabScope,
        in context: ModelContext
    ) throws -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sortBy = [SortDescriptor<TabDataModel>(\.index), SortDescriptor(\.guid)]
        let descriptor: FetchDescriptor<TabDataModel>
        switch scope {
        case .space:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == spaceId
                },
                sortBy: sortBy
            )
        case .profile:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        case .app:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    $0.profileId == nil &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        }
        return try context.fetch(descriptor)
    }

    func applyCurrentPinnedTabOwner(
        profileId: String,
        spaceId: String,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        let owner = Self.pinnedTabOwner(for: try pinnedTabScope(in: context),
                                        profileId: profileId,
                                        spaceId: spaceId)
        try applyPinnedTabOwner(owner, to: tab, in: context)
    }

    fileprivate static func pinnedTabOwner(for scope: PinnedTabScope,
                                           profileId: String,
                                           spaceId: String) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: profileId, spaceId: spaceId)
        case .profile:
            return PinnedTabOwner(profileId: profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    /// Returns whether a pinned row belongs to the store's currently selected
    /// scope. Inactive rows are retained as migration backups, so callers that
    /// mutate by physical guid must reject them rather than reporting success
    /// after changing data that no window can currently see.
    @MainActor
    func isPinnedTabInActiveScope(_ tab: TabDataModel) -> Bool {
        guard tab.dataType == .pinnedTab, let context = mainContext else {
            return false
        }
        do {
            return pinnedTab(tab, belongsTo: try pinnedTabScope(in: context))
        } catch {
            AppLogError("[LocalStore] Failed to validate pinned-tab scope membership: \(error)")
            return false
        }
    }

    @MainActor
    func isPinnedTabInActiveScope(guid: String) -> Bool {
        guard let tab = getTab(by: guid) else { return false }
        return isPinnedTabInActiveScope(tab)
    }

    /// Resolves a physical pinned guid against the collection currently owned
    /// by the requested window. A scope migration retains its source rows as
    /// inactive backups and creates new physical rows, so a UI action queued
    /// during that handoff can still carry the old guid. Resolve that backup
    /// through lineage and the complete persisted variant instead of mutating
    /// the invisible source row or creating a duplicate in the new scope.
    func activePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        in context: ModelContext
    ) throws -> TabDataModel? {
        let scope = try pinnedTabScope(in: context)
        let activeTabs = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        if let exact = activeTabs.first(where: { $0.guid == guid }) {
            return exact
        }

        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sourceDescriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let source = try context.fetch(sourceDescriptor).first,
              !pinnedTab(source, belongsTo: scope) else {
            // A guid owned by another active Space/Profile must never be
            // redirected into this window's collection.
            return nil
        }

        let lineageId = source.pinLineageId ?? source.guid
        let lineageMatches = activeTabs.filter {
            ($0.pinLineageId ?? $0.guid) == lineageId
        }
        guard !lineageMatches.isEmpty else { return nil }

        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw }
        ))
        // Use `uniquingKeysWith`: schema GUIDs are not unique, so duplicate rows would trap
        // `uniqueKeysWithValues` inside a write transaction. Keep the first row, matching
        // `pinnedTabRow(with:in:)`; see `healDuplicatePinnedTabRowsBody`.
        let rowsByGuid = Dictionary(allPinned.map { ($0.guid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let sourceSignature = pinnedTabVariantSignature(for: source, rowsByGuid: rowsByGuid)
        let exactVariants = lineageMatches.filter {
            pinnedTabVariantSignature(for: $0, rowsByGuid: rowsByGuid) == sourceSignature
        }
        if exactVariants.count == 1 {
            return exactVariants[0]
        }
        return lineageMatches.count == 1 ? lineageMatches[0] : nil
    }

    /// Updates a pinned record in the requested window's active owner. The
    /// owner-aware resolution keeps an edit sheet that straddles a scope
    /// migration from writing into the retained, invisible backup row.
    func updatePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        url: URL,
        title: String?,
        overrideTitle: String?? = nil
    ) {
        performBackgroundWrite { context in
            do {
                guard let activeTab = try self.activePinnedTab(
                    resolving: guid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                ) else {
                    AppLogWarn("[LocalStore] Active pinned tab not found for update: \(guid)")
                    return
                }
                var contentDidChange = activeTab.url != url
                activeTab.url = url
                activeTab.needUpdateMetaData = true
                if let title {
                    if activeTab.title != title { contentDidChange = true }
                    activeTab.title = title
                }
                if let overrideTitle {
                    let name = overrideTitle.flatMap { $0.isEmpty ? nil : $0 }
                    if activeTab.overrideTitle != name { contentDidChange = true }
                    activeTab.overrideTitle = name
                }
                let now = Date()
                if contentDidChange { activeTab.contentUpdatedDate = now }
                activeTab.updatedDate = now
            } catch {
                AppLogError("[LocalStore] Failed to update pinned tab: \(error)")
            }
        }
    }

    /// Executes an Agent/API mutation only while its exact physical guid is
    /// still part of the selected scope. Unlike a window-owned UI action, an
    /// API call has no unambiguous child Space to target after a narrowing
    /// migration, so a stale guid must fail closed instead of touching backup
    /// data or guessing an owner.
    func updateActivePinnedTab(
        guid: String,
        url: URL?,
        title: String?
    ) {
        // Preserve the entry-point no-op before enqueueing: it schedules no write and logs nothing, so this
        // path never reaches the equivalent shared-body guard.
        guard url != nil || title != nil else { return }
        performBackgroundWrite { context in
            do {
                try self.updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to update active pinned tab: \(error)")
            }
        }
    }

    /// Single implementation shared by both entry points.
    private func updateActivePinnedTabBody(
        guid: String,
        url: URL?,
        title: String?,
        in context: ModelContext
    ) throws {
        // Supplying no fields is a caller bug, not a successful no-op.
        guard url != nil || title != nil else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        // Keep assignments unconditional: skipping unchanged values would also skip `needUpdateMetaData` and
        // alter UI behavior. `contentDidChange` controls only `contentUpdatedDate`.
        var contentDidChange = false
        if let url {
            if tab.url != url { contentDidChange = true }
            tab.url = url
            tab.needUpdateMetaData = true
        }
        if let title {
            if tab.title != title { contentDidChange = true }
            tab.title = title
        }
        let now = Date()
        if contentDidChange {
            tab.contentUpdatedDate = now
        }
        tab.updatedDate = now
    }

    func removeActivePinnedTab(guid: String) {
        performBackgroundWrite { context in
            do {
                try self.removeActivePinnedTabBody(guid: guid, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to remove active pinned tab: \(error)")
            }
        }
    }

    /// Single implementation shared by both entry points.
    private func removeActivePinnedTabBody(guid: String, in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        context.delete(tab)
    }

    private func pinnedTabVariantSignature(
        for tab: TabDataModel,
        rowsByGuid: [String: TabDataModel]
    ) -> PinnedTabVariantSignature {
        let partner = tab.splitPartnerGuid.flatMap { rowsByGuid[$0] }
        return PinnedTabVariantSignature(
            content: contentSignature(for: tab),
            splitPartnerLineageId: partner.map { $0.pinLineageId ?? $0.guid },
            splitPartnerContent: partner.map { contentSignature(for: $0) },
            layout: tab.layout
        )
    }

    private func applyPinnedTabOwner(
        _ owner: PinnedTabOwner,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        tab.profileId = owner.profileId
        tab.spaceId = owner.spaceId
        if let profileId = owner.profileId {
            tab.profile = try profile(with: profileId, in: context, createIfNeeded: true)
        } else {
            tab.profile = nil
        }
    }

    private func browserDataSettings(
        in context: ModelContext,
        createIfNeeded: Bool
    ) throws -> BrowserDataSettingsModel? {
        let singletonId = BrowserDataSettingsModel.singletonId
        let descriptor = FetchDescriptor<BrowserDataSettingsModel>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        guard createIfNeeded else { return nil }
        let settings = BrowserDataSettingsModel()
        context.insert(settings)
        return settings
    }

    private func migratePinnedTabs(
        from sourceScope: PinnedTabScope,
        to targetScope: PinnedTabScope,
        preferredProfileId: String?,
        preferredSpaceId: String?,
        in context: ModelContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw },
            sortBy: [SortDescriptor(\.index), SortDescriptor(\.guid)]
        ))
        let activeSourceRows = allPinned.filter { pinnedTab($0, belongsTo: sourceScope) }
        // A Profile collection with no Space cannot be represented while Space
        // scope is active. Its rows remain logically live even though their
        // physical owner still has Profile shape, so include them alongside the
        // visible Space collections when leaving Space scope. The persisted bit
        // distinguishes them from ordinary, stale Profile migration backups if
        // Spaces are created, deleted, or re-profiled before the next change.
        let dormantSourceRows = sourceScope == .space
            ? allPinned.filter {
                $0.isPinnedTabDormant && pinnedTab($0, belongsTo: .profile)
            }
            : []
        let sourceRows = activeSourceRows + dormantSourceRows
        let targetRows = allPinned.filter { pinnedTab($0, belongsTo: targetScope) }

        // Old rows for an inactive target scope are backups, not migration
        // input. Rebuild that target from the currently active scope so
        // switching back never resurrects stale edits. Deletion happens after
        // insertion because dormant Profile rows are both logical source rows
        // and physical rows in the Profile-shaped target collection.

        let targetOwners = try pinnedTabTargetOwners(
            for: targetScope,
            sourceRows: sourceRows,
            in: context
        )
        // Keep the first row, as in `activePinnedTab(resolving:…)`: schema GUIDs are not unique, and
        // `uniqueKeysWithValues` would trap mid-migration. Rows sharing a GUID also share lineage by
        // construction, so either gives the same value.
        let lineageByGuid = Dictionary(sourceRows.map { ($0.guid, $0.pinLineageId ?? $0.guid) },
                                       uniquingKeysWith: { first, _ in first })

        for owner in targetOwners.sorted(by: { $0.sortKey < $1.sortKey }) {
            let collections = sourceCollections(
                from: sourceRows,
                sourceScope: sourceScope,
                targetScope: targetScope,
                targetOwner: owner,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId
            )
            let candidates = mergeCandidates(
                from: collections,
                lineageByGuid: lineageByGuid
            )
            try insertPinnedTabs(candidates, for: owner, in: context)
        }

        for row in targetRows {
            context.delete(row)
        }

        if sourceScope == .profile, targetScope == .space {
            let profileIdsWithSpaces = Set(
                try context.fetch(FetchDescriptor<SpaceModel>()).map(\.profileId)
            )
            for row in activeSourceRows {
                guard let profileId = row.profileId ?? row.profile?.profileId else {
                    row.isPinnedTabDormant = false
                    continue
                }
                row.isPinnedTabDormant = !profileIdsWithSpaces.contains(profileId)
            }
        } else {
            // Once a dormant collection has been represented in another active
            // scope, its retained physical rows become ordinary backups again.
            for row in dormantSourceRows where !targetRows.contains(where: { $0 === row }) {
                row.isPinnedTabDormant = false
            }
        }
    }

    private func pinnedTab(_ tab: TabDataModel, belongsTo scope: PinnedTabScope) -> Bool {
        switch scope {
        case .space:
            return tab.spaceId != nil
        case .profile:
            return (tab.profileId != nil || tab.profile != nil) && tab.spaceId == nil
        case .app:
            return tab.profileId == nil && tab.spaceId == nil
        }
    }

    private func pinnedTabTargetOwners(
        for scope: PinnedTabScope,
        sourceRows: [TabDataModel],
        in context: ModelContext
    ) throws -> Set<PinnedTabOwner> {
        switch scope {
        case .app:
            return [PinnedTabOwner(profileId: nil, spaceId: nil)]
        case .profile:
            let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let profileIds = Set(profiles.map(\.profileId))
                .union(sourceRows.compactMap { $0.profileId ?? $0.profile?.profileId })
            return Set(profileIds.map { PinnedTabOwner(profileId: $0, spaceId: nil) })
        case .space:
            let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
            return Set(spaces.map {
                PinnedTabOwner(profileId: $0.profileId, spaceId: $0.spaceId)
            })
        }
    }

    private func sourceCollections(
        from sourceRows: [TabDataModel],
        sourceScope: PinnedTabScope,
        targetScope: PinnedTabScope,
        targetOwner: PinnedTabOwner,
        preferredProfileId: String?,
        preferredSpaceId: String?
    ) -> [[TabDataModel]] {
        let relevantRows = sourceRows.filter { row in
            switch (sourceScope, targetScope) {
            case (.app, _), (_, .app):
                return true
            case (.profile, .space), (.space, .profile):
                return (row.profileId ?? row.profile?.profileId) == targetOwner.profileId
            default:
                return true
            }
        }
        let grouped = Dictionary(grouping: relevantRows) { row in
            owner(of: row, at: sourceScope)
        }
        let orderedOwners = grouped.keys.sorted { lhs, rhs in
            let lhsPreferred = isPreferred(
                lhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            let rhsPreferred = isPreferred(
                rhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.sortKey < rhs.sortKey
        }
        return orderedOwners.map { owner in
            (grouped[owner] ?? []).sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.guid < $1.guid
            }
        }
    }

    private func owner(of tab: TabDataModel, at scope: PinnedTabScope) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: tab.spaceId)
        case .profile:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    private func isPreferred(
        _ owner: PinnedTabOwner,
        scope: PinnedTabScope,
        profileId: String?,
        spaceId: String?
    ) -> Bool {
        switch scope {
        case .space:
            return owner.spaceId == spaceId
        case .profile:
            return owner.profileId == profileId
        case .app:
            return true
        }
    }

    private func mergeCandidates(
        from collections: [[TabDataModel]],
        lineageByGuid: [String: String]
    ) -> [PinnedTabMergeCandidate] {
        var candidates: [PinnedTabMergeCandidate] = []
        var candidateIndicesByLineage: [String: [Int]] = [:]

        for collection in collections {
            for source in collection {
                let lineageId = source.pinLineageId ?? source.guid
                let signature = PinnedTabVariantSignature(
                    content: contentSignature(for: source),
                    splitPartnerLineageId: source.splitPartnerGuid.flatMap { lineageByGuid[$0] },
                    splitPartnerContent: source.splitPartnerGuid
                        .flatMap { partnerGuid in
                            collections.lazy.flatMap { $0 }.first(where: { $0.guid == partnerGuid })
                        }
                        .map { contentSignature(for: $0) },
                    layout: source.layout
                )
                let matchingIndex = candidateIndicesByLineage[lineageId]?.first {
                    candidates[$0].signature == signature
                }
                if let matchingIndex {
                    candidates[matchingIndex].sourceGuids.append(source.guid)
                    if let lastSeen = source.lastSeen,
                       candidates[matchingIndex].lastSeen.map({ lastSeen > $0 }) ?? true {
                        candidates[matchingIndex].lastSeen = lastSeen
                    }
                    if let edited = source.contentUpdatedDate,
                       candidates[matchingIndex].contentUpdatedDate.map({ edited > $0 }) ?? true {
                        candidates[matchingIndex].contentUpdatedDate = edited
                    }
                    continue
                }

                let candidate = PinnedTabMergeCandidate(
                    source: source,
                    lineageId: lineageId,
                    signature: signature,
                    sourceGuids: [source.guid],
                    lastSeen: source.lastSeen,
                    contentUpdatedDate: source.contentUpdatedDate
                )
                candidates.append(candidate)
                candidateIndicesByLineage[lineageId, default: []].append(candidates.count - 1)
            }
        }
        return candidates
    }

    private func contentSignature(for tab: TabDataModel) -> PinnedTabContentSignature {
        PinnedTabContentSignature(
            title: tab.title,
            url: tab.url
        )
    }

    private func insertPinnedTabs(
        _ candidates: [PinnedTabMergeCandidate],
        for owner: PinnedTabOwner,
        in context: ModelContext
    ) throws {
        var targetModels: [TabDataModel] = []
        var candidateIndexBySourceGuid: [String: Int] = [:]

        for (index, candidate) in candidates.enumerated() {
            let source = candidate.source
            let model = TabDataModel(
                title: source.title,
                guid: UUID().uuidString,
                index: index,
                url: source.url,
                favicon: source.favicon,
                createdDate: source.createdDate,
                updatedDate: source.updatedDate
            )
            model.dataType = .pinnedTab
            model.overrideTitle = source.overrideTitle
            model.isOpenned = false
            model.isCreatedByChromium = source.isCreatedByChromium
            model.needUpdateMetaData = source.needUpdateMetaData
            model.source = source.source
            model.secondaryUrl = source.secondaryUrl
            model.secondaryTitle = source.secondaryTitle
            model.layout = source.layout
            model.lastSeen = candidate.lastSeen
            model.icon = source.icon
            model.contentUpdatedDate = candidate.contentUpdatedDate
            model.pinLineageId = candidate.lineageId
            // Insert before touching relationships, matching `moveOrCreatePinnedTabBody`.
            // `applyPinnedTabOwner` writes `profile`, whose inverse `ProfileModel.tabs` would otherwise
            // register a blank placeholder with six missing required fields. Every later save then fails
            // validation (NSCocoaErrorDomain 1560) until rollback.
            context.insert(model)
            try applyPinnedTabOwner(owner, to: model, in: context)
            targetModels.append(model)
            for sourceGuid in candidate.sourceGuids {
                candidateIndexBySourceGuid[sourceGuid] = index
            }
        }

        for (index, candidate) in candidates.enumerated() {
            guard let partnerGuid = candidate.source.splitPartnerGuid,
                  let partnerIndex = candidateIndexBySourceGuid[partnerGuid] else {
                targetModels[index].splitPartnerGuid = nil
                continue
            }
            targetModels[index].splitPartnerGuid = targetModels[partnerIndex].guid
        }
    }
}

extension LocalStore {
    func healDuplicatePinnedTabRows() {
        performBackgroundWrite { context in
            do {
                _ = try self.healDuplicatePinnedTabRowsBody(in: context)
            } catch {
                AppLogError("[LocalStore] Pinned-tab duplicate self-heal failed: \(error)")
            }
        }
    }

    /// Transaction body exposed for tests against a store with known contents.
    @discardableResult
    func healDuplicatePinnedTabRowsBody(
        in context: ModelContext
    ) throws -> (sharedGuid: Int, sharedIdentity: Int) {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == pinnedRaw }
        )
        // Owner derivation reads `profile?.profileId`; prefetch avoids a fault for each row.
        descriptor.relationshipKeyPathsForPrefetching = [\.profile]
        let rows = try context.fetch(descriptor)
        guard rows.count > 1 else { return (0, 0) }

        /// Order each group with the survivor first.
        func ordered(_ group: [(offset: Int, row: TabDataModel)])
            -> [(offset: Int, row: TabDataModel)] {
            group.sorted {
                if $0.row.index != $1.row.index { return $0.row.index < $1.row.index }
                if $0.row.createdDate != $1.row.createdDate {
                    return $0.row.createdDate < $1.row.createdDate
                }
                return $0.offset < $1.offset
            }
        }

        // 1. Shared GUIDs. Traverse group keys deterministically for repeatable results on the same rows.
        var byGuid: [String: [(offset: Int, row: TabDataModel)]] = [:]
        for (offset, row) in rows.enumerated() {
            byGuid[row.guid, default: []].append((offset: offset, row: row))
        }
        var sharedGuid = 0
        var survivors: [(offset: Int, row: TabDataModel)] = []
        var doomed: [TabDataModel] = []
        for key in byGuid.keys.sorted() {
            let group = ordered(byGuid[key] ?? [])
            guard let keeper = group.first else { continue }
            survivors.append(keeper)
            guard group.count > 1 else { continue }
            sharedGuid += group.count - 1
            // Keep split-partner backlinks: this GUID still exists and points to the survivor.
            doomed.append(contentsOf: group.dropFirst().map(\.row))
        }

        // 2. Exact identity duplicates among surviving, non-dormant rows only.
        let rowsByGuid = Dictionary(rows.map { ($0.guid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var byIdentity: [String: [(offset: Int, row: TabDataModel)]] = [:]
        for entry in survivors where !entry.row.isPinnedTabDormant {
            let lineage = (entry.row.pinLineageId ?? entry.row.guid).lowercased()
            let owner = entry.row.spaceId ?? entry.row.profileId ?? "app"
            byIdentity[lineage + "\u{0}" + owner, default: []].append(entry)
        }
        var sharedIdentity = 0
        for key in byIdentity.keys.sorted() {
            let group = ordered(byIdentity[key] ?? [])
            guard group.count > 1, let keeper = group.first else { continue }
            let keeperSignature = pinnedTabVariantSignature(for: keeper.row,
                                                            rowsByGuid: rowsByGuid)
            for entry in group.dropFirst()
            where pinnedTabVariantSignature(for: entry.row, rowsByGuid: rowsByGuid)
                == keeperSignature {
                sharedIdentity += 1
                // This GUID disappears with its row, so first clear partner links that would otherwise dangle
                // from survivors.
                try clearSplitPartnerBackReferenceBody(of: entry.row, in: context)
                doomed.append(entry.row)
            }
        }

        guard !doomed.isEmpty else { return (0, 0) }
        for row in doomed { context.delete(row) }
        AppLogWarn("[LocalStore] pins: startup self-heal collapsed \(sharedGuid) row(s) "
                   + "sharing a guid and \(sharedIdentity) exact duplicate row(s) of one identity")
        return (sharedGuid: sharedGuid, sharedIdentity: sharedIdentity)
    }

    /// Single implementation shared by both entry points.
    func createPinnedTabBody(guid: String,
                             url: URL,
                             title: String,
                             profileId: String,
                             spaceId: String,
                             index: Int?,
                             lineageId: String?,
                             in context: ModelContext) throws {
        if try pinnedTabRow(with: guid, in: context) != nil {
            AppLogWarn("[LocalStore] Refused a pinned-tab create on an existing guid")
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let now = Date()
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: url,
            favicon: nil,
            createdDate: now,
            updatedDate: now
        )
        model.dataType = .pinnedTab
        model.isCreatedByChromium = false
        model.pinLineageId = lineageId ?? guid
        // Insert before assigning ownership, as in `insertPinnedTabs`: `applyCurrentPinnedTabOwner` writes
        // `profile`, whose inverse would otherwise register a placeholder with missing required fields.
        context.insert(model)
        do {
            try applyCurrentPinnedTabOwner(
                profileId: profileId,
                spaceId: spaceId,
                to: model,
                in: context
            )
        } catch {
            // Remove the inserted row if ownership assignment fails. Fire-and-forget `createPinnedTab` only
            // logs the error, so `perform` would otherwise save a pin with no profile/profileId/spaceId:
            // invisible locally but permanently published under the app owner. Throwing callers also roll back
            // via `performThrowing`; explicit deletion keeps both paths correct.
            context.delete(model)
            throw error
        }
        let insertIndex = min(max(index ?? activePins.count, 0), activePins.count)
        activePins.insert(model, at: insertIndex)
        for (position, tabModel) in activePins.enumerated() {
            tabModel.index = position
            tabModel.updatedDate = now
        }
    }

    func moveOrCreatePinnedTabBody(guid tabGuid: String,
                                   lineageId tabLineageId: String?,
                                   title tabTitle: String,
                                   overrideTitle: String?,
                                   url tabURL: URL?,
                                   after afterGuid: String?,
                                   profileId: String,
                                   spaceId: String,
                                   newGuid: String?,
                                   in context: ModelContext) throws {
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let resolvedTabGuid = try activePinnedTab(
            resolving: tabGuid,
            profileId: profileId,
            spaceId: spaceId,
            in: context
        )?.guid
        let resolvedAfterGuid: String?
        if let afterGuid {
            guard let activeAfterTab = try activePinnedTab(
                resolving: afterGuid,
                profileId: profileId,
                spaceId: spaceId,
                in: context
            ) else {
                throw LocalStoreWriteError.rowNotFound
            }
            resolvedAfterGuid = activeAfterTab.guid
        } else {
            resolvedAfterGuid = nil
        }

        var tabToMove: TabDataModel
        // Track whether this call created the row. On ownership failure, remove only a new row; deleting an
        // existing row would destroy the user's pin.
        var didCreateRow = false
        let now = Date()
        if let resolvedTabGuid,
           let tabToMoveIndex = activePins.firstIndex(where: { $0.guid == resolvedTabGuid }) {
            tabToMove = activePins.remove(at: tabToMoveIndex)
        } else {
            guard tabLineageId == nil else {
                throw LocalStoreWriteError.rowNotInActiveScope
            }
            guard let url = tabURL else {
                throw LocalStoreWriteError.invalidURL
            }

            tabToMove = TabDataModel(
                title: tabTitle,
                guid: newGuid ?? UUID().uuidString,
                index: 0,
                url: url,
                favicon: nil,
                createdDate: now,
                updatedDate: now
            )
            tabToMove.dataType = .pinnedTab
            tabToMove.overrideTitle = overrideTitle
            tabToMove.isCreatedByChromium = false
            tabToMove.pinLineageId = tabLineageId ?? tabToMove.guid
            context.insert(tabToMove)
            didCreateRow = true
            AppLogInfo("[LocalStore] Created new pinned tab with guid: \(String(tabGuid.prefix(8)))")
        }

        if tabToMove.pinLineageId == nil {
            tabToMove.pinLineageId = tabToMove.guid
        }
        do {
            try applyCurrentPinnedTabOwner(
                profileId: profileId,
                spaceId: spaceId,
                to: tabToMove,
                in: context
            )
        } catch {
            // Like `createPinnedTabBody`, this has a fire-and-forget caller. Remove only a row created by this
            // call; preserve existing rows on the move path.
            if didCreateRow { context.delete(tabToMove) }
            throw error
        }

        let insertIndex: Int
        if let resolvedAfterGuid {
            guard let afterIndex = activePins.firstIndex(where: { $0.guid == resolvedAfterGuid }) else {
                throw LocalStoreWriteError.rowNotFound
            }
            insertIndex = afterIndex + 1
        } else {
            insertIndex = 0
        }

        activePins.insert(tabToMove, at: insertIndex)

        for (index, tabModel) in activePins.enumerated() {
            tabModel.index = index
            tabModel.updatedDate = now
        }
    }

    func updateTabSplitPartnerBody(_ guid: String,
                                   partnerGuid: String?,
                                   in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let predicate = #Predicate<TabDataModel> { $0.guid == guid && $0.type == pinnedRaw }
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        let layoutAlreadyCleared = partnerGuid != nil || tab.layout == nil
        guard tab.splitPartnerGuid != partnerGuid || !layoutAlreadyCleared else { return }
        tab.splitPartnerGuid = partnerGuid
        if partnerGuid == nil { tab.layout = nil }
        tab.updatedDate = Date()
    }


    /// Clear the link pointing back to this row in the same transaction before split-pin deletion. Write only
    /// if the partner still references this row; a stale one-way link must not break the partner's new pair.
    private func clearSplitPartnerBackReferenceBody(of tab: TabDataModel,
                                                    in context: ModelContext) throws {
        guard let partnerGuid = tab.splitPartnerGuid, partnerGuid != tab.guid,
              let partner = try pinnedTabRow(with: partnerGuid, in: context),
              partner.splitPartnerGuid == tab.guid else {
            return
        }
        try updateTabSplitPartnerBody(partnerGuid, partnerGuid: nil, in: context)
    }

    /// Resolve only a pin row by GUID. Ordinary tabs may share GUID space; matching any `TabDataModel` as
    /// `bookmarkNode(with:)` does could rewrite a tab and introduce it into the next pin snapshot.
    private func pinnedTabRow(with guid: String,
                              in context: ModelContext) throws -> TabDataModel? {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        return try context.fetch(descriptor).first
    }
}
