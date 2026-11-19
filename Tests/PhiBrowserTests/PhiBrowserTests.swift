// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

private final class BookmarkMenuTestTarget: NSObject {
    @objc func menuAction(_ sender: Any?) {}
}
import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import Phi

final class PhiBrowserTests: XCTestCase {

    /// In-memory fixtures never write the signed-in account's configuration.
    private var shortcutOverrides: [CommandWrapper: ShortcutOverride] {
        get {
            Dictionary(uniqueKeysWithValues: Shortcuts.configuration.overrides.compactMap { id, value in
                CommandWrapper(rawValue: id).map { ($0, value) }
            })
        }
        set {
            Shortcuts.configuration = ShortcutConfiguration(
                overrides: Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }),
                fileURL: Shortcuts.configuration.fileURL,
                files: .init(
                    read: { _ in throw CocoaError(.fileReadNoPermission) },
                    write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                    backup: { _, _ in throw CocoaError(.fileWriteNoPermission) }
                )
            )
        }
    }

    private enum InputSource {
        static let us = "com.apple.keylayout.US"
        static let russian = "com.apple.keylayout.Russian"
        static let dvorak = "com.apple.keylayout.Dvorak"
        static let dvorakCommandQWERTY = "com.apple.keylayout.DVORAK-QWERTYCMD"
        static let hebrewQWERTY = "com.apple.keylayout.Hebrew-QWERTY"
        static let arabicAZERTY = "com.apple.keylayout.Arabic-AZERTY"
    }

    private func makeShortcutKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = UInt16(kVK_ANSI_C)
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    func testCopyURLShortcutIsCustomizableFromEditShortcuts() {
        XCTAssertEqual(
            Shortcuts.DefaultShortcuts[.PHI_COPY_URL],
            ShortcutsKey(characters: "c", modifiers: [.command, .shift])
        )
        XCTAssertTrue(Shortcuts.Group.edit.commands.contains(.PHI_COPY_URL))
        XCTAssertEqual(CommandWrapper.PHI_COPY_URL.displayName, "Copy URL")
    }

    func testAlternateNewTabFollowsNewTabInFileShortcuts() {
        XCTAssertEqual(Array(Shortcuts.Group.file.commands.prefix(3)),
                       [.IDC_NEW_TAB, .PHI_ALTERNATE_NEW_TAB, .IDC_NEW_WINDOW])
        XCTAssertEqual(CommandWrapper.PHI_ALTERNATE_NEW_TAB.displayName, "Alternate New Tab")
    }

    private func matchedPeekCommand(for event: NSEvent, inputSourceIdentifier: String) -> CommandWrapper? {
        guard let keys = ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: inputSourceIdentifier) else { return nil }
        return Shortcuts.Group.peek.commands.first { keys.matches(Shortcuts.key(for: $0)) }
    }

    func testPeekSpaceShortcutsIgnoreOrdinaryWindowOverrides() throws {
        let previousConfiguration = Shortcuts.configuration
        defer {
            Shortcuts.configuration = previousConfiguration
            CommandDispatcher.reloadPhiShortcutMap()
        }
        shortcutOverrides = [:]
        CommandDispatcher.reloadPhiShortcutMap()
        shortcutOverrides[.IDC_OPEN_FILE] = .custom(ShortcutsKey(
            characters: "p", modifiers: [.command, .shift]
        ))
        shortcutOverrides[.PHI_TOGGLE_SIDEBAR] = .disabled

        let event = try makeShortcutKeyEvent(
            characters: "o", charactersIgnoringModifiers: "o",
            modifiers: .command, keyCode: UInt16(kVK_ANSI_O)
        )
        XCTAssertEqual(matchedPeekCommand(
            for: event, inputSourceIdentifier: InputSource.us
        ), .PHI_PEEK_OPEN_IN_SPACE)
        XCTAssertNil(CommandDispatcher.interceptedPhiCommand(
            for: event, inputSourceIdentifier: InputSource.us
        ))
    }

    func testPeekSpaceShortcutsSupportRebindingDisablingAndRestoring() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides = [:]
        let command = CommandWrapper.PHI_PEEK_OPEN_IN_SPACE
        let originalEvent = try makeShortcutKeyEvent(
            characters: "o", charactersIgnoringModifiers: "o",
            modifiers: .command, keyCode: UInt16(kVK_ANSI_O)
        )
        let customEvent = try makeShortcutKeyEvent(
            characters: "o", charactersIgnoringModifiers: "o",
            modifiers: [.command, .control], keyCode: UInt16(kVK_ANSI_O)
        )
        shortcutOverrides[command] = .custom(ShortcutsKey(
            characters: "o", modifiers: [.command, .control]
        ))
        XCTAssertNil(matchedPeekCommand(
            for: originalEvent, inputSourceIdentifier: InputSource.us
        ))
        XCTAssertEqual(matchedPeekCommand(
            for: customEvent, inputSourceIdentifier: InputSource.us
        ), command)

        shortcutOverrides[command] = .disabled
        XCTAssertNil(matchedPeekCommand(
            for: customEvent, inputSourceIdentifier: InputSource.us
        ))
        XCTAssertNil(matchedPeekCommand(
            for: originalEvent, inputSourceIdentifier: InputSource.us
        ))
        shortcutOverrides.removeValue(forKey: command)
        XCTAssertEqual(matchedPeekCommand(
            for: originalEvent, inputSourceIdentifier: InputSource.us
        ), command)
        XCTAssertEqual(Shortcuts.key(for: .PHI_TOGGLE_SIDEBAR),
                       Shortcuts.DefaultShortcuts[.PHI_TOGGLE_SIDEBAR])
        XCTAssertEqual(Shortcuts.key(for: .IDC_OPEN_FILE),
                       Shortcuts.DefaultShortcuts[.IDC_OPEN_FILE])
    }

    @MainActor
    func testPeekShortcutSettingsIgnoreCommandsUnavailableInPeek() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides = [:]
        let viewModel = ShortcutsViewModel()

        for command in [
            CommandWrapper.PHI_TOGGLE_CHATBAR,
            .IDC_TAB_SEARCH, .IDC_DEV_TOOLS,
        ] {
            shortcutOverrides[.PHI_PEEK_OPEN_IN_SPACE] =
                .custom(try XCTUnwrap(Shortcuts.key(for: command)))
            viewModel.rebuildSections()
            let items = viewModel.sections.flatMap(\.items)
            let expansion = try XCTUnwrap(items.first {
                $0.command == .PHI_PEEK_OPEN_IN_SPACE
            })
            let other = try XCTUnwrap(items.first { $0.command == command })
            XCTAssertFalse(expansion.hasConflict, "Unexpected conflict with \(command)")
            XCTAssertFalse(other.conflictingCommandNames.contains(expansion.name))
        }

        shortcutOverrides[.PHI_PEEK_OPEN_IN_SPACE] =
            .custom(try XCTUnwrap(Shortcuts.key(for: .PHI_TOGGLE_CHATBAR)))
        let event = try makeShortcutKeyEvent(
            characters: "e", charactersIgnoringModifiers: "e",
            modifiers: [.command], keyCode: UInt16(kVK_ANSI_E)
        )
        XCTAssertEqual(matchedPeekCommand(
            for: event, inputSourceIdentifier: InputSource.us
        ), .PHI_PEEK_OPEN_IN_SPACE)
    }

    @MainActor
    func testPeekShortcutSettingsSeparateWindowContextsButReportSharedConflicts() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides = [:]
        let viewModel = ShortcutsViewModel()
        let section = try XCTUnwrap(viewModel.sections.first {
            $0.category == Shortcuts.Group.peek.title
        })
        XCTAssertEqual(section.items.map(\.command), Shortcuts.Group.peek.commands)
        XCTAssertTrue(section.items.allSatisfy { !$0.hasConflict })

        shortcutOverrides[.PHI_PEEK_OPEN_IN_SPACE] =
            .custom(try XCTUnwrap(Shortcuts.key(for: .PHI_COPY_URL)))
        viewModel.rebuildSections()
        let items = viewModel.sections.flatMap(\.items)
        XCTAssertTrue(try XCTUnwrap(items.first {
            $0.command == .PHI_PEEK_OPEN_IN_SPACE
        }).hasConflict)
        XCTAssertTrue(try XCTUnwrap(items.first {
            $0.command == .PHI_COPY_URL
        }).hasConflict)
        XCTAssertFalse(try XCTUnwrap(items.first {
            $0.command == .PHI_TOGGLE_SIDEBAR
        }).hasConflict)
    }

    func testFileMenuInstallsAlternateNewTabAfterNewTabWithoutDuplicates() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides.removeValue(forKey: .PHI_ALTERNATE_NEW_TAB)

        let menu = NSMenu(title: "File")
        for command in [CommandWrapper.IDC_NEW_WINDOW, .IDC_NEW_TAB, .IDC_NEW_INCOGNITO_WINDOW] {
            let item = NSMenuItem(title: "Existing command", action: nil, keyEquivalent: "")
            item.tag = command.rawValue
            menu.addItem(item)
        }
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)

        let items = menu.items.filter { $0.tag == CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        let newTabIndex = try XCTUnwrap(menu.items.firstIndex { $0.tag == CommandWrapper.IDC_NEW_TAB.rawValue })
        XCTAssertEqual(menu.items.firstIndex(of: item), newTabIndex + 1)
        XCTAssertEqual(item.title, NSLocalizedString("app.fileMenu.alternateNewTab", value: "Alternate New Tab",
            comment: "File menu and Shortcuts settings - Command title for opening the opposite of the configured New Tab action"))
        XCTAssertEqual(item.action, NSSelectorFromString("alternateNewTabFromMenu:"))
        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])

        shortcutOverrides[.PHI_ALTERNATE_NEW_TAB] = .custom(.init(characters: "j", modifiers: [.control, .command]))
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        let customized = try XCTUnwrap(menu.items.first { $0.tag == CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue })
        XCTAssertEqual(customized.keyEquivalent, "j")
        XCTAssertEqual(customized.keyEquivalentModifierMask, [.control, .command])

        shortcutOverrides[.PHI_ALTERNATE_NEW_TAB] = .disabled
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        let disabled = try XCTUnwrap(menu.items.first { $0.tag == CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue })
        XCTAssertTrue(disabled.keyEquivalent.isEmpty)
        XCTAssertEqual(disabled.keyEquivalentModifierMask.rawValue, 0)
    }

    func testFileMenuAlternateNewTabFallsBackToFirstItem() {
        let menu = NSMenu(title: "File")
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        XCTAssertEqual(menu.items.first?.tag, CommandWrapper.PHI_ALTERNATE_NEW_TAB.rawValue)
    }

    @MainActor func testAppsMenuFollowsSpacesWithoutDuplicates() throws {
        let menu = NSMenu(title: "Main")
        let spaces = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
        spaces.tag = AppController.spacesMenuItemTag
        menu.addItem(spaces)
        let target = AppController.shared
        for _ in 0..<3 {
            AppController.installOrUpdateAppsMenu(in: menu, target: target)
            let apps = try XCTUnwrap(menu.items.first { $0.tag == AppController.appsMenuItemTag })
            XCTAssertEqual(menu.items.filter { $0.tag == AppController.appsMenuItemTag }.count, 1)
            XCTAssertEqual(menu.items.firstIndex(of: apps), try XCTUnwrap(menu.items.firstIndex(of: spaces)) + 1)
            let items = try XCTUnwrap(apps.submenu?.items)
            XCTAssertEqual(items.count, 5)
            XCTAssertTrue(items[3].isSeparatorItem)
            XCTAssertEqual(items[4].title, "New Drifter Chat")
            XCTAssertEqual(items[4].tag, CommandWrapper.PHI_NEW_DRIFTER_CHAT.rawValue)
            XCTAssertEqual(items[4].keyEquivalent, "")
            let rows = Array(items.prefix(3))
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows.map(\.title), MistAppID.allCases.map(\.name))
            XCTAssertEqual(rows.map(\.tag), [CommandWrapper.PHI_OPEN_CLIPBOARD.rawValue, CommandWrapper.PHI_OPEN_DRIFTER.rawValue, CommandWrapper.PHI_OPEN_MAIL.rawValue])
            XCTAssertEqual(rows.map(\.keyEquivalent), ["", "D", ""])
            XCTAssertEqual(rows[1].keyEquivalentModifierMask, .command)
            let mail = try XCTUnwrap(rows.last)
            XCTAssertEqual(mail.title, "Mail")
            XCTAssertEqual(mail.tag, CommandWrapper.PHI_OPEN_MAIL.rawValue)
            XCTAssertEqual(mail.action, NSSelectorFromString("openMistApp:"))
            XCTAssertEqual(mail.representedObject as? String, MistAppID.mail.rawValue)
            XCTAssertTrue(mail.target === target)
            XCTAssertEqual(mail.image?.size, NSSize(width: 16, height: 16))
        }
    }

    func testFileMenuDoesNotOfferMail() {
        let menu = NSMenu(title: "File")
        for _ in 0..<2 { AppController.installOrUpdateFileMenuItems(in: menu, target: nil) }
        XCTAssertFalse(menu.items.contains { $0.tag == CommandWrapper.PHI_OPEN_MAIL.rawValue })
    }

    func testFileMenuInstallsPhiItemsBelowIncognitoWindow() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides.removeValue(forKey: .PHI_NEW_INCOGNITO_SPACE)

        let menu = NSMenu(title: "File")
        let incognitoItem = NSMenuItem(
            title: "New Incognito Window",
            action: nil,
            keyEquivalent: ""
        )
        incognitoItem.tag = CommandWrapper.IDC_NEW_INCOGNITO_WINDOW.rawValue
        menu.addItem(incognitoItem)

        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)

        let incognitoSpaceItems = menu.items.filter {
            $0.tag == CommandWrapper.PHI_NEW_INCOGNITO_SPACE.rawValue
        }
        let incognitoSpaceItem = try XCTUnwrap(incognitoSpaceItems.first)
        let incognitoIndex = try XCTUnwrap(menu.items.firstIndex(of: incognitoItem))
        let incognitoSpaceIndex = try XCTUnwrap(
            menu.items.firstIndex(of: incognitoSpaceItem)
        )

        XCTAssertEqual(incognitoSpaceItems.count, 1)
        XCTAssertEqual(incognitoSpaceIndex, incognitoIndex + 1)
        XCTAssertEqual(
            incognitoSpaceItem.title,
            NSLocalizedString(
                "app.fileMenu.createNewIncognitoSpace",
                value: "New Incognito Space",
                comment: "File menu and Shortcuts settings - Command title for creating a new Incognito Space"
            )
        )
        XCTAssertEqual(
            incognitoSpaceItem.action,
            NSSelectorFromString("newIncognitoSpaceFromMenu:")
        )
        XCTAssertEqual(incognitoSpaceItem.keyEquivalent, "")
        XCTAssertEqual(
            incognitoSpaceItem.keyEquivalentModifierMask,
            []
        )

        shortcutOverrides[.PHI_NEW_INCOGNITO_SPACE] = .custom(ShortcutsKey(
            characters: "i",
            modifiers: [.command, .control]
        ))
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        let customizedIncognitoSpaceItem = try XCTUnwrap(menu.items.first {
            $0.tag == CommandWrapper.PHI_NEW_INCOGNITO_SPACE.rawValue
        })
        XCTAssertEqual(customizedIncognitoSpaceItem.keyEquivalent, "")
        XCTAssertEqual(
            customizedIncognitoSpaceItem.keyEquivalentModifierMask,
            []
        )
    }

    func testFileMenuInstallsSharePageAbovePrintAndRemovesChromiumShareSubmenu() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides.removeValue(forKey: .PHI_SHARE_PAGE)

        let menu = NSMenu(title: "File")
        menu.addItem(.separator())
        let chromiumShareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        chromiumShareItem.submenu = NSMenu(title: "Share")
        menu.addItem(chromiumShareItem)
        menu.addItem(.separator())
        let printItem = NSMenuItem(title: "Print…", action: nil, keyEquivalent: "")
        printItem.tag = CommandWrapper.IDC_PRINT.rawValue
        menu.addItem(printItem)

        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)

        let shareItems = menu.items.filter {
            $0.tag == CommandWrapper.PHI_SHARE_PAGE.rawValue
        }
        let shareItem = try XCTUnwrap(shareItems.first)
        let shareIndex = try XCTUnwrap(menu.items.firstIndex(of: shareItem))
        let printIndex = try XCTUnwrap(menu.items.firstIndex(of: printItem))

        XCTAssertEqual(shareItems.count, 1)
        XCTAssertEqual(shareIndex, printIndex - 1)
        let screenshotItems = menu.items.filter {
            $0.action == NSSelectorFromString("copyFullPageScreenshotFromMenu:")
        }
        let screenshotItem = try XCTUnwrap(screenshotItems.first)
        XCTAssertEqual(screenshotItems.count, 1)
        XCTAssertEqual(menu.items.firstIndex(of: screenshotItem), shareIndex - 2)
        let areaItems = menu.items.filter { $0.action == NSSelectorFromString("capturePageAreaFromMenu:") }
        XCTAssertEqual(areaItems.count, 1)
        XCTAssertEqual(menu.items.firstIndex(of: try XCTUnwrap(areaItems.first)), shareIndex - 1)
        XCTAssertEqual(screenshotItem.keyEquivalent, "!")
        // The shifted printable key already carries Shift in AppKit's menu equivalent.
        XCTAssertEqual(screenshotItem.keyEquivalentModifierMask, [.command])
        XCTAssertFalse(screenshotItem.isHidden)
        XCTAssertEqual(
            shareItem.action,
            NSSelectorFromString("sharePageFromMenu:")
        )
        XCTAssertEqual(shareItem.keyEquivalent, "")
        XCTAssertEqual(shareItem.keyEquivalentModifierMask, [])
        XCTAssertFalse(shareItem.isHidden)
        XCTAssertFalse(menu.items.contains(chromiumShareItem))
        for index in 1..<menu.items.count {
            XCTAssertFalse(
                menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem,
                "adjacent separators left behind at index \(index)"
            )
        }

        shortcutOverrides[.PHI_SHARE_PAGE] = .custom(ShortcutsKey(
            characters: "u",
            modifiers: [.command, .control]
        ))
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        let customizedItem = try XCTUnwrap(menu.items.first {
            $0.tag == CommandWrapper.PHI_SHARE_PAGE.rawValue
        })
        XCTAssertEqual(customizedItem.keyEquivalent, "")
        XCTAssertEqual(
            customizedItem.keyEquivalentModifierMask,
            []
        )
    }

    func testFileMenuKeepsTheCloseRowChromiumHidesWhileNoTabbedWindowIsKey() {
        // The live File menu as Chromium lays it out while no tabbed browser
        // window is key: the Shift-Cmd-W row is parked hidden with tag 0 and
        // no action, and the Cmd-W row acts as Close Window. The hook re-runs
        // on this menu (the agent CDP switch); deleting the
        // parked row leaves Chromium nothing to swap Close Tab back onto.
        let menu = NSMenu(title: "File")
        menu.addItem(.separator())
        let parkedCloseItem = NSMenuItem(title: "Close Window", action: nil, keyEquivalent: "W")
        parkedCloseItem.keyEquivalentModifierMask = .command
        parkedCloseItem.isHidden = true
        menu.addItem(parkedCloseItem)
        let closeAllItem = NSMenuItem(
            title: "Close All",
            action: NSSelectorFromString("closeAll:"),
            keyEquivalent: "W"
        )
        closeAllItem.keyEquivalentModifierMask = [.command, .option]
        closeAllItem.isAlternate = true
        menu.addItem(closeAllItem)
        let cmdWItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        cmdWItem.tag = CommandWrapper.IDC_CLOSE_WINDOW.rawValue
        menu.addItem(cmdWItem)
        menu.addItem(.separator())
        let chromiumShareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        menu.addItem(chromiumShareItem)
        menu.addItem(.separator())
        let printItem = NSMenuItem(title: "Print…", action: nil, keyEquivalent: "")
        printItem.tag = CommandWrapper.IDC_PRINT.rawValue
        menu.addItem(printItem)

        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)

        XCTAssertTrue(menu.items.contains(parkedCloseItem))
        XCTAssertFalse(menu.items.contains(chromiumShareItem))
    }

    func testInputSourceIdentifierSelectionPrefersTextContextAndUsesSystemFallback() {
        var systemLookupCount = 0
        XCTAssertEqual(
            ShortcutsKey.resolvedInputSourceIdentifier(
                textInputContextIdentifier: InputSource.russian,
                systemInputSourceIdentifier: {
                    systemLookupCount += 1
                    return InputSource.hebrewQWERTY
                }
            ),
            InputSource.russian
        )
        XCTAssertEqual(systemLookupCount, 0)
        XCTAssertEqual(
            ShortcutsKey.resolvedInputSourceIdentifier(
                textInputContextIdentifier: nil,
                systemInputSourceIdentifier: {
                    systemLookupCount += 1
                    return InputSource.hebrewQWERTY
                }
            ),
            InputSource.hebrewQWERTY
        )
        XCTAssertEqual(systemLookupCount, 1)
    }

    func testPhiShortcutMatchingFallsBackToASCIICommandCharacterForCyrillicInputSource() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [copyURLKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testCyrillicCommandCaptureMatchesLatinDefaultShortcut() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        XCTAssertEqual(recordedKey, copyURLKey)
        XCTAssertEqual(recordedKey.characters, "c")
        XCTAssertEqual(recordedKey.displayString, "⇧⌘C")
    }

    func testCyrillicCommandCaptureUsesLatinShiftedMenuEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "P",
            charactersIgnoringModifiers: "\u{0417}",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_P)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let menuKey = recordedKey.menuKeyEquivalent

        XCTAssertEqual(recordedKey.characters, "p")
        XCTAssertEqual(recordedKey.modifiers, [.command, .shift])
        XCTAssertEqual(recordedKey.displayString, "⇧⌘P")
        XCTAssertEqual(menuKey.characters, "P")
        XCTAssertEqual(menuKey.modifiers, [.command])
    }

    func testShiftedPrintableShortcutProjectsToSameMenuIdentity() {
        let recordedKey = ShortcutsKey(
            characters: "+",
            modifiers: [.command, .shift]
        )
        let existingKey = ShortcutsKey(characters: "+", modifiers: [.command])

        XCTAssertEqual(recordedKey.menuKeyEquivalent, existingKey.menuKeyEquivalent)
    }

    func testQuitShortcutMatchesConfiguredKeyOrCommandQ() {
        let commandQ = ShortcutsKey(characters: "q", modifiers: .command)
        let controlOptionQ = ShortcutsKey(
            characters: "q",
            modifiers: [.control, .option]
        )
        let commandW = ShortcutsKey(characters: "w", modifiers: .command)
        let cyrillicCommandQ = ShortcutsKey(
            characters: "\u{0439}",
            modifiers: .command
        )
        let cases: [(
            name: String,
            eventKeys: ShortcutsKey.EventKeys,
            configuredQuitKey: ShortcutsKey?,
            confirms: Bool
        )] = [
            (
                "default ⌘Q",
                .init(canonical: commandQ, legacy: nil),
                nil,
                true
            ),
            (
                "custom ⌃⌥Q hit",
                .init(canonical: controlOptionQ, legacy: nil),
                controlOptionQ,
                true
            ),
            (
                "custom ⌃⌥Q rejects ⌘Q",
                .init(canonical: commandQ, legacy: nil),
                controlOptionQ,
                false
            ),
            // Recording lowercases characters, so an uppercase stored key only
            // arrives through legacy data; the row is here to exercise the
            // menu-equivalent leg, which no recorded key reaches for Quit.
            (
                "shifted key shares the menu equivalent",
                .init(
                    canonical: ShortcutsKey(
                        characters: "q",
                        modifiers: [.command, .shift]
                    ),
                    legacy: nil
                ),
                ShortcutsKey(characters: "Q", modifiers: .command),
                true
            ),
            (
                "legacy non-Latin key",
                .init(canonical: commandQ, legacy: cyrillicCommandQ),
                cyrillicCommandQ,
                true
            ),
            (
                "⌘W is not Quit",
                .init(canonical: commandW, legacy: nil),
                nil,
                false
            ),
            (
                "⌘Q with extra modifier is not Quit",
                .init(
                    canonical: ShortcutsKey(
                        characters: "q",
                        modifiers: [.command, .option]
                    ),
                    legacy: nil
                ),
                nil,
                false
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PhiAlert.isQuitShortcut(
                    testCase.eventKeys,
                    configuredQuitKey: testCase.configuredQuitKey
                ),
                testCase.confirms,
                testCase.name
            )
        }
    }

    func testShortcutViewModelReportsMenuEquivalentConflict() throws {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides = [
            .IDC_RELOAD: .custom(ShortcutsKey(
                characters: "+",
                modifiers: [.command, .shift]
            )),
            .IDC_NEW_WINDOW: .custom(ShortcutsKey(
                characters: "+",
                modifiers: [.command]
            )),
        ]

        let viewModel = ShortcutsViewModel()
        let items = viewModel.sections.flatMap(\.items)
        let backItem = try XCTUnwrap(
            items.first { $0.command == .IDC_RELOAD }
        )
        let forwardItem = try XCTUnwrap(
            items.first { $0.command == .IDC_NEW_WINDOW }
        )

        XCTAssertTrue(backItem.hasConflict)
        XCTAssertTrue(forwardItem.hasConflict)
    }

    func testShiftedBracketCaptureKeepsShiftedIdentity() throws {
        let event = try makeShortcutKeyEvent(
            characters: "]",
            charactersIgnoringModifiers: "}",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(
            recordedKey,
            ShortcutsKey(characters: "}", modifiers: [.command, .shift])
        )
    }

    func testNativeMenuWriterProjectsChatPanelDefault() {
        let command = CommandWrapper.PHI_TOGGLE_CHATBAR
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides.removeValue(forKey: command)

        let item = NSMenuItem(
            title: "Toggle Chatbar",
            action: nil,
            keyEquivalent: "s"
        )
        item.tag = command.rawValue
        item.keyEquivalentModifierMask = [.command, .shift]

        Shortcuts.updateShortcut(for: item)

        XCTAssertEqual(item.keyEquivalent, "e")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }

    func testPhiShortcutMatchingUsesShiftedPrintableExecutionIdentity() throws {
        let event = try makeShortcutKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "+",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Equal)
        )
        let existingKey = ShortcutsKey(characters: "+", modifiers: [.command])

        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [existingKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.us
            ),
            .PHI_COPY_URL
        )
    }

    func testShortcutMatchingPrefersExactStoredKeyOverMenuEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "+", charactersIgnoringModifiers: "+",
            modifiers: [.command, .shift], keyCode: UInt16(kVK_ANSI_Equal)
        )
        let exact = ShortcutsKey(characters: "+", modifiers: [.command, .shift])
        let equivalent = ShortcutsKey(characters: "+", modifiers: .command)
        let keys = try XCTUnwrap(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: InputSource.us))
        XCTAssertTrue(keys.matches(exact))
        XCTAssertTrue(keys.matches(equivalent))
        XCTAssertFalse(keys.matches(nil))
        XCTAssertFalse(keys.matches(ShortcutsKey(characters: "+", modifiers: [.command, .option])))
        XCTAssertEqual(CommandDispatcher.matchedPhiCommand(
            for: event, shortcutMap: [equivalent: .PHI_COPY_URL, exact: .PHI_TOGGLE_READER],
            inputSourceIdentifier: InputSource.us
        ), .PHI_TOGGLE_READER)
    }

    func testShortcutMenuEquivalentTieUsesStableCommandOrder() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C", charactersIgnoringModifiers: "C", modifiers: [.command, .shift]
        )
        // Both stored forms project to Command-Capital-C, while neither is
        // the canonical lower-case c plus Shift. Old files can contain both.
        let first = ShortcutsKey(characters: "C", modifiers: .command)
        let second = ShortcutsKey(characters: "C", modifiers: [.command, .shift])
        XCTAssertEqual(first.menuKeyEquivalent, second.menuKeyEquivalent)
        let expected = [CommandWrapper.PHI_COPY_URL, .PHI_TOGGLE_READER].min { $0.rawValue < $1.rawValue }
        for pairs in [[(first, CommandWrapper.PHI_COPY_URL), (second, .PHI_TOGGLE_READER)],
                      [(second, CommandWrapper.PHI_TOGGLE_READER), (first, .PHI_COPY_URL)]] {
            XCTAssertEqual(CommandDispatcher.matchedPhiCommand(
                for: event, shortcutMap: Dictionary(uniqueKeysWithValues: pairs),
                inputSourceIdentifier: InputSource.us
            ), expected)
        }
    }

    func testLatinAndCyrillicEventsResolveToSameCanonicalShortcut() throws {
        let latinEvent = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "C",
            modifiers: [.command, .shift]
        )
        let cyrillicEvent = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let latinKeys = try XCTUnwrap(
            ShortcutsKey.eventKeys(
                for: latinEvent,
                inputSourceIdentifier: InputSource.us
            )
        )
        let cyrillicKeys = try XCTUnwrap(
            ShortcutsKey.eventKeys(
                for: cyrillicEvent,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let shortcutMap = [latinKeys.canonical: CommandWrapper.PHI_COPY_URL]

        XCTAssertEqual(cyrillicKeys.canonical, latinKeys.canonical)
        XCTAssertNil(latinKeys.legacy)
        XCTAssertEqual(
            cyrillicKeys.legacy,
            ShortcutsKey(characters: "\u{0441}", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: latinEvent,
                shortcutMap: shortcutMap,
                inputSourceIdentifier: InputSource.us
            ),
            .PHI_COPY_URL
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: cyrillicEvent,
                shortcutMap: shortcutMap,
                inputSourceIdentifier: InputSource.russian
            ),
            .PHI_COPY_URL
        )
    }

    func testPhiShortcutMatchingPrefersCanonicalLatinBinding() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let cyrillicKey = ShortcutsKey(
            characters: "\u{0441}",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [
                cyrillicKey: .PHI_NEW_CONVERSATION,
                copyURLKey: .PHI_COPY_URL,
            ],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testPhiShortcutMatchingUsesLegacyNonLatinBindingWhenCanonicalIsUnassigned() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let cyrillicKey = ShortcutsKey(
            characters: "\u{0441}",
            modifiers: [.command, .shift]
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [cyrillicKey: .PHI_NEW_CONVERSATION],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_NEW_CONVERSATION)
    }

    func testPhiShortcutMatchingDoesNotFallbackWhenIgnoringModifiersIsASCII() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )
        let physicalKey = ShortcutsKey(
            characters: "z",
            modifiers: [.command, .shift]
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [physicalKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.dvorak
        )

        XCTAssertNil(command)
    }

    func testShortcutCaptureKeepsSemanticASCIICharacterForAlternateLayout() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.dvorak
            )
        )

        XCTAssertEqual(
            recordedKey,
            ShortcutsKey(characters: ";", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [recordedKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorak
            ),
            .PHI_COPY_URL
        )
    }

    func testCommandQWERTYLayoutUsesPhysicalLatinKeyWithCommand() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )
        let physicalKey = ShortcutsKey(
            characters: "z",
            modifiers: [.command, .shift]
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            )
        )

        XCTAssertEqual(recordedKey, physicalKey)
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [physicalKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testCommandQWERTYLayoutUsesPhysicalPunctuationWithCommand() throws {
        let unshiftedEvent = try makeShortcutKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "+",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )
        let shiftedEvent = try makeShortcutKeyEvent(
            characters: "}",
            charactersIgnoringModifiers: "+",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )
        let unshiftedKey = ShortcutsKey(
            characters: "]",
            modifiers: [.command]
        )
        let shiftedKey = ShortcutsKey(
            characters: "}",
            modifiers: [.command, .shift]
        )

        XCTAssertEqual(
            ShortcutsKey.recordingKey(
                for: unshiftedEvent,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            unshiftedKey
        )
        XCTAssertEqual(
            ShortcutsKey.recordingKey(
                for: shiftedEvent,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            shiftedKey
        )
        XCTAssertEqual(shiftedKey.menuKeyEquivalent.characters, "}")
        XCTAssertEqual(shiftedKey.menuKeyEquivalent.modifiers, [.command])
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: shiftedEvent,
                shortcutMap: [shiftedKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testShortcutCaptureUsesASCIIEquivalentWithoutCommandWhenProvided() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.control, .shift]
        )
        let shortcut = ShortcutsKey(characters: "c", modifiers: [.control, .shift])
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [shortcut: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(recordedKey, shortcut)
        XCTAssertEqual(recordedKey.displayString, "⌃⇧C")
        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testLegacyShiftOnlyASCIIShortcutMatchesWithoutAllowingNewRecording() throws {
        let event = try makeShortcutKeyEvent(characters: "C", charactersIgnoringModifiers: "\u{0421}", modifiers: .shift)
        let key = ShortcutsKey(characters: "c", modifiers: .shift)
        XCTAssertNil(ShortcutsKey.recordingKey(for: event, inputSourceIdentifier: InputSource.russian))
        XCTAssertEqual(ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: InputSource.russian)?.canonical, key)
        XCTAssertEqual(CommandDispatcher.matchedPhiCommand(for: event,
            shortcutMap: [key: .PHI_COPY_URL], inputSourceIdentifier: InputSource.russian), .PHI_COPY_URL)
    }

    func testNonASCIICaptureKeepsSemanticKeyWithoutASCIIEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "\u{041F}",
            charactersIgnoringModifiers: "\u{041F}",
            modifiers: [.control, .shift],
            keyCode: UInt16(kVK_ANSI_G)
        )
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let semanticKey = ShortcutsKey(
            characters: "\u{043F}",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(recordedKey, semanticKey)
        XCTAssertEqual(recordedKey.displayString, "⌃⇧П")
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [semanticKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.russian
            ),
            .PHI_COPY_URL
        )
    }

    func testPhiShortcutMatchingFallsBackWhenIgnoringModifiersIsEmpty() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [copyURLKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testHebrewCommandCaptureUsesInputSourceSpecificLatinEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "q",
            charactersIgnoringModifiers: "/",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_Q)
        )

        let hebrewKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.hebrewQWERTY
            )
        )
        let nonHebrewKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(hebrewKey, ShortcutsKey(characters: "q", modifiers: [.command]))
        XCTAssertEqual(nonHebrewKey, ShortcutsKey(characters: "/", modifiers: [.command]))
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [hebrewKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.hebrewQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testArabicCommandCaptureUsesInputSourceSpecificLatinEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "V",
            charactersIgnoringModifiers: "{",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_V)
        )

        let arabicKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.arabicAZERTY
            )
        )
        let nonArabicKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(
            arabicKey,
            ShortcutsKey(characters: "v", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            nonArabicKey,
            ShortcutsKey(characters: "{", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [arabicKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.arabicAZERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testCopyURLShortcutKeycapsMatchMacModifierOrder() {
        let shortcut = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

        XCTAssertEqual(shortcut.keycapTokens, ["⇧", "⌘", "C"])
    }

    func testShortcutKeycapsUseReadableSpecialKeySymbols() {
        let shortcut = ShortcutsKey(
            characters: "\u{F702}",
            modifiers: [.control, .option]
        )

        XCTAssertEqual(shortcut.keycapTokens, ["⌃", "⌥", "←"])
        XCTAssertEqual(shortcut.displayString, "⌃⌥←")
    }

    func testShortcutCaptureNormalizesShiftTabToTabCharacter() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(format: "%c", NSBackTabCharacter),
                charactersIgnoringModifiers: String(format: "%c", NSBackTabCharacter),
                isARepeat: false,
                keyCode: UInt16(kVK_Tab)
            )
        )

        let shortcut = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(shortcut.characters, "\t")
        XCTAssertEqual(shortcut.modifiers, [.control, .shift])
        XCTAssertEqual(shortcut.displayString, "⌃⇧⇥")
        XCTAssertEqual(shortcut.menuKeyEquivalent.characters, "\t")
        XCTAssertEqual(shortcut.menuKeyEquivalent.modifiers, [.control, .shift])
    }

    func testThemeSnapshotRoundTripPreservesRGBAndStandardizesAlpha() {
        let theme = Theme(id: "theme-snapshot-round-trip", name: "Snapshot")
        theme.setColor(
            light: NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.30, alpha: 0.45),
            dark: NSColor(calibratedRed: 0.70, green: 0.60, blue: 0.50, alpha: 0.85),
            for: .windowOverlayBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.35, alpha: 0.31),
            dark: NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.45, alpha: 0.79),
            for: .windowBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.60, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.60, green: 0.40, blue: 0.20, alpha: 1.0),
            for: .themeColor
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.70, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.30, alpha: 1.0),
            for: .extensionActonColor
        )

        let snapshot = theme.makeSnapshot()
        let restoredTheme = snapshot.makeTheme()

        XCTAssertEqual(snapshot.version, ThemeSnapshot.currentVersion)

        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: theme
                .color(for: .windowOverlayBackground, appearance: .light)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            equals: theme
                .color(for: .windowOverlayBackground, appearance: .dark)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .light),
            equals: theme
                .color(for: .windowBackground, appearance: .light)
                .withAlphaComponent(1)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            equals: theme
                .color(for: .windowBackground, appearance: .dark)
                .withAlphaComponent(1)
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .dark),
            equals: theme.color(for: .themeColor, appearance: .dark)
        )
        assertColor(
            restoredTheme.color(for: .extensionActonColor, appearance: .light),
            equals: theme.color(for: .extensionActonColor, appearance: .light)
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .light),
            0.8,
            accuracy: 0.001,
            "ThemeSnapshot V2 must ignore customized light overlay alpha."
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .dark),
            0.8,
            accuracy: 0.001,
            "ThemeSnapshot V2 must ignore customized dark overlay alpha."
        )
        XCTAssertEqual(snapshot.colors.windowOverlayBackground.light.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowOverlayBackground.dark.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowBackground.light.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowBackground.dark.alpha, 1, accuracy: 0.001)
    }

    func testThemeWindowRolesAlwaysExposeStandardAlpha() {
        let theme = Theme(id: "fixed-alpha-contract", name: "Fixed Alpha")
        theme.setColor(
            light: NSColor(hex: 0x112233, alpha: 0.12),
            dark: NSColor(hex: 0x445566, alpha: 0.93),
            for: .windowOverlayBackground
        )
        theme.setColor(
            light: NSColor(hex: 0x778899, alpha: 0.24),
            dark: NSColor(hex: 0xAABBCC, alpha: 0.68),
            for: .windowBackground
        )

        XCTAssertEqual(theme.windowOverlayOpacity(for: .light), 0.8, accuracy: 0.0001)
        XCTAssertEqual(theme.windowOverlayOpacity(for: .dark), 0.8, accuracy: 0.0001)
        XCTAssertEqual(
            theme.color(for: .windowBackground, appearance: .light).alphaComponent,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            theme.color(for: .windowBackground, appearance: .dark).alphaComponent,
            1,
            accuracy: 0.0001
        )
    }

    func testVersion1ColoredThemeSnapshotMigratesFromLatestCanonicalTheme() throws {
        let legacyTheme = Theme(id: Theme.mint.id, name: "Legacy Mint")
        legacyTheme.setColor(
            light: NSColor(calibratedRed: 0.91, green: 0.12, blue: 0.37, alpha: 0.23),
            dark: NSColor(calibratedRed: 0.17, green: 0.83, blue: 0.41, alpha: 0.67),
            for: .windowOverlayBackground
        )
        legacyTheme.setColor(
            light: .magenta,
            dark: .orange,
            for: .windowBackground
        )
        legacyTheme.setColor(light: .red, dark: .blue, for: .themeColor)
        legacyTheme.setColor(light: .yellow, dark: .purple, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: legacyTheme.id,
            name: legacyTheme.name,
            colors: rawEditableColors(from: legacyTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.mint)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: Theme.mint)

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        XCTAssertEqual(migratedSnapshot.id, Theme.mint.id)
        XCTAssertEqual(migratedSnapshot.name, Theme.mint.name)
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            saturation: 0.40,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            saturation: 0.40,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            saturation: 0.40,
            alpha: 1
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .light),
            equals: Theme.mint.color(for: .themeColor, appearance: .light)
        )
        assertColor(
            restoredTheme.color(for: .extensionActonColor, appearance: .dark),
            equals: Theme.mint.color(for: .extensionActonColor, appearance: .dark)
        )
    }

    func testVersion1PureThemeSnapshotMigratesToAppearanceSpecificMidpoints() throws {
        let legacyTheme = Theme(id: Theme.pure.id, name: "Legacy Pure")
        legacyTheme.setColor(light: .red, dark: .green, for: .windowOverlayBackground)
        legacyTheme.setColor(light: .blue, dark: .yellow, for: .windowBackground)
        legacyTheme.setColor(light: .orange, dark: .purple, for: .themeColor)
        legacyTheme.setColor(light: .cyan, dark: .magenta, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: legacyTheme.id,
            name: legacyTheme.name,
            colors: rawEditableColors(from: legacyTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.pure)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: Theme.pure)

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            brightness: 0.89,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            brightness: 0.20,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            brightness: 0.25,
            alpha: 1
        )
        XCTAssertEqual(
            Theme.pure
                .color(for: .windowOverlayBackground, appearance: .light)
                .hsbBrightnessComponent,
            1,
            accuracy: 0.0001,
            "Migration must not mutate the canonical built-in instance."
        )
    }

    func testVersion1DefaultSnapshotAliasMigratesToPure() throws {
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: "default",
            name: "Default",
            colors: rawEditableColors(from: Theme.pure)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.pure)
        )

        XCTAssertEqual(migratedSnapshot.id, Theme.pure.id)
        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
    }

    func testVersion1CustomThemeSnapshotKeepsRGBAndStandardizesAlpha() throws {
        let customTheme = Theme(id: "custom-theme", name: "Custom")
        customTheme.setColor(
            light: NSColor(calibratedRed: 0.11, green: 0.22, blue: 0.33, alpha: 0.44),
            dark: NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.77, alpha: 0.88),
            for: .windowOverlayBackground
        )
        customTheme.setColor(light: .red, dark: .green, for: .windowBackground)
        customTheme.setColor(light: .blue, dark: .yellow, for: .themeColor)
        customTheme.setColor(light: .orange, dark: .purple, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: customTheme.id,
            name: customTheme.name,
            colors: rawEditableColors(from: customTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: nil)
        )
        let restoredTheme = migratedSnapshot.makeTheme()

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        XCTAssertEqual(migratedSnapshot.id, customTheme.id)
        XCTAssertEqual(migratedSnapshot.name, customTheme.name)
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: customTheme
                .color(for: .windowOverlayBackground, appearance: .light)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            equals: customTheme
                .color(for: .windowOverlayBackground, appearance: .dark)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .light),
            equals: customTheme.color(for: .themeColor, appearance: .light)
        )
    }

    func testVersion2SnapshotRestoreKeepsCanonicalNonEditableRoles() throws {
        let canonicalTheme = Theme(id: "future-built-in", name: "Future")
        canonicalTheme.setColor(light: .brown, dark: .gray, for: .textPrimary)
        let editableTheme = Theme(id: canonicalTheme.id, name: canonicalTheme.name)
        editableTheme.setColor(light: .red, dark: .green, for: .windowOverlayBackground)
        let snapshot = editableTheme.makeSnapshot()

        let migratedSnapshot = try XCTUnwrap(
            snapshot.migratedToCurrentVersion(matching: canonicalTheme)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: canonicalTheme)

        XCTAssertEqual(migratedSnapshot, snapshot)
        assertColor(
            restoredTheme.color(for: .textPrimary, appearance: .light),
            equals: .brown
        )
        assertColor(
            restoredTheme.color(for: .textPrimary, appearance: .dark),
            equals: .gray
        )
    }

    func testVersion2SnapshotIgnoresPersistedAlpha() throws {
        let savedTheme = Theme(id: "v2-saved-alpha", name: "Saved Alpha")
        savedTheme.setColor(
            light: NSColor(hex: 0x2468AC),
            dark: NSColor(hex: 0x13579B),
            for: .windowOverlayBackground
        )
        savedTheme.setColor(
            light: NSColor(hex: 0xF0E0D0),
            dark: NSColor(hex: 0x302010),
            for: .windowBackground
        )
        let savedSnapshot = ThemeSnapshot(
            version: ThemeSnapshot.currentVersion,
            id: savedTheme.id,
            name: savedTheme.name,
            colors: rawEditableColors(from: savedTheme)
        )

        let normalizedSnapshot = try XCTUnwrap(
            savedSnapshot.migratedToCurrentVersion(matching: nil)
        )
        let restoredTheme = normalizedSnapshot.makeTheme()

        XCTAssertEqual(normalizedSnapshot.colors.windowOverlayBackground.light.alpha, 0.8)
        XCTAssertEqual(normalizedSnapshot.colors.windowOverlayBackground.dark.alpha, 0.8)
        XCTAssertEqual(normalizedSnapshot.colors.windowBackground.light.alpha, 1)
        XCTAssertEqual(normalizedSnapshot.colors.windowBackground.dark.alpha, 1)
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: NSColor(hex: 0x2468AC, alpha: 0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            equals: NSColor(hex: 0x302010, alpha: 1)
        )
    }

    func testUnsupportedThemeSnapshotVersionIsNotApplied() {
        let futureSnapshot = ThemeSnapshot(
            version: ThemeSnapshot.currentVersion + 1,
            id: Theme.mint.id,
            name: Theme.mint.name,
            colors: Theme.mint.makeSnapshot().colors
        )

        XCTAssertNil(
            futureSnapshot.migratedToCurrentVersion(matching: Theme.mint)
        )
    }

    func testThemeColorAdjustmentForcesStandardAlpha() {
        let base = Theme(id: "alpha-normalization", name: "Alpha")
        base.setColor(
            light: NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.8, alpha: 0.37),
            dark: NSColor(calibratedRed: 0.8, green: 0.5, blue: 0.2, alpha: 0.63),
            for: .windowOverlayBackground
        )
        base.setColor(
            light: NSColor(calibratedWhite: 0.9, alpha: 0.71),
            dark: NSColor(calibratedWhite: 0.1, alpha: 0.79),
            for: .windowBackground
        )

        let adjusted = ThemeColorAdjustment.applyingSaturation(
            light: 0.4,
            dark: 0.4,
            darkWindowBackground: 0.4,
            to: base
        )

        XCTAssertEqual(
            adjusted.color(for: .windowOverlayBackground, appearance: .light).alphaComponent,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowOverlayBackground, appearance: .dark).alphaComponent,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowBackground, appearance: .dark).alphaComponent,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowBackground, appearance: .light).alphaComponent,
            1,
            accuracy: 0.0001
        )
    }

    func testNormalizedThemeSliderTrackColorKeepsRgbAndForcesFullOpacity() {
        let sourceColor = NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 0.37)

        let normalizedColor = normalizedThemeSliderTrackColor(from: sourceColor)

        assertColor(
            normalizedColor,
            equals: NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 1.0)
        )
    }

    func testPureThemeBrightnessScaleGetsDarkerFromLeftToRight() {
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: -1, appearance: .light), 0.94, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 0, appearance: .light), 0.94, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 50, appearance: .light), 0.89, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 100, appearance: .light), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 101, appearance: .light), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.sliderValue(forBrightness: 0.89, appearance: .light), 50, accuracy: 0.0001)

        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 0, appearance: .dark), 0.40, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 50, appearance: .dark), 0.20, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 100, appearance: .dark), 0, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.sliderValue(forBrightness: 0.20, appearance: .dark), 50, accuracy: 0.0001)

        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 0), 0.30, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 50), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 100), 0.20, accuracy: 0.0001)
    }

    func testPureTabSubSelectionUsesContrastOverlayAcrossBrightnessRange() {
        for sliderValue in [0.0, 50.0, 100.0] {
            let theme = ThemeColorAdjustment.applyingPureBrightness(
                sliderValue: sliderValue,
                to: .pure
            )

            assertColor(
                ThemedColor.tabSubSelectionBackground.resolve(
                    theme: theme,
                    appearance: .light
                ),
                equals: NSColor.black.withAlphaComponent(0.08)
            )
        }
    }

    func testColoredThemeTabSubSelectionKeepsExistingColors() {
        assertColor(
            ThemedColor.tabSubSelectionBackground.resolve(
                theme: .mint,
                appearance: .light
            ),
            equals: NSColor(white: 0.9, alpha: 1)
        )
        assertColor(
            ThemedColor.tabSubSelectionBackground.resolve(
                theme: .mint,
                appearance: .dark
            ),
            equals: NSColor.white.withAlphaComponent(0.18)
        )
    }

    func testDefaultColoredThemeSaturationIsFortyPercent() {
        XCTAssertEqual(ThemeColorAdjustment.defaultSaturation, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            OverlaySaturationScale.sliderValue(
                forSaturation: Double(ThemeColorAdjustment.defaultSaturation)
            ),
            37.5,
            accuracy: 0.0001
        )
    }

    func testHSBBrightnessReplacementPreservesSaturationAndSetsAlpha() {
        let sourceColor = NSColor(
            colorSpace: .extendedSRGB,
            hue: 0,
            saturation: 0,
            brightness: 1,
            alpha: 0.4
        )

        let adjustedColor = sourceColor.withHSBBrightness(0.76, alpha: 0.8)

        XCTAssertEqual(adjustedColor.hsbSaturationComponent, 0, accuracy: 0.0001)
        XCTAssertEqual(adjustedColor.hsbBrightnessComponent, 0.76, accuracy: 0.0001)
        XCTAssertEqual(adjustedColor.alphaComponent, 0.8, accuracy: 0.0001)
    }

    @MainActor
    func testBrowserThemeContextPublishesThemeChangesForSameThemeIdentifier() {
        let initialTheme = Theme(id: "browser-context-same-id", name: "Context")
        initialTheme.setColor(
            light: NSColor(hex: 0x445566, alpha: 0.40),
            dark: NSColor(hex: 0x112233, alpha: 0.80),
            for: .windowOverlayBackground
        )

        let context = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: initialTheme,
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )

        var observedLightOverlayColors: [NSColor] = []
        let subscription = context.subscribe { theme, appearance in
            observedLightOverlayColors.append(
                theme.color(for: .windowOverlayBackground, appearance: appearance)
            )
        }

        let updatedTheme = initialTheme.duplicating()
        updatedTheme.setColor(
            light: NSColor(hex: 0xAA8844, alpha: 0.72),
            dark: NSColor(hex: 0x335577, alpha: 0.36),
            for: .windowOverlayBackground
        )
        context.setTheme(updatedTheme)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        _ = subscription

        XCTAssertEqual(observedLightOverlayColors.count, 2)
        guard observedLightOverlayColors.count == 2 else { return }
        assertColor(
            observedLightOverlayColors[0],
            equals: NSColor(hex: 0x445566, alpha: 0.8)
        )
        assertColor(
            observedLightOverlayColors[1],
            equals: NSColor(hex: 0xAA8844, alpha: 0.8)
        )
    }

    func testBookmarkMainMenuItemRoutingKeepsChromiumBookmarksItemUntouched() {
        let action = BookmarkMainMenuItemRouting.action(
            tag: ChromiumMainMenuRole.bookmarks.rawValue
        )

        XCTAssertEqual(
            action,
            .hideSystemItem,
            "The Chromium-owned Bookmarks menu item must stay discoverable by IDC_BOOKMARKS_MENU so AppController should only hide it instead of repurposing it as the native custom Bookmarks menu."
        )
    }

    func testBookmarkMainMenuItemRoutingRecognizesCustomBookmarksItem() {
        let action = BookmarkMainMenuItemRouting.action(
            tag: AppController.bookmarksMenuItemTag
        )

        XCTAssertEqual(
            action,
            .configureCustomItem,
            "The native Phi Bookmarks item should be the only menu item that gets reconfigured and rebuilt."
        )
    }

    func testChromiumMainMenuRoleUsesTagsInsteadOfLocalizedTitles() {
        let mainMenu = NSMenu(title: "")
        let appItem = NSMenuItem(title: "Localized App Menu", action: nil, keyEquivalent: "")
        appItem.tag = ChromiumMainMenuRole.app.rawValue
        let viewItem = NSMenuItem(title: "Localized View Menu", action: nil, keyEquivalent: "")
        viewItem.tag = ChromiumMainMenuRole.view.rawValue
        let historyItem = NSMenuItem(title: "Localized History Menu", action: nil, keyEquivalent: "")
        historyItem.tag = ChromiumMainMenuRole.history.rawValue
        mainMenu.addItem(appItem)
        mainMenu.addItem(viewItem)
        mainMenu.addItem(historyItem)

        XCTAssertEqual(
            ChromiumMainMenuRole.resolve(viewItem, helpMenu: nil),
            .view
        )
        XCTAssertTrue(ChromiumMainMenuRole.app.item(in: mainMenu) === appItem)
        XCTAssertEqual(ChromiumMainMenuRole.history.index(in: mainMenu), 2)
    }

    func testChromiumMainMenuRoleAcceptsLegacyAndCurrentChromiumTags() {
        // Chromium 150 tags the View menu IDC_VIEW_MENU; 152 tags it kMacViewMenuId.
        XCTAssertEqual(ChromiumMainMenuRole(tag: 44000), .view)
        XCTAssertEqual(ChromiumMainMenuRole(tag: 57327), .view)
        XCTAssertEqual(ChromiumMainMenuRole(tag: 40029), .bookmarks)
        XCTAssertEqual(ChromiumMainMenuRole(tag: 57333), .bookmarks)
        XCTAssertNil(ChromiumMainMenuRole(tag: 0))

        let mainMenu = NSMenu(title: "")
        let legacyHistoryItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        legacyHistoryItem.tag = 46000  // IDC_HISTORY_MENU
        mainMenu.addItem(legacyHistoryItem)

        XCTAssertEqual(ChromiumMainMenuRole.resolve(legacyHistoryItem, helpMenu: nil), .history)
        XCTAssertTrue(ChromiumMainMenuRole.history.item(in: mainMenu) === legacyHistoryItem)
        XCTAssertEqual(ChromiumMainMenuRole.history.index(in: mainMenu), 0)
        XCTAssertEqual(BookmarkMainMenuItemRouting.action(tag: 40029), .hideSystemItem)
    }

    func testChromiumMainMenuRoleRecognizesAppKitHelpMenuByIdentity() {
        let helpMenu = NSMenu(title: "Localized Help Menu")
        let helpItem = NSMenuItem(title: "Localized Help Menu", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu

        XCTAssertEqual(
            ChromiumMainMenuRole.resolve(helpItem, helpMenu: helpMenu),
            .help
        )
    }

    /// Mirrors the two New Tab items of Chromium's Tab menu template.
    private func makeTabMenuWithNewTabItems() -> (NSMenu, right: NSMenuItem, below: NSMenuItem) {
        let menu = NSMenu(title: "Tab")
        let right = NSMenuItem(title: "New Tab to the Right", action: nil, keyEquivalent: "")
        right.tag = CommandWrapper.IDC_NEW_TAB_TO_RIGHT.rawValue
        let below = NSMenuItem(title: "New Tab Below", action: nil, keyEquivalent: "")
        below.tag = CommandWrapper.IDC_NEW_TAB_TO_RIGHT.rawValue
        below.isHidden = true
        menu.addItem(right)
        menu.addItem(below)
        return (menu, right, below)
    }

    func testTabMenuShowsNewTabToTheRightInComfortableLayout() {
        let (menu, right, below) = makeTabMenuWithNewTabItems()
        AppController.applyNewTabOrientation(in: menu, layoutMode: .performance)

        AppController.applyNewTabOrientation(in: menu, layoutMode: .comfortable)

        XCTAssertEqual([right.isHidden, below.isHidden], [false, true])
    }

    func testTabMenuShowsNewTabBelowInVerticalLayouts() {
        for layoutMode in [LayoutMode.balanced, .performance] {
            let (menu, right, below) = makeTabMenuWithNewTabItems()

            AppController.applyNewTabOrientation(in: menu, layoutMode: layoutMode)

            XCTAssertEqual([right.isHidden, below.isHidden], [true, false], "\(layoutMode)")
        }
    }

    func testTabMenuNewTabItemsLeftAloneWhenTemplateChanges() {
        let menu = NSMenu(title: "Tab")
        let only = NSMenuItem(title: "New Tab to the Right", action: nil, keyEquivalent: "")
        only.tag = CommandWrapper.IDC_NEW_TAB_TO_RIGHT.rawValue
        menu.addItem(only)

        AppController.applyNewTabOrientation(in: menu, layoutMode: .performance)

        XCTAssertFalse(only.isHidden)
    }

    func testBookmarkMenuContentBuilderAddsBookmarkThisTabAndRecursiveBookmarks() {
        let previousConfiguration = Shortcuts.configuration
        defer { Shortcuts.configuration = previousConfiguration }
        shortcutOverrides[.IDC_SHOW_BOOKMARK_MANAGER] = .disabled

        let rootBookmark = Bookmark(title: "Phi", url: "https://phibrowser.com")
        let folder = Bookmark(folderTitle: "Favorites")
        let childBookmark = Bookmark(title: "Docs", url: "https://docs.phibrowser.com")
        folder.addChild(childBookmark)
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [rootBookmark, folder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(
            menu.items.first?.title,
            NSLocalizedString("app.bookmarksMenu.addOrEditCurrentTab", value: "Bookmark This Tab...", comment: "Bookmarks menu - Menu item to add or edit a bookmark for the currently focused tab")
        )
        XCTAssertEqual(menu.items.first?.tag, CommandWrapper.IDC_BOOKMARK_THIS_TAB.rawValue)
        XCTAssertEqual(
            menu.items.dropFirst().first?.title,
            NSLocalizedString("app.bookmarksMenu.addAllOpenTabs", value: "Bookmark All Tabs...", comment: "Bookmarks menu - Menu item to add bookmarks for all currently open tabs in the active window")
        )
        XCTAssertEqual(menu.items.dropFirst().first?.tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertTrue(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should enable the Bookmark This Tab item when the active window has a focusable tab URL."
        )
        XCTAssertTrue(menu.items.dropFirst(2).first?.isSeparatorItem == true)
        XCTAssertEqual(
            menu.items.dropFirst(3).first?.title,
            NSLocalizedString("app.bookmarksMenu.openManager", value: "Manage Bookmarks", comment: "Bookmarks menu - Menu item that opens the bookmark management page")
        )
        let managerItem = menu.items.dropFirst(3).first
        XCTAssertEqual(managerItem?.tag, CommandWrapper.IDC_SHOW_BOOKMARK_MANAGER.rawValue)
        XCTAssertEqual(managerItem?.action, #selector(BookmarkMenuTestTarget.menuAction(_:)))
        XCTAssertEqual(managerItem?.keyEquivalent, "")
        XCTAssertEqual(managerItem?.keyEquivalentModifierMask, [])
        XCTAssertEqual(
            menu.items.dropFirst(4).first?.title,
            NSLocalizedString("app.bookmarksMenu.exportCurrentSpace", value: "Export Bookmarks...", comment: "Bookmarks menu - Menu item to export the current Space's bookmarks to an HTML file")
        )
        XCTAssertTrue(menu.items.dropFirst(5).first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.dropFirst(6).map(\.title), ["Phi", "Favorites"])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title), ["Docs"])
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkThisTabWithoutFocusedTab() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: false,
            canBookmarkAllTabs: false,
            canExportBookmarks: false,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertFalse(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark This Tab item when there is no focused tab with a bookmarkable URL."
        )
        XCTAssertFalse(
            menu.items.dropFirst().first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark All Tabs item when the active window does not have more than one bookmarkable open tab."
        )
        XCTAssertFalse(
            menu.items.dropFirst(4).first?.isEnabled == true,
            "The Bookmarks menu should disable the Export Bookmarks item when the current Space has no bookmarks to export."
        )
        XCTAssertEqual(menu.items.count, 5)
    }

    func testBookmarkMenuContentBuilderShowsDisabledEmptyItemForEmptyFolders() {
        let emptyFolder = Bookmark(folderTitle: "Empty Folder")
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [emptyFolder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        let folderItem = menu.items[6]
        let emptyItem = try? XCTUnwrap(folderItem.submenu?.items.first)

        XCTAssertEqual(folderItem.title, "Empty Folder")
        XCTAssertEqual(
            emptyItem?.title,
            NSLocalizedString("app.bookmarksMenu.emptyFolderPlaceholder", value: "Empty", comment: "Bookmarks menu - Disabled placeholder item shown when a bookmark folder has no child bookmarks")
        )
        XCTAssertFalse(
            emptyItem?.isEnabled == true,
            "Empty bookmark folders should show a disabled placeholder item so the submenu still renders a stable empty state."
        )
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkAllTabsWithoutEnoughTabs() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: false,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(menu.items[1].tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertFalse(
            menu.items[1].isEnabled,
            "Bookmark All Tabs should be disabled unless the active window has more than one bookmarkable open tab."
        )
    }














    @MainActor
    func testExtensionPopupAnchorUsesPrimaryScreenHeightForChromiumFlip() {
        let point = NSPoint(x: 240, y: 320)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumPoint.x, 240)
        XCTAssertEqual(
            chromiumPoint.y,
            580,
            "Extension popup anchors must flip against the primary display height so Swift matches Chromium's global screen coordinates."
        )
    }

    @MainActor
    func testExtensionPopupAnchorPreservesLegitimateNegativeChromiumY() {
        let point = NSPoint(x: 120, y: 960)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            chromiumPoint.y,
            -60,
            "Points above the primary display should remain negative after the AppKit-to-Chromium flip."
        )
    }

    @MainActor
    func testExtensionPopupAnchorRectFlipUsesPrimaryScreenHeight() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumRect = ExtensionPopupAnchor.chromiumScreenRect(
            from: appKitRect,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumRect.origin.x, 240)
        XCTAssertEqual(
            chromiumRect.origin.y,
            556,
            "Anchor rects must flip as y = primary height - maxY so the rect's top edge lands in Chromium's top-left-origin screen space."
        )
        XCTAssertEqual(chromiumRect.size, appKitRect.size)
    }

    @MainActor
    func testExtensionPopupAnchorLegacyPointMatchesPointBasedConversion() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let pointFromRect = ExtensionPopupAnchor.legacyAnchorPoint(
            for: ExtensionPopupAnchor.chromiumScreenRect(
                from: appKitRect,
                primaryScreenFrame: primaryFrame
            )
        )
        let pointFromBottomLeft = ExtensionPopupAnchor.chromiumScreenPoint(
            from: NSPoint(x: appKitRect.minX, y: appKitRect.minY),
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            pointFromRect,
            pointFromBottomLeft,
            "The old-framework fallback must reproduce the icon's visual bottom-left corner exactly as the point-based path did."
        )
    }





















    func testOmniBoxSearchCoordinatorSuppressesOnlyTheNextAutomaticSearchAfterPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "https://phibrowser.com", minInputLength: 1)

        XCTAssertFalse(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com", minInputLength: 1),
            "Prefilling the current tab URL should not immediately trigger a duplicate automatic search."
        )
        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com/path", minInputLength: 1),
            "Only the next automatic search should be suppressed so later edits still update suggestions."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsResponsesMatchingTheLatestQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)
        _ = coordinator.beginRequest(query: "phibrowser", source: .openPrefill)

        XCTAssertFalse(
            coordinator.shouldAcceptResponse(forQuery: "phi"),
            "Stale suggestion responses should be ignored once a newer query has been issued."
        )
        XCTAssertTrue(
            coordinator.shouldAcceptResponse(forQuery: "phibrowser"),
            "Responses matching the latest query should be applied to the UI."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsStreamedResponsesForTheSameQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)

        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
        // Chromium streams multiple updates per request as providers respond, every
        // subsequent emission for the same query must still be applied.
        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
    }

    func testOmniBoxSearchCoordinatorDoesNotArmSuppressionForEmptyPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "", minInputLength: 1)

        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "g", minInputLength: 1),
            "An empty prefill should not consume the user's first real search edit."
        )
    }

    func testOmniBoxTraceSessionFormatsReadableElapsedLogMessages() {
        var ticks: [UInt64] = [1_000_000_000, 1_125_000_000]
        let session = OmniBoxTraceSession(
            trigger: "address-bar",
            timeProvider: { ticks.removeFirst() }
        )

        let message = session.message(for: "request-start", details: "queryLength=12")

        XCTAssertTrue(message.contains("[OmniboxTrace]"))
        XCTAssertTrue(message.contains("trigger=address-bar"))
        XCTAssertTrue(message.contains("stage=request-start"))
        XCTAssertTrue(message.contains("elapsed=125.0ms"))
        XCTAssertTrue(message.contains("queryLength=12"))
    }

    func testHoverableButtonNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let button = HoverableButtonNSView(
            config: HoverableButtonConfig(title: "Test", displayMode: .titleOnly),
            action: {}
        )
        var didInvokeSecondaryAction = false
        button.secondaryAction = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        button.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Pinned extension buttons should route right clicks through their secondary action."
        )
    }

    func testHoverableViewInvokesSecondaryClickActionOnRightMouseDown() throws {
        let view = HoverableView()
        var didInvokeSecondaryClick = false
        view.secondaryClickAction = {
            didInvokeSecondaryClick = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryClick,
            "Sidebar pinned extension items should route right clicks through their secondary click action."
        )
    }

    func testSecondaryClickPassthroughNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickPassthroughNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover extension items should route right clicks through the shared secondary click passthrough."
        )
    }

    /// Builds a pre-V2 payload without applying the current fixed-alpha rule.
    private func rawEditableColors(from theme: Theme) -> ThemeEditableColors {
        let overlay = theme.colorPair(for: .windowOverlayBackground)
        let windowBackground = theme.colorPair(for: .windowBackground)
        return ThemeEditableColors(
            windowOverlayBackground: StoredColorPair(
                light: StoredRGBAColor(overlay.light.withAlphaComponent(0.23)),
                dark: StoredRGBAColor(overlay.dark.withAlphaComponent(0.67))
            ),
            windowBackground: StoredColorPair(
                light: StoredRGBAColor(windowBackground.light.withAlphaComponent(0.31)),
                dark: StoredRGBAColor(windowBackground.dark.withAlphaComponent(0.79))
            ),
            themeColor: StoredColorPair(theme.colorPair(for: .themeColor)),
            extensionActonColor: StoredColorPair(
                theme.colorPair(for: .extensionActonColor)
            )
        )
    }

    private func assertHSB(
        _ color: NSColor,
        saturation: CGFloat? = nil,
        brightness: CGFloat? = nil,
        alpha: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
        var actualSaturation: CGFloat = 0
        var actualBrightness: CGFloat = 0
        var actualAlpha: CGFloat = 0
        resolvedColor.getHue(
            nil,
            saturation: &actualSaturation,
            brightness: &actualBrightness,
            alpha: &actualAlpha
        )

        if let saturation {
            XCTAssertEqual(actualSaturation, saturation, accuracy: 0.001, file: file, line: line)
        }
        if let brightness {
            XCTAssertEqual(actualBrightness, brightness, accuracy: 0.001, file: file, line: line)
        }
        if let alpha {
            XCTAssertEqual(actualAlpha, alpha, accuracy: 0.001, file: file, line: line)
        }
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualColor = actual.usingColorSpace(.extendedSRGB) ?? actual
        let expectedColor = expected.usingColorSpace(.extendedSRGB) ?? expected

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}
