// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Foundation
import SwiftUI
@objc class PhiChromiumCoordinator: NSObject {
    @objc static var shared = PhiChromiumCoordinator()

    /// App-scoped download events for aggregate views spanning browser windows.
    let downloadEvents = PassthroughSubject<ChromiumDownloadEvent, Never>()

    /// Live ask-Space overlays keyed by the source windowId, so a second
    /// match for the same window replaces (rather than stacks) the prompt and
    /// dismissal can tear the right one down.
    private var activeChoosers: [Int64: NSWindow] = [:]
    /// `willClose` observers for the source windows hosting an active chooser,
    /// keyed the same way. Drained in lockstep with `activeChoosers` so a
    /// source window closing mid-prompt can't leak its overlay NSWindow (the
    /// overlay is `isReleasedWhenClosed = false` and AppKit only detaches it
    /// from the parent, it doesn't drop our dictionary reference).
    private var chooserCloseObservers: [Int64: NSObjectProtocol] = [:]
    /// How each active chooser resolves as declined ("keep it here"), keyed
    /// the same way; used when its Space leaves the shell unanswered.
    private var chooserDeclines: [Int64: () -> Void] = [:]
    /// Crash payloads that arrived before their (cross-window-dragged) tab was
    /// created on the Mac side, keyed by Chromium tab guid. Drained by
    /// `BrowserState.handleNewTabFromChromium` when the tab appears.
    private var pendingCrashBuffer: [Int: CrashPageData] = [:]

    /// True while a backup import is creating Chromium profiles; read via the
    /// bridge by preinstalled apps to defer extension preinstall. Main-thread only.
    var isBackupImportInProgress = false

}

extension PhiChromiumCoordinator: @preconcurrency PhiChromiumBridgeDelegate {
    func shouldEnablePhiExtensions() -> Bool {
        false
    }

    /// Chromium is about to replay a profile's session at cold start and is
    /// asking which windows to rebuild now. Answered from the restore
    /// snapshot already in memory; nil keeps the full replay. Synchronous by
    /// contract — the replay is waiting on this stack.
    func coldStartEagerWindowIds() -> [NSNumber]? {
        MainActor.assumeIsolated { SpaceManager.shared.coldStartEagerWindowIds() }
    }

    func coldStartRestorePlan() -> [String: [NSNumber]]? {
        MainActor.assumeIsolated { SpaceManager.shared.coldStartRestorePlan() }
    }

    /// Which profiles own this cold start's eager windows, so the replay can
    /// start with one that will hand a window back. Same gate, classification
    /// and tick as the plan above; nil keeps Chromium's stored order.
    func coldStartPreferredProfiles() -> [String]? {
        MainActor.assumeIsolated { SpaceManager.shared.coldStartPreferredProfiles() }
    }

    /// What that replay actually parked, per profile, as it happens.
    func coldStartParkedGhostWindows(
        _ parkedWindowIdsByProfileId: [String: [NSNumber]]
    ) {
        let windowIdsByProfileId = parkedWindowIdsByProfileId.mapValues {
            $0.map(\.intValue)
        }
        MainActor.assumeIsolated {
            SpaceManager.shared.applyColdStartParkedGhostReceipt(
                windowIdsByProfileId: windowIdsByProfileId)
        }
    }

    /// The receipt with the replay half: the same parked registry, plus
    /// which profile's replay this receipt settles and the saved window ids
    /// that replay matched — the cold-start repair hook. A framework that
    /// knows this selector calls it INSTEAD of the plain one above.
    func coldStartParkedGhostWindows(
        _ parkedWindowIdsByProfileId: [String: [NSNumber]],
        replayedForProfile profileBasename: String,
        replayedWindowIds: [NSNumber]
    ) {
        let windowIdsByProfileId = parkedWindowIdsByProfileId.mapValues {
            $0.map(\.intValue)
        }
        MainActor.assumeIsolated {
            SpaceManager.shared.applyColdStartReplayReceipt(
                windowIdsByProfileId: windowIdsByProfileId,
                reportingProfileId: profileBasename,
                replayedWindowIds: replayedWindowIds.map(\.intValue))
        }
    }

    /// Source of truth for the browser-process DevTools gate that blocks
    /// remote-debugging clients from the user's own Spaces. Read live per gated
    /// command, so the Settings toggle applies without a relaunch.
    func agentUserSpaceOperationsEnabled() -> Bool {
        true
    }

    /// A CDP client drove a tab in one of the user's own Spaces. The app has no
    /// other way to see this — page automation rides a socket it handed to
    /// Chromium — so the mask follows these reports rather than a driver's
    /// goodwill. Delivered on the UI thread, which is the main thread.
    func agentDidOperateUserSpaceTab(_ tabId: Int64, windowId: Int64, sessionId: Int64) {
        guard Thread.isMainThread else {
            assertionFailure("agentDidOperateUserSpaceTab off the main thread")
            return
        }
        MainActor.assumeIsolated {
            AgentUserSpaceDriveRegistry.shared.didOperate(
                tabId: tabId.intValue, windowId: windowId.intValue, sessionId: sessionId)
        }
    }

    /// The same session is working on the tab without driving it. Only keeps
    /// an existing mask alive — a reading agent never claims a page.
    func agentDidObserveUserSpaceTab(_ tabId: Int64, windowId: Int64, sessionId: Int64) {
        guard Thread.isMainThread else {
            assertionFailure("agentDidObserveUserSpaceTab off the main thread")
            return
        }
        MainActor.assumeIsolated {
            AgentUserSpaceDriveRegistry.shared.didObserve(
                tabId: tabId.intValue, windowId: windowId.intValue, sessionId: sessionId)
        }
    }

    /// That driving session ended — the real close event behind the mask, as
    /// opposed to the idle timeout that would otherwise be the only signal.
    func agentDidStopOperatingUserSpaceTab(_ tabId: Int64, sessionId: Int64) {
        guard Thread.isMainThread else {
            assertionFailure("agentDidStopOperatingUserSpaceTab off the main thread")
            return
        }
        MainActor.assumeIsolated {
            AgentUserSpaceDriveRegistry.shared.didStop(
                tabId: tabId.intValue, sessionId: sessionId)
        }
    }

    func isBackupImporting() -> Bool { isBackupImportInProgress }

    /// Always refill an empty window with a tab: Mist has no client side for
    /// Chromium's placeholder mode (the omnibox opened over an empty window).
    func shouldAutoCreateTabInEmptyWindow() -> Bool { true }

    func shouldAutoInstallICloudPasswords() -> Bool {
        PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords.loadValue()
    }

    @objc(isShortHighlightLinkEnabled)
    func isShortHighlightLinkEnabled() -> Bool {
        // Short links require a Phi account, which Mist doesn't have.
        false
    }

    func isAutoPictureInPictureEnabled() -> Bool {
        PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode() != .off
    }

    func isAutoPipParkEnabled() -> Bool {
        PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode() == .parked
    }

    func handleExtensionMessage(_ type: String, payload: String, requestId: String, senderId: String) -> String? {
        return ExtensionMessageRouter.shared.handle(type: type, payload: payload, requestId: requestId, senderId: senderId)
    }

    func toggleChatSidebar(_ show: NSNumber?) {
        toggleChatSidebar(show, windowId: -1)
    }

    /// `windowId` is the calling tab's Browser window (-1 without a tab). In
    /// hosted mode the active controller is the Space on screen, which a tab
    /// in a background Space calling this is not.
    func toggleChatSidebar(_ show: NSNumber?, windowId: Int64) {
        let manager = SpaceSessionControllersManager.shared
        let owner = windowId >= 0 ? manager.getBrowserState(for: Int(windowId)) : nil
        guard let state = owner ?? manager.activeWindowController?.browserState else {
            return
        }
        if let show {
            state.toggleAIChat(!show.boolValue)
        } else {
            state.toggleAIChat()
        }
    }

    func showFeedbackDialog() {}

