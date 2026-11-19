// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

protocol MainBrowserWindowLookup {
    func controller(for windowId: Int) -> SpaceSessionController?
}

class SpaceSessionControllersManager: MainBrowserWindowLookup {
    static let shared = SpaceSessionControllersManager()

    /// Chromium windows the shell deliberately leaves unmanaged: browser types
    /// that never get a `SpaceSessionController`, such as web-app windows
    /// (Phi Chat, hosted by its macOS app shim). Bridge events scoped to these
    /// ids are expected and must not be reported as missing windows.
    private var unmanagedWindowIds: Set<Int> = []
    private var unmanagedWindowCloseObservers: [Int: NSObjectProtocol] = [:]
    private(set) var activeWindowController: SpaceSessionController? {
        didSet {
            guard oldValue !== activeWindowController else { return }
            NotificationCenter.default.post(
                name: .activeBrowserWindowDidChange,
                object: activeWindowController
            )
        }
    }
    private var windowControllers: Set<SpaceSessionController> = []

    private init() {}

    func retainWindowControllerUntilWindowClosed(_ windowController: SpaceSessionController) {
        assert(Thread.isMainThread)
        guard !windowControllers.contains(windowController),
              let window = windowController.window,
              let lifecycleWindow = windowController.lifecycleWindow else {
            return
        }

        if windowControllers.isEmpty {
            activeWindowController = windowController
        }

        windowControllers.insert(windowController)

        // The close that ends a controller's life is its Chromium window's:
        // in hosted mode that is not the (shared, longer-lived) shell.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: lifecycleWindow)
        // A hosted shell reports key status through `ShellWindowController`
        // (`noteWindowBecameKey`), resolving to the presented session.
        if !windowController.isHosted {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(windowDidBecomeKey(_:)),
                                                   name: NSWindow.didBecomeKeyNotification,
                                                   object: window)
        }
    }

    /// Hosted-window mode: tracks a session built ahead of its Browser (see
    /// `SpaceSessionController.isDormant`). No close observer — there is no
    /// window to close yet; `noteChromiumWindowAttached` adds it when the
    /// Browser arrives, `releaseDormantSession` drops a session that never
    /// gets one.
    func retainDormantSession(_ windowController: SpaceSessionController) {
        assert(Thread.isMainThread)
        guard !windowControllers.contains(windowController),
              windowController.window != nil else { return }
        windowControllers.insert(windowController)
    }

    func noteChromiumWindowAttached(_ windowController: SpaceSessionController) {
        assert(Thread.isMainThread)
        guard windowControllers.contains(windowController),
              let lifecycleWindow = windowController.lifecycleWindow else { return }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: lifecycleWindow)
    }

    func releaseDormantSession(_ windowController: SpaceSessionController) {
        assert(Thread.isMainThread)
        windowControllers.remove(windowController)
        if activeWindowController === windowController {
            activeWindowController = windowControllers.first(where: { $0.isPresentedOrLegacy })
                ?? windowControllers.first
        }
    }

    /// Hosted-window mode: whether a slot-bound Chromium window is presented
    /// through the slot's shell rather than adopted as its own NSWindow.
    static func isHostedSession(browserType: ChromiumBrowserType, slot: SpaceWindowSlot?) -> Bool {
        guard slot != nil else { return false }
        return browserType == .normal || browserType == .incognitoSpace || browserType == .agentSpace
    }

    /// Creates the native owner matching Chromium's semantic window type.
    @MainActor
    @discardableResult
    func createWindowController(
        window: NSWindow,
        windowId: Int,
        browserType: ChromiumBrowserType,
        profileId: String,
        spaceId: String = SpaceManager.shared.currentDefaultSpaceId,
        account: Account = AccountController.shared.localDataAccount,
        slot: SpaceWindowSlot? = nil,
        chromiumWindow: NSWindow? = nil,
        dormant: Bool = false
    ) -> SpaceSessionController {
        return SpaceSessionController(
            window: window,
            windowId: windowId,
            browserType: browserType,
            profileId: profileId,
            spaceId: spaceId,
            account: account,
            slot: slot,
            chromiumWindow: chromiumWindow,
            dormant: dormant
        )
    }

    @objc private func windowWillClose(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = controller(forLifecycleWindow: window) else {
            return
        }
        WindowThemeMessageRouter.shared.stopObservingWindow(windowId: windowController.windowId)
        OverlayToastCenter.shared.clearWindow(windowId: windowController.windowId)
        // Normal, Incognito Space, and agent-Space windows live in slots
        // (mirrors the registerWindow gate in SpaceSessionController.init).
        // Skipping the Incognito Space's window here left its dead controller
        // registered: a window-driven cascade that included the Incognito Space
        // never drained its last entry, so the cascade-veto recovery "recovered"
        // onto the already-closed NSWindow and surfaced a blank shell. Agent
        // Space windows register too, so they must unregister here as well.
        if windowController.browserType == .normal || windowController.browserType == .incognitoSpace || windowController.browserType == .agentSpace {
            // Slot.unregisterWindow handles the per-slot "surface another
            // visible controller if this was the visible one" logic and
            // asks SpaceManager to drop the slot when it becomes empty. Agent
            // Space windows register (see SpaceSessionController.init), so
            // they must unregister here too or their slot/window leaks when the
            // Space is closed.
            windowController.slot?.unregisterWindow(windowController, for: windowController.spaceId)
        }
        // Shadow windows live outside slots entirely (see
        // AgentSpaceManager+Shadow.swift). Chromium can still tear one down on
        // its own — closing its last tab does, since shadow browsers skip
        // placeholder mode — so drop the registry entry or a re-bind would
        // hand its driver a dead windowId.
        if windowController.browserType == .shadow {
            MainActor.assumeIsolated {
                AgentSpaceManager.shared.shadowWindowDidClose(
                    windowId: windowController.windowId)
            }
        }
        windowControllers.remove(windowController)
        if activeWindowController === windowController {
            // Hosted sessions share a visible shell; only the presented one
            // stands for it.
            activeWindowController = windowControllers.first(where: {
                $0.window?.isVisible == true && $0.isPresentedOrLegacy
            }) ?? windowControllers.first(where: { !$0.isDormant })
        }
        // Chromium keeps every window close pending until it is told the gesture
        // is over; a cascade in flight makes this a no-op (see
        // `SpaceManager.reportWindowGroupCloseSettled`).
        SpaceManager.shared.reportWindowGroupCloseSettled()
    }

    @objc private func windowDidBecomeKey(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = window.windowController as? SpaceSessionController else {
            return
        }
        activeWindowController = windowController
        AppLogDebug("window did become key window: \(windowController.windowId)")
    }

    /// Hosted-window mode: a shell became key — its presented session is now
    /// the active controller. Called by `ShellWindowController`.
    func noteWindowBecameKey(_ window: NSWindow) {
        guard let windowController = findControllerWith(window: window) else { return }
        activeWindowController = windowController
        AppLogDebug("shell did become key window: \(windowController.windowId)")
    }

    /// Hosted-window mode: `controller` was just presented in its shell. The
    /// shell stays key across a Space switch, so no key notification announces
    /// that the session standing for it changed; if the shell is key, the
    /// presented session is the active controller from now on.
    func notePresentedInShell(_ controller: SpaceSessionController) {
        // The shell's window group: a switch made while one of its child
        // panels holds key (peek, reader, find bar) is still the user's
        // window, and the menu actions reading `activeWindowController`
        // must follow it.
        let ownsKey = (controller.window as? ShellWindow)?.groupOwnsKey
            ?? controller.window?.isKeyWindow
        guard ownsKey == true else { return }
        activeWindowController = controller
        AppLogDebug("presented session became active: \(controller.windowId)")
    }

    /// True while `PhiChromiumCoordinator` is inside Chromium's synchronous
    /// window-created callback, where the Browser being reported is still
    /// under construction. Hosted sessions defer their activation push to
    /// Chromium while this is set.
    var isInsideWindowCreatedCallback = false

    /// The controller whose life the close of `window` ends: the adopted
    /// window's controller, or in hosted mode the session backed by that
    /// Chromium window.
    private func controller(forLifecycleWindow window: NSWindow) -> SpaceSessionController? {
        windowControllers.first { $0.lifecycleWindow === window }
    }

    func getBrowserState(for browserId: Int) -> BrowserState? {
        return windowControllers.first(where: { $0.windowId == browserId })?.browserState
    }

    /// Records a Chromium window the shell will not manage so that
    /// window-scoped bridge events for it are dropped quietly until it closes.
    func registerUnmanagedWindow(_ window: NSWindow, windowId: Int) {
        unmanagedWindowIds.insert(windowId)
        if let previous = unmanagedWindowCloseObservers[windowId] {
            NotificationCenter.default.removeObserver(previous)
        }
        unmanagedWindowCloseObservers[windowId] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.unregisterUnmanagedWindow(windowId)
        }
    }

    func isUnmanagedWindow(_ windowId: Int) -> Bool {
        unmanagedWindowIds.contains(windowId)
    }

    private func unregisterUnmanagedWindow(_ windowId: Int) {
        unmanagedWindowIds.remove(windowId)
        if let observer = unmanagedWindowCloseObservers.removeValue(forKey: windowId) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func controller(for windowId: Int) -> SpaceSessionController? {
        windowControllers.first(where: { $0.windowId == windowId })
    }

    /// Resolves an NSWindow to its controller. A hosted shell is shared by
    /// every session of its slot, so it resolves to the PRESENTED one; a
    /// hosted session's hidden Chromium window resolves to that session
    /// (Chromium's command pipeline hands that window back).
    /// The session a context click landed in: the one presented in the window
    /// under the click. A right-click does not make its window key, so
    /// `activeWindowController` can be another window's Space. Falls back to
    /// it for menus not opened from a window (the menu bar).
    func controllerUnderContextClick() -> SpaceSessionController? {
        if let window = NSApp.currentEvent?.window,
           let controller = findControllerWith(window: window) {
            return controller
        }
        return activeWindowController
    }

    func findControllerWith(window: NSWindow) -> SpaceSessionController? {
        if let presented = windowControllers.first(where: { $0.window === window && $0.isPresentedOrLegacy }) {
            return presented
        }
        if let hosted = windowControllers.first(where: { $0.hostedChromiumWindow === window }) {
            return hosted
        }
        // Between a conceal and the next present no session of a shell is
        // presented; answer with a live session rather than a dormant one,
        // whose reserved id no Browser answers to.
        return windowControllers.first { $0.window === window && !$0.isDormant }
            ?? windowControllers.first { $0.window === window }
    }

    func getActiveWindowState() -> BrowserState? { activeWindowController?.browserState }

    /// Returns every tracked browser window controller. Dormant sessions are
    /// left out: they carry a reserved window id no Browser answers to yet.
    func getAllWindows() -> [SpaceSessionController] {
        return windowControllers.filter { !$0.isDormant }
    }

    /// Returns a live Chromium window ID; dormant sessions have no Browser yet.
    func getFirstAvailableWindowId() -> Int? {
        windowControllers.first(where: { !$0.isDormant })?.windowId
    }




    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    /// Posted when the focused browser window changes (or is cleared). Menu
    /// state that depends on the active window — e.g. the menu-bar Spaces
    /// menu, which is hidden for incognito windows — refreshes on this.
    static let activeBrowserWindowDidChange = Notification.Name("activeBrowserWindowDidChange")
}
