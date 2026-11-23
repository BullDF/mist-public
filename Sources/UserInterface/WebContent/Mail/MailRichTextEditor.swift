import AppKit
import WebKit

class MailRichTextEditor: WKWebView, WKNavigationDelegate, NSFontChanging, NSColorChanging {
    static let world = WKContentWorld.world(name: "MistMailCompose")
    var onState: (([String: Any]) -> Void)?
    var onShortcut: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private let bridge = MailRichTextScriptBridge()
    private var readiness: Result<Void, Error>?
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var initialLoad = true
    var onReady: (() -> Void)?
    var onChanged: (() -> Void)?
    var onError: ((Error) -> Void)?
    var formattingEnabled = true
    var allowsBodyEditing = true {
        didSet {
            guard oldValue != allowsBodyEditing else { return }
            Task { [self] in
                do { try await call("document.body.contentEditable = enabled ? 'true' : 'false'", arguments: ["enabled": allowsBodyEditing]) }
                catch { onError?(error) }
            }
        }
    }
    private var fontPanelReference: NSFont?

    init(configuration: WKWebViewConfiguration = WKWebViewConfiguration(), compose: Bool = false) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, contentWorld: Self.world, name: "compose")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.editingScript + (compose ? "(true)" : "(false)"), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        navigationDelegate = self; bridge.editor = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadDocument(_ document: String) {
        var html = document
        // Remote images, styles and fonts load, as in the reader; active content, forms and local files don't.
        let csp = "<meta data-mist-compose http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; img-src data: cid: mist-mail-cid: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:; frame-src 'none'; object-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'\">"
        if let head = html.range(of: "<head\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: csp, at: head.upperBound) }
        else if let body = html.range(of: "<body\\b", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: "<head>\(csp)</head>", at: body.lowerBound) }
        loadHTMLString(html, baseURL: nil)
    }
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
            } catch { completeReadiness(.failure(error)); onError?(error) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completeReadiness(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completeReadiness(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { completeReadiness(.failure(EditorError.scriptUnavailable)) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if initialLoad, action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { initialLoad = false; decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
    @discardableResult
    func call(_ function: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await waitUntilReady()
        return try await callAsyncJavaScript(function, arguments: arguments, in: nil, contentWorld: Self.world)
    }
    func exec(_ command: String, value: String? = nil, panelSelection: Bool = false) async throws {
        try await call("window.MistMailCompose.exec(command, value, panelSelection)", arguments: [
            "command": command, "value": value ?? NSNull(), "panelSelection": panelSelection
        ])
    }
    func focus(atStart: Bool = false) {
        Task { [self] in
            do { try await call("window.MistMailCompose.focus(atStart)", arguments: ["atStart": atStart]); window?.makeFirstResponder(self) }
            catch { onError?(error) }
        }
    }
    func runCommand(_ command: String, value: String? = nil, panelSelection: Bool = false) {
        guard formattingEnabled else { return }
        Task { [self] in
            do { try await exec(command, value: value, panelSelection: panelSelection) }
            catch { onError?(error) }
        }
    }

    func showFontPanel(family: String) async throws {
        try await capturePanelSelection(for: "fontName")
        guard window != nil, formattingEnabled else { return }
        let manager = NSFontManager.shared
        let reference = manager.font(withFamily: family, traits: [], weight: 5, size: 16) ?? .systemFont(ofSize: 16)
        fontPanelReference = reference
        manager.target = self
        manager.setSelectedFont(reference, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender, window != nil, manager.target === self, manager.fontPanel(false)?.isVisible == true,
              let reference = fontPanelReference else { return }
        let font = manager.convert(reference)
        guard let family = font.familyName, family != reference.familyName else { return }
        fontPanelReference = font
        runCommand("fontName", value: MailFormattingToolbar.fontStack(for: family), panelSelection: true)
    }

    // The toolbar's target/action applies color to the captured range. Suppress WebKit's responder action.
    @objc func changeColor(_ sender: NSColorPanel?) {}

    func capturePanelSelection(for command: String) async throws {
        try await call("window.MistMailCompose.capturePanelSelection(command)", arguments: ["command": command])
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, fontPanelReference != nil, NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    fileprivate func receive(_ value: [String: Any]) {
        switch value["kind"] as? String {
        case "changed": onChanged?()
        case "state": onState?(value)
        case "focus": onFocusChange?(value["focused"] as? Bool == true)
        case "shortcut":
            if let command = value["command"] as? String { handleShortcut(command) }
        default: break
        }
    }

    func handleShortcut(_ command: String) { onShortcut?(command) }

    func exportBody() async throws -> String? {
        let script = #"""
        const body = document.body;
        return body.innerText.replace(/[\s\u200B\uFEFF]/g, '') || body.querySelector('img') ? body.innerHTML : '';
        """#
        guard let html = try await call(script) as? String else { throw EditorError.invalidExport }
        return html.isEmpty ? nil : html
    }

    enum EditorError: Error { case scriptUnavailable, invalidExport }

    static let editingScript = #"""
    (compose => {
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
      const panelRanges = new Map();
      const saveSelection = () => {
        const selection = getSelection();
        if (selection.rangeCount && body.contains(selection.anchorNode)) savedRange = selection.getRangeAt(0).cloneRange();
      };
      const restoreSelection = (range = savedRange) => {
        body.focus();
        if (range && range.startContainer.isConnected) {
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
        }
      };
      const link = () => {
        const node = getSelection().anchorNode;
        return (node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement)?.closest('a') || null;
      };
      const state = () => {
        stateTimer = null;
        const value = {kind:'state', link:!!link(), href:link()?.getAttribute('href') || ''};
        for (const command of ['bold','italic','underline','strikeThrough','insertUnorderedList','insertOrderedList']) value[command] = document.queryCommandState(command);
        value.fontName = String(document.queryCommandValue('fontName'));
        value.fontSize = String(document.queryCommandValue('fontSize'));
        value.foreColor = String(document.queryCommandValue('foreColor'));
        post(value);
      };
      const changed = () => { saveSelection(); post({kind:'changed'}); state(); };
      document.addEventListener('selectionchange', () => { saveSelection(); if (!stateTimer) stateTimer = setTimeout(state, 80); });
      body.addEventListener('input', changed);
      if (!compose) {
        const focusChanged = () => post({kind:'focus', focused:document.hasFocus() && body.contains(document.activeElement)});
        body.addEventListener('focusin', focusChanged);
        body.addEventListener('focusout', () => post({kind:'focus', focused:false}));
        window.addEventListener('focus', focusChanged);
        window.addEventListener('blur', () => post({kind:'focus', focused:false}));
      }
      body.addEventListener('paste', event => {
        const types = Array.from(event.clipboardData?.types || []);
        if (types.includes('Files') && !types.includes('text/html') && !types.includes('text/plain')) {
          event.preventDefault();
          if (compose) post({kind:'shortcut',command:'paste'});
        }
      });
      if (!compose) body.addEventListener('drop', event => {
        if (event.dataTransfer?.files.length) event.preventDefault();
      });
      document.addEventListener('keydown', event => {
        if (!body.isContentEditable || !event.metaKey || event.altKey || event.ctrlKey) return;
        const key = event.key.toLowerCase(), commands = {b:'bold',i:'italic',u:'underline'};
        if (commands[key] || key === 'k' || (compose && key === 'enter')) {
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
      const signatureElement = (root = body) => Array.from(root.querySelectorAll('div.mist-signature')).find(node => !node.closest('blockquote'));
      const matchesSignature = (element, html) => {
        const expected = document.createElement('template'), actual = document.createElement('template');
        expected.innerHTML = html;
        actual.innerHTML = element.innerHTML;
        return actual.content.isEqualNode(expected.content);
      };
      const hasText = text => /[^\s\u200B\uFEFF]/.test(text);
      window.MistMailCompose = {
        saveSelection, restoreSelection,
        capturePanelSelection(command) {
          panelRanges.set(command, savedRange?.cloneRange() ?? null);
        },
        exec(command, value = null, panelSelection = false) {
          restoreSelection(panelSelection ? panelRanges.get(command) : savedRange);
          if (['fontName', 'fontSize', 'foreColor'].includes(command)) document.execCommand('styleWithCSS', false, true);
          if (command === 'createLink' && getSelection().isCollapsed) {
            const anchor = document.createElement('a'); anchor.href = value; anchor.textContent = value;
            const range = getSelection().rangeCount ? getSelection().getRangeAt(0) : document.createRange();
            if (!getSelection().rangeCount) { range.selectNodeContents(body); range.collapse(false); }
            range.insertNode(anchor); range.setStartAfter(anchor); range.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(range);
          } else if (command === 'unlink' && link()) {
            const anchor = link(); anchor.replaceWith(...anchor.childNodes);
          } else document.execCommand(command, false, value);
          changed();
          if (panelSelection) panelRanges.set(command, savedRange?.cloneRange() ?? null);
        },
        insertInlineImage(url) { restoreSelection(); document.execCommand('insertImage', false, url); changed(); },
        focus(atStart) {
          body.focus();
          if (atStart) { const range = document.createRange(); range.selectNodeContents(body); range.collapse(true); getSelection().removeAllRanges(); getSelection().addRange(range); }
          saveSelection(); state();
        },
        swapSignature(previous, next) {
          const element = signatureElement();
          if (!element || ((hasText(element.innerText) || element.querySelector('img')) && !matchesSignature(element, previous))) return false;
          element.innerHTML = next;
          post({kind:'changed'});
          return true;
        },
        export(expectedSignature = null) {
          const clone = document.documentElement.cloneNode(true);
          clone.querySelectorAll('[data-mist-compose]').forEach(node => node.remove());
          clone.querySelectorAll('[contenteditable]').forEach(node => node.removeAttribute('contenteditable'));
          const html = '<!doctype html>' + clone.outerHTML;
          const plainText = plain(body).replace(/\n{3,}/g,'\n\n').replace(/^\n+|\n+$/g,'');
          const signature = expectedSignature && signatureElement(clone);
          if (!signature || !matchesSignature(signature, expectedSignature)) return {html, plainText, hasOnlyUntouchedSignature:false};
          signature.remove();
          const remaining = clone.querySelector('body');
          remaining.querySelectorAll('script, style, template, noscript').forEach(node => node.remove());
          return {html, plainText, hasOnlyUntouchedSignature:!hasText(remaining.textContent) && !remaining.querySelector('img')};
        }
      };
      state();
    })
    """#
}

private final class MailRichTextScriptBridge: NSObject, WKScriptMessageHandler {
    weak var editor: MailRichTextEditor?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        editor?.receive(value)
    }
}
