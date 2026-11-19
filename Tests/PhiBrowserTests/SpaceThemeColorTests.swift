import XCTest
@testable import Phi

final class SpaceThemeColorTests: XCTestCase {
    /// Phi's Space color vocabulary is eight built-in themes, so a source
    /// color is snapped to the nearest hue rather than stored as-is. These
    /// pin which hue lands where.
    func testASourceColorSnapsToTheBuiltInThemeNearestInHue() {
        let expected: [(String, String)] = [
            ("#ff2d2d", "coral"),
            ("#ffcc33", "amber"),
            ("#3cd63c", "mint"),
            ("#33d6dd", "aqua"),
            ("#2f9dff", "mist"),
            ("#6f4dff", "iris"),
            ("#d94dff", "petal"),
        ]
        for (sourceHex, themeID) in expected {
            XCTAssertEqual(
                SpaceThemeColor.resolved(forSourceColorHex: sourceHex).themeID,
                themeID,
                "\(sourceHex) should snap to \(themeID)")
        }
    }

    /// An absent color takes the default theme without snapping a stand-in hue.
    func testASpaceWithNoThemeTakesTheDefaultThemeRatherThanASnappedStandIn() {
        let resolved = SpaceThemeColor.resolved(forSourceColorHex: nil)

        XCTAssertEqual(resolved.themeID, SpaceThemeColor.defaultThemeID)
        XCTAssertNotEqual(
            resolved.themeID,
            SpaceThemeColor.resolved(
                forSourceColorHex: LocalStore.defaultSpaceColorHex).themeID)
    }

    func testAColorTooCloseToNeutralTakesTheDefaultTheme() {
        for sourceHex in ["#808080", "#f2f2f0", "#0a0a0a", "#000000"] {
            XCTAssertEqual(
                SpaceThemeColor.resolved(forSourceColorHex: sourceHex).themeID,
                SpaceThemeColor.defaultThemeID,
                "\(sourceHex) names no hue and should take the default theme")
        }
    }

    /// Matching returns the theme's color rather than the input color.
    func testMatchingReturnsTheThemesColor() {
        let resolved = SpaceThemeColor.resolved(forSourceColorHex: "#ff2d2d")

        XCTAssertEqual(resolved.colorHex,
            SpaceThemeColor.overlayHex(ofThemeID: "coral"))
        XCTAssertNotEqual(resolved.colorHex, "#ff2d2d")
    }
}
