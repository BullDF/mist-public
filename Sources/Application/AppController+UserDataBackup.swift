// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

extension AppController {
    private enum PhiUserDataBackupPromptResult {
        case cancel
        case skipBackup
        case performBackup
    }

    private struct PhiUserDataImportStaging {
        let stagingURL: URL
        let extractedPhiURL: URL
        let referencedProfileIds: Set<String>
        let profileDisplayNames: [String: String]

        func cleanup() {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    private struct PhiUserDataProfileRepairResult {
        let profileIdRemaps: [String: String]
        let createdProfileIds: [String]
    }

    @MainActor
    @objc func clearAllUserData(_ sender: Any?) {
        beginClearUserDataFlow()
    }

    @MainActor
    @objc func exportUserData(_ sender: Any?) {
        _ = performPhiUserDataBackupExport()
    }

    @MainActor
    @objc func importUserDataFromBackup(_ sender: Any?) {
        let confirm = NSAlert()
        confirm.messageText = NSLocalizedString("app.userDataImport.confirmation.title", value: "Import Phi User Data?", comment: "User data import - Confirmation alert title before replacing Phi user data from zip")
        confirm.informativeText = NSLocalizedString("app.userDataImport.confirmation.message", value: "This replaces the Phi user data folder with the archive and restarts Phi. Save your work first.", comment: "User data import - Confirmation alert body warning data replacement and relaunch")
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: NSLocalizedString("app.userDataImport.confirmation.importButton", value: "Import...", comment: "User data import - Alert button to open file picker for zip backup"))
        confirm.addButton(withTitle: NSLocalizedString("app.userDataImport.confirmation.cancelButton", value: "Cancel", comment: "User data import - Alert button to cancel importing user data"))
        guard confirm.runModal() == .alertFirstButtonReturn else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip]
        panel.title = NSLocalizedString("app.userDataImport.filePicker.title", value: "Select Phi User Data Backup", comment: "User data import - NSOpenPanel title for choosing a Phi user data zip")

        guard panel.runModal() == .OK, let zipURL = panel.url else {
            return
        }

        do {
            let staging = try Self.preparePhiUserDataImport(from: zipURL)
            AppLogInfo("[Debug] Phi user data import prepared: archive=\(zipURL.path) referencedProfiles=\(Self.formatProfileIds(staging.referencedProfileIds))")
            // Defer Chromium-side extension preinstall for the profiles we
            // create here: this flow relaunches before an async install can
            // finish, so let the next launch run it. Read through the bridge by
            // both the default-apps (preinstalled) path and the iCloud
            // Passwords auto-install (PhiICloudPasswordsExternalLoader). Defer
            // clears it on every exit.
            PhiChromiumCoordinator.shared.isBackupImportInProgress = true
            Self.createMissingChromiumProfiles(
                for: staging.referencedProfileIds,
                displayNames: staging.profileDisplayNames
            ) { [weak self] result in
                guard let self else {
                    staging.cleanup()
                    return
                }
                switch result {
                case .success(let repairResult):
                    do {
                        AppLogInfo("[Debug] Phi user data import applying profile remaps: \(Self.formatProfileIdRemaps(repairResult.profileIdRemaps))")
                        try Self.applyImportedProfileIdRemaps(repairResult.profileIdRemaps, in: staging.extractedPhiURL)
                        AppLogInfo("[Debug] Phi user data import replacing Phi data directory")
                        try Self.replacePhiUserDataDirectory(withExtractedPhiAt: staging.extractedPhiURL)
                        staging.cleanup()
                        AppLogInfo("[Debug] Phi user data imported from \(zipURL.path), relaunching")
                        Self.relaunchPhiApplication()
                    } catch {
                        Self.rollbackCreatedChromiumProfiles(repairResult.createdProfileIds) {
                            staging.cleanup()
                            self.presentPhiUserDataImportFailure(error)
                        }
                    }
                case .failure(let error):
                    staging.cleanup()
                    presentPhiUserDataImportFailure(error)
                }
            }
        } catch {
            presentPhiUserDataImportFailure(error)
        }
    }

    @MainActor
    private func beginClearUserDataFlow() {
        guard showQuitAlert() else {
            return
        }

        switch promptBackupBeforeClearingPhiUserData() {
        case .cancel:
            return
        case .skipBackup:
            break
        case .performBackup:
            guard performPhiUserDataBackupExport() else {
                return
            }
        }

        // Last step before terminating: any defaults write after the
        // preferences domain is dropped would resurrect it in cfprefsd.
        UserDataRemoval.beginRemoval(of: .currentProduct)
        NSApp.terminate(nil)
    }

