// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// chrome/app/chrome_command_ids.h. Chromium 152 moved the structural menu
// containers to the "Centralized Placeholder Command IDs" block at the bottom
// of that file (kEditMenuId, kMacViewMenuId, ...); 150 tags the same menus
// with the legacy IDC_*_MENU values. Both sets are hand-copied and both are
// accepted while the client ships against either framework, so re-check
// them on every major.
enum ChromiumMainMenuRole: Int {
    case edit = 57343       // kEditMenuId
    case bookmarks = 57333  // kBookmarksMenuId (AppMenuModel::kBookmarksMenuPlaceholder)
    case help = 57330       // kHelpMenuId
    case window = 57321     // kMacWindowMenuId
    case view = 57327       // kMacViewMenuId
    case file = 57326       // kMacFileMenuId
    case app = 57325        // kMacChromeMenuId
    case history = 57324    // kMacHistoryMenuId
    case tab = 57323        // kMacTabMenuId
    case profiles = 57322   // kMacProfileMainMenuId

    private static let legacyTags: [Int: Self] = [
        36004: .edit,       // IDC_EDIT_MENU
        40029: .bookmarks,  // IDC_BOOKMARKS_MENU
        40244: .help,       // IDC_HELP_MENU
        34045: .window,     // IDC_WINDOW_MENU
        44000: .view,       // IDC_VIEW_MENU
        44001: .file,       // IDC_FILE_MENU
        44002: .app,        // IDC_CHROME_MENU
        46000: .history,    // IDC_HISTORY_MENU
        46001: .tab,        // IDC_TAB_MENU
        46100: .profiles,   // IDC_PROFILE_MAIN_MENU
    ]

    init?(tag: Int) {
        guard let role = Self(rawValue: tag) ?? Self.legacyTags[tag] else { return nil }
        self = role
    }

    static func resolve(_ item: NSMenuItem, helpMenu: NSMenu?) -> Self? {
        if let role = Self(tag: item.tag) {
            return role
        }
        // Chromium currently assigns IDC_HELP_MENU to no AppKit item. Its
        // NSApplication helpMenu reference is the stable native fallback.
        if let helpMenu = helpMenu, item.submenu === helpMenu {
            return .help
        }
        return nil
    }

    func item(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { Self(tag: $0.tag) == self }
    }

    func index(in menu: NSMenu) -> Int? {
        menu.items.firstIndex { Self(tag: $0.tag) == self }
    }
}

private final class SpaceThemeEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SpaceThemeEditorPanelDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private enum SpaceThemeEditorPanelPlacement {
    case nearTrigger(NSPoint)
    case windowTop
}

private final class SpaceThemeEditorMenuContext {
    weak var browserState: BrowserState?
    let placement: SpaceThemeEditorPanelPlacement

    init(browserState: BrowserState?, placement: SpaceThemeEditorPanelPlacement) {
        self.browserState = browserState
        self.placement = placement
    }
}

@MainActor
private final class SpaceThemeEditorPanelPresenter {
    static let shared = SpaceThemeEditorPanelPresenter()

    private weak var parentWindow: NSWindow?
    private var panel: SpaceThemeEditorPanel?
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    func present(
        spaceId: String,
        from window: NSWindow,
        placement: SpaceThemeEditorPanelPlacement,
        themeSource: ThemeStateProvider
    ) {
        dismiss()

        let contentSize = SpaceThemeEditorView.contentSize
        let panel = SpaceThemeEditorPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentViewController = ThemedHostingController(
            rootView: SpaceThemeEditorView(spaceId: spaceId) { [weak self] in
                self?.dismiss()
            },
            themeSource: themeSource
        )
        panel.setContentSize(contentSize)
        if let contentView = panel.contentView {
            let dragView = SpaceThemeEditorPanelDragView()
            dragView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(dragView)
            NSLayoutConstraint.activate([
                dragView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                dragView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                dragView.topAnchor.constraint(equalTo: contentView.topAnchor),
                dragView.heightAnchor.constraint(equalToConstant: 8),
            ])
        }
        self.panel = panel
        parentWindow = window

        // NSMenu actions run inside AppKit's modal event-tracking loop. Wait
        // until the menu has closed before ordering the child panel above its
        // browser window.
        DispatchQueue.main.async { [weak self, weak window, weak panel] in
            guard let self,
                  let window,
                  let panel,
                  self.panel === panel,
                  window.isVisible else { return }

            let origin = self.initialOrigin(
                panelSize: panel.frame.size,
                placement: placement,
                window: window
            )
            panel.setFrameOrigin(origin)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            self.installDismissMonitors()
        }
    }

    private func initialOrigin(
        panelSize: NSSize,
        placement: SpaceThemeEditorPanelPlacement,
        window: NSWindow
    ) -> NSPoint {
        let margin: CGFloat = 8

        switch placement {
        case .windowTop:
            let visibleFrame = window.screen?.visibleFrame ?? window.frame
            let topInset: CGFloat = 12
            let x = min(
                max(
                    window.frame.midX - panelSize.width / 2,
                    visibleFrame.minX + margin
                ),
                visibleFrame.maxX - panelSize.width - margin
            )
            let y = min(
                max(
                    window.frame.maxY - panelSize.height - topInset,
                    visibleFrame.minY + margin
                ),
                visibleFrame.maxY - panelSize.height - margin
            )
            return NSPoint(x: x, y: y)

        case let .nearTrigger(triggerScreenPoint):
            let screen = NSScreen.screens.first { $0.frame.contains(triggerScreenPoint) }
                ?? window.screen
            let visibleFrame = screen?.visibleFrame ?? window.frame
            let gap: CGFloat = 12

            var x = triggerScreenPoint.x + gap
            if x + panelSize.width > visibleFrame.maxX - margin {
                x = triggerScreenPoint.x - panelSize.width - gap
            }

            var y = triggerScreenPoint.y - panelSize.height - gap
            if y < visibleFrame.minY + margin {
                y = triggerScreenPoint.y + gap
            }

            x = min(
                max(x, visibleFrame.minX + margin),
                visibleFrame.maxX - panelSize.width - margin
            )
            y = min(
                max(y, visibleFrame.minY + margin),
                visibleFrame.maxY - panelSize.height - margin
            )
            return NSPoint(x: x, y: y)
        }
    }

    func dismiss() {
        removeDismissMonitors()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        parentWindow = nil
    }

    private func installDismissMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseEvents.union(.keyDown)
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
            } else if (event.type == .leftMouseDown
                        || event.type == .rightMouseDown
                        || event.type == .otherMouseDown),
                      event.window !== panel {
                self.dismiss()
            }
            return event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }
}

extension AppController {
    @MainActor @objc func openMistApp(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String, let id = MistAppID(rawValue: rawID) else { return }
        SpaceSessionControllersManager.shared.getActiveWindowState()?.openApp(id)
    }

    @MainActor @objc func newDrifterChatFromMenu(_ sender: Any?) {
        SpaceSessionControllersManager.shared.getActiveWindowState()?.openNewDrifterChat()
    }

    static let extensionInfoItemTag = 500002
    static let exportLogsItemTag = 500011
    static let manageUserDataHelpSeparatorTag = 500012
    static let manageUserDataParentItemTag = 500013
    static let timeMachineBackupsParentItemTag = 500014
    static let toggleBookmarkBarOnNewTabItemTag = 500004
    static let layoutModeDefaultItemTag = 500005
    static let layoutModeNavigationAtTopItemTag = 500006
    static let layoutModeTraditionalItemTag = 500007
    static let layoutModeTitleItemTag = 500008
    private static let reportIssueCommandTag = 40008 // Chromium IDC_FEEDBACK
    static let whatsNewItemTag = 500009
    static let improveTranslationsItemTag = 500028
    static let bookmarksMenuItemTag = 500010
    static let bookmarksMenuIdentifier = NSUserInterfaceItemIdentifier("phi.bookmarks.menu")
    static let spacesNewProfileItemTag = 500015
    static let spacesDeleteProfileParentItemTag = 500016
    static let viewMenuPhiSectionSeparatorTag = 500023
    static let agentAutoViewItemTag = 500024
    // 500025: was 500036, which collided with spacesChangeProfileParentTag
    // (harmless across submenus, but tags must stay unique to grep sanely).
    static let agentTranscriptItemTag = 500025
    static let viewLibraryItemTag = 500040
    static let debugMenuItemTag = 500027
    static let spacesProfileSeparatorTag = 500020
    static let deleteProfileSubmenuIdentifier = NSUserInterfaceItemIdentifier("phi.spaces.deleteProfile")
    static let appsMenuItemTag = 500019
    static let spacesMenuItemTag = 500018
    static let spacesNewSpaceItemTag = 500030
    static let spacesRenameItemTag = 500031
    static let spacesChangeThemeParentTag = 500033
    static let spacesChangeProfileParentTag = 500036
    static let spacesDeleteSpaceItemTag = 500037
    static let spacesURLRulesItemTag = 500021
    static let spacesURLRulesSeparatorTag = 500022
    static let spacesMenuIdentifier = NSUserInterfaceItemIdentifier("phi.spaces.menu")
    static let timeMachineBackupsMenuIdentifier = NSUserInterfaceItemIdentifier("phi.time-machine.backups.menu")

