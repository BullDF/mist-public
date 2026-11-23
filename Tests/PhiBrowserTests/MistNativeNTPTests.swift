import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistNativeNTPTests: XCTestCase {
    func testAppsWidgetOrderLayoutAndVisibility() throws {
        XCTAssertEqual(MistApps.all.map(\.id), [.clipboard, .drifter, .mail])
        XCTAssertEqual(MistApps.all.map { $0.id.name }, ["Clipboard", "Drifter", "Mail"])
        let page = NewTabViewController(state: try makeState(isIncognito: false))
        page.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        page.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(page.appsWidget.isHidden)
        // The tiles sit 32 under the composer; the widget's frame includes their 8 pt hover margin.
        XCTAssertEqual(page.composer.view.frame.minY - page.appsWidget.frame.maxY, 24, accuracy: 0.1)
        XCTAssertEqual(page.composer.view.frame.width, MistKit.readableWidth, accuracy: 0.1)
        // The page header is the logo alone, 36 above the composer.
        XCTAssertEqual(page.header.frame.size, NSSize(width: 72, height: 72))
        XCTAssertEqual(page.header.frame.minY - page.composer.view.frame.maxY, 36, accuracy: 0.1)
        XCTAssertEqual(page.composer.view.frame.midX, page.appsWidget.frame.midX, accuracy: 0.1)
        // The omnibox sizes itself from its suggestion rows, so drive real rows.
        page.composer.viewModel.state.suggestions = [OmniBoxSuggestion(
            type: .searchSuggest, title: "mist", url: "https://example.com/?q=mist", index: 0,
            stringToFill: "mist", swapContentsAndDescription: false
        )]
        drainUpdates()
        drainUpdates()
        XCTAssertTrue(page.appsWidget.isHidden)
        page.composer.viewModel.state.clearSuggestions()
        drainUpdates()
        drainUpdates()
        XCTAssertFalse(page.appsWidget.isHidden)
    }

    func testComposerFieldTakesTheKitSelectionAndCaret() async throws {
        let composer = MistNewTabComposerViewController(state: try makeState())
        let plain = NSTextField(string: "plain")
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        window.contentView?.addSubview(composer.view)
        window.contentView?.addSubview(plain)
        composer.view.frame = NSRect(x: 0, y: 150, width: 640, height: 116)
        plain.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let input = try XCTUnwrap(descendants(of: composer.view, type: OmniBoxTextField.self).first)
        XCTAssertTrue(window.makeFirstResponder(input.textFiled))
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        let themed = ThemedColor.mistTextSelection.resolve(theme: composer.view.themeStateProvider.currentTheme,
                                                           appearance: composer.view.currentAppearance)
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, themed)
        XCTAssertEqual(editor.insertionPointColor, .labelColor)

        XCTAssertTrue(window.makeFirstResponder(plain))
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, .selectedTextBackgroundColor)
    }

    func testAppsWidgetHiddenInIncognito() throws {
        let page = NewTabViewController(state: try makeState())
        page.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        page.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(page.appsWidget.isHidden)
        // Titled "Incognito" under the logo, the header keeps its bottom 36 above the composer.
        XCTAssertGreaterThan(page.header.frame.height, 72 + 14)
        XCTAssertEqual(page.header.frame.minY - page.composer.view.frame.maxY, 36, accuracy: 0.1)
    }

    func testAppWidgetOpenerPreservesDraft() throws {
        let page = NewTabViewController(state: try makeState(isIncognito: false))
        let tab = Tab(url: "chrome://newtab/", isActive: true, index: 0)
        _ = page.view
        page.updateForTab(tab)
        var opened: [(MistAppID, Tab?)] = []
        page.appOpener = { opened.append(($0, $1)) }
        page.openApp(.mail)
        XCTAssertEqual(opened.last?.0, .mail)
        XCTAssertTrue(opened.last?.1 === tab)
        let input = try XCTUnwrap(descendants(of: page.composer.view, type: OmniBoxTextField.self).first)
        input.updateDisplayText("   ")
        page.composer.omnibox.omniBoxTextFieldDidChange(input, suppressAutoComplete: false)
        page.openApp(.drifter)
        XCTAssertTrue(opened.last?.1 === tab)
        input.updateDisplayText("draft")
        page.composer.omnibox.omniBoxTextFieldDidChange(input, suppressAutoComplete: false)
        page.openApp(.clipboard)
        XCTAssertEqual(opened.last?.0, .clipboard)
        XCTAssertNil(opened.last?.1)
    }
    func testAppSuggestionReplacesOnlyBlankNewTab() throws {
        let state = try makeState()
        var opened: [(MistAppID, Tab?)] = []
        let model = OmniBoxViewModel(windowState: state, openApp: { opened.append(($0, $1)) })
        var suggestion = OmniBoxSuggestion(type: .app, title: "Mail", url: "", index: -1, stringToFill: "Mail", swapContentsAndDescription: false)
        suggestion.app = .mail
        let blank = Tab(url: "chrome://newtab/", isActive: true, index: 0)
        model.updateStatus(with: blank, suppressAutomaticSearch: true)
        model.state.suggestions = [suggestion]
        model.clickSuggestionAtIndex(0)
        XCTAssertEqual(opened.last?.0, .mail)
        XCTAssertTrue(opened.last?.1 === blank)
        let web = Tab(url: "https://example.com", isActive: true, index: 0)
        model.updateStatus(with: web, suppressAutomaticSearch: true)
        model.state.suggestions = [suggestion]
        model.clickSuggestionAtIndex(0)
        XCTAssertNil(opened.last?.1)
    }
    private var directory: URL?
    private var store: LocalStore?

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testNormalNewTabURLsUseNativePage() {
        for url in ["chrome://newtab", "chrome://newtab/", "phi://newtab/"] {
            XCTAssertTrue(Tab.shouldUseMistNativeNTP(url: url, isIncognito: false))
        }
    }

    func testChatOmniboxStartsEmptyAndPreservesChat() throws {
        let model = OmniBoxViewModel(windowState: try makeState())
        let chatURL = AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString
        let tab = Tab(url: chatURL, isActive: false, index: 0)
        model.updateStatus(with: tab, suppressAutomaticSearch: true)
        XCTAssertEqual(model.state.inputText, "")
        XCTAssertTrue(model.opensSubmissionInNewTab)
        model.updateInputText("old text")
        model.setCurrentTab(tab)
        XCTAssertEqual(model.state.inputText, "")
        XCTAssertTrue(model.opensSubmissionInNewTab)
        model.updateStatus(with: Tab(url: "https://example.com", isActive: false, index: 1))
        XCTAssertFalse(model.opensSubmissionInNewTab)
        XCTAssertEqual(model.state.inputText, "https://example.com")
    }

    func testPendingLinkAndOrdinaryURLsDoNotUseNativePage() {
        for url in [nil, "", "https://example.com", "about:blank"] as [String?] {
            XCTAssertFalse(Tab.shouldUseMistNativeNTP(url: url, isIncognito: false))
        }
        XCTAssertFalse(Tab.shouldUseMistNativeNTP(url: "chrome://newtab/", isIncognito: true))
        XCTAssertFalse(Tab.shouldUseMistNativeNTP(url: "chrome://newtab/", isIncognito: nil))
    }

    func testDelayedURLAndBackNavigationOptInWithoutLinkFlash() {
        let tab = Tab(url: nil, isActive: false, index: 0)
        tab.nativeNTPIsIncognito = false
        tab.updateMistNativeNTPForURL()
        XCTAssertFalse(tab.usesNativeNTP)
        tab.url = "https://example.com"
        XCTAssertFalse(tab.usesNativeNTP)
        tab.url = "chrome://newtab/"
        XCTAssertTrue(tab.usesNativeNTP)
        XCTAssertNotEqual(tab.title, Tab.incognitoNewTabTitle)
    }

    func testIncognitoStillRequiresCounterOptIn() {
        let tab = Tab(url: "chrome://newtab/", isActive: false, index: 0)
        tab.nativeNTPIsIncognito = true
        tab.updateMistNativeNTPForURL()
        XCTAssertFalse(tab.usesNativeNTP)
        tab.usesNativeNTP = true
        XCTAssertEqual(tab.title, Tab.incognitoNewTabTitle)
    }

    func testEscapeReachesComposerOnlyAfterPopupHandling() throws {
        let input = MistPromptTextView()
        input.string = "Keep this draft"
        var keys: [UInt16] = []
        input.onSlashKey = { keys.append($0.keyCode); return true }
        input.keyDown(with: try keyEvent(code: 53))
        XCTAssertEqual(keys, [53])
        XCTAssertEqual(input.string, "Keep this draft")
        input.onSlashKey = { keys.append($0.keyCode); return false }
        input.keyDown(with: try keyEvent(code: 53))
        XCTAssertEqual(keys, [53, 53])
        XCTAssertEqual(input.string, "Keep this draft")
    }

    func testPanelTabSwitchFollowsToggleChatbarInViewGroupAndHasBrowserScope() throws {
        let view = Shortcuts.Group.view.commands
        let index = try XCTUnwrap(view.firstIndex(of: .PHI_TOGGLE_CHATBAR))
        XCTAssertEqual(view.dropFirst(index + 1).first, .PHI_SWITCH_CHAT_PANEL_AND_TAB)
        XCTAssertEqual(CommandWrapper.PHI_SWITCH_CHAT_PANEL_AND_TAB.shortcutScope, .browser)
    }

    func testMarkerCommandsAreUnboundInViewGroup() {
        let commands: [CommandWrapper] = [.PHI_DRIFTER_PREVIOUS_MARKER, .PHI_DRIFTER_NEXT_MARKER]
        let view = Shortcuts.Group.view.commands
        for command in commands {
            XCTAssertNil(Shortcuts.DefaultShortcuts[command])
            XCTAssertEqual(command.shortcutScope, .browser)
            XCTAssertTrue(view.contains(command))
        }
        XCTAssertEqual(Array(view.suffix(3)), [.PHI_DRIFTER_EFFORT_MENU] + commands)
    }

    func testPickerShortcutsReachOnlyAFocusedDrifterComposer() throws {
        let bindings = Shortcuts.DefaultShortcuts.map {
            ShortcutBinding(commandID: $0.key.rawValue, key: $0.value, scope: $0.key.shortcutScope, source: .configured)
        }
        for (command, character) in [(CommandWrapper.PHI_DRIFTER_MODEL_MENU, "m"), (.PHI_DRIFTER_EFFORT_MENU, ".")] {
            let key = ShortcutsKey(characters: character, modifiers: .command)
            XCTAssertEqual(Shortcuts.DefaultShortcuts[command], key)
            XCTAssertTrue(ShortcutInventory(bindings: bindings).conflicts(for: command.rawValue, key: key, in: .browser).isEmpty)
        }

        let composer = MistNewTabComposerViewController(state: try makeState())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = composer.view
        composer.focusInput()
        XCTAssertNil(MistDrifterLaunchRow.focused(in: window), "The New Tab Page's composer has no pickers")

        let chat = AgentChatComposer()
        chat.configureLaunch()
        window.contentView = chat
        window.makeFirstResponder(chat.editor.textView)
        XCTAssertTrue(MistDrifterLaunchRow.focused(in: window) === chat.browserLaunchRow)
        window.makeFirstResponder(nil)
        XCTAssertNil(MistDrifterLaunchRow.focused(in: window))
    }

    private func keyEvent(code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: code))
    }

    func testFloatingOmniboxStillSwallowsOnlyForwardTab() throws {
        let state = try makeState()
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        let input = try XCTUnwrap(descendants(of: omnibox.view, type: OmniBoxTextField.self).first)
        let editor = NSTextView()
        XCTAssertTrue(input.control(input.textFiled, textView: editor,
                                    doCommandBy: #selector(NSTextView.insertTab(_:))))
        XCTAssertFalse(input.control(input.textFiled, textView: editor,
                                     doCommandBy: #selector(NSTextView.insertBacktab(_:))))
    }

    private func makeState(isIncognito: Bool = true) throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        return BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default", isIncognito: isIncognito)
    }

    private func descendants<T: NSView>(of view: NSView, type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, type: type)
        }
    }

    private func drainUpdates() {
        let drained = expectation(description: "Omnibox updates delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}

final class AgentChatNavigationSpy: NSObject, WebContentWrapper {
    let mediaControls: PhiMediaControls = InactiveMediaControlsStub()
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isMediaSessionMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false
    @objc dynamic var isDiscarded = false
    @objc dynamic var isUnloaded = false
    @objc dynamic var isDistillable = false
    @objc dynamic var pageColor: NSColor?
    @objc dynamic var devToolsTargetId: String? = nil

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    private(set) var navigatedURLs: [String] = []
    private(set) var customValues: [String] = []

    init(urlString: String?, title: String?) {
        self.urlString = urlString
        self.title = title
        super.init()
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) {
        navigatedURLs.append(urlString)
        self.urlString = urlString
    }
    func navigateInPlace(toURL urlString: String) { self.urlString = urlString }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) { customValues.append(customValue) }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func updateIsPeekPresented(_ presented: Bool) {}
    func toggleAudioMuted() {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}