    @MainActor
    private func promptBackupBeforeClearingPhiUserData() -> PhiUserDataBackupPromptResult {
        let alert = NSAlert()
        alert.messageText = "Back Up User Data First?"
        alert.informativeText = "You can save a zip of your browser data before local files are removed and the app quits."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Backup...")
        alert.addButton(withTitle: "Skip Backup")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .performBackup
        case .alertSecondButtonReturn:
            return .skipBackup
        default:
            return .cancel
        }
    }

    @MainActor
    private func performPhiUserDataBackupExport() -> Bool {
        let fm = FileManager.default
        let browserDataAvailable = Self.isDirectory(
            at: URL(
                fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(),
                isDirectory: true
            )
        )

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultPhiUserDataBackupFileName()
        panel.title = NSLocalizedString("app.userDataExport.savePanel.title", value: "Back Up Phi User Data", comment: "User data export - NSSavePanel title for saving Phi user data directory as zip")
        panel.prompt = NSLocalizedString("app.userDataExport.savePanel.saveButton", value: "Save", comment: "User data export - NSSavePanel confirm button title when saving Phi user data backup zip")

        guard panel.runModal() == .OK, let destinationZIP = panel.url else {
            return false
        }

        let stagingDirectory = fm.temporaryDirectory.appendingPathComponent(
            "PhiDataExport-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedZIP = stagingDirectory.appendingPathComponent(
            "Phi-data.zip",
            isDirectory: false
        )

        do {
            try fm.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer {
                try? fm.removeItem(at: stagingDirectory)
            }

            guard browserDataAvailable else {
                throw NSError(
                    domain: "PhiUserDataBackup",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString(
                            "app.userDataExport.browserDataUnavailable.message",
                            value: "The Phi browser data folder is no longer available.",
                            comment: "User data export - Error when browser data disappears before the backup starts"
                        )
                    ]
                )
            }
            syncCurrentChromiumProfileDisplayNamesToLocalStore()
            try zipPhiBrowserDataDirectory(to: stagedZIP)

            try Self.publishBackup(from: stagedZIP, to: destinationZIP)
            AppLogInfo("[Debug] Phi user data backup saved to \(destinationZIP.path)")
            return true
        } catch {
            AppLogWarn("[Debug] Phi user data backup failed: \(error.localizedDescription)")
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("app.userDataExport.failure.title", value: "Backup Failed", comment: "User data export - Alert title when the requested backup cannot be created")
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("app.userDataExport.failure.dismissButton", value: "OK", comment: "User data export - Failure alert dismiss button"))
            errorAlert.runModal()
            return false
        }
    }

    private func defaultPhiUserDataBackupFileName() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return "Mist-data-\(formatter.string(from: Date())).zip"
    }

    @MainActor
    private func syncCurrentChromiumProfileDisplayNamesToLocalStore() {
        ProfileManager.shared.refresh()
        var displayNames: [String: String] = [:]
        for profile in ProfileManager.shared.profiles {
            displayNames[profile.profileId] = profile.displayName
        }
        AccountController.shared.localDataAccount.localStorage
            .upsertProfileDisplayNames(displayNames)
    }

    private func zipPhiBrowserDataDirectory(to destinationZIP: URL) throws {
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        let phiFolderName = (FileSystemUtils.phiBrowserDataDirectory() as NSString).lastPathComponent

        if fm.fileExists(atPath: destinationZIP.path) {
            try fm.removeItem(at: destinationZIP)
        }

        try Self.runZip(
            arguments: ["-r", "-q", destinationZIP.path, phiFolderName],
            currentDirectoryURL: parentURL
        )
    }

    private static func runZip(
        arguments: [String],
        currentDirectoryURL: URL
    ) throws {
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty
                ? "zip exited with status \(process.terminationStatus)."
                : errText
            throw NSError(
                domain: "PhiUserDataBackup",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    private static func publishBackup(
        from stagedZIP: URL,
        to destinationZIP: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedZIP.path) else {
            throw NSError(
                domain: "PhiUserDataBackup",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "app.userDataExport.archive.missingOutputMessage",
                        value: "No backup archive was produced.",
                        comment: "User data export - Error when the requested backup produces no archive"
                    )
                ]
            )
        }

        let temporaryDestination = destinationZIP
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationZIP.lastPathComponent).\(UUID().uuidString).tmp"
            )
        defer {
            try? fm.removeItem(at: temporaryDestination)
        }

        try fm.copyItem(at: stagedZIP, to: temporaryDestination)
        if fm.fileExists(atPath: destinationZIP.path) {
            _ = try fm.replaceItemAt(
                destinationZIP,
                withItemAt: temporaryDestination
            )
        } else {
            try fm.moveItem(at: temporaryDestination, to: destinationZIP)
        }
    }

    @MainActor
    private func presentPhiUserDataImportFailure(_ error: Error) {
        AppLogWarn("[Debug] Phi user data import failed: \(error.localizedDescription)")
        let errorAlert = NSAlert()
        errorAlert.messageText = NSLocalizedString("app.userDataImport.failure.title", value: "Import Failed", comment: "User data import - Alert title when extracting or applying backup fails")
        errorAlert.informativeText = error.localizedDescription
        errorAlert.alertStyle = .warning
        errorAlert.addButton(withTitle: NSLocalizedString("app.userDataImport.failure.dismissButton", value: "OK", comment: "User data import - Failure alert dismiss button"))
        errorAlert.runModal()
    }

    private static func preparePhiUserDataImport(from zipURL: URL) throws -> PhiUserDataImportStaging {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PhiDataImport-\(UUID().uuidString)", isDirectory: true)
        var shouldCleanupStaging = true
        defer {
            if shouldCleanupStaging {
                try? fm.removeItem(at: staging)
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        try runUnzip(archive: zipURL, destination: staging)
        AppLogInfo("[Debug] Phi user data import archive extracted to \(staging.path)")

        let extractedPhi = staging.appendingPathComponent("Phi", isDirectory: true)
        guard isDirectory(at: extractedPhi) else {
            throw NSError(
                domain: "PhiUserDataImport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("app.userDataImport.invalidArchive.missingTopLevelFolder", value: "The archive does not contain a top-level Phi folder.", comment: "User data import - Error message when zip does not include the expected Phi directory at archive root")]
            )
        }

        do {
            let referencedProfileIds = try importedProfileIds(in: extractedPhi)
            let profileDisplayNames = try importedProfileDisplayNames(in: extractedPhi)
            AppLogInfo("[Debug] Phi user data import found referenced profiles: \(formatProfileIds(referencedProfileIds))")
            shouldCleanupStaging = false
            return PhiUserDataImportStaging(
                stagingURL: staging,
                extractedPhiURL: extractedPhi,
                referencedProfileIds: referencedProfileIds,
                profileDisplayNames: profileDisplayNames
            )
        }
    }

    private static func replacePhiUserDataDirectory(withExtractedPhiAt extractedPhi: URL) throws {
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
        let phiURL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)

        guard isDirectory(at: extractedPhi) else {
            throw NSError(
                domain: "PhiUserDataImport",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("app.userDataImport.invalidArchive.restoredItemNotDirectory", value: "The restored Phi user data is not a directory.", comment: "User data import - Error message when extracted Phi item is not a directory")]
            )
        }

        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let preparedPhiURL = parentURL.appendingPathComponent(".PhiImportPrepared-\(UUID().uuidString)", isDirectory: true)
        let previousPhiURL = parentURL.appendingPathComponent(".PhiImportPrevious-\(UUID().uuidString)", isDirectory: true)
        var movedExistingPhi = false

        do {
            try fm.copyItem(at: extractedPhi, to: preparedPhiURL)
            if fm.fileExists(atPath: phiURL.path) {
                try fm.moveItem(at: phiURL, to: previousPhiURL)
                movedExistingPhi = true
            }
            try fm.moveItem(at: preparedPhiURL, to: phiURL)
            if movedExistingPhi {
                do {
                    try fm.removeItem(at: previousPhiURL)
                } catch {
                    AppLogWarn("[Debug] Phi user data import left previous Phi data directory at \(previousPhiURL.path): \(error.localizedDescription)")
                }
            }
        } catch {
            try? fm.removeItem(at: preparedPhiURL)
            if movedExistingPhi, !fm.fileExists(atPath: phiURL.path), fm.fileExists(atPath: previousPhiURL.path) {
                do {
                    try fm.moveItem(at: previousPhiURL, to: phiURL)
                    AppLogInfo("[Debug] Phi user data import restored previous Phi data directory after replace failure")
                } catch {
                    AppLogWarn("[Debug] Phi user data import failed to restore previous Phi data directory: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func importedProfileIds(in phiDataURL: URL) throws -> Set<String> {
        var profileIds = Set<String>()
        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            profileIds.formUnion(try profileIdsReferencedBySpaces(inStoreDirectory: storeDirectoryURL))
        }
        return profileIds
    }

    private static func importedProfileDisplayNames(in phiDataURL: URL) throws -> [String: String] {
        var displayNames: [String: String] = [:]
        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            // A Chromium profileId should represent the same global profile
            // across imported user stores. If snapshots disagree, keep the
            // first value; the mismatch belongs to profile snapshot drift,
            // not restore-time arbitration.
            displayNames.merge(
                try profileDisplayNames(inStoreDirectory: storeDirectoryURL),
                uniquingKeysWith: { existing, _ in existing }
            )
        }
        return displayNames
    }

    private static func importedLocalStoreDirectoryURLs(in phiDataURL: URL) throws -> [URL] {
        let fm = FileManager.default
        let usersURL = phiDataURL.appendingPathComponent("users", isDirectory: true)
        guard fm.fileExists(atPath: usersURL.path) else {
            return []
        }

        return try fm.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { userURL in
            let values = try? userURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                return nil
            }
            let storeDirectoryURL = userURL.appendingPathComponent("localDB", isDirectory: true)
            let storeURL = storeDirectoryURL.appendingPathComponent(LocalStore.compatibilityConfiguration.storeFilename)
            guard fm.fileExists(atPath: storeURL.path) else {
                return nil
            }
            return storeDirectoryURL
        }
    }

    private static func profileIdsReferencedBySpaces(inStoreDirectory storeDirectoryURL: URL) throws -> Set<String> {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = ModelContext(container)
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        return Set(spaces.map(\.profileId))
    }

    private static func profileDisplayNames(inStoreDirectory storeDirectoryURL: URL) throws -> [String: String] {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = ModelContext(container)
        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        var displayNames: [String: String] = [:]
        for profile in profiles {
            guard let displayName = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayName.isEmpty else {
                continue
            }
            displayNames[profile.profileId] = displayName
        }
        return displayNames
    }

    private static func openImportedLocalStoreContainer(at storeDirectoryURL: URL) throws -> ModelContainer {
        let compatibilityController = LocalStoreCompatibilityController(
            configuration: LocalStore.compatibilityConfiguration
        )
        let compatibilityResult = try compatibilityController.prepareStore(at: storeDirectoryURL)
        let openPlan: LocalStoreOpenPlan
        switch compatibilityResult {
        case .ready(let plan):
            openPlan = plan
        case .requiresNewerApp(let issue):
            throw NSError(
                domain: "PhiUserDataImport",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "The imported local store at \(storeDirectoryURL.path) requires a newer Mist data format (\(issue.activeStoreFormatVersion))."
                ]
            )
        }

        let configuration = ModelConfiguration(
            url: storeDirectoryURL.appendingPathComponent(LocalStore.compatibilityConfiguration.storeFilename)
        )
        let container = try ModelContainer(
            for: TabDataModel.self,
            ProfileModel.self,
            SpaceModel.self,
            SpaceURLRule.self,
            BrowserDataSettingsModel.self,
            migrationPlan: TabDataModelMigrationPlan.self,
            configurations: configuration
        )
        try compatibilityController.markStoreOpenedSuccessfully(openPlan, at: storeDirectoryURL)
        return container
    }

    @MainActor
    private static func createMissingChromiumProfiles(
        for importedProfileIds: Set<String>,
        displayNames importedDisplayNames: [String: String],
        completion: @escaping (Result<PhiUserDataProfileRepairResult, Error>) -> Void
    ) {
        let profileManager = ProfileManager.shared
        profileManager.refresh()
        let existingProfileIds = Set(profileManager.profiles.map(\.profileId))
        var pendingProfileIds = Set(importedProfileIds.filter { $0 != LocalStore.defaultProfileId && !existingProfileIds.contains($0) })

        guard !pendingProfileIds.isEmpty else {
            AppLogInfo("[Debug] Phi user data import profile repair: no missing Chromium profiles")
            completion(.success(PhiUserDataProfileRepairResult(profileIdRemaps: [:], createdProfileIds: [])))
            return
        }

        AppLogInfo("[Debug] Phi user data import profile repair: missingChromiumProfiles=\(formatProfileIds(pendingProfileIds))")
        var profileIdRemaps: [String: String] = [:]
        var createdProfileIds: [String] = []

        func failAndRollback(_ error: Error) {
            rollbackCreatedChromiumProfiles(createdProfileIds) {
                completion(.failure(error))
            }
        }

        func createNextProfile() {
            profileManager.refresh()
            let existingProfileIds = Set(profileManager.profiles.map(\.profileId))
            let satisfiedProfileIds = pendingProfileIds.intersection(existingProfileIds)
            if !satisfiedProfileIds.isEmpty {
                for profileId in satisfiedProfileIds {
                    AppLogInfo("[Debug] Phi user data import profile repair satisfied imported profile \(profileId)")
                    pendingProfileIds.remove(profileId)
                }
            }

            guard let importedProfileId = pendingProfileIds.sorted(by: importedProfileRestoreSort).first else {
                AppLogInfo("[Debug] Phi user data import profile repair completed: remaps=\(formatProfileIdRemaps(profileIdRemaps))")
                completion(.success(PhiUserDataProfileRepairResult(profileIdRemaps: profileIdRemaps, createdProfileIds: createdProfileIds)))
                return
            }

            let displayName = restoredProfileDisplayName(
                for: importedProfileId,
                importedDisplayName: importedDisplayNames[importedProfileId]
            )
            AppLogInfo("[Debug] Phi user data import profile repair creating Chromium profile for \(importedProfileId)")
            profileManager.createProfile(displayName: displayName) { newProfileId in
                guard let newProfileId else {
                    failAndRollback(profileRepairError("Failed to create Chromium profile for imported profile \(importedProfileId)."))
                    return
                }
                createdProfileIds.append(newProfileId)

                if newProfileId == importedProfileId {
                    pendingProfileIds.remove(importedProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId)")
                } else if pendingProfileIds.contains(newProfileId) {
                    pendingProfileIds.remove(newProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId), satisfying imported profile \(newProfileId) before remapping \(importedProfileId)")
                } else {
                    profileIdRemaps[importedProfileId] = newProfileId
                    pendingProfileIds.remove(importedProfileId)
                    AppLogInfo("[Debug] Phi user data import profile repair created Chromium profile \(newProfileId) for imported profile \(importedProfileId)")
                }
                createNextProfile()
            }
        }

        createNextProfile()
    }

    @MainActor
    private static func restoredProfileDisplayName(for importedProfileId: String, importedDisplayName: String?) -> String {
        let profileManager = ProfileManager.shared
        profileManager.refresh()
        let preferredName = importedDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if let preferredName, !preferredName.isEmpty {
            baseName = preferredName
        } else {
            baseName = importedProfileId
        }

        if !profileManager.displayNameExists(baseName) {
            return baseName
        }

        let restoredName = "Restored \(baseName)"
        if !profileManager.displayNameExists(restoredName) {
            return restoredName
        }

        var suffix = 2
        while profileManager.displayNameExists("\(restoredName) \(suffix)") {
            suffix += 1
        }
        return "\(restoredName) \(suffix)"
    }

    @MainActor
    private static func rollbackCreatedChromiumProfiles(_ profileIds: [String], completion: @escaping () -> Void) {
        let rollbackProfileIds = profileIds.reversed()
        guard !rollbackProfileIds.isEmpty else {
            completion()
            return
        }

        AppLogInfo("[Debug] Phi user data import profile repair rolling back Chromium profiles: \(formatProfileIds(Set(profileIds)))")

        func deleteNext(index: ReversedCollection<[String]>.Index) {
            guard index != rollbackProfileIds.endIndex else {
                completion()
                return
            }

            let profileId = rollbackProfileIds[index]
            ProfileManager.shared.deleteProfile(profileId) { success, error in
                if success {
                    AppLogInfo("[Debug] Phi user data import profile repair rolled back Chromium profile \(profileId)")
                } else {
                    AppLogWarn("[Debug] Phi user data import profile repair failed to roll back Chromium profile \(profileId): \(error?.reasonText ?? "unknown error")")
                }
                deleteNext(index: rollbackProfileIds.index(after: index))
            }
        }

        deleteNext(index: rollbackProfileIds.startIndex)
    }

    private static func formatProfileIds(_ profileIds: Set<String>) -> String {
        let sorted = profileIds.sorted(by: importedProfileRestoreSort)
        return sorted.isEmpty ? "none" : sorted.joined(separator: ",")
    }

    private static func formatProfileIdRemaps(_ profileIdRemaps: [String: String]) -> String {
        guard !profileIdRemaps.isEmpty else {
            return "none"
        }
        return profileIdRemaps
            .sorted { lhs, rhs in importedProfileRestoreSort(lhs.key, rhs.key) }
            .map { "\($0.key)->\($0.value)" }
            .joined(separator: ",")
    }

    private static func importedProfileRestoreSort(_ lhs: String, _ rhs: String) -> Bool {
        let lhsProfileNumber = chromiumGeneratedProfileNumber(lhs)
        let rhsProfileNumber = chromiumGeneratedProfileNumber(rhs)
        switch (lhsProfileNumber, rhsProfileNumber) {
        case let (lhs?, rhs?):
            return lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func chromiumGeneratedProfileNumber(_ profileId: String) -> Int? {
        let prefix = "Profile "
        guard profileId.hasPrefix(prefix) else {
            return nil
        }
        return Int(profileId.dropFirst(prefix.count))
    }

    private static func applyImportedProfileIdRemaps(_ profileIdRemaps: [String: String], in phiDataURL: URL) throws {
        let effectiveRemaps = profileIdRemaps.filter { $0.key != $0.value }
        guard !effectiveRemaps.isEmpty else {
            return
        }

        for storeDirectoryURL in try importedLocalStoreDirectoryURLs(in: phiDataURL) {
            try applyImportedProfileIdRemaps(effectiveRemaps, inStoreDirectory: storeDirectoryURL)
        }
    }

    private static func applyImportedProfileIdRemaps(_ profileIdRemaps: [String: String], inStoreDirectory storeDirectoryURL: URL) throws {
        let container = try openImportedLocalStoreContainer(at: storeDirectoryURL)
        let context = ModelContext(container)
        var didChange = false

        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        for space in spaces {
            guard let newProfileId = profileIdRemaps[space.profileId] else {
                continue
            }
            space.profileId = newProfileId
            space.updatedDate = Date()
            didChange = true
        }

        let tabs = try context.fetch(FetchDescriptor<TabDataModel>())
        for tab in tabs {
            guard let oldProfileId = tab.profileId,
                  let newProfileId = profileIdRemaps[oldProfileId] else {
                continue
            }
            tab.profileId = newProfileId
            tab.updatedDate = Date()
            didChange = true
        }

        let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
        var profilesById: [String: ProfileModel] = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.profileId, $0) }
        )
        for profile in profiles {
            guard let newProfileId = profileIdRemaps[profile.profileId] else {
                continue
            }
            if let targetProfile = profilesById[newProfileId], targetProfile !== profile {
                for tab in profile.tabs {
                    tab.profile = targetProfile
                    tab.profileId = newProfileId
                }
                if targetProfile.bookmarkRoot == nil {
                    targetProfile.bookmarkRoot = profile.bookmarkRoot
                }
                if targetProfile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    targetProfile.displayName = profile.displayName
                }
                context.delete(profile)
            } else {
                profilesById.removeValue(forKey: profile.profileId)
                profile.profileId = newProfileId
                profilesById[newProfileId] = profile
            }
            didChange = true
        }

        if didChange {
            try context.save()
        }
    }

    private static func profileRepairError(_ message: String) -> NSError {
        NSError(
            domain: "PhiUserDataImport",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func runUnzip(archive: URL, destination: URL) throws {
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", destination.path]
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "unzip exited with status \(process.terminationStatus)." : errText
            throw NSError(domain: "PhiUserDataImport", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    @MainActor
    static func relaunchPhiApplication() {
        let bundlePath = Bundle.main.bundleURL.path
        let quoted = shellSingleQuotedForSh(bundlePath)
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "( while /bin/kill -0 \(processIdentifier) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \(quoted) ) &",
        ]
        do {
            try relaunch.run()
            relaunch.waitUntilExit()
        } catch {
            AppLogError("Failed to schedule Phi relaunch: \(error.localizedDescription)")
            return
        }

        NSApp.terminate(nil)
    }

    private static func shellSingleQuotedForSh(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
