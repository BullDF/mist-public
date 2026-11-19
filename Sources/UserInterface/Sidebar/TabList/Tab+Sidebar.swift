// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
extension Tab: SidebarItem {
    var isBookmark: Bool {
        false
    }
    
    var id: AnyHashable {
        return guid
    }
    
    var isExpandable: Bool {
        return !subTabs.isEmpty
    }
    
    var childrenItems: [SidebarItem] {
        return subTabs
    }
    
    var itemType: SidebarItemType {
        return .tab
    }
    
    func performAction(with owner: SidebarTabListItemOwner?) {
        webContentWrapper?.setAsActiveTab()
    }
    
    var isSelectable: Bool { true }
}

extension Tab: ContextMenuRepresentable {
    @MainActor func makeContextMenu(on menu: NSMenu) {
        menu.removeAllItems()
        contextMenuOwnerState = SpaceSessionControllersManager.shared
            .controllerUnderContextClick()?.browserState

        var items: [NSMenuItem] = []
       
        
        // When the right-clicked tab is part of a split, the pin action operates
        // on the split as a unit — pin moves both panes into `pinnedTabs` and
        // marks the SplitGroup as pinned; unpin reverses that. The same
        // `splitMembership` lookup covers all three cell shapes (live tab,
        // pinned record with live panes, closed pinned split).
        let browserStateForMenu = contextMenuState
        let splitMembership = browserStateForMenu?.splitMembership(forCellTab: self)
        let isPinnedSplitCell = splitMembership?.isPinned == true
        // Shortcuts act on the focused tab, so only its menu shows them.
        let showsShortcuts = browserStateForMenu?.focusingTab?.guid == guid

        // Off-the-record windows (standalone incognito and the Incognito
        // Space) have no pinned tabs, so the pin item is dropped from the
        // menu rather than disabled.
        let isIncognitoWindow = browserStateForMenu?.isIncognito == true

        if !isIncognitoWindow {
            let pinItem: NSMenuItem
            if let membership = splitMembership, let liveGroup = membership.liveGroup {
                let title = liveGroup.isPinned
                    ? NSLocalizedString("sidebar.tabContextMenu.unpinLiveSplit", value: "Unpin Split", comment: "Tab context menu - Remove the pin from a live split")
                    : NSLocalizedString("sidebar.tabContextMenu.pinSplit", value: "Pin Split", comment: "Tab context menu - Pin the split that contains this tab")
                pinItem = NSMenuItem(title: title,
                                     action: #selector(SpaceSessionController.togglePinSplit(_:)),
                                     keyEquivalent: "")
                pinItem.representedObject = liveGroup.id
            } else if let pair = splitMembership?.pinnedDBPair {
                // Closed pinned split — both panes are closed so there's no live
                // splitId. Route through the persistence-aware unpin path that
                // drops the pairing and reopens both URLs as a fresh non-pinned
                // split.
                pinItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.unpinClosedSplit", value: "Unpin Split", comment: "Tab context menu - Remove the pin from a closed pinned split"),
                                     action: #selector(SpaceSessionController.unpinClosedPinnedSplit(_:)),
                                     keyEquivalent: "")
                pinItem.representedObject = [pair.left, pair.right]
            } else {
                pinItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.pinTab", value: "Pin", comment: "Tab context menu - Menu item to pin the selected tab"),
                                     action: #selector(SpaceSessionController.togglePin(_:)),
                                     keyEquivalent: "")
                if isPinned {
                    pinItem.title = NSLocalizedString("sidebar.tabContextMenu.unpinTab", value: "Unpin", comment: "Tab context menu - Menu item to unpin the selected tab")
                }
            }
            items.append(pinItem)
        }
        
        // Resolve the live non-pinned split URL pair (if any) so the
        // duplicate / copy blocks can flip to split-aware variants when the
        // right-clicked cell represents a merged pair. Pinned-split URLs are
        // read directly off the membership panes below.
        let nonPinnedSplitPair: (leftURL: String, rightURL: String)? = {
            guard let membership = splitMembership,
                  membership.liveGroup?.isPinned == false,
                  let leftURL = membership.leftPane.url, !leftURL.isEmpty,
                  let rightURL = membership.rightPane.url, !rightURL.isEmpty else {
                return nil
            }
            return (leftURL, rightURL)
        }()
        let isSplitCell = isPinnedSplitCell || nonPinnedSplitPair != nil

        // Pinned and non-pinned splits both duplicate as a fresh split
        // (both panes), not just one pane.
        let duplicateItem: NSMenuItem
        if isSplitCell {
            duplicateItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.duplicateSplit", value: "Duplicate Split", comment: "Tab context menu - Duplicate both panes of a split as a new split"),
                                       action: #selector(duplicateSplitTab),
                                       keyEquivalent: "")
        } else {
            duplicateItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.duplicateTab", value: "Duplicate", comment: "Tab context menu - Menu item to duplicate the selected tab"),
                                       action: #selector(duplicateTab),
                                       keyEquivalent: "")
            if showsShortcuts {
                applyShortcut(.IDC_DUPLICATE_TAB, to: duplicateItem)
            }
        }
        duplicateItem.target = self
        items.append(duplicateItem)

        if !isSplitCell {
            let renameItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.rename", value: "Rename", comment: "Tab context menu - Rename the selected tab"),
                                        action: #selector(beginRenamingTab), keyEquivalent: "")
            renameItem.target = self
            items.append(renameItem)
        }

        // Splits expose one copy item per pane so the user can pick which
        // side to copy without having to dissolve the split. Regular tabs
        // keep the single "Copy Link".
        let copyPrimaryURL: String?
        let copySecondaryURL: String?
        if isPinnedSplitCell, let membership = splitMembership {
            copyPrimaryURL = membership.leftPane.url
            copySecondaryURL = membership.rightPane.url
        } else if let pair = nonPinnedSplitPair {
            copyPrimaryURL = pair.leftURL
            copySecondaryURL = pair.rightURL
        } else {
            copyPrimaryURL = nil
            copySecondaryURL = nil
        }
        if let primaryURL = copyPrimaryURL, let secondaryURL = copySecondaryURL {
            let splitLayout = splitMembership?.liveGroup?.layout
                ?? splitMembership?.pinnedDBPair.flatMap { pair in
                    browserStateForMenu?.pinnedSplitLayout(leftDB: pair.left, rightDB: pair.right)
                }
                ?? .vertical
            let isStacked = splitLayout == .horizontal
            let copyPrimaryTitle = isStacked
                ? NSLocalizedString("sidebar.tabContextMenu.copyTopPaneURL", value: "Copy Top URL", comment: "Tab context menu - Copy the top pane's URL for a stacked split")
                : NSLocalizedString("sidebar.tabContextMenu.copyLeftPaneURL", value: "Copy Left URL", comment: "Tab context menu - Copy the left pane's URL for a side-by-side split")
            let copySecondaryTitle = isStacked
                ? NSLocalizedString("sidebar.tabContextMenu.copyBottomPaneURL", value: "Copy Bottom URL", comment: "Tab context menu - Copy the bottom pane's URL for a stacked split")
                : NSLocalizedString("sidebar.tabContextMenu.copyRightPaneURL", value: "Copy Right URL", comment: "Tab context menu - Copy the right pane's URL for a side-by-side split")

            let copyPrimaryURLItem = NSMenuItem(title: copyPrimaryTitle,
                                                action: #selector(copySplitPaneURL(_:)),
                                                keyEquivalent: "")
            copyPrimaryURLItem.target = self
            copyPrimaryURLItem.representedObject = primaryURL
            items.append(copyPrimaryURLItem)

            let copySecondaryURLItem = NSMenuItem(title: copySecondaryTitle,
                                                  action: #selector(copySplitPaneURL(_:)),
                                                  keyEquivalent: "")
            copySecondaryURLItem.target = self
            copySecondaryURLItem.representedObject = secondaryURL
            items.append(copySecondaryURLItem)
        } else {
            let copyUrlItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.copyTabURL", value: "Copy Link", comment: "Tab context menu - Menu item to copy the tab URL to clipboard"), action: #selector(SpaceSessionController.myCopyLink(_:)), keyEquivalent: "")
            if showsShortcuts {
                applyShortcut(.PHI_COPY_URL, to: copyUrlItem)
            }
            items.append(copyUrlItem)
        }

        items.append(.separator())

        // Split view: either dissolve the existing split this tab belongs to,
        // or open a fresh tab paired with this one as a new split. Mutually exclusive.
        if let state = contextMenuState {
            if let existingSplit = splitMembership?.liveGroup ?? state.splitGroup(forTabId: guid) {
                // Pinned splits don't expose "Reverse Panes" / "Remove from
                // Split" — those are normal-split affordances. Unpinning a
                // pinned split (via the "Unpin Split" item above) re-renders
                // it as a normal split and the items reappear.
                if !existingSplit.isPinned {
                    let reverseSplitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.reverseSplitPanes", value: "Reverse Panes", comment: "Tab context menu - Swap the left/right (or top/bottom) panes of the split this tab belongs to"),
                        action: #selector(reverseSplitPanes(_:)),
                        keyEquivalent: "")
                    reverseSplitItem.target = self
                    reverseSplitItem.representedObject = existingSplit.id
                    items.append(reverseSplitItem)
                }

                let convertLayoutItem = NSMenuItem(
                    title: existingSplit.layout == .vertical
                        ? NSLocalizedString("sidebar.tabContextMenu.convertToVerticalSplit", value: "Convert to Vertical Split", comment: "Split context menu - Switch a side-by-side split to a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.convertToHorizontalSplit", value: "Convert to Horizontal Split", comment: "Split context menu - Switch a stacked split to a side-by-side split"),
                    action: #selector(convertSplitLayout(_:)),
                    keyEquivalent: "")
                convertLayoutItem.target = self
                convertLayoutItem.representedObject = existingSplit.id
                items.append(convertLayoutItem)

                if !existingSplit.isPinned {
                    let removeSplitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.removeFromSplit", value: "Remove from Split", comment: "Tab context menu - Dissolve the split that contains this tab"),
                        action: #selector(removeFromSplit(_:)),
                        keyEquivalent: "")
                    removeSplitItem.target = self
                    removeSplitItem.representedObject = existingSplit.id
                    items.append(removeSplitItem)
                }
                items.append(.separator())
            } else if let pair = splitMembership?.pinnedDBPair {
                let layout = state.pinnedSplitLayout(leftDB: pair.left, rightDB: pair.right)
                let convertLayoutItem = NSMenuItem(
                    title: layout == .vertical
                        ? NSLocalizedString("sidebar.tabContextMenu.convertToVerticalSplit", value: "Convert to Vertical Split", comment: "Split context menu - Switch a side-by-side split to a stacked split")
                        : NSLocalizedString("sidebar.tabContextMenu.convertToHorizontalSplit", value: "Convert to Horizontal Split", comment: "Split context menu - Switch a stacked split to a side-by-side split"),
                    action: #selector(convertClosedPinnedSplitLayout(_:)),
                    keyEquivalent: "")
                convertLayoutItem.target = self
                convertLayoutItem.representedObject = [pair.left, pair.right]
                items.append(convertLayoutItem)
                items.append(.separator())
            } else if splitMembership == nil {
                // Pinned tabs are allowed here; `openNewTabAsSplit` demotes a
                // pinned partner to the normal list (leaving an unopened
                // pinned placeholder behind) before creating the split, so
                // splits never live inside the pinned strip.
                //
                // When another tab is focused (and isn't itself in a split),
                // the action pairs this tab with the focused one instead of
                // opening a blank new-tab pane — surfaced as "Split with
                // Current". Right-clicking the focused tab itself keeps the
                // blank-pane "Open as Split".
                let splitItem: NSMenuItem
                if let focused = state.focusingTab,
                   focused.guid != guid,
                   state.splitGroup(forTabId: focused.guid) == nil {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.splitWithCurrent", value: "Split with Current", comment: "Tab context menu - Pair this tab with the currently focused tab in a split"),
                        action: #selector(splitWithCurrent),
                        keyEquivalent: "")
                } else {
                    splitItem = NSMenuItem(
                        title: NSLocalizedString("sidebar.tabContextMenu.openAsSplit", value: "Open as Split", comment: "Tab context menu - Open a new tab as the second pane in a split with this tab"),
                        action: #selector(openAsSplit),
                        keyEquivalent: "")
                }
                splitItem.target = self
                items.append(splitItem)
                items.append(.separator())
            }
        }
        
        // The split block above may already end with a separator — don't
        // stack another.
        if items.last?.isSeparatorItem == false {
            items.append(.separator())
        }

        let countBeforeTabGroupBlock = items.count
        appendTabGroupMenuItems(into: &items)
        appendMoveToWindowMenuItems(into: &items)
        if items.count > countBeforeTabGroupBlock {
            // Group and window items contributed entries; close them with a
            // separator before the pin/edit/close block.
            items.append(.separator())
        }
        // If the block was empty (pinned tab), the separator we appended
        // above already serves as the bookmark→pin/close divider.

        let countBeforeMoveToSpace = items.count
        appendMoveToSpaceMenuItems(into: &items, isSplitCell: isSplitCell)
        if items.count > countBeforeMoveToSpace {
            items.append(.separator())
        }

        if isPinned {
            let editItem = NSMenuItem(title: NSLocalizedString("sidebar.pinnedTabContextMenu.editAction", value: "Edit...", comment: "Pinned tab context menu - Edit pinned tab menu item"), action: #selector(editPinnedTab), keyEquivalent: "")
            editItem.target = self
            items.append(editItem)
        }
        
        if !isPinned || (isPinned && isOpenned) {
            let closeItem = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.closeTab", value: "Close", comment: "Tab context menu - Menu item to close the selected tab"), action: #selector(SpaceSessionController.closeTab(_:)), keyEquivalent: "")
            // A split cell's Close closes both panes; the shortcut closes one.
            if showsShortcuts && !isSplitCell {
                applyShortcut(.IDC_CLOSE_TAB, to: closeItem)
            }
            items.append(closeItem)
        }

        let closeOther = NSMenuItem(title: NSLocalizedString("sidebar.tabContextMenu.closeOtherTabs", value: "Close Other Tabs", comment: "Tab context menu - Menu item to close all tabs except the selected one"), action: #selector(SpaceSessionController.closeOther(_:)), keyEquivalent: "")
        if showsShortcuts {
            applyShortcut(.IDC_WINDOW_CLOSE_OTHER_TABS, to: closeOther)
        }
        items.append(closeOther)
        
        items.forEach { item in
            if item.representedObject == nil {
                item.representedObject = self
            }
            menu.addItem(item)
        }
    }

    /// The Space this tab's (or bookmark's) context-menu actions run against:
    /// the one the menu was opened from, else the active one.
    private var contextMenuState: BrowserState? {
        contextMenuOwnerState ?? SpaceSessionControllersManager.shared.activeWindowController?.browserState
    }

    @MainActor private var contextMenuWindowController: SpaceSessionController? {
        contextMenuState?.windowController
            ?? SpaceSessionControllersManager.shared.activeWindowController
    }

    /// Shows the shortcut currently set for `command`, read each time the
    /// menu is built.
    private func applyShortcut(_ command: CommandWrapper, to item: NSMenuItem) {
        item.tag = command.rawValue
        Shortcuts.updateShortcut(for: item)
    }

    @MainActor
    @objc private func editPinnedTab() {
        guard let windowController = contextMenuWindowController else {
            return
        }
        guard let guid = guidInLocalDB, !guid.isEmpty else {
            return
        }
        let state = windowController.browserState

        // Pinned-split cells edit both panes in a single sheet so the user
        // doesn't have to unpin to change either side. `pinnedSplitDBPair`
        // returns `(leftDB, rightDB)` in left→right layout order to match the
        // primary/secondary inputs in `EditPinnedTabView`.
        if let pinnedSelf = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }),
           let (leftDB, rightDB) = state.pinnedSplitDBPair(forPinnedTab: pinnedSelf),
           let leftTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }),
           let rightTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == rightDB }) {
            let leftURL = state.pinnedTabEditingURL(for: leftDB, fallbackURL: leftTab.url)
            let leftTitle = leftTab.storedTitle ?? leftTab.title
            let rightURL = state.pinnedTabEditingURL(for: rightDB, fallbackURL: rightTab.url)
            let rightTitle = rightTab.storedTitle ?? rightTab.title

            EditPinnedTabPresenter.presentModal(
                mode: .pin,
                title: leftTitle,
                urlString: leftURL,
                secondaryUrlString: rightURL,
                secondaryTitleString: rightTitle,
                from: windowController.window
            ) { [weak windowController, weak leftTab, weak rightTab] result in
                guard let windowController, let leftTab, let rightTab else { return }
                let state = windowController.browserState
                Self.applyPinnedTabEdit(targetTab: leftTab,
                                        url: result.url,
                                        title: result.title,
                                        in: state)
                Self.applyPinnedTabEdit(targetTab: rightTab,
                                        url: result.secondaryUrl,
                                        title: result.secondaryTitle,
                                        in: state)
            }
            return
        }

        guard let pinnedTab = state.pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else {
            return
        }
        let initialURL = state.pinnedTabEditingURL(for: guid, fallbackURL: url)
        let initialTitle = pinnedTab.storedTitle ?? pinnedTab.title

        EditPinnedTabPresenter.presentModal(mode: .pin,
                                            title: initialTitle,
                                            urlString: initialURL,
                                            from: windowController.window) { [weak windowController, weak pinnedTab] result in
            guard let windowController, let pinnedTab else { return }
            let state = windowController.browserState
            Self.applyPinnedTabEdit(targetTab: pinnedTab,
                                    url: result.url,
                                    title: result.title,
                                    in: state)
        }
    }

    @MainActor
    static func applyPinnedTabEdit(targetTab: Tab,
                                   url rawURL: String?,
                                   title newTitle: String?,
                                   in state: BrowserState) {
        // The edit sheet can stay open while a scope migration replaces the
        // physical database guid. Scope sync retains and rebinds this Tab
        // object, so resolve its current guid only when Save is pressed.
        guard state.pinnedTabs.contains(where: { $0 === targetTab }),
              let pinnedGuid = targetTab.guidInLocalDB,
              !pinnedGuid.isEmpty,
              let rawURL,
              let normalizedURL = state.localStore.normalizedURL(from: rawURL) else { return }

        let normalizedString = normalizedURL.absoluteString
        let row = state.localStore.getTab(by: pinnedGuid)
        let displayTitle = row.map { $0.overrideTitle.flatMap { $0.isEmpty ? nil : $0 } ?? $0.title } ?? targetTab.title
        let nameChange: String?? = newTitle.flatMap { title in
            title.isEmpty ? .some(nil) : (title == displayTitle ? nil : .some(title))
        }
        state.localStore.updatePinnedTab(
            resolving: pinnedGuid,
            profileId: state.profileId,
            spaceId: state.spaceId,
            url: normalizedURL,
            title: nil,
            overrideTitle: nameChange
        )

        targetTab.pinnedUrl = normalizedString
        if targetTab.url != normalizedString {
            targetTab.url = normalizedString
        }
        if let nameChange {
            if let nameChange { targetTab.applyStoredTitle(nameChange) }
            else { targetTab.clearStoredTitle() }
        }
        if targetTab.isOpenned, let wrapper = targetTab.webContentWrapper {
            wrapper.updateTabCustomValue("")
            wrapper.navigate(toURL: normalizedString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak targetTab] in
                guard let currentGuid = targetTab?.guidInLocalDB else { return }
                wrapper.updateTabCustomValue(currentGuid)
            }
        }
    }

    @MainActor
    static var renameTabLabel: String {
        NSLocalizedString("sidebar.tabContextMenu.renameTab", value: "Rename Tab",
                          comment: "Tab name editor - Accessibility label of the field that renames a tab")
    }

    @MainActor
    @objc private func beginRenamingTab() {
        // Reset first: an editor that couldn't begin (its view off screen) leaves it set.
        isRenaming = false
        DispatchQueue.main.async { [weak self] in self?.isRenaming = true }
    }

    @MainActor
    @objc private func duplicateTab() {
        guard let tabURL = url, !tabURL.isEmpty else { return }
        contextMenuState?.createTab(tabURL, focusAfterCreate: true)
    }

    /// Builds the tab-group block of the right-click menu. Branches on
    /// `groupToken`:
    ///
    ///   * Ungrouped tab → "New Tab Group" + (when other groups exist)
    ///     "Add to Group ▶" submenu listing this window's groups in
    ///     strip order with color swatches.
    ///   * Grouped tab → move and remove commands, plus the start page
    ///     command for eligible tabs in the vertical sidebar.
    ///
    /// Skipped entirely for pinned tabs (Chromium's TabStripModel
    /// doesn't allow them in groups). Also skipped for
    /// bookmark-backed tabs, but only in sidebar layouts: there the
    /// tab's identity is the bookmark itself and group affiliation
    /// would conflict with the bookmark binding. In the Comfortable
    /// horizontal-strip layout these tabs are surfaced as regular
    /// tabs in the strip, so the group menu is available like any
    /// other tab.
    @MainActor
    private func appendTabGroupMenuItems(into items: inout [NSMenuItem]) {
        let browserState = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId)
        guard offersGroupAndWindowMenuItems(state: browserState) else {
            return
        }
        if groupToken == nil {
            let newGroupItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.newTabGroup", value: "New Tab Group",
                    comment: "Tab context menu - Add this tab to a newly created tab group"),
                action: #selector(addToNewTabGroup),
                keyEquivalent: "")
            newGroupItem.target = self
            items.append(newGroupItem)

            let orderedGroups = orderedGroupsInStripOrder(state: browserState)
            if !orderedGroups.isEmpty {
                let parent = NSMenuItem(
                    title: NSLocalizedString("sidebar.tabContextMenu.addToGroupSubmenu", value: "Add to Group",
                        comment: "Tab context menu - Submenu to add this tab to an existing tab group"),
                    action: nil,
                    keyEquivalent: "")
                let submenu = NSMenu()
                for group in orderedGroups {
                    let entry = NSMenuItem(
                        title: group.displayTitle,
                        action: #selector(addToExistingTabGroup(_:)),
                        keyEquivalent: "")
                    entry.target = self
                    entry.image = NSImage.tabGroupColorSwatch(for: group.color)
                    entry.representedObject = group.token
                    submenu.addItem(entry)
                }
                parent.submenu = submenu
                items.append(parent)
            }
        } else if let currentToken = groupToken {
            // Grouped tab: offer "Move to Group ▶" listing every other
            // group in this window plus "Remove from Group". The move
            // path reuses addTabsToGroup; Chromium's TabStripModel removes
            // the tab from its current group atomically before joining
            // the destination, so a single bridge call suffices.
            let otherGroups = orderedGroupsInStripOrder(state: browserState)
                .filter { $0.token != currentToken }
            if !otherGroups.isEmpty {
                let parent = NSMenuItem(
                    title: NSLocalizedString("sidebar.tabContextMenu.moveToGroupSubmenu", value: "Move to Group",
                        comment: "Tab context menu - Submenu to move this tab to another tab group"),
                    action: nil,
                    keyEquivalent: "")
                let submenu = NSMenu()
                for group in otherGroups {
                    let entry = NSMenuItem(
                        title: group.displayTitle,
                        action: #selector(addToExistingTabGroup(_:)),
                        keyEquivalent: "")
                    entry.target = self
                    entry.image = NSImage.tabGroupColorSwatch(for: group.color)
                    entry.representedObject = group.token
                    submenu.addItem(entry)
                }
                parent.submenu = submenu
                items.append(parent)
            }

            let moveToNewItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.moveToNewGroup", value: "Move to New Group",
                    comment: "Tab context menu - Move this tab out of its current group into a newly created group"),
                action: #selector(moveToNewTabGroup),
                keyEquivalent: "")
            moveToNewItem.target = self
            items.append(moveToNewItem)

            if browserState?.layoutMode.isTraditional == false, canHaveGroupStartPage {
                // Sidebar menus use AppKit's automatic item validation.
                let canSet = canSetGroupStartPage
                let setStartPageItem = NSMenuItem(
                    title: NSLocalizedString("sidebar.tabContextMenu.setStartPage", value: "Set Current Page as Start Page",
                        comment: "Tab context menu - Remember the current page as the grouped tab's start page"),
                    action: canSet ? #selector(setCurrentPageAsGroupStartPage) : nil,
                    keyEquivalent: "")
                setStartPageItem.target = self
                setStartPageItem.isEnabled = canSet
                items.append(setStartPageItem)
            }

            let removeItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.removeFromGroup", value: "Remove from Group",
                    comment: "Tab context menu - Remove this tab from its tab group"),
                action: #selector(removeFromTabGroup),
                keyEquivalent: "")
            removeItem.target = self
            items.append(removeItem)
        }
    }

    /// Pinned tabs, and bookmark-backed tabs in sidebar layouts, get neither
    /// the group items nor the window items; see `appendTabGroupMenuItems`.
    private func offersGroupAndWindowMenuItems(state: BrowserState?) -> Bool {
        if isPinned {
            return false
        }
        let inHorizontalStrip = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
            || (state?.bookmarksAreLaunchers ?? false)
        return inHorizontalStrip || !isBookmarkBackedTab(state: state)
    }

    /// Appends "Move to New Window", which becomes a "Move to Another
    /// Window ▶" submenu once another window can take this tab: "New Window",
    /// a separator, then one row per such window, frontmost first. A row
    /// stands for the Space its window shows. A split moves as a pair, as the
    /// group items treat it.
    @MainActor
    private func appendMoveToWindowMenuItems(into items: inout [NSMenuItem]) {
        let sourceState = SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
        guard let sourceState, webContentWrapper != nil,
              offersGroupAndWindowMenuItems(state: sourceState) else { return }

        let targets = moveToWindowTargets(from: sourceState)
        guard !targets.isEmpty else {
            let moveItem = NSMenuItem(
                title: NSLocalizedString("sidebar.tabContextMenu.moveToNewWindow", value: "Move to New Window",
                    comment: "Tab context menu - Move this tab into a newly created window"),
                action: #selector(moveToNewWindow),
                keyEquivalent: "")
            moveItem.target = self
            items.append(moveItem)
            return
        }

        let parent = NSMenuItem(
            title: NSLocalizedString("sidebar.tabContextMenu.moveToWindowSubmenu", value: "Move to Another Window",
                comment: "Tab context menu - Submenu to move this tab into a new window or another open window"),
            action: nil,
            keyEquivalent: "")
        let submenu = NSMenu()
        let newWindowItem = NSMenuItem(
            title: NSLocalizedString("sidebar.tabContextMenu.moveToWindowSubmenu.newWindow", value: "New Window",
                comment: "Tab context menu - Move to Another Window entry that moves this tab into a newly created window"),
            action: #selector(moveToNewWindow),
            keyEquivalent: "")
        newWindowItem.target = self
        submenu.addItem(newWindowItem)
        submenu.addItem(.separator())
        for target in targets {
            let active = target.focusingTab ?? target.tabs.last
            let activeTitle = active.map { $0.title.isEmpty ? ($0.url ?? "") : $0.title } ?? ""
            let entry = NSMenuItem(
                title: TabWindowMoveMenu.windowTitle(activeTabTitle: activeTitle,
                                                     otherTabCount: max(0, target.tabs.count - 1)),
                action: #selector(moveToExistingWindow(_:)),
                keyEquivalent: "")
            entry.target = self
            entry.representedObject = target.windowId
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        items.append(parent)
    }

    /// Windows this tab can move into, frontmost first: each window's
    /// presented Space, leaving out the tab's own window, windows without a
    /// tab strip (popups, apps, agent Spaces), and windows Chromium can't move
    /// it into (another profile, or a different off-the-record kind).
    @MainActor
    private func moveToWindowTargets(from sourceState: BrowserState) -> [BrowserState] {
        let sourceWindow = sourceState.windowController?.window
        let stripTypes: Set<ChromiumBrowserType> = [.normal, .incognito, .incognitoSpace]
        let candidates = SpaceSessionControllersManager.shared.getAllWindows().filter { controller in
            controller.isPresentedOrLegacy
                && controller.windowId != sourceState.windowId
                && (sourceWindow == nil || controller.window !== sourceWindow)
                && stripTypes.contains(controller.browserType)
                && controller.browserState.canAcceptCrossWindowDrag(from: sourceState)
        }
        let frontToBack = NSApp.orderedWindows
        func depth(_ controller: SpaceSessionController) -> Int {
            controller.window.flatMap { window in frontToBack.firstIndex { $0 === window } }
                ?? frontToBack.count
        }
        return candidates
            .sorted { (depth($0), $0.windowId) < (depth($1), $1.windowId) }
            .map(\.browserState)
    }

    /// Tears this tab (with its split partner) off into a new window, as a
    /// drag out of the strip does.
    @MainActor
    @objc private func moveToNewWindow() {
        guard let wrapper = webContentWrapper else { return }
        let state = SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
        // A bookmark-opened tab leaves its binding behind, as a tear-off does.
        graduateBookmarkBackedMembers(splitAwareGroupMemberIds(state: state), state: state)
        state?.seedNewTabBeforeMovingOut(tabIds: [guid])
        wrapper.moveSplit(toNewWindow: true)
    }

    /// Moves this tab (with its split partner) to the end of the chosen
    /// window's strip, then brings that window forward. Chromium activates the
    /// arriving tab there; both windows' tab lists follow its callbacks.
    @MainActor
    @objc private func moveToExistingWindow(_ sender: NSMenuItem) {
        guard let targetWindowId = sender.representedObject as? Int,
              let wrapper = webContentWrapper,
              let targetController = SpaceSessionControllersManager.shared.controller(for: targetWindowId) else {
            return
        }
        let sourceState = SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
        let targetState = targetController.browserState
        let memberIds = splitAwareGroupMemberIds(state: sourceState)
        graduateBookmarkBackedMembers(memberIds, state: sourceState)
        // A lone tab books its slot in the target's normal list, as the
        // Move to Space path does; a split arrives as a pair without one
        // (see `TabStrip.moveTabToWindow`).
        if memberIds.count == 1 {
            targetState.scheduleNormalTabInsertion(tabGuid: guid, at: targetState.normalTabs.count)
        }
        sourceState?.seedNewTabBeforeMovingOut(tabIds: [guid])
        wrapper.moveSplit(toWindow: targetState.windowId.int64Value, at: targetState.tabs.count)
        targetController.window?.makeKeyAndOrderFront(nil)
    }

    /// Appends a "Move to Space ▶" submenu listing every Space except the one
    /// this tab already lives in. Selecting a Space hands the tab to
    /// `SpaceManager.moveTab` — a true cross-window move when the target shares
    /// this tab's profile, or a URL re-open + origin-close across profiles.
    ///
    /// Restricted to plain normal tabs: pinned, split and bookmark-backed tabs
    /// carry per-Space persistence bindings (`guidInLocalDB` / the custom-value
    /// throttle mirror) that a move would strand, and Incognito windows have no
    /// Spaces at all. The submenu is also suppressed when the Spaces feature is
    /// off or no other Space exists.
    @MainActor
    private func appendMoveToSpaceMenuItems(into items: inout [NSMenuItem], isSplitCell: Bool) {
        guard !isPinned, !isSplitCell,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else { return }
        let sourceState = SpaceSessionControllersManager.shared.getBrowserState(for: windowId)
        guard let sourceState, !sourceState.isIncognito,
              !isBookmarkBackedTab(state: sourceState) else { return }

        // This window's own list: an agent Space hosted by another window is
        // not a destination offered here (`SpaceWindowSlot.presents`).
        let offered = SpaceManager.shared.slot(forWindowId: windowId)?.presentedSpaces
            ?? SpaceManager.shared.spaces
        let targets = offered.filter { $0.spaceId != sourceState.spaceId }
        guard !targets.isEmpty else { return }

        let parent = NSMenuItem(
            title: NSLocalizedString("sidebar.tabContextMenu.moveToSpaceSubmenu", value: "Move to Space",
                comment: "Tab context menu - Submenu to move this tab to another Space"),
            action: nil,
            keyEquivalent: "")
        let submenu = NSMenu()
        for space in targets {
            let entry = NSMenuItem(title: space.name,
                                   action: #selector(moveTabToSpace(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.image = SpaceIconView.menuImage(for: space.iconName)
            entry.representedObject = space.spaceId
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        items.append(parent)
    }

    @MainActor
    @objc private func moveTabToSpace(_ sender: NSMenuItem) {
        guard let targetSpaceId = sender.representedObject as? String else { return }
        SpaceManager.shared.moveTab(self, toSpaceId: targetSpaceId)
    }

    /// True iff this tab is a bookmark-backed tab (its `guidInLocalDB`
    /// resolves to a bookmark in this window's manager). Pinned tabs are
    /// excluded — they have their own localDB binding semantic.
    private func isBookmarkBackedTab(state: BrowserState?) -> Bool {
        guard !isPinned,
              let guid = guidInLocalDB, !guid.isEmpty,
              let state else { return false }
        return state.bookmarkManager.bookmark(withGuid: guid) != nil
    }

    /// Returns this window's tab groups in tab-strip order (first
    /// appearance of each token in `normalTabs`). Matches Chrome's
    /// "Add to Group" submenu ordering.
    private func orderedGroupsInStripOrder(state: BrowserState?)
        -> [WebContentGroupInfo] {
        guard let state else { return [] }
        var seen = Set<String>()
        var ordered: [WebContentGroupInfo] = []
        for tab in state.normalTabs {
            guard let token = tab.groupToken,
                  !seen.contains(token),
                  let info = state.groups[token] else { continue }
            seen.insert(token)
            ordered.append(info)
        }
        return ordered
    }

    /// Resolves both members of the non-pinned split this tab belongs to,
    /// in primary→secondary order. Returns just `[self.guid]` when the tab
    /// isn't part of a split. The bridge's group ops (`createGroupFromTabs`,
    /// `addTabsToGroup`, `removeTabsFromGroup`) already expand to whole-
    /// split membership Chromium-side via `ExpandIndicesToCoverSplits`, but
    /// the Mac-side optimistic update has to mirror that expansion or the
    /// partner's `groupToken` stays stale until `tabJoinedGroup` rides the
    /// async EventBus hop — the merged-cell invariant in
    /// `normalSplitCollapseInfo` (both panes share the same token) fails
    /// in the meantime and the right pane leaks as a stray chip.
    private func splitAwareGroupMemberIds(state: BrowserState?) -> [NSNumber] {
        var ids: [NSNumber] = [NSNumber(value: Int64(guid))]
        guard let state,
              let group = state.splitGroup(forTabId: guid),
              !group.isPinned,
              let partnerId = group.partnerTabId(of: guid) else {
            return ids
        }
        ids.append(NSNumber(value: Int64(partnerId)))
        return ids
    }

    /// Sheds the bookmark binding from any bookmark-opened member before a
    /// group op. Chromium's `createGroupFromTabs` / `addTabsToGroup` reject a
    /// batch that still contains a Phi-managed (`custom_value`) tab, so an
    /// ungraduated bookmark tab would silently drop the whole request. No-op
    /// for non-bookmark members.
    @MainActor
    private func graduateBookmarkBackedMembers(_ memberIds: [NSNumber], state: BrowserState?) {
        guard let state else { return }
        for member in memberIds {
            if let tab = state.tabs.first(where: { $0.guid == member.intValue }) {
                state.graduateBookmarkTabToPlainTab(tab)
            }
        }
    }

    @MainActor
    @objc private func addToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] addToNewTabGroup: no bridge available")
            return
        }
        let state = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId)
        let tabIds = splitAwareGroupMemberIds(state: state)
        // A bookmark-opened tab is Phi-managed (its bookmark guid lives in
        // `custom_value`); Chromium's `createGroupFromTabs` rejects the whole
        // batch if any member is Phi-managed, so the group would never form.
        // Graduate any bookmark-backed member into a plain tab first, matching
        // the drag-into-group path.
        graduateBookmarkBackedMembers(tabIds, state: state)
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] addToNewTabGroup: windowId=\(windowId) tabIds=\(tabIds) returned token=\(token)")
        if !token.isEmpty {
            for member in tabIds {
                state?.applyOptimisticGroupMembership(
                    tabId: member.intValue, newToken: token)
            }
        }
    }

    /// Move this (already-grouped) tab into a newly created group.
    /// Reuses `createGroupFromTabs`: Chromium's TabStripModel atomically
    /// detaches the tab from its current group before forming the new
    /// group, so a single bridge call suffices (no separate remove step).
    /// Chromium emits kClosed for the old group if this was its last tab.
    @MainActor
    @objc private func moveToNewTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: no bridge available")
            return
        }
        let state = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId)
        let tabIds = splitAwareGroupMemberIds(state: state)
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        AppLogDebug("[TAB_GROUPS] moveToNewTabGroup: windowId=\(windowId) tabIds=\(tabIds) returned token=\(token)")
        if !token.isEmpty {
            for member in tabIds {
                state?.applyOptimisticGroupMembership(
                    tabId: member.intValue, newToken: token)
            }
        }
    }

    @MainActor
    @objc private func addToExistingTabGroup(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              ChromiumLauncher.sharedInstance().bridge != nil,
              let state = SpaceSessionControllersManager.shared.getBrowserState(for: windowId) else {
            AppLogDebug("[TAB_GROUPS] addToExistingTabGroup: missing token, bridge or window")
            return
        }
        let tabIds = splitAwareGroupMemberIds(state: state)
        // Graduate any bookmark-opened member into a plain tab first; Chromium's
        // `addTabsToGroup` rejects the whole batch if any member is Phi-managed.
        graduateBookmarkBackedMembers(tabIds, state: state)
        state.addTabsToGroupEnd(tabIds.map(\.intValue), token: token)
        AppLogDebug("[TAB_GROUPS] addToExistingTabGroup windowId=\(windowId) tabIds=\(tabIds) token=\(token)")
    }

    @MainActor
    @objc private func removeFromTabGroup() {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else {
            AppLogDebug("[TAB_GROUPS] removeFromTabGroup: no bridge available")
            return
        }
        let state = SpaceSessionControllersManager.shared
            .getBrowserState(for: windowId)
        let tabIds = splitAwareGroupMemberIds(state: state)
        bridge.removeTabsFromGroup(withWindowId: Int64(windowId),
                                   tabIds: tabIds)
        AppLogDebug("[TAB_GROUPS] removeFromTabGroup windowId=\(windowId) tabIds=\(tabIds)")
        for member in tabIds {
            state?.applyOptimisticGroupMembership(
                tabId: member.intValue, newToken: nil)
        }
    }

    @MainActor
    @objc private func duplicateSplitTab() {
        guard let state = contextMenuState,
              let membership = state.splitMembership(forCellTab: self),
              let leftURL = membership.leftPane.url, !leftURL.isEmpty,
              let rightURL = membership.rightPane.url, !rightURL.isEmpty else {
            return
        }
        let layout = membership.liveGroup?.layout
            ?? membership.pinnedDBPair.map {
                state.pinnedSplitLayout(leftDB: $0.left, rightDB: $0.right)
            }
            ?? .vertical
        state.openTwoURLsAsSplit(primaryURL: leftURL,
                                 secondaryURL: rightURL,
                                 layout: layout)
    }

    @objc private func copySplitPaneURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, !urlString.isEmpty else {
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(URLProcessor.phiBrandEnsuredUrlString(urlString), forType: .string)
    }

    @MainActor
    @objc private func openAsSplit() {
        guard let state = contextMenuState else { return }
        // Unopened pinned cell: `guid` here is the synthetic id on the
        // pinned record, not a live Chromium tab. Route through the
        // pinned-URL materialization path so a real partner tab exists
        // by the time the split is formed.
        if !isOpenned,
           let pinnedDBGuid = guidInLocalDB, !pinnedDBGuid.isEmpty {
            let pinnedURLString = pinnedUrl ?? url ?? ""
            if !pinnedURLString.isEmpty {
                state.openNewTabAsSplitFromUnopenedPinned(pinnedDBGuid: pinnedDBGuid,
                                                          url: pinnedURLString)
                return
            }
        }
        state.openNewTabAsSplit(partnerTabId: guid)
    }

    /// "Split with Current": pairs this tab with the currently focused tab
    /// as a vertical split — focused tab stays on the left, this tab takes
    /// the right pane. Both members are normalized first so the split
    /// doesn't inherit pinned-ness or a bookmark binding (mirrors the
    /// drag-onto-page flows in `SplitTabDropContainer`).
    @MainActor
    @objc private func splitWithCurrent() {
        guard let state = contextMenuState,
              let focusedId = state.focusingTab?.guid,
              state.splitGroup(forTabId: focusedId) == nil else { return }
        // Unopened pinned cell: `guid` is synthetic, so there is no live tab
        // to pair. Open the pinned URL as a fresh pane next to the focused
        // tab and leave the pinned record intact (mirrors
        // `performSplitDropFromPinned`'s closed-pinned fallback).
        if !isOpenned, let pinnedDBGuid = guidInLocalDB, !pinnedDBGuid.isEmpty {
            let pinnedURLString = pinnedUrl ?? url ?? ""
            guard !pinnedURLString.isEmpty else { return }
            state.makeTabNormalOpened(tabId: focusedId)
            state.openNewTabAsSplit(partnerTabId: focusedId,
                                    partnerNavigateURL: URLProcessor.processUserInput(pinnedURLString))
            return
        }
        guard guid != focusedId else { return }
        state.makeTabNormalOpened(tabId: guid)
        state.makeTabNormalOpened(tabId: focusedId)
        state.createSplit(leftTabId: focusedId, rightTabId: guid, layout: .vertical)
    }

    @MainActor
    @objc private func removeFromSplit(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String else { return }
        state.removeSplit(splitId)
    }

    @MainActor
    @objc private func reverseSplitPanes(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String else { return }
        state.reverseTabsInSplit(splitId)
    }

    @MainActor
    @objc private func convertSplitLayout(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let splitId = sender.representedObject as? String,
              let group = state.splitGroup(forId: splitId) else { return }
        state.updateSplitLayout(splitId, layout: group.layout.toggled)
    }

    @MainActor
    @objc private func convertClosedPinnedSplitLayout(_ sender: NSMenuItem) {
        guard let state = contextMenuState,
              let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let layout = state.pinnedSplitLayout(leftDB: pair[0], rightDB: pair[1])
        state.updatePinnedSplitLayout(leftDB: pair[0], rightDB: pair[1], layout: layout.toggled)
    }
}
