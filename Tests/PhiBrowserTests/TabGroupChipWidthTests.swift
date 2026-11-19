// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class TabGroupChipWidthTests: XCTestCase {

    func test_expanded_includesCountBadge() {
        let width = TabGroupChipView.chipWidth(
            forTitle: "Work",
            memberCount: 5,
            isCollapsed: false
        )
        // leadingPad(6) + dot(16) + dotGap(6) + label("Work"@13pt~38) + safety(4)
        //   + countToLabelGap(6) + countBadge(~22) + rightPad(6)
        // ≈ 104. Allow ±20pt range for font measurement variance.
        XCTAssertGreaterThan(width, 84)
        XCTAssertLessThan(width, 125)
    }

    func test_collapsed_includesMosaicInsteadOfCount() {
        let expanded = TabGroupChipView.chipWidth(
            forTitle: "Work",
            memberCount: 5,
            isCollapsed: false
        )
        let collapsed = TabGroupChipView.chipWidth(
            forTitle: "Work",
            memberCount: 5,
            isCollapsed: true
        )
        // The 28pt mosaic replaces a roughly 19pt single-digit count badge.
        XCTAssertGreaterThan(collapsed, expanded)
        XCTAssertEqual(collapsed - expanded, 9, accuracy: 2)
    }

    func test_collapsed_widthDoesNotDependOnMemberCount() {
        // Mosaic is fixed-size regardless of whether overflow shows
        // (overflow lives inside slot 3, not as separate text width
        // budget).
        let smallGroup = TabGroupChipView.chipWidth(
            forTitle: "Work",
            memberCount: 2,
            isCollapsed: true
        )
        let bigGroup = TabGroupChipView.chipWidth(
            forTitle: "Work",
            memberCount: 100,
            isCollapsed: true
        )
        XCTAssertEqual(smallGroup, bigGroup, accuracy: 0.5,
            "Collapsed chip width should be invariant to memberCount.")
    }

    func test_hitTestUsesParentCoordinates() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        let chip = TabGroupChipView()
        chip.frame = CGRect(x: 48, y: 16, width: 120, height: TabGroupChipView.height)
        parent.addSubview(chip)

        let hit = parent.hitTest(CGPoint(x: 60, y: 24))

        XCTAssertTrue(hit === chip)
    }

    func test_clickingCollapsedMosaicTogglesCollapse() {
        let title = "Work"
        let width = TabGroupChipView.chipWidth(
            forTitle: title,
            memberCount: 5,
            isCollapsed: true
        )
        let chip = TabGroupChipView()
        chip.frame = CGRect(x: 0, y: 0, width: width, height: TabGroupChipView.height)
        chip.configure(
            token: "group-1",
            color: .blue,
            displayTitle: title,
            memberCount: 5,
            isCollapsed: true,
            memberFavicons: [nil, nil, nil, nil]
        )
        chip.layout()

        let collapseX = width - TabGroupChipView.labelRightPadding - TabGroupChipView.collapseControlSize
        let trailingX = collapseX - TabGroupChipView.collapseControlGap
        let mosaicX = trailingX - TabGroupChipMosaicView.mosaicSize
        let mosaicCenter = CGPoint(
            x: mosaicX + TabGroupChipMosaicView.mosaicSize / 2,
            y: TabGroupChipView.height / 2
        )

        var toggledToken: String?
        var clickedToken: String?
        chip.onCollapseToggle = { toggledToken = $0 }
        chip.onClick = { clickedToken = $0 }

        chip.mouseDown(with: mouseEvent(type: .leftMouseDown, location: mosaicCenter))
        chip.mouseUp(with: mouseEvent(type: .leftMouseUp, location: mosaicCenter))

        XCTAssertEqual(toggledToken, "group-1")
        XCTAssertNil(clickedToken)
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
