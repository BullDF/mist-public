// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData
import Combine

enum BookmarkPinConversionError: Error {
    case invalidSource
    case invalidDestination
}

extension LocalStore {
    /// Sync uses the same bookmark transaction bodies as local edits. Awaiting
    /// the FIFO commit keeps the sync cursor behind durable state and publishes
    /// normal store notifications for sidebars and the Chromium bookmark mirror.
    func applyMistSyncBookmark(_ value: MistBrowserSyncBookmark, profileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            let node: TabDataModel
            if let existing = try self.bookmarkNode(with: value.localID, in: context) {
                guard existing.dataType == (value.folder ? .bookmarkFolder : .bookmark),
                      try !self.isBookmarkRoot(existing, in: context) else { throw MistSyncError.invalidRecord }
                node = existing
                let actualParent = try self.resolveParent(for: value.parent, profileId: profileId,
                    spaceId: value.space, in: context)
                if node.spaceId != value.space || node.parent?.guid != actualParent?.guid || node.profileId != profileId {
                    try self.moveBookmarksBody([node.guid], sourceProfileId: node.profileId ?? profileId,
                        toSpaceId: value.space, targetProfileId: profileId, targetParentId: value.parent,
                        destinationIndex: value.index, in: context)
                }
                try self.updateBookmarkBody(node.guid, profileId: profileId, title: value.title,
                    url: value.folder ? nil : value.url, secondaryUrl: .some(value.secondaryURL),
                    secondaryTitle: .some(value.secondaryTitle), in: context)
            } else if value.folder {
                node = try self.createDirectoryBody(title: value.title, profileId: profileId, parentId: value.parent,
                    index: value.index, guid: value.localID, spaceId: value.space, in: context)
            } else {
                node = try self.createBookmarkBody(url: self.userInputBookmarkURL(from: value.url), title: value.title,
                    profileId: profileId, parentId: value.parent, index: value.index, guid: value.localID,
                    spaceId: value.space, secondaryUrl: try value.secondaryURL.map { try self.userInputBookmarkURL(from: $0) },
                    secondaryTitle: value.secondaryTitle, layout: value.layout, favicon: nil, in: context)
                node.needUpdateMetaData = true
            }
            node.syncId = value.syncID
            node.title = value.title
            node.layout = value.layout
            node.index = value.index
        }
    }

    func deleteMistSyncBookmark(_ guid: String, profileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            guard try self.bookmarkNode(with: guid, in: context) != nil else { return }
            try self.deleteBookmarkBody(guid, profileId: profileId, in: context)
        }
    }

    func reorderMistSyncBookmarks(_ guids: [String]) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            let nodes = try guids.map { guid -> TabDataModel in
                guard let node = try self.bookmarkNode(with: guid, in: context),
                      try !self.isBookmarkRoot(node, in: context) else { throw MistSyncError.invalidRecord }
                return node
            }
            guard Set(nodes.compactMap { $0.parent?.guid }).count <= 1 else { throw MistSyncError.invalidRecord }
            self.normalizeIndexes(for: nodes)
        }
    }

    /// Converts closed or cross-Space bookmarks without requiring a window runtime.
    /// Creation and removal share one transaction so a failed drop preserves its source.
    func convertBookmarksToPinnedTabs(_ guids: [String], sourceProfileId: String, sourceSpaceId: String,
                                      targetProfileId: String, targetSpaceId: String,
                                      destinationIndex: Int) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            guard !guids.isEmpty, Set(guids).count == guids.count else {
                throw BookmarkPinConversionError.invalidSource
            }
            let bookmarks = try guids.map { guid in
                guard let node = try self.bookmarkNode(with: guid, in: context),
                      node.dataType == .bookmark, node.profileId == sourceProfileId,
                      node.spaceId == sourceSpaceId else {
                    throw BookmarkPinConversionError.invalidSource
                }
                return node
            }
            var pins = try self.pinnedTabs(profileId: targetProfileId, spaceId: targetSpaceId,
                                           scope: self.pinnedTabScope(in: context), in: context)
            let now = Date()
            var created: [TabDataModel] = []
            for bookmark in bookmarks {
                let urls = [bookmark.url, bookmark.secondaryUrl].compactMap { $0 }
                var unit: [TabDataModel] = []
                for (pane, url) in urls.enumerated() {
                    let guid = UUID().uuidString
                    let pin = TabDataModel(title: pane == 0 ? bookmark.title : (bookmark.secondaryTitle ?? bookmark.title),
                        guid: guid, index: 0, url: url, favicon: pane == 0 ? bookmark.favicon : nil,
                        createdDate: now, updatedDate: now)
                    pin.dataType = .pinnedTab
                    pin.isCreatedByChromium = false
                    pin.pinLineageId = guid
                    try self.applyCurrentPinnedTabOwner(profileId: targetProfileId, spaceId: targetSpaceId,
                                                         to: pin, in: context)
                    context.insert(pin)
                    unit.append(pin)
                }
                if unit.count == 2 {
                    unit[0].splitPartnerGuid = unit[1].guid
                    unit[1].splitPartnerGuid = unit[0].guid
                    unit.forEach { $0.layout = bookmark.layout }
                }
                created.append(contentsOf: unit)
            }
            pins.insert(contentsOf: created, at: min(max(destinationIndex, 0), pins.count))
            self.normalizeIndexes(for: pins)
            let removed = Set(guids)
            for bookmark in bookmarks {
                if let parent = bookmark.parent {
                    self.normalizeIndexes(for: try self.children(of: parent, in: context).filter { !removed.contains($0.guid) })
                }
                context.delete(bookmark)
            }
        }
    }

    /// Saves a pin unit as one bookmark, preserving both panes and their order.
    func convertPinnedTabToBookmark(_ guid: String, sourceProfileId: String, sourceSpaceId: String,
                                    targetProfileId: String, targetSpaceId: String,
                                    parentGuid: String?, destinationIndex: Int) async throws -> Set<String> {
        try await performBackgroundWriteAndWaitThrowing { context in
            let pins = try self.pinnedTabs(profileId: sourceProfileId, spaceId: sourceSpaceId,
                                           scope: self.pinnedTabScope(in: context), in: context)
            guard let source = pins.first(where: { $0.guid == guid }) else {
                throw BookmarkPinConversionError.invalidSource
            }
            let unit = try Self.pinnedTransferUnit(containing: source, partnerGuidHint: nil, in: pins)
            guard let primary = unit.first else { throw BookmarkPinConversionError.invalidSource }
            if let parentGuid {
                guard let folder = try self.bookmarkNode(with: parentGuid, in: context),
                      folder.dataType == .bookmarkFolder, folder.profileId == targetProfileId,
                      folder.spaceId == targetSpaceId else { throw BookmarkPinConversionError.invalidDestination }
            }
            guard let parent = try self.resolveParent(for: parentGuid, profileId: targetProfileId,
                                                      spaceId: targetSpaceId, in: context) else {
                throw BookmarkPinConversionError.invalidDestination
            }
            let secondary = unit.count == 2 ? unit[1] : nil
            _ = try self.insertBookmarkNode(title: primary.title, profileId: targetProfileId, url: primary.url,
                parent: parent, index: destinationIndex, guid: nil, spaceId: targetSpaceId,
                secondaryUrl: secondary?.url, secondaryTitle: secondary?.title,
                layout: primary.layout ?? secondary?.layout, favicon: primary.favicon, now: Date(), in: context)
            let removed = Set(unit.map(\.guid))
            unit.forEach { context.delete($0) }
            self.normalizeIndexes(for: pins.filter { !removed.contains($0.guid) })
            return removed
        }
    }

    private static let folderPlaceholderURL: URL = {
        URL(string: "https://bookmark.phi/folder")!
    }()
    /// Creates a bookmark node, attaching it to the root when `parentId` is nil.
    /// `secondaryUrl` is set only for split-view bookmarks; clicking such a
    /// bookmark opens both URLs as a split. `secondaryTitle`
    /// is the secondary pane's display name and is shown alongside the
    /// primary title in the bookmark bar/sidebar. `layout` stores the raw
    /// divider orientation and defaults to side-by-side when absent.
    func createBookmark(url: String?,
                        title: String?,
                        profileId: String,
                        parentId: String?,
                        index: Int? = nil,
                        guid: String? = nil,
                        spaceId: String = LocalStore.defaultSpaceId,
                        secondaryUrl: String? = nil,
                        secondaryTitle: String? = nil,
                        layout: String? = nil,
                        favicon: Data? = nil) {
        let bookmarkURL: URL
        do {
            bookmarkURL = try userInputBookmarkURL(from: url)
        } catch {
            AppLogError("Invalid bookmark url: \(url ?? "nil")")
            return
        }
        // A nil `secondaryUrl` means a single-URL bookmark; a non-nil but
        // unparseable value is a user error and must surface, not silently
        // turn the bookmark into a single-URL one.
        let normalizedSecondary: URL?
        if let raw = secondaryUrl {
            do {
                normalizedSecondary = try userInputBookmarkURL(from: raw)
            } catch {
                AppLogError("Invalid bookmark secondary url: \(raw)")
                return
            }
        } else {
            normalizedSecondary = nil
        }

        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.createBookmarkBody(url: bookmarkURL,
                                                title: title,
                                                profileId: profileId,
                                                parentId: parentId,
                                                index: index,
                                                guid: guid,
                                                spaceId: spaceId,
                                                secondaryUrl: normalizedSecondary,
                                                secondaryTitle: secondaryTitle,
                                                layout: layout,
                                                favicon: favicon,
                                                in: context)
            } catch {
                AppLogError("Failed to create bookmark: \(error)")
            }
        }
    }

    private func createBookmarkBody(url: URL,
                                    title: String?,
                                    profileId: String,
                                    parentId: String?,
                                    index: Int?,
                                    guid: String?,
                                    spaceId: String,
                                    secondaryUrl: URL?,
                                    secondaryTitle: String?,
                                    layout: String? = nil,
                                    favicon: Data?,
                                    in context: ModelContext) throws -> TabDataModel {
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let now = Date()
        let node = try insertBookmarkNode(title: title,
                                          profileId: profileId,
                                          url: url,
                                          parent: parent,
                                          index: index,
                                          guid: guid,
                                          spaceId: spaceId,
                                          secondaryUrl: secondaryUrl,
                                          secondaryTitle: secondaryTitle,
                                          layout: layout,
                                          favicon: favicon,
                                          now: now,
                                          in: context)
        return node
    }

    /// Creates a bookmark folder node.
    func createDirectory(title: String,
                         profileId: String,
                         parentId: String?,
                         index: Int? = nil,
                         guid: String? = nil,
                         spaceId: String = LocalStore.defaultSpaceId) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.createDirectoryBody(title: title,
                                                 profileId: profileId,
                                                 parentId: parentId,
                                                 index: index,
                                                 guid: guid,
                                                 spaceId: spaceId,
                                                 in: context)
            } catch {
                AppLogError("Failed to create directory: \(error)")
            }
        }
    }

    private func createDirectoryBody(title: String,
                                     profileId: String,
                                     parentId: String?,
                                     index: Int?,
                                     guid: String?,
                                     spaceId: String,
                                     in context: ModelContext) throws -> TabDataModel {
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let now = Date()
        let folder = try insertDirectoryNode(title: title,
                                             profileId: profileId,
                                             parent: parent,
                                             index: index,
                                             guid: guid,
                                             spaceId: spaceId,
                                             now: now,
                                             in: context)
        return folder
    }

    func createDirectoryWithBookmarks(folderTitle: String,
                                      folderGuid: String,
                                      profileId: String,
                                      parentId: String?,
                                      index: Int?,
                                      spaceId: String = LocalStore.defaultSpaceId,
                                      bookmarks: [(title: String?,
                                                   url: String,
                                                   guid: String,
                                                   secondaryUrl: String?,
                                                   secondaryTitle: String?,
                                                   layout: String?,
                                                   favicon: Data?)]) {
        let normalizedBookmarks: [(title: String?,
                                   url: URL,
                                   guid: String,
                                   secondaryUrl: URL?,
                                   secondaryTitle: String?,
                                   layout: String?,
                                   favicon: Data?)] = bookmarks.compactMap { bookmark -> (title: String?,
                                                                                            url: URL,
                                                                                            guid: String,
                                                                                            secondaryUrl: URL?,
                                                                                            secondaryTitle: String?,
                                                                                            layout: String?,
                                                                                            favicon: Data?)? in
            guard let primaryURL = normalizedURL(from: bookmark.url) else {
                AppLogError("Invalid bookmark url: \(bookmark.url)")
                return nil
            }
            let normalizedSecondaryURL: URL?
            if let secondaryUrl = bookmark.secondaryUrl {
                guard let normalized = normalizedURL(from: secondaryUrl) else {
                    AppLogError("Invalid bookmark secondary url: \(secondaryUrl)")
                    return nil
                }
                normalizedSecondaryURL = normalized
            } else {
                normalizedSecondaryURL = nil
            }
            return (title: bookmark.title,
                    url: primaryURL,
                    guid: bookmark.guid,
                    secondaryUrl: normalizedSecondaryURL,
                    secondaryTitle: bookmark.secondaryTitle,
                    layout: bookmark.layout,
                    favicon: bookmark.favicon)
        }
        guard normalizedBookmarks.count == bookmarks.count else { return }

        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let parent = try self.resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogError("Parent folder not found when creating directory with bookmarks")
                    return
                }
                let now = Date()
                let folder = try self.insertDirectoryNode(title: folderTitle,
                                                          profileId: profileId,
                                                          parent: parent,
                                                          index: index,
                                                          guid: folderGuid,
                                                          spaceId: parent.spaceId,
                                                          now: now,
                                                          in: context)
                for (childIndex, bookmark) in normalizedBookmarks.enumerated() {
                    _ = try self.insertBookmarkNode(title: bookmark.title,
                                                    profileId: profileId,
                                                    url: bookmark.url,
                                                    parent: folder,
                                                    index: childIndex,
                                                    guid: bookmark.guid,
                                                    spaceId: folder.spaceId,
                                                    secondaryUrl: bookmark.secondaryUrl,
                                                    secondaryTitle: bookmark.secondaryTitle,
                                                    layout: bookmark.layout,
                                                    favicon: bookmark.favicon,
                                                    now: now,
                                                    in: context)
                }
            } catch {
                AppLogError("Failed to create directory with bookmarks: \(error)")
            }
        }
    }
    
    /// Ensures the hidden root folder exists for bookmarks without an explicit
    /// parent, in the given Space.
    func createDefaultRootDir(profileId: String,
                              spaceId: String = LocalStore.defaultSpaceId) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                _ = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true)
            } catch {
                AppLogError("Failed to create default root: \(error)")
            }
        }
    }

    /// Chromium's permanent bookmark bar node is the model root's first child.
    private static let chromiumBookmarkBarRootIndex = 0

    func saveChromiumBookmarksToLocalStore(_ bookmarks: [BookmarkWrapper], profileId: String, spaceId: String = LocalStore.defaultSpaceId) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                // An empty tree is an ordinary outcome (nothing staged, or the
                // window went away before the tree could be read), not the
                // missing-bookmark-bar failure the guard below reports.
                guard !bookmarks.isEmpty else {
                    AppLogWarn("No Chromium bookmarks to import: the bridge returned an empty tree")
                    return
                }
                guard try self.importTargetSpaceIsWritable(profileId: profileId, spaceId: spaceId, in: context) else {
                    AppLogWarn("Skipping Chromium bookmark import: space \(spaceId) no longer exists for profile \(profileId)")
                    return
                }
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true),
                      let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: true) else {
                    AppLogError("Skipping Chromium bookmark import: no profile or bookmark root "
                        + "for profile \(profileId) space \(spaceId)")
                    return
                }
                // Chromium titles its permanent bookmark bar node in the UI
                // language (`IDS_BOOKMARK_BAR_FOLDER_NAME`), so it cannot be found
                // by an English title. Match the model position instead. Array
                // position would not do — the bridge drops permanent nodes that
                // are hidden while empty (the mobile node on desktop), so what it
                // hands back is a filtered view, while `indexInParent` still
                // carries each node's real index under the root.
                guard let bookmarksBar = bookmarks.first(where: {
                          $0.indexInParent == Self.chromiumBookmarkBarRootIndex
                      }),
                      bookmarksBar.isFolder else {
                    AppLogError("Bookmark bar node not found in Chromium bookmarks "
                        + "(\(bookmarks.count) root node(s)); nothing imported")
                    return
                }
                var insertedCount = 0
                
                func insertChromiumBookmark(
                    _ wrapper: BookmarkWrapper,
                    parent: TabDataModel,
                    index: Int
                ) throws {
                    let title = (wrapper.title?.isEmpty == false)
                        ? wrapper.title!
                        : (wrapper.urlString ?? "Untitled")
                    let url = wrapper.isFolder
                        ? Self.folderPlaceholderURL
                        : self.normalizedURL(from: wrapper.urlString)
                    
                    guard let url else {
                        AppLogError("Skipping bookmark with invalid URL: \(wrapper.urlString ?? "nil")")
                        return
                    }
                    
                    let now = Date()
                    let node = TabDataModel(
                        title: title,
                        guid: UUID().uuidString,
                        index: 0,
                        url: url,
                        favicon: nil,
                        createdDate: now,
                        updatedDate: now
                    )
                    node.dataType = wrapper.isFolder ? .bookmarkFolder : .bookmark
                    node.isCreatedByChromium = false
                    node.spaceId = parent.spaceId
                    node.profileId = profileId
                    node.source = Self.importedBrowserSourceValue(
                        forTitle: title,
                        inheritedSource: parent.source,
                        isTopLevelImportFolder: parent.guid == root.guid
                    )
                    context.insert(node)
                    node.profile = profile
                    try self.insert(node: node, to: parent, at: index, in: context)
                    insertedCount += 1
                    
                    let orderedChildren = wrapper.children.sorted { $0.indexInParent < $1.indexInParent }
                    for (childIndex, child) in orderedChildren.enumerated() {
                        try insertChromiumBookmark(child, parent: node, index: childIndex)
                    }
                }
                
                let orderedRootChildren = bookmarksBar.children.sorted { $0.indexInParent < $1.indexInParent }
                for (index, bookmark) in orderedRootChildren.enumerated() {
                    try insertChromiumBookmark(bookmark, parent: root, index: index)
                }
                AppLogInfo("Imported \(insertedCount) Chromium bookmark node(s) "
                    + "into profile \(profileId) space \(spaceId)")
            } catch {
                AppLogError("Failed to save Chromium bookmarks: \(error)")
            }
        }
    }

    func reorderImportedBrowserFolders(profileId: String, spaceId: String = LocalStore.defaultSpaceId) async {
        await performBackgroundWriteAndWait { [weak self] context in
            guard let self else { return }
            do {
                guard let root = try self.bookmarkRoot(profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: false) else { return }
                let rootChildren = try self.children(of: root, in: context)

                let rankedImportFolders = rootChildren.enumerated().compactMap { offset, child -> (Int, Int, TabDataModel)? in
                    guard let rank = Self.importedBrowserFolderRank(for: child.title),
                          child.dataType == .bookmarkFolder else {
                        return nil
                    }
                    return (rank, offset, child)
                }

                guard !rankedImportFolders.isEmpty else { return }

                let importFolderGuids = Set(rankedImportFolders.map { $0.2.guid })
                let orderedImportFolders = rankedImportFolders
                    .sorted { lhs, rhs in
                        if lhs.0 != rhs.0 {
                            return lhs.0 < rhs.0
                        }
                        return lhs.1 < rhs.1
                    }
                    .map(\.2)

                let otherFolders = rootChildren.filter {
                    $0.dataType == .bookmarkFolder && !importFolderGuids.contains($0.guid)
                }
                let nonFolders = rootChildren.filter { $0.dataType != .bookmarkFolder }

                self.normalizeIndexes(for: otherFolders + orderedImportFolders + nonFolders)
            } catch {
                AppLogError("Failed to reorder imported browser folders: \(error)")
            }
        }
    }
    
    /// Moves a bookmark or folder to a new parent and sibling index.
    func moveBookmark(_ guid: String, profileId: String, to parentId: String?, newIndex: Int) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.moveBookmarkBody(guid,
                                          profileId: profileId,
                                          toParentGuid: parentId,
                                          index: newIndex,
                                          in: context)
            } catch {
                AppLogError("Failed to move bookmark: \(error)")
            }
        }
    }

    private func moveBookmarkBody(_ guid: String,
                                  profileId: String,
                                  toParentGuid parentId: String?,
                                  index newIndex: Int?,
                                  in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard try !isBookmarkRoot(node, in: context) else {
            throw LocalStoreWriteError.rowIsRoot
        }
        let targetSpaceId = node.spaceId ?? Self.defaultSpaceId
        guard let parent = try resolveParent(for: parentId,
                                             profileId: profileId,
                                             spaceId: targetSpaceId,
                                             in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }

        let originalParent = node.parent
        node.parent = parent

        if let originalParent, originalParent.guid != parent.guid {
            let originalSiblings = try children(of: originalParent, in: context)
            normalizeIndexes(for: originalSiblings)
        }

        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: newIndex, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)

        let now = Date()
        if originalParent?.guid != parent.guid {
            node.locationUpdatedDate = now
        }
        node.updatedDate = now
    }

    /// Moves an explicit bookmark selection as a visual batch.
    ///
    /// When a selected folder also contains selected descendants, only the
    /// selected descendant roots stay inside that folder. Unselected children
    /// are lifted next to their selected parent, and selected descendant
    /// folders shed their own unselected children recursively.
    func moveSelectedBookmarks(_ guids: [String],
                               profileId: String,
                               to parentId: String?,
                               newIndex: Int?,
                               expectedSpaceId: String? = nil) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                var uniqueGuids: [String] = []
                var seenGuids = Set<String>()
                for guid in guids where seenGuids.insert(guid).inserted {
                    uniqueGuids.append(guid)
                }
                guard !uniqueGuids.isEmpty else { return }

                var nodes: [TabDataModel] = []
                for guid in uniqueGuids {
                    guard let node = try self.bookmarkNode(with: guid, in: context),
                          expectedSpaceId == nil || (node.spaceId == expectedSpaceId && node.profileId == profileId),
                          try !self.isBookmarkRoot(node, in: context) else {
                        continue
                    }
                    nodes.append(node)
                }
                guard !nodes.isEmpty else { return }

                let resolveSpaceId = nodes.first?.spaceId ?? Self.defaultSpaceId
                guard let targetParent = try self.resolveParent(for: parentId,
                                                                profileId: profileId,
                                                                spaceId: resolveSpaceId,
                                                        in: context, createIfNeeded: true) else {
                    AppLogError("Target parent not found for selected bookmark move")
                    return
                }

                let selectedGuids = Set(nodes.map(\.guid))
                guard !selectedGuids.contains(targetParent.guid) else {
                    AppLogError("Attempted to move selected bookmarks into selected folder")
                    return
                }

                for node in nodes where node.dataType == .bookmarkFolder {
                    if targetParent.guid == node.guid ||
                        self.hasAncestor(of: targetParent, in: [node.guid]) {
                        AppLogError("Attempted to move selected bookmark folder into itself")
                        return
                    }
                }

                let rootNodes = nodes.filter { !self.hasAncestor(of: $0, in: selectedGuids) }
                guard !rootNodes.isEmpty else { return }

                let rootGuids = Set(rootNodes.map(\.guid))
                let originalTargetChildren = try self.children(of: targetParent, in: context)
                let adjustedIndex: Int? = {
                    guard var index = newIndex else { return nil }
                    let upperBound = min(index, originalTargetChildren.count)
                    let movingBeforeIndex = originalTargetChildren
                        .prefix(upperBound)
                        .filter { rootGuids.contains($0.guid) }
                        .count
                    index -= movingBeforeIndex
                    return index
                }()

                var sourceParentsByGuid: [String: TabDataModel] = [:]
                for node in rootNodes {
                    if let originalParent = node.parent {
                        sourceParentsByGuid[originalParent.guid] = originalParent
                    }
                    let movedOut = node.parent?.guid != targetParent.guid
                    node.parent = targetParent
                    node.updatedDate = Date()
                    if movedOut { node.locationUpdatedDate = node.updatedDate }
                }

                for parent in sourceParentsByGuid.values where parent.guid != targetParent.guid {
                    self.normalizeIndexes(for: try self.children(of: parent, in: context))
                }

                var targetSiblings = try self.children(of: targetParent, in: context)
                    .filter { !rootGuids.contains($0.guid) }
                let targetIndex = Self.clamp(index: adjustedIndex ?? Int.max,
                                             upperBound: targetSiblings.count)
                targetSiblings.insert(contentsOf: rootNodes, at: targetIndex)
                self.normalizeIndexes(for: targetSiblings)

                let now = Date()
                for node in rootNodes where node.dataType == .bookmarkFolder {
                    if try self.hasSelectedDescendant(of: node,
                                                      selectedGuids: selectedGuids,
                                                      in: context) {
                        try self.liftUnselectedChildren(from: node,
                                                        selectedGuids: selectedGuids,
                                                        updatedDate: now,
                                                        in: context)
                    }
                }
            } catch {
                AppLogError("Failed to move selected bookmarks: \(error)")
            }
        }
    }

    /// Moves an explicit bookmark selection to another Space's bookmark root.
    /// Selected folder descendants remain inside the folder while unselected
    /// children are lifted beside it, matching bookmark drag behavior.
    func moveBookmarks(_ guids: [String],
                       sourceProfileId: String,
                       toSpaceId targetSpaceId: String,
                       targetProfileId: String,
                       sourceSpaceId: String? = nil,
                       targetParentId: String? = nil,
                       destinationIndex: Int? = nil) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.moveBookmarksBody(guids,
                                           sourceProfileId: sourceProfileId,
                                           toSpaceId: targetSpaceId,
                                           targetProfileId: targetProfileId,
                                           sourceSpaceId: sourceSpaceId,
                                           targetParentId: targetParentId,
                                           destinationIndex: destinationIndex,
                                           in: context)
            } catch {
                AppLogError("Failed to move bookmarks to Space: \(error)")
            }
        }
    }

    private func moveBookmarksBody(_ guids: [String],
                                   sourceProfileId: String,
                                   toSpaceId targetSpaceId: String,
                                   targetProfileId: String,
                                   sourceSpaceId: String? = nil,
                                   targetParentId: String? = nil,
                                   destinationIndex: Int? = nil,
                                   in context: ModelContext) throws {
        // An empty list is a caller bug, not a successful no-op.
        guard !guids.isEmpty else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let targetSpaceIsWritable: Bool
        if targetSpaceId == Self.defaultSpaceId {
            targetSpaceIsWritable = true
        } else {
            targetSpaceIsWritable = try importTargetSpaceIsWritable(profileId: targetProfileId,
                                                                    spaceId: targetSpaceId,
                                                                    in: context)
        }
        guard targetSpaceIsWritable else {
            throw LocalStoreWriteError.targetNotWritable
        }
        guard let targetProfile = try profile(with: targetProfileId,
                                              in: context,
                                              createIfNeeded: true),
              let targetRoot = try bookmarkRoot(profileId: targetProfileId,
                                                      spaceId: targetSpaceId,
                                                      in: context, createIfNeeded: true) else {
            throw LocalStoreWriteError.rowNotFound
        }

        let destination: TabDataModel
        if let targetParentId {
            guard let folder = try bookmarkNode(with: targetParentId, in: context),
                  folder.dataType == .bookmarkFolder,
                  folder.profileId == targetProfileId,
                  folder.spaceId == targetSpaceId else {
                throw LocalStoreWriteError.rowNotFound
            }
            destination = folder
        } else {
            destination = targetRoot
        }

        let requestedGuids = Set(guids)
        guard !requestedGuids.contains(destination.guid),
              !hasAncestor(of: destination, in: requestedGuids) else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let originalSiblings = try children(of: destination, in: context)
        var sourceParentsByGuid: [String: TabDataModel] = [:]
        var movedNodes: [TabDataModel] = []
        var movedGuids = Set<String>()
        let now = Date()

        for guid in guids {
            guard let node = try bookmarkNode(with: guid, in: context),
                  node.profileId == sourceProfileId,
                  sourceSpaceId == nil || node.spaceId == sourceSpaceId,
                  try !isBookmarkRoot(node, in: context),
                  !hasAncestor(of: node, in: requestedGuids) else {
                continue
            }
            if node.spaceId == targetSpaceId && node.profileId == targetProfileId
                && targetParentId == nil && destinationIndex == nil {
                continue
            }

            if let parent = node.parent {
                sourceParentsByGuid[parent.guid] = parent
            }
            node.parent = destination
            node.locationUpdatedDate = now
            try retagBookmarkSubtree(node,
                                     profileId: targetProfileId,
                                     profile: targetProfile,
                                     spaceId: targetSpaceId,
                                     updatedDate: now,
                                     in: context)
            movedNodes.append(node)
            movedGuids.insert(node.guid)
        }

        guard !movedNodes.isEmpty else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        for parent in sourceParentsByGuid.values where parent.guid != destination.guid {
            let siblings = try children(of: parent, in: context)
            normalizeIndexes(for: siblings)
        }

        var targetSiblings = try children(of: destination, in: context)
            .filter { !movedGuids.contains($0.guid) }
        if let destinationIndex {
            let bounded = min(max(destinationIndex, 0), originalSiblings.count)
            let removedBefore = originalSiblings.prefix(bounded).filter { movedGuids.contains($0.guid) }.count
            let insertion = min(max(bounded - removedBefore, 0), targetSiblings.count)
            targetSiblings.insert(contentsOf: movedNodes, at: insertion)
        } else {
            targetSiblings.append(contentsOf: movedNodes)
        }
        normalizeIndexes(for: targetSiblings)

        for node in movedNodes where node.dataType == .bookmarkFolder {
            if try hasSelectedDescendant(of: node,
                                         selectedGuids: requestedGuids,
                                         in: context) {
                try liftUnselectedChildren(from: node,
                                           selectedGuids: requestedGuids,
                                           updatedDate: now,
                                           in: context)
            }
        }
        destination.updatedDate = now
    }

    /// Clones an explicit bookmark selection into another Space's bookmark
    /// root. A folder with explicitly selected descendants copies only those
    /// descendants; a folder selected by itself still copies its whole tree.
    func cloneBookmarks(_ guids: [String],
                        sourceProfileId: String,
                        toSpaceId targetSpaceId: String,
                        targetProfileId: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard !guids.isEmpty else { return }
                let targetSpaceIsWritable: Bool
                if targetSpaceId == Self.defaultSpaceId {
                    targetSpaceIsWritable = true
                } else {
                    targetSpaceIsWritable = try self.importTargetSpaceIsWritable(
                        profileId: targetProfileId,
                        spaceId: targetSpaceId,
                        in: context)
                }
                guard targetSpaceIsWritable else {
                    AppLogError("Target Space not found when cloning bookmarks")
                    return
                }
                guard try self.profile(with: targetProfileId,
                                       in: context,
                                       createIfNeeded: true) != nil,
                      let targetRoot = try self.bookmarkRoot(profileId: targetProfileId,
                                                             spaceId: targetSpaceId,
                                                             in: context,
                                                             createIfNeeded: true) else {
                    AppLogError("Target bookmark root not found when cloning bookmarks")
                    return
                }

                let requestedGuids = Set(guids)
                var sourceRoots: [TabDataModel] = []
                for guid in guids {
                    guard let node = try self.bookmarkNode(with: guid, in: context),
                          node.profileId == sourceProfileId,
                          try !self.isBookmarkRoot(node, in: context),
                          !self.hasAncestor(of: node, in: requestedGuids) else {
                        continue
                    }
                    sourceRoots.append(node)
                }
                guard !sourceRoots.isEmpty else { return }

                let insertionIndex = try self.children(of: targetRoot, in: context).count
                let now = Date()
                for (offset, sourceRoot) in sourceRoots.enumerated() {
                    _ = try self.cloneSelectedBookmarkSubtree(sourceRoot,
                                                              selectedGuids: requestedGuids,
                                                              to: targetRoot,
                                                              at: insertionIndex + offset,
                                                              profileId: targetProfileId,
                                                              spaceId: targetSpaceId,
                                                              createdDate: now,
                                                              in: context)
                }
                targetRoot.updatedDate = now
            } catch {
                AppLogError("Failed to clone bookmarks to Space: \(error)")
            }
        }
    }
    
    /// Updates bookmark title and URL, normalizing the URL when provided.
    /// `secondaryUrl` / `secondaryTitle` are split-bookmark specific: pass
    /// `.some(value)` to set or replace, `.some("")` (for secondaryUrl) to
    /// clear it and turn the bookmark back into a single-URL bookmark, or
    /// `.none` to leave it untouched. Clearing `secondaryUrl` also clears
    /// `secondaryTitle` even if no explicit update was passed for the title.
    func updateBookmark(_ guid: String,
                        profileId: String,
                        title: String?,
                        url: String?,
                        secondaryUrl: String?? = nil,
                        secondaryTitle: String?? = nil,
                        iconName: String? = nil,
                        expectedSpaceId: String? = nil) {
        let titleUpdate = (title?.isEmpty == false) ? title : nil
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.updateBookmarkBody(guid,
                                            profileId: profileId,
                                            title: titleUpdate,
                                            url: url,
                                            secondaryUrl: secondaryUrl,
                                            secondaryTitle: secondaryTitle,
                                            iconName: iconName,
                                            expectedSpaceId: expectedSpaceId,
                                            in: context)
            } catch {
                AppLogError("Failed to update bookmark: \(error)")
            }
        }
    }

    /// Updates the persisted orientation of a split-view bookmark. Ordinary
    /// bookmarks are ignored so layout metadata cannot outlive the second URL.
    func updateBookmarkSplitLayout(_ guid: String, layout: String) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                guard let node = try self.bookmarkNode(with: guid, in: context),
                      node.secondaryUrl != nil,
                      node.layout != layout else {
                    return
                }
                node.layout = layout
                node.updatedDate = Date()
            } catch {
                AppLogError("Failed to update bookmark split layout: \(error)")
            }
        }
    }
    
    ///
    /// Validate all URLs before writing any fields, avoiding a partial title update when a simultaneous URL
    /// edit is invalid.
    private func updateBookmarkBody(_ guid: String,
                                    profileId: String,
                                    title: String?,
                                    url: String?,
                                    secondaryUrl: String??,
                                    secondaryTitle: String??,
                                    iconName: String? = nil,
                                    expectedSpaceId: String? = nil,
                                    in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context),
              expectedSpaceId == nil || (node.spaceId == expectedSpaceId && node.profileId == profileId) else {
            throw LocalStoreWriteError.rowNotFound
        }

        var resolvedURL: URL?
        if let urlString = url {
            guard let newURL = normalizedURL(from: urlString) else {
                throw LocalStoreWriteError.invalidURL
            }
            resolvedURL = newURL
        }
        // Outer optional selects whether to change; inner optional selects the value, with nil meaning clear.
        var resolvedSecondaryURL: URL??
        if let secondaryUrlOpt = secondaryUrl {
            if let raw = secondaryUrlOpt, !raw.isEmpty {
                // Mirror the primary-URL behavior: a non-empty secondary URL
                // that fails to parse aborts the whole update so the user sees
                // the error and the bookmark does not silently keep its old
                // state mixed with partially-applied changes.
                guard let normalized = normalizedURL(from: raw) else {
                    throw LocalStoreWriteError.invalidURL
                }
                resolvedSecondaryURL = .some(normalized)
            } else {
                resolvedSecondaryURL = .some(nil)
            }
        }

        var contentDidChange = false
        if let resolvedURL, node.url != resolvedURL {
            node.url = resolvedURL
            contentDidChange = true
        }
        if let title {
            let effectiveTitle = title.isEmpty ? node.url.absoluteString : title
            if node.title != effectiveTitle {
                node.title = effectiveTitle
                contentDidChange = true
            }
        }
        var secondaryUrlClearedInThisUpdate = false
        if let resolvedSecondaryURL {
            if node.secondaryUrl != resolvedSecondaryURL {
                node.secondaryUrl = resolvedSecondaryURL
                contentDidChange = true
            }
            secondaryUrlClearedInThisUpdate = resolvedSecondaryURL == nil
        }
        if secondaryUrlClearedInThisUpdate {
            node.layout = nil
            if node.secondaryTitle != nil {
                node.secondaryTitle = nil
                contentDidChange = true
            }
        } else if let secondaryTitleOpt = secondaryTitle {
            let newSecondaryTitle = (secondaryTitleOpt?.isEmpty == false) ? secondaryTitleOpt : nil
            if node.secondaryTitle != newSecondaryTitle {
                node.secondaryTitle = newSecondaryTitle
                contentDidChange = true
            }
        }
        if let iconName, node.dataType == .bookmarkFolder, node.icon != iconName {
            node.icon = iconName
            contentDidChange = true
        }

        let now = Date()
        // Stamp only actual content changes; saving an identical title must not outrank a peer's edit.
        if contentDidChange {
            node.contentUpdatedDate = now
        }
        node.updatedDate = now
    }

    /// Deletes a bookmark or folder and compacts sibling indexes.
    func deleteBookmark(_ guid: String, profileId: String, expectedSpaceId: String? = nil) {
        performBackgroundWrite { [weak self] context in
            guard let self else { return }
            do {
                try self.deleteBookmarkBody(guid, profileId: profileId,
                                            expectedSpaceId: expectedSpaceId, in: context)
            } catch {
                AppLogError("Failed to delete bookmark: \(error)")
            }
        }
    }

    private func deleteBookmarkBody(_ guid: String,
                                    profileId: String,
                                    expectedSpaceId: String? = nil,
                                    in context: ModelContext) throws {
        guard let node = try bookmarkNode(with: guid, in: context),
              expectedSpaceId == nil || (node.spaceId == expectedSpaceId && node.profileId == profileId) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard try !isBookmarkRoot(node, in: context) else {
            throw LocalStoreWriteError.rowIsRoot
        }

        let parent = node.parent
        context.delete(node)

        if let parent {
            let siblings = try children(of: parent, in: context)
            normalizeIndexes(for: siblings)
        }
    }
    
    @MainActor
    /// Returns all bookmarks directly under the specified parent.
    func fetchBookmarks(parentId: String?,
                        profileId: String,
                        spaceId: String = LocalStore.defaultSpaceId) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            guard let parent = try resolveParent(for: parentId, profileId: profileId, spaceId: spaceId, in: context, createIfNeeded: false) else {
                return []
            }
            let siblings = try children(of: parent, in: context)
            return siblings
        } catch {
            AppLogError("Failed to fetch bookmarks: \(error)")
            return []
        }
    }

    @MainActor
    /// Returns only bookmark rows for the requested Spaces, ordered by most
    /// recently opened first. The scripting API consumes a flat list, so this
    /// intentionally avoids reconstructing the bookmark folder tree.
    func fetchBookmarkTabs(in spaces: [Space]) -> [TabDataModel] {
        guard !spaces.isEmpty, let context = mainContext else { return [] }

        let profileIdBySpaceId = Dictionary(
            uniqueKeysWithValues: spaces.map { ($0.spaceId, $0.profileId) }
        )
        let bookmarkRaw = TabDataType.bookmark.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == bookmarkRaw },
            sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor).filter { bookmark in
                guard let spaceId = bookmark.spaceId,
                      let expectedProfileId = profileIdBySpaceId[spaceId] else {
                    return false
                }
                return bookmark.profileId == expectedProfileId
                    || bookmark.profile?.profileId == expectedProfileId
            }
        } catch {
            AppLogError("Failed to fetch bookmark tabs: \(error)")
            return []
        }
    }
    
    @MainActor
    /// Returns a single bookmark node for editing or navigation.
    func fetchBookmark(with guid: String) -> TabDataModel? {
        guard let context = mainContext else { return nil }
        do {
            return try bookmarkNode(with: guid, in: context)
        } catch {
            AppLogError("Failed to fetch bookmark \(guid): \(error)")
            return nil
        }
    }
    
    @MainActor
    /// Publishes bookmark changes from the underlying store, scoped to a Space.
    /// Pre-Spaces rows are backfilled to `LocalStore.defaultSpaceId` by the
    /// V5→V6 migration, so this filter is total — no nil-equivalence rule.
    func bookmarksPublisher(profileId: String,
                            spaceId: String = LocalStore.defaultSpaceId) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[TabDataModel], Never>([])
        let fetchBookmarks: () -> [TabDataModel]? = { [weak self] in
            guard let context = self?.mainContext else { return nil }
            do {
                let bookmarkRaw = TabDataType.bookmark.rawValue
                let folderRaw = TabDataType.bookmarkFolder.rawValue
                let predicate = #Predicate<TabDataModel> { $0.type == bookmarkRaw || $0.type == folderRaw }
                let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.createdDate)]
                let descriptor = FetchDescriptor<TabDataModel>(
                    predicate: predicate,
                    sortBy: sortBy
                )
                let bookmarks: [TabDataModel] = try context.fetch(descriptor)
                return bookmarks.filter {
                    $0.profile?.profileId == profileId && $0.spaceId == spaceId
                }
            } catch {
                AppLogError("Failed to fetch bookmarks for publisher: \(error)")
                return []
            }
        }
        
        if let bookmarks = fetchBookmarks() {
            subject.send(bookmarks)
        }
        
        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter { Self.notificationContainsChanges($0, matching: {
                guard $0.entity.name == TabDataModel.entityName, let type = Self.tabType(from: $0) else { return false }
                return type == TabDataType.bookmark.rawValue || type == TabDataType.bookmarkFolder.rawValue
            }) }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard let bookmarks = fetchBookmarks() else { return }
                subject.send(bookmarks)
            }
        
        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}

