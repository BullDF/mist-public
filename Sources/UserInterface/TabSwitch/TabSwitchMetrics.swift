// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CoreGraphics

enum TabSwitchMetrics {
    private static let longPressThresholdKey = "TabSwitch.longPressThreshold"
    private static let defaultLongPressThreshold: TimeInterval = 0.25

    static var longPressThreshold: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: longPressThresholdKey)
        return stored > 0 ? stored : defaultLongPressThreshold
    }

    static let windowHorizontalInset: CGFloat = 16
    static let windowVerticalInset: CGFloat = 16
    static let windowCornerRadius: CGFloat = 20
    static let cellWidth: CGFloat = 182
    static let cellHeight: CGFloat = 157
    static let cellSpacing: CGFloat = 8
    static let cellCornerRadius: CGFloat = 8
    static let cellContentInset: CGFloat = 12

    static let previewInset: CGFloat = 12
    static let previewHeight: CGFloat = 105
    static let previewCornerRadius: CGFloat = 8

    static let titleTopSpacing: CGFloat = 8
    static let titleLineLimit = 1
    static let hoverAnimationDuration: TimeInterval = 0.15

    /// The panel stays this far inside its window's sides; tabs past it scroll.
    static let windowParentMargin: CGFloat = 32

    static func panelWidth(cellCount: Int) -> CGFloat {
        CGFloat(cellCount) * cellWidth
            + CGFloat(max(0, cellCount - 1)) * cellSpacing
            + windowHorizontalInset * 2
    }

    /// Whole cells that fit a panel at most `width` wide, at least one.
    static func visibleCellCount(fittingPanelWidth width: CGFloat) -> Int {
        let fitting = (width - windowHorizontalInset * 2 + cellSpacing) / (cellWidth + cellSpacing)
        return fitting >= 1 ? Int(fitting.rounded(.down)) : 1
    }
}
