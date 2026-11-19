// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// The single delete-Space confirmation shared by Settings, the sidebar strip
/// and the app menu. Callers keep their own guards, the deletion.
@MainActor
enum SpaceDeletionConfirmation {
    /// Returns true when the user confirmed the deletion.
    static func run(space: Space) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.spaces.deleteConfirmation.title", value: "Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = informativeText(
            pinnedTabScope: AccountController.shared.localDataAccount.localStorage.pinnedTabScope()
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.spaces.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func informativeText(pinnedTabScope: PinnedTabScope?) -> String {
        var text: String
        if pinnedTabScope == .space {
            text = NSLocalizedString("settings.spaces.deleteConfirmation.spaceScopedMessage", value: "Bookmarks and pinned tabs belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation with Space-scoped pinned tabs"
            )
        } else {
            text = NSLocalizedString("settings.spaces.deleteConfirmation.message", value: "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation"
            )
        }
        return text
    }
}

/// The single delete-Profile flow shared by Settings and the app menu:
/// confirmation, the post-modal in-use re-check, the deletion and its failure alert.
@MainActor
enum ProfileDeletionFlow {
    static func confirmAndDelete(_ profile: PhiBrowserProfile) {
        guard profile.profileId != LocalStore.defaultProfileId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("settings.profiles.deleteConfirmation.title", value: "Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = informativeText()
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.deleteButton", value: "Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("settings.profiles.deleteConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Re-check AFTER the modal: the delete control was validated before it
        // opened, and a Space can be bound to this profile while the
        // confirmation sits on screen (background work — the agent surface
        // included — keeps running under runModal). Nothing below this guard
        // re-checks: neither ProfileManager nor the Chromium bridge knows
        // about Space bindings.
        guard !SpaceManager.shared.isProfileInUse(profile.profileId) else {
            presentFailure(NSLocalizedString("settings.profiles.deleteFailure.inUseBySpace", value: "A Space is using this profile. Delete that Space or change its profile first.",
                comment: "Body of the profile-delete error when a Space became bound to the profile before the deletion ran"
            ))
            return
        }
        ProfileManager.shared.deleteProfile(profile.profileId, removeLocalData: true) { success, failure in
            guard !success else { return }
            switch failure {
            case .reason(let reason?):
                presentFailure(reason)
            case .reason(nil), nil:
                presentFailure(NSLocalizedString("settings.profiles.deleteFailure.unknownError", value: "Unknown error", comment: "Fallback profile-delete error reason"))
            }
        }
    }

    static func informativeText() -> String {
        let text = NSLocalizedString("settings.profiles.deleteConfirmation.browserDataAndChats", value: "Cookies, history, extensions, and other browser data in this profile will be permanently removed. Conversations will be kept in Phi Chat under Uncategorized. If AI is disabled or unavailable, conversations will be moved when AI is enabled and available again.",
            comment: "Profiles settings - Profile deletion confirmation distinguishing permanently removed browser data from retained conversations and explaining deferred organization while AI is unavailable"
        )
        return text
    }

    private static func presentFailure(_ reason: String) {
        let errAlert = NSAlert()
        errAlert.messageText = NSLocalizedString("settings.profiles.deleteFailure.title", value: "Couldn't delete profile", comment: "Title of the profile-delete error")
        errAlert.informativeText = reason
        errAlert.runModal()
    }
}