    func startObservingMainMenu() {
        guard let app = NSApplication.shared as NSApplication? else {
            AppLogWarn("⚠️ NSApp is nil — startObservingMainMenu() called too early.")
            return
        }
        startStrippingRemovedMenuItems()
        startObservingServiceShortcuts()
        MistHistoryMenuReopen.install()
        menuObservation = app.observe(\.mainMenu, options: [.new, .old]) { [weak self] app, change in
            AppLogDebug("Main menu changed: \(change)")
            self?.hookAndRebuildMainMenu()
        }
        // Every layout-mode writer (View menu, Settings, tab-area context
        // menu, sync) goes through the standard defaults.
        lastMenuLayoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        layoutModeMenuObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mode = PhiPreferences.GeneralSettings.loadLayoutMode()
                guard mode != self.lastMenuLayoutMode else { return }
                self.lastMenuLayoutMode = mode
                self.refreshPrefGatedMenuItems()
            }
        }
    }

    /// Strips framework items for deleted features from every menu, including
    /// Chromium's web content context menus, as it starts tracking.
    func startStrippingRemovedMenuItems() {
        guard removedMenuItemsObservation == nil else { return }
        removedMenuItemsObservation = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            // Synchronous on the tracking (main) thread, before the menu draws.
            if let menu = notification.object as? NSMenu { MistRemovedMenuItems.strip(menu) }
        }
    }

    /// Enforce released native keys and reserve Tab Search's and Mail's chords without changing the
    /// user's Services preferences or removing the service's menu action.
    func startObservingServiceShortcuts() {
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification,
                     NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            center.removeObserver(self, name: name, object: nil)
            center.addObserver(self, selector: #selector(serviceMenuItemsDidChange(_:)),
                               name: name, object: nil)
        }
        if let menu = NSApp.mainMenu { Self.suppressReservedServiceShortcut(in: menu) }
        if let menu = NSApp.servicesMenu { Self.suppressReservedServiceShortcut(in: menu) }
    }

    @objc private func serviceMenuItemsDidChange(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
           menu.items.indices.contains(index) {
            Self.suppressReservedServiceShortcut(on: menu.items[index])
        } else {
            Self.suppressReservedServiceShortcut(in: menu)
        }
        ShortcutMenuPresentation.handle(notification)
    }

    static func suppressReservedServiceShortcut(in menu: NSMenu) {
        menu.items.forEach { suppressReservedServiceShortcut(on: $0) }
    }

    private static func suppressReservedServiceShortcut(on item: NSMenuItem) {
        if let submenu = item.submenu { suppressReservedServiceShortcut(in: submenu) }
        var menu = item.menu
        while let parent = menu?.supermenu { menu = parent }
        if menu === NSApp.mainMenu { Shortcuts.suppressReleasedNativeShortcut(on: item) }
        // AppKit dispatches Services through this selector, including items in
        // replacement menus that no longer equal NSApp.servicesMenu.
        guard item.action == NSSelectorFromString("_processRequest:") else { return }
        let declared = item.keyEquivalent.isEmpty && item.view == nil
            ? (item.copy() as? NSMenuItem ?? item) : item
        let key = ShortcutsKey(characters: declared.keyEquivalent,
                               modifiers: declared.keyEquivalentModifierMask)
        // Terminal's man page Services claim ⇧⌘A (Tab Search) and ⇧⌘M (Mail).
        let reserved = [ShortcutsKey(characters: "a", modifiers: [.command, .shift]),
                        ShortcutsKey(characters: "m", modifiers: [.command, .shift])]
        guard reserved.contains(where: { $0.menuKeyEquivalent == key.menuKeyEquivalent }) else { return }
        // Explicitly clear the declared key too, so detached inventory copies
        // cannot restore it. Reentrant change notifications see an empty key.
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }

    /// Schedules the main-menu hook so pref-gated items appear or disappear
    /// without waiting for Chromium's next menu swap — the View ▸ agent items
    /// follow the agent CDP switch (`AgentCDPListener.setEnabled` calls this),
    /// and the Tab menu's New Tab title follows the layout mode.
    /// Coalesces repeated requests and waits until menu tracking ends.
    func refreshPrefGatedMenuItems() {
        guard !isMainMenuRefreshScheduled else { return }
        isMainMenuRefreshScheduled = true

        // The main dispatch queue also drains during menu tracking. Use only
        // default mode to avoid mutating AppKit's active menu backing views.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isMainMenuRefreshScheduled = false
                self.hookAndRebuildMainMenu()
            }
        }
    }

    private func hookAndRebuildMainMenu() {
        guard let mainMenu = NSApp.mainMenu else {
            return
        }
        Self.suppressReservedServiceShortcut(in: mainMenu)

        var hasBookmarksMenu = false
        for menuItem in mainMenu.items {
            let menuRole = ChromiumMainMenuRole.resolve(menuItem, helpMenu: NSApp.helpMenu)

            if let submenu = menuItem.submenu, menuRole == .view {
                submenu.items.forEach {
                    let tag = $0.tag
                    if [40009, 40250, 40259, 40282, 40296, 40299, 40251].contains(tag) {
                        $0.isHidden = true
                    }
                }

                submenu.items.removeAll { item in
                    item.tag == CommandWrapper.PHI_TOGGLE_SIDEBAR.rawValue ||
                    item.tag == CommandWrapper.PHI_TOGGLE_CHATBAR.rawValue ||
                    item.tag == CommandWrapper.PHI_SWITCH_CHAT_PANEL_AND_TAB.rawValue ||
                    item.tag == CommandWrapper.PHI_CLOSE_PANEL_CHAT.rawValue ||
                    item.tag == CommandWrapper.PHI_NEW_CONVERSATION.rawValue ||
                    item.tag == CommandWrapper.PHI_TOGGLE_READER.rawValue ||
                    item.tag == AppController.viewLibraryItemTag ||
                    item.tag == AppController.viewMenuPhiSectionSeparatorTag ||
                    item.tag == CommandWrapper.IDC_SHOW_BOOKMARK_BAR.rawValue ||
                    item.tag == AppController.toggleBookmarkBarOnNewTabItemTag ||
                    item.tag == AppController.layoutModeDefaultItemTag ||
                    item.tag == AppController.layoutModeNavigationAtTopItemTag ||
                    item.tag == AppController.layoutModeTraditionalItemTag ||
                    item.tag == AppController.layoutModeTitleItemTag ||
                    item.tag == AppController.agentAutoViewItemTag ||
                    item.tag == AppController.agentTranscriptItemTag
                }

                if submenu.items.last?.isSeparatorItem == false {
                    let topSeparator = NSMenuItem.separator()
                    topSeparator.tag = AppController.viewMenuPhiSectionSeparatorTag
                    submenu.addItem(topSeparator)
                }

                let toggleReaderItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.toggleReaderView", value: "Toggle Reader View", comment: "View menu - Menu item that switches the current page between Reader View and the normal page"),
                                                  action: #selector(toggleReaderView(_:)),
                                                  keyEquivalent: "r")
                toggleReaderItem.keyEquivalentModifierMask = [.command, .option]
                toggleReaderItem.tag = CommandWrapper.PHI_TOGGLE_READER.rawValue
                Shortcuts.updateShortcut(for: toggleReaderItem)
                toggleReaderItem.target = self
                submenu.addItem(toggleReaderItem)

                let libraryItem = NSMenuItem(title: LibraryViewModule.title,
                                             action: #selector(openLibrary(_:)),
                                             keyEquivalent: "")
                libraryItem.tag = AppController.viewLibraryItemTag
                libraryItem.target = self
                submenu.addItem(libraryItem)

                let readerSeparator = NSMenuItem.separator()
                readerSeparator.tag = AppController.viewMenuPhiSectionSeparatorTag
                submenu.addItem(readerSeparator)

                let layoutTtitle = NSMenuItem.sectionHeader(title: NSLocalizedString("app.viewMenu.layoutModeSectionTitle", value: "Layout Mode", comment: "View menu - Layout mode section header in View menu"))
                layoutTtitle.tag = AppController.layoutModeTitleItemTag
                submenu.addItem(layoutTtitle)

                let navigationAtTopItem = NSMenuItem(title: LayoutMode.balanced.displayName,
                                                     action: #selector(selectLayoutMode(_:)),
                                                     keyEquivalent: "")
                navigationAtTopItem.tag = AppController.layoutModeNavigationAtTopItemTag
                navigationAtTopItem.target = self
                submenu.addItem(navigationAtTopItem)

                let defaultLayoutItem = NSMenuItem(title: LayoutMode.performance.displayName,
                                                   action: #selector(selectLayoutMode(_:)),
                                                   keyEquivalent: "")
                defaultLayoutItem.tag = AppController.layoutModeDefaultItemTag
                defaultLayoutItem.target = self
                submenu.addItem(defaultLayoutItem)

                let traditionalLayoutItem = NSMenuItem(title: LayoutMode.comfortable.displayName,
                                                       action: #selector(selectLayoutMode(_:)),
                                                       keyEquivalent: "")
                traditionalLayoutItem.tag = AppController.layoutModeTraditionalItemTag
                traditionalLayoutItem.target = self
                submenu.addItem(traditionalLayoutItem)

                let bookmarkBarSeparator = NSMenuItem.separator()
                bookmarkBarSeparator.tag = AppController.viewMenuPhiSectionSeparatorTag
                submenu.addItem(bookmarkBarSeparator)
                let toggleBookmarkBarItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.alwaysShowBookmarkBar", value: "Always Show Bookmark Bar", comment: "View menu - Menu item to always show the bookmark bar"),
                                                   action: #selector(toggleBookmarkBar(_:)),
                                                   keyEquivalent: "")
                applyEffectiveShortcut(.IDC_SHOW_BOOKMARK_BAR, to: toggleBookmarkBarItem)
                toggleBookmarkBarItem.target = self
                submenu.addItem(toggleBookmarkBarItem)
                let toggleBookmarkBarOnNewTabItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.showBookmarkBarOnNewTab", value: "Show Bookmark Bar on New Tab", comment: "View menu - Menu item to show the bookmark bar on new tab pages"),
                                                   action: #selector(toggleBookmarkBarOnNewTab(_:)),
                                                   keyEquivalent: "")
                toggleBookmarkBarOnNewTabItem.tag = AppController.toggleBookmarkBarOnNewTabItemTag
                toggleBookmarkBarOnNewTabItem.target = self
                submenu.addItem(toggleBookmarkBarOnNewTabItem)

                let sidebarSeparator = NSMenuItem.separator()
                sidebarSeparator.tag = AppController.viewMenuPhiSectionSeparatorTag
                submenu.addItem(sidebarSeparator)

                let toggleSidebarItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.toggleSidebar", value: "Toggle Sidebar", comment: "View menu - Menu item to show or hide the sidebar"),
                                                   action: #selector(toggleSidebar(_:)),
                                                   keyEquivalent: "s")
                toggleSidebarItem.keyEquivalentModifierMask = [.command]
                toggleSidebarItem.tag = CommandWrapper.PHI_TOGGLE_SIDEBAR.rawValue
                Shortcuts.updateShortcut(for: toggleSidebarItem)
                toggleSidebarItem.target = self
                submenu.addItem(toggleSidebarItem)

                let toggleChatbarItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.toggleChatbar", value: "Toggle Chat Panel", comment: "View menu - Menu item to show or hide the chat panel"),
                                                   action: #selector(toggleChatbar(_:)),
                                                   keyEquivalent: "e")
                toggleChatbarItem.keyEquivalentModifierMask = .command
                toggleChatbarItem.tag = CommandWrapper.PHI_TOGGLE_CHATBAR.rawValue
                Shortcuts.updateShortcut(for: toggleChatbarItem)
                toggleChatbarItem.target = self
                submenu.addItem(toggleChatbarItem)

                let switchChatPanelAndTabItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.switchChatPanelAndTab", value: "Switch Between Chat Panel and Tab", comment: "View menu and shortcuts - Go from the chat panel to the chat's own tab, or from a chat tab back to the tab whose chat panel shows it"),
                                                          action: #selector(switchChatPanelAndTab(_:)),
                                                          keyEquivalent: "")
                applyEffectiveShortcut(.PHI_SWITCH_CHAT_PANEL_AND_TAB, to: switchChatPanelAndTabItem)
                switchChatPanelAndTabItem.target = self
                submenu.addItem(switchChatPanelAndTabItem)

                let closeChatItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.closeChat", value: "Close Chat", comment: "View menu and shortcuts - Close the chat the focused tab's chat panel shows, with its tab; the panel closes too"),
                                               action: #selector(closePanelChat(_:)),
                                               keyEquivalent: "")
                applyEffectiveShortcut(.PHI_CLOSE_PANEL_CHAT, to: closeChatItem)
                closeChatItem.target = self
                submenu.addItem(closeChatItem)

                let newConversationItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.newConversation", value: "New Chat", comment: "View menu - Menu item to start a new Browser Agent chat in the chat panel"),
                                                   action: #selector(newConversation(_:)),
                                                   keyEquivalent: "o")
                newConversationItem.keyEquivalentModifierMask = [.command, .shift]
                newConversationItem.tag = CommandWrapper.PHI_NEW_CONVERSATION.rawValue
                Shortcuts.updateShortcut(for: newConversationItem)
                newConversationItem.target = self
                submenu.addItem(newConversationItem)

                // The agent view items follow the CDP master switch, not
                // developer mode: they matter exactly while agents can drive
                // the browser, and `AgentCDPListener.setEnabled` refreshes the
                // menu so they appear/disappear the moment the switch flips.
                if PhiPreferences.AgentSpaces.cdpAgentAccessEnabled {
                    let agentAutoViewSeparator = NSMenuItem.separator()
                    agentAutoViewSeparator.tag = AppController.viewMenuPhiSectionSeparatorTag
                    submenu.addItem(agentAutoViewSeparator)
                    let agentAutoViewItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.agentAutoview", value: "Agent Autoview", comment: "View menu - Toggle that automatically switches to the Space of an operating agent"),
                                                       action: #selector(toggleAgentAutoView(_:)),
                                                       keyEquivalent: "")
                    agentAutoViewItem.tag = AppController.agentAutoViewItemTag
                    agentAutoViewItem.target = self
                    submenu.addItem(agentAutoViewItem)

                    let agentTranscriptItem = NSMenuItem(title: NSLocalizedString("app.viewMenu.agentTranscript", value: "Agent Transcript", comment: "View menu - Toggle for the console mirroring the driving agent's session"),
                                                         action: #selector(toggleAgentTranscript(_:)),
                                                         keyEquivalent: "")
                    agentTranscriptItem.tag = AppController.agentTranscriptItemTag
                    agentTranscriptItem.target = self
                    submenu.addItem(agentTranscriptItem)
                }
            } else

            if menuRole == .app, let subMenu = menuItem.submenu {
                // "Import from Another Browser..." is built here rather than
                // by Chromium, which drops it under the Phi build flag: an item
                // Chromium builds is validated by its own command controller,
                // which the client cannot drive. It keeps the command
                // identifier as its tag, so the shortcut the user assigns to
                // that command still reaches it.
                // Remove-then-insert keeps this idempotent across menu rebuilds
                // (Chromium can swap the main menu wholesale).
                subMenu.items.removeAll {
                    $0.tag == CommandWrapper.IDC_IMPORT_SETTINGS.rawValue
                }
                let importItem = NSMenuItem(
                    title: NSLocalizedString("app.phiMenu.importFromAnotherBrowser", value: "Import from Another Browser...",
                        comment: "Phi menu - Menu item opening the window that imports bookmarks and settings from another browser"),
                    action: #selector(showImportDataWindowFromMenu(_:)),
                    keyEquivalent: ""
                )
                importItem.tag = CommandWrapper.IDC_IMPORT_SETTINGS.rawValue
                importItem.target = self
                Shortcuts.updateShortcut(for: importItem)
                if let clearBrowsingDataIndex = subMenu.items.firstIndex(where: {
                    $0.tag == CommandWrapper.IDC_CLEAR_BROWSING_DATA.rawValue
                }) {
                    subMenu.insertItem(importItem, at: clearBrowsingDataIndex + 1)
                } else {
                    subMenu.addItem(importItem)
                }

            } else

            if menuRole == .edit, let subMenu = menuItem.submenu {
                installOrUpdateCopyURLMenuItem(in: subMenu)
                installOrUpdateSelectionShortcuts(in: subMenu)
            } else

            if menuRole == .file, let subMenu = menuItem.submenu {
                Self.installOrUpdateFileMenuItems(in: subMenu, target: self)
            } else

            if menuRole == .window, let subMenu = menuItem.submenu {
                installOrUpdateWindowMenuItems(in: subMenu)
            } else

            if menuRole == .profiles {
                menuItem.isHidden = true
            }

            switch BookmarkMainMenuItemRouting.action(tag: menuItem.tag) {
            case .configureCustomItem:
                hasBookmarksMenu = true
                configureBookmarksMenuItem(menuItem)
            case .hideSystemItem:
                menuItem.isHidden = true
                clearKeyEquivalents(in: menuItem.submenu)
            case .ignore:
                break
            }

            if menuRole == .tab, let subMenu = menuItem.submenu {
                let hiddenCommandTags: Set<Int> = [
                    CommandWrapper.IDC_WINDOW_PIN_TAB.rawValue,
                    CommandWrapper.IDC_WINDOW_GROUP_TAB.rawValue,
                    CommandWrapper.IDC_MOVE_TAB_TO_NEW_WINDOW.rawValue,
                    CommandWrapper.IDC_WINDOW_CLOSE_OTHER_TABS.rawValue,
                    CommandWrapper.IDC_WINDOW_CLOSE_TABS_TO_RIGHT.rawValue
                ]
                subMenu.items.forEach { item in
                    if hiddenCommandTags.contains(item.tag) {
                        item.isHidden = true
                    }
                }
                Self.applyNewTabOrientation(in: subMenu)
                installOrUpdateStartPageMenuItems(in: subMenu)
                installOrUpdateUnpinAndCloseMenuItem(in: subMenu)
            } else

            if menuRole == .help, let subMenu = menuItem.submenu {
                // Remove existing custom items to avoid duplication on menu rebuild
                subMenu.items.removeAll {
                    $0.tag == AppController.extensionInfoItemTag ||
                    $0.tag == AppController.exportLogsItemTag ||
                    $0.tag == AppController.improveTranslationsItemTag ||
                    $0.tag == AppController.manageUserDataHelpSeparatorTag ||
                    $0.tag == AppController.timeMachineBackupsParentItemTag ||
                    $0.tag == AppController.manageUserDataParentItemTag
                }

                let extensionInfoItem = NSMenuItem(title: NSLocalizedString("app.helpMenu.extensionInfo", value: "Extension Info", comment: "Help menu - Menu item to show extension version info, only visible when holding Option key"),
                                                   action: #selector(showExtensionInfo(_:)),
                                                   keyEquivalent: "")
                extensionInfoItem.tag = AppController.extensionInfoItemTag
                extensionInfoItem.isHidden = true
                extensionInfoItem.target = self

                let exportLogsItem = NSMenuItem(title: NSLocalizedString("app.helpMenu.exportLogs", value: "Export Logs...", comment: "Help menu - Menu item to export Phi logs as a zip archive; visible only when holding Option key"),
                                                action: #selector(exportLogs(_:)),
                                                keyEquivalent: "")
                exportLogsItem.tag = AppController.exportLogsItemTag
                exportLogsItem.isHidden = true
                exportLogsItem.target = self

                if subMenu.items.count > 0 {
                    subMenu.insertItem(extensionInfoItem, at: 0)
                    subMenu.insertItem(exportLogsItem, at: 1)
                } else {
                    subMenu.addItem(extensionInfoItem)
                    subMenu.addItem(exportLogsItem)
                }

                let whatsNewItem = NSMenuItem(title: NSLocalizedString("app.helpMenu.whatsNew", value: "What's New", comment: "Help menu - Menu item that opens the chrome://whats-new page in a new tab, replacing 'Report an Issue'"),
                                              action: #selector(showWhatsNew(_:)),
                                              keyEquivalent: "")
                whatsNewItem.tag = AppController.whatsNewItemTag
                whatsNewItem.target = self
                if subMenu.item(withTag: AppController.reportIssueCommandTag) != nil {
                    subMenu.items.removeAll { $0.tag == AppController.whatsNewItemTag }
                }
                if let reportIssueIndex = subMenu.items.firstIndex(where: {
                    $0.tag == AppController.reportIssueCommandTag || $0.tag == AppController.whatsNewItemTag
                }) {
                    subMenu.removeItem(at: reportIssueIndex)
                    subMenu.insertItem(whatsNewItem, at: reportIssueIndex)
                } else {
                    subMenu.addItem(whatsNewItem)
                }

                let improveTranslationsItem = NSMenuItem(
                    title: NSLocalizedString(
                        "app.helpMenu.improveTranslations",
                        value: "Improve Translations for Phi Browser",
                        comment: "Help menu - Menu item below What's New that opens Phi's translation contribution website"
                    ),
                    action: #selector(showImproveTranslations(_:)),
                    keyEquivalent: ""
                )
                improveTranslationsItem.tag = AppController.improveTranslationsItemTag
                improveTranslationsItem.target = self
                if let whatsNewIndex = subMenu.items.firstIndex(where: {
                    $0.tag == AppController.whatsNewItemTag
                }) {
                    subMenu.insertItem(improveTranslationsItem, at: whatsNewIndex + 1)
                } else {
                    subMenu.addItem(improveTranslationsItem)
                }

                let userDataSeparator = NSMenuItem.separator()
                userDataSeparator.tag = AppController.manageUserDataHelpSeparatorTag
                subMenu.addItem(userDataSeparator)

                subMenu.addItem(makeTimeMachineBackupsMenuItem())

                let manageUserDataTitle = NSLocalizedString("app.helpMenu.manageUserData", value: "Manage User Data", comment: "Help menu - Parent menu item for exporting and importing Phi user data backup")
                let manageUserDataItem = NSMenuItem(title: manageUserDataTitle, action: nil, keyEquivalent: "")
                manageUserDataItem.tag = AppController.manageUserDataParentItemTag
                let userDataSubmenu = NSMenu(title: manageUserDataTitle)
                let exportUserDataItem = NSMenuItem(
                    title: NSLocalizedString("app.helpMenu.exportUserData", value: "Export User Data...", comment: "Help menu - Submenu item to save Phi user data folder as a zip backup"),
                    action: #selector(exportUserData(_:)),
                    keyEquivalent: ""
                )
                exportUserDataItem.target = self
                let importUserDataItem = NSMenuItem(
                    title: NSLocalizedString("app.helpMenu.importUserData", value: "Import User Data...", comment: "Help menu - Submenu item to replace Phi user data from a zip backup and relaunch the app"),
                    action: #selector(importUserDataFromBackup(_:)),
                    keyEquivalent: ""
                )
                importUserDataItem.target = self
                userDataSubmenu.addItem(exportUserDataItem)
                userDataSubmenu.addItem(importUserDataItem)
                manageUserDataItem.submenu = userDataSubmenu
                subMenu.addItem(manageUserDataItem)

                subMenu.delegate = self
            }
        }

        if !hasBookmarksMenu {
            installBookmarksMenu(in: mainMenu)
        }

        installOrUpdateSpacesMenu(in: mainMenu)
        MainActor.assumeIsolated { Self.installOrUpdateAppsMenu(in: mainMenu, target: self) }

        if mainMenu.items.first(where: { $0.tag == AppController.debugMenuItemTag }) == nil {
            let item = buildDebugMenuItem()
            if UserDefaults.standard.bool(forKey: PhiPreferences.phiMainDebugMenuEnabled.rawValue) == true {
                mainMenu.addItem(item)
            }
        }
    }

    /// Chromium's Tab menu carries two items for New Tab to the Right, and only
    /// their order tells them apart: both have the same tag, action and key
    /// equivalent, and their titles are Chromium-localized strings. The order
    /// comes from `BuildTabMenu` in chrome/browser/ui/cocoa/main_menu_builder.mm,
    /// which lists the "to the Right" title first and a hidden "New Tab Below"
    /// second. Upstream's `-[AppController onVerticalTabStripModeChanged:]`
    /// (chrome/browser/app_controller_mac.mm, copied into Phi's
    /// phi_app_controller_mac.mm) reads them the same way: [0] horizontal,
    /// [1] vertical. Keep the indices below in step with both; the count check
    /// cannot catch a reorder, which would only swap the titles shown.
    ///
    /// Upstream swaps them on its vertical tab strip mode, which Phi never
    /// turns on, so swap them on the layout mode: only Comfortable lays tabs
    /// out horizontally.
    static func applyNewTabOrientation(
        in tabMenu: NSMenu,
        layoutMode: LayoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
    ) {
        let items = tabMenu.items.filter {
            $0.tag == CommandWrapper.IDC_NEW_TAB_TO_RIGHT.rawValue
        }
        guard items.count == 2 else {
            AppLogWarn("Tab menu has \(items.count) New Tab to the Right items, expected 2; leaving them as built")
            return
        }
        // items[0] is "to the Right", items[1] is "New Tab Below".
        let vertical = !layoutMode.isTraditional
        items[0].isHidden = vertical
        items[1].isHidden = !vertical
    }

    /// A grouped tab's start page commands, after Chromium's Mute Site, Pin Tab and Group Tab rows. Sidebar layouts
    /// only, like the tab context menu: the horizontal strip shows no start page. Remove-then-insert keeps this
    /// idempotent across menu rebuilds.
    private func installOrUpdateStartPageMenuItems(
        in tabMenu: NSMenu,
        layoutMode: LayoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
    ) {
        let commands: [CommandWrapper] = [.PHI_RETURN_TO_START_PAGE, .PHI_SET_START_PAGE]
        tabMenu.items.removeAll { item in commands.contains { $0.rawValue == item.tag } }
        let anchorTags = [CommandWrapper.IDC_WINDOW_MUTE_SITE, .IDC_WINDOW_PIN_TAB, .IDC_WINDOW_GROUP_TAB].map(\.rawValue)
        var index = tabMenu.items.lastIndex { anchorTags.contains($0.tag) }.map { $0 + 1 } ?? tabMenu.items.count
        for command in commands {
            let title = command == .PHI_SET_START_PAGE
                ? NSLocalizedString("app.tabMenu.setStartPage", value: "Set Current Page as Start Page", comment: "Tab menu and shortcuts - Remember the focused grouped tab's current page as its start page")
                : NSLocalizedString("app.tabMenu.returnToStartPage", value: "Return to Start Page", comment: "Tab menu and shortcuts - Take the focused grouped tab back to its start page")
            let item = NSMenuItem(title: title, action: #selector(performStartPageCommandFromMenu(_:)), keyEquivalent: "")
            applyEffectiveShortcut(command, to: item)
            item.target = self
            item.isHidden = layoutMode.isTraditional
            tabMenu.insertItem(item, at: index)
            index += 1
        }
    }

    @MainActor @objc func performStartPageCommandFromMenu(_ sender: NSMenuItem) {
        guard let command = CommandWrapper(rawValue: sender.tag) else { return }
        SpaceSessionControllersManager.shared.getActiveWindowState()?.performStartPageCommand(command)
    }

    /// Unpin and Close, after the start page commands, in every layout. Remove-then-insert keeps this idempotent
    /// across menu rebuilds.
    private func installOrUpdateUnpinAndCloseMenuItem(in tabMenu: NSMenu) {
        let command = CommandWrapper.PHI_UNPIN_AND_CLOSE_TAB
        tabMenu.items.removeAll { $0.tag == command.rawValue }
        let anchorTags = [CommandWrapper.IDC_WINDOW_MUTE_SITE, .IDC_WINDOW_PIN_TAB, .IDC_WINDOW_GROUP_TAB,
                          .PHI_RETURN_TO_START_PAGE, .PHI_SET_START_PAGE].map(\.rawValue)
        let index = tabMenu.items.lastIndex { anchorTags.contains($0.tag) }.map { $0 + 1 } ?? tabMenu.items.count
        let item = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.unpinAndCloseTab", value: "Unpin and Close", comment: "Pinned tab context menu, Tab menu and shortcuts - Close the tab and remove its pin, where Close keeps the pin"),
                              action: #selector(unpinAndCloseFromMenu(_:)), keyEquivalent: "")
        applyEffectiveShortcut(command, to: item)
        item.target = self
        tabMenu.insertItem(item, at: index)
    }

    @MainActor @objc func unpinAndCloseFromMenu(_ sender: NSMenuItem) {
        SpaceSessionControllersManager.shared.getActiveWindowState()?.performUnpinAndCloseCommand()
    }

    static func installOrUpdateFileMenuItems(
        in subMenu: NSMenu,
        target: AppController?
    ) {
        subMenu.items.forEach { item in
            if item.tag == CommandWrapper.IDC_SAVE_PAGE.rawValue {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = .init(rawValue: 0)
                Shortcuts.updateShortcut(for: item)
            }
        }

        // Chromium's File menu ships its own Share submenu on macOS. Phi
        // replaces it with a single picker-backed item so sharing has one
        // owner (File menu and address bar menu both route through
        // PageSharingPresenter). The submenu parent is the only Chromium File
        // row without a command: its title is localized and its tag is not
        // stable across Chromium versions, but every other Chromium row
        // carries an IDC tag and dispatch action while separators identify
        // themselves — so tag 0 + no action + not a separator is the row.
        // Removal (not isHidden) so a Chromium-side menu refresh cannot
        // resurface it without rebuilding the menu, which re-runs this hook.
        // A row Chromium has hidden is not it: while no tabbed browser window
        // is key, the Close Window/Close Tab swap (PhiAppController
        // -updateMenuItemKeyEquivalents) parks the Shift-Cmd-W row hidden with
        // tag 0 and no action. This hook also re-runs on the live menu, and
        // deleting that row ends the swap: Cmd-W stays on Close Window.
        subMenu.items.removeAll { item in
            !item.isSeparatorItem && !item.isHidden && item.tag == 0
                && (item.action == nil || item.submenu != nil)
        }

        // The removed Share row sat between two separators; collapse the
        // resulting adjacent pair so the menu doesn't show a double divider.
        var separatorScanIndex = subMenu.items.count - 1
        while separatorScanIndex > 0 {
            if subMenu.items[separatorScanIndex].isSeparatorItem,
               subMenu.items[separatorScanIndex - 1].isSeparatorItem {
                subMenu.removeItem(at: separatorScanIndex)
            }
            separatorScanIndex -= 1
        }

        // Chromium can replace the main menu wholesale. Remove and reinsert
        // Phi's rows so rebuilding remains idempotent.
        subMenu.items.removeAll { item in
            item.tag == CommandWrapper.PHI_NEW_INCOGNITO_SPACE.rawValue
                || item.tag == CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue
                || item.tag == CommandWrapper.PHI_SHARE_PAGE.rawValue
                || item.action == #selector(AppController.copyFullPageScreenshotFromMenu(_:))
                || item.action == #selector(AppController.capturePageAreaFromMenu(_:))
        }

        let newIncognitoSpaceItem = NSMenuItem(
            title: NSLocalizedString(
                "app.fileMenu.createNewIncognitoSpace",
                value: "New Incognito Space",
                comment: "File menu and Shortcuts settings - Command title for creating a new Incognito Space"
            ),
            action: #selector(AppController.newIncognitoSpaceFromMenu(_:)),
            keyEquivalent: "n"
        )
        newIncognitoSpaceItem.keyEquivalentModifierMask = [.control, .shift]
        newIncognitoSpaceItem.tag = CommandWrapper.PHI_NEW_INCOGNITO_SPACE.rawValue
        Shortcuts.updateShortcut(for: newIncognitoSpaceItem)
        newIncognitoSpaceItem.target = target

        let insertionIndex = subMenu.items.firstIndex(where: {
            $0.tag == CommandWrapper.IDC_NEW_INCOGNITO_WINDOW.rawValue
        }).map { $0 + 1 } ?? subMenu.items.count
        subMenu.insertItem(newIncognitoSpaceItem, at: insertionIndex)

        let alternateNewTabItem = NSMenuItem(
            title: NSLocalizedString(
                "app.fileMenu.alternateNewTab",
                value: "Alternate New Tab",
                comment: "File menu and Shortcuts settings - Command title for opening the opposite of the configured New Tab action"
            ),
            action: #selector(AppController.alternateNewTabFromMenu(_:)),
            keyEquivalent: "t"
        )
        alternateNewTabItem.keyEquivalentModifierMask = [.command, .option]
        alternateNewTabItem.tag = CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue
        Shortcuts.updateShortcut(for: alternateNewTabItem)
        alternateNewTabItem.target = target

        let alternateInsertionIndex = subMenu.items.firstIndex(where: {
            $0.tag == CommandWrapper.IDC_NEW_TAB.rawValue
        }).map { $0 + 1 } ?? 0
        subMenu.insertItem(alternateNewTabItem, at: alternateInsertionIndex)

        let sharePageItem = NSMenuItem(
            title: NSLocalizedString(
                "app.fileMenu.sharePage",
                value: "Share\u{2026}",
                comment: "File menu - Share the current page via the macOS share picker"
            ),
            action: #selector(AppController.sharePageFromMenu(_:)),
            keyEquivalent: "s"
        )
        sharePageItem.keyEquivalentModifierMask = [.control, .option]
        sharePageItem.tag = CommandWrapper.PHI_SHARE_PAGE.rawValue
        Shortcuts.updateShortcut(for: sharePageItem)
        sharePageItem.target = target

        let screenshotItem = NSMenuItem(
            title: NSLocalizedString(
                "app.fileMenu.copyFullPageScreenshot",
                value: "Capture Full Page",
                comment: "File menu - Capture the entire current webpage and copy it as an image"
            ),
            action: #selector(AppController.copyFullPageScreenshotFromMenu(_:)),
            keyEquivalent: ""
        )
        screenshotItem.tag = CommandWrapper.PHI_CAPTURE_FULL_PAGE.rawValue
        Shortcuts.updateShortcut(for: screenshotItem)
        screenshotItem.target = target

        let areaScreenshotItem = NSMenuItem(
            title: NSLocalizedString("app.fileMenu.capturePageArea", value: "Capture Area…",
                                     comment: "File menu - Select a visible webpage area to capture and edit"),
            action: #selector(AppController.capturePageAreaFromMenu(_:)), keyEquivalent: "")
        areaScreenshotItem.tag = CommandWrapper.PHI_CAPTURE_AREA.rawValue
        Shortcuts.updateShortcut(for: areaScreenshotItem)
        areaScreenshotItem.target = target

        // Same slot Safari uses: directly above Print.
        if let printIndex = subMenu.items.firstIndex(where: {
            $0.tag == CommandWrapper.IDC_PRINT.rawValue
        }) {
            subMenu.insertItem(screenshotItem, at: printIndex)
            subMenu.insertItem(areaScreenshotItem, at: printIndex + 1)
            subMenu.insertItem(sharePageItem, at: printIndex + 2)
        } else {
            subMenu.addItem(screenshotItem)
            subMenu.addItem(areaScreenshotItem)
            subMenu.addItem(sharePageItem)
        }
    }

    fileprivate func rebuildDeleteProfileSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let deletable = ProfileManager.shared.profiles.filter { $0.profileId != LocalStore.defaultProfileId }
        guard !deletable.isEmpty else {
            let empty = NSMenuItem(
                title: NSLocalizedString("app.spacesMenu.deleteProfile.emptyPlaceholder", value: "No Profiles to Delete", comment: "Spaces menu - Delete Profile submenu empty state"),
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(empty)
            return
        }
        for profile in deletable {
            // Store-read, not the `spaces` cache — see `isProfileInUse`.
            let inUse = SpaceManager.shared.isProfileInUse(profile.profileId)
            let title: String
            if inUse {
                title = String(
                    format: NSLocalizedString("app.spacesMenu.deleteProfile.inUseLabel", value: "%@ — in use by a Space", comment: "Spaces menu - Delete Profile row label for a profile bound to a Space"),
                    profile.displayName
                )
            } else {
                title = profile.displayName
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(deleteSelectedProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile
            menu.addItem(item)
        }
    }

    @objc func newProfile(_ sender: Any?) {
        guard let name = ProfileNameFieldValidator.present(.create) else { return }
        ProfileManager.shared.createProfile(displayName: name) { _ in }
    }

    @MainActor @objc func deleteSelectedProfile(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let profile = menuItem.representedObject as? PhiBrowserProfile else {
            return
        }
        ProfileDeletionFlow.confirmAndDelete(profile)
    }

    private func configureBookmarksMenuItem(_ menuItem: NSMenuItem) {
        menuItem.title = NSLocalizedString("app.mainMenu.bookmarksConfiguredTitle", value: "Bookmarks", comment: "Main menu - Top-level Bookmarks menu title in the application menu bar")
        menuItem.tag = AppController.bookmarksMenuItemTag
        menuItem.isHidden = isActiveWindowIncognito()

        let submenu = menuItem.submenu ?? NSMenu(title: menuItem.title)
        submenu.identifier = AppController.bookmarksMenuIdentifier
        submenu.delegate = self
        menuItem.submenu = submenu

        rebuildBookmarksMenu(submenu)
    }

    private func clearKeyEquivalents(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            clearKeyEquivalents(in: item.submenu)
        }
    }

    private func installBookmarksMenu(in mainMenu: NSMenu) {
        let menuItem = NSMenuItem(
            title: NSLocalizedString("app.mainMenu.bookmarksInstalledTitle", value: "Bookmarks", comment: "Main menu - Top-level Bookmarks menu title in the application menu bar"),
            action: nil,
            keyEquivalent: ""
        )
        menuItem.tag = AppController.bookmarksMenuItemTag
        configureBookmarksMenuItem(menuItem)

        if let historyIndex = ChromiumMainMenuRole.history.index(in: mainMenu) {
            mainMenu.insertItem(menuItem, at: historyIndex + 1)
        } else if let windowIndex = ChromiumMainMenuRole.window.index(in: mainMenu) {
            mainMenu.insertItem(menuItem, at: windowIndex)
        } else {
            mainMenu.addItem(menuItem)
        }
    }

    private func makeTimeMachineBackupsMenuItem() -> NSMenuItem {
        let title = NSLocalizedString("app.helpMenu.timeMachineBackups", value: "Time Machine Backups", comment: "Help menu - Parent menu item listing completed Phi Time Machine backups")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = AppController.timeMachineBackupsParentItemTag

        let submenu = NSMenu(title: title)
        submenu.identifier = AppController.timeMachineBackupsMenuIdentifier
        submenu.delegate = self
        rebuildTimeMachineBackupsMenu(submenu)
        item.submenu = submenu
        return item
    }

    private func rebuildTimeMachineBackupsMenu(_ menu: NSMenu) {
        do {
            try TimeMachineMenuPresenter().populate(
                menu,
                target: self,
                action: #selector(restoreTimeMachineBackup(_:))
            )
        } catch {
            AppLogError("Time Machine backups menu failed: \(error.localizedDescription)")
            menu.removeAllItems()
            let item = NSMenuItem(
                title: NSLocalizedString("app.helpMenu.timeMachineBackupsUnavailablePlaceholder", value: "Backups Unavailable", comment: "Help menu - Time Machine submenu placeholder when the backup catalog cannot be read"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    private func rebuildBookmarksMenu(_ menu: NSMenu) {
        let bookmarks = SpaceSessionControllersManager.shared.activeWindowController?.browserState.bookmarkManager.rootFolder.children ?? []

        BookmarkMenuContentBuilder.populate(
            menu: menu,
            bookmarks: bookmarks,
            canBookmarkCurrentTab: canBookmarkCurrentTab(),
            canBookmarkAllTabs: canBookmarkAllTabs(),
            canExportBookmarks: canExportBookmarks(),
            target: self,
            bookmarkThisTabAction: #selector(bookmarkThisTab(_:)),
            bookmarkAllTabsAction: #selector(bookmarkAllTabs(_:)),
            bookmarkManagerAction: #selector(openBookmarkManager(_:)),
            exportBookmarksAction: #selector(exportBookmarks(_:)),
            openBookmarkAction: #selector(openBookmarkMenuItem(_:))
        )
    }

    private func isActiveWindowIncognito() -> Bool {
        SpaceSessionControllersManager.shared.activeWindowController?.browserState.isIncognito == true
    }

    /// Re-evaluates the menu-bar "Bookmarks" top-level item's visibility
    /// against the focused window. Called when the active window changes (see
    /// `.activeBrowserWindowDidChange`) so the menu drops out for off-the-record
    /// windows — standalone incognito and the Incognito Space — and returns
    /// for normal ones. Mirrors `refreshSpacesMenuVisibility`.
    @objc func refreshBookmarksMenuVisibility() {
        guard let item = NSApp.mainMenu?.items.first(where: {
            $0.tag == AppController.bookmarksMenuItemTag
        }) else { return }
        item.isHidden = isActiveWindowIncognito()
    }

    private func canBookmarkCurrentTab() -> Bool {
        guard !isActiveWindowIncognito() else { return false }
        guard let state = SpaceSessionControllersManager.shared
            .activeWindowController?.browserState,
              !state.isInPlaceholderMode,
              let tab = state.pageCommandTarget,
              let url = tab.url, !url.isEmpty else {
            return false
        }

        return true
    }

    private func canBookmarkAllTabs() -> Bool {
        guard !isActiveWindowIncognito() else { return false }
        let bookmarkableTabsCount = SpaceSessionControllersManager.shared.activeWindowController?.browserState.normalTabs.filter { !$0.isLocalPage }.count ?? 0
        return bookmarkableTabsCount > 1
    }

    /// Export is meaningful only when its output would be non-empty: the
    /// active Space's bookmark tree or the window's visible pinned
    /// collection has at least one item. Incognito windows never load a
    /// bookmark tree and keep `pinnedTabs` empty, so the predicate disables
    /// them too.
    private func canExportBookmarks() -> Bool {
        guard let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState else {
            return false
        }
        return BookmarkHTMLExporter.hasExportableContent(
            bookmarks: state.bookmarkManager.rootFolder.children,
            pinnedTabs: state.pinnedTabs)
    }

    private func installOrUpdateSelectionShortcuts(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                installOrUpdateSelectionShortcuts(in: submenu)
            }
            // These native actions arrive without command tags. Keep their
            // responder-chain routing while sharing configuration and inventory.
            switch item.action {
            case NSSelectorFromString("copyToFindPboard:"):
                applyEffectiveShortcut(.IDS_EDIT_USE_SELECTION_MAC, to: item)
            case NSSelectorFromString("centerSelectionInVisibleArea:"):
                applyEffectiveShortcut(.IDS_EDIT_JUMP_TO_SELECTION_MAC, to: item)
            default:
                break
            }
        }
    }

    private func installOrUpdateCopyURLMenuItem(in menu: NSMenu) {
        menu.items.removeAll { $0.tag == CommandWrapper.PHI_COPY_URL.rawValue }

        let item = NSMenuItem(
            title: NSLocalizedString("app.editMenu.copySelectedTabURLAction", value: "Copy URL", comment: "Edit menu - Copy the selected tab URL to the clipboard"),
            action: #selector(copySelectedTabURLs(_:)),
            keyEquivalent: ""
        )
        applyEffectiveShortcut(.PHI_COPY_URL, to: item)
        item.target = self

        if let copyIndex = menu.items.firstIndex(where: {
            $0.tag == CommandWrapper.IDC_CONTENT_CONTEXT_COPY.rawValue
        }) {
            menu.insertItem(item, at: copyIndex + 1)
        } else {
            menu.addItem(item)
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared
            .activeWindowController?.browserState else {
            return
        }
        state.toggleSidebar()
    }

    @objc func toggleChatbar(_ sendar: Any?) {
        guard let state = SpaceSessionControllersManager.shared
            .activeWindowController?.browserState else {
            return
        }
        state.toggleAIChat()
    }

    @MainActor
    @objc func toggleReaderView(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState,
              let tab = state.readerViewTarget(focusingTab: state.focusingTab) else {
            return
        }
        state.toggleReaderView(for: tab)
    }

    @MainActor
    @objc func openLibrary(_ sender: Any?) {
        guard let owner = SpaceSessionControllersManager.shared.activeWindowController,
              let source = owner.window?.contentView else { return }
        owner.showLibrary(from: source)
    }

    @MainActor
    @objc func copySelectedTabURLs(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState else {
            return
        }
        guard let copiedURLs = state.copySelectedTabURLs() else {
            return
        }
        OverlayToastCenter.shared.showURLCopyConfirmation(copiedURLs: copiedURLs, in: state)
    }

    @MainActor
    @objc func copyFullPageScreenshotFromMenu(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else { return }
        PageScreenshotService.shared.capture(in: state)
    }

    @MainActor
    @objc func capturePageAreaFromMenu(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else { return }
        PageScreenshotService.shared.capture(in: state, area: true)
    }

    @MainActor
    @objc func alternateNewTabFromMenu(_ sender: Any?) {
        // Mouse clicks and scripted actions can have a non-key event or no event.
        if let event = NSApp.currentEvent,
           event.type == .keyDown || event.type == .keyUp,
           event.isARepeat { return }
        SpaceSessionControllersManager.shared.activeWindowController?.newAlternateBrowserTab()
    }

    @MainActor
    @objc func sharePageFromMenu(_ sender: Any?) {
        SpaceSessionControllersManager.shared.activeWindowController?.sharePage(sender)
    }

    @MainActor @objc func switchChatPanelAndTab(_ sender: Any?) {
        guard let controller = SpaceSessionControllersManager.shared.activeWindowController else { return }
        MistChatPanelViewController.performPanelTabSwitch(in: controller)
    }

    @MainActor @objc func closePanelChat(_ sender: Any?) {
        guard let controller = SpaceSessionControllersManager.shared.activeWindowController else { return }
        MistChatPanelViewController.performCloseChat(in: controller)
    }

    /// Starts a new native chat in the focused page's panel.
    @MainActor
    @objc func newConversation(_ sender: Any?) {
        guard let windowController = SpaceSessionControllersManager.shared.activeWindowController,
              let tabId = windowController.browserState.focusingTab?.guid else {
            return
        }
        windowController.mainSplitViewController.webContentContainerViewController
            .findController(forTabId: tabId)?.newPanelChat()
    }

    @objc func toggleBookmarkBar(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue)
    }

    /// View ▸ Agent Autoview — follow the operating agent's Space while it
    /// works (see `AgentSpaceManager.autoViewReevaluate`). Turning it ON
    /// surfaces an already-running agent immediately.
    @objc func toggleAgentAutoView(_ sender: Any?) {
        let enabled = !PhiPreferences.AgentSpaces.autoViewEnabled
        PhiPreferences.AgentSpaces.autoViewEnabled = enabled
        if enabled {
            // Menu actions arrive on the main thread; the manager is main-actor.
            MainActor.assumeIsolated {
                AgentSpaceManager.shared.autoViewReevaluate()
            }
        }
    }

    /// View ▸ Agent Transcript — the console mirroring the driving
    /// code agent's session (live transcript + command prompt).
    @objc func toggleAgentTranscript(_ sender: Any?) {
        MainActor.assumeIsolated {
            AgentTranscriptPanelController.shared.toggle()
        }
    }

    @objc func toggleBookmarkBarOnNewTab(_ sender: Any?) {
        let currentValue = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
        UserDefaults.standard.set(!currentValue, forKey: PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.rawValue)
    }

    @objc func bookmarkThisTab(_ sender: Any?) {
        SpaceSessionControllersManager.shared.activeWindowController?.toggleBookmark(sender)
    }

    @objc func bookmarkAllTabs(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared.activeWindowController?.browserState else {
            return
        }

        let tabs = state.normalTabs
        guard !tabs.isEmpty else { return }
        for tab in tabs {
            if tab.isLocalPage { continue }
            let title = tab.title.isEmpty ? (tab.url ?? "") : tab.title
            let url = tab.url ?? ""
            guard !url.isEmpty else { continue }
            state.bookmarkManager.addBookmark(title: title,
                                              url: url,
                                              faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
        }
    }

    @objc func openBookmarkManager(_ sender: Any?) {
        guard let state = SpaceSessionControllersManager.shared
            .activeWindowController?.browserState,
              !state.isIncognito else {
            return
        }
        state.openTab(URLProcessor.processUserInput("phi://bookmarks"))
    }

    @objc func openBookmarkMenuItem(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let bookmark = item.representedObject as? Bookmark else {
            return
        }

        SpaceSessionControllersManager.shared.activeWindowController?.browserState.openBookmark(bookmark)
    }

    /// Bookmark-export writes still running on the background queue, and
    /// whether app termination is parked on confirmed bookmark or screenshot writes (`.terminateLater`).
    /// Main-thread only.
    static var inFlightBookmarkExportWrites = 0
    static var bookmarkExportTerminationPending = false

    /// Exports the active window's current Space's bookmark tree — preceded
    /// by a Favorites folder carrying the window's visible pinned tabs, when
    /// it has any — to a Netscape-format HTML file. The system save panel
    /// handles the same-name replace confirmation; the write is atomic so a
    /// mid-write failure leaves any existing file intact.
    @objc func exportBookmarks(_ sender: Any?) {
        guard let windowController = SpaceSessionControllersManager.shared.activeWindowController,
              let window = windowController.window else { return }
        let state = windowController.browserState
        guard BookmarkHTMLExporter.hasExportableContent(
            bookmarks: state.bookmarkManager.rootFolder.children,
            pinnedTabs: state.pinnedTabs) else { return }

        // Menu actions are dispatched on the main thread.
        let spaceName = MainActor.assumeIsolated {
            state.localStore.getAllSpaces()
                .first { $0.spaceId == state.spaceId }?.name ?? "Default"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = BookmarkHTMLExporter.defaultFilename(spaceName: spaceName,
                                                                          date: Date())
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // Read the tree and pinned collection at confirmation time, not
            // when the sheet was presented — edits made while the panel was
            // open must export.
            MainActor.assumeIsolated {
                try? BookmarkHTMLExporter.export(from: state, to: url, overwrite: true) { result in
                    if case .failure(let error) = result {
                        AppLogError("Bookmark export failed: \(error.localizedDescription)")
                        let alert = NSAlert()
                        alert.alertStyle = .critical
                        alert.messageText = NSLocalizedString("app.bookmarkExport.failure.title", value: "Could Not Export Bookmarks", comment: "Export bookmarks failure alert - title shown when writing the exported HTML file fails")
                        alert.informativeText = error.localizedDescription
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    @objc func selectLayoutMode(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }

        switch menuItem.tag {
        case AppController.layoutModeDefaultItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        case AppController.layoutModeNavigationAtTopItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        case AppController.layoutModeTraditionalItemTag:
            PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        default:
            break
        }
    }

    @objc func showWhatsNew(_ sender: Any?) {
        BrowserState.currentState()?.createTab("chrome://whats-new", focusAfterCreate: true)
    }

    @objc func showImproveTranslations(_ sender: Any?) {
        BrowserState.currentState()?.createTab(
            "https://i18n.phibrowser.com/",
            focusAfterCreate: true
        )
    }

    @objc func restoreTimeMachineBackup(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let backupIDString = menuItem.representedObject as? String,
              let backupID = UUID(uuidString: backupIDString) else {
            return
        }

        do {
            guard let details = try TimeMachineMenuPresenter().backupDetails(id: backupID) else {
                presentTimeMachineRestoreFailure(
                    NSLocalizedString("app.timeMachineRestore.backupUnavailableMessage", value: "The selected Time Machine backup is no longer available.", comment: "Help menu - Time Machine restore error when a selected backup disappears")
                )
                return
            }

            let backup = details.backup
            let backupTitle = backup.menuTitle()
            let snapshotSize = details.snapshotSizeBytes.map {
                timeMachineBackupSizeDescription($0)
            } ?? "…"
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("app.timeMachineBackup.details.title", value: "Time Machine Backup", comment: "Help menu - Title of the selected Time Machine backup details alert")
            alert.informativeText = timeMachineBackupDetailsInformativeText(
                backupTitle: backupTitle,
                snapshotSizeDescription: snapshotSize
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("app.timeMachineRestore.confirmation.restoreButton", value: "Restore", comment: "Help menu - Time Machine restore confirmation button"))
            alert.addButton(withTitle: NSLocalizedString("app.timeMachineRestore.confirmation.cancelButton", value: "Cancel", comment: "Time Machine restore - Cancel confirmation button"))
            alert.addButton(withTitle: NSLocalizedString("app.timeMachineBackup.details.deleteButton", value: "Delete Backup", comment: "Help menu - Button in the selected Time Machine backup details alert that starts deletion"))
            alert.buttons[2].hasDestructiveAction = true

            if details.snapshotSizeBytes == nil {
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = Result {
                        try TimeMachineCatalogStore().resolveSnapshotSizeBytes(id: backup.id)
                    }
                    DispatchQueue.main.async {
                        let resolvedSize: UInt64?
                        switch outcome {
                        case .success(let size):
                            resolvedSize = size
                        case .failure(let error):
                            AppLogError(
                                "[TimeMachine] Could not resolve backup size for \(backup.id.uuidString): "
                                    + error.localizedDescription
                            )
                            resolvedSize = nil
                        }
                        guard alert.window.isVisible else {
                            return
                        }
                        alert.informativeText = self.timeMachineBackupDetailsInformativeText(
                            backupTitle: backupTitle,
                            snapshotSizeDescription: self.timeMachineBackupSizeDescription(resolvedSize)
                        )
                    }
                }
            }

            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                deleteTimeMachineBackup(backup)
                return
            }
            guard response == .alertFirstButtonReturn else {
                return
            }

            let progressModal = TimeMachineRestoreProgressModal(backupTitle: backupTitle)
            DispatchQueue.main.async {
                Task {
                    let coordinator = TimeMachineRestoreCoordinator(progressHandler: { progress in
                        Task { @MainActor in
                            progressModal.update(progress)
                        }
                    })

                    do {
                        _ = try await coordinator.prepareAndLaunchRestore(for: backup)
                        await MainActor.run {
                            progressModal.finish(outcome: .success(()), response: .OK)
                        }
                    } catch {
                        await MainActor.run {
                            progressModal.finish(outcome: .failure(error), response: .abort)
                        }
                    }
                }
            }

            _ = progressModal.run()
            switch progressModal.outcome {
            case .some(.success):
                NSApp.terminate(nil)
            case .some(.failure(let error)):
                let messageTemplate = NSLocalizedString("app.timeMachineRestore.launchFailureMessage", value: "Phi could not start Time Machine restore: %@",
                    comment: "Help menu - Time Machine restore launch failure body"
                )
                presentTimeMachineRestoreFailure(String(format: messageTemplate, error.localizedDescription))
            case .none:
                break
            }
        } catch {
            let messageTemplate = NSLocalizedString("app.timeMachineRestore.catalogReadFailureMessage", value: "Phi could not read Time Machine backups: %@",
                comment: "Help menu - Time Machine restore catalog read failure body"
            )
            presentTimeMachineRestoreFailure(String(format: messageTemplate, error.localizedDescription))
        }
    }

    private func timeMachineBackupDetailsInformativeText(
        backupTitle: String,
        snapshotSizeDescription: String
    ) -> String {
        let messageTemplate = NSLocalizedString("app.timeMachineRestore.confirmation.message", value: "Phi will quit and restore %@. The current app and selected user data will be replaced.",
            comment: "Help menu - Time Machine restore confirmation body"
        )
        let dataSizeTemplate = NSLocalizedString("app.timeMachineBackup.details.dataSize", value: "Backup data size: %@", comment: "Help menu - Selected Time Machine backup logical data size; placeholder is a formatted byte count or an unavailable label")
        return [
            String(format: messageTemplate, backupTitle),
            String(format: dataSizeTemplate, snapshotSizeDescription)
        ].joined(separator: "\n\n")
    }

    private func timeMachineBackupSizeDescription(_ sizeBytes: UInt64?) -> String {
        guard let sizeBytes else {
            return NSLocalizedString("app.timeMachineBackup.details.dataSizeUnavailable", value: "Unavailable", comment: "Help menu - Fallback shown when a Time Machine backup's logical data size was not recorded")
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: sizeBytes),
            countStyle: .file
        )
    }

    private func deleteTimeMachineBackup(_ backup: TimeMachineBackupRecord) {
        let backupTitle = backup.menuTitle()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("app.timeMachineBackup.deleteConfirmation.title", value: "Delete Time Machine Backup?", comment: "Help menu - Title of the Time Machine backup deletion confirmation")
        let messageTemplate = NSLocalizedString("app.timeMachineBackup.deleteConfirmation.message", value: "Deleting %@ will permanently remove this restore point. Your current Phi app and data will not be affected. This cannot be undone.", comment: "Help menu - Time Machine backup deletion confirmation; placeholder is the selected backup title")
        alert.informativeText = String(format: messageTemplate, backupTitle)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("app.timeMachineBackup.deleteConfirmation.deleteButton", value: "Delete", comment: "Help menu - Destructive button that confirms Time Machine backup deletion"))
        alert.addButton(withTitle: NSLocalizedString("app.timeMachineBackup.deleteConfirmation.cancelButton", value: "Cancel", comment: "Help menu - Button that cancels Time Machine backup deletion"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let progressModal = TimeMachineBackupDeletionProgressModal(backupTitle: backupTitle)
        DispatchQueue.main.async {
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result {
                    try TimeMachineCatalogStore().deleteBackupAtUserRequest(id: backup.id)
                }
                DispatchQueue.main.async {
                    progressModal.finish(outcome: outcome)
                }
            }
        }
        _ = progressModal.run()

        switch progressModal.outcome {
        case .success(.some(_)):
            AppLogInfo("[TimeMachine] Deleted backup \(backup.id.uuidString) at the user's request.")
        case .success(.none):
            presentTimeMachineBackupDeletionFailure(
                NSLocalizedString("app.timeMachineBackup.deleteFailure.backupUnavailableMessage", value: "The selected Time Machine backup is no longer available.", comment: "Help menu - Time Machine backup deletion error when the selected backup disappears")
            )
        case .failure(let error):
            let messageTemplate = NSLocalizedString("app.timeMachineBackup.deleteFailure.message", value: "Phi could not delete the Time Machine backup: %@", comment: "Help menu - Time Machine backup deletion failure body; placeholder is the error description")
            presentTimeMachineBackupDeletionFailure(String(format: messageTemplate, error.localizedDescription))
        case .none:
            presentTimeMachineBackupDeletionFailure(
                NSLocalizedString("app.timeMachineBackup.deleteFailure.interruptedMessage", value: "The Time Machine backup deletion was interrupted.", comment: "Help menu - Time Machine backup deletion error when the deletion progress ends without a result")
            )
        }
    }

    private func presentTimeMachineBackupDeletionFailure(_ message: String) {
        AppLogError("Time Machine backup deletion failed: \(message)")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("app.timeMachineBackup.deleteFailure.title", value: "Time Machine Backup Deletion Failed", comment: "Help menu - Time Machine backup deletion failure alert title")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("app.timeMachineBackup.deleteFailure.dismissButton", value: "OK", comment: "Help menu - Button that dismisses a Time Machine backup deletion failure"))
        alert.runModal()
    }

    private func presentTimeMachineRestoreFailure(_ message: String) {
        AppLogError("Time Machine restore failed: \(message)")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("app.timeMachineRestore.failure.title", value: "Time Machine Restore Failed", comment: "Help menu - Time Machine restore failure alert title")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("app.timeMachineRestore.failure.dismissButton", value: "OK", comment: "Time Machine restore - Failure alert dismiss button"))
        alert.runModal()
    }

    @objc func exportLogs(_ sender: Any?) {
        let phiLogsURL = URL(fileURLWithPath: FileSystemUtils.phiBrowserDataDirectory(), isDirectory: true)
            .appendingPathComponent("PhiLogs", isDirectory: true)
        let fm = FileManager.default
        let hasPhi = fm.fileExists(atPath: phiLogsURL.path)
        guard hasPhi else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("app.logExport.noLogsFound.title", value: "Export Logs", comment: "Help menu - Log export alert title when no log folders exist")
            alert.informativeText = NSLocalizedString("app.logExport.noLogsFound.message", value: "No Phi log folder was found.", comment: "Help menu - Log export alert when the PhiLogs directory is missing")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("app.logExport.noLogsFound.dismissButton", value: "OK", comment: "Log export - No-log-folders alert dismiss button"))
            alert.runModal()
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Mist_Logs_\(formatter.string(from: Date())).zip"
        panel.title = NSLocalizedString("app.logExport.savePanel.title", value: "Export Logs", comment: "Help menu - NSSavePanel window title for saving the log export zip")
        panel.prompt = NSLocalizedString("app.logExport.savePanel.exportButton", value: "Export", comment: "Help menu - NSSavePanel primary button title for confirming log export save location")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let destURL = panel.url else { return }
            do {
                try self.zipPhiLogsExport(
                    phiLogsURL: phiLogsURL,
                    destinationZIP: destURL
                )
            } catch {
                AppLogError("Log export failed: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("app.logExport.failure.title", value: "Export Failed", comment: "Help menu - Log export error alert title")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("app.logExport.failure.dismissButton", value: "OK", comment: "Log export - Failure alert dismiss button"))
                alert.runModal()
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func zipPhiLogsExport(
        phiLogsURL: URL,
        destinationZIP: URL
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PhiLogExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let dest = staging.appendingPathComponent("PhiLogs", isDirectory: true)
        try fm.copyItem(at: phiLogsURL, to: dest)

        if fm.fileExists(atPath: destinationZIP.path) {
            try fm.removeItem(at: destinationZIP)
        }

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destinationZIP.path, "PhiLogs"]
        process.currentDirectoryURL = staging
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "zip exited with status \(process.terminationStatus)." : errText
            throw NSError(domain: "PhiLogExport", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    @objc func showExtensionInfo(_ sender: Any?) {
        let versionsDict = SpaceSessionControllersManager.shared.activeWindowController?.browserState.extensionManager.phiExtensionVersions

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("app.extensionInfoAlert.title", value: "Extension Info", comment: "Extension info alert - Title of the alert showing extension version information")

        let informativeText: String
        if let dict = versionsDict, !dict.isEmpty {
            let lines = dict.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key): \($0.value)" }
            informativeText = lines.joined(separator: "\n")
        } else {
            informativeText = NSLocalizedString("app.extensionInfoAlert.emptyMessage", value: "No extensions found or versions unavailable.", comment: "Extension info alert - Fallback when no extension versions are available")
        }

        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("app.extensionInfoAlert.dismissButton", value: "OK", comment: "Extension info alert - OK button to dismiss the alert"))
        alert.runModal()
    }

    // MARK: - Spaces top-level menu

    /// Whether the menu-bar "Spaces" top-level menu should be visible. Hidden
    /// when the Spaces feature is off, and hidden when the focused window
    /// doesn't participate in Spaces — standalone incognito windows expose no
    /// Spaces, matching the suppressed sidebar strip and the off-the-record
    /// "Open Link In Space" menu. The Incognito Space's window IS a
    /// Space, so the menu stays (its mutating items are disabled separately
    /// in `validateUserInterfaceItem`). `!= false` keeps the no-window case
    /// showing the menu, as before.
    private var shouldShowSpacesMenu: Bool {
        PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && SpaceSessionControllersManager.shared
                .activeWindowController?.browserState.participatesInSpaces != false
    }

    /// True while the menu-bar Spaces menu is tracking. A Space-list change
    /// arriving mid-track defers its rebuild to `menuDidClose` rather than
    /// swapping the items out from under the pointer.
    fileprivate static var isSpacesMenuTracking = false

    /// A Space-list change that arrived while the menu was tracking and still
    /// has to be applied.
    fileprivate static var spacesMenuNeedsRebuild = false

    /// The Space list changed order — a Space created, deleted or reordered,
    /// or (far more often) an agent Space appearing or ending. Rebuilds the
    /// installed Spaces menu immediately.
    ///
    /// Space items cache their IDs and positions. Refresh them when the list
    /// changes so every installed presentation stays current.
    ///
    /// Only ever refreshes a menu that is already installed: this can fire
    /// from `SpaceManager`'s first store read, which happens before the main
    /// menu is hooked (and touching it that early is the documented startup
    /// crash in `bind`).
    @objc func spaceListDidChange() {
        // The post rides `SpaceManager`'s own thread. Every writer of `spaces`
        // is on main today, so this hop is a guard rail rather than a hot path
        // — but it is AppKit on the other side of it.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.spaceListDidChange() }
            return
        }
        guard let submenu = NSApp.mainMenu?.items
            .first(where: { $0.tag == AppController.spacesMenuItemTag })?
            .submenu else { return }
        guard !AppController.isSpacesMenuTracking else {
            AppController.spacesMenuNeedsRebuild = true
            return
        }
        rebuildSpacesMenu(submenu)
    }

    /// Re-evaluates the menu-bar "Spaces" top-level item's visibility against
    /// the focused window. Called when the active window changes (see
    /// `.activeBrowserWindowDidChange`) so the menu drops out for incognito
    /// windows and returns for normal ones.
    @objc func refreshSpacesMenuVisibility() {
        NSApp.mainMenu?.items.first { $0.tag == AppController.spacesMenuItemTag }?.isHidden = !shouldShowSpacesMenu
        NSApp.mainMenu?.items.first { $0.tag == AppController.appsMenuItemTag }?.isHidden =
            SpaceSessionControllersManager.shared.getActiveWindowState()?.isIncognito == true
    }

    @MainActor static func installOrUpdateAppsMenu(in mainMenu: NSMenu, target: AppController?) {
        let item = mainMenu.items.first { $0.tag == appsMenuItemTag } ?? NSMenuItem()
        if item.menu != nil { mainMenu.removeItem(item) }
        item.title = NSLocalizedString("app.mainMenu.apps", value: "Apps", comment: "Main menu - Top-level Apps menu title")
        item.tag = appsMenuItemTag
        item.isHidden = SpaceSessionControllersManager.shared.getActiveWindowState()?.isIncognito == true
        let submenu = item.submenu ?? NSMenu(title: item.title)
        submenu.removeAllItems()
        for app in MistApps.all {
            let row = NSMenuItem(title: app.id.name, action: #selector(openMistApp(_:)), keyEquivalent: "")
            row.target = target
            row.representedObject = app.id.rawValue
            row.tag = app.openCommand.rawValue
            let icon = app.icon(nil)
            row.image = NSImage(named: icon.asset)?.copy() as? NSImage
            row.image?.size = NSSize(width: 16, height: 16)
            row.image?.isTemplate = icon.isTemplate
            Shortcuts.updateShortcut(for: row)
            submenu.addItem(row)
        }
        submenu.addItem(.separator())
        let newChat = NSMenuItem(
            title: NSLocalizedString("app.mainMenu.apps.newDrifterChat", value: "New Drifter Chat", comment: "Apps menu and shortcuts - Start a new empty Drifter chat"),
            action: #selector(newDrifterChatFromMenu(_:)), keyEquivalent: "")
        newChat.tag = CommandWrapper.PHI_NEW_DRIFTER_CHAT.rawValue
        newChat.target = target
        newChat.image = NSImage(named: DrifterApp.logo)?.copy() as? NSImage
        newChat.image?.size = NSSize(width: 16, height: 16)
        Shortcuts.updateShortcut(for: newChat)
        submenu.addItem(newChat)
        item.submenu = submenu
        let index = mainMenu.items.firstIndex { $0.tag == spacesMenuItemTag }.map { $0 + 1 } ?? mainMenu.items.count
        mainMenu.insertItem(item, at: index)
    }

    private func installOrUpdateWindowMenuItems(in menu: NSMenu) {
        let command = CommandWrapper.PHI_MAKE_PRIMARY_WINDOW
        for item in menu.items where item.tag == command.rawValue { menu.removeItem(item) }
        let item = NSMenuItem(
            title: NSLocalizedString("app.windowMenu.makePrimaryWindow", value: "Make Primary Window", comment: "Window menu item for making the focused window primary"),
            action: #selector(makePrimaryWindowFromMenu(_:)), keyEquivalent: "")
        item.tag = command.rawValue
        item.target = self
        Shortcuts.updateShortcut(for: item)
        let anchor = menu.items.firstIndex { $0.action == #selector(NSWindow.performZoom(_:)) }
            ?? menu.items.firstIndex { $0.tag == CommandWrapper.IDC_MINIMIZE_WINDOW.rawValue }
        menu.insertItem(item, at: anchor.map { $0 + 1 } ?? 0)
    }

    @objc func makePrimaryWindowFromMenu(_ sender: Any?) {
        if let slot = SpaceSessionControllersManager.shared.activeWindowController?.slot {
            SpaceManager.shared.markPrimary(slot)
        }
    }

    /// Finds the existing Spaces top-level menu item by tag and refreshes its
    /// submenu, or installs a new one right after the View menu when this is
    /// the first time the main menu has been hooked (or after Chromium swapped
    /// the menu wholesale).
    private func installOrUpdateSpacesMenu(in mainMenu: NSMenu) {
        let menuItem: NSMenuItem
        let isNew: Bool
        if let existing = mainMenu.items.first(where: { $0.tag == AppController.spacesMenuItemTag }) {
            menuItem = existing
            isNew = false
        } else {
            menuItem = NSMenuItem(
                title: NSLocalizedString("app.mainMenu.spaces", value: "Spaces", comment: "Main menu - Top-level Spaces menu title in the application menu bar"),
                action: nil,
                keyEquivalent: ""
            )
            menuItem.tag = AppController.spacesMenuItemTag
            isNew = true
        }

        let submenu = menuItem.submenu ?? NSMenu(title: menuItem.title)
        submenu.identifier = AppController.spacesMenuIdentifier
        submenu.delegate = self
        submenu.autoenablesItems = true
        menuItem.submenu = submenu
        menuItem.isHidden = !shouldShowSpacesMenu

        // Hooking the main menu ends any tracking session this delegate was
        // waiting on — Chromium can swap the whole menu out from under an open
        // one, and its `menuDidClose` would never arrive to clear the flag,
        // parking every later rebuild behind a menu that is already gone.
        AppController.isSpacesMenuTracking = false
        AppController.spacesMenuNeedsRebuild = false
        rebuildSpacesMenu(submenu)

        if isNew {
            let insertIndex: Int
            if let viewIdx = ChromiumMainMenuRole.view.index(in: mainMenu) {
                insertIndex = viewIdx + 1
            } else if let historyIdx = ChromiumMainMenuRole.history.index(in: mainMenu) {
                insertIndex = historyIdx
            } else {
                insertIndex = mainMenu.items.count
            }
            mainMenu.insertItem(menuItem, at: insertIndex)
        }
    }

    /// Populates the Spaces submenu from `SpaceManager.shared`. Called from
    /// `installOrUpdateSpacesMenu` after a main-menu swap and from
    /// `menuWillOpen` so each open reflects the current Spaces list and the
    /// active Space of the focused window.
    /// Appends the active-Space actions (Rename, Edit Theme, Change Profile,
    /// plus Change Icon when multiple Spaces exist) to `menu`, so other context
    /// menus — e.g. the sidebar / tab-area menu — can offer the same Space
    /// controls as the Spaces menu.
    /// Items target the controller and act on the currently active Space.
    func appendActiveSpaceMenuItems(
        to menu: NSMenu,
        browserState: BrowserState? = nil,
        triggerScreenPoint: NSPoint? = nil
    ) {
        let targetSlot = browserState?.windowController?.slot ?? currentSpacesSlot()
        let activeSpaceId = targetSlot?.activeSpaceId ?? SpaceManager.shared.activeSpaceId
        let activeSpace = SpaceManager.shared.spaces.first { $0.spaceId == activeSpaceId }
        let showsChangeIconItem = SpaceManager.shared.spaces.count > 1

        let newSpaceItem = NSMenuItem(
            title: NSLocalizedString("app.activeSpaceContextMenu.newSpaceAction", value: "New Space\u{2026}", comment: "Active Space context menu - Create a new Space"),
            action: #selector(newSpaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newSpaceItem.target = self
        menu.addItem(newSpaceItem)

        let renameItem = NSMenuItem(
            title: NSLocalizedString("app.activeSpaceContextMenu.renameSpaceAction", value: "Rename Space\u{2026}", comment: "Active Space context menu - Rename the active Space"),
            action: #selector(renameActiveSpace(_:)),
            keyEquivalent: ""
        )
        renameItem.target = self
        menu.addItem(renameItem)

        let changeIconItem: NSMenuItem?
        if showsChangeIconItem {
            let item = NSMenuItem(
                title: NSLocalizedString("app.tabAreaMenu.changeIcon", value: "Change Icon\u{2026}", comment: "Tab-area menu - opens the icon/emoji picker below the active Space's icon"),
                action: #selector(requestActiveSpaceIconPicker(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            changeIconItem = item
        } else {
            changeIconItem = nil
        }

        let editThemeItem = NSMenuItem(
            title: NSLocalizedString("app.activeSpaceContextMenu.themeSubmenuTitle", value: "Edit Theme", comment: "Active Space context menu - opens the theme editor for the active Space"),
            action: #selector(requestActiveSpaceThemeEditor(_:)),
            keyEquivalent: ""
        )
        editThemeItem.target = self
        editThemeItem.representedObject = SpaceThemeEditorMenuContext(
            browserState: browserState,
            placement: triggerScreenPoint.map(SpaceThemeEditorPanelPlacement.nearTrigger)
                ?? .windowTop
        )
        menu.addItem(editThemeItem)

        let changeProfileParent = NSMenuItem(
            title: NSLocalizedString("app.activeSpaceContextMenu.profileSubmenuTitle", value: "Change Profile", comment: "Active Space context menu - Submenu to re-bind the active Space to another profile"),
            action: nil,
            keyEquivalent: ""
        )
        changeProfileParent.submenu = makeSpacesProfileSubmenu(for: activeSpace)
        menu.addItem(changeProfileParent)

        let deleteSpaceItem = NSMenuItem(
            title: NSLocalizedString("app.activeSpaceContextMenu.deleteSpaceAction", value: "Delete Space\u{2026}", comment: "Active Space context menu - Delete the active Space"),
            action: #selector(deleteActiveSpace(_:)),
            keyEquivalent: ""
        )
        deleteSpaceItem.target = self
        menu.addItem(deleteSpaceItem)

        // An Incognito Space's own action: close its windows and tear the
        // Space itself down (confirmed in `requestCloseIncognitoSpace`).
        // Appended only while one IS the active Space — this builder runs on
        // every menu open, so the conditional presence stays fresh.
        if let activeSpaceId = activeSpace?.spaceId, SpaceManager.isIncognitoSpaceId(activeSpaceId) {
            menu.addItem(.separator())
            let closeSpaceItem = NSMenuItem(
                title: NSLocalizedString("app.spacesMenu.closeActiveIncognitoSpace", value: "Close Incognito Space", comment: "Spaces menu - close the active Incognito Space's windows and end it"),
                action: #selector(closeIncognitoSpaceFromMenu(_:)),
                keyEquivalent: ""
            )
            closeSpaceItem.target = self
            menu.addItem(closeSpaceItem)
        }

        // While the agent controls this Space, disable the actions that would
        // mutate its workspace. New Space is left enabled (it doesn't touch the
        // agent Space).
        if focusedSpaceIsAgentControlled() {
            [renameItem, changeIconItem, editThemeItem, changeProfileParent, deleteSpaceItem]
                .compactMap { $0 }
                .forEach(Self.disableAgentLockedMenuItem)
        } else if focusedSpaceIsAgentSpace() {
            // The user took control, so most edits are allowed again — but
            // re-profiling replaces the Space's windows and would break the
            // agent, so Change Profile stays disabled for any agent Space.
            Self.disableAgentLockedMenuItem(changeProfileParent)
        }
    }

    /// Greys out a menu item that acts on an agent-controlled Space. Clearing
    /// the action/target (and any submenu) makes AppKit's automatic menu
    /// enabling disable it, so it reads as unavailable rather than vanishing.
    private static func disableAgentLockedMenuItem(_ item: NSMenuItem) {
        item.action = nil
        item.target = nil
        item.submenu = nil
        item.isEnabled = false
    }

    /// Fills `menu` with one item per Space — its icon and a checkmark on the active one — that switches the focused window to
    /// that Space, plus a trailing "New Space" item. Drives the horizontal tab
    /// strip's active-Space chip, whose left-click presents this as a switcher
    /// menu (the menu rendition of the old switcher popover; hovering the chip
    /// shows the Space hover card instead), and the sidebar strip's "…" overflow
    /// affordance, so both layouts share one switcher UI. Items target the
    /// controller and reuse the Spaces menu's activate / create actions, so
    /// switching here behaves exactly like the menu-bar Spaces menu.
    func populateSpaceSwitcherMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let activeSpaceId = currentActiveSpace()?.spaceId

        for (index, space) in currentPresentedSpaces().enumerated() {
            let item = NSMenuItem(
                title: space.name,
                action: #selector(activateSpaceFromMenu(_:)),
                keyEquivalent: ""
            )
            if let command = CommandWrapper.spaceSelectionCommand(at: index) {
                applyEffectiveShortcut(command, to: item)
            }
            item.target = self
            item.representedObject = space.spaceId
            item.state = (space.spaceId == activeSpaceId) ? .on : .off
            item.image = spaceMenuIcon(for: space)
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
            #endif
            menu.addItem(item)
        }

        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }
        let newSpaceItem = NSMenuItem(
            title: NSLocalizedString("app.spaceSwitcherMenu.newSpaceAction", value: "New Space\u{2026}", comment: "Space switcher menu - Create a new Space"),
            action: #selector(newSpaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newSpaceItem.target = self
        newSpaceItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(newSpaceItem)
    }

    /// A menu-ready icon for a Space row. A Space with a live agent task wears
    /// the driving agent's brand icon — the same render-time override as the
    /// strip's pip (`SpacesStripView.pipIcon`), so the menu and the switcher
    /// agree on who is working; the Space's stored robot signature stays
    /// untouched. Always called on the main thread during menu tracking, but
    /// this synchronous menu-build path isn't `@MainActor`-isolated, so assume
    /// the isolation the helpers require rather than ripple the annotation
    /// through it.
    private func spaceMenuIcon(for space: Space) -> NSImage? {
        MainActor.assumeIsolated {
            guard let task = AgentSpaceManager.shared.tasksBySpaceId[space.spaceId] else {
                return SpaceIconView.menuImage(for: space.iconName)
            }
            let badge = AgentDriverBadge.make(agentName: task.agentName)
            if let asset = badge.assetName,
               let image = NSImage(named: asset)?.copy() as? NSImage {
                // Menu glyphs are 16pt; the brand assets pad their ink to
                // `assetInkRatio` of the canvas, so size the canvas up for the
                // INK to match. Copied first — NSImage(named:) is a shared
                // cache instance.
                let canvas = 16 / AgentDriverBadge.assetInkRatio
                image.size = NSSize(width: canvas, height: canvas)
                return image
            }
            return NSImage(systemSymbolName: badge.symbol,
                           accessibilityDescription: badge.label)
        }
    }

    private func applyEffectiveShortcut(_ command: CommandWrapper, to item: NSMenuItem) {
        item.tag = command.rawValue
        guard let key = Shortcuts.key(for: command) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = .init(rawValue: 0)
            return
        }
        let menuKey = key.menuKeyEquivalent
        item.keyEquivalent = menuKey.characters
        item.keyEquivalentModifierMask = menuKey.modifiers
    }

    fileprivate func rebuildSpacesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let activeSpace = currentActiveSpace()
        let activeSpaceId = activeSpace?.spaceId
        let showsChangeIconItem = SpaceManager.shared.spaces.count > 1

        let newSpaceItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.newSpace", value: "New Space\u{2026}", comment: "Spaces menu - Create a new Space"),
            action: #selector(newSpaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newSpaceItem.tag = AppController.spacesNewSpaceItemTag
        newSpaceItem.target = self
        menu.addItem(newSpaceItem)

        let renameItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.renameSpace", value: "Rename Space\u{2026}", comment: "Spaces menu - Rename the active Space"),
            action: #selector(renameActiveSpace(_:)),
            keyEquivalent: ""
        )
        renameItem.tag = AppController.spacesRenameItemTag
        renameItem.target = self
        menu.addItem(renameItem)

        let changeIconItem: NSMenuItem?
        if showsChangeIconItem {
            let item = NSMenuItem(
                title: NSLocalizedString("app.spacesMenu.changeIcon", value: "Change Icon\u{2026}", comment: "Spaces menu - opens the icon/emoji picker below the active Space's icon"),
                action: #selector(requestActiveSpaceIconPicker(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            changeIconItem = item
        } else {
            changeIconItem = nil
        }

        let editThemeItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.changeTheme", value: "Edit Theme", comment: "Spaces menu - opens the theme editor for the active Space"),
            action: #selector(requestActiveSpaceThemeEditor(_:)),
            keyEquivalent: ""
        )
        editThemeItem.tag = AppController.spacesChangeThemeParentTag
        editThemeItem.target = self
        editThemeItem.representedObject = SpaceThemeEditorMenuContext(
            browserState: nil,
            placement: .windowTop
        )
        menu.addItem(editThemeItem)

        let changeProfileParent = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.changeProfile", value: "Change Profile", comment: "Spaces menu - Submenu to re-bind the active Space to another profile"),
            action: nil,
            keyEquivalent: ""
        )
        changeProfileParent.tag = AppController.spacesChangeProfileParentTag
        changeProfileParent.submenu = makeSpacesProfileSubmenu(for: activeSpace)
        menu.addItem(changeProfileParent)

        let deleteSpaceItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.deleteSpace", value: "Delete Space\u{2026}", comment: "Spaces menu - Delete the active Space"),
            action: #selector(deleteActiveSpace(_:)),
            keyEquivalent: ""
        )
        deleteSpaceItem.tag = AppController.spacesDeleteSpaceItemTag
        deleteSpaceItem.target = self
        menu.addItem(deleteSpaceItem)

        // While the agent controls this Space, disable the actions that would
        // mutate its workspace (mirrors the tab-area context menu). New Space
        // and the Next/Previous switchers below stay enabled.
        if focusedSpaceIsAgentControlled() {
            [renameItem, changeIconItem, editThemeItem, changeProfileParent, deleteSpaceItem]
                .compactMap { $0 }
                .forEach(Self.disableAgentLockedMenuItem)
        } else if focusedSpaceIsAgentSpace() {
            // Change Profile stays disabled for an agent Space even after the
            // user takes control — re-profiling would break the running agent.
            Self.disableAgentLockedMenuItem(changeProfileParent)
        }

        menu.addItem(.separator())

        let nextItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.nextSpace", value: "Next Space", comment: "Spaces menu - Activate the next Space in the strip"),
            action: #selector(activateNextSpace(_:)),
            keyEquivalent: ""
        )
        applyEffectiveShortcut(.PHI_SELECT_NEXT_SPACE, to: nextItem)
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.previousSpace", value: "Previous Space", comment: "Spaces menu - Activate the previous Space in the strip"),
            action: #selector(activatePreviousSpace(_:)),
            keyEquivalent: ""
        )
        applyEffectiveShortcut(.PHI_SELECT_PREVIOUS_SPACE, to: prevItem)
        prevItem.target = self
        menu.addItem(prevItem)

        let spaces = currentPresentedSpaces()
        if !spaces.isEmpty {
            menu.addItem(.separator())
            for (index, space) in spaces.enumerated() {
                let item = NSMenuItem(
                    title: space.name,
                    action: #selector(activateSpaceFromMenu(_:)),
                    keyEquivalent: ""
                )
                if let command = CommandWrapper.spaceSelectionCommand(at: index) {
                    applyEffectiveShortcut(command, to: item)
                }
                item.target = self
                item.representedObject = space.spaceId
                item.state = (space.spaceId == activeSpaceId) ? .on : .off
                item.image = spaceMenuIcon(for: space)
                #if compiler(>=6.4)
                if #available(macOS 27.0, *) {
                    item.preferredImageVisibility = .visible
                }
                #endif
                menu.addItem(item)
            }
        }

        let urlRulesSeparator = NSMenuItem.separator()
        urlRulesSeparator.tag = AppController.spacesURLRulesSeparatorTag
        menu.addItem(urlRulesSeparator)

        let urlRulesItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.urlRules", value: "URL Rules\u{2026}", comment: "Spaces menu - Open the universal URL routing rules editor"),
            action: #selector(openURLRulesEditor(_:)),
            keyEquivalent: ""
        )
        urlRulesItem.tag = AppController.spacesURLRulesItemTag
        urlRulesItem.target = self
        menu.addItem(urlRulesItem)

        let profileSeparator = NSMenuItem.separator()
        profileSeparator.tag = AppController.spacesProfileSeparatorTag
        menu.addItem(profileSeparator)

        let newProfileItem = NSMenuItem(
            title: NSLocalizedString("app.spacesMenu.newProfile", value: "New Profile\u{2026}", comment: "Spaces menu - Create a new browser profile"),
            action: #selector(newProfile(_:)),
            keyEquivalent: ""
        )
        newProfileItem.tag = AppController.spacesNewProfileItemTag
        newProfileItem.target = self
        menu.addItem(newProfileItem)

        let deleteProfileTitle = NSLocalizedString("app.spacesMenu.deleteProfile.submenuTitle", value: "Delete Profile", comment: "Spaces menu - Submenu listing deletable browser profiles")
        let deleteProfileParent = NSMenuItem(
            title: deleteProfileTitle,
            action: nil,
            keyEquivalent: ""
        )
        deleteProfileParent.tag = AppController.spacesDeleteProfileParentItemTag
        let deleteSubmenu = NSMenu(title: deleteProfileTitle)
        deleteSubmenu.identifier = AppController.deleteProfileSubmenuIdentifier
        deleteSubmenu.delegate = self
        deleteProfileParent.submenu = deleteSubmenu
        menu.addItem(deleteProfileParent)
        rebuildDeleteProfileSubmenu(deleteSubmenu)
    }

    private func makeSpacesProfileSubmenu(for space: Space?) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("app.spacesMenu.profileSubmenu.title", value: "Change Profile", comment: "Spaces menu - Profile submenu title for the active Space"))
        // The agent's fallback profile belongs to the agent — the user can't
        // re-bind a normal Space to it (matches the create-Space pickers).
        for profile in ProfileManager.shared.userAssignableProfiles {
            let item = NSMenuItem(
                title: profile.displayName,
                action: #selector(selectSpaceProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.profileId
            item.state = (profile.profileId == space?.profileId) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Slot the menu actions should target. Prefers the controller that's
    /// currently active in this app instance; falls back to the `keySlot`
    /// (most-recently-key window) when no controller is active — covers the
    /// menu-bar-from-background-app case.
    fileprivate func currentSpacesSlot() -> SpaceWindowSlot? {
        SpaceSessionControllersManager.shared.activeWindowController?.slot
            ?? SpaceManager.shared.keySlot
    }

    fileprivate func currentActiveSpace() -> Space? {
        let slot = currentSpacesSlot()
        let id = slot?.activeSpaceId ?? SpaceManager.shared.activeSpaceId
        guard let id else { return nil }
        return SpaceManager.shared.spaces.first(where: { $0.spaceId == id })
    }

    /// The Spaces the menus offer for the targeted slot — its own list, so
    /// an agent Space hosted by another window is neither listed nor cycled
    /// through from here (`SpaceWindowSlot.presents`). The full list stands in
    /// when no slot resolves, matching `currentActiveSpace`'s fallback.
    fileprivate func currentPresentedSpaces() -> [Space] {
        currentSpacesSlot()?.presentedSpaces ?? SpaceManager.shared.spaces
    }

    /// True when the focused window is showing an agent Space that the agent
    /// currently controls (not handed off to the user). While the agent holds
    /// control, its workspace must not be mutated from the menus: New Tab and
    /// the modify-this-Space actions (Rename / Change Icon / Edit Theme / Change
    /// Profile / Delete) are disabled. New Space and switching Spaces stay
    /// enabled so the user can always leave the agent Space.
    func focusedSpaceIsAgentControlled() -> Bool {
        guard let id = currentActiveSpace()?.spaceId else { return false }
        return MainActor.assumeIsolated { AgentSpaceManager.shared.isAgentOwned(id) }
    }

    /// True when the focused Space is an agent Space, regardless of who holds
    /// control. Used for actions that stay disabled even after the user takes
    /// control — notably Change Profile, which would break the running agent.
    func focusedSpaceIsAgentSpace() -> Bool {
        guard let id = currentActiveSpace()?.spaceId else { return false }
        return MainActor.assumeIsolated { AgentSpaceManager.shared.isAgentSpace(id) }
    }

    /// True when `item` lives in the Tab, Bookmarks, or History top-level menu —
    /// the menus disabled wholesale while the focused Space is agent-controlled.
    /// Bookmarks carries a stable identifier; Chromium-owned Tab and History
    /// menus are identified through their owning top-level menu item's tag.
    func itemIsInAgentLockedMenu(_ item: NSMenuItem) -> Bool {
        // Walk up to the submenu that sits directly under the main menu.
        var top: NSMenu? = item.menu
        while let m = top, let sup = m.supermenu, sup !== NSApp.mainMenu {
            top = sup
        }
        guard let topMenu = top else { return false }
        if topMenu.identifier == AppController.bookmarksMenuIdentifier { return true }
        if let owner = NSApp.mainMenu?.items.first(where: { $0.submenu === topMenu }) {
            let role = ChromiumMainMenuRole.resolve(owner, helpMenu: NSApp.helpMenu)
            return role == .tab || role == .history
        }
        return false
    }

    private func cycleActiveSpace(by step: Int) {
        guard let slot = currentSpacesSlot() else { return }
        let spaces = slot.presentedSpaces
        guard !spaces.isEmpty else { return }
        guard let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else {
            slot.activate(spaceId: spaces[0].spaceId, userInitiated: true)
            return
        }
        let nextIdx = (currentIdx + step + spaces.count) % spaces.count
        slot.activate(spaceId: spaces[nextIdx].spaceId, userInitiated: true)
    }

    @objc func newSpaceFromMenu(_ sender: Any?) {
        let activeProfileId = currentActiveSpace()?.profileId ?? LocalStore.defaultProfileId
        CreateSpacePanel.requestCreation(initialProfileId: activeProfileId)
    }

    @objc func renameActiveSpace(_ sender: Any?) {
        guard let space = currentActiveSpace() else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("app.renameSpaceDialog.title", value: "Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("app.renameSpaceDialog.message", value: "Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("app.renameSpaceDialog.renameButton", value: "Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("app.renameSpaceDialog.cancelButton", value: "Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = space.name
        textField.placeholderString = space.name
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        SpaceManager.shared.renameSpace(spaceId: space.spaceId, to: trimmed, expectedStoreIdentifier: space.storeIdentifier)
    }

    /// Opens the icon/emoji picker for the active Space, anchored below its icon
    /// in whichever Spaces strip is on screen (the sidebar's active pip or the
    /// tab strip's chip). Routed through the window's slot because an NSMenu item
    /// has no view of its own to anchor a SwiftUI popover to.
    @objc func requestActiveSpaceIconPicker(_ sender: Any?) {
        currentSpacesSlot()?.requestIconPicker()
    }

    /// Opens the active Space's theme editor from the targeted browser window.
    /// Presentation is deferred until menu tracking ends.
    @MainActor @objc func requestActiveSpaceThemeEditor(_ sender: Any?) {
        let context = (sender as? NSMenuItem)?.representedObject as? SpaceThemeEditorMenuContext
        let browserState = context?.browserState
        let slot = browserState?.windowController?.slot ?? currentSpacesSlot()
        guard let spaceId = slot?.activeSpaceId,
              let controller = browserState?.windowController ?? slot?.visibleController,
              let window = controller.window else { return }

        SpaceThemeEditorPanelPresenter.shared.present(
            spaceId: spaceId,
            from: window,
            placement: context?.placement ?? .windowTop,
            themeSource: controller.browserState.themeContext
        )
    }

    @objc func selectSpaceProfile(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let profileId = menuItem.representedObject as? String,
              let space = currentActiveSpace() else { return }
        confirmSpaceProfileChange(space, to: profileId)
    }

    func confirmSpaceProfileChange(_ space: Space, to profileId: String) {
        guard SpaceManager.shared.acceptsStoreAction(from: space.storeIdentifier),
              space.spaceId != LocalStore.defaultSpaceId,
              space.profileId != profileId,
              let profile = ProfileManager.shared.profile(for: profileId) else { return }
        // Changing the profile closes and respawns the Space's window (a
        // window's profile is baked in at spawn); its open tabs are
        // reopened on the new profile — confirm like Space deletion does.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("app.changeSpaceProfileConfirmation.title", value: "Change Profile to \u{201C}%@\u{201D}?", comment: "Title of the change-Space-profile confirmation"),
            profile.displayName
        )
        let pinnedTabScope = MainActor.assumeIsolated {
            AccountController.shared.localDataAccount.localStorage.pinnedTabScope()
        }
        switch pinnedTabScope {
        case .space:
            alert.informativeText = NSLocalizedString("app.changeSpaceProfileConfirmation.spaceScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks and pinned tabs stay with the Space.",
                comment: "Body of the change-Space-profile confirmation with Space-scoped pinned tabs"
            )
        case .profile:
            alert.informativeText = NSLocalizedString("app.changeSpaceProfileConfirmation.profileScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs will be the new profile's.",
                comment: "Body of the change-Space-profile confirmation with Profile-scoped pinned tabs"
            )
        case .app:
            alert.informativeText = NSLocalizedString("app.changeSpaceProfileConfirmation.appScopedMessage", value: "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs remain shared across the app.",
                comment: "Body of the change-Space-profile confirmation with App-scoped pinned tabs"
            )
        }
        alert.addButton(withTitle: NSLocalizedString("app.changeSpaceProfileConfirmation.confirmButton", value: "Change Profile", comment: "Confirm button of the change-Space-profile confirmation"))
        alert.addButton(withTitle: NSLocalizedString("app.changeSpaceProfileConfirmation.cancelButton", value: "Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SpaceManager.shared.changeProfile(spaceId: space.spaceId, toProfileId: profileId, expectedStoreIdentifier: space.storeIdentifier)
    }

    @objc func deleteActiveSpace(_ sender: Any?) {
        guard let space = currentActiveSpace() else { return }
        confirmSpaceDeletion(space)
    }

    func confirmSpaceDeletion(_ space: Space) {
        guard SpaceManager.shared.acceptsStoreAction(from: space.storeIdentifier),
              SpaceManager.shared.canDeleteSpace(spaceId: space.spaceId) else { return }
        let confirmed = MainActor.assumeIsolated {
            SpaceDeletionConfirmation.run(space: space)
        }
        guard confirmed else { return }
        SpaceManager.shared.deleteSpace(spaceId: space.spaceId, expectedStoreIdentifier: space.storeIdentifier)
    }

    /// Closes the active Incognito Space: its windows across all slots go,
    /// and the Space itself is torn down with them. Confirmed (with a "Do
    /// not ask again" option) in `requestCloseIncognitoSpace`. Reachable
    /// only while an Incognito Space is active (`appendActiveSpaceMenuItems`
    /// gates the item).
    @objc func closeIncognitoSpaceFromMenu(_ sender: Any?) {
        guard let spaceId = currentActiveSpace()?.spaceId,
              SpaceManager.isIncognitoSpaceId(spaceId) else { return }
        // Menu actions always arrive on the main thread; assume isolation
        // rather than annotating the @objc selector (same pattern as
        // SpaceManager.applyTheme).
        _ = MainActor.assumeIsolated {
            SpaceManager.shared.requestCloseIncognitoSpace(spaceId: spaceId)
        }
    }

    /// Creates a new Incognito Space and brings it to the front of the
    /// focused window — or a fresh window when none is open. All Incognito
    /// Spaces browse the same private session (one shared OTR profile);
    /// each is its own Space in the strip until it's closed.
    @objc func newIncognitoSpaceFromMenu(_ sender: Any?) {
        MainActor.assumeIsolated {
            openNewIncognitoSpace()
        }
    }

    @MainActor
    func openNewIncognitoSpace() {
        let timing = SpaceSwitchTiming()
        let manager = SpaceManager.shared
        let spaceId = manager.createIncognitoSpace(timing: timing)
        timing.mark("incognito.slot_lookup.begin")
        if let slot = currentSpacesSlot() {
            timing.mark("incognito.slot_lookup.end")
            slot.suppressHoverCard(spaceId: spaceId)
            slot.activate(spaceId: spaceId, timing: timing)
        } else {
            // No browser window open (menu-bar-only state): mint a slot
            // and spawn the Space's window into it, the same shape a
            // Chromium-initiated Cmd+N takes.
            let slot = manager.createSlot(initialSpaceId: spaceId)
            timing.mark("incognito.slot_create.end")
            slot.activate(spaceId: spaceId, onActivationFailed: {
                // Undo the whole menu action rather than half of it: with
                // nothing on screen, a Space left in the strip behind a
                // reclaimed slot is one the user has no surface to reach.
                //
                // Conditioned on the reclaim, not on the failure report:
                // `activate` also reports failure with the spawned window
                // registered (the user switched Space mid-spawn), and
                // closing the Space there would tear down a window that
                // did arrive. `reclaimMintedSlot` is the one place that
                // tells those two apart.
                //
                // Slot first: `closeIncognitoSpace` retreats any slot
                // showing the Space to the default one, which would spawn
                // a window into the very slot being reclaimed.
                guard manager.reclaimMintedSlot(slot, mintedForThisAttempt: true) else { return }
                manager.closeIncognitoSpace(spaceId: spaceId)
            }, timing: timing)
        }
    }

    @objc func activateNextSpace(_ sender: Any?) {
        cycleActiveSpace(by: 1)
    }

    @objc func activatePreviousSpace(_ sender: Any?) {
        cycleActiveSpace(by: -1)
    }

    @objc func activateSpaceFromMenu(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let spaceId = menuItem.representedObject as? String,
              let slot = currentSpacesSlot() else { return }
        // A menu pick is a deliberate switch, not a hover: arm the same click
        // suppression the sidebar pips use, so the target's hover card doesn't
        // pop under a cursor that happens to rest on its pip — or on the
        // horizontal chip — after the swap (see
        // `SpaceWindowSlot.hoverCardSuppressedSpaceId`).
        slot.suppressHoverCard(spaceId: spaceId)
        slot.activate(spaceId: spaceId, userInitiated: true)
    }

    @objc func openURLRulesEditor(_ sender: Any?) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "Phi URL Rules" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("Phi URL Rules")
        window.title = NSLocalizedString("app.urlRulesEditor.windowTitle", value: "URL Rules", comment: "Window title for the universal URL rules editor")
        window.isReleasedWhenClosed = false
        let editor = URLRulesEditor(manager: SpaceManager.shared) { [weak window] in
            window?.close()
        }
        window.contentViewController = ThemedHostingController(rootView: editor)
        window.setContentSize(NSSize(width: 680, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Runs the import command the Chromium-built menu item used to carry.
    /// The item keeps that command as its tag, so handing the item itself to
    /// the dispatcher takes exactly the route it took before — including the
    /// Incognito answer, which belongs to the command rather than to this
    /// menu item.
    @MainActor
    @objc func showImportDataWindowFromMenu(_ sender: Any?) {
        guard let sender,
              let window = SpaceSessionControllersManager.shared
                .activeWindowController?.window else { return }
        _ = CommandDispatcher.dispatchCommand(sender, window: window)
    }

    // MARK: - Chromium Menu Actions

    @objc func orderFrontStandardAboutPanel(_ sender: Any?) {
        if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue ?? "" == "About Phi Browser" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let aboutView = AboutView()
        let hostingController = ThemedHostingController(rootView: aboutView)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("About Phi Browser")

        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 290, height: 180))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

    }

    // MARK: - Menu Validation

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(makePrimaryWindowFromMenu(_:)) {
            let role = SpaceSessionControllersManager.shared.activeWindowController?.slot?.primaryRole
            (item as? NSMenuItem)?.state = role == .primary ? .on : .off
            return role == .markable
        }
        if item.action == #selector(toggleSidebar(_:))
            || item.action == #selector(toggleChatbar(_:)) {
            guard let currentWindow = NSApp.keyWindow ?? NSApp.mainWindow,
                  let sessionController = currentWindow.windowController as? SpaceSessionController,
                  !sessionController.isLibraryOverlayVisible else {
                return false
            }
        }

        // Placeholder mode: tab-targeted menu items must not act on the
        // (now-empty) tab strip. Chromium-side CommandUpdater already disables
        // most of these because the placeholder isn't in TabStripModel; this
        // is belt-and-suspenders for selector-based items (AI sidebar) and
        // defensive against any Chromium command that might still trip.
        if SpaceSessionControllersManager.shared
            .getActiveWindowState()?.isInPlaceholderMode == true {
            if item.action == #selector(toggleChatbar(_:)) { return false }
            if let menuItem = item as? NSMenuItem {
                let placeholderDisabledTags: Set<Int> = [
                    CommandWrapper.IDC_RELOAD.rawValue,
                    CommandWrapper.IDC_RELOAD_BYPASSING_CACHE.rawValue,
                    33009,                                       // IDC_RELOAD_CLEARING_CACHE
                    CommandWrapper.IDC_CLOSE_TAB.rawValue,
                    CommandWrapper.IDC_VIEW_SOURCE.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue,
                    CommandWrapper.IDC_DEV_TOOLS_CONSOLE.rawValue,
                    40007,                                       // IDC_DEV_TOOLS_DEVICES
                    40237,                                       // IDC_DEV_TOOLS_TOGGLE
                    CommandWrapper.IDC_FIND.rawValue,
                    CommandWrapper.IDC_FIND_NEXT.rawValue,
                    CommandWrapper.IDC_FIND_PREVIOUS.rawValue,
                    CommandWrapper.IDC_PRINT.rawValue,
                    CommandWrapper.IDC_ZOOM_PLUS.rawValue,
                    CommandWrapper.IDC_ZOOM_MINUS.rawValue,
                    CommandWrapper.IDC_ZOOM_NORMAL.rawValue,
                    CommandWrapper.IDC_SAVE_PAGE.rawValue,
                    CommandWrapper.IDC_BACK.rawValue,
                    CommandWrapper.IDC_FORWARD.rawValue,
                ]
                if placeholderDisabledTags.contains(menuItem.tag) { return false }
            }
        }

        // Agent lock: while the agent controls the focused Space, disable the
        // menus the user must not drive against its workspace — New Tab (File
        // menu) plus every item in the Tab, Bookmarks, and History menus.
        // Their shortcuts are separately swallowed in
        // `CommandDispatcher.handleKeyEquivalent`. Take control re-enables them.
        if let menuItem = item as? NSMenuItem, focusedSpaceIsAgentControlled() {
            if menuItem.tag == CommandWrapper.IDC_NEW_TAB.rawValue
                || menuItem.tag == CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue { return false }
            if itemIsInAgentLockedMenu(menuItem) { return false }
        }

        if item.action == #selector(openMistApp(_:)) {
            return SpaceSessionControllersManager.shared.getActiveWindowState().map { !$0.isIncognito } ?? false
        }
        if item.action == #selector(toggleChatbar(_:)) {
            let state = SpaceSessionControllersManager.shared.getActiveWindowState()
            return state?.canShowChatPanel(for: state?.focusingTab) == true
        }
        if item.action == #selector(switchChatPanelAndTab(_:)) {
            return SpaceSessionControllersManager.shared.getActiveWindowState().map { state in
                MainActor.assumeIsolated { MistChatPanelViewController.panelTabSwitch(in: state) != nil }
            } ?? false
        }
        if item.action == #selector(closePanelChat(_:)) {
            return SpaceSessionControllersManager.shared.getActiveWindowState().map { state in
                MainActor.assumeIsolated { MistChatPanelViewController.closeChatHost(in: state) != nil }
            } ?? false
        }
        if item.action == #selector(performStartPageCommandFromMenu(_:)) {
            guard let command = (item as? NSMenuItem).flatMap({ CommandWrapper(rawValue: $0.tag) }) else { return false }
            return SpaceSessionControllersManager.shared.getActiveWindowState()?.startPageCommandTab(command) != nil
        }
        if item.action == #selector(unpinAndCloseFromMenu(_:)) {
            return SpaceSessionControllersManager.shared.getActiveWindowState()?.focusingTab != nil
        }

        // New Conversation only applies while focus is inside the AI sidebar;
        // otherwise disable the item so its shortcut falls through to the
        // original behavior.
        if item.action == #selector(newConversation(_:)) {
            let state = SpaceSessionControllersManager.shared.getActiveWindowState()
            guard let state,
                  state.canShowChatPanel(for: state.focusingTab),
                  state.focusingTab?.aiChatCollapsed == false,
                  state.focusingTab?.lastFocusTarget == .aiChat else {
                return false
            }
        }

        // Toggle Sidebar is unavailable in the traditional layout.
        if item.action == #selector(toggleSidebar(_:)) {
            if PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                return false
            }
        }

        if item.action == #selector(showPreferences(_:)) {
            return true
        }

        if item.action == #selector(showImportDataWindowFromMenu(_:)) {
            return SpaceSessionControllersManager.shared.activeWindowController != nil
        }

        if item.action == #selector(openBookmarkManager(_:)) {
            return SpaceSessionControllersManager.shared.activeWindowController != nil &&
                !isActiveWindowIncognito()
        }

        if item.action == #selector(selectLayoutMode(_:)) {
            if let menuItem = item as? NSMenuItem {
                let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()

                switch menuItem.tag {
                case AppController.layoutModeDefaultItemTag:
                    menuItem.state = (layoutMode == .performance) ? .on : .off
                case AppController.layoutModeNavigationAtTopItemTag:
                    menuItem.state = (layoutMode == .balanced) ? .on : .off
                case AppController.layoutModeTraditionalItemTag:
                    menuItem.state = (layoutMode == .comfortable) ? .on : .off
                default:
                    break
                }
                return true
            }
        }

        if item.action == #selector(toggleAgentAutoView(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.state = PhiPreferences.AgentSpaces.autoViewEnabled ? .on : .off
                return true
            }
        }

        if item.action == #selector(toggleReaderView(_:)) {
            if let menuItem = item as? NSMenuItem {
                let tab = MainActor.assumeIsolated { () -> Tab? in
                    guard let state = SpaceSessionControllersManager.shared
                        .activeWindowController?.browserState else { return nil }
                    return state.readerViewTarget(focusingTab: state.focusingTab)
                }
                menuItem.state = (tab?.extensionReaderActive ?? false) ? .on : .off
                // Nothing to distill on the native NTP: it has no WebContents,
                // so there is no page to run extraction against.
                guard let tab, !tab.isShowingNativeNTP else { return false }
                return true
            }
        }

        if item.action == #selector(openLibrary(_:)) {
            let canOpen = MainActor.assumeIsolated {
                guard let owner = SpaceSessionControllersManager.shared.activeWindowController else {
                    return false
                }
                return owner.window?.contentView != nil
            }
            return canOpen
        }

        if item.action == #selector(toggleAgentTranscript(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.state = MainActor.assumeIsolated {
                    AgentTranscriptPanelController.shared.isVisible
                } ? .on : .off
                return true
            }
        }

        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if item.action == #selector(toggleBookmarkBar(_:)) {
            if let menuItem = item as? NSMenuItem {
                if !traditionalLayout {
                    menuItem.isHidden = true
                    return false
                }
                menuItem.isHidden = false
                let isAlwaysShow = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
                menuItem.state = isAlwaysShow ? .on : .off
                return true
            }
        }
        if item.action == #selector(toggleBookmarkBarOnNewTab(_:)) {
            if let menuItem = item as? NSMenuItem {
                let isAlwaysShow = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
                if !traditionalLayout || isAlwaysShow {
                    menuItem.isHidden = true
                    return false
                }
                menuItem.isHidden = false
                let isShowOnNewTab = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
                menuItem.state = isShowOnNewTab ? .on : .off
                return true
            }
        }
        let spacesFeatureEnabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        if item.action == #selector(newProfile(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.isHidden = !spacesFeatureEnabled
            }
            return spacesFeatureEnabled
        }
        if item.action == #selector(newIncognitoSpaceFromMenu(_:)) {
            if let menuItem = item as? NSMenuItem {
                menuItem.isHidden = !spacesFeatureEnabled
            }
            return spacesFeatureEnabled
        }
        if item.action == #selector(deleteSelectedProfile(_:)) {
            guard spacesFeatureEnabled,
                  let menuItem = item as? NSMenuItem,
                  let profile = menuItem.representedObject as? PhiBrowserProfile else {
                return false
            }
            return !SpaceManager.shared.isProfileInUse(profile.profileId)
        }
        let spacesActions: [Selector] = [
            #selector(newSpaceFromMenu(_:)),
            #selector(renameActiveSpace(_:)),
            #selector(requestActiveSpaceIconPicker(_:)),
            #selector(requestActiveSpaceThemeEditor(_:)),
            #selector(selectSpaceProfile(_:)),
            #selector(deleteActiveSpace(_:)),
            #selector(closeIncognitoSpaceFromMenu(_:)),
            #selector(activateNextSpace(_:)),
            #selector(activatePreviousSpace(_:)),
            #selector(activateSpaceFromMenu(_:)),
            #selector(openURLRulesEditor(_:)),
        ]
        if let action = item.action, spacesActions.contains(action) {
            guard spacesFeatureEnabled else { return false }
            // An Incognito Space's name, profile binding and existence are
            // fixed: its name is derived ("Incognito" / "Incognito N"), its
            // shared OTR profile can't be re-bound, and the Space ends via
            // Close Incognito Space, not delete. Icon and theme stay
            // enabled — both live outside SwiftData. Navigation and the
            // rules editor stay available too.
            let mutatingSpaceActions: [Selector] = [
                #selector(renameActiveSpace(_:)),
                #selector(selectSpaceProfile(_:)),
                #selector(deleteActiveSpace(_:)),
            ]
            if mutatingSpaceActions.contains(action),
               let activeId = currentActiveSpace()?.spaceId,
               SpaceManager.isIncognitoSpaceId(activeId) {
                return false
            }
            if action == #selector(renameActiveSpace(_:))
                || action == #selector(requestActiveSpaceIconPicker(_:))
                || action == #selector(requestActiveSpaceThemeEditor(_:)) {
                return currentActiveSpace() != nil
            }
            if action == #selector(deleteActiveSpace(_:)) {
                // Any Space can be deleted except the last user Space.
                guard let space = currentActiveSpace() else { return false }
                return SpaceManager.shared.canDeleteSpace(spaceId: space.spaceId)
            }
            if action == #selector(selectSpaceProfile(_:)) {
                // The default space's profile can't change — its bookmark
                // root is shared with the legacy per-profile root.
                guard let space = currentActiveSpace(),
                      space.spaceId != LocalStore.defaultSpaceId else { return false }
                if let menuItem = item as? NSMenuItem {
                    let representedId = menuItem.representedObject as? String
                    menuItem.state = (representedId == space.profileId) ? .on : .off
                }
                return true
            }
            if action == #selector(activateNextSpace(_:)) || action == #selector(activatePreviousSpace(_:)) {
                return SpaceManager.shared.spaces.count > 1 && currentSpacesSlot() != nil
            }
            if action == #selector(activateSpaceFromMenu(_:)) {
                // Reject a Space removed since the last rebuild. Agent Spaces
                // can disappear while a menu still carries their IDs.
                guard let menuItem = item as? NSMenuItem,
                      let spaceId = menuItem.representedObject as? String,
                      currentPresentedSpaces()
                          .contains(where: { $0.spaceId == spaceId }) else {
                    return false
                }
                let activeId = currentActiveSpace()?.spaceId
                menuItem.state = (spaceId == activeId) ? .on : .off
                return currentSpacesSlot() != nil
            }
            return true
        }
        if item.action == #selector(copySelectedTabURLs(_:)) {
            guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else {
                return false
            }
            if let menuItem = item as? NSMenuItem {
                menuItem.title = state.selectedTabCountForURLCopy > 1
                    ? NSLocalizedString("app.editMenu.copySelectedTabURLs", value: "Copy URLs", comment: "Edit menu - Copy the selected tab URLs to the clipboard")
                    : NSLocalizedString("app.editMenu.copySelectedTabURLState", value: "Copy URL", comment: "Edit menu - Single selected-tab URL title when updating menu state")
            }
            return state.hasCopyableSelectedTabURLs
        }
        if item.action == #selector(copyFullPageScreenshotFromMenu(_:)) || item.action == #selector(capturePageAreaFromMenu(_:)) {
            return MainActor.assumeIsolated {
                guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else { return false }
                return PageScreenshotService.shared.canCapture(in: state, area: item.action == #selector(capturePageAreaFromMenu(_:)))
            }
        }
        if item.action == #selector(alternateNewTabFromMenu(_:)) {
            return SpaceSessionControllersManager.shared.getActiveWindowState() != nil
                && !focusedSpaceIsAgentControlled()
        }
        if item.action == #selector(sharePageFromMenu(_:)) {
            guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else {
                return false
            }
            return MainActor.assumeIsolated {
                PageSharingPresenter.canShare(tab: state.pageCommandTarget)
            }
        }
        if item.action == #selector(bookmarkThisTab(_:)) {
            return canBookmarkCurrentTab()
        }
        if item.action == #selector(bookmarkAllTabs(_:)) {
            return canBookmarkAllTabs()
        }
        if item.action == #selector(exportBookmarks(_:)) {
            return canExportBookmarks()
        }
        if item.action == #selector(openBookmarkMenuItem(_:)) {
            guard let menuItem = item as? NSMenuItem,
                  let bookmark = menuItem.representedObject as? Bookmark else {
                return false
            }
            return !bookmark.isFolder
        }
        // Command-dispatched main-menu items that reach the app delegate had no
        // key browser window to handle them. Defer their enabled state to
        // PhiAppController (no-window CommandUpdater: New Tab/New Window enabled,
        // tab-only commands disabled), matching upstream AppController.
        if item.action == #selector(commandDispatch(_:)) {
            return validateChromiumMenuItem(item)
        }

        return true
    }

    private func validateChromiumMenuItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let selector = NSSelectorFromString("validateUserInterfaceItemFromMenu:")
        guard let bridge = ChromiumLauncher.sharedInstance().bridge as? NSObject,
              bridge.responds(to: selector) else {
            return false
        }
        return ChromiumLauncher.sharedInstance().bridge?.validateUserInterfaceItem(fromMenu: item) ?? false
    }

    // New-window/new-tab commands that spawn a window when none is open. They
    // are dropped while a session restore is in flight so their Chromium window
    // cannot race the restore's per-profile session commit (see below).
    private static let windowlessSpawnCommandTags: Set<Int> = [
        CommandWrapper.IDC_NEW_WINDOW.rawValue,
        CommandWrapper.IDC_NEW_INCOGNITO_WINDOW.rawValue,
        CommandWrapper.IDC_NEW_TAB.rawValue,
    ]

    @IBAction @objc func commandDispatch(_ sender: Any?) {
        // A windowless session restore is in flight: dropping a new-window/tab
        // command here keeps its Chromium window from racing the restore's
        // per-profile commit (which would conclude the profile still has a
        // window and suppress its restore). The user can reissue once the
        // restored windows arrive.
        //
        // This gate reads the flag directly, so it applies to EVERY windowless
        // reopen. The Space-switch gate next door
        // (`SpaceManager.reopenDropsActivations`) additionally requires that
        // the reopen armed the lazy filter. The asymmetry is deliberate and
        // documented there: this one shipped before that feature, so leaving it
        // unconditional is what keeps "the lazy switch off means today's
        // behavior" true.
        if SpaceManager.shared.isSessionRestoreInFlight,
           let tag = (sender as? NSMenuItem)?.tag,
           Self.windowlessSpawnCommandTags.contains(tag) {
            return
        }
        // No key browser window handled this command, so it reached the app
        // delegate. Forward to PhiAppController (via the bridge), which contains
        // the no-window handling for File-menu commands like New Tab/New Window.
        ChromiumLauncher.sharedInstance().bridge?.commandDispatchFromMenu(sender as Any)
    }
}

