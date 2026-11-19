// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
struct CommandDispatcher {
    /// PHI-only commands intercepted in `handleKeyEquivalent` before Chromium sees them.
    private static let phiInterceptedCommands: [CommandWrapper] = [
        .PHI_TAB_SWITCHER_FORWARD,
        .PHI_TAB_SWITCHER_BACKWARD,
        .PHI_COPY_URL,
        .PHI_ALTERNATE_NEW_TAB,
        .PHI_CAPTURE_FULL_PAGE,
        .PHI_CAPTURE_AREA,
        .PHI_DRIFTER_MODEL_MENU,
        .PHI_DRIFTER_EFFORT_MENU,
        .PHI_DRIFTER_PREVIOUS_MARKER,
        .PHI_DRIFTER_NEXT_MARKER,
        .PHI_SWITCH_CHAT_PANEL_AND_TAB,
    ]

    /// Commands swallowed while the focused tab shows the native NTP — it has no
    /// WebContents to inspect or view source of.
    private static let nativeNtpBlockedCommands: Set<CommandWrapper> = [
        .IDC_DEV_TOOLS,
        .IDC_DEV_TOOLS_INSPECT,
        .IDC_DEV_TOOLS_CONSOLE,
        .IDC_VIEW_SOURCE,
    ]

    /// Reverse lookup: user-configured shortcut key → PHI command.
    /// Rebuilt when shortcuts change via `reloadPhiShortcutMap()`.
    private static var phiShortcutMap: [ShortcutsKey: CommandWrapper] = buildPhiShortcutMap()

    static func reloadPhiShortcutMap() {
        phiShortcutMap = buildPhiShortcutMap()
    }

    private static func buildPhiShortcutMap() -> [ShortcutsKey: CommandWrapper] {
        var map: [ShortcutsKey: CommandWrapper] = [:]
        for cmd in phiInterceptedCommands {
            if let key = Shortcuts.key(for: cmd) {
                map[key] = cmd
            }
        }
        return map
    }

