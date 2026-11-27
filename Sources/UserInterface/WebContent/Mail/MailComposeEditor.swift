import AppKit
import WebKit
import UniformTypeIdentifiers
import MistMailCore

final class MailComposeEditor: MailRichTextEditor {
    static var usesNativeCID: Bool { !WKWebView.handlesURLScheme("cid") }
    let model: MailComposeModel
    private var signatureUpdate: Task<Void, Never>?
    /// WebKit registers the body's edits with this view's undo manager. Its own keeps them out of the window's,
    /// which the window's text fields share, and lets them go with the compose pane.
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    init(model: MailComposeModel) {
        self.model = model
        let cidHandler = MailComposeCIDHandler(model: model, nativeCID: Self.usesNativeCID)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: Self.usesNativeCID ? "cid" : "mist-mail-cid")
        super.init(configuration: configuration, compose: true)
        onError = { [weak model] in model?.report($0) }
        onChanged = { [weak model] in model?.editorChanged() }
        setAccessibilityLabel(MailStrings.messageBody)
        registerForDraggedTypes([.fileURL])
        model.exportEditor = { [weak self] in
            guard let self else { throw EditorError.invalidExport }
            return try await exportDocument()
        }
        var html = MailComposeFormatting.document(html: model.draft.html, plainText: model.draft.plainText)
        if !Self.usesNativeCID { html = MailBodyPreparation.rewriteCIDs(html, messageID: model.draft.id) }
        loadDocument(html)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Break the model/editor export lifetime after the final save, never while it is exporting.
    func detach() { model.exportEditor = nil }
    override func handleShortcut(_ command: String) {
        if command == "paste" { pasteAttachments(nil) }
        else { super.handleShortcut(command) }
    }

    func exportDocument() async throws -> MailComposeExport {
        await signatureUpdate?.value
        guard let value = try await call("return window.MistMailCompose.export(signature)", arguments: [
            "signature": model.automaticSignature ?? NSNull()
        ]) as? [String: Any], var html = value["html"] as? String, let text = value["plainText"] as? String,
              let onlySignature = value["hasOnlyUntouchedSignature"] as? Bool else { throw EditorError.invalidExport }
        if !Self.usesNativeCID {
            let pattern = "mist-mail-cid://" + model.draft.id.uuidString.lowercased() + "/([^\\s\"'<>]+)"
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                if let range = Range(match.range, in: html), let cid = Range(match.range(at: 1), in: html) {
                    let value = MailBodyPreparation.normalizedCID(String(html[cid]))
                    html.replaceSubrange(range, with: "cid:" + MailComposeFormatting.escape(value))
                }
            }
        }
        return .init(html: html, plainText: text, hasOnlyUntouchedSignature: onlySignature)
    }
    func swapSignature(from previous: String?, to next: String?) {
        let pending = signatureUpdate
        let next = MailAccountConfig.normalizedSignature(next)
        signatureUpdate = Task { [weak self] in
            await pending?.value
            guard let self else { return }
            do {
                let swapped = try await call("return window.MistMailCompose.swapSignature(previous, next)", arguments: [
                    "previous": MailAccountConfig.normalizedSignature(previous) ?? "", "next": next ?? ""
                ])
                if swapped as? Bool == true { model.signatureSwapped(to: next) }
            } catch { model.report(error) }
        }
    }

    func insertInlineImage(_ data: Data) {
        Task { [self] in
            do {
                try await waitUntilReady()
                let cid = try model.addInlineImage(data)
                let url = Self.usesNativeCID ? "cid:" + cid : MailBodyPreparation.cidURL(messageID: model.draft.id, cid: cid)!.absoluteString
                try await call("window.MistMailCompose.insertInlineImage(url)", arguments: ["url": url])
            } catch { model.report(error) }
        }
    }
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    /// Files, or an image with no text, paste as attachments or an inline image.
    static func pastesAttachments(_ board: NSPasteboard) -> Bool {
        !fileURLs(board).isEmpty || (board.string(forType: .html) == nil && board.string(forType: .string) == nil && NSImage(pasteboard: board) != nil)
    }
    /// Never name this `paste(_:)`: WKWebView implements `paste:` itself (no subview does), and an
    /// override shadows it, so text and HTML would no longer paste.
    @objc func pasteAttachments(_ sender: Any?) {
        guard allowsBodyEditing else { return }
        let board = NSPasteboard.general, files = Self.fileURLs(board)
        if !files.isEmpty { model.addFiles(files); return }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { insertInlineImage(png) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every view in the window, so paste only while the editor has focus (not the Chat panel's composer).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
           (window?.firstResponder as? NSView)?.isDescendant(of: self) == true,
           Self.pastesAttachments(.general) { pasteAttachments(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.fileURLs(sender.draggingPasteboard).isEmpty ? super.prepareForDragOperation(sender) : true
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = Self.fileURLs(sender.draggingPasteboard)
        if files.isEmpty { return super.performDragOperation(sender) }
        model.addFiles(files); return true
    }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        func filter(_ menu: NSMenu) {
            for item in menu.items {
                let id = item.identifier?.rawValue ?? ""
                if ["Open", "Download", "Back", "Forward", "Reload", "Stop", "Inspect", "Share"].contains(where: { id.contains($0) }) { menu.removeItem(item) }
                else if let submenu = item.submenu { filter(submenu) }
            }
        }
        filter(menu)
        if Self.pastesAttachments(.general) {
            for item in menu.items where item.action == #selector(NSText.paste(_:)) { item.target = self; item.action = #selector(pasteAttachments(_:)) }
        }
    }
}

private final class MailComposeCIDHandler: NSObject, WKURLSchemeHandler {
    weak var model: MailComposeModel?
    let nativeCID: Bool
    init(model: MailComposeModel, nativeCID: Bool) { self.model = model; self.nativeCID = nativeCID }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let model, let url = task.request.url else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        if !nativeCID, url.host != model.draft.id.uuidString.lowercased() { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let cid = nativeCID ? String(url.absoluteString.dropFirst(4)) : String(url.path.dropFirst())
        guard let file = model.draft.attachments.first(where: { $0.contentID.map(MailBodyPreparation.normalizedCID) == MailBodyPreparation.normalizedCID(cid) })?.file, file.isFileURL else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        do {
            let data = try Data(contentsOf: file)
            task.didReceive(URLResponse(url: url, mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream", expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
