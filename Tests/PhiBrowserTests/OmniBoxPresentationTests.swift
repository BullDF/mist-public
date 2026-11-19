// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor
final class OmniBoxPresentationTests: XCTestCase {
    func testHeldEscapeIsConsumedThroughDismissalUntilRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let container = OmniBoxContainerViewController(browserState: state)
        let browserWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: browserWindow.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: browserWindow.frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        browserWindow.isReleasedWhenClosed = false
        panel.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        browserWindow.addChildWindow(panel, ordered: .above)
        panel.contentView?.addSubview(container.view)
        container.view.frame = try XCTUnwrap(panel.contentView).bounds
        await drainUpdates()

        let escape = try keyEvent(window: panel)
        XCTAssertTrue(container.handleKeyboardEvent(escape) === escape,
                      "An inactive omnibox must leave Escape to the current responder")
        container.showOmniBox(fromAddressBar: false)
        let unrelatedEscape = try keyEvent(window: otherWindow)
        XCTAssertTrue(container.handleKeyboardEvent(unrelatedEscape) === unrelatedEscape)
        XCTAssertTrue(container.hasShown)
        let ordinaryKey = try keyEvent(window: panel, keyCode: 0, characters: "a")
        XCTAssertTrue(container.handleKeyboardEvent(ordinaryKey) === ordinaryKey)

        var dismissals = 0
        let subscription = NotificationCenter.default.publisher(for: .phiInWindowOverlayVisibilityChanged)
            .sink { notification in
                if notification.object as? NSWindow === browserWindow,
                   notification.userInfo?["visible"] as? Bool == false {
                    dismissals += 1
                }
            }
        XCTAssertNil(container.handleKeyboardEvent(escape))
        XCTAssertFalse(container.hasShown)
        browserWindow.removeChildWindow(panel)
        XCTAssertNil(container.handleKeyboardEvent(try keyEvent(window: panel, isRepeat: true)))
        XCTAssertNil(container.handleKeyboardEvent(try keyEvent(window: browserWindow, isRepeat: true)))
        XCTAssertEqual(dismissals, 1, "Autorepeat must not dismiss again after focus returns to the browser")
        XCTAssertNil(container.handleKeyboardEvent(try keyEvent(window: browserWindow, type: .keyUp)))
        let nextEscape = try keyEvent(window: browserWindow)
        XCTAssertTrue(container.handleKeyboardEvent(nextEscape) === nextEscape)
        let closeShortcut = try keyEvent(window: browserWindow, keyCode: 13, characters: "w", modifiers: .command)
        XCTAssertTrue(container.handleKeyboardEvent(closeShortcut) === closeShortcut)

        browserWindow.addChildWindow(panel, ordered: .above)
        container.showOmniBox(fromAddressBar: false)
        XCTAssertNil(container.handleKeyboardEvent(try keyEvent(window: panel, keyCode: 13,
                                                               characters: "w", modifiers: .command)))
        XCTAssertFalse(container.hasShown)
        withExtendedLifetime(subscription) {}
        browserWindow.removeChildWindow(panel)
        panel.close()
        otherWindow.close()
        browserWindow.close()
        try await store.closeForAccountDirectoryRemoval()
        try FileManager.default.removeItem(at: directory)
    }

    private func keyEvent(window: NSWindow, type: NSEvent.EventType = .keyDown,
                          keyCode: UInt16 = 53, characters: String = "\u{1b}",
                          modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: isRepeat, keyCode: keyCode))
    }

    func testCenteredReopeningDoesNotReuseAddressBarFrameWhenSizeIsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let container = OmniBoxContainerViewController(browserState: state)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let anchor = NSView(frame: NSRect(x: 120, y: 540, width: 500, height: 40))
        root.addSubview(anchor)
        root.addSubview(container.view)
        container.view.frame = root.bounds
        let omnibox = try XCTUnwrap(container.omniBoxController)
        await drainUpdates()

        container.showOmniBox(fromAddressBar: false)
        let centeredFrame = omnibox.view.frame
        XCTAssertGreaterThan(centeredFrame.width, 0)
        container.hideOmniBox()
        await drainUpdates()

        var sizes: [NSSize] = []
        let subscription = omnibox.$contentSize.dropFirst().sink { sizes.append($0) }
        for _ in 0..<2 {
            container.showOmniBox(fromAddressBar: true, addressView: anchor)
            XCTAssertTrue(container.isAnchoredToAddressBarForTesting)
            XCTAssertNotEqual(omnibox.view.frame, centeredFrame)
            container.hideOmniBox()
            await drainUpdates()

            container.showOmniBox(fromAddressBar: false)
            XCTAssertFalse(container.isAnchoredToAddressBarForTesting)
            XCTAssertEqual(omnibox.view.frame, centeredFrame)
            container.hideOmniBox()
            await drainUpdates()
        }
        XCTAssertTrue(sizes.isEmpty, "Presentation changes must not require duplicate size publications")
        withExtendedLifetime(subscription) {}
        try await store.closeForAccountDirectoryRemoval()
        try FileManager.default.removeItem(at: directory)
    }

    func testNewRowsStartAtTheTopSoAppRowsAboveTheDefaultShow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // The list is collapsed when its first rows arrive; its height follows them.
        let view = OmniBoxSuggestionView(frame: NSRect(x: 0, y: 0, width: 600, height: 0))
        window.contentView?.addSubview(view)
        var app = OmniBoxSuggestion(type: .app, title: "Drifter", url: "", index: -1, stringToFill: "Drifter", swapContentsAndDescription: false)
        app.app = .drifter
        app.allowedToBeDefault = false
        let rows = [app] + (0..<8).map {
            OmniBoxSuggestion(type: .searchSuggest, title: "dr \($0)", url: "https://example.com/\($0)", index: $0,
                              stringToFill: "dr \($0)", swapContentsAndDescription: false)
        }
        view.layoutSubtreeIfNeeded()
        view.updateSuggestions(rows, selectedIndex: 1, dataSourceChanged: true)
        view.setFrameSize(NSSize(width: 600, height: 226))
        view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(tableView(in: view))
        XCTAssertEqual(table.visibleRect.minY, 0, "The app row above the default row must show")
        table.scrollRowToVisible(8)
        XCTAssertGreaterThan(table.visibleRect.minY, 0)
        view.updateSuggestions(rows, selectedIndex: 1, dataSourceChanged: true)
        XCTAssertEqual(table.visibleRect.minY, 0, "New rows start at the top")
        view.updateSuggestions(rows, selectedIndex: 8, dataSourceChanged: false)
        XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: 8)), "A selected row still scrolls into view")
    }

    private func tableView(in view: NSView) -> NSTableView? {
        view as? NSTableView ?? view.subviews.lazy.compactMap { self.tableView(in: $0) }.first
    }

    private func drainUpdates() async {
        let delivered = expectation(description: "View updates delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 1)
    }
}
