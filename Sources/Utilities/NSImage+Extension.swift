// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

extension NSImage {
    static  func configureSymbolImage(
        systemName: String,
        pointSize: CGFloat = 20,
        weight: NSFont.Weight = .regular,
        color: NSColor = .systemRed
    ) -> NSImage? {
        
        let weightConfig = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        )
        
        let colorConfig = NSImage.SymbolConfiguration(
            paletteColors: [color, color, color]
        )
        
        let combinedConfig = weightConfig.applying(colorConfig)
        
        return NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: nil
        )?
            .withSymbolConfiguration(combinedConfig)
    }
}
