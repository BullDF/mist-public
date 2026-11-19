// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Account-scoped preferences persisted to a plist under `account.userDataStorage/defaults`.
///
/// Memory must never lead disk (R-M3-4a-83). Both `set(_:forKey:)` overloads snapshot `storage` and restore it on
/// persistence failure within the same `queue.sync` block. A failed write must not leave an in-memory value
/// that causes the next read-modify-write to skip persistence (§2.7, second round after plist write failure).
///
/// Each overload owns its `queue.sync` block and returns whether persistence succeeded. Snapshot and
/// rollback must stay in that block so another writer's changes cannot be rolled back.
final class AccountUserDefaults {
    private let account: Account
    private let storeURL: URL
    private let queue: DispatchQueue
    private var storage: [String: Any]

    init(account: Account, storeURL overrideStoreURL: URL? = nil) {
        self.account = account
        let fileURL = overrideStoreURL ?? Self.storeURL(for: account)
        let defaultsDir = fileURL.deletingLastPathComponent()
        self.storeURL = fileURL
        self.queue = DispatchQueue(label: "com.phibrowser.accountDefaults.\(account.userID)")

        do {
            try FileManager.default.createDirectory(at: defaultsDir, withIntermediateDirectories: true)
        } catch {
            AppLogError("Failed to create defaults directory: \(error.localizedDescription)")
        }

        self.storage = AccountUserDefaults.loadStore(from: fileURL)
    }

    // MARK: - Public API (UserDefaults-like)
    func object(forKey key: String) -> Any? {
        queue.sync {
            storage[key]
        }
    }

    /// Returns true after persistence; restores the previous `storage` on failure (R-M3-4a-83).
    @discardableResult
    func set(_ value: Any?, forKey key: String) -> Bool {
        queue.sync {
            let previous = storage
            if let value = value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            guard persistLocked() else {
                storage = previous
                return false
            }
            return true
        }
    }

    /// The `DefaultsKey` overload owns its `queue.sync` block and must implement rollback too; updating only
    /// one overload produces no type error.
    @discardableResult
    func set(_ value: Any?, forKey key: DefaultsKey) -> Bool {
        queue.sync {
            let previous = storage
            if let value = value {
                storage[key.rawValue] = value
            } else {
                storage.removeValue(forKey: key.rawValue)
            }
            guard persistLocked() else {
                storage = previous
                return false
            }
            return true
        }
    }

    func double(forKey key: String) -> Double {
        object(forKey: key) as? Double ?? 0
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    // MARK: - Helpers
    /// Where `account`'s defaults plist lives.
    static func storeURL(for account: Account) -> URL {
        account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
            .appendingPathComponent("account_defaults.plist")
    }

    /// One value straight off the plist of the account with `userID`, without
    /// opening a store: no directory is created and nothing is retained. For
    /// the launch-time read that runs before any account is bound
    /// (`SpaceManager.coldStartPreferredProfiles`).
    static func storedObject(forKey key: DefaultsKey, ofAccountWithUserID userID: String) -> Any? {
        storedObject(forKey: key.rawValue, ofAccountWithUserID: userID)
    }

    /// The raw-key form, for a key derived from a `DefaultsKey` rather than
    /// one of them (`SpaceManager.slotsRestoreSnapshotDefaultsKey`).
    static func storedObject(forKey key: String, ofAccountWithUserID userID: String) -> Any? {
        loadStore(from: storeURL(for: Account(userID: userID)))[key]
    }

    private static func loadStore(from url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return plist as? [String: Any] ?? [:]
        } catch {
            AppLogError("Failed to load account defaults: \(error.localizedDescription)")
            return [:]
        }
    }

    /// The caller must hold `queue` and handle false: all six write APIs use it to trigger rollback.
    private func persistLocked() -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: storage, format: .xml, options: 0)
            try data.write(to: storeURL, options: .atomic)
            return true
        } catch {
            AppLogError("Failed to write account defaults: \(error.localizedDescription)")
            return false
        }
    }

}

