// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Settings
extension Settings.PaneIdentifier {
    static let general = Self("general")
    static let advanced = Self("advanced")
    static let shortcuts = Self("shortcuts")
    static let profiles = Self("profiles")
    static let spaces = Self("spaces")
}

extension NSImage {
    static func settingsPaneIcon(systemSymbolName: String, pointSize: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)!
            .withSymbolConfiguration(SymbolConfiguration(pointSize: pointSize, weight: .regular))!
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
            symbol.draw(in: NSRect(
                x: bounds.midX - symbol.size.width / 2,
                y: bounds.midY - symbol.size.height / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ))
            return true
        }
        image.isTemplate = true
        return image
    }
}
