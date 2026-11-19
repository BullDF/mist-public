// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class OmniBoxThemeTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testOmniBoxTracksWindowThemeWhileVisibleAndAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let context = state.themeContext
        let red = Theme(id: "omnibox-red", name: "Red", colorPalette: [.windowBackground: ColorPair(.red)])
        let yellow = Theme(id: "omnibox-yellow", name: "Yellow", colorPalette: [.windowBackground: ColorPair(.yellow)])
        // The panel is the kit's card, a step lighter than a dark page.
        func card(_ theme: Theme) -> NSColor { ThemedColor.mistCardFill.resolve(theme: theme, appearance: .dark) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
                                                     profileId: state.profileId, account: store.account,
                                                     browserState: state)
        context.mirrorsSharedTheme = false
        context.mirrorsSharedAppearance = false
        context.setUserAppearanceChoice(.dark)
        context.setTheme(red)
        drainThemeUpdates()
        defer {
            controller.omniBoxHostPanel?.orderOut(nil)
            window.close()
            withExtendedLifetime(controller) {}
        }

        let panel = try XCTUnwrap(controller.attachAndShowOmniBoxHostPanel())
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        panel.contentView?.addSubview(omnibox.view)
        let background = try XCTUnwrap(omnibox.view.subviews.first as? MistCardView)
        XCTAssertTrue(panel.themeStateProvider === context)
        XCTAssertTrue(background.themeStateProvider === context)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, card(red))

        // Updating the active Space's window context must refresh an already mounted overlay.
        context.setTheme(yellow)
        drainThemeUpdates()
        assertBackground(background, card(yellow))

        // Reuse the same panel and views, as the production dismiss/show path does.
        omnibox.view.removeFromSuperview()
        window.removeChildWindow(panel)
        panel.orderOut(nil)
        context.setTheme(red)
        drainThemeUpdates()
        XCTAssertTrue(controller.attachAndShowOmniBoxHostPanel() === panel)
        panel.contentView?.addSubview(omnibox.view)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, card(red))

        context.setUserAppearanceChoice(.light)
        drainThemeUpdates()
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .light)
        assertBackground(background, .white)
        context.setUserAppearanceChoice(.dark)
        drainThemeUpdates()
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, card(red))
    }

    func testFloatingFieldTakesTheKitSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        window.contentView?.addSubview(omnibox.view)
        omnibox.view.frame = NSRect(x: 0, y: 0, width: 680, height: 57)
        omnibox.focusTextField()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
        func fields(in view: NSView) -> [OmniBoxTextField] {
            (view as? OmniBoxTextField).map { [$0] } ?? view.subviews.flatMap(fields(in:))
        }
        let input = try XCTUnwrap(fields(in: omnibox.view).first)
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        let themed = ThemedColor.mistTextSelection.resolve(theme: omnibox.view.themeStateProvider.currentTheme,
                                                           appearance: omnibox.view.currentAppearance)
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, themed,
                       "The panel's inline completion shows in the kit's selection, never the accent color")
    }

    func testIncognitoOmniBoxUsesLightInputTextWhenAppAppearanceIsLight() throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store,
                                 profileId: "Default", isIncognito: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
                                                     profileId: state.profileId, account: store.account,
                                                     browserState: state)
        defer {
            controller.omniBoxHostPanel?.orderOut(nil)
            window.close()
            withExtendedLifetime(controller) {}
        }

        let panel = try XCTUnwrap(controller.attachAndShowOmniBoxHostPanel())
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        panel.contentView?.addSubview(omnibox.view)
        func fields(in view: NSView) -> [OmniBoxTextField] {
            (view as? OmniBoxTextField).map { [$0] } ?? view.subviews.flatMap(fields(in:))
        }
        let input = try XCTUnwrap(fields(in: omnibox.view).first)
        input.updateDisplayText("google.com")
        omnibox.focusTextField()
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)

        XCTAssertEqual(NSApp.effectiveAppearance.phiAppearance, .light)
        XCTAssertEqual(window.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(input.textFiled.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(editor.effectiveAppearance.phiAppearance, .dark)
        var textBrightness: CGFloat?
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            textBrightness = editor.textColor?.usingColorSpace(.genericGray)?.whiteComponent
        }
        XCTAssertGreaterThan(try XCTUnwrap(textBrightness), 0.5)
    }

    func testUnownedPanelKeepsGlobalThemeFallback() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertNil(panel.browserThemeContext)
        XCTAssertTrue(panel.themeStateProvider === ThemeManager.shared)
    }

    func testOtherEngineSuggestionsAreUnsupported() {
        let otherEngine = OmniBoxSuggestion(chromiumDic: [
            "type": "search-other-engine", "contents": "spotify.com cats",
            "description": "Spotify", "destinationUrl": "https://open.spotify.com/search/cats",
            "fillIntoEdit": "spotify.com cats", "line": 0
        ])
        let defaultEngine = OmniBoxSuggestion(chromiumDic: [
            "type": "search-what-you-typed", "contents": "spotify.com cats",
            "description": "", "destinationUrl": "https://default.example/search?q=spotify.com+cats",
            "fillIntoEdit": "spotify.com cats", "line": 1
        ])

        XCTAssertEqual(otherEngine.type, .searchEngine)
        XCTAssertFalse(otherEngine.isSupportedType)
        XCTAssertEqual(defaultEngine.type, .searchSuggest)
        XCTAssertTrue(defaultEngine.isSupportedType)
    }

    func testOnlyNewTabOmniBoxSwitchesToOpenTabsByDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let viewModel = OmniBoxViewModel(windowState: BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default"))

        viewModel.opennedFromCurrentTab = false
        XCTAssertTrue(viewModel.switchesToOpenTabByDefault)
        viewModel.opennedFromCurrentTab = true
        XCTAssertFalse(viewModel.switchesToOpenTabByDefault)
    }

    private func drainThemeUpdates() {
        let drained = expectation(description: "Theme updates delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    /// The card's fill is its surface layer's, drawn above its shadow layers and below its content view's layer.
    private func assertBackground(_ card: MistCardView, _ expected: NSColor,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let surface = card.layer?.sublayers?.last { layer in !card.subviews.contains { $0.layer === layer } }
        guard let cgColor = surface?.backgroundColor,
              let actual = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected an sRGB omnibox background", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}
