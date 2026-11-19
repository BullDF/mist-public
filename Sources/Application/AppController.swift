// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import AuthenticationServices
import SwiftData
import CocoaLumberjackSwift
import Kingfisher
import WebKit
import Settings

@objc class AppController: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!
    @objc static private(set)var shared: AppController!

    var settingsWindowController: SettingsWindowController?
    /// The application the settings window took the foreground from, so
    /// closing the window can hand activation back to it.
    var settingsActivationSource: NSRunningApplication?
    var menuObservation: NSKeyValueObservation?
    var removedMenuItemsObservation: NSObjectProtocol?
    /// Refreshes the main menu when the layout mode changes, so the Tab menu's
    /// layout-dependent New Tab title follows it; a layout change swaps no
    /// menu, so `menuObservation` does not see it.
    var layoutModeMenuObservation: NSObjectProtocol?
    /// Layout mode last seen by `layoutModeMenuObservation`; the menu is
    /// refreshed only when this actually changes.
    var lastMenuLayoutMode: LayoutMode?
    var isMainMenuRefreshScheduled = false
    /// Polls cold-launch readiness without forwarding before the first regular
    /// Chromium window can safely own or precede the external open.
    private static let coldOpenURLForwardDelay: TimeInterval = 0.5
    /// Upper bound on cold-open forward deferrals (attempts × delay ≈ 4s).
    private static let coldOpenURLForwardMaxAttempts = 8
    private var coldOpenURLForwardWorkItem: DispatchWorkItem?
    private var coldOpenURLForwardAttempts = 0
    private var pendingColdOpenForwardURLs: [URL] = []
    private var screenshotExportTerminationTask: Task<Void, Never>?
    private var mailTerminationTask: Task<Void, Never>?
    /// Cached in `applicationWillFinishLaunching`; weak — owned by `ChromiumLauncher`, not AppController.
    private weak var chromiumBridge: (any PhiChromiumBridgeProtocol)?
    override init() {
        super.init()
        Self.shared = self
        // Opt out of AppKit's window-state restoration. macOS otherwise
        // re-enters native fullscreen on a previously-fullscreen window a few
        // seconds into the next launch (its own Spaces/saved-state restoration),
        // independent of Chromium's restored show-state and the window's
        // `isRestorable` — leaving restored windows fullscreen (and the reconcile
        // then orphans empty fullscreen Spaces). Chromium owns tab/session
        // restore and Phi owns window frame/Space affinity, so AppKit's
        // window-state restoration is redundant here; turning it off makes
        // restored windows come back as normal windows. Set in `init` (before
        // `applicationWillFinishLaunching`) so it lands before AppKit reads it.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChromiumLauncher.sharedInstance().bridge?.applicationDidFinishLaunching(notification)
        MistBuildFlavor.applyApplicationIcon()
        MistSyncEngine.shared.start()
        MistAppPlaceholders.shared.start()
        MistMailService.shared.start()
        SlackAgentConnection.shared.start()
        SlackAgentBridge.shared.start()
        SlackAgentAccess.installChatHooks()
        DrifterCodexPicks.preload()
        ChromiumLauncher.sharedInstance().bridge?.setMetricsReportingEnabled(false) { effectiveEnabled in
            if effectiveEnabled {
                AppLogWarn("[OSS] Failed to disable Chromium metrics reporting")
            }
        }

        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self

        setupKinfisherCache()

        DefaultExtensionManifestWriter.start()

        // The agent CDP socket listens for the whole app session, whether or
        // not agent browser control is switched on: Mist's own Browser Agent
        // connects through it either way, and other agents are refused while
        // it is off (see AgentCDPListener).
        AgentCDPListener.shared.start()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(phiWillTryToTerminateApplicationNotification(_:)),
                                               name: Notification.Name("PhiWillTryToTerminateApplicationNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(phiDidCancelTerminateApplicationNotification(_:)),
                                               name: Notification.Name("PhiDidCancelTerminateApplicationNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshSpacesMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(spaceListDidChange),
                                               name: .spaceListDidChange,
                                               object: nil)
        // The Spaces menu lists the focused window's own Spaces (an agent
        // Space is listed only by the window hosting it), so its position →
        // Space mapping has to follow the focused window, not just the list.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(spaceListDidChange),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshBookmarksMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        bindChromiumBridgeIfNeeded()

        // Register defaults before any settings are read.
        UserDefaultsRegistration.registerDefaults()
        // The framework still has Kiosk routing; Mist keeps it off.
        chromiumBridge?.setOpenExternalLinksInKioskEnabled(false)
        chromiumBridge?.setOpenKioskOnCommandOptionClickEnabled(false)

        setupLogging()
        AppLogInfo("------------------------------  Starting: \(Self.makeClientString())  ------------------------------")

        // The startup takeover for the user-data removal mechanism runs in
        // main() (UserDataRemovalBootstrap), before Chromium reads any state.

        // Warm the Space registry before Chromium's cold-start replay can ask
        // it anything. That replay queries `coldStartEagerWindowIds` from its
        // own stack, and the singleton's first touch is what loads the restore
        // snapshot and seeds the Space list; doing it here means the answer is
        // read from memory instead of built inside the replay. A launch that
        // has no account bound yet warms nothing and the pull answers nil,
        // which is the full replay this app has always done.
        MainActor.assumeIsolated { _ = SpaceManager.shared }

        chromiumBridge?.applicationWillFinishLaunching(notification)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coldOpenURLForwardWorkItem?.cancel()
        coldOpenURLForwardWorkItem = nil
        AppLogInfo("-------applicationWillTerminate----")
        AgentCDPListener.shared.stop()
        MistMailService.shared.applicationWillTerminate()
        if let chromiumBridge {
            chromiumBridge.applicationWillTerminate(notification)
        } else {
            AppLogWarn("[AppController] applicationWillTerminate: chromium bridge not cached; using launcher fallback")
            ChromiumLauncher.sharedInstance().bridge?.applicationWillTerminate(notification)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogInfo("-----------------------------  Quitting: \(Self.makeClientString()) ------------------------------")
        // Note: on Cmd+Q this fires AFTER Chromium's window teardown; the restore
        // snapshot is frozen earlier, in phiWillTryToTerminateApplicationNotification.
        // Re-assert here as a backstop for any quit path that reaches this hook.
        SpaceManager.shared.markTerminating()
        TabNameStore.shared.freeze()
        // Confirmed writes can start while Chromium's own quit confirmation is up.
        // Recheck both export owners after browser teardown, without a late discard veto.
        if MistMailService.shared.needsTerminationFlush || Self.inFlightBookmarkExportWrites > 0 || sender.windows.contains(where: {
            ($0.windowController as? ScreenshotEditorWindowController)?.hasConfirmedExport == true
        }) {
            Self.bookmarkExportTerminationPending = true
            MainActor.assumeIsolated { resumeTerminationAfterConfirmedExports() }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Uses the existing export termination gate; neither export owner may resume Quit early.
    @MainActor
    func resumeTerminationAfterConfirmedExports() {
        guard Self.bookmarkExportTerminationPending, screenshotExportTerminationTask == nil, mailTerminationTask == nil else { return }
        let editors = NSApp.windows.compactMap { $0.windowController as? ScreenshotEditorWindowController }
            .filter { $0.hasConfirmedExport }
        if !editors.isEmpty {
            screenshotExportTerminationTask = Task { @MainActor [self] in
                for editor in editors { await editor.waitForConfirmedExport() }
                screenshotExportTerminationTask = nil
                resumeTerminationAfterConfirmedExports() // Include writers started during the wait.
            }
            return
        }
        guard Self.inFlightBookmarkExportWrites == 0 else { return }
        if MistMailService.shared.needsTerminationFlush {
            mailTerminationTask = Task { @MainActor [self] in
                await MistMailService.shared.flushForTermination()
                mailTerminationTask = nil
                resumeTerminationAfterConfirmedExports()
            }
            return
        }
        Self.bookmarkExportTerminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window keeps the app alive, and the session data
        // behind that close is safe: Chromium defers every close in the
        // window group until SpaceManager reports the teardown settled
        // (windowGroupCloseDidSettle), so a title-bar close stores the same
        // session quitting does and a Dock reopen restores it.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if SpaceManager.shared.reopenOnPersistedSpaceIfWindowless() {
            return true
        }
        return ChromiumLauncher.sharedInstance().bridge?.applicationShouldHandleReopen(sender, hasVisibleWindows: hasVisibleWindows) ?? false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = ChromiumLauncher.sharedInstance().bridge?.applicationDockMenu(sender)
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first, DeeplinkHandler.handle(url) {
            return
        }
        scheduleForwardOpenURLsToChromium(application: application, urls: urls)
    }

    /// Forwards `application(_:open:)` URLs to Chromium once the app can
    /// honor Space URL rules for them: a browser window is registered (so
    /// `PhiOpenUrlsInBrowser` doesn't call `Browser::Create` against a
    /// mid-restore session) AND the initial rule snapshot has been pushed to
    /// Chromium's routing table (forwarding earlier would resolve the URL
    /// against an empty table and open it unrouted in the last-active
    /// window). Cold launch retries in `coldOpenURLForwardDelay` steps up to
    /// `coldOpenURLForwardMaxAttempts`. Standard opens then forward as a
    /// last resort if readiness does not arrive within the bounded wait.
    private func scheduleForwardOpenURLsToChromium(
        application: NSApplication,
        urls: [URL]
    ) {
        SpaceManager.shared.beginSessionRestoreForExternalOpenIfEligible()
        let isCurrentRequestReady = isReadyToForwardOpenURLs()

        if !pendingColdOpenForwardURLs.isEmpty {
            pendingColdOpenForwardURLs.append(contentsOf: urls)
            if isReadyToForwardOpenURLs() {
                coldOpenURLForwardWorkItem?.cancel()
                coldOpenURLForwardWorkItem = nil
                let urlsToForward = pendingColdOpenForwardURLs
                pendingColdOpenForwardURLs.removeAll()
                coldOpenURLForwardAttempts = 0
                forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "coalesced")
            } else {
                scheduleColdOpenForwardRetry(application: application)
            }
            return
        }

        if isCurrentRequestReady {
            forwardOpenURLsToChromium(
                application: application,
                urls: urls,
                label: "immediate"
            )
            return
        }

        pendingColdOpenForwardURLs.append(contentsOf: urls)
        scheduleColdOpenForwardRetry(application: application)
    }

    private func isReadyToForwardOpenURLs() -> Bool {
        SpaceManager.shared.hasLoadedURLRules
            && !SpaceManager.shared.awaitsRestoredPrimary
            && SpaceSessionControllersManager.shared.getFirstAvailableWindowId() != nil
    }

    private func scheduleColdOpenForwardRetry(application: NSApplication) {
        guard coldOpenURLForwardWorkItem == nil else {
            AppLogDebug("[coldopen] urls appended to pending bridge forward queue")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coldOpenURLForwardWorkItem = nil
            self.coldOpenURLForwardAttempts += 1
            let isReady = self.isReadyToForwardOpenURLs()
            if !isReady,
               self.coldOpenURLForwardAttempts < Self.coldOpenURLForwardMaxAttempts {
                self.scheduleColdOpenForwardRetry(application: application)
                return
            }
            let label = isReady ? "deferred" : "deferred-timeout"
            let urlsToForward = self.pendingColdOpenForwardURLs
            self.pendingColdOpenForwardURLs.removeAll()
            self.coldOpenURLForwardAttempts = 0
            self.forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: label)
        }
        coldOpenURLForwardWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldOpenURLForwardDelay, execute: work)
        AppLogDebug("[coldopen] urls call bridge scheduled in \(Self.coldOpenURLForwardDelay)s (attempt \(coldOpenURLForwardAttempts + 1)/\(Self.coldOpenURLForwardMaxAttempts))")
    }

    private func forwardOpenURLsToChromium(application: NSApplication, urls: [URL], label: String) {
        let openedInPrimary = MainActor.assumeIsolated {
            SpaceManager.shared.openExternalURLsInPrimaryWindow(urls)
        }
        AppLogDebug("[coldopen] urls call bridge (\(label), path=\(openedInPrimary ? "primary" : "chromium"))")
        if openedInPrimary { return }
        ChromiumLauncher.sharedInstance().bridge?.application(application, open: urls)
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, willContinueUserActivityWithType: userActivityType) ?? false
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, continue: userActivity, restorationHandler: restorationHandler) ?? false
    }

    @MainActor
    @objc func phiWillTryToTerminateApplicationNotification(_ notification: Notification) {
        // Posted (synchronously, main thread) by phi_app_controller_mac.mm's
        // -tryToTerminateApplication once the quit is past the confirm sheet and
        // the in-progress-downloads prompt, BEFORE chrome::CloseAllBrowsers()
        // tears the windows down. This is the only quit signal that fires ahead
        // of that teardown cascade (the AppKit applicationWillTerminate hook runs
        // after it). Freeze the restore snapshot here so the closing windows
        // can't drain it — the next launch then regroups restored windows into
        // their slots and re-enters fullscreen. One refusal is still ahead of
        // the teardown, a page's beforeunload prompt; it lifts the freeze again
        // through phiDidCancelTerminateApplicationNotification below.
        SpaceManager.shared.markTerminating()
        TabNameStore.shared.freeze()
    }

    @MainActor
    @objc func phiDidCancelTerminateApplicationNotification(_ notification: Notification) {
        // Posted (synchronously, main thread) by phi_app_controller_mac.mm when a
        // beforeunload prompt answered "stay" calls off a quit it had announced
        // above. No window has closed by then — Chromium asks every window's
        // handlers before it closes the first — so the frozen layout is still
        // the live one: lift the freeze and let layout changes persist again.
        // Nothing is written here; a change refused during the freeze is still
        // pending and lands with the next write.
        SpaceManager.shared.clearTerminating()
        TabNameStore.shared.unfreeze()
    }

    private func bindChromiumBridgeIfNeeded() {
        if chromiumBridge == nil {
            chromiumBridge = ChromiumLauncher.sharedInstance().bridge
        }
    }

}