// MARK: - NSMenuDelegate for Help menu Option key handling
extension AppController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu.identifier == AppController.bookmarksMenuIdentifier {
            rebuildBookmarksMenu(menu)
            return
        }
        if menu.identifier == AppController.deleteProfileSubmenuIdentifier {
            rebuildDeleteProfileSubmenu(menu)
            return
        }
        if menu.identifier == AppController.spacesMenuIdentifier {
            AppController.isSpacesMenuTracking = true
            AppController.spacesMenuNeedsRebuild = false
            rebuildSpacesMenu(menu)
            return
        }
        if menu.identifier == AppController.timeMachineBackupsMenuIdentifier {
            rebuildTimeMachineBackupsMenu(menu)
            return
        }

        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
        if let extensionInfoItem = menu.item(withTag: AppController.extensionInfoItemTag) {
            extensionInfoItem.isHidden = !optionKeyPressed
        }
        if let exportLogsItem = menu.item(withTag: AppController.exportLogsItemTag) {
            exportLogsItem.isHidden = !optionKeyPressed
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu.identifier == AppController.spacesMenuIdentifier else { return }
        AppController.isSpacesMenuTracking = false
        // Apply a list change that arrived while the menu was down, so the
        // Space rows are current before the menu opens again.
        guard AppController.spacesMenuNeedsRebuild else { return }
        AppController.spacesMenuNeedsRebuild = false
        rebuildSpacesMenu(menu)
    }
}

