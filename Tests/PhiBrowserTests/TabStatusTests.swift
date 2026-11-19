// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class TabStatusTests: XCTestCase {
    func testCornerBadgeTracksAgentActivity() {
        XCTAssertNil(TabCornerBadgeStatus.resolve(isAgentActive: false))
        XCTAssertEqual(TabCornerBadgeStatus.resolve(isAgentActive: true), .agent)
    }

    func testAgentBadgeCombinesMultipleLiveBookmarkPanes() {
        XCTAssertEqual(TabCornerBadgeStatus.highestPriority([nil, .agent]), .agent)
        XCTAssertNil(TabCornerBadgeStatus.highestPriority([nil, nil]))
    }

    func testDiscardedAndUnloadedOpenIndicatorsUseThirtyPercentOpacity() {
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: false,
            isUnloaded: false,
            dimmingEnabled: true
        ), 1)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: true,
            isUnloaded: false,
            dimmingEnabled: true
        ), 0.3)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: false,
            isUnloaded: true,
            dimmingEnabled: true
        ), 0.3)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: true,
            isUnloaded: true,
            dimmingEnabled: true
        ), 0.3)
    }

    @MainActor
    func testFaviconScalingPreservesSlotsAndTracksPaneRebindingAndPreference() throws {
        let defaults = UserDefaults.standard
        let key = PhiPreferences.GeneralSettings.showUnloadedTabIndicators.rawValue
        let originalValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            defaults.set(originalValue, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        let leftWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://left.example")
        leftWrapper.isUnloaded = true
        let rightWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://right.example")
        let leftTab = Tab(guid: 901, url: leftWrapper.urlString, isActive: false,
                          index: 0, webContentView: leftWrapper)
        let rightTab = Tab(guid: 902, url: rightWrapper.urlString, isActive: false,
                           index: 1, webContentView: rightWrapper)
        let leftModel = TabStatusModel()
        let rightModel = TabStatusModel()
        leftModel.configure(with: leftTab)
        rightModel.configure(with: rightTab)
        let leftView = TabFaviconImageView(model: leftModel, cornerRadius: 3)
        let rightView = TabFaviconImageView(model: rightModel, cornerRadius: 3)
        let leftImage = try XCTUnwrap(leftView.subviews.first as? NSImageView)
        let rightImage = try XCTUnwrap(rightView.subviews.first as? NSImageView)

        for size in [CGFloat(14), 16, 18] {
            leftView.frame = CGRect(x: 0, y: 0, width: size, height: size)
            leftView.layoutSubtreeIfNeeded()
            XCTAssertEqual(leftImage.frame.width, size * 0.8, accuracy: 0.001)
            XCTAssertEqual(leftImage.frame.midX, size / 2, accuracy: 0.001)
            XCTAssertEqual(leftImage.frame.midY, size / 2, accuracy: 0.001)
            XCTAssertEqual(leftView.frame.width, size)
        }
        leftView.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        rightView.frame = leftView.frame

        func waitForWidths(_ left: CGFloat, _ right: CGFloat) {
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                leftView.layoutSubtreeIfNeeded()
                rightView.layoutSubtreeIfNeeded()
                return abs(leftImage.frame.width - left) < 0.001
                    && abs(rightImage.frame.width - right) < 0.001
            }, object: nil)
            wait(for: [updated], timeout: 2)
        }

        waitForWidths(12.8, 16)
        rightWrapper.isDiscarded = true
        waitForWidths(12.8, 12.8)
        leftWrapper.isUnloaded = false
        waitForWidths(16, 12.8)

        // Rebind the same pane views when the split order changes.
        leftModel.configure(with: rightTab)
        rightModel.configure(with: leftTab)
        waitForWidths(12.8, 16)

        defaults.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        waitForWidths(16, 16)
        defaults.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        waitForWidths(12.8, 16)

        leftModel.prepareForReuse()
        rightModel.prepareForReuse()
        waitForWidths(16, 16)
    }

    func testOpenIndicatorOnlyShowsForInactiveOpenTabs() {
        XCTAssertTrue(TabFaviconPresentation.showsOpenIndicator(
            isOpened: true,
            isActive: false
        ))
        XCTAssertFalse(TabFaviconPresentation.showsOpenIndicator(
            isOpened: true,
            isActive: true
        ))
        XCTAssertFalse(TabFaviconPresentation.showsOpenIndicator(
            isOpened: false,
            isActive: false
        ))
    }

    func testOpenIndicatorMetricsMatchPinnedAndBookmarkSpacing() {
        XCTAssertEqual(TabOpenIndicatorMetrics.diameter, 2)
        XCTAssertEqual(TabOpenIndicatorMetrics.pinnedSpacing, 3)
        XCTAssertEqual(TabOpenIndicatorMetrics.comfortablePinnedSpacing, 2)
        XCTAssertEqual(TabOpenIndicatorMetrics.bookmarkSpacing, 2)
    }

}
