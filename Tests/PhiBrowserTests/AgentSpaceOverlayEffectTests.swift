import AppKit
import XCTest
@testable import Phi

@MainActor
final class AgentSpaceOverlayEffectTests: XCTestCase {
    func testClickTypeAndScrollEffectsWearTheSpaceThemeColor() throws {
        let overlay = AgentSpaceOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.applyTheme(.coral, appearance: .light)
        let expected = try XCTUnwrap(Theme.coral.color(for: .themeColor, appearance: .light).usingColorSpace(.sRGB))
        let before = Set((overlay.layer?.sublayers ?? []).map(ObjectIdentifier.init))
        overlay.playEffect(kind: .click, at: CGPoint(x: 100, y: 100), size: nil, dy: nil)
        overlay.playEffect(kind: .type, at: CGPoint(x: 200, y: 150), size: CGSize(width: 120, height: 24), dy: nil)
        overlay.playEffect(kind: .scroll, at: CGPoint(x: 200, y: 150), size: nil, dy: 1)
        func shapes(_ layer: CALayer) -> [CAShapeLayer] {
            ((layer as? CAShapeLayer).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap(shapes)
        }
        let added = (overlay.layer?.sublayers ?? []).filter { !before.contains(ObjectIdentifier($0)) }.flatMap(shapes)
        let colors = added.flatMap { [$0.strokeColor, $0.fillColor] }.compactMap { $0 }.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        XCTAssertGreaterThanOrEqual(colors.count, 4)
        for color in colors {
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.01)
        }
    }
}
