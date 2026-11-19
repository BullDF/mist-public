import AppKit
import WebKit
import XCTest
import MistMailCore
@testable import Phi

@MainActor
final class MailComposeEditorTests: XCTestCase {
    private func editor(html: String, attachments: [MailDraftAttachment] = []) async throws -> (MailComposeEditor, NSWindow) {
        let source = FixtureMailPageDataSource(), snapshot = try await source.snapshot()
        let model = MailComposeModel(draft: .init(accountID: snapshot.accounts[0].id, html: html, attachments: attachments), source: source)
        let editor = MailComposeEditor(model: model)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        do { try await editor.waitUntilReady() }
        catch { window.close(); throw error }
        return (editor, window)
    }
    func testIsolatedEditingRunsWithContentJavaScriptOffAndMailScriptsDoNot() async throws {
        let (editor, window) = try await editor(html: "<script>document.documentElement.dataset.mailScript='ran'</script><img src=\"data:image/png;base64,broken\" onerror=\"document.documentElement.dataset.mailError='ran'\"><p>Hello</p>")
        defer { editor.detach(); window.close() }
        XCTAssertFalse(editor.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let result = try await editor.call("return {script:document.documentElement.dataset.mailScript || '', error:document.documentElement.dataset.mailError || '', editable:document.body.isContentEditable}") as? [String: Any]
        XCTAssertEqual(result?["script"] as? String, ""); XCTAssertEqual(result?["error"] as? String, "")
        XCTAssertEqual(result?["editable"] as? Bool, true)
        XCTAssertTrue(editor.configuration.websiteDataStore.isPersistent == false)
    }
    func testExportRemovesEditorNodesAndKeepsEditableQuotesInOneDocument() async throws {
        let (editor, window) = try await editor(html: "<div>Hello</div><blockquote type=\"cite\"><p>Original</p><blockquote type=\"cite\"><div>Nested</div></blockquote></blockquote><ul><li>First</li><li><a href=\"https://example.com\">Second</a></li></ul>")
        defer { editor.detach(); window.close() }
        let value = try await editor.exportDocument()
        XCTAssertTrue(value.html.hasPrefix("<!doctype html>")); XCTAssertFalse(value.html.contains("data-mist-compose"))
        XCTAssertFalse(value.html.contains("contenteditable")); XCTAssertTrue(value.html.contains("<blockquote type=\"cite\">"))
        XCTAssertTrue(value.plainText.contains("> Original")); XCTAssertTrue(value.plainText.contains("> > Nested"))
        XCTAssertTrue(value.plainText.contains("- First\n- Second"))
    }
    func testReplyPlainTextSeparatesParagraphsAndDefaultTextIsNormalSize() async throws {
        let (editor, window) = try await editor(html: MailComposeFormatting.document(html: "<div>Thanks</div><p>On Monday, Ada wrote:</p><blockquote type=\"cite\"><h1>Title</h1><p>Body</p></blockquote>"))
        defer { editor.detach(); window.close() }
        let value = try await editor.exportDocument()
        XCTAssertEqual(value.plainText, "Thanks\n\nOn Monday, Ada wrote:\n\n> Title\n> \n> Body")
        try await editor.call("window.MistMailCompose.focus(true)")
        let size = try await editor.call("return String(document.queryCommandValue('fontSize'))") as? String
        XCTAssertEqual(size, "2", "The 13px body must read as Normal, legacy size 2")
    }
    func testCIDRoundTripUsesSupportedSchemeAndServesImage() async throws {
        let source = FixtureMailPageDataSource(), messages = try await source.messages(in: .unifiedInbox, before: nil, limit: 200)
        let message = try XCTUnwrap(messages.first { $0.hasAttachments }), detail = try await source.detail(message.id)
        let file = try XCTUnwrap(detail.inlineFiles["diagram"])
        let (editor, window) = try await editor(html: "<img id=\"inline\" src=\"cid:diagram\">", attachments: [.init(filename: "diagram.png", file: file, contentID: "<diagram>")])
        defer { editor.detach(); window.close() }
        XCTAssertEqual(MailComposeEditor.usesNativeCID, !WKWebView.handlesURLScheme("cid"))
        let src = try await editor.call("return document.getElementById('inline').getAttribute('src')") as? String
        XCTAssertEqual(src?.hasPrefix(MailComposeEditor.usesNativeCID ? "cid:" : "mist-mail-cid:"), true)
        let size = try await editor.call("const img = document.getElementById('inline'); if (!img.complete) await new Promise(resolve => {img.onload=resolve;img.onerror=resolve;}); return img.naturalWidth;") as? Int
        XCTAssertEqual(size, 1)
        let value = try await editor.exportDocument()
        XCTAssertTrue(value.html.contains("src=\"cid:diagram\"")); XCTAssertFalse(value.html.contains("mist-mail-cid:"))
    }
    func testBoldOnSelectionAndLinkWithoutSelection() async throws {
        let (editor, window) = try await editor(html: "<p id=\"text\">Selected text</p>")
        defer { editor.detach(); window.close() }
        try await editor.call("const range=document.createRange();range.selectNodeContents(document.getElementById('text'));getSelection().removeAllRanges();getSelection().addRange(range);window.MistMailCompose.saveSelection();")
        try await editor.exec("bold")
        let value = try await editor.exportDocument()
        XCTAssertTrue(value.html.contains("<b>") || value.html.contains("font-weight"))
        try await editor.call("window.MistMailCompose.focus(true)")
        try await editor.exec("createLink", value: "https://example.com")
        let linked = try await editor.exportDocument()
        XCTAssertTrue(linked.html.contains(">https://example.com</a>"))
    }
}