// MARK: - Bookmark Root (visible to sibling LocalStore extensions)
extension LocalStore {
    /// Whether imported bookmarks may be written into `(profileId, spaceId)`.
    /// The default Space is always allowed (its root is the legacy profile root
    /// and needs no `SpaceModel`). A non-default Space must still have a live
    /// `SpaceModel`: if it was deleted or re-profiled mid-import, writing would
    /// create an orphan root the UI never shows, so the import is dropped.
    func importTargetSpaceIsWritable(profileId: String, spaceId: String, in context: ModelContext) throws -> Bool {
        if spaceId == Self.defaultSpaceId { return true }
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId && $0.profileId == profileId }
        )
        return try context.fetchCount(descriptor) > 0
    }

    /// Resolves the hidden root folder for `(profileId, spaceId)`.
    ///
    /// For the default Space, the root is shared with `ProfileModel.bookmarkRoot`
    /// so pre-Spaces data stays reachable without migration data movement —
    /// when a default-space root is materialized we link it on both
    /// `space.bookmarkRoot` and `profile.bookmarkRoot`. For non-default Spaces
    /// a fresh `TabDataModel` folder is created and linked only on the
    /// Space; the Profile-level link is left alone so the default space's
    /// behavior is unchanged.
    func bookmarkRoot(profileId: String,
                      spaceId: String,
                      in context: ModelContext,
                      createIfNeeded: Bool) throws -> TabDataModel? {
        guard let profile = try profile(with: profileId, in: context, createIfNeeded: createIfNeeded) else {
            return nil
        }
        let spaceDescriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId && $0.profileId == profileId }
        )
        let space = try context.fetch(spaceDescriptor).first

        // Prefer the explicit per-Space root if already linked.
        if let existing = space?.bookmarkRoot {
            return existing
        }
        // Legacy compat: for the default Space, treat the Profile's existing
        // bookmarkRoot as the Space's root and back-link if the Space row
        // is around to receive the pointer.
        if spaceId == Self.defaultSpaceId, let profileRoot = profile.bookmarkRoot {
            space?.bookmarkRoot = profileRoot
            return profileRoot
        }
        // Heal-on-read: an earlier call may have created a root but failed
        // to set the back-link (e.g. because `space` was nil at the time,
        // or because two BookmarkManagers initialised concurrently for
        // the same (profileId, spaceId) — now possible since a Space can
        // host a window in multiple slots simultaneously). Without this
        // recovery, every call here creates ANOTHER orphan root, and the
        // bookmarks publisher returns all of them — visible to the user
        // as duplicate "Bookmarks" folders in non-default Spaces.
        // Reclaim the first matching un-parented bookmarkFolder for this
        // (profileId, spaceId) instead of stamping out a new one. We
        // fetch by the simplest predicate the macro supports (just
        // `type == folder`) and post-filter in Swift to keep the
        // expression checkable — same pattern the publisher uses.
        let folderRaw = TabDataType.bookmarkFolder.rawValue
        let folderDescriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == folderRaw },
            sortBy: [SortDescriptor(\.createdDate)]
        )
        let candidateFolders = try context.fetch(folderDescriptor)
        let orphanRoots = candidateFolders.filter {
            $0.parent == nil &&
            $0.spaceId == spaceId &&
            $0.profileId == profileId &&
            $0.isCreatedByChromium == false
        }
        if let primary = orphanRoots.first {
            // Re-link to the SpaceModel so subsequent calls hit the fast
            // `space?.bookmarkRoot` branch above and stop fetching here.
            space?.bookmarkRoot = primary
            // If earlier races stamped out more than one orphan root,
            // collapse them: reparent every duplicate root's children
            // under the primary, then delete the duplicate. We keep the
            // oldest (createdDate ascending) so any references that
            // already point at the primary stay valid.
            if orphanRoots.count > 1 {
                for duplicate in orphanRoots.dropFirst() {
                    let dupGuid = duplicate.guid
                    let childDescriptor = FetchDescriptor<TabDataModel>(
                        predicate: #Predicate<TabDataModel> { $0.parent?.guid == dupGuid }
                    )
                    // Reparent before deleting. Use `try` (not `try?`): if the
                    // fetch fails we must NOT delete the duplicate, or its
                    // children would be orphaned (SwiftData nullifies their
                    // `parent`) and the bookmarks silently lost. The enclosing
                    // function throws, so the error propagates and the write is
                    // abandoned with the duplicate intact.
                    for child in try context.fetch(childDescriptor) {
                        child.parent = primary
                    }
                    context.delete(duplicate)
                }
            }
            return primary
        }
        guard createIfNeeded else { return nil }
        let now = Date()
        let root = TabDataModel(title: NSLocalizedString("localData.bookmarks.rootFolderTitle", value: "Bookmarks", comment: "Default root bookmarks folder title"),
                                guid: UUID().uuidString,
                                index: 0,
                                url: Self.folderPlaceholderURL,
                                favicon: nil as Data?,
                                createdDate: now,
                                updatedDate: now)
        root.dataType = TabDataType.bookmarkFolder
        root.profileId = profileId
        root.spaceId = spaceId
        root.isCreatedByChromium = false
        context.insert(root)
        root.profile = profile
        space?.bookmarkRoot = root
        // Mirror onto the Profile only when this is the first time the
        // default Space materializes; non-default spaces must not pollute
        // the profile-wide pointer or imports/legacy lookups will jump
        // spaces unexpectedly.
        if spaceId == Self.defaultSpaceId, profile.bookmarkRoot == nil {
            profile.bookmarkRoot = root
        }
        return root
    }

}