extension AccountUserDefaults {
    enum DefaultsKey: String {
        /// Controls whether notification cards auto-popup. Default is popup enabled.
        case notificationPopupMode
        case lastKnownSidebarWidth
        case activeSpaceId
        /// The Space currently holding the "default" role (see
        /// `SpaceManager.currentDefaultSpaceId`). Absent until the user
        /// deletes the well-known `default-space`, whose id is the
        /// implicit initial value; deletion hands the role to another
        /// Space and records it here so it survives relaunches.
        case defaultSpaceId
        /// Per-Space theme override map (`[spaceId: themeId]`). A spaceId
        /// missing from this map means "follow the global theme"; an entry
        /// means the Space pins itself to that theme regardless of the
        /// global selection. Stored here rather than on `SpaceModel` to
        /// avoid a schema migration for what is purely a UI preference.
        case spaceThemeIds
        /// Legacy per-Space window-overlay opacity map. ThemeSnapshot V2 no
        /// longer reads these values; the key remains only so Space deletion
        /// can clean records written by older builds.
        case spaceOverlayOpacities
        /// Per-Space theme saturation map. Overlay entries are keyed by
        /// appearance; `windowBackgroundDark` carries the matching dark
        /// window-background saturation.
        case spaceThemeSaturations
        /// Per-Space Pure-theme slider value. The shared position maps to
        /// separate light and dark brightness ranges.
        case spacePureThemeSliderValues
        /// Snapshot of the slot/window/Space layout written on every
        /// `SpaceWindowSlot.registerWindow`. Read on the next launch by
        /// `SpaceManager` so Chromium-restored windows reattach to the
        /// Space they had when the snapshot was saved, instead of all
        /// piling into the persisted-active Space. Under an explicit
        /// `--user-data-dir` the stored key carries that directory
        /// (`SpaceManager.slotsRestoreSnapshotKey`): the ids it maps belong
        /// to one Chromium data directory only.
        case slotsRestoreSnapshot
    }

    /// Notification popup behavior mode.
    enum NotificationPopupMode: String {
        /// Cards automatically appear when new notifications arrive.
        case popup
        /// Cards stay hidden until the user opens them manually.
        case mute

    }

    /// Current notification popup mode.
    var notificationPopupMode: NotificationPopupMode {
        guard let rawValue = string(forKey: DefaultsKey.notificationPopupMode.rawValue),
              let mode = NotificationPopupMode(rawValue: rawValue) else {
            return .popup
        }
        return mode
    }

    /// Persists the notification popup mode and broadcasts the change.
    func setNotificationPopupMode(_ mode: NotificationPopupMode) {
        set(mode.rawValue, forKey: DefaultsKey.notificationPopupMode.rawValue)
        NotificationCenter.default.post(
            name: .notificationPopupModeDidChange,
            object: nil,
            userInfo: ["mode": mode]
        )
    }

    var lastKnownSidebarWidth: CGFloat {
        CGFloat(double(forKey: DefaultsKey.lastKnownSidebarWidth.rawValue))
    }

    func setLastKnownSidebarWidth(_ width: CGFloat) {
        guard width > 0 else {
            return
        }
        set(Double(width), forKey: DefaultsKey.lastKnownSidebarWidth.rawValue)
    }

    /// Snapshot of the per-Space theme override map. Returns an empty
    /// dictionary when no Spaces have a theme override set yet.
    func spaceThemeIds() -> [String: String] {
        (object(forKey: DefaultsKey.spaceThemeIds.rawValue) as? [String: String]) ?? [:]
    }

    /// Persists the per-Space theme override map verbatim. Callers should
    /// mutate a snapshot from `spaceThemeIds()` and pass the new map here.
    func setSpaceThemeIds(_ map: [String: String]) {
        set(map, forKey: DefaultsKey.spaceThemeIds.rawValue)
    }

    /// Reads legacy per-Space opacity records for cleanup only.
    func spaceOverlayOpacities() -> [String: [String: Double]] {
        (object(forKey: DefaultsKey.spaceOverlayOpacities.rawValue) as? [String: [String: Double]]) ?? [:]
    }

    /// Updates legacy per-Space opacity records during cleanup.
    func setSpaceOverlayOpacities(_ map: [String: [String: Double]]) {
        set(map, forKey: DefaultsKey.spaceOverlayOpacities.rawValue)
    }

    /// Snapshot of the per-Space theme-saturation map. Returns an empty
    /// dictionary when no Space has a custom saturation yet.
    func spaceThemeSaturations() -> [String: [String: Double]] {
        (object(forKey: DefaultsKey.spaceThemeSaturations.rawValue) as? [String: [String: Double]]) ?? [:]
    }

    /// Persists the per-Space theme-saturation map verbatim. Callers should
    /// mutate a snapshot from `spaceThemeSaturations()` and pass it back.
    func setSpaceThemeSaturations(_ map: [String: [String: Double]]) {
        set(map, forKey: DefaultsKey.spaceThemeSaturations.rawValue)
    }

    /// Snapshot of the per-Space Pure-theme slider-value map.
    func spacePureThemeSliderValues() -> [String: Double] {
        (object(forKey: DefaultsKey.spacePureThemeSliderValues.rawValue) as? [String: Double]) ?? [:]
    }

    /// Persists the per-Space Pure-theme slider-value map verbatim.
    func setSpacePureThemeSliderValues(_ map: [String: Double]) {
        set(map, forKey: DefaultsKey.spacePureThemeSliderValues.rawValue)
    }

}

extension Notification.Name {
    /// Posted when the notification popup mode setting changes.
    static let notificationPopupModeDidChange = Notification.Name("notificationPopupModeDidChange")
}
