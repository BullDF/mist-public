// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// The bridge push is faked by calling the coordinator's delegate method.
/// Chromium knows no Browser under these window ids, so the bridge calls
/// made along the way return early (as in `ClosedWindowReleaseTests`).
@MainActor
final class ContentSurfaceControllerRebuildTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private let manager = SpaceManager(observeAccountChanges: false)
    private var chromiumWindows: [NSWindow] = []
    private var subscriptions = Set<AnyCancellable>()
    // Counted across tests: the registry is the process-wide singleton, so
    // an id must not repeat within the host process.
    private static var nextWindowId = 123459101

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "surface-rebuild-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
    }

    override func tearDown() async throws {
        subscriptions.removeAll()
        manager.discardSpacePrewarm()
        for slot in manager.slots { slot.closeShellIfPresent() }
        chromiumWindows.forEach { $0.close() }
        chromiumWindows.removeAll()
        // Drain queued UI reads before resetting their SwiftData context.
        let drained = expectation(description: "UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testLiveWindowAdoptsItsSurfaceBeforeTabsArrive() async throws {
        let slot = makeSlot()
        let windowId = Self.takeWindowId()
        let instance = makeSpaceInstance(in: slot, spaceId: "first", windowId: windowId)
        present(instance, in: slot)
        let state = instance.browserState
        var events: [String] = []
        let arrived = expectation(description: "Tab delivered by the coordinator")
        state.$contentSurfaceView.compactMap { $0 }.first()
            .sink { _ in events.append("surface") }
            .store(in: &subscriptions)
        state.$tabs.filter { !$0.isEmpty }.first()
            .sink { _ in events.append("tab"); arrived.fulfill() }
            .store(in: &subscriptions)
        let hostingView = NSView()
        PhiChromiumCoordinator.shared.contentSurfaceCreated(Int64(windowId), hostingView: hostingView)
        PhiChromiumCoordinator.shared.newTabCreated(
            withInfo: ["id": windowId + 1, "url": "https://example.com", "index": 0],
            windowId: Int64(windowId))
        await fulfillment(of: [arrived], timeout: 2)

        XCTAssertTrue(state.contentSurfaceView === hostingView)
        XCTAssertEqual(events, ["surface", "tab"])
        let container = instance.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(hostingView.isDescendant(of: container.view))
        XCTAssertTrue(container.hasContentSurface)
    }


    func testWindowCreatedWithBrowserAccessAdoptsItsSurfaceDirectly() throws {
        let slot = makeSlot()
        let windowId = Self.takeWindowId()
        let instance = makeSpaceInstance(in: slot, spaceId: "first", windowId: windowId)
        present(instance, in: slot)
        let hostingView = NSView()
        PhiChromiumCoordinator.shared.contentSurfaceCreated(Int64(windowId), hostingView: hostingView)
        XCTAssertTrue(instance.browserState.contentSurfaceView === hostingView)
        let container = instance.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(hostingView.isDescendant(of: container.view))
        XCTAssertTrue(container.hasContentSurface)
    }

    private static func takeWindowId() -> Int {
        nextWindowId += 1
        return nextWindowId
    }

    /// A slot in the registry with its shell window.
    private func makeSlot() -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        return slot
    }

    /// Stands in for the hidden Chromium window whose close ends a Space
    /// instance; closed in `tearDown`.
    private func makeChromiumWindow(for slot: SpaceWindowSlot) -> NSWindow {
        let window = NSWindow(contentRect: slot.shell!.window.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        chromiumWindows.append(window)
        return window
    }

    /// A live Space instance in `slot`'s shell, as `mainBrowserWindowCreated`
    /// builds one with browser access.
    private func makeSpaceInstance(in slot: SpaceWindowSlot, spaceId: String,
                                   windowId: Int) -> SpaceSessionController {
        let chromiumWindow = makeChromiumWindow(for: slot)
        let state = BrowserState(windowId: windowId, localStore: store, profileId: "Default", spaceId: spaceId)
        return SpaceSessionController(window: slot.shell!.window, windowId: windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            slot: slot, browserState: state, chromiumWindow: chromiumWindow)
    }

    /// Shows `instance` in `slot`'s shell and lays its tree out there.
    private func present(_ instance: SpaceSessionController, in slot: SpaceWindowSlot) {
        slot.presentRequestedSession(instance, activate: false)
        slot.shell?.split.setSidebarGeometry(width: 240, collapsed: false)
        slot.shell?.split.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(slot.visibleController === instance)
    }

}