// MARK: - Helpers
private extension LocalStore {
    /// Inserts a node into the parent children sequence and reindexes siblings.
    func insert(node: TabDataModel,
                to parent: TabDataModel,
                at index: Int?,
                in context: ModelContext) throws {
        node.parent = parent
        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: index, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)
    }
    
    func children(of parent: TabDataModel, in context: ModelContext) throws -> [TabDataModel] {
        let parentGuid = parent.guid
        let predicate = #Predicate<TabDataModel> {
            $0.parent?.guid == parentGuid
        }

        // Use `guid` as the secondary key, matching `pinnedTabs(...)`. An excluded sibling (parked, pending
        // deletion or unidentified) may retain an index that collides with a newly assigned one. Without a
        // stable tie-break, fetch order can flip every round and cause endless rank commits; with it,
        // collisions are deterministic even if imperfect.
        let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index), SortDescriptor(\.guid)]
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate, sortBy: sortBy)
        return try context.fetch(descriptor)
    }
    
    /// Normalizes sibling indexes into a contiguous `0...n-1` range.
    func normalizeIndexes(for nodes: [TabDataModel]) {
        for (position, node) in nodes.enumerated() where node.index != position {
            node.index = position
            node.updatedDate = Date()
        }
    }
    
    func bookmarkNode(with guid: String, in context: ModelContext) throws -> TabDataModel? {
        let predicate = #Predicate<TabDataModel> { $0.guid == guid }
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    func hasAncestor(of node: TabDataModel, in guids: Set<String>) -> Bool {
        var parent = node.parent
        while let current = parent {
            if guids.contains(current.guid) {
                return true
            }
            parent = current.parent
        }
        return false
    }

    func hasSelectedDescendant(of folder: TabDataModel,
                               selectedGuids: Set<String>,
                               in context: ModelContext) throws -> Bool {
        for child in try children(of: folder, in: context) {
            if selectedGuids.contains(child.guid) {
                return true
            }
            if child.dataType == .bookmarkFolder,
               try hasSelectedDescendant(of: child,
                                         selectedGuids: selectedGuids,
                                         in: context) {
                return true
            }
        }
        return false
    }

    func selectedDescendantRoots(under node: TabDataModel,
                                 selectedGuids: Set<String>,
                                 in context: ModelContext) throws -> [TabDataModel] {
        guard node.dataType == .bookmarkFolder else { return [] }
        var roots: [TabDataModel] = []
        for child in try children(of: node, in: context) {
            if selectedGuids.contains(child.guid) {
                roots.append(child)
            } else {
                roots.append(contentsOf: try selectedDescendantRoots(under: child,
                                                                     selectedGuids: selectedGuids,
                                                                     in: context))
            }
        }
        return roots
    }

    func moveBookmarkNode(_ node: TabDataModel,
                          to parent: TabDataModel,
                          at index: Int,
                          updatedDate: Date,
                          in context: ModelContext) throws {
        let originalParent = node.parent
        node.parent = parent
        node.updatedDate = updatedDate
        if originalParent?.guid != parent.guid {
            node.locationUpdatedDate = updatedDate
        }

        if let originalParent, originalParent.guid != parent.guid {
            let originalSiblings = try children(of: originalParent, in: context)
            normalizeIndexes(for: originalSiblings)
        }

        var siblings = try children(of: parent, in: context).filter { $0.guid != node.guid }
        let targetIndex = Self.clamp(index: index, upperBound: siblings.count)
        siblings.insert(node, at: targetIndex)
        normalizeIndexes(for: siblings)
    }

    func liftUnselectedChildren(from folder: TabDataModel,
                                selectedGuids: Set<String>,
                                updatedDate: Date,
                                in context: ModelContext) throws {
        guard let parent = folder.parent else { return }

        let originalChildren = try children(of: folder, in: context)
        var siblingOffsetAfterFolder = 1

        for child in originalChildren {
            if selectedGuids.contains(child.guid) {
                if child.dataType == .bookmarkFolder,
                   try hasSelectedDescendant(of: child,
                                             selectedGuids: selectedGuids,
                                             in: context) {
                    try liftUnselectedChildren(from: child,
                                               selectedGuids: selectedGuids,
                                               updatedDate: updatedDate,
                                               in: context)
                }
                continue
            }

            let selectedDescendantRoots = try selectedDescendantRoots(under: child,
                                                                      selectedGuids: selectedGuids,
                                                                      in: context)
            if !selectedDescendantRoots.isEmpty {
                let currentFolderChildren = try children(of: folder, in: context)
                let childIndex = currentFolderChildren.firstIndex { $0.guid == child.guid }
                    ?? currentFolderChildren.count
                var descendantInsertionIndex = childIndex
                for descendant in selectedDescendantRoots {
                    try moveBookmarkNode(descendant,
                                         to: folder,
                                         at: descendantInsertionIndex,
                                         updatedDate: updatedDate,
                                         in: context)
                    descendantInsertionIndex += 1
                    if descendant.dataType == .bookmarkFolder,
                       try hasSelectedDescendant(of: descendant,
                                                 selectedGuids: selectedGuids,
                                                 in: context) {
                        try liftUnselectedChildren(from: descendant,
                                                   selectedGuids: selectedGuids,
                                                   updatedDate: updatedDate,
                                                   in: context)
                    }
                }
            }

            let parentChildren = try children(of: parent, in: context)
            guard let folderIndex = parentChildren.firstIndex(where: { $0.guid == folder.guid }) else {
                continue
            }
            try moveBookmarkNode(child,
                                 to: parent,
                                 at: folderIndex + siblingOffsetAfterFolder,
                                 updatedDate: updatedDate,
                                                                  in: context)
            siblingOffsetAfterFolder += 1
        }

        normalizeIndexes(for: try children(of: folder, in: context))
    }

    func retagBookmarkSubtree(_ node: TabDataModel,
                              profileId: String,
                              profile: ProfileModel,
                              spaceId: String,
                              updatedDate: Date,
                              in context: ModelContext) throws {
        node.profileId = profileId
        node.profile = profile
        node.spaceId = spaceId
        node.updatedDate = updatedDate
        for child in try children(of: node, in: context) {
            try retagBookmarkSubtree(child,
                                     profileId: profileId,
                                     profile: profile,
                                     spaceId: spaceId,
                                     updatedDate: updatedDate,
                                     in: context)
        }
    }

    func cloneBookmarkSubtree(_ source: TabDataModel,
                              to parent: TabDataModel,
                              at index: Int,
                              profileId: String,
                              spaceId: String,
                              createdDate: Date,
                              in context: ModelContext) throws -> TabDataModel {
        let clone: TabDataModel
        if source.dataType == .bookmarkFolder {
            clone = try insertDirectoryNode(title: source.title,
                                            profileId: profileId,
                                            parent: parent,
                                            index: index,
                                            guid: nil,
                                            spaceId: spaceId,
                                            now: createdDate,
                                            in: context)
            for (childIndex, child) in try children(of: source, in: context).enumerated() {
                _ = try cloneBookmarkSubtree(child,
                                             to: clone,
                                             at: childIndex,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             createdDate: createdDate,
                                             in: context)
            }
        } else {
            clone = try insertBookmarkNode(title: source.title,
                                           profileId: profileId,
                                           url: source.url,
                                           parent: parent,
                                           index: index,
                                           guid: nil,
                                           spaceId: spaceId,
                                           secondaryUrl: source.secondaryUrl,
                                           secondaryTitle: source.secondaryTitle,
                                           layout: source.layout,
                                           favicon: source.favicon,
                                           now: createdDate,
                                           in: context)
            clone.lastSeen = source.lastSeen
        }
        clone.overrideTitle = source.overrideTitle
        clone.source = source.source
        clone.icon = source.icon
        return clone
    }

    func cloneSelectedBookmarkSubtree(_ source: TabDataModel,
                                      selectedGuids: Set<String>,
                                      to parent: TabDataModel,
                                      at index: Int,
                                      profileId: String,
                                      spaceId: String,
                                      createdDate: Date,
                                      in context: ModelContext) throws -> TabDataModel {
        guard source.dataType == .bookmarkFolder,
              try hasSelectedDescendant(of: source,
                                        selectedGuids: selectedGuids,
                                        in: context) else {
            return try cloneBookmarkSubtree(source,
                                            to: parent,
                                            at: index,
                                            profileId: profileId,
                                            spaceId: spaceId,
                                            createdDate: createdDate,
                                            in: context)
        }

        let clone = try insertDirectoryNode(title: source.title,
                                            profileId: profileId,
                                            parent: parent,
                                            index: index,
                                            guid: nil,
                                            spaceId: spaceId,
                                            now: createdDate,
                                            in: context)
        let selectedChildren = try selectedDescendantRoots(under: source,
                                                           selectedGuids: selectedGuids,
                                                           in: context)
        for (childIndex, child) in selectedChildren.enumerated() {
            _ = try cloneSelectedBookmarkSubtree(child,
                                                 selectedGuids: selectedGuids,
                                                 to: clone,
                                                 at: childIndex,
                                                 profileId: profileId,
                                                 spaceId: spaceId,
                                                 createdDate: createdDate,
                                                 in: context)
        }
        clone.overrideTitle = source.overrideTitle
        clone.source = source.source
        clone.icon = source.icon
        return clone
    }

    func insertDirectoryNode(title: String,
                             profileId: String,
                             parent: TabDataModel,
                             index: Int?,
                             guid: String?,
                             spaceId: String?,
                             now: Date,
                             in context: ModelContext) throws -> TabDataModel {
        let folder = TabDataModel(title: title,
                                  guid: guid ?? UUID().uuidString,
                                  index: 0,
                                  url: Self.folderPlaceholderURL,
                                  favicon: nil as Data?,
                                  createdDate: now,
                                  updatedDate: now)
        folder.dataType = TabDataType.bookmarkFolder
        folder.spaceId = spaceId ?? parent.spaceId
        folder.profileId = profileId
        folder.isCreatedByChromium = false
        // Insert before assigning `profile`. Its inverse `ProfileModel.tabs` otherwise creates an
        // uninitialized placeholder for a model outside the context; its missing required fields cause every
        // later save to fail validation (NSCocoaErrorDomain 1560). This applies to every new `TabDataModel`,
        // not only pins.
        context.insert(folder)
        folder.profile = parent.profile
        try insert(node: folder, to: parent, at: index, in: context)
        return folder
    }

    func insertBookmarkNode(title: String?,
                            profileId: String,
                            url: URL,
                            parent: TabDataModel,
                            index: Int?,
                            guid: String?,
                            spaceId: String?,
                            secondaryUrl: URL? = nil,
                            secondaryTitle: String? = nil,
                            layout: String? = nil,
                            favicon: Data? = nil,
                            now: Date,
                            in context: ModelContext) throws -> TabDataModel {
        let resolvedTitle: String
        if let title, !title.isEmpty {
            resolvedTitle = title
        } else {
            resolvedTitle = url.absoluteString
        }
        let bookmark = TabDataModel(title: resolvedTitle,
                                    guid: guid ?? UUID().uuidString,
                                    index: 0,
                                    url: url,
                                    favicon: favicon,
                                    createdDate: now,
                                    updatedDate: now)
        bookmark.dataType = TabDataType.bookmark
        bookmark.spaceId = spaceId ?? parent.spaceId
        bookmark.profileId = profileId
        bookmark.isCreatedByChromium = false
        bookmark.secondaryUrl = secondaryUrl
        bookmark.secondaryTitle = (secondaryTitle?.isEmpty == false) ? secondaryTitle : nil
        bookmark.layout = secondaryUrl == nil ? nil : layout
        context.insert(bookmark)
        bookmark.profile = parent.profile
        try insert(node: bookmark, to: parent, at: index, in: context)
        return bookmark
    }
    
    func resolveParent(for parentId: String?,
                       profileId: String,
                       spaceId: String = LocalStore.defaultSpaceId,
                       in context: ModelContext,
                       createIfNeeded: Bool = true) throws -> TabDataModel? {
        if let parentId {
            if let node = try bookmarkNode(with: parentId, in: context),
               node.dataType == .bookmarkFolder {
                return node
            }
        }
        return try bookmarkRoot(profileId: profileId,
                                spaceId: spaceId,
                                in: context,
                                createIfNeeded: createIfNeeded)
    }

    func userInputBookmarkURL(from raw: String?) throws -> URL {
        guard let normalized = normalizedURL(from: raw),
              let processed = URL(string: URLProcessor.processUserInput(normalized.absoluteString)) else {
            throw LocalStoreWriteError.invalidURL
        }
        return processed
    }

    /// Returns true if `node` is the hidden top-level folder for any Profile
    /// or Space — i.e. moving/deleting it is illegal because the bookmark tree
    /// would lose its root.
    func isBookmarkRoot(_ node: TabDataModel, in context: ModelContext) throws -> Bool {
        let profileDescriptor: FetchDescriptor<ProfileModel> = FetchDescriptor<ProfileModel>()
        if try context.fetch(profileDescriptor).contains(where: { $0.bookmarkRoot?.guid == node.guid }) {
            return true
        }
        let spaceDescriptor: FetchDescriptor<SpaceModel> = FetchDescriptor<SpaceModel>()
        return try context.fetch(spaceDescriptor).contains(where: { $0.bookmarkRoot?.guid == node.guid })
    }

    static func importedBrowserSourceValue(
        forTitle title: String,
        inheritedSource: Int,
        isTopLevelImportFolder: Bool
    ) -> Int {
        guard isTopLevelImportFolder else {
            return inheritedSource == 0 ? 1 : inheritedSource
        }

        switch importedBrowserFolderRank(for: title) {
        case 0:  // Chrome
            return 1
        case 3:  // Safari
            return 2
        default:
            return inheritedSource == 0 ? 1 : inheritedSource
        }
    }

    /// Where an imported-browser folder sorts among its kind at the Space root:
    /// Chrome 0, Safari 3 — the order of the import window's
    /// rows. Nil for any other folder.
    static func importedBrowserFolderRank(for title: String) -> Int? {
        let lowercasedTitle = title.lowercased()
        if lowercasedTitle.contains("chrome") {
            return 0
        }
        if lowercasedTitle.contains("safari") {
            return 3
        }
        return nil
    }
    
    static func clamp(index: Int?, upperBound: Int) -> Int {
        guard let index = index else { return upperBound }
        return max(0, min(index, upperBound))
    }
    
    static func clamp(index: Int, upperBound: Int) -> Int {
        max(0, min(index, upperBound))
    }
    
}

extension LocalStore {
    func normalizedURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(raw)")
    }
}