    func downloadEventOccurred(_ eventType: DownloadEventType, guid: String,
                               downloadItem: (any DownloadItemWrapper)?, profileId: String,
                               isOffTheRecord: Bool) {
        let eventName: String
        switch eventType {
        case .created: eventName = "CREATED"
        case .updated: eventName = "UPDATED"
        case .completed: eventName = "COMPLETED"
        case .cancelled: eventName = "CANCELLED"
        case .interrupted: eventName = "INTERRUPTED"
        case .paused: eventName = "PAUSED"
        case .resumed: eventName = "RESUMED"
        case .removed: eventName = "REMOVED"
        case .destroyed: eventName = "DESTROYED"
        case .opened: eventName = "OPENED"
        @unknown default: eventName = "UNKNOWN"
        }

        if let item = downloadItem {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), File: \(item.fileNameToReportUser), Progress: \(item.percentComplete)%, State: \(item.state), Speed: \(item.currentSpeed) B/s")
        } else {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), Item: nil")
        }

        downloadEvents.send(.init(eventType: eventType, guid: guid, wrapper: downloadItem,
                                  profileId: profileId, isOffTheRecord: isOffTheRecord))

        // Downloads are profile-scoped, so every open window needs the update.
        for controller in SpaceSessionControllersManager.shared.getAllWindows() {
            guard controller.browserState.profileId == profileId,
                  controller.browserState.isIncognito == isOffTheRecord else { continue }
            controller.browserState.downloadsManager.handleDownloadEvent(
                eventType: eventType,
                guid: guid,
                wrapper: downloadItem,
                profileId: profileId
            )
        }
    }

    func keyEquivalentOverride(forCommand commandId: Int32) -> [String : Any]? {
        let id = Int(commandId)

        guard let state = Shortcuts.chromiumOverrideState(for: id) else {
            return nil
        }

        if state.inheritsDefaults {
            return ["excludedKeyEquivalents": state.excludedKeys.map { key in
                let equivalent = key.menuKeyEquivalent
                return ["keyEquivalent": equivalent.characters,
                        "modifierFlags": equivalent.modifiers.rawValue] as [String: Any]
            }]
        }
        if let key = state.key {
            let menuKey = key.menuKeyEquivalent
            return [
                "keyEquivalent": menuKey.characters,
                "modifierFlags": menuKey.modifiers.rawValue
            ]
        } else {
            return [
                "keyEquivalent": "",
                "modifierFlags": 0
            ]
        }
    }

    func getNativeSettings() -> String {
        return #"{"phiAIEnabled":false}"#
    }

    func handleDeeplink(withUrlString urlString: String, windowId: Int64) -> Bool {
        return DeeplinkHandler.handle(urlString)
    }

    /// A navigation matched a Space URL rule whose action is "ask every time"
    /// and Chromium cancelled it. Dims the source window and presents the
    /// destination chooser (current Space first); opens the URL in the chosen
    /// destination, or keeps it in the source window if the user declines.
    /// Owns the prompt + routing so Chromium stays out of the UI and
    /// Space-window lifecycle.
    func askSpace(forURL urlString: String, defaultSpaceId: String, sourceWindowId: Int64,
                  sourceIsNewTab: Bool, ordinaryNewTab: Bool) {
        // `ordinaryNewTab` picks upstream's top-or-end placement; every new
        // tab opens at the end in Mist. The four-argument callback is what
        // the framework sends a client without this one.
        askSpace(forURL: urlString, defaultSpaceId: defaultSpaceId,
                 sourceWindowId: sourceWindowId, sourceIsNewTab: sourceIsNewTab)
    }

    func askSpace(forURL urlString: String, defaultSpaceId: String, sourceWindowId: Int64, sourceIsNewTab: Bool) {
        Task { @MainActor [self] in
            let manager = SpaceManager.shared
            let spaces = manager.spaces
            guard !spaces.isEmpty,
                  let controller = SpaceSessionControllersManager.shared
                      .controller(for: Int(sourceWindowId)),
                  let sourceWindow = controller.window else {
                // No Spaces to choose from, or the source window is gone — fall
                // back to the rule's default Space rather than dropping the URL.
                manager.routeAskedURL(urlString,
                                      toSpaceId: spaces.isEmpty ? nil : defaultSpaceId,
                                      sourceWindowId: sourceWindowId,
                                      sourceIsNewTab: sourceIsNewTab)
                return
            }
            // Hosted mode: `window` is the shell, which shows another Space
            // while this one is in the background (an agent Space navigating,
            // a redirect after a switch). Nobody can answer for it, so the
            // navigation stays where it started, as a decline would keep it.
            guard controller.isPresentedOrLegacy else {
                AppLogInfo("[SpaceChooser] source window \(sourceWindowId) is not on screen; keeping the URL in its Space")
                manager.routeAskedURL(urlString,
                                      toSpaceId: nil,
                                      sourceWindowId: sourceWindowId,
                                      sourceIsNewTab: sourceIsNewTab)
                return
            }

            // List the current Space first, then the rest in their order.
            // Live Incognito Spaces collapse into ONE generic "Incognito"
            // choice: its id is the rules' generic target, which
            // `routeAskedURL` resolves to the first live Incognito Space —
            // creating one when none exists — so the choice is always
            // offered. It leads when the navigation started in an Incognito
            // Space (that Space is then the resolution target) and trails
            // the user Spaces otherwise.
            let currentSpaceId = controller.spaceId
            let currentIsIncognito = SpaceManager.isIncognitoSpaceId(currentSpaceId)
            let userSpaces = spaces.filter { !SpaceManager.isIncognitoSpaceId($0.spaceId) }
            var ordered = userSpaces.filter { $0.spaceId == currentSpaceId }
                + userSpaces.filter { $0.spaceId != currentSpaceId }
            let incognitoTarget = manager.incognitoRuleTargetSpace()
            if currentIsIncognito {
                ordered.insert(incognitoTarget, at: 0)
            } else {
                ordered.append(incognitoTarget)
            }
            // Resolve each Space's theme (pinned theme + custom overlay
            // opacity) for the source window's appearance, so a row's tint
            // matches what that Space actually looks like.
            let appearance = sourceWindow.effectiveAppearance.phiAppearance
            let items: [SpaceChooserItem] = ordered.map { space in
                let theme = manager.resolvedTheme(forSpaceId: space.spaceId)
                let themeNSColor = theme.color(for: .themeColor, appearance: appearance)
                // Contrast is computed on the opaque color, then the row is
                // tinted with the theme's overlay opacity (the Opacity setting)
                // so the item background is translucent like the box.
                let legible: NSColor = themeNSColor.isLight() ? .black : .white
                let opacity = theme.windowOverlayOpacity(for: appearance)
                // The generic Incognito choice is "current" whenever the
                // navigation started in any Incognito Space — that Space is
                // what the choice resolves to.
                let isCurrent = space.spaceId == currentSpaceId
                    || (currentIsIncognito && space.spaceId == SpaceManager.incognitoRuleTargetId)
                return SpaceChooserItem(
                    id: space.spaceId,
                    name: space.name,
                    iconName: space.iconName,
                    isCurrent: isCurrent,
                    themeColor: Color(nsColor: themeNSColor.withAlphaComponent(opacity)),
                    textColor: Color(nsColor: legible))
            }

            // The box's translucency follows the current Space's resolved
            // overlay opacity, so it matches the window it sits over.
            let currentTheme = manager.resolvedTheme(forSpaceId: currentSpaceId)
            let boxBackground = Color(
                nsColor: currentTheme.color(for: .windowOverlayBackground, appearance: appearance))

            // Replace any prompt already up for this window.
            self.dismissChooser(windowId: sourceWindowId)

            let chooser = SpaceChooserView(items: items, boxBackground: boxBackground) { [weak self] chosen in
                self?.dismissChooser(windowId: sourceWindowId)
                SpaceManager.shared.routeAskedURL(urlString,
                                                  toSpaceId: chosen,
                                                  sourceWindowId: sourceWindowId,
                                                  sourceIsNewTab: sourceIsNewTab)
            }

            // Borderless child window over the source window: a child window
            // sits above the parent (and its accelerated web-content surface)
            // and moves with it, so the dim reliably covers the whole window.
            let overlay = SpaceChooserOverlayWindow(
                contentRect: sourceWindow.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.isReleasedWhenClosed = false
            overlay.contentView = NSHostingView(rootView: chooser)
            overlay.setFrame(sourceWindow.frame, display: false)

            sourceWindow.addChildWindow(overlay, ordered: .above)
            overlay.makeKeyAndOrderFront(nil)
            self.activeChoosers[sourceWindowId] = overlay
            self.chooserDeclines[sourceWindowId] = {
                SpaceManager.shared.routeAskedURL(urlString,
                                                  toSpaceId: nil,
                                                  sourceWindowId: sourceWindowId,
                                                  sourceIsNewTab: sourceIsNewTab)
            }
            // Tear the prompt down if the source window closes underneath it,
            // so a stranded entry can't accumulate for the session. The token
            // is removed in `dismissChooser`. Hosted mode watches the source
            // Space's own Browser window: the shell outlives it.
            let closeChooser: @MainActor (Notification) -> Void = { [weak self] _ in
                self?.dismissChooser(windowId: sourceWindowId)
            }
            self.chooserCloseObservers[sourceWindowId] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: controller.lifecycleWindow ?? sourceWindow,
                queue: .main) { notification in
                    MainActor.assumeIsolated {
                        closeChooser(notification)
                    }
                }
        }
    }

    /// The user picked a Space from the web-content right-click "Open link as"
    /// submenu. Open `urlString` in that Space, reusing the ask-Space routing
    /// path which activates (cold-spawning if needed) the target Space's window
    /// and opens the URL there, bypassing Space URL routing for the re-open.
    func openLink(inSpace spaceId: String, url urlString: String, sourceWindowId: Int64) {
        Task { @MainActor in
            // Right-click "Open link as <Space>" always originates from a real
            // page (you right-clicked a link), never a new tab — so no in-place
            // open / NTP reset.
            SpaceManager.shared.routeAskedURL(urlString,
                                              toSpaceId: spaceId,
                                              sourceWindowId: sourceWindowId,
                                              sourceIsNewTab: false)
        }
    }

    /// A silent Space URL rule auto-routed `urlString` to `spaceId`, but that
    /// Space had no open window, so Chromium cancelled the navigation and asked
    /// us to surface the Space. Reuse the ask-Space routing path, which
    /// activates (cold-spawning if needed) the target Space's window in the
    /// source window's slot and opens the URL there, bypassing Space URL
    /// routing for the re-open so the same rule doesn't re-match in a loop.
    func routeURL(inSpace spaceId: String, url urlString: String, sourceWindowId: Int64,
                  ordinaryNewTab: Bool, sourceIsNewTab: Bool) {
        // `ordinaryNewTab` picks upstream's top-or-end placement; every new
        // tab opens at the end in Mist. The three-argument callback is what
        // the framework sends a client without this one.
        routeURL(inSpace: spaceId, url: urlString, sourceWindowId: sourceWindowId)
    }

    func routeURL(inSpace spaceId: String, url urlString: String, sourceWindowId: Int64) {
        Task { @MainActor in
            // Silent auto-route to a Space with no open window. The stranded
            // source NTP (if any) is reset on the Chromium side via
            // `refreshNewTabInWindow`, so pass false here to avoid resetting it
            // twice; this path is always a Space switch, never an in-place open.
            SpaceManager.shared.routeAskedURL(urlString,
                                              toSpaceId: spaceId,
                                              sourceWindowId: sourceWindowId,
                                              sourceIsNewTab: false)
        }
    }

    /// A Space URL rule routed a new-tab navigation to a different Space (the
    /// URL opened elsewhere). Reset the source window's active new-tab page back
    /// to a clean state. Used by the auto-route-to-an-open-window path, which is
    /// handled entirely on the Chromium side and so signals the refresh here.
    func refreshNewTab(inWindow windowId: Int64) {
        Task { @MainActor in
            SpaceManager.shared.refreshActiveNewTab(inWindow: windowId)
        }
    }

    /// Tears down the ask-Space overlay for `windowId`, if any, and returns
    /// key focus to the parent window. Always called on the main thread (the
    /// presenting Task and the SwiftUI button actions both run there).
    /// Hosted mode: the chooser's Space is leaving the shell with the prompt
    /// unanswered. The overlay belongs to the shell, so it would stay over the
    /// next Space; resolve it the way a decline does.
    func declineChooser(windowId: Int64) {
        guard let decline = chooserDeclines[windowId] else { return }
        dismissChooser(windowId: windowId)
        decline()
    }

    private func dismissChooser(windowId: Int64) {
        chooserDeclines.removeValue(forKey: windowId)
        if let token = chooserCloseObservers.removeValue(forKey: windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        guard let overlay = activeChoosers.removeValue(forKey: windowId) else { return }
        let parent = overlay.parent
        parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        parent?.makeKey()
    }

    func importStarted(_ browserType: BrowserType) {
        AppLogDebug("importStarted type: \(browserType)")
    }

    func importItemProgress(_ browserType: BrowserType, started: Bool) {
        AppLogDebug("importItemProgress type: \(browserType), started: \(started)")
    }

    func importCompleted(_ browserType: BrowserType, success: Bool) {
        AppLogDebug("importCompleted type: \(browserType), success: \(success)")

        NotificationCenter.default.post(
            name: .browserImportCompleted,
            object: nil,
            userInfo: [
                "browserType": browserType.rawValue,
                "success": success
            ]
        )
    }

    func canShowChromiumWindow() -> Bool { true }

    func canOpenExternalLinksInKiosk() -> Bool { false }

    func isPhiGuestMode() -> Bool { true }

    func showLoginUI() {}

    // The framework requires this delegate method; Mist has no Phi account.
    func getAuth0AccessTokenSyncly() -> String { "" }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64) {
        // Legacy entry point kept for framework/client version skew: a Phi
        // Framework built before `restoredFromWindowId` was added calls this
        // selector. Zero means "not a session-restore re-creation", so the
        // restore-snapshot claim below never fires on this path.
        mainBrowserWindowCreated(window,
                                 type: browserType,
                                 profileId: profileId,
                                 windowId: windowId,
                                 restoredFromWindowId: 0)
    }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64) {
        // Legacy entry point kept for framework/client version skew: a Phi
        // Framework built before `restoredSpaceId` was added calls this
        // selector. Nil means "not a tab-restore re-creation", so the
        // restored-Space branch below never fires on this path.
        mainBrowserWindowCreated(window,
                                 type: browserType,
                                 profileId: profileId,
                                 windowId: windowId,
                                 restoredFromWindowId: restoredFromWindowId,
                                 restoredSpaceId: nil)
    }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64, restoredSpaceId: String?, restoredClosedWindowId: Int64) {
        mainBrowserWindowCreated(
            window,
            type: browserType,
            profileId: profileId,
            windowId: windowId,
            restoredFromWindowId: restoredFromWindowId,
            restoredSpaceId: restoredSpaceId,
            restoredClosedWindowId: restoredClosedWindowId,
            presentationContext: nil
        )
    }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64, restoredSpaceId: String?, restoredClosedWindowId: Int64, presentationContext: [String: Any]?) {
        // The undo stack rebuilt the whole window saved as
        // `restoredClosedWindowId`, and Chromium dropped its parked record for
        // that id before making this call. Retire this side's half first, so
        // the placement below — and the snapshot persist a window arrival
        // triggers — never runs against a record describing a window the user
        // is looking at.
        //
        // Deliberately its own field rather than `restoredFromWindowId`: that
        // one is matched against the restore snapshot
        // (`claimRestoredWindow`), and this window claims no saved slot — it
        // is a brand-new group the stack built. Feeding it there would consume
        // the entry's index and re-point the slot the entry belongs to.
        if restoredClosedWindowId > 0 {
            SpaceManager.shared.retireParkedGhostReopenedFromUndoStack(
                windowId: Int(restoredClosedWindowId))
        }
        handleMainBrowserWindowCreated(
            window,
            type: browserType,
            profileId: profileId,
            windowId: windowId,
            restoredFromWindowId: restoredFromWindowId,
            restoredSpaceId: restoredSpaceId,
            restoredClosedWindowId: restoredClosedWindowId
        )
    }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64, restoredSpaceId: String?) {
        handleMainBrowserWindowCreated(
            window,
            type: browserType,
            profileId: profileId,
            windowId: windowId,
            restoredFromWindowId: restoredFromWindowId,
            restoredSpaceId: restoredSpaceId
        )
    }

    private func handleMainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64, restoredSpaceId: String?, restoredClosedWindowId: Int64 = 0) {
        AppLogInfo("🌐 [Chromium] mainBrowserWindowCreated called - windowId: \(windowId), restoredFrom: \(restoredFromWindowId), restoredSpace: \(restoredSpaceId ?? "nil"), type: \(browserType.rawValue)")
        // This callback runs synchronously inside Browser::Create; hosted
        // sessions defer their activation push to Chromium while it is set.
        SpaceSessionControllersManager.shared.isInsideWindowCreatedCallback = true
        defer { SpaceSessionControllersManager.shared.isInsideWindowCreatedCallback = false }

        guard browserType == .normal || browserType == .incognito
                || browserType == .incognitoSpace || browserType == .shadow
                || browserType == .agentSpace else {
            AppLogInfo("🌐 [Chromium] Ignoring unsupported window type: \(browserType.rawValue)")
            // The framework keeps routing tab and extension events for this
            // window (e.g. the Phi Chat web-app window); let EventBus drop them
            // quietly instead of logging a missing window for each one.
            SpaceSessionControllersManager.shared.registerUnmanagedWindow(window, windowId: Int(windowId))
            return
        }

        if browserType == .normal {
            SpaceManager.shared
                .observeNormalWindowProfileForDefaultSpace(profileId)
        }

        // Check Chromium window availability BEFORE creating a controller.

        // Chromium has no concept of Spaces or slots. Resolve which slot
        // (i.e. which user-perceived browser window) this Chromium window
        // belongs to, and what Space it should be tagged with:
        //   1. If some slot has a pending spawn intent for this windowId,
        //      that slot owns the window and the intent carries the spaceId
        //      — covers the "user clicked a Space pip, Chromium spawned a
        //      window for us" path, and stays correct even if the user
        //      clicked another Space in the gap before this async callback.
        //   2. Otherwise this is a Chromium-initiated window: Cmd+N from
        //      the macOS menu bar, session restore, target=_blank with
        //      new-window disposition, etc. Always create a NEW slot so
        //      the new window is its own independent "window group" — if
        //      we attached to the existing keySlot, the new controller
        //      would silently overwrite `keySlot.windowsBySpaceId[spaceId]`
        //      and orphan the original window, leaving its sidebar
        //      routing pip clicks to the wrong window. The new slot
        //      inherits the keySlot's current Space for "Cmd+N opens in
        //      the same context" continuity.
        //
        // Whatever path resolves it, the Space must be bound to the
        // window's actual Chromium profile: pinned tabs and bookmarks are
        // loaded from the controller's profileId, so tagging a window with
        // another profile's Space surfaces that profile's pinned tabs
        // inside the Space. `spaceId(boundTo:preferring:)` re-resolves any
        // inconsistent pair — the spawn path requested the Space's own
        // profile so it's a pass-through there, but the fallback and
        // restore paths pair Chromium's profile with a Swift-chosen Space
        // and the two can disagree.
        let resolvedSlot: SpaceWindowSlot?
        let spaceId: String
        // Tracks whether this window came back through Chromium session restore
        // — the only path that surfaces several windows into one slot, and so
        // the only one that needs the post-restore visibility reconcile below.
        var isRestoredWindow = false
        var waitsForChromiumShow = true
        // Incognito Space windows take the same slot-resolution path as
        // normal ones: they are spawned by a slot with a pending spawn
        // intent, and `spaceId(boundTo:preferring:)` passes through because
        // the synthetic Incognito Space's profileId IS the wire id Chromium
        // reports for them. Standalone incognito stays orthogonal below.
        // Agent Space windows resolve the same way — registered into a slot via
        // the pending-spawn claim from `spawnHiddenWindow` so the user can later
        // switch to them; they differ only in that Chromium never Show()s them
        // (agent-mode browsers), so the window stays ordered out until surfaced.
        if browserType == .normal || browserType == .incognitoSpace || browserType == .agentSpace {
            if let claim = SpaceManager.shared.claimPendingSpawn(forWindowId: Int(windowId)) {
                waitsForChromiumShow = false
                resolvedSlot = claim.slot
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: claim.spaceId)
            } else if let restoredSpace = SpaceManager.shared.restoredSpaceTarget(
                restoredSpaceId, profileId: profileId) {
                // Tab-restore path ("Reopen Closed Window"): the restore entry
                // carried the Space its window belonged to, so honor it instead
                // of inheriting the active Space. Ranked above the
                // session-restore claim below because a Space stamped into the
                // entry is exact, where that claim's zero-id branch only
                // profile-matches a snapshot.
                //
                // A NEW slot, not the key slot: joining the key slot would
                // register this window as a non-active sibling Space and hide
                // it, so the reopen would look like nothing happened. Its own
                // slot opens on the restored Space and is visible.
                spaceId = restoredSpace
                resolvedSlot = SpaceManager.shared.createSlot(initialSpaceId: spaceId)
            } else if let restored = SpaceManager.shared.claimRestoredWindow(
                forRestoredFromWindowId: Int(restoredFromWindowId),
                profileId: profileId,
                arrivingWindowId: Int(windowId)) {
                // Session-restore path: Chromium replays each saved window
                // as a separate `mainBrowserWindowCreated` callback with no
                // pending spawn, reporting the PREVIOUS session's windowId
                // as `restoredFromWindowId` (the per-run `windowId` never
                // matches the persisted snapshot). Without this lookup every
                // restored window would inherit `keySlot.activeSpaceId` and
                // tabs from non-active Spaces would migrate into the active
                // one.
                resolvedSlot = restored.slot
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: restored.spaceId)
                isRestoredWindow = true
                // Where a restored window ends up is decided in three steps —
                // which snapshot entry claimed it, what that entry said its
                // visible Space was, and the profile-consistency re-resolve
                // above — and today a wrong landing Space leaves no record of
                // which one of them was wrong. All three go on this one line,
                // stated positively so the reading never rests on a line being
                // absent.
                AppLogInfo("🌐 [Chromium] restore attribution: restoredFrom=\(restoredFromWindowId) claimed by \(restored.matchedBy.rawValue) → space=\(spaceId) (claimed=\(restored.spaceId), snapshot entry active=\(restored.entryActiveSpaceId ?? "nil"))")
            } else {
                let initial = SpaceManager.shared.keySlot?.activeSpaceId
                    ?? SpaceManager.shared.persistedActiveSpaceId
                    ?? SpaceManager.shared.currentDefaultSpaceId
                // Correct BEFORE creating the slot so it starts on the
                // resolved Space and the window surfaces as the slot's
                // active window below. The mint variant also steers off a
                // Space whose only window is parked as a lazy-restore ghost —
                // this is the one path that CREATES a window for the Space
                // it answers, and a fresh window there would stand beside
                // the parked record as a doubled Space.
                spaceId = SpaceManager.shared.fallbackMintSpaceId(boundTo: profileId,
                                                                  preferring: initial)
                resolvedSlot = SpaceManager.shared.createSlot(initialSpaceId: spaceId)
                // The other half of the attribution line above, and the one
                // that matters: a window Chromium replayed but no snapshot
                // entry claimed lands on whatever `initial` seeded — the key
                // slot's Space, else the persisted one, else the default —
                // which is the wrong-Space symptom itself. Logged for every
                // window taking this branch, ordinary Cmd+N included
                // (`restoredFrom=0` with no restore running names those), so
                // the judgement never has to rest on a missing line.
                AppLogInfo("🌐 [Chromium] restore attribution: restoredFrom=\(restoredFromWindowId) claimed nothing in the snapshot → space=\(spaceId) (minted preferring=\(initial))")
            }
        } else {
            // Incognito / shadow windows are orthogonal to Spaces.
            resolvedSlot = nil
            spaceId = SpaceManager.shared.persistedActiveSpaceId ?? SpaceManager.shared.currentDefaultSpaceId
        }

        let switchTiming = resolvedSlot?.timingForHostedSpawn(spaceId: spaceId)
        switchTiming?.mark("window_callback.attributed")
        defer { switchTiming?.mark("window_callback.return") }
        if let resolvedSlot,
           let dormant = resolvedSlot.dormantSession(forWindowId: Int(windowId)) {
            dormant.browserState.tabNameRestoreSourceWindowId = Int(restoredFromWindowId != 0 ? restoredFromWindowId : restoredClosedWindowId)
            // The Browser was spawned under a window id the slot reserved for
            // a session it built ahead of time: that session takes the
            // window instead of a new controller being made for it.
            switchTiming?.mark("dormant.browser_attach.begin")
            MainActor.assumeIsolated {
                dormant.attachChromiumWindow(window)
            }
            switchTiming?.mark("dormant.browser_attach.end")
            AppLogInfo("🌐 [Chromium] Hosted session attached to its dormant session — spaceId=\(spaceId), presented=\(dormant.isPresented)")
            return
        }

        if SpaceSessionControllersManager.shared.findControllerWith(window: window) == nil {
            // Restored sibling-Space windows must be concealed for the whole
            // restore burst — Chromium's post-construction Show()/re-orders
            // (and the startup activation of the last-used profile's browser)
            // undo any eager orderOut, but alpha survives them all. The mark
            // must precede the controller init: slot registration runs inside
            // it, and the conceal has to land before the registration-time
            // tab-group enrollment (a transparent window selected into the
            // shared group frame blanks the visible active window). Revealed
            // by the slot's visibility reconcile once the burst settles.
            //
            // Which windows qualify is `SpaceWindowSlot.concealsRestoredSibling`;
            // having a slot at all is the call site's question and stays here.
            if let resolvedSlot,
               SpaceWindowSlot.concealsRestoredSibling(
                   isRestoredWindow: isRestoredWindow,
                   slotActiveSpaceId: resolvedSlot.activeSpaceId,
                   windowSpaceId: spaceId) {
                resolvedSlot.markRestoredSiblingForConcealment(spaceId: spaceId)
            }
            // The NSWindow callback is synchronous on Chromium's UI thread;
            // register its state before the first tab event can be delivered.
            // Hosted-window mode: a slot-bound window is never shown by
            // Chromium. Its session presents into the slot's shell, and the
            // Chromium NSWindow only carries the Browser's lifecycle.
            let hosted = SpaceSessionControllersManager.isHostedSession(
                browserType: browserType, slot: resolvedSlot)
            switchTiming?.mark("native_session.create.begin")
            let mainWindowController = MainActor.assumeIsolated {
                SpaceSessionControllersManager.shared.createWindowController(
                    window: hosted
                        ? resolvedSlot!.prepareShellForChromiumWindow(
                            windowId: Int(windowId), frame: window.frame,
                            waitsForShow: waitsForChromiumShow && !isRestoredWindow).window
                        : window,
                    windowId: Int(windowId),
                    browserType: browserType,
                    profileId: profileId,
                    spaceId: spaceId,
                    slot: resolvedSlot,
                    chromiumWindow: hosted ? window : nil
                )
            }
            switchTiming?.mark("native_session.create.end")
            mainWindowController.browserState.tabNameRestoreSourceWindowId = Int(restoredFromWindowId != 0 ? restoredFromWindowId : restoredClosedWindowId)
            // Do NOT force key/front for the active window here. Chromium's
            // BrowserWindow Show() / ShowInactive() runs post-ctor on this same
            // NSWindow and drives visibility + activation with the correct
            // intent; forcing makeKeyAndOrderFront here made
            // chrome.windows.create({focused:false}) come to the foreground (the
            // focused param was effectively ignored).
            if mainWindowController.isHosted {
                // Nothing to order out: the slot presented (or kept
                // concealed) the session at registration, and no Chromium
                // Show() will ever re-order a hosted window on screen.
                AppLogInfo("🌐 [Chromium] Hosted session registered — spaceId=\(spaceId), presented=\(mainWindowController.isPresented)")
            } else if browserType != .shadow {
                // A standalone Incognito window: adopted as its own NSWindow,
                // shown by Chromium. Restored windows are surfaced before the
                // deferred autosave tick in MainSplitViewController can run
                // (the main thread is busy replaying the session), so their
                // first visible frame would show the default sidebar width
                // and jump later. Adopt the persisted split position now,
                // ahead of any Show().
                if isRestoredWindow {
                    mainWindowController.mainSplitViewController
                        .adoptAutosavedSplitPositionNow()
                }
            } else {
                AppLogInfo("🌐 Shadow window controller initialized but hidden.")
            }
            AppLogInfo("🌐 [Chromium] ✅ Window controller created with browser access")
        }
    }

    var extensionChangedCallback: (([[AnyHashable : Any]], Int64) -> Void)? {
        return { extensions ,windowId in
            EventBus.shared.send(ExtensionEvent(browserId: windowId.intValue, action: .extensionChanged(info: extensions)))
        }
    }

    /// Hosted-window mode: Chromium asked to show or activate a hosted
    /// browser window. Present that window's Space in its slot instead.
    @objc func windowRequestedPresentation(_ windowId: Int64) {
        windowRequestedPresentation(windowId, activate: true)
    }

    @objc func windowRequestedPresentation(_ windowId: Int64, activate: Bool) {
        MainActor.assumeIsolated {
            SpaceManager.shared.presentHostedWindow(windowId: Int(windowId), activate: activate)
        }
    }

    /// Hosted-window mode: Chromium changed a hosted browser's fullscreen
    /// state; the shell presenting it follows.
    @objc func windowRequestedFullscreen(_ fullscreen: Bool, forWindowId windowId: Int64) {
        windowRequestedFullscreen(fullscreen, forWindowId: windowId, targetDisplayId: -1)
    }

    @objc func windowRequestedFullscreen(_ fullscreen: Bool, forWindowId windowId: Int64,
                                        targetDisplayId: Int64) {
        MainActor.assumeIsolated {
            guard let controller = SpaceSessionControllersManager.shared.controller(for: Int(windowId)) else {
                // No session follows this Browser: end Chromium's pending transition.
                SpaceSessionController.completeHostedFullscreenTransition(windowId: Int(windowId))
                return
            }
            controller.requestShellFullscreen(fullscreen, targetDisplayId: targetDisplayId)
        }
    }

    // Explicit @objc so the optional-protocol selectors are guaranteed visible
    // to the ObjC bridge's respondsToSelector: dispatch (matches the codebase's
    // tabRelationshipSnapshotChanged precedent).
    @objc func badgeInfoChanged(_ info: [AnyHashable : Any]) {
        let windowId = (info["windowId"] as? NSNumber)?.intValue ?? 0
        EventBus.shared.send(ExtensionEvent(browserId: windowId, action: .badgeChanged(info: info)))
    }

    @objc func actionIconChanged(_ info: [AnyHashable : Any]) {
        let windowId = (info["windowId"] as? NSNumber)?.intValue ?? 0
        EventBus.shared.send(ExtensionEvent(browserId: windowId, action: .iconChanged(info: info)))
    }

    /// Renderer crash page arrived for `tabId` in `windowId` (both pre-resolved
    /// by Chromium; the WebContents may be mid-teardown). Resolve the tab and
    /// install the crash state synchronously so show/hide stay ordered. Must be
    /// `@objc`: this is an optional protocol selector and Chromium gates the
    /// whole crash page on `respondsToSelector:` for it.
    @objc func showCrashPage(_ tabId: Int64, windowId: Int64, data: [AnyHashable : Any]) {
        // Runs on Chromium's UI/main thread today (= AppKit main = MainActor), but
        // that isn't type-enforced. Mirror tabWillBeRemove: assert and skip rather
        // than trap if it ever arrives off-main — a crash notification must never
        // take down the browser process.
        guard Thread.isMainThread else {
            assertionFailure("showCrashPage off the main thread; skipping crash page")
            return
        }
        MainActor.assumeIsolated {
            guard let windowController = SpaceSessionControllersManager.shared
                    .getAllWindows()
                    .first(where: { $0.windowId == Int(windowId) }),
                  let tab = windowController.browserState.resolveTab(Int(tabId)) else {
                // Cross-window drag can replay a crash before the destination
                // window's tab exists on the Mac side. Buffer it; the tab's
                // creation (BrowserState.handleNewTabFromChromium) drains it.
                pendingCrashBuffer[Int(tabId)] = CrashPageData(dictionary: data)
                return
            }
            tab.crashState = CrashPageData(dictionary: data)
        }
    }

    /// Remove and return a buffered crash payload for a tab that has now been
    /// created (cross-window drag). Returns nil if none was buffered.
    func drainPendingCrash(tabId: Int) -> CrashPageData? {
        pendingCrashBuffer.removeValue(forKey: tabId)
    }

    /// Renderer recovered (committed a non-crashed navigation). Clear the crash
    /// state for `tabId`. Optional selector → `@objc` required.
    @objc func hideCrashPage(_ tabId: Int64, windowId: Int64) {
        guard Thread.isMainThread else {
            assertionFailure("hideCrashPage off the main thread; skipping crash page teardown")
            return
        }
        MainActor.assumeIsolated {
            guard let windowController = SpaceSessionControllersManager.shared
                    .getAllWindows()
                    .first(where: { $0.windowId == Int(windowId) }),
                  let tab = windowController.browserState.resolveTab(Int(tabId)) else {
                // The crash may have been buffered before the tab existed (a
                // cross-window drag replays show before creation). Recovery can
                // arrive in that same pre-creation window — drop the stale
                // payload so the tab's later creation doesn't replay a crash the
                // renderer has already recovered from.
                pendingCrashBuffer.removeValue(forKey: Int(tabId))
                return
            }
            // Clear immediately by design: a renderer crash is rare, and a brief
            // blank while the page reloads usefully signals the reload is under
            // way (rather than looking stuck). No fixed delay / staleness token
            // is needed — bridge show/hide run synchronously and in order here.
            tab.crashState = nil
        }
    }

    /// Builds the (Tab, NativeTabCreationContext) pair from one
    /// newTabCreatedWithInfo-shaped bridge payload. Shared by the per-tab
    /// path and the restored-window snapshot path (T3A) so the two parses
    /// cannot drift.
    private func makeTab(fromBridgeInfo tabInfo: [AnyHashable: Any],
                         windowId: Int64) -> (tab: Tab, context: NativeTabCreationContext) {
        let title = tabInfo["title"] as? String
        let url = tabInfo["url"] as? String
        let index = tabInfo["index"] as? Int ?? -1
        let id = tabInfo["id"] as? Int ?? -1
        let active = false // fixeme
        let contentView = tabInfo["webView"] as? (WebContentWrapper & NSObject)
        let customGuid = tabInfo["customGuid"] as? String
        // Empty string means "not in any group" — the chromium bridge always
        // emits the key, so absence (older builds) is also treated as none.
        let groupIdHex = (tabInfo["groupIdHex"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let tab = Tab(guid: id,
                      url: url,
                      isActive: active,
                      index: index,
                      title: title,
                      webContentView: contentView,
                      customGuid: customGuid,
                      windowId: Int(windowId))
        // Apply the group affiliation eagerly so the sidebar's first render
        // after `tabs.append(tab)` already places this tab inside its group —
        // no transient "outside group" frame for tabs created directly into a
        // group (createTabInGroup, future regroup-on-create flows).
        if let groupIdHex {
            if let state = SpaceSessionControllersManager.shared.getBrowserState(for: Int(windowId)) {
                state.updateTabGroupMembership(tab, token: groupIdHex)
            } else {
                tab.updateGroupMembership(groupIdHex)
            }
        }
        let creationPayload = (tabInfo["creationContext"] as? [AnyHashable: Any]) ?? tabInfo
        let creationContext = NativeTabCreationContext(dictionary: creationPayload)
        return (tab, creationContext)
    }

    func newTabCreated(withInfo tabInfo: [AnyHashable : Any], windowId: Int64) {
        AppLogDebug("[Tab] newTabCreated: \(tabInfo) \n, windowId: \(windowId)")

        let (tab, creationContext) = makeTab(fromBridgeInfo: tabInfo, windowId: windowId)
        let id = tab.guid
        AppLogDebug(
            "[NativeTab] mac newTabCreated " +
            "tabId=\(id) windowId=\(windowId) index=\(tab.index) " +
            "creationPayload=\((tabInfo["creationContext"] as? [AnyHashable: Any]) ?? tabInfo)"
        )
        EventBus.shared.send(TabEvent(browserId: windowId.intValue,
                                      action: .newTabWithContext(tab, context: creationContext)))
    }

    /// One restored saved window delivered as a single batch (T3A snapshot
    /// seam). Called SYNCHRONOUSLY inside Chromium's session-restore replay
    /// stack: parse, take ownership, and apply the whole payload here in the
    /// same stack (T3B) — data and the visible list no longer wait for the
    /// main queue to drain the replay backlog. Deliberately NOT routed
    /// through EventBus (T3A amendment decision 1). The applied transaction
    /// must never call back into Chromium synchronously; BrowserState's
    /// snapshot transaction owns that discipline.
    @objc(restoredWindowSnapshot:windowId:)
    func restoredWindowSnapshot(_ snapshot: [String: Any], windowId: Int64) {
        let tabInfos = (snapshot["tabs"] as? [[AnyHashable: Any]]) ?? []
        let items = tabInfos.map { makeTab(fromBridgeInfo: $0, windowId: windowId) }
        let activeTabId = snapshot["activeTabId"] as? Int
        let splitActions = parseSplitActions(fromBridgeEvents: snapshot["splitEvents"])

        guard !items.isEmpty else { return }


        let payload = BrowserState.RestoredWindowSnapshot(tabs: items,
                                                          activeTabId: activeTabId,
                                                          splitActions: splitActions)
        // T3B: apply synchronously in this replay stack. The bridge calls on
        // Chromium's UI thread (= AppKit main = MainActor) but that isn't
        // type-enforced — mirror showCrashPage's assert-and-degrade rather
        // than trap; the off-main fallback keeps the T3A task shape so the
        // window still restores.
        guard Thread.isMainThread else {
            assertionFailure("restoredWindowSnapshot off the main thread; deferring application")
            Task { @MainActor in
                self.applyRestoredWindowSnapshot(payload, windowId: windowId)
            }
            return
        }
        MainActor.assumeIsolated {
            applyRestoredWindowSnapshot(payload, windowId: windowId)
        }
    }

    @MainActor
    private func applyRestoredWindowSnapshot(_ payload: BrowserState.RestoredWindowSnapshot,
                                             windowId: Int64) {
        guard let browserState = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId.intValue) else {
            // Same drop semantics as a queued event whose window closed:
            // the payload (tabs + wrappers) is simply released.
            AppLogWarn("Window not found for restored snapshot: \(windowId)")
            return
        }
        browserState.handleRestoredWindowSnapshot(payload)
    }

    /// Decodes the snapshot's buffered split events into the same actions
    /// the individual split delegate methods would have sent.
    private func parseSplitActions(fromBridgeEvents events: Any?) -> [SplitEvent.SplitAction] {
        guard let dicts = events as? [[AnyHashable: Any]], !dicts.isEmpty else { return [] }
        return dicts.compactMap { event in
            guard let type = event["type"] as? String,
                  let splitId = event["splitId"] as? String else {
                AppLogError("[Split] restored snapshot: malformed split event \(event)")
                return nil
            }
            switch type {
            case "created":
                guard let panes = Self.splitPanes(event["tabIds"]),
                      let layout = event["layout"] as? String,
                      let ratio = Self.splitRatio(event["fractions"]) else {
                    AppLogError("[Split] restored snapshot: malformed created event \(event)")
                    return nil
                }
                return .created(splitId: splitId,
                                primaryTabId: panes.primary,
                                secondaryTabId: panes.secondary,
                                layout: parseBridgeLayout(layout),
                                ratio: ratio)
            case "visualsChanged":
                guard let layout = event["layout"] as? String,
                      let ratio = Self.splitRatio(event["fractions"]) else {
                    AppLogError("[Split] restored snapshot: malformed visualsChanged event \(event)")
                    return nil
                }
                return .visualsChanged(splitId: splitId,
                                       layout: parseBridgeLayout(layout),
                                       ratio: ratio)
            case "contentsChanged":
                guard let panes = Self.splitPanes(event["tabIds"]) else {
                    AppLogError("[Split] restored snapshot: malformed contentsChanged event \(event)")
                    return nil
                }
                return .contentsChanged(splitId: splitId,
                                        primaryTabId: panes.primary,
                                        secondaryTabId: panes.secondary)
            case "removed":
                return .removed(splitId: splitId)
            default:
                AppLogError("[Split] restored snapshot: unknown split event type \(type)")
                return nil
            }
        }
    }

    @objc(tabRelationshipSnapshotChanged:windowId:version:)
    func tabRelationshipSnapshotChanged(_ snapshotInfo: [AnyHashable : Any], windowId: Int64, version: Int64) {
        AppLogDebug("[Tab] tabRelationshipSnapshotChanged: \(snapshotInfo), windowId: \(windowId)")
        let openerByTabId = (snapshotInfo["openerByTabId"] as? [AnyHashable: Any]) ?? snapshotInfo
        let resetOnActiveChangeTabIds = (snapshotInfo["resetOnActiveChangeTabIds"] as? [Any]) ?? []
        AppLogDebug(
            "[NativeTab] mac relationshipSnapshot " +
            "windowId=\(windowId) version=\(version) " +
            "openerByTabId=\(openerByTabId) " +
            "resetOnActiveChangeTabIds=\(resetOnActiveChangeTabIds)"
        )
        guard let snapshot = NativeTabRelationshipSnapshot(
            dictionary: [
                "windowId": windowId,
                "version": version,
                "openerByTabId": openerByTabId,
                "resetOnActiveChangeTabIds": resetOnActiveChangeTabIds,
            ],
            fallbackWindowId: windowId.intValue
        ) else {
            AppLogWarn("[Tab] Failed to parse relationship snapshot for windowId: \(windowId)")
            return
        }
        EventBus.shared.send(
            TabEvent(
                browserId: windowId.intValue,
                action: .updateTabRelationships(snapshot)
            )
        )
    }

    func tabWillBeRemove(_ tabId: Int64, windowId: Int64) {
        AppLogDebug("tabWillBeRemove: \(tabId)")
        // Detach the closing tab's native view from Peek or Reader SYNCHRONOUSLY,
        // before the async EventBus close dispatch. This bridge callback runs on
        // the UI/main thread inside Chromium's synchronous close turn while the
        // WebContents is still alive; the EventBus close (Task { @MainActor }) runs
        // only AFTER Chromium has destroyed it. MainActor.assumeIsolated mirrors
        // windowDidEnterPlaceholderMode's synchronous-detach pattern.
        // The contract above holds today (BrowserThread::UI = the AppKit main thread =
        // MainActor), but it isn't type-enforced. Assert it; if Chromium ever delivers
        // this off-main, skip the detach rather than trapping — the EventBus close
        // below must still fire.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                // nil window (already torn down) → nothing to detach.
                let controller = SpaceSessionControllersManager.shared
                    .controller(for: windowId.intValue)
                // If the closing tab is hosted by the Peek panel, detach its
                // native view now, while the WebContents is still alive — the
                // async EventBus close below runs after Chromium destroyed it.
                controller?.peekPanelControllerIfLoaded?
                    .detachContentIfHosting(tabId: tabId.intValue)
                // Same rule for a closing reader-overlay surface tab.
                controller?.readerPanelControllersIfLoaded
                    .forEach { $0.detachContentIfHosting(tabId: tabId.intValue) }
                // Before the async close below, while the Mac list still has
                // every tab Chromium is closing in this turn.
                controller?.browserState.noteTabWillBeRemoved(tabId: tabId.intValue)
            }
        } else {
            assertionFailure("tabWillBeRemove off the main thread; skipping the synchronous detach")
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AgentUserSpaceDriveRegistry.shared.tabWasRemoved(tabId: tabId.intValue)
            }
        }
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .closeTab(tabId.intValue)))
    }

    func getWebContentSuperView() -> NSView? {
        return nil
    }

    func tabTitleUpdated(_ tabId: Int64, title: String, windowId: Int64) {
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .updateTabTitle(tabId: tabId.intValue, newTitle: title)))
    }

    @objc func initApplication() {
        enum _Store {
            static var app: AppController?
        }
        let controller = AppController()
        _Store.app = controller
        NSApp = PhiApplication.shared
        NSApp.delegate = controller
        controller.startObservingMainMenu()

    }

    @MainActor
    func runQuitConfirmAlert() -> Bool {
        // A key browser window hosts the confirmation as its sheet. Any other
        // key window (picture in picture, Task Manager, a tool panel) would
        // only squeeze it, so the alert then stands on its own instead.
        let keyWindow = NSApp.keyWindow
        let hostWindow = keyWindow?.windowController is SpaceSessionController
            ? keyWindow
            : nil
        return PhiAlert.runQuitAlert(relativeTo: hostWindow)
    }

    func activeTabChanged(_ tabId: Int64, index: Int32, windowId: Int64) {
        AppLogDebug("[Tab]: activeTabChanged: \(tabId), atIndex:\(index), window:\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                         action: .focusTabWithTabId(tabId.intValue)))
    }

    func tabIndicesUpdated(_ tabIndices: [NSNumber : NSNumber], windowId: Int64) {
        AppLogDebug("[Tab] tabIndicesUpdated: \(tabIndices), window:\(windowId)")
        let map: [Int: Int] = tabIndices.reduce(into: [:]) { partialResult, element in
            partialResult[element.key.intValue] = element.value.intValue
        }
        let targetWindowId: Int?
        if windowId != 0 {
            targetWindowId = windowId.intValue
        } else {
            // Chromium could not resolve the owning window (or the embedded
            // framework predates it sending one). Routing a full-strip map to
            // the active window is a guess: it silently drops the correction
            // for whichever window actually moved, so make it visible.
            targetWindowId = SpaceSessionControllersManager.shared.activeWindowController?.windowId
            AppLogWarn(
                "[NativeTab] tabIndices arrived without a windowId; " +
                "falling back to the active window \(targetWindowId.map(String.init) ?? "nil")"
            )
        }
        guard let targetWindowId else {
            return
        }
        EventBus.shared
            .send(TabEvent(browserId: targetWindowId,
                         action: .updateTabIndex(map)))
    }

    // =========================================================================
    // DevTools embedding
    // =========================================================================

    /// Called by Chromium when DevTools has attached (docked) to a tab.
    func devToolsDidAttach(toTab tabId: Int64, windowId: Int64, devToolsView: NSView) {
        guard let windowController = SpaceSessionControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleDevToolsDidAttach(tabId: Int(tabId), devToolsView: devToolsView)
    }

    /// Called by Chromium when DevTools has detached from a tab (closed or undocked).
    func devToolsDidDetach(fromTab tabId: Int64, windowId: Int64) {
        guard let windowController = SpaceSessionControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleDevToolsDidDetach(tabId: Int(tabId))
    }

    /// Called by Chromium when the inspected page bounds change.
    func updateInspectedPageBounds(_ bounds: CGRect, forTabId tabId: Int64, windowId: Int64, hideInspectedContents hide: Bool) {
        guard let windowController = SpaceSessionControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleUpdateInspectedPageBounds(tabId: Int(tabId), bounds: bounds, hide: hide)
    }

    // =========================================================================
    // Tab first paint
    // =========================================================================

    /// Required bridge callback; native page containers mount without waiting for first paint.
    func tabReady(toDisplay tabId: Int64, windowId: Int64) {}

    // =========================================================================
    // Content fullscreen (HTML5 requestFullscreen)
    // =========================================================================

    /// Called when a tab enters or exits HTML5 content fullscreen.
    /// Routed through EventBus to the owning BrowserState, which drives the
    /// re-parent of that tab's hostView to cover the window.
    func tabContentFullscreenChanged(_ tabId: Int64,
                                     windowId: Int64,
                                     isFullscreen: Bool) {
        AppLogDebug("[Fullscreen] tabContentFullscreenChanged: tabId=\(tabId), windowId=\(windowId), isFullscreen=\(isFullscreen)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .tabContentFullscreenChanged(
                               tabId: tabId.intValue,
                               isFullscreen: isFullscreen)))
    }

    // =========================================================================
    // Placeholder mode (last-tab close → chrome://dino shell)
    //
    // Mirrors the Chromium-side bridge in
    // chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h.
    // The synchronous detach contract (spec §9.1) requires the BrowserState
    // state flip + NSView detach to complete BEFORE returning to Chromium,
    // hence MainActor.assumeIsolated rather than Task { @MainActor in ... }.
    // =========================================================================

    func windowDidEnterPlaceholderMode(_ windowId: Int64,
                                       placeholderView wrapper: any WebContentWrapper) {
        AppLogInfo("🦖 [Coordinator] enterPlaceholderMode windowId=\(windowId)")
        guard let windowController = SpaceSessionControllersManager.shared
                .getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            AppLogWarn("🦖 [Coordinator] no controller for windowId=\(windowId)")
            return
        }
        // Placeholder mode means the last-tab close did NOT close the window,
        // so the tab-driven-close marker `Tab.close()` armed for this Space
        // predicts an auto-close that will never happen. Cancel it here —
        // before the cast below, which can fail and would otherwise leave a
        // live marker to misclassify the user's next genuine close of this
        // window as a hand-off to a sibling Space.
        windowController.slot?.cancelTabDrivenClose(for: windowController.spaceId)
        guard let nsWrapper = wrapper as? (WebContentWrapper & NSObject) else {
            AppLogWarn("🦖 [Coordinator] wrapper cast failed")
            return
        }
        // Synchronous (NOT Task { @MainActor in ... }) so state flips before
        // returning to Chromium.
        MainActor.assumeIsolated {
            windowController.browserState.enterPlaceholderMode(wrapper: nsWrapper)
        }
    }

    func windowDidExitPlaceholderMode(_ windowId: Int64) {
        AppLogInfo("🦖 [Coordinator] exitPlaceholderMode windowId=\(windowId)")
        guard let windowController = SpaceSessionControllersManager.shared
                .getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            AppLogWarn("🦖 [Coordinator] no controller for windowId=\(windowId)")
            return
        }
        MainActor.assumeIsolated {
            windowController.browserState.exitPlaceholderMode()
        }
    }

    // =========================================================================
    // Extension side panel (Chromium → Mac)
    //
    // Mirrors the Chromium-side contract in PhiChromiumBridgeHeader.h:
    // non-nil info+wrapper = adopt the panel NSView (open / content change),
    // nil = closed. The close leg shares placeholder mode's synchronous
    // detach contract, hence MainActor.assumeIsolated rather than an async
    // hop — Chromium destroys the outgoing panel view right after this
    // bridge callback returns.
    // =========================================================================

    func extensionSidePanelChanged(_ windowId: Int64,
                                   info: [String: Any]?,
                                   panelView wrapper: (any WebContentWrapper)?) {
        guard let windowController = SpaceSessionControllersManager.shared
                .getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            // Normal during window teardown: Chromium pushes the close from
            // the browser's pre-destruction sweep after the Mac side already
            // dropped the window controller.
            AppLogInfo("[ExtSidePanel] [Coordinator] no controller for windowId=\(windowId) (info=\(info == nil ? "nil" : "set"))")
            return
        }

        let panelState: BrowserState.ExtensionSidePanelState?
        if let info, let wrapper {
            guard let nsWrapper = wrapper as? (WebContentWrapper & NSObject) else {
                AppLogWarn("[ExtSidePanel] [Coordinator] wrapper cast failed windowId=\(windowId)")
                return
            }
            panelState = BrowserState.ExtensionSidePanelState(
                extensionId: info["extensionId"] as? String ?? "",
                displayName: info["displayName"] as? String ?? "",
                iconPNG: info["iconPNG"] as? Data,
                wrapper: nsWrapper
            )
        } else {
            panelState = nil
        }

        // Synchronous (NOT Task { @MainActor in ... }) so the outgoing NSView
        // is out of the hierarchy before returning to Chromium.
        MainActor.assumeIsolated {
            windowController.browserState.updateExtensionSidePanel(panelState)
        }
    }

    // =========================================================================
    // Content surface (Chromium → Mac)
    //
    // Same addressing and synchronous hop as the extension side panel: sent
    // right after mainBrowserWindowCreated for the same windowId, once per
    // Space instance and only while PhiContentSurface is on.
    // =========================================================================

    func contentSurfaceCreated(_ windowId: Int64, hostingView: NSView) {
        let manager = SpaceSessionControllersManager.shared
        guard let windowController = manager.getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            AppLogWarn("[ContentSurface] [Coordinator] no controller for windowId=\(windowId)")
            return
        }
        MainActor.assumeIsolated {
            windowController.browserState.adoptContentSurface(hostingView)
        }
    }

    // =========================================================================
    // Tab groups (Chromium → Mac)
    //
    // Forwards all 5 bridge callbacks through EventBus, matching the
    // dispatch shape used by TabEvent. The actual state
    // updates happen in `BrowserState.handleTabGroup*`.
    // =========================================================================

    private func decodeGroupColor(_ wire: String, context: String) -> GroupColor {
        if let color = GroupColor(rawValue: wire) {
            return color
        }
        AppLogWarn(
            "[TAB_GROUPS] unknown wire color \"\(wire)\" in \(context); falling back to .grey"
        )
        return .grey
    }

    private func dispatchGroupAction(_ action: TabGroupEvent.TabGroupAction,
                                      windowId: Int64) {
        EventBus.shared.send(TabGroupEvent(browserId: windowId.intValue, action: action))
    }

    func tabGroupCreated(_ windowId: Int64,
                         tokenHex: String,
                         title: String,
                         color: String,
                         isCollapsed: Bool,
                         initialTabIds: [NSNumber]) {
        let decodedColor = decodeGroupColor(color, context: "tabGroupCreated token=\(tokenHex)")
        let tabIds = initialTabIds.map { $0.intValue }
        dispatchGroupAction(.groupCreated(token: tokenHex,
                                           title: title,
                                           color: decodedColor,
                                           isCollapsed: isCollapsed,
                                           initialTabIds: tabIds),
                            windowId: windowId)
    }

    func tabGroupVisualDataChanged(_ windowId: Int64,
                                    tokenHex: String,
                                    title: String,
                                    color: String,
                                    isCollapsed: Bool) {
        let decodedColor = decodeGroupColor(
            color,
            context: "tabGroupVisualDataChanged token=\(tokenHex)")
        dispatchGroupAction(.groupVisualDataChanged(token: tokenHex,
                                                     title: title,
                                                     color: decodedColor,
                                                     isCollapsed: isCollapsed),
                            windowId: windowId)
    }

    func tabGroupClosed(_ windowId: Int64, tokenHex: String) {
        dispatchGroupAction(.groupClosed(token: tokenHex), windowId: windowId)
    }

    func tabJoinedGroup(_ windowId: Int64, tabId: Int64, tokenHex: String) {
        dispatchGroupAction(.tabJoinedGroup(tabId: tabId.intValue, token: tokenHex),
                            windowId: windowId)
    }

    func tabLeftGroup(_ windowId: Int64, tabId: Int64, tokenHex: String) {
        dispatchGroupAction(.tabLeftGroup(tabId: tabId.intValue, token: tokenHex),
                            windowId: windowId)
    }

    @objc(showToast:windowId:toastId:message:shareURL:duration:)
    func showToast(_ tabId: Int64, windowId: Int64, toastId: String,
                   message: String, shareURL: String, duration: TimeInterval) -> Bool {
        // The synchronous result lets Chromium fall back when no native host exists.
        guard Thread.isMainThread, !message.isEmpty,
              let controller = SpaceSessionControllersManager.shared
                .controller(for: Int(windowId)) else { return false }
        let id: UUID
        if toastId.isEmpty {
            id = UUID()
        } else if let parsedID = UUID(uuidString: toastId) {
            id = parsedID
        } else {
            return false
        }
        let shareURLs = shareURL.isEmpty ? [] : URL(string: shareURL).map { [$0] } ?? []
        if controller.browserState.peekState.peekTab(withId: Int(tabId)) != nil {
            return controller.peekPanelControllerIfLoaded?.showToast(
                id: id, message: message, shareURLs: shareURLs,
                duration: duration, tabId: Int(tabId)) ?? false
        }
        return OverlayToastCenter.shared.show(
            title: message, duration: duration, placement: .topTrailing,
            shareURLs: shareURLs, in: .windowId(Int(windowId)), id: id) != nil
    }

    @objc(dismissToast:windowId:)
    func dismissToast(_ toastId: String, windowId: Int64) {
        guard Thread.isMainThread, let id = UUID(uuidString: toastId) else { return }
        OverlayToastCenter.shared.dismiss(id: id)
        SpaceSessionControllersManager.shared.controller(for: Int(windowId))?
            .peekPanelControllerIfLoaded?.dismissToast(id: id)
    }

    @objc(linkToHighlightCopied:windowId:url:isShortLink:)
    func link(toHighlightCopied tabId: Int64, windowId: Int64, url: String, isShortLink: Bool) {
        guard !url.isEmpty, let copiedURL = URL(string: url) else { return }
        DispatchQueue.main.async {
            guard let controller = SpaceSessionControllersManager.shared
                .controller(for: Int(windowId)) else { return }
            // Chromium already wrote the clipboard, including long-link fallback.
            if controller.browserState.peekState.peekTab(withId: Int(tabId)) != nil {
                controller.peekPanelControllerIfLoaded?
                    .showHighlightLinkCopyConfirmation(url: copiedURL, tabId: Int(tabId))
            } else {
                OverlayToastCenter.shared.showHighlightLinkCopyConfirmation(url: copiedURL, in: controller.browserState)
            }
        }

    }

    func targetURLChanged(_ tabId: Int64, windowId: Int64, url: String) {
        guard let windowController = SpaceSessionControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else {
            return
        }

        DispatchQueue.main.async {
            windowController.browserState.updateTargetURL(url, from: Int(tabId))
        }
    }
}

