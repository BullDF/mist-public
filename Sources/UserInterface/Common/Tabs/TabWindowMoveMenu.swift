// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Row titles for the tab context menu's "Move to Another Window" submenu,
/// formatted like Chrome's: the window's active tab title, then how many other
/// tabs the window holds, with the title elided so the row fits.
enum TabWindowMoveMenu {
    /// Chrome's `kWindowTitleForMenuMaxWidth`.
    static let maxRowWidth: CGFloat = 400
    /// The title keeps at least this many characters' width, however long
    /// the "and N other tabs" part runs.
    static let minTitleCharacters = 4

    static func windowTitle(activeTabTitle: String, otherTabCount: Int) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        return windowTitle(activeTabTitle: activeTabTitle,
                           otherTabCount: otherTabCount,
                           maxWidth: maxRowWidth) { text in
            (text as NSString).size(withAttributes: [.font: font]).width
        }
    }

    static func windowTitle(activeTabTitle: String,
                            otherTabCount: Int,
                            maxWidth: CGFloat,
                            measure: (String) -> CGFloat) -> String {
        let suffixWidth = measure(format(title: "", otherTabCount: otherTabCount))
        let minWidth = measure(String(activeTabTitle.prefix(minTitleCharacters)))
        let title = elide(activeTabTitle,
                          toWidth: max(maxWidth - suffixWidth, minWidth),
                          measure: measure)
        return format(title: title, otherTabCount: otherTabCount)
    }

    private static func format(title: String, otherTabCount: Int) -> String {
        switch otherTabCount {
        case ...0:
            return title
        case 1:
            return String(
                format: NSLocalizedString("sidebar.tabContextMenu.moveToWindowSubmenu.windowWithOneOtherTab",
                    value: "%@ and 1 other tab",
                    comment: "Tab context menu - Move to Another Window row for a window holding one tab besides its active one. %@ is the active tab's title"),
                title)
        default:
            return String(
                format: NSLocalizedString("sidebar.tabContextMenu.moveToWindowSubmenu.windowWithOtherTabs",
                    value: "%1$@ and %2$d other tabs",
                    comment: "Tab context menu - Move to Another Window row for a window holding several tabs besides its active one. %1$@ is the active tab's title, %2$d how many other tabs the window holds"),
                title, otherTabCount)
        }
    }

    /// Cuts `text` at the end, adding "…", so it measures at most `width`.
    static func elide(_ text: String, toWidth width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard measure(text) > width else { return text }
        let characters = Array(text)
        func candidate(_ length: Int) -> String {
            let prefix = String(characters[..<length])
            return prefix.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "…"
        }
        // Longest prefix that still fits once the ellipsis is added.
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(candidate(mid)) <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return candidate(low)
    }
}