    @MainActor
    static func dispatchCommand(_ sender: Any, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: (sender as AnyObject).tag) else {
            return false
        }
        return dispatchCommand(command, to: window)
    }

    /// True while `window` shows an agent Space the agent currently controls.
    /// Its workspace is off-limits to the user until they take control.
    @MainActor
    static func isWindowAgentLocked(_ window: NSWindow) -> Bool {
        guard let state = SpaceSessionControllersManager.shared
                .findControllerWith(window: window)?.browserState else { return false }
        return AgentSpaceManager.shared.isAgentOwned(state.spaceId)
    }

    @MainActor
    private static func dispatchCommand(_ command: CommandWrapper, to window: NSWindow,
                                        initiatingShortcut: ShortcutsKey? = nil) -> Bool {
        guard let windowController = SpaceSessionControllersManager.shared.findControllerWith(window: window) else {
            return false
        }
        // Agent lock blocks every browser command until the user takes control.
        if isWindowAgentLocked(window) {
            return true
        }
        // DevTools can't attach to the native NTP (no WebContents) — swallow the command.
        if nativeNtpBlockedCommands.contains(command),
           let tab = windowController.browserState.focusingTab,
           (tab.isShowingNativeNTP || (!windowController.browserState.isIncognito && (MistApps.address(tab.url) != nil))) {
            AppLogDebug("[DevToolsBlock] swallowed \(command) on native NTP")
            return true
        }

        switch command {
        case .PHI_SWITCH_CHAT_PANEL_AND_TAB:
            return MistChatPanelViewController.performPanelTabSwitch(in: windowController)
        case .PHI_DRIFTER_MODEL_MENU, .PHI_DRIFTER_EFFORT_MENU:
            guard let row = MistDrifterLaunchRow.focused(in: window) else { return false }
            row.showPicker(command == .PHI_DRIFTER_MODEL_MENU ? .model : .effort)
            return true
        case .PHI_DRIFTER_PREVIOUS_MARKER, .PHI_DRIFTER_NEXT_MARKER:
            guard case let .app(page) = nativePage(in: windowController), let chat = page as? AgentChatViewController else { return false }
            chat.stepMarker(forward: command == .PHI_DRIFTER_NEXT_MARKER)
            return true
        case .IDC_RELOAD, .IDC_RELOAD_BYPASSING_CACHE:
            if case let .app(page) = nativePage(in: windowController) { return page.performPageCommand(command) }
            return false
        case .IDC_FIND, .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS, .IDC_ZOOM_PLUS, .IDC_ZOOM_MINUS, .IDC_ZOOM_NORMAL:
            guard let page = nativePage(in: windowController) else { return false }
            page.perform(command)
            return true
        case .IDC_SHOW_BOOKMARK_BAR:
            // Keep the Chromium command identity while Phi owns its presentation.
            if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                AppController.shared?.toggleBookmarkBar(nil)
            }
            return true
        case .IDC_HOME:
            guard !AgentAnimationManager.shared.isActive(for: windowController.browserState.focusingTab?.guid ?? 0) else {
                // disable home command when the current tab is excuting agent job
                return true
            }
            return false
        case .IDC_BACK:
            windowController.goBack(nil)
            return true
        case .IDC_FORWARD:
            windowController.goForward(nil)
            return true
        case .IDC_NEW_TAB:
            windowController.newBrowserTab(nil)
            return true
        case .IDC_RESTORE_TAB:
            let state = windowController.browserState
            return !state.isIncognito
                && AgentChatStore.shared.restoreClosedTabSkippingAgentFolders(windowId: state.windowId)
        case .PHI_ALTERNATE_NEW_TAB:
            windowController.newAlternateBrowserTab()
            return true
        case .IDC_NEW_TAB_TO_RIGHT:
            // Placeholder mode has no active tab, so "to the right" has no
            // meaning — fall back to a plain new tab. Outside placeholder,
            // let Chromium handle it normally (it operates on active_index()).
            if windowController.browserState.isInPlaceholderMode {
                windowController.newBrowserTab(nil)
                return true
            }
            return false
        case .IDC_CLOSE_TAB:
            if windowController.handleCloseTab() {
                return true
            }
            // ⌘W closing the last home page tears the whole window slot
            // down — same as ⇧⌘W / the red ✕. It deliberately does NOT tag
            // the slot as a tab-driven close (tab UI closes do).
            // A last real page gets a home page first; closing that home
            // page goes through the shell's window-driven cascade below.
            //
            // An INCOGNITO Space is the exception: it is an ephemeral
            // session inside the slot, not a user-perceived window of its
            // own, so ⌘W on its last tab reads as "close this Incognito
            // Space". That teardown is confirmed first ("Do not ask again"
            // suppressible) and then closes the Space's windows in every
            // slot, retreat-first — closing the last incognito window is
            // what makes Chromium destroy the shared OTR profile. Swallow
            // the command either way: on confirm the window close takes the
            // tab with it, on cancel nothing must close.
            let state = windowController.browserState
            if state.isIncognitoSpace, state.tabs.count <= 1 {
                _ = MainActor.assumeIsolated {
                    SpaceManager.shared.requestCloseIncognitoSpace(spaceId: windowController.spaceId)
                }
                return true
            }
            if let tab = state.focusingTab,
               state.applyLastTabClosePolicy(to: [tab], intent: .windowDriven) {
                return true
            }
            return false
        case .IDC_CLOSE_TAB_GROUP:
            let state = windowController.browserState
            if let token = state.focusingTab?.groupToken {
                let members = state.normalTabs.filter { $0.groupToken == token }
                if state.applyLastTabClosePolicy(to: members, intent: .windowDriven) { return true }
            }
            return false
        case .IDC_FOCUS_LOCATION:
            windowController.openLocationBar(nil)
            return true
        case .IDC_TAB_SEARCH:
            windowController.toggleSearchTabs()
            return true
        case .IDC_WINDOW_PIN_TAB:
            return true
        case .IDC_WINDOW_CLOSE_OTHER_TABS:
            // The tab context menus' Close Other Tabs, which show this
            // shortcut: on the selection, else the focused tab.
            let state = windowController.browserState
            if state.multiSelection.isActive {
                state.closeTabsOutsideMultiSelection()
            } else if let tab = state.focusingTab {
                state.closeTabs(keeping: [tab.guid])
            }
            return true
        case .IDC_SELECT_PREVIOUS_TAB:
            windowController.browserState.swicthTab(.back)
            return true
        case .IDC_SELECT_NEXT_TAB:
            windowController.browserState.swicthTab(.forward)
            return true
        case .PHI_TAB_SWITCHER_FORWARD:
            windowController.browserState.tabSwitchManager.handleStep(
                .forward, initiatingKey: initiatingShortcut)
            return true
        case .PHI_TAB_SWITCHER_BACKWARD:
            windowController.browserState.tabSwitchManager.handleStep(
                .backward, initiatingKey: initiatingShortcut)
            return true
        case .PHI_COPY_URL:
            let state = windowController.browserState
            guard let copiedURLs = state.copySelectedTabURLs() else { return false }
            OverlayToastCenter.shared.showURLCopyConfirmation(copiedURLs: copiedURLs, in: state)
            return true
        case .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA:
            let state = windowController.browserState
            let area = command == .PHI_CAPTURE_AREA
            guard PageScreenshotService.shared.canCapture(in: state, area: area) else { return false }
            PageScreenshotService.shared.capture(in: state, area: area)
            return true
        case .IDC_SELECT_LAST_TAB:
            windowController.browserState.swicthTab(.last)
            return true
        case .IDC_FOCUS_SEARCH:
            windowController.newBrowserTab(nil)
            return true
        case .IDC_IMPORT_SETTINGS:
            // Migration and browser-data import must not write into the user's
            // data at the same time. The menu item is greyed out while a
            // Migration is in flight, but the command also arrives from
            // Chromium, so the refusal lives at the chokepoint every route
            // passes through. Swallowed rather than explained: the greyed item
            // is where the user is told.
            // Import targets the active Space's profile; off-the-record
            // windows (standalone incognito and the Incognito Space) have
            // no importable profile — tell the user instead of opening the
            // import window.
            guard !windowController.browserState.isIncognito else {
                windowController.presentImportUnavailableInIncognitoAlert()
                return true
            }
            windowController.showImportDataWindow()
            return true
        case .IDC_BOOKMARK_THIS_TAB:
            windowController.toggleBookmark(nil)
            return true
        case .IDC_SHOW_BOOKMARK_MANAGER:
            guard !windowController.browserState.isIncognito else { return true }
            windowController.browserState.openTab(
                URLProcessor.processUserInput("phi://bookmarks")
            )
            return true
        case let c where c.rawValue >= CommandWrapper.IDC_SELECT_TAB_0.rawValue && c.rawValue <= CommandWrapper.IDC_SELECT_TAB_7.rawValue:
            SpaceSessionControllersManager.shared.findControllerWith(window: window)?.selectTabWithIndex(c.rawValue - CommandWrapper.IDC_SELECT_TAB_0.rawValue)
            return true
        default: break
        }
        return false
    }

    @MainActor
    static func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {

        // An applicable binding owns the key even when its action currently
        // has no result (for example, Copy URL without a copyable selection).
        // Returning the action's success here would let a hidden Chromium
        // alias execute a different command for the same press.
        if let phiCommand = interceptedPhiCommand(for: event),
           phiShortcutApplies(phiCommand, to: window) {
            if phiCommand == .PHI_ALTERNATE_NEW_TAB, event.isARepeat { return true }
            _ = dispatchCommand(phiCommand, to: window, initiatingShortcut: Shortcuts.key(for: phiCommand))
            return true
        }

        // Swallow every other browser shortcut until the user takes control.
        if isWindowAgentLocked(window) {
            return true
        }

        return false
    }

    /// A native page that takes find and zoom instead of Chromium's hidden page behind it.
    @MainActor
    private enum NativePage {
        case reader(MarkdownReaderViewController)
        case app(any MistAppPage)

        func perform(_ command: CommandWrapper) {
            switch self {
            case let .reader(reader): reader.performPageCommand(command)
            case let .app(page): _ = page.performPageCommand(command)
            }
        }

        var zoom: CGFloat? {
            switch self {
            case let .reader(reader): reader.zoom
            case let .app(page): page.pageZoom
            }
        }
    }

    /// A chat holding focus (its tab page or a Chat panel), else the focused tab's Markdown reader or chat page.
    @MainActor
    private static func nativePage(in windowController: SpaceSessionController) -> NativePage? {
        var responder = windowController.window?.firstResponder
        while let current = responder {
            if let page = current as? any MistAppPage,
               (page as? AgentChatViewController).map({ $0.conversation != nil }) ?? true { return .app(page) }
            responder = current.nextResponder
        }
        let state = windowController.browserState
        let container = windowController.mainSplitViewController.webContentContainerViewController
        // Chromium passes its hosted window, not the shell window that shows native pages.
        guard let tab = state.focusingTab, state.pageCommandTarget === tab else { return nil }
        if !state.isIncognito, MistApps.address(tab.url) != nil, let page = container.appPage(for: tab),
           page.isViewLoaded, page.view.window != nil, page.view.window === windowController.window { return .app(page) }
        if tab.showsMarkdownReader, let reader = container.markdownReader(for: tab),
           reader.isViewLoaded, reader.view.window != nil, reader.view.window === windowController.window {
            return .reader(reader)
        }
        return nil
    }

    /// Whether a zoom menu item is enabled over the native page in `window`, or nil when Chromium decides.
    /// Chromium answers for its hidden page, which stays at 100%, so Actual Size would stay disabled.
    @MainActor
    static func nativePageZoomEnabled(_ tag: Int, window: NSWindow) -> Bool? {
        guard let command = CommandWrapper(rawValue: tag),
              command == .IDC_ZOOM_PLUS || command == .IDC_ZOOM_MINUS || command == .IDC_ZOOM_NORMAL,
              let controller = SpaceSessionControllersManager.shared.findControllerWith(window: window),
              let page = nativePage(in: controller) else { return nil }
        guard let zoom = page.zoom else { return false }
        if command == .IDC_ZOOM_NORMAL { return abs(zoom - 1) > 0.0001 }
        return MarkdownReaderZoom.canStep(zoom, up: command == .IDC_ZOOM_PLUS)
    }

    /// Window/feature scope is distinct from transient action availability.
    /// Keep non-browser windows out of interception without duplicating action validation.
    @MainActor
    private static func phiShortcutApplies(_ command: CommandWrapper, to window: NSWindow) -> Bool {
        guard let controller = SpaceSessionControllersManager.shared.findControllerWith(window: window) else {
            return false
        }
        // Elsewhere the keys stay with the page.
        if command == .PHI_SWITCH_CHAT_PANEL_AND_TAB {
            return MistChatPanelViewController.panelTabSwitch(in: controller.browserState) != nil
        }
        if command == .PHI_DRIFTER_PREVIOUS_MARKER || command == .PHI_DRIFTER_NEXT_MARKER {
            if case let .app(page) = nativePage(in: controller), page is AgentChatViewController { return true }
            return false
        }
        if command == .PHI_DRIFTER_MODEL_MENU || command == .PHI_DRIFTER_EFFORT_MENU {
            return MistDrifterLaunchRow.focused(in: window) != nil
        }
        return true
    }

    static func interceptedPhiCommand(
        for event: NSEvent,
        inputSourceIdentifier: String? = nil
    ) -> CommandWrapper? {
        matchedPhiCommand(
            for: event,
            shortcutMap: phiShortcutMap,
            inputSourceIdentifier: inputSourceIdentifier
        )
    }

    static func matchedPhiCommand(
        for event: NSEvent,
        shortcutMap: [ShortcutsKey: CommandWrapper],
        inputSourceIdentifier: String? = nil
    ) -> CommandWrapper? {
        let eventKeys: ShortcutsKey.EventKeys?
        if let inputSourceIdentifier {
            eventKeys = ShortcutsKey.eventKeys(
                for: event,
                inputSourceIdentifier: inputSourceIdentifier
            )
        } else {
            eventKeys = ShortcutsKey.eventKeys(for: event)
        }
        guard let eventKeys else { return nil }
        return shortcutMap.compactMap { key, command -> (rank: Int, command: CommandWrapper)? in
            guard let rank = eventKeys.matchingRank(for: key) else { return nil }
            return (rank, command)
        }.min {
            // Old configurations may contain equivalent conflicting bindings.
            // Keep resolution stable instead of depending on Dictionary order.
            $0.rank == $1.rank ? $0.command.rawValue < $1.command.rawValue : $0.rank < $1.rank
        }?.command
    }

    @MainActor
    static func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: Int(commandId)) else {
            return false
        }
        AppLogDebug("will dispatch command: \(command)")
        return dispatchCommand(command, to: window)
    }
}
