import AppKit
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class MistSelectableTextLinksTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func host(_ prefix: String, link: String, suffix: String, width: CGFloat) throws -> (MistKitHostingView, NSView, CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var text = AttributedString(prefix)
        var linked = AttributedString(link)
        linked.link = URL(fileURLWithPath: "/tmp/file.swift")
        text += linked
        text += AttributedString(suffix)
        let hosting = MistKitHostingView(rootView: Text(text).font(Font(font)).textSelection(.enabled)
            .frame(width: width, alignment: .leading))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let textView = try XCTUnwrap(all(hosting).first { $0.accessibilityRole() == .staticText })
        return (hosting, textView, ("M" as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The window point at the middle of character `column` on line `line` (of `lines`) of a flipped text view.
    private func point(column: Int, line: Int = 0, lines: Int = 1, in view: NSView, advance: CGFloat) -> NSPoint {
        let lineHeight = view.bounds.height / CGFloat(lines)
        let y = (CGFloat(line) + 0.5) * lineHeight
        return view.convert(NSPoint(x: (CGFloat(column) + 0.5) * advance, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
    }

    func testHandShowsOnlyOverTheLink() throws {
        let (hosting, text, advance) = try host("Read(", link: "/tmp/file.swift", suffix: ") · 12 lines", width: 600)
        XCTAssertFalse(hosting.handTarget(at: point(column: 2, in: text, advance: advance)))
        XCTAssertTrue(hosting.handTarget(at: point(column: 5, in: text, advance: advance)))
        XCTAssertTrue(hosting.handTarget(at: point(column: 19, in: text, advance: advance)))
        XCTAssertFalse(hosting.handTarget(at: point(column: 20, in: text, advance: advance)))
        XCTAssertFalse(hosting.handTarget(at: point(column: 25, in: text, advance: advance)))
    }

    func testHandFollowsAWrappedLinkOntoItsNextLine() throws {
        let path = "/Users/someone/Projects/mist/Sources/UserInterface/WebContent/AgentChat/AgentChatViewController.swift"
        let (hosting, text, advance) = try host("Update(", link: path, suffix: ")", width: 60 * 7.3)
        let lines = Int((text.bounds.height / NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular))).rounded())
        XCTAssertEqual(lines, 2)
        XCTAssertFalse(hosting.handTarget(at: point(column: 3, line: 0, lines: lines, in: text, advance: advance)))
        XCTAssertTrue(hosting.handTarget(at: point(column: 0, line: 1, lines: lines, in: text, advance: advance)))
    }
}
