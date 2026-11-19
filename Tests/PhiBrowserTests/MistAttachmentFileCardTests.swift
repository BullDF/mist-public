import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistAttachmentFileCardTests: XCTestCase {
    /// A tracking area fires under a view laid over the card (Mail's recipient suggestions over compose's attachments).
    func testCardHoversOnlyWhereNothingCoversIt() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let card = MistAttachmentFileCard(icon: NSImage(), name: "Notes.pdf", kind: nil, onOpen: {}, onRemove: {})
        card.frame = NSRect(origin: NSPoint(x: 10, y: 10), size: MistAttachmentFileCard.size)
        root.addSubview(card)
        root.addSubview(NSView(frame: NSRect(x: 110, y: 0, width: 290, height: 100)))
        func point(_ x: CGFloat) -> NSPoint { root.convert(NSPoint(x: x, y: 30), to: nil) }
        func enter(_ x: CGFloat) throws {
            card.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point(x), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        }
        func move(_ x: CGFloat) throws {
            card.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point(x), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        try enter(150)
        XCTAssertFalse(card.isHovered)
        try move(50)
        XCTAssertTrue(card.isHovered)
        try move(150)
        XCTAssertFalse(card.isHovered)
        try enter(50)
        XCTAssertTrue(card.isHovered)
    }
}
