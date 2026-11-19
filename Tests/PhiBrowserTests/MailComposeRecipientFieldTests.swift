import AppKit
import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailComposeRecipientFieldTests: XCTestCase {
    private func mount() async throws -> (MailComposeViewController, NSWindow, [NSTokenField]) {
        let source = FixtureMailPageDataSource(), snapshot = try await source.snapshot()
        let model = MailComposeModel(draft: .init(accountID: snapshot.accounts[0].id), source: source)
        let controller = MailComposeViewController(model: model, accounts: snapshot.accounts)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 700)); window.orderFrontRegardless()
        do { try await controller.editor.waitUntilReady() }
        catch { controller.editor.detach(); window.close(); throw error }
        func fields(in view: NSView) -> [NSTokenField] {
            if let field = view as? NSTokenField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        return (controller, window, fields(in: controller.view))
    }

    func testTypingAndCompletionKeepEditingStableUntilCommit() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        let to = try XCTUnwrap(fields.first)
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("johnnym", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.complete(nil)
        for _ in 0..<50 {
            controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(editor.string, "johnnym")
        XCTAssertTrue(controller.model.draft.to.isEmpty)
        // Autosave must not end the active field edit or validate its tokens.
        try await controller.model.saveNow()
        XCTAssertTrue(to.currentEditor() === editor)
        XCTAssertEqual(editor.string, "johnnym")
        XCTAssertTrue(controller.model.draft.to.isEmpty)
        controller.commitPendingFields()
        XCTAssertEqual(controller.model.draft.to, [.init("johnnym")])
        XCTAssertNil(to.currentEditor())
        try await controller.model.close()
    }

    func testEndingRecipientEditingPublishesTokensAndPreservesThemOnRender() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        func subject(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, !(field is NSTokenField), field.accessibilityLabel() == MailStrings.subjectField { return field }
            return view.subviews.lazy.compactMap { subject(in: $0) }.first
        }
        let to = try XCTUnwrap(fields.first), subjectField = try XCTUnwrap(subject(in: controller.view))
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("ada@cs.example.edu", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(window.makeFirstResponder(subjectField))
        XCTAssertEqual(controller.model.draft.to, [.init("ada@cs.example.edu")])
        let subjectEditor = try XCTUnwrap(subjectField.currentEditor() as? NSTextView)
        subjectEditor.insertText("Subject", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        let tokens = try XCTUnwrap(to.objectValue as? [Any])
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(controller.tokenField(to, editingStringForRepresentedObject: try XCTUnwrap(tokens.first)), "ada@cs.example.edu")
        XCTAssertEqual(controller.model.draft.to, [.init("ada@cs.example.edu")])
        try await controller.model.close()
    }

    func testEndingRecipientEditingPublishesCompletion() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        let to = try XCTUnwrap(fields.first)
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("Ad", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertCompletion("Ada <ada@example.com>", forPartialWordRange: NSRange(location: 0, length: 2), movement: 0, isFinal: true)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(controller.model.draft.to, [.init("ada@example.com", name: "Ada")])
        try await controller.model.close()
    }

    func testCompletionExcludesOnlyTheMatchingDraftRecipientList() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        XCTAssertEqual(fields.count, 3)
        let to = try XCTUnwrap(fields.first)
        for _ in 0..<100 where controller.model.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let ada = try XCTUnwrap(controller.model.suggestions.first { $0.address.email == "ada@example.com" }?.address)
        let display = MailComposeFormatting.display(ada)
        func completions(_ field: NSTokenField) -> [String] {
            controller.recipientSuggestions(for: field, matching: "ad").map(MailComposeFormatting.display)
        }
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("ad", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(completions(to).contains(display))
        controller.model.update { $0.to = [ada] }
        XCTAssertFalse(completions(to).contains(display))
        for field in fields.dropFirst() {
            XCTAssertTrue(completions(field).contains(display))
        }
        XCTAssertEqual(editor.string, "ad")
        controller.commitPendingFields()
        try await controller.model.close()
    }

    func testSuggestionListCompletesTheTypedRecipientAfterAToken() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        for _ in 0..<100 where controller.model.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let ada = try XCTUnwrap(controller.model.suggestions.first { $0.address.email == "ada@example.com" }?.address)
        func list(in view: NSView) -> MailRecipientSuggestionList? {
            view as? MailRecipientSuggestionList ?? view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        let to = try XCTUnwrap(fields.first), suggestions = try XCTUnwrap(list(in: controller.view))
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("team@example.com,", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(suggestions.isHidden)
        editor.insertText("ad", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: to))
        XCTAssertFalse(suggestions.isHidden)
        let index = try XCTUnwrap(suggestions.matches.firstIndex(of: ada))
        XCTAssertNil(suggestions.selectedAddress)
        // Return with nothing selected keeps the list's hands off the typed text.
        XCTAssertFalse(controller.control(to, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: to))
        // Through the field editor, as keys arrive.
        for _ in 0...index { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        XCTAssertEqual(suggestions.selectedAddress, ada)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(suggestions.isHidden)
        XCTAssertEqual(editor.string, String(repeating: String(Character(UnicodeScalar(NSTextAttachment.character)!)), count: 2))
        controller.commitPendingFields()
        XCTAssertEqual(controller.model.draft.to, [.init("team@example.com"), ada])
        try await controller.model.close()
    }

    func testChoosingASuggestionKeepsAQuotedNamesCommaInOneToken() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        for _ in 0..<100 where controller.model.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        func list(in view: NSView) -> MailRecipientSuggestionList? {
            view as? MailRecipientSuggestionList ?? view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        let to = try XCTUnwrap(fields.first), suggestions = try XCTUnwrap(list(in: controller.view))
        XCTAssertTrue(window.makeFirstResponder(to))
        let editor = try XCTUnwrap(to.currentEditor() as? NSTextView)
        editor.insertText("ad", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: to))
        XCTAssertFalse(suggestions.isHidden)
        let doe = MailAddress("john@example.com", name: "Doe, John")
        suggestions.onChoose?(doe)
        XCTAssertEqual(to.tokenizingCharacterSet, CharacterSet(charactersIn: ",;\n\r"))
        controller.commitPendingFields()
        XCTAssertEqual(controller.model.draft.to, [doe])
        try await controller.model.close()
    }

    func testRecipientFieldsHaveFixedHeightAndTokensHaveValueEquality() async throws {
        let (controller, window, fields) = try await mount()
        defer { controller.editor.detach(); window.close() }
        XCTAssertEqual(fields.count, 3)
        for field in fields {
            XCTAssertEqual(field.intrinsicContentSize, NSSize(width: NSView.noIntrinsicMetric, height: 18))
            XCTAssertEqual(field.cell?.wraps, false); XCTAssertEqual(field.cell?.isScrollable, true)
            let first = try XCTUnwrap(controller.tokenField(field, representedObjectForEditing: "Ada <Ada@example.com>") as? NSObject)
            let equal = try XCTUnwrap(controller.tokenField(field, representedObjectForEditing: "Ada <ada@example.com>") as? NSObject)
            let renamed = try XCTUnwrap(controller.tokenField(field, representedObjectForEditing: "Other <ada@example.com>") as? NSObject)
            XCTAssertEqual(first, equal); XCTAssertEqual(first.hash, equal.hash)
            XCTAssertNotEqual(first, renamed)
        }
        controller.commitPendingFields()
        try await controller.model.close()
    }
}
