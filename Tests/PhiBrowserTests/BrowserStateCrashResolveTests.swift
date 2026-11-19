// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Crash-page events resolve live page tabs by their Chromium guid.
@MainActor
final class BrowserStateCrashResolveTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    func testResolveTabFindsNormalTabByGuid() throws {
        let state = try makeState()
        state.tabs = [
            Tab(guid: 1, url: "https://a.example", isActive: false, index: 0),
            Tab(guid: 2, url: "https://b.example", isActive: false, index: 1),
        ]
        XCTAssertEqual(state.resolveTab(2)?.guid, 2)
    }

    func testResolveTabReturnsNilForUnknownGuid() throws {
        let state = try makeState()
        state.tabs = [Tab(guid: 1, url: "https://a.example", isActive: false, index: 0)]
        XCTAssertNil(state.resolveTab(99))
    }

}