extension PhiChromiumCoordinator {
    @MainActor
    func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(commandId, window: window)
    }

    @MainActor
    func commandDispatch(_ sender: Any, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(sender, window: window)
    }

    @MainActor
    func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        return CommandDispatcher.handleKeyEquivalent(event, window: window)
    }
}

extension PhiChromiumCoordinator {
    func extensionsLoaded(_ extensions: [[AnyHashable : Any]]) {

    }

    func extensionTriggered(_ extensionId: String) {

    }

    func extensionPinned(_ extensionId: String) {

    }

    func extensionUnpinned(_ extensionId: String) {

    }

    func extensionMoved(_ extensionId: String, to newIndex: Int32) {

    }

    func extensionInstallResult(_ extensionId: String, status: String) {
    }

}

extension PhiChromiumCoordinator {
    func omniboxResultChanged(_ matches: [[AnyHashable : Any]], originalInput: String, windowId: Int64) {
        guard let infos = matches as? [[String: Any]] else {
            return
        }
        EventBus.shared.send(OmniEvent(browserId: Int(windowId),
                                       action: .searchSuggestionResultChanged(suggestions: infos,
                                                                              originalInput: originalInput)))
    }
}

// MARK: - Split view notifications

extension PhiChromiumCoordinator {
    /// The bridge reports a split's panes as lists in slot order (two to
    /// four). Mist only ever creates two-pane splits: slot 0 is the primary
    /// pane, and its share of the split axis is the ratio.
    static func splitPanes(_ raw: Any?) -> (primary: Int, secondary: Int)? {
        guard let ids = raw as? [NSNumber], ids.count == 2 else { return nil }
        return (ids[0].intValue, ids[1].intValue)
    }

