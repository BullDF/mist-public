// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation

/// One row from the Chromium-side profile attributes store, projected to
/// Swift. `profileId` is the on-disk basename and the wire identifier used
/// in every bridge call. `isInUse` reflects whether a live Chromium Browser
/// is currently bound to this profile (orthogonal to whether a `Space`
/// references it — that check lives on `SpaceManager`).
struct PhiBrowserProfile: Hashable, Identifiable {
    let profileId: String
    let displayName: String
    let isLoaded: Bool
    let isInUse: Bool

    var id: String { profileId }
}

/// Why `ProfileManager.deleteProfile` failed.
enum ProfileDeletionFailure: Error {
    /// A reason from the bridge, shown as-is; nil when none was given.
    case reason(String?)
    /// The reason text, for callers that only log it.
    var reasonText: String? {
        switch self {
        case .reason(let text): return text
        }
    }
}

struct SearchEngineInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let keyword: String
    let isDefault: Bool
}

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [PhiBrowserProfile] = []

    var userAssignableProfiles: [PhiBrowserProfile] { profiles }

    private init() {
        refresh()
    }

    // MARK: - Read

    static let listDidChange = Notification.Name("ProfileManager.listDidChange")

    /// Complete, read-only bridge projection. Unlike refresh(), this does not
    /// persist names.
    static func readProfiles() -> [PhiBrowserProfile]? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return nil }
        let raw = bridge.listProfiles()
        let decoded = raw.compactMap(Self.decode(_:))
        guard !decoded.isEmpty, decoded.count == raw.count else { return nil }
        return decoded
    }

    /// Pulls the latest profile list from the bridge. Synchronous and
    /// cheap (Chromium-side just reads from in-memory ProfileAttributesStorage).
    /// Safe to call repeatedly on the main thread.
    @discardableResult
    func refresh() -> Bool {
        // An incomplete bridge response must not look like Profile deletion.
        guard let decodedProfiles = Self.readProfiles() else { return false }
        let identityChanged = Set(profiles.map(\.profileId)) != Set(decodedProfiles.map(\.profileId))
        profiles = decodedProfiles
        if identityChanged {
            NotificationCenter.default.post(name: Self.listDidChange, object: self)
        }
        persistDisplayNamesToLocalStore(decodedProfiles)
        return true
    }

    /// Convenience lookup — nil if the basename isn't known. Most callers
    /// only need the displayName for UI labelling.
    func profile(for profileId: String) -> PhiBrowserProfile? {
        profiles.first(where: { $0.profileId == profileId })
    }

    /// True when some existing profile already uses `name` (compared
    /// case-insensitively, after trimming). Pass `excluding` while renaming so
    /// a profile isn't flagged as a duplicate of itself. Chromium itself allows
    /// duplicate profile names; this is a Phi-side guard so the create / rename
    /// prompts can keep display names unique — two identically named profiles
    /// are indistinguishable in menus and pickers.
    func displayNameExists(_ name: String, excluding profileId: String? = nil) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return profiles.contains {
            $0.profileId != profileId &&
            $0.displayName.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    // MARK: - Mutations

    /// Sync preserves distinct remote identities even when concurrent changes
    /// produce equal names. User-facing callers keep the uniqueness guard.
    func createProfile(displayName: String,
                       allowsDuplicateDisplayName: Bool = false,
                       completion: @escaping (String?) -> Void) {
        refresh()
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, allowsDuplicateDisplayName || !displayNameExists(trimmed, excluding: nil) else {
            completion(nil)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.createProfile(withDisplayName: trimmed) { [weak self] newId in
            DispatchQueue.main.async {
                self?.refresh()
                completion(newId)
            }
        }
    }

    /// Backfills the iCloud Passwords preference for existing profiles. If the choice was never
    /// recorded AND there is exactly one (default) profile whose enabled
    /// extensions already include iCloud Passwords, adopt it as the choice so
    /// new profiles inherit it. Driven by the extensions-loaded signal so the
    /// default profile's extensions are known; idempotent + self-healing.
    func backfillICloudPasswordsPrefIfNeeded(installedExtensionIds: [String]) {
        let pref = PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords
        guard !pref.isSet else { return }
        refresh()
        guard profiles.count == 1 else { return }
        guard installedExtensionIds.contains(PhiExtensionID.icloudPasswords) else { return }
        pref.save(true)
    }

    /// Schedules a profile for deletion. Completion fires on the main queue
    /// with success/error. Callers MUST refuse the action while any Space is
    /// bound to this profile — `SpaceManager.isProfileInUse` is the
    /// authoritative check, including at action time after a confirmation
    /// modal. There is no backstop below this call: Space bindings are a
    /// Mac-side concept the Chromium bridge knows nothing about, so an
    /// unguarded delete strands the bound Spaces on a nonexistent profile.
    /// The user-data backup rollback flow bypasses the guard deliberately —
    /// it deletes profiles wholesale while restoring a snapshot.
    @MainActor
    func deleteProfile(_ profileId: String,
                       removeLocalData: Bool = false,
                       completion: @escaping (Bool, ProfileDeletionFailure?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, .reason("bridge unavailable"))
            return
        }
        // Keep cleanup attached to the original account across the asynchronous Chromium deletion.
        let account = AccountController.shared.localDataAccount
        let finish: @MainActor (Bool, String?) -> Void = { [weak self] success, error in
            self?.refresh()
            if success, removeLocalData {
                Task { @MainActor in
                    await Self.removeLocalRows(ofDeletedProfile: profileId, account: account)
                }
            }
            completion(success, success ? nil : .reason(error))
        }
        bridge.deleteProfile(profileId) { success, error in
            Task { @MainActor in finish(success, error) }
        }
    }

    @MainActor
    static func removeLocalRows(ofDeletedProfile profileId: String, account: Account) async {
        do {
            try await account.localStorage.deleteProfileRowCascadeThrowing(profileId: profileId)
        } catch {
            AppLogWarn("[ProfileManager] could not remove the deleted profile's local rows")
        }
    }

    /// Renames a profile's display name. Completion fires on the main queue with
    /// success/error (failing on an empty or duplicate name). Refreshes the
    /// published list before completion fires so subscribers observe the new name.
    ///
    /// Same submit-time guard as `createProfile`: the rename prompt greys out its
    /// confirm button live, but re-check uniqueness here so a stale list can't
    /// commit a duplicate.
    func renameProfile(_ profileId: String,
                       to displayName: String,
                       allowsDuplicateDisplayName: Bool = false,
                       completion: @escaping (Bool, String?) -> Void) {
        refresh()
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, allowsDuplicateDisplayName || !displayNameExists(trimmed, excluding: profileId) else {
            completion(false, nil)
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.renameProfile(profileId, toDisplayName: trimmed) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.refresh()
                completion(success, error)
            }
        }
    }

    private func persistDisplayNamesToLocalStore(_ profiles: [PhiBrowserProfile]) {
        var displayNamesByProfileId: [String: String] = [:]
        for profile in profiles {
            displayNamesByProfileId[profile.profileId] = profile.displayName
        }
        Task { @MainActor in
            AccountController.shared.localDataAccount.localStorage
                .upsertProfileDisplayNames(displayNamesByProfileId)
        }
    }

    // MARK: - Per-profile settings

    /// Lists the search engines Mist offers for a profile: Google and Bing,
    /// plus the current default if it's neither, so the picker always shows
    /// the engine in use. Completion fires on the main queue; empty on failure.
    /// May load the profile first, so the callback can be delayed for an off
    /// profile.
    func searchEngines(forProfile profileId: String,
                       completion: @escaping ([SearchEngineInfo]) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion([])
            return
        }
        bridge.listSearchEngines(profileId) { raw in
            DispatchQueue.main.async {
                completion((raw ?? []).compactMap(Self.decodeEngine(_:)).filter {
                    $0.isDefault || Self.offeredSearchEngineKeywords.contains($0.keyword.lowercased())
                })
            }
        }
    }

    func setDefaultSearchEngine(_ engineId: String,
                                forProfile profileId: String,
                                completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDefaultSearchEngine(profileId, engineId: engineId) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Reads a profile's default download directory. Completion fires on the
    /// main queue; nil on failure.
    func downloadLocation(forProfile profileId: String,
                          completion: @escaping (String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(nil)
            return
        }
        bridge.getDownloadLocation(profileId) { path in
            DispatchQueue.main.async { completion(path) }
        }
    }

    /// Sets a profile's default download directory. Completion fires on the main
    /// queue with success/error.
    func setDownloadLocation(_ path: String,
                             forProfile profileId: String,
                             completion: @escaping (Bool, String?) -> Void) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.setDownloadLocation(profileId, path: path) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    /// Opens one of a profile's data/settings pages ("privacy", "passwords",
    /// "payments", "notifications", "clearBrowserData") in a browser window for
    /// that profile. Completion fires on the main queue with success/error.
    func openDataPage(_ page: String,
                      forProfile profileId: String,
                      completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            completion(false, "bridge unavailable")
            return
        }
        bridge.openProfileDataPage(profileId, page: page) { success, error in
            DispatchQueue.main.async { completion(success, error) }
        }
    }

    // MARK: - Wire decoding

    private static func decode(_ dict: [String: Any]) -> PhiBrowserProfile? {
        guard let id = dict["profileId"] as? String,
              let name = dict["displayName"] as? String else {
            return nil
        }
        let loaded = (dict["isLoaded"] as? NSNumber)?.boolValue ?? false
        let inUse = (dict["isInUse"] as? NSNumber)?.boolValue ?? false
        return PhiBrowserProfile(
            profileId: id,
            displayName: name,
            isLoaded: loaded,
            isInUse: inUse
        )
    }

    /// Chromium's prepopulated keywords for Google and Bing.
    private static let offeredSearchEngineKeywords: Set<String> = ["google.com", "bing.com"]

    private static func decodeEngine(_ dict: [String: Any]) -> SearchEngineInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }
        let keyword = dict["keyword"] as? String ?? ""
        let isDefault = (dict["isDefault"] as? NSNumber)?.boolValue ?? false
        return SearchEngineInfo(id: id, name: name, keyword: keyword, isDefault: isDefault)
    }

}
