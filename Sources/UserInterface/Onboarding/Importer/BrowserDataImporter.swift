// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import SwiftData

class BrowserDataImporter {
    enum Phase {
        case waiting
        case importingChromeData
        case importingSafariData
        case importingFile
        case done
    }

    struct ChromiumProfileInfo: Equatable {
        let directory: String
        let name: String
        let email: String?
    }

    private(set) var targetProfileId: String
    private(set) var targetSpaceId: String
    private(set) var targetWindowId: Int?

    /// True from the moment an import starts until its deferred bookmark
    /// persistence finishes. While true the target must not be rebound, or the
    /// pending snapshot would be saved into the newly-bound Space instead of
    /// the one the running import was started for.
    private(set) var isImporting = false

    // Continuations for active import requests, keyed by browser type.
    private var importContinuations: [
        BrowserType: CheckedContinuation<SourceImportResult, Never>
    ] = [:]
    private let continuationQueue = DispatchQueue(label: "com.phibrowser.import.continuation")

    private(set) var failedImports: [BrowserType] = []
    @Published private(set) var phase: Phase = .waiting
    @Published var status: String = ""

    /// Resolves the store imported bookmarks are written into.
    private let localDataStoreProvider: () -> LocalStore?
    /// Resolves the Chromium bridge every import request goes through, so a
    /// test can drive the importer without one.
    private let bridgeProvider: () -> PhiChromiumBridgeProtocol?

    init(targetProfileId: String = LocalStore.defaultProfileId,
         targetSpaceId: String = SpaceManager.shared.currentDefaultSpaceId,
         targetWindowId: Int? = nil,
         localDataStoreProvider: @escaping () -> LocalStore? = {
             AccountController.shared.localDataAccount.localStorage
         },
         bridgeProvider: @escaping () -> PhiChromiumBridgeProtocol? = {
             ChromiumLauncher.sharedInstance().bridge
         }
    ) {
        self.targetProfileId = targetProfileId
        self.targetSpaceId = targetSpaceId
        self.targetWindowId = targetWindowId
        self.localDataStoreProvider = localDataStoreProvider
        self.bridgeProvider = bridgeProvider
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportCompleted(_:)),
            name: .browserImportCompleted,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Retargets a future import to a different window/profile/Space when the
    /// single import window is re-invoked from another Space. Callers must skip
    /// this while `isImporting` is true so the in-flight import keeps its
    /// original destination.
    func updateTarget(profileId: String, spaceId: String, windowId: Int?) {
        targetProfileId = profileId
        targetSpaceId = spaceId
        targetWindowId = windowId
    }

    /// Starts importing data from the selected browsers. Returns `false` only
    /// when the call was ignored because an import is already in flight, so the
    /// caller can skip its completion handler instead of advancing/closing the
    /// UI out from under the running import.
    @MainActor
    @discardableResult
    func startImportData(
        _ options: [BrowserType],
        chromeProfileDirectory: String? = nil,
        dataTypesPerBrowser: [BrowserType: [String]]? = nil,
        importFilePath: String? = nil
    ) async -> Bool {
        // Reentrancy gate: a second start (rapid double-click, repeated action
        // dispatch, programmatic re-call) while an import is unresolved would
        // overwrite the BrowserType-keyed continuation and race the shared
        // Chromium bookmark staging. @MainActor plus setting the flag with no
        // preceding await makes this check atomic against a queued second call.
        // Returning false lets the caller skip its completion for this ignored start.
        guard !isImporting else {
            AppLogInfo("Import already in progress; ignoring re-entrant start")
            return false
        }
        isImporting = true
        let lockedProfileId = targetProfileId
        let lockedSpaceId = targetSpaceId
        ImportTargetLock.shared.begin(into: lockedSpaceId)
        failedImports.removeAll()
        let sourceOptions = options

        // Prefer the caller-provided window so Chromium import state follows the initiating window/profile.
        guard let windowId = targetWindowId ?? SpaceSessionControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogError("No available window for import")
            failedImports = sourceOptions
            updateCompletionStatus()
            isImporting = false
            ImportTargetLock.shared.end(into: lockedSpaceId)
            return true
        }