    static func splitRatio(_ raw: Any?) -> Double? {
        guard let shares = raw as? [NSNumber], shares.count == 2 else { return nil }
        return shares[0].doubleValue
    }

    func splitCreated(_ splitId: String,
                      tabIds: [NSNumber],
                      layout: String,
                      fractions: [NSNumber],
                      windowId: Int64) {
        AppLogDebug("[Split] created: id=\(splitId) tabs=\(tabIds) layout=\(layout) fractions=\(fractions) window=\(windowId)")
        guard let panes = Self.splitPanes(tabIds), let ratio = Self.splitRatio(fractions) else {
            AppLogError("[Split] created: not a two-pane split, ignored: id=\(splitId) tabs=\(tabIds) fractions=\(fractions)")
            return
        }
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .created(splitId: splitId,
                             primaryTabId: panes.primary,
                             secondaryTabId: panes.secondary,
                             layout: parseBridgeLayout(layout),
                             ratio: ratio)))
    }

    func splitVisualsChanged(_ splitId: String,
                             layout: String,
                             fractions: [NSNumber],
                             windowId: Int64) {
        guard let ratio = Self.splitRatio(fractions) else {
            AppLogError("[Split] visualsChanged: not a two-pane split, ignored: id=\(splitId) fractions=\(fractions)")
            return
        }
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .visualsChanged(splitId: splitId,
                                    layout: parseBridgeLayout(layout),
                                    ratio: ratio)))
    }

    private func parseBridgeLayout(_ raw: String) -> SplitLayout {
        if let layout = SplitLayout(bridgeString: raw) { return layout }
        AppLogError("[Split] unknown bridge layout string '\(raw)' — defaulting to vertical")
        return .vertical
    }

    func splitContentsChanged(_ splitId: String,
                              tabIds: [NSNumber],
                              windowId: Int64) {
        AppLogDebug("[Split] contentsChanged: id=\(splitId) tabs=\(tabIds) window=\(windowId)")
        guard let panes = Self.splitPanes(tabIds) else {
            AppLogError("[Split] contentsChanged: not a two-pane split, ignored: id=\(splitId) tabs=\(tabIds)")
            return
        }
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .contentsChanged(splitId: splitId,
                                     primaryTabId: panes.primary,
                                     secondaryTabId: panes.secondary)))
    }

    func splitRemoved(_ splitId: String, windowId: Int64) {
        AppLogDebug("[Split] removed: id=\(splitId) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .removed(splitId: splitId)))
    }

    func openReaderView(forTabId tabId: Int64, windowId: Int64) {
        AppLogInfo("📖 [Reader] context menu asked for Reader View: " +
                   "tab=\(tabId) window=\(windowId)")
        EventBus.shared.send(TabEvent(
            browserId: windowId.intValue,
            action: .openReaderView(tabId: tabId.intValue)))
    }

    func openLinkAsSplitPartner(withPartnerTabId partnerTabId: Int64,
                                url: String,
                                windowId: Int64) {
        AppLogDebug("[Split] openLinkAsSplitPartner: partner=\(partnerTabId) url=\(url) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .openLinkAsSplitPartner(partnerTabId: partnerTabId.intValue,
                                            url: url)))
    }

    func openLinkAsPeek(withSourceTabId sourceTabId: Int64,
                        url: String,
                        windowId: Int64) {
        AppLogDebug("👀 [Peek] openLinkAsPeek: source=\(sourceTabId) url=\(url) window=\(windowId)")
        EventBus.shared.send(TabEvent(
            browserId: windowId.intValue,
            action: .openLinkAsPeek(sourceTabId: sourceTabId.intValue, url: url)))
    }

    // Synchronous query from Chromium's context-menu build: "Open Link in
    // Peek View" is offered only while the Peek feature toggle (Settings ›
    // Advanced) is on and a sidebar layout is active — Peek is a
    // sidebar-layout surface.
    func isPeekLinkSurfaceEnabled() -> Bool {
        PhiPreferences.GeneralSettings.peekViewEnabled.loadValue()
            && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
    }

    // Synchronous query from Chromium as it creates the new foreground tab of
    // a link: whether that tab opens in the Peek panel on its own. Chromium
    // keeps the tab's first load in its window when it does.
    func opensAutoPeekForLink(fromTabId sourceTabId: Int64,
                              url: String,
                              windowId: Int64) -> Bool {
        SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId.intValue)?
            .opensAutoPeek(forLinkFrom: sourceTabId.intValue, urlString: url) ?? false
    }

    // Content blocking of a profile published a new rule generation or
    // changed status; the Privacy pane's facade re-reads on this.
    func contentBlockingStatusChanged(_ profileId: String) {
        NotificationCenter.default.post(name: .contentBlockingStatusChanged, object: profileId)
    }
}

extension Int64 {
    var intValue: Int { Int(self) }
}

extension Int {
    var int64Value: Int64 { Int64(self) }
}
