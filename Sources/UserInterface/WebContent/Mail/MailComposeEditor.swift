import AppKit
import WebKit
import UniformTypeIdentifiers
import MistMailCore

final class MailComposeEditor: WKWebView, WKNavigationDelegate {
    static let world = WKContentWorld.world(name: "MistMailCompose")
    static var usesNativeCID: Bool { !WKWebView.handlesURLScheme("cid") }
    let model: MailComposeModel
    var onState: (([String: Any]) -> Void)?
    var onShortcut: ((String) -> Void)?
    private let cidHandler: MailComposeCIDHandler
    private let bridge = MailComposeScriptBridge()
    private var readiness: Result<Void, Error>?
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var initialLoad = true
    var onReady: (() -> Void)?
    var isUserInteractionEnabledForCompose = true {
        didSet {
            guard oldValue != isUserInteractionEnabledForCompose else { return }
            Task { [self] in
                do { try await call("document.body.contentEditable = enabled ? 'true' : 'false'", arguments: ["enabled": isUserInteractionEnabledForCompose]) }
                catch { model.report(error) }
            }
        }
    }

    init(model: MailComposeModel) {
        self.model = model
        cidHandler = MailComposeCIDHandler(model: model, nativeCID: Self.usesNativeCID)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: Self.usesNativeCID ? "cid" : "mist-mail-cid")
        configuration.userContentController.add(bridge, contentWorld: Self.world, name: "compose")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.editingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        navigationDelegate = self; bridge.editor = self
        setAccessibilityLabel(MailStrings.messageBody)
        registerForDraggedTypes([.fileURL])
        model.exportEditor = { [weak self] in
            guard let self else { throw EditorError.invalidExport }
            return try await exportDocument()
        }
        var html = MailComposeFormatting.document(html: model.draft.html, plainText: model.draft.plainText)
        if !Self.usesNativeCID { html = MailBodyPreparation.rewriteCIDs(html, messageID: model.draft.id) }
        // Remote images, styles and fonts load, as in the reader; active content, forms and local files don't.
        let csp = "<meta data-mist-compose http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; img-src data: cid: mist-mail-cid: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:; frame-src 'none'; object-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'\">"
        if let head = html.range(of: "<head\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: csp, at: head.upperBound) }
        else if let body = html.range(of: "<body\\b", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: "<head>\(csp)</head>", at: body.lowerBound) }
        loadHTMLString(html, baseURL: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Break the model/editor export lifetime after the final save, never while it is exporting.
    func detach() { model.exportEditor = nil }
    func waitUntilReady() async throws {
        if let readiness { return try readiness.get() }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    private func completeReadiness(_ result: Result<Void, Error>) {
        guard readiness == nil else { return }
        readiness = result
        let pending = waiting; waiting = []
        pending.forEach { $0.resume(with: result) }
        if case .success = result { onReady?() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [self] in
            do {
                let ready = try await callAsyncJavaScript("return typeof window.MistMailCompose === 'object'", arguments: [:], in: nil, contentWorld: Self.world)
                guard ready as? Bool == true else { throw EditorError.scriptUnavailable }
                completeReadiness(.success(()))
            } catch { completeReadiness(.failure(error)); model.report(error) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completeReadiness(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completeReadiness(.failure(error)) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if initialLoad, action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { initialLoad = false; decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    @discardableResult
    func call(_ function: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await waitUntilReady()
        return try await callAsyncJavaScript(function, arguments: arguments, in: nil, contentWorld: Self.world)
    }
    func exportDocument() async throws -> MailComposeExport {
        guard let value = try await call("return window.MistMailCompose.export()") as? [String: String], var html = value["html"], let text = value["plainText"] else { throw EditorError.invalidExport }
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
        return .init(html: html, plainText: text)
    }
    func exec(_ command: String, value: String? = nil) async throws {
        try await call("window.MistMailCompose.exec(command, value)", arguments: ["command": command, "value": value ?? NSNull()])
    }
    func focus(atStart: Bool = false) {
        Task { [self] in
            do { try await call("window.MistMailCompose.focus(atStart)", arguments: ["atStart": atStart]); window?.makeFirstResponder(self) }
            catch { model.report(error) }
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
    fileprivate func receive(_ value: [String: Any]) {
        switch value["kind"] as? String {
        case "changed": model.editorChanged()
        case "state": onState?(value)
        case "shortcut":
            if let command = value["command"] as? String {
                if command == "paste" { pasteAttachments(nil) } else { onShortcut?(command) }
            }
        default: break
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
        guard isUserInteractionEnabledForCompose else { return }
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
    enum EditorError: Error { case scriptUnavailable, invalidExport }

    static let editingScript = #"""
    (() => {
      'use strict';
      const body = document.body;
      body.contentEditable = 'true';
      body.spellcheck = true;
      const style = document.createElement('style');
      style.dataset.mistCompose = '';
      // The margin lives on html: a quoted original's `body{margin:0!important}` comes later and would put
      // the text under the overlay scroll bar.
      style.textContent = 'html{background:white!important;color:black!important;color-scheme:light;padding:20px!important}body{min-height:calc(100vh - 40px);margin:0!important;outline:none;overflow-wrap:anywhere;color:black!important;background:white!important}img{max-width:100%;height:auto}blockquote{border-left:2px solid #ccc;margin-left:0;padding-left:12px}';
      document.head.appendChild(style);
      const post = value => window.webkit.messageHandlers.compose.postMessage(value);
      let savedRange = null, stateTimer = null;
      const saveSelection = () => {
        const selection = getSelection();
        if (selection.rangeCount && body.contains(selection.anchorNode)) savedRange = selection.getRangeAt(0).cloneRange();
      };
      const restoreSelection = () => {
        body.focus();
        if (savedRange && savedRange.startContainer.isConnected) { const selection = getSelection(); selection.removeAllRanges(); selection.addRange(savedRange); }
      };
      const link = () => {
        const node = getSelection().anchorNode;
        return (node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement)?.closest('a') || null;
      };
      const state = () => {
        stateTimer = null;
        const value = {kind:'state', link:!!link(), href:link()?.getAttribute('href') || ''};
        for (const command of ['bold','italic','underline','strikeThrough','insertUnorderedList','insertOrderedList']) value[command] = document.queryCommandState(command);
        value.fontSize = String(document.queryCommandValue('fontSize'));
        value.foreColor = String(document.queryCommandValue('foreColor'));
        post(value);
      };
      const changed = () => { saveSelection(); post({kind:'changed'}); state(); };
      document.addEventListener('selectionchange', () => { saveSelection(); if (!stateTimer) stateTimer = setTimeout(state, 80); });
      body.addEventListener('input', changed);
      body.addEventListener('paste', event => {
        const types = Array.from(event.clipboardData?.types || []);
        if (types.includes('Files') && !types.includes('text/html') && !types.includes('text/plain')) {
          event.preventDefault(); post({kind:'shortcut',command:'paste'});
        }
      });
      document.addEventListener('keydown', event => {
        if (!event.metaKey || event.altKey || event.ctrlKey) return;
        const key = event.key.toLowerCase(), commands = {b:'bold',i:'italic',u:'underline'};
        if (commands[key] || key === 'k' || key === 'enter') {
          event.preventDefault(); event.stopPropagation();
          if (commands[key]) window.MistMailCompose.exec(commands[key]);
          else post({kind:'shortcut',command:key === 'k' ? 'link' : 'send'});
        }
      }, true);
      const plain = node => {
        if (node.nodeType === Node.TEXT_NODE) return node.nodeValue;
        if (node.nodeType !== Node.ELEMENT_NODE) return '';
        const tag = node.tagName;
        if (['SCRIPT','STYLE','HEAD','NOSCRIPT','TEMPLATE'].includes(tag) || node.hasAttribute('data-mist-compose')) return '';
        if (tag === 'BR') return '\n';
        let value = Array.from(node.childNodes).map(plain).join('');
        if (tag === 'BLOCKQUOTE') return value.replace(/\n{3,}/g,'\n\n').replace(/^\n+|\n+$/g,'').split('\n').map(line => '> ' + line).join('\n') + '\n';
        if (tag === 'LI') {
          const parent = node.parentElement;
          const prefix = parent.tagName === 'OL' ? String(Array.from(parent.children).indexOf(node) + (Number(parent.getAttribute('start')) || 1)) + '. ' : '- ';
          return prefix + value.replace(/\n$/,'') + '\n';
        }
        // Paragraphs and headings stand apart by a blank line, as their margins do; DIVs are the editor's lines.
        if (['P','H1','H2','H3','H4','H5','H6'].includes(tag)) return '\n' + value.replace(/\n+$/,'') + '\n\n';
        if (['DIV','UL','OL','PRE','TR'].includes(tag)) return value + (value.endsWith('\n') ? '' : '\n');
        return value;
      };
      window.MistMailCompose = {
        saveSelection, restoreSelection,
        exec(command, value = null) {
          restoreSelection();
          if (command === 'fontSize' || command === 'foreColor') document.execCommand('styleWithCSS', false, true);
          if (command === 'createLink' && getSelection().isCollapsed) {
            const anchor = document.createElement('a'); anchor.href = value; anchor.textContent = value;
            const range = getSelection().rangeCount ? getSelection().getRangeAt(0) : document.createRange();
            if (!getSelection().rangeCount) { range.selectNodeContents(body); range.collapse(false); }
            range.insertNode(anchor); range.setStartAfter(anchor); range.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(range);
          } else if (command === 'unlink' && link()) {
            const anchor = link(); anchor.replaceWith(...anchor.childNodes);
          } else document.execCommand(command, false, value);
          changed();
        },
        insertInlineImage(url) { restoreSelection(); document.execCommand('insertImage', false, url); changed(); },
        focus(atStart) {
          body.focus();
          if (atStart) { const range = document.createRange(); range.selectNodeContents(body); range.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(range); }
          saveSelection(); state();
        },
        export() {
          const clone = document.documentElement.cloneNode(true);
          clone.querySelectorAll('[data-mist-compose]').forEach(node => node.remove());
          clone.querySelectorAll('[contenteditable]').forEach(node => node.removeAttribute('contenteditable'));
          return {html:'<!doctype html>' + clone.outerHTML, plainText:plain(body).replace(/\n{3,}/g,'\n\n').replace(/^\n+|\n+$/g,'')};
        }
      };
      state();
    })();
    """#
}

private final class MailComposeScriptBridge: NSObject, WKScriptMessageHandler {
    weak var editor: MailComposeEditor?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        editor?.receive(value)
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
