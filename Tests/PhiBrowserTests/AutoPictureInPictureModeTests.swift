// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AutoPictureInPictureModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults().defaults
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallDefaultsToNormal() {
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), .normal)
    }

    func testUnknownStoredValueFallsBackToNormal() {
        defaults.set("sideways", forKey: PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), .normal)
    }

    func testSaveRoundTripsEveryMode() {
        for mode in AutoPictureInPictureMode.allCases {
            PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode, to: defaults)
            XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), mode)
        }
    }
}