        AppLogInfo("Import started: browsers=\(options.map { Self.browserName(for: $0) }), "
            + "profileId=\(targetProfileId), spaceId=\(targetSpaceId)")

        // Validate the file source before any destructive work: if its path is
        // missing/unreadable (the file was moved or deleted after picking, or a nil
        // path reached us from a programmatic caller), drop `.file` so we neither
        // clear the Chromium bookmark staging below nor start an import that can't
        // succeed. Surface it as a failed import so the skip isn't silent.
        var options = options
        if options.contains(.file) {
            let readable = importFilePath.map {
                !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0)
            } ?? false
            if !readable {
                AppLogWarn("File import skipped: no readable file at \(importFilePath ?? "nil")")
                options.removeAll { $0 == .file }
                failedImports.append(.file)
            }
        }

        // Only clear bookmarks if at least one browser is importing bookmarks
        let bookmarkSources = options.filter { option in
            guard let types = dataTypesPerBrowser?[option] else { return true } // nil = import all
            return types.contains(ImportDataType.bookmarks.rawValue)
        }
        if !bookmarkSources.isEmpty {
            bridgeProvider()?.removeAllBookmarks(withWindowId: windowId.int64Value)
        }

        for option in options {
            updatePhase(option)

            let result = await importData(option, windowId: windowId,
                sourceProfileDirectory: option == .chrome ? chromeProfileDirectory : nil,
                dataTypes: dataTypesPerBrowser?[option], importFilePath: importFilePath)
            switch result {
            case .completed(let success):
                if !success {
                    failedImports.append(option)
                }
                AppLogInfo("Import from \(option) completed with success: \(success)")
            case .bridgeUnavailable:
                failedImports.append(option)
            }
        }

        updateCompletionStatus()

        if !bookmarkSources.isEmpty {
            Task {
                let persistence = await self.persistImportedBookmarksAfterSnapshot(
                    windowId: windowId
                )
                await MainActor.run {
                    if !persistence.snapshotSucceeded {
                        self.failedImports.append(
                            contentsOf: bookmarkSources
                        )
                    }
                    if !persistence.storeSucceeded {
                        self.failedImports.append(contentsOf: bookmarkSources)
                    }
                    self.failedImports = Self.uniqueBrowserTypes(
                        self.failedImports
                    )
                    self.updateCompletionStatus()
                    // The tree is in and the completion is announced: hand
                    // the Bookmarks still without an icon in the Space it
                    // landed in — the locked target, whatever the importer
                    // is retargeted to once `isImporting` clears — to the
                    // favicon backfill and move on. Never awaited; the
                    // status and the lock below are as they
                    // were.
                    self.backfillFavicons(profileId: lockedProfileId, spaceId: lockedSpaceId)
                    self.isImporting = false
                }
                ImportTargetLock.shared.end(into: lockedSpaceId)
            }
        } else {
            isImporting = false
            ImportTargetLock.shared.end(into: lockedSpaceId)
        }

        return true
    }

    /// Imports data for one browser using a continuation-backed async flow.
    private enum SourceImportResult {
        case completed(Bool)
        case bridgeUnavailable
    }

    @MainActor
    private func importData(
        _ option: BrowserType,
        windowId: Int,
        sourceProfileDirectory: String?,
        dataTypes: [String]?,
        importFilePath: String? = nil
    ) async -> SourceImportResult {
        guard let bridge = bridgeProvider() else {
            AppLogError(
                "Import from \(Self.browserName(for: option)) was not "
                    + "dispatched: no Chromium bridge"
            )
            return .bridgeUnavailable
        }

        return await withCheckedContinuation { continuation in
            continuationQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: .completed(false))
                    return
                }

                self.importContinuations[option] = continuation

                DispatchQueue.main.async {
                    let profile = sourceProfileDirectory ?? ""
                    if option == .file {
                        // File import: Chromium sniffs the file type + parses it, staging
                        // the result into its BookmarkModel to be pulled back like the
                        // browser sources. Completion arrives via importCompleted(.file).
                        bridge.importData(
                            fromFilePath: importFilePath ?? "",
                            windowId: Int64(windowId)
                        )
                    } else {
                        bridge.importBrowserData(
                            from: option,
                            profile: profile,
                            dataTypes: dataTypes,
                            windowId: Int64(windowId)
                        )
                    }
                }
            }
        }
    }

    /// Handles the completion callback emitted by the Chromium bridge.
    @objc private func handleImportCompleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let browserTypeRaw = userInfo["browserType"] as? UInt,
              let browserType = BrowserType(rawValue: browserTypeRaw),
              let success = userInfo["success"] as? Bool else {
            AppLogError("Invalid import completion notification")
            return
        }

        continuationQueue.async { [weak self] in
            guard let self = self,
                  let continuation = self.importContinuations.removeValue(forKey: browserType) else {
                AppLogError("No continuation found for browser type: \(browserType)")
                return
            }

            continuation.resume(returning: .completed(success))
        }
    }

    /// Updates the current import phase and status text.
    private func updatePhase(_ option: BrowserType) {
        switch option {
        case .chrome:
            phase = .importingChromeData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingChrome", value: "Importing Chrome data...", comment: "Browser data importer - Status message while importing Chrome browser data")
        case .safari:
            phase = .importingSafariData
            status = NSLocalizedString("oobe.importBrowserData.progress.importingSafari", value: "Importing Safari data...", comment: "Browser data importer - Status message while importing Safari browser data")
        case .file:
            phase = .importingFile
            status = NSLocalizedString("oobe.importBrowserData.progress.importingFile", value: "Importing data from file...", comment: "Browser data importer - Status message while importing data from a file")
        default:
            phase = .waiting
            status = ""
        }
    }

    private func updateCompletionStatus() {
        phase = .done
        if failedImports.isEmpty {
            status = NSLocalizedString("oobe.importBrowserData.progress.completed", value: "Import completed successfully", comment: "Browser data importer - Status message when all imports completed successfully")
        } else {
            let failedBrowserNames = failedImports.map { Self.browserName(for: $0) }.joined(separator: ", ")
            let format = NSLocalizedString("oobe.importBrowserData.progress.completedWithErrors", value: "Import completed with errors. Failed to import from: %@", comment: "Browser data importer - Status message when some imports failed, shows list of failed browsers")
            status = String(format: format, failedBrowserNames)
        }
    }

    /// Returns the user-facing browser name.
    private static func browserName(for type: BrowserType) -> String {
        switch type {
        case .chrome:
            return "Chrome"
        case .safari:
            return "Safari"
        case .file:
            return "File"
        default:
            return "Unknown"
        }
    }

    private struct BookmarkPersistenceResult {
        let snapshotSucceeded: Bool
        let storeSucceeded: Bool

    }

    private func persistImportedBookmarksAfterSnapshot(
        windowId: Int
    ) async -> BookmarkPersistenceResult {
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        let bookmarkWrappers: [BookmarkWrapper]
        let snapshotSucceeded: Bool
        let snapshot = await MainActor.run {
            self.bridgeProvider()?.getAllBookmarks(
                withWindowId: windowId.int64Value
            )
        }
        if let snapshot {
            bookmarkWrappers = snapshot
            snapshotSucceeded = true
        } else {
            AppLogError("Imported bookmarks were dropped: no Chromium bridge is available")
            bookmarkWrappers = []
            snapshotSucceeded = false
        }
        let storeSucceeded = await persistImportedBookmarks(
            bookmarkWrappers
        )
        return BookmarkPersistenceResult(
            snapshotSucceeded: snapshotSucceeded,
            storeSucceeded: storeSucceeded
        )
    }

    /// Writes an imported tree into the local data store. Split out of the
    /// snapshot step so it can be driven without the Chromium bridge.
    @discardableResult
    func persistImportedBookmarks(
        _ bookmarks: [BookmarkWrapper]
    ) async -> Bool {
        guard let store = localDataStoreProvider() else {
            AppLogError("Imported bookmarks were dropped: no local data store is available")
            return false
        }

        await store.saveChromiumBookmarksToLocalStore(
            bookmarks, profileId: targetProfileId, spaceId: targetSpaceId)

        await store.reorderImportedBrowserFolders(
            profileId: targetProfileId, spaceId: targetSpaceId)
        return true
    }

    /// Hands the Space's Bookmarks that hold no icon to the favicon backfill,
    /// in sidebar order: the rows the import just wrote, and any the Space
    /// already had without one. Leaving out the rows with an icon here is a
    /// pre-filter — an import lands in a Space the user already has, and
    /// the backfill reads every queued row back one by one — not a
    /// decision: which rows are asked, and what is written, the backfill
    /// still settles at each row's turn.
    @MainActor
    private func backfillFavicons(profileId: String, spaceId: String) {
        guard let store = localDataStoreProvider() else { return }
        let guids = FaviconBackfill.bookmarkGUIDs(
            under: store.fetchBookmarks(parentId: nil, profileId: profileId, spaceId: spaceId),
            where: { $0.favicon == nil })
        FaviconBackfill.shared.enqueue(profileId: profileId, guids: guids)
    }

    private static func uniqueBrowserTypes(
        _ browserTypes: [BrowserType]
    ) -> [BrowserType] {
        var seen = Set<String>()
        return browserTypes.filter {
            let source = switch $0 {
            case .chrome: "chrome"
            case .safari: "safari"
            case .file: "file"
            default: "unknown"
            }
            return seen.insert(source).inserted
        }
    }

    func loadChromiumProfiles(
        localStateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    ) -> [ChromiumProfileInfo] {
        guard let data = try? Data(contentsOf: localStateURL) else {
            AppLogError("Unable to read Local State at \(localStateURL.path)")
            return []
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = root["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any],
            let profilesOrder = profile["profiles_order"] as? [String]
        else {
            AppLogError("Invalid Local State profile structure")
            return []
        }

        var results: [ChromiumProfileInfo] = []
        results.reserveCapacity(profilesOrder.count)
        for directory in profilesOrder {
            guard let info = infoCache[directory] as? [String: Any] else {
                continue
            }
            // An empty display name falls back to the directory basename.
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            let email = info["user_name"] as? String
            results.append(ChromiumProfileInfo(directory: directory, name: name, email: email))
        }

        return results
    }

}

// MARK: - Notification Name
extension Notification.Name {
    static let browserImportCompleted = Notification.Name("browserImportCompleted")
}

/// Tracks which Spaces currently have an import writing into them so a Space
/// can't be deleted out from under an in-flight import — which would otherwise
/// strand the imported bookmarks under an orphan root (the persist path also
/// revalidates the Space as a backstop). The importer brackets this around its
/// `isImporting` window. Lock-guarded rather than actor-isolated so the
/// non-isolated `SpaceManager.deleteSpace` can consult it synchronously.
final class ImportTargetLock {
    static let shared = ImportTargetLock()
    private let lock = NSLock()
    private var importingSpaceIds: Set<String> = []
    private init() {}

    func begin(into spaceId: String) {
        lock.lock(); defer { lock.unlock() }
        importingSpaceIds.insert(spaceId)
    }

    func end(into spaceId: String) {
        lock.lock(); defer { lock.unlock() }
        importingSpaceIds.remove(spaceId)
    }

    func isImporting(into spaceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return importingSpaceIds.contains(spaceId)
    }

}
