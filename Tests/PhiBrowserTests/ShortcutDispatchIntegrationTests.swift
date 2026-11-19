// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ShortcutDispatchIntegrationTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration!
    private var directory: URL!
    private var accountDirectory: URL!
    private var store: LocalStore!
    private var previousDefaults: [String: Any] = [:]
    private let defaultKeys = ["spacesFeatureEnabled"]
    private let inspectKey = ShortcutsKey(characters: "c", modifiers: [.command, .option])
    private let copyKey = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

    override func setUp() async throws {
        previousConfiguration = Shortcuts.configuration
        for key in defaultKeys { previousDefaults[key] = UserDefaults.standard.object(forKey: key) }
        configure([:])
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shortcut-dispatch-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
    }

    override func tearDown() async throws {
        Shortcuts.configuration = previousConfiguration
        CommandDispatcher.reloadPhiShortcutMap()
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        for key in defaultKeys { UserDefaults.standard.set(previousDefaults[key], forKey: key) }
        let drained = expectation(description: "Dispatch fixture UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func testAlternateNewTabResolvesOptionCommandTAndReleasesDisabledOrReboundKey() throws {
        let key = ShortcutsKey(characters: "t", modifiers: [.command, .option])
        let window = makeWindow()
        defer { window.close() }
        let original = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: key.modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "†", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: original,
            inputSourceIdentifier: "com.apple.keylayout.US"), .PHI_ALTERNATE_NEW_TAB)
        XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(original, window: window))
        configure([.PHI_ALTERNATE_NEW_TAB: .disabled])
        XCTAssertNil(CommandDispatcher.interceptedPhiCommand(for: original))
        configure([.PHI_ALTERNATE_NEW_TAB: .custom(inspectKey)])
        XCTAssertNil(CommandDispatcher.interceptedPhiCommand(for: original))
        XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: try event(inspectKey, in: window)),
                       .PHI_ALTERNATE_NEW_TAB)
    }

    func testPickerKeysAreUnhandledWithoutComposerFocus() throws {
        try withController { _, window in
            for command in [CommandWrapper.PHI_DRIFTER_MODEL_MENU, .PHI_DRIFTER_EFFORT_MENU] {
                let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(key, in: window), window: window))
            }
        }
    }

    func testAlternateNewTabRepeatIsConsumedWithoutOpeningOmnibox() throws {
        let preference = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT
        let previousValue = UserDefaults.standard.object(forKey: preference.rawValue)
        defer { UserDefaults.standard.set(previousValue, forKey: preference.rawValue) }
        UserDefaults.standard.set(true, forKey: preference.rawValue)
        try withController { controller, window in
            XCTAssertNil(controller.omniBoxContainerViewController)
            let repeated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "†", charactersIgnoringModifiers: "t", isARepeat: true, keyCode: 17))
            XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(repeated, window: window))
            XCTAssertNil(controller.omniBoxContainerViewController)
        }
    }

    func testUnavailableNativeActionsConsumeTheirKeyBeforeHiddenInspect() throws {
        XCTAssertFalse(Shortcuts.additionalBindings().contains { $0.commandID == CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue })
        try withController { controller, window in
            XCTAssertNil(controller.browserState.focusingTab)
            for command in [CommandWrapper.PHI_COPY_URL,
                            .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA] {
                assignInspectKey(to: command)
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: try event(inspectKey, in: window)), command)
                let item = NSMenuItem(title: "Unavailable action", action: nil, keyEquivalent: "")
                item.tag = command.rawValue
                XCTAssertFalse(CommandDispatcher.dispatchCommand(item, window: window), "No action result for \(command)")
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window),
                              "The matched \(command) must stop fallback even without an action result")
            }
        }
    }

    func testBookmarkBarCommandUsesPhiVisibility() throws {
        let defaults = UserDefaults.standard
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let visibilityKey = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue
        let layout = defaults.object(forKey: layoutKey)
        let visibility = defaults.object(forKey: visibilityKey)
        defer {
            defaults.set(layout, forKey: layoutKey)
            defaults.set(visibility, forKey: visibilityKey)
        }
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        defaults.set(false, forKey: visibilityKey)
        let command = Int32(CommandWrapper.IDC_SHOW_BOOKMARK_BAR.rawValue)
        try withController { _, window in
            XCTAssertTrue(CommandDispatcher.dispatchCommand(command, window: window))
            XCTAssertTrue(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
            XCTAssertTrue(CommandDispatcher.dispatchCommand(command, window: window))
            XCTAssertFalse(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
        }
    }

    func testDisabledAndReboundCommandsDoNotConsumeTheirOldKey() throws {
        try withController { _, window in
            configure([.PHI_COPY_URL: .disabled])
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
            let replacement = ShortcutsKey(characters: "k", modifiers: .control)
            configure([.PHI_COPY_URL: .custom(replacement)])
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
            XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(replacement, in: window), window: window))
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(
                try event(.init(characters: "k", modifiers: [.control, .option]), in: window), window: window))
        }
    }

    func testScreenshotDefaultsMatchShiftedDigitsAndReleaseOldKeys() throws {
        try withController { _, window in
            for (command, character, digit, code) in [
                (CommandWrapper.PHI_CAPTURE_FULL_PAGE, "!", "1", UInt16(18)),
                (.PHI_CAPTURE_AREA, "@", "2", UInt16(19))
            ] {
                let original = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .shift], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                let unshifted = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: digit,
                    charactersIgnoringModifiers: digit, isARepeat: false, keyCode: code))
                configure([:])
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: original), command)
                XCTAssertNil(CommandDispatcher.interceptedPhiCommand(for: unshifted))
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(original, window: window))
                configure([command: .disabled])
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(original, window: window))
                configure([command: .custom(inspectKey)])
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(original, window: window))
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            }
        }
    }

    func testPageCommandsDoNotClaimSettingsOrOtherNonBrowserWindows() throws {
        let window = makeWindow()
        defer { window.close() }
        XCTAssertNil(SpaceSessionControllersManager.shared.findControllerWith(window: window))
        for command in [CommandWrapper.PHI_COPY_URL,
                        .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA, .PHI_ALTERNATE_NEW_TAB] {
            assignInspectKey(to: command)
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
        }
    }

    func testCopyURLStillExecutesInOrdinaryWindows() throws {
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        var ownedChangeCount: Int?
        defer {
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }
        try withController { controller, window in
            let url = "https://example.test/shortcut-copy"
            let tab = Tab(guid: 1001, url: url, isActive: true, index: 0)
            controller.browserState.tabs = [tab]
            controller.browserState.focusingTab = tab
            XCTAssertTrue(controller.browserState.hasCopyableSelectedTabURLs)
            configure([:])
            XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
            ownedChangeCount = pasteboard.changeCount
            XCTAssertEqual(pasteboard.string(forType: .string), url)
        }
    }

    private func assignInspectKey(to command: CommandWrapper) {
        var overrides: [CommandWrapper: ShortcutOverride] = [.PHI_COPY_URL: .disabled]
        overrides[command] = .custom(inspectKey)
        configure(overrides)
    }

    private func configure(_ overrides: [CommandWrapper: ShortcutOverride]) {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }))
        CommandDispatcher.reloadPhiShortcutMap()
    }

    private func withController(_ body: (SpaceSessionController, NSWindow) throws -> Void) throws {
        let window = makeWindow()
        let controller: SpaceSessionController
        let state = BrowserState(windowId: 987654322, localStore: store,
                                 profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
        controller = SpaceSessionController(window: window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            browserState: state, dormant: true)
        defer {
            OverlayToastCenter.shared.clearWindow(windowId: controller.windowId)
            controller.discardDormant()
            window.close()
            withExtendedLifetime(controller) {}
        }
        XCTAssertTrue(SpaceSessionControllersManager.shared.findControllerWith(window: window) === controller)
        try body(controller, window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ key: ShortcutsKey, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: 8))
    }
}
