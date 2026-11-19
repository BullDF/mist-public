import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistPromptCodeBlockTests: XCTestCase {
    private func host() -> (MistPromptEditor, NSWindow) {
        let editor = MistPromptEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 650, height: 64)
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.makeFirstResponder(editor.textView)
        editor.layoutSubtreeIfNeeded()
        return (editor, window)
    }

    private func typeFence(_ editor: MistPromptEditor) {
        for _ in 0..<3 { editor.textView.insertText("`", replacementRange: editor.textView.selectedRange()) }
    }

    private func openFence(_ editor: MistPromptEditor) throws {
        typeFence(editor)
        editor.textView.keyDown(with: try key(36, flags: .shift))
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testTypingOpensBlockWithHiddenGlyphsAndMonospacedContent() throws {
        let (editor, window) = host()
        defer { window.close() }
        try openFence(editor)
        XCTAssertEqual(editor.text, "```\n\n```")
        XCTAssertEqual(editor.textView.selectedRange().location, 4)
        let storage = try XCTUnwrap(editor.textView.textStorage)
        XCTAssertEqual((storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        // Each fence keeps its first backtick as a clear glyph so its line has a fragment of its own.
        for index in [1, 2, 6, 7] {
            XCTAssertTrue(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null))
        }
        for index in [0, 4, 5] {
            XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null))
        }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .clear)
    }

    func testEnterSendsLiteralMarkdownAndModifiedEnterInsertsLine() throws {
        let (editor, window) = host()
        defer { window.close() }
        try openFence(editor)
        var sent: String?
        editor.textView.onSubmit = { sent = editor.text }
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(sent, "```\n\n```")
        editor.textView.keyDown(with: try key(36, flags: .shift))
        XCTAssertEqual(editor.text, "```\n\n\n```")
    }

    func testTypingFenceOnLastLineLeavesBlock() {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "```swift\na\n\n```"
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        typeFence(editor)
        XCTAssertEqual(editor.text, "```swift\na\n```\n")
        XCTAssertEqual(editor.textView.selectedRange().location, 15)
    }

    func testDownAndUpExitWithUndoableNewlines() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "```\nx\n```"
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertEqual(editor.text, "```\nx\n```\n")
        XCTAssertEqual(editor.textView.selectedRange().location, 10)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.text, "```\nx\n```")
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.doCommand(by: #selector(NSTextView.moveUp(_:)))
        XCTAssertEqual(editor.text, "\n```\nx\n```")
        XCTAssertEqual(editor.textView.selectedRange().location, 0)
    }

    func testLeavingBlockGivesTheEmptyLineBelowAFullHeightCaret() throws {
        let (editor, window) = host()
        defer { window.close() }
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        let container = try XCTUnwrap(editor.textView.textContainer)
        manager.ensureLayout(for: container)
        let plainLine = manager.extraLineFragmentRect.height
        let plainInput = editor.inputHeight
        editor.text = "```\nx\n```"
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertEqual(editor.text, "```\nx\n```\n")
        manager.ensureLayout(for: container)
        XCTAssertEqual(manager.extraLineFragmentRect.height, plainLine, "The caret's line is a plain line, not the fence's")
        XCTAssertEqual((editor.textView.typingAttributes[.font] as? NSFont)?.pointSize, 16)
        let height = editor.inputHeight
        XCTAssertGreaterThan(height, plainInput)
        editor.textView.insertText("y", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(height, editor.inputHeight, "Typing on the line doesn't grow the composer")

        editor.text = "```\nx\n\n```"
        editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        typeFence(editor)
        XCTAssertEqual(editor.text, "```\nx\n```\n")
        manager.ensureLayout(for: container)
        XCTAssertEqual(manager.extraLineFragmentRect.height, plainLine)
        XCTAssertEqual(editor.inputHeight, height)
    }

    func testBackspaceEmptyBlockRemovesIt() throws {
        let (editor, window) = host()
        defer { window.close() }
        try openFence(editor)
        editor.textView.doCommand(by: #selector(NSTextView.deleteBackward(_:)))
        XCTAssertEqual(editor.text, "")
        XCTAssertEqual(editor.textView.selectedRange().location, 0)
        editor.text = "```python"
        editor.textView.keyDown(with: try key(36, flags: .shift))
        editor.textView.doCommand(by: #selector(NSTextView.deleteBackward(_:)))
        XCTAssertEqual(editor.text, "")
    }

    func testOneUndoRevertsTheConvertingKeystroke() throws {
        let (editor, window) = host()
        defer { window.close() }
        // One group per key event, as AppKit's event grouping makes them; the conversion joins its keystroke's group.
        let undo = try XCTUnwrap(editor.textView.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        for character in "```python" {
            undo.beginUndoGrouping()
            editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
            undo.endUndoGrouping()
        }
        undo.beginUndoGrouping()
        editor.textView.keyDown(with: try key(36, flags: .shift))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.text, "```python\n\n```")
        undo.undo()
        XCTAssertEqual(editor.text, "```python")
        XCTAssertEqual(editor.textView.selectedRange().location, 9)
    }

    func testFenceStaysLiteralUntilModifiedEnter() throws {
        let (editor, window) = host()
        defer { window.close() }
        typeFence(editor)
        XCTAssertEqual(editor.text, "```")
        var sent: String?
        editor.textView.onSubmit = { sent = editor.text }
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(sent, "```")
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 0)).contains(.null))
    }

    func testLanguageHeaderAndPlainOpeningHeight() throws {
        let (editor, window) = host()
        defer { window.close() }
        for language in ["python", ""] {
            editor.text = "```" + language
            editor.textView.keyDown(with: try key(36, flags: .shift))
            let manager = try XCTUnwrap(editor.textView.layoutManager)
            manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
            let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: editor.text).first)
            XCTAssertEqual(AgentCodeBlockDrawing.fenceLineRect(block.opening, manager: manager).height, language.isEmpty ? 10 : 32, accuracy: 0.1)
            XCTAssertTrue(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 1)).contains(.null))
            if !language.isEmpty { XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 3)).contains(.null)) }
        }
    }

    func testEditingFenceAboveBlockKeepsItVisible() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "\nplain\n```\nx\n```"
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        typeFence(editor)
        XCTAssertEqual(editor.textView.styledCodeBlocks.first?.opening.location, 10)
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 0)).contains(.null))
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.textView.styledCodeBlocks.first?.opening.location, 0)
    }

    func testRestoredDraftStylesCodeAndTypingAttributes() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.setText("plain\n```swift\ncode\n```", mentions: [])
        editor.textView.setSelectedRange(NSRange(location: 15, length: 0))
        let attrs = editor.textView(editor.textView, shouldChangeTypingAttributes: [:], toAttributes: [:])
        XCTAssertEqual((attrs[.font] as? NSFont)?.pointSize, 14)
        XCTAssertEqual((attrs[.font] as? NSFont)?.isFixedPitch, true)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let plain = editor.textView(editor.textView, shouldChangeTypingAttributes: [:], toAttributes: [:])
        XCTAssertEqual((plain[.font] as? NSFont)?.pointSize, 16)
        XCTAssertEqual(editor.textView.textStorage?.attribute(.agentHiddenFence, at: 7, effectiveRange: nil) as? Bool, true)
        let block = try XCTUnwrap(editor.textView.styledCodeBlocks.first)
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        XCTAssertEqual(AgentCodeBlockDrawing.fenceLineRect(block.opening, manager: manager).height, 32, accuracy: 0.1)
        XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 9)).contains(.null))
    }

    func testCodeSuppressesMentionAndCommandPopupsAndStyling() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.mentionsEnabled = true
        editor.mentionTabs = { [Tab(guid: 1, url: "https://example.com", isActive: false, index: 0, title: "Page")] }
        editor.slashCommandsEnabled = true
        editor.slashCommands = [.init(name: "usr", description: "Test", argumentHint: "")]
        for content in ["@", "/usr"] {
            editor.text = "```\n" + content + "\n```"
            editor.textView.setSelectedRange(NSRange(location: 4 + content.utf16.count, length: 0))
            editor.updateSlashCommands()
            XCTAssertTrue(editor.mentionPopup.matches.isEmpty)
            XCTAssertTrue(editor.commandPopup.matches.isEmpty)
            XCTAssertNil(editor.textView.textStorage?.attribute(AgentChatSlashStyle.token, at: 4, effectiveRange: nil))
            var sent = false
            editor.textView.onSubmit = { sent = true }
            editor.textView.keyDown(with: try key(36))
            XCTAssertTrue(sent)
        }
    }


    func testPasteAndRangeReplacementStayLiteral() {
        let (editor, window) = host()
        defer { window.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("`", forType: .string)
        editor.text = "``"
        editor.textView.paste(from: pasteboard)
        XCTAssertEqual(editor.text, "```")
        editor.text = "``x"
        editor.textView.setSelectedRange(NSRange(location: 2, length: 1))
        editor.textView.insertText("`", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.text, "```")
    }

    func testPlainTextHeightIsUnchangedAndCodeUsesActualLayout() throws {
        let (editor, window) = host()
        defer { window.close() }
        let lineHeight = ceil(try XCTUnwrap(editor.textView.layoutManager).defaultLineHeight(for: .systemFont(ofSize: 16)))
        for count in 1...10 {
            editor.text = Array(repeating: "line", count: count).joined(separator: "\n")
            XCTAssertEqual(editor.inputHeight, 64 + CGFloat(min(count, 8) - 1) * (lineHeight + 4))
            editor.text = String(repeating: "\n", count: count - 1)
            XCTAssertEqual(editor.inputHeight, 64 + CGFloat(min(count, 8) - 1) * (lineHeight + 4))
        }
        editor.slashCommandsEnabled = true
        editor.slashCommands = [.init(name: "usr", description: "Test", argumentHint: "")]
        editor.text = "/usr\n/usr\n/usr"
        XCTAssertEqual(editor.inputHeight, 64 + 2 * (lineHeight + 4))
        editor.text = "```\nx\n```"
        XCTAssertLessThan(editor.inputHeight, 64 + 2 * (lineHeight + 4))
    }

    func testWrappedCodeArrowsOnlyExitAtVisualEdges() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "```\n" + String(repeating: "x", count: 300) + "\n```"
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertFalse(editor.text.hasSuffix("\n"))
        XCTAssertNotNil(AgentCodeBlocks.containing(editor.textView.selectedRange(), in: editor.text))
        editor.textView.setSelectedRange(NSRange(location: 304, length: 0))
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertTrue(editor.text.hasSuffix("\n"))
    }

    func testBoxSpansItsOwnFenceLinesBetweenPlainLines() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "before\n```\ncode\n```\nafter"
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: editor.text).first)
        func line(at character: Int) -> NSRect {
            manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil)
        }
        let top = AgentCodeBlockDrawing.fenceLineRect(block.opening, manager: manager)
        let bottom = AgentCodeBlockDrawing.fenceLineRect(block.closing, manager: manager)
        XCTAssertGreaterThanOrEqual(top.minY, line(at: 0).maxY, "The box starts below the line before it")
        XCTAssertLessThanOrEqual(top.maxY, line(at: block.content.location).minY)
        XCTAssertGreaterThanOrEqual(bottom.minY, line(at: block.content.location).maxY)
        XCTAssertLessThanOrEqual(bottom.maxY, line(at: (editor.text as NSString).length - 1).minY, "The box ends above the line after it")
        XCTAssertEqual(top.minY - line(at: 0).maxY, 6, accuracy: 0.5, "A gap separates the box from the line before it")
        XCTAssertEqual(line(at: (editor.text as NSString).length - 1).minY - bottom.maxY, 6, accuracy: 0.5, "and from the line after it")
    }

    func testFinalBlockKeepsItsBottomPadding() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "```\ncode\n```"
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
        let block = try XCTUnwrap(AgentCodeBlocks.blocks(in: editor.text).first)
        let code = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: block.content.location), effectiveRange: nil)
        let bottom = AgentCodeBlockDrawing.fenceLineRect(block.closing, manager: manager)
        XCTAssertEqual(bottom.minY, code.maxY, accuracy: 0.5)
        XCTAssertEqual(bottom.height, 10, accuracy: 0.5, "The final fence line is the box's bottom padding")
    }

    func testLineStartCaretFitsInsideTheClipViewAndTextStaysPut() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "jjl"
        let manager = try XCTUnwrap(editor.textView.layoutManager)
        let container = try XCTUnwrap(editor.textView.textContainer)
        manager.ensureLayout(for: container)
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let start = editor.textView.convert(NSPoint(x: line.minX + manager.location(forGlyphAt: 0).x, y: 0), to: editor).x
        XCTAssertEqual(start, 46)
        // The text wraps short of the overlay scroll bar at the scroll view's right edge.
        XCTAssertEqual(container.size.width - 2 * container.lineFragmentPadding,
                       editor.bounds.width - 58 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        let clip = try XCTUnwrap(editor.textView.enclosingScrollView).contentView
        // The 2 pt caret is centered on its insertion point.
        XCTAssertLessThanOrEqual(clip.convert(clip.bounds, to: editor).minX, start - 1)
    }

    func testClearingASentBlockRestoresThePlainCaret() throws {
        let (editor, window) = host()
        defer { window.close() }
        for draft in ["```python\nx = 1\n```", "```\nx = 1\n```"] {
            editor.text = draft
            editor.text = ""
            let font = try XCTUnwrap(editor.textView.typingAttributes[.font] as? NSFont)
            let style = try XCTUnwrap(editor.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            XCTAssertEqual(font.pointSize, 16)
            XCTAssertEqual(style.firstLineHeadIndent, 0)
            XCTAssertEqual(style.maximumLineHeight, editor.textView.defaultParagraphStyle?.maximumLineHeight)
        }
    }
}
