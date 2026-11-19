// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum SpaceThemeColor {
    /// A built-in theme and its overlay color.
    struct Resolved: Equatable {
        let themeID: String
        let colorHex: String
    }

    /// The theme for a source Space whose color names no hue — too close to
    /// neutral, or too dark — and for one the source gave no theme at all.
    static var defaultThemeID: String { Theme.default.id }

    /// A nil color is the source saying it gave this Space no theme, which
    /// takes the default rather than being snapped: substituting a color
    /// first would snap that stand-in to whatever hue it happened to have.
    static func resolved(forSourceColorHex hex: String?) -> Resolved {
        let themeID = hex.map(nearestThemeID(toColorHex:)) ?? defaultThemeID
        return Resolved(themeID: themeID, colorHex: overlayHex(ofThemeID: themeID))
    }

    /// Hue carries the source's color intent and is all the eight-theme
    /// vocabulary can hold; a color with too little saturation or brightness
    /// has no hue worth matching.
    private static let neutralSaturation: CGFloat = 0.15
    private static let neutralBrightness: CGFloat = 0.12

    private static func nearestThemeID(toColorHex hex: String) -> String {
        guard let source = hsb(of: NSColor(hexString: hex)),
              source.saturation >= neutralSaturation,
              source.brightness >= neutralBrightness else {
            return defaultThemeID
        }
        // Read off `Theme.builtInThemes` rather than restated here, so a theme
        // added to Phi becomes a color target with no second list to keep
        // in step. The default theme is left out of the comparison: its
        // overlay is white, so it has no hue — it is what a neutral falls
        // back to, not something a hue can be nearest to.
        let nearest = Theme.builtInThemes
            .filter { $0.id != defaultThemeID }
            .min { hueDistance(source.hue, of: $0) < hueDistance(source.hue, of: $1) }
        return nearest?.id ?? defaultThemeID
    }

    static func overlayHex(ofThemeID id: String) -> String {
        overlayColor(of: Theme.builtInThemes.first { $0.id == id } ?? Theme.default)
            .hexRGBString
    }

    /// Hue is 0...1 and wraps, so the distance is the shorter way round.
    private static func hueDistance(_ hue: CGFloat, of theme: Theme) -> CGFloat {
        guard let themeHue = hsb(of: overlayColor(of: theme))?.hue else {
            return .greatestFiniteMagnitude
        }
        let delta = abs(hue - themeHue)
        return min(delta, 1 - delta)
    }

    /// Light, explicitly: color matching must not depend on the appearance the user
    /// happens to be in. `setTheme` re-derives the stored `colorHex` for the
    /// live appearance as soon as the Space is created.
    private static func overlayColor(of theme: Theme) -> NSColor {
        theme.color(for: .windowOverlayBackground, appearance: .light)
    }

    private static func hsb(
        of color: NSColor
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
    }
}
