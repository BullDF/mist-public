import AppKit
import XCTest
@testable import Phi

final class MarkdownMathTests: XCTestCase {
    private var renderer: MarkdownRenderer {
        MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .systemFont(ofSize: 20),
            nsFontSubheading: .systemFont(ofSize: 17), nsFontSmall: .systemFont(ofSize: 12),
            textNS: .labelColor, dimNS: .secondaryLabelColor, typesetMath: MarkdownMathTypesetter.typeset)
    }

    func testTypesettingAndFallback() throws {
        let math = try XCTUnwrap(MarkdownMathTypesetter.typeset(latex: #"\frac{a}{b}"#, display: false, pointSize: 16, color: .labelColor))
        XCTAssertGreaterThan(math.image.size.width, 0)
        XCTAssertGreaterThan(math.image.size.height, 0)
        XCTAssertGreaterThan(math.baseline, 0)
        XCTAssertNil(MarkdownMathTypesetter.typeset(latex: #"\unknowncommand"#, display: false, pointSize: 16, color: .labelColor))
        let text = #"$\unknowncommand$"#
        XCTAssertEqual(renderer.markdownRuns(text, color: .labelColor).string, text + "\n")
        XCTAssertTrue(renderer.markdownRuns("value $x$", color: .labelColor).isEqual(to: renderer.markdownRuns("value $x$", color: .labelColor)))
    }

    func testTypesetsSizedDelimitersAndAliases() {
        for latex in [#"\ln a(E) \;=\; \ln a_i \;+\; \frac{E - E_i}{E_{i+1} - E_i}\,\bigl(\ln a_{i+1} - \ln a_i\bigr), \qquad E_i \le E \le E_{i+1}"#,
                      #"w_m \;=\; \exp\!\bigl(-4\,\lvert \ln p_m - \ln a(E) \rvert\bigr)\cdot \min\!\Bigl(1,\, \frac{\tau}{t_m}\Bigr)^{2}"#,
                      #"\max\!\Bigl(\frac{p_m}{a(E)},\, \frac{a(E)}{p_m}\Bigr)^{-4} \Bigl( x"#, #"\operatorname{softmax}(z) = \dfrac{e^z}{\lVert e^z \rVert}"#] {
            XCTAssertNotNil(MarkdownMathTypesetter.typeset(latex: latex, display: true, pointSize: 16, color: .labelColor), latex)
        }
    }

    func testInlineMathKeepsTheFontsAscent() throws {
        let text = renderer.markdownRuns("$x$", color: .labelColor)
        let attachment = try XCTUnwrap(text.attribute(.attachment, at: 0, effectiveRange: nil) as? MarkdownMathAttachment)
        let cell = try XCTUnwrap(attachment.attachmentCell as? MarkdownMathAttachmentCell)
        XCTAssertEqual(cell.ascent, NSFont.systemFont(ofSize: 14).ascender, accuracy: 0.01, "A cell holding only `$x$` lines up with text")
        let display = try XCTUnwrap(renderer.markdownRuns("$$x$$", color: .labelColor).attribute(.attachment, at: 0, effectiveRange: nil) as? MarkdownMathAttachment)
        XCTAssertEqual(try XCTUnwrap(display.attachmentCell?.cellSize().height), display.typeset.image.size.height, accuracy: 0.01, "Display math keeps its own height")
    }

    func testCopyMathAndPlainText() throws {
        let view = AgentChatTextView(frame: .zero, textContainer: nil)
        let rendered = renderer.markdownRuns("value $x$", color: .labelColor)
        view.textStorage?.setAttributedString(rendered)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 0, length: rendered.length - 1))
        // Copy passes the view's legacy type names; a rich text view also offers RTFD.
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes + [.rtfd]))
        XCTAssertNil(board.data(forType: .rtfd))
        XCTAssertEqual(board.string(forType: .string), "value $x$")
        let data = try XCTUnwrap(board.data(forType: .rtf))
        XCTAssertEqual(try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string, "value $x$")
        board.clearContents()
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "value")
    }
}
