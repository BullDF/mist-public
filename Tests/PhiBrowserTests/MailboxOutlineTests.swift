import AppKit
import XCTest
@testable import Phi

@MainActor
final class MailboxOutlineTests: XCTestCase {
    func testDisclosureButtonsAreCenteredInExpandableRows() async throws {
        let controller = MailPageViewController(source: FixtureMailPageDataSource(), defaults: makeTestDefaults().defaults)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1100, height: 1000)); window.orderFrontRegardless()
        defer { window.close() }
        let outline = controller.outline
        XCTAssertEqual(outline.rowHeight, MistSidebarCellView.rowHeight)
        XCTAssertEqual(outline.intercellSpacing, .zero)
        for _ in 0..<100 {
            controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            // The empty snapshot already has an All Inboxes row.
            if outline.numberOfRows > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(outline.numberOfRows, 1)
        var expandableRows = 0
        func disclosure(in view: NSView) -> NSView? {
            if view.identifier == NSOutlineView.disclosureButtonIdentifier { return view }
            return view.subviews.lazy.compactMap { disclosure(in: $0) }.first
        }
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row), outline.isExpandable(item) else { continue }
            expandableRows += 1
            outline.scrollRowToVisible(row)
            let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
            controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let button = try XCTUnwrap(disclosure(in: rowView), "Missing disclosure button for row \(row)")
            let frame = outline.convert(button.bounds, from: button)
            XCTAssertEqual(frame.midY, outline.rect(ofRow: row).midY, accuracy: 1, "Row \(row)")
            XCTAssertEqual(outline.frameOfOutlineCell(atRow: row).midY, outline.rect(ofRow: row).midY, accuracy: 1)
        }
        XCTAssertGreaterThan(expandableRows, 0)
    }
}
