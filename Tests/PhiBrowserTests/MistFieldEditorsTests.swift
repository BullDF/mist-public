import AppKit
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class MistFieldEditorsTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
    }
    override func tearDown() async throws {
        window.close()
        window = nil
    }

    private func settle() async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func selection(_ editor: NSText?) -> NSColor? {
        (editor as? NSTextView)?.selectedTextAttributes[.backgroundColor] as? NSColor
    }
    private func themed(_ view: NSView) -> NSColor {
        ThemedColor.mistTextSelection.resolve(theme: view.themeStateProvider.currentTheme, appearance: view.currentAppearance)
    }
    private func add(_ view: NSView, y: CGFloat) {
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 20, y: y, width: 300, height: 28)
    }

    func testWellStylesTheSharedEditorAndHandsItBackToOtherFields() async throws {
        let kitField = NSTextField(string: "kit"), plain = NSTextField(string: "plain")
        let well = MistFieldWellView(kitField)
        add(well, y: 200)
        add(plain, y: 100)
        XCTAssertTrue(window.makeFirstResponder(kitField))
        try await settle()
        let editor = try XCTUnwrap(kitField.currentEditor() as? NSTextView)
        XCTAssertEqual(selection(editor), themed(well))
        XCTAssertEqual(editor.insertionPointColor, .labelColor)
        XCTAssertEqual(well.layer?.borderWidth, 2)

        XCTAssertTrue(window.makeFirstResponder(plain))
        try await settle()
        XCTAssertTrue(plain.currentEditor() === editor)
        XCTAssertEqual(selection(editor), .selectedTextBackgroundColor)
        XCTAssertEqual(well.layer?.borderWidth, MistKit.borderWidth)
    }

    func testFocusMovingBetweenKitFieldsKeepsTheKitSelection() async throws {
        let first = NSTextField(string: "one"), second = NSTextField(string: "two")
        add(MistFieldWellView(first), y: 200)
        add(MistFieldWellView(second), y: 100)
        XCTAssertTrue(window.makeFirstResponder(first))
        try await settle()
        XCTAssertTrue(window.makeFirstResponder(second))
        try await settle()
        XCTAssertEqual(selection(second.currentEditor()), themed(second))
    }

    func testTokenFieldEditorTakesTheKitSelection() async throws {
        let tokens = NSTokenField(string: "")
        add(MistFieldWellView(tokens), y: 200)
        XCTAssertTrue(window.makeFirstResponder(tokens))
        try await settle()
        XCTAssertEqual(selection(tokens.currentEditor()), themed(tokens))
    }

    func testSelectableKitLabelSelectsInTheKitColor() async throws {
        let label = NSTextField.mistWrappingLabel("Subject", style: .cardTitle, selectable: true)
        XCTAssertTrue(label is MistSelectableLabel)
        XCTAssertFalse(NSTextField.mistWrappingLabel("Line", style: .secondary) is MistSelectableLabel)
        add(label, y: 200)
        // A click selects in a label; it never accepts first responder itself.
        label.selectText(nil)
        try await settle()
        XCTAssertEqual(selection(label.currentEditor()), themed(label))
    }

    func testSwiftUIWellClaimsItsTextField() async throws {
        let hosting = MistKitHostingView(rootView: MistFieldWell(shape: .rounded) { TextField("", text: .constant("value")) }.padding(20))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(hosting)
        try await settle()
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        let textField = try XCTUnwrap(field(in: hosting))
        XCTAssertTrue(window.makeFirstResponder(textField))
        try await settle()
        XCTAssertEqual(selection(textField.currentEditor()), themed(hosting))
    }

    func testTextViewSelectionFollowsTheTheme() {
        let textView = NSTextView()
        textView.applyMistSelection()
        XCTAssertEqual(textView.selectedTextAttributes[.backgroundColor] as? NSColor, themed(textView))
    }
}