extension AppController {
    static var clientString: String?
    static func makeClientString() -> String {
        if clientString != nil { return clientString! }

        let preferredLang: String = {
            if let id = Locale.preferredLanguages.first, let lang = id.split(separator: "-").first {
                return String(lang)
            }
            return Locale.current.language.languageCode?.identifier ?? "en"
        }()

        let country = (Locale.current as NSLocale).object(forKey: .countryCode) as? String ?? "US"
        let localeStr = "\(preferredLang)-\(country)"

        let info = Bundle.main.infoDictionary ?? [:]
        let buildVersion = info["CFBundleVersion"] as? String ?? "0"
        let marketingVersion = info["CFBundleShortVersionString"] as? String ?? "0"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let marketingWithChannel = marketingVersion

        let name = "Phi /\(buildVersion) \(marketingWithChannel) (\(localeStr)); MacOS/\(osVersion);"
        clientString = name
        return name
    }
}

extension AppController {
    private func setupKinfisherCache() {
        FaviconDataProvider.setupCache()
    }
}

extension AppController: ASWebAuthenticationSessionWebBrowserSessionHandling {
    func begin(_ request: ASWebAuthenticationSessionRequest!) {
        ChromiumLauncher.sharedInstance().bridge?.beginHandling(request)
    }

    func cancel(_ request: ASWebAuthenticationSessionRequest!)  {
        ChromiumLauncher.sharedInstance().bridge?.cancel(request)
    }
}