private final class TimeMachineBackupDeletionProgressModal {
    private let window: NSPanel
    private let progressIndicator: NSProgressIndicator

    private(set) var outcome: Result<TimeMachineBackupRecord?, Error>?

    init(backupTitle: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("app.timeMachineBackup.deleteProgress.windowTitle", value: "Time Machine Backup", comment: "Time Machine backup deletion progress window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let titleLabel = NSTextField(labelWithString: NSLocalizedString("app.timeMachineBackup.deleteProgress.title", value: "Deleting Backup", comment: "Time Machine backup deletion progress title"))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let backupLabel = NSTextField(labelWithString: backupTitle)
        backupLabel.font = .systemFont(ofSize: 12)
        backupLabel.textColor = .secondaryLabelColor
        backupLabel.lineBreakMode = .byTruncatingMiddle
        backupLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.controlSize = .regular
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView
        contentView.addSubview(titleLabel)
        contentView.addSubview(backupLabel)
        contentView.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            backupLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            backupLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            backupLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: backupLabel.bottomAnchor, constant: 18)
        ])
    }

    func run() -> NSApplication.ModalResponse {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        progressIndicator.startAnimation(nil)
        return NSApp.runModal(for: window)
    }

    func finish(outcome: Result<TimeMachineBackupRecord?, Error>) {
        self.outcome = outcome
        progressIndicator.stopAnimation(nil)
        NSApp.stopModal(withCode: .stop)
        window.orderOut(nil)
        window.close()
    }
}

private final class TimeMachineRestoreProgressModal {
    private let window: NSPanel
    private let titleLabel: NSTextField
    private let backupLabel: NSTextField
    private let stageLabel: NSTextField
    private let progressIndicator: NSProgressIndicator

    private(set) var outcome: Result<Void, Error>?

    init(backupTitle: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 156),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("app.timeMachineRestore.progress.windowTitle", value: "Time Machine Restore", comment: "Time Machine restore progress window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        titleLabel = NSTextField(labelWithString: NSLocalizedString("app.timeMachineRestore.progress.title", value: "Preparing Time Machine Restore",
            comment: "Time Machine restore progress title"
        ))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        backupLabel = NSTextField(labelWithString: backupTitle)
        backupLabel.font = .systemFont(ofSize: 12)
        backupLabel.textColor = .secondaryLabelColor
        backupLabel.lineBreakMode = .byTruncatingMiddle
        backupLabel.translatesAutoresizingMaskIntoConstraints = false

        stageLabel = NSTextField(labelWithString: Self.message(for: .preparing))
        stageLabel.font = .systemFont(ofSize: 12)
        stageLabel.textColor = .secondaryLabelColor
        stageLabel.lineBreakMode = .byTruncatingTail
        stageLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.controlSize = .regular
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        contentView.addSubview(titleLabel)
        contentView.addSubview(backupLabel)
        contentView.addSubview(progressIndicator)
        contentView.addSubview(stageLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            backupLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            backupLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            backupLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: backupLabel.bottomAnchor, constant: 22),

            stageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stageLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 10)
        ])
    }

    func run() -> NSApplication.ModalResponse {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        progressIndicator.startAnimation(nil)
        return NSApp.runModal(for: window)
    }

    func update(_ progress: TimeMachineRestorePreparationProgress) {
        stageLabel.stringValue = Self.message(for: progress.stage)
        if let fractionCompleted = progress.fractionCompleted {
            if progressIndicator.isIndeterminate {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
            }
            progressIndicator.doubleValue = fractionCompleted * 100
        } else {
            if !progressIndicator.isIndeterminate {
                progressIndicator.isIndeterminate = true
            }
            progressIndicator.startAnimation(nil)
        }
    }

    func finish(outcome: Result<Void, Error>, response: NSApplication.ModalResponse) {
        self.outcome = outcome
        progressIndicator.stopAnimation(nil)
        NSApp.stopModal(withCode: response)
        window.orderOut(nil)
        window.close()
    }

    private static func message(for stage: TimeMachineRestorePreparationStage) -> String {
        switch stage {
        case .preparing:
            return NSLocalizedString("app.timeMachineRestore.progress.preparingRestore", value: "Preparing restore...", comment: "Time Machine restore progress stage")
        case .downloadingPackage:
            return NSLocalizedString("app.timeMachineRestore.progress.downloadingRollbackPackage", value: "Downloading rollback package...", comment: "Time Machine restore progress stage")
        case .expandingPackage:
            return NSLocalizedString("app.timeMachineRestore.progress.expandingRollbackPackage", value: "Expanding rollback package...", comment: "Time Machine restore progress stage")
        case .validatingPackage:
            return NSLocalizedString("app.timeMachineRestore.progress.validatingRollbackApp", value: "Validating rollback app...", comment: "Time Machine restore progress stage")
        case .preparingInstaller:
            return NSLocalizedString("app.timeMachineRestore.progress.preparingInstaller", value: "Preparing installer...", comment: "Time Machine restore progress stage")
        case .launchingInstaller:
            return NSLocalizedString("app.timeMachineRestore.progress.startingRestore", value: "Starting restore...", comment: "Time Machine restore progress stage")
        case .readyToQuit:
            return NSLocalizedString("app.timeMachineRestore.progress.restartingPhi", value: "Restarting Phi...", comment: "Time Machine restore progress stage")
        }
    }
}
