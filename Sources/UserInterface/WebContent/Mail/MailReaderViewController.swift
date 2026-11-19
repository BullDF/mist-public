import AppKit
import WebKit
import Quartz
import UniformTypeIdentifiers
import MistMailCore

final class MailReaderViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: MailPageModel
    var openLink: ((URL) -> Void)?
    private let scheme = MailCIDSchemeHandler()
    private(set) var webView: MailBodyWebView!
    /// The header's text edge. The body's web view is inset to it on the left, so a message's own CSS can't
    /// put its content against the divider. On the right the web view reaches the pane's edge and the page
    /// pads its text to the same edge, so the overlay scroll bar draws in that margin instead of over the text.
    /// A framed page keeps both insets and pads both sides.
    private static let textEdge: CGFloat = 24
    private let header = NSStackView()
    private let attachments = MailAttachmentCardsView(insets: NSEdgeInsets(top: 0, left: MailReaderViewController.textEdge, bottom: 14, right: MailReaderViewController.textEdge))
    private let placeholder = MistPlaceholderView()
    private let card = MistCardView(style: .content)
    private let toolbar = NSStackView.mistToolbar([])
    private let findBar = NativeFindBar()
    private var detail: MailMessageDetail?
    private var messageID: UUID?
    private var loadTask: Task<Void, Never>?
    private var initialLoad = false
    private var loadToken = UUID()
    private var previewFile: URL?
    private var bodyInsets: [NSLayoutConstraint] = []
    private(set) var zoom: CGFloat = 1 { didSet { webView?.pageZoom = zoom; applyGutter() } }
    /// Page zoom scales CSS pixels, so the page's margin is set in them to stay `textEdge` points wide at every zoom.
    private var gutter: CGFloat { Self.textEdge / zoom }

    init(model: MailPageModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loadTask?.cancel() }
    override func loadView() {
        view = AgentChatBackgroundView()
        view.themeChanged = { [weak self] in self?.renderBody() }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent(); configuration.setURLSchemeHandler(scheme, forURLScheme: "mist-mail-cid")
        webView = MailBodyWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self; webView.pageZoom = zoom
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 22, left: Self.textEdge, bottom: 14, right: Self.textEdge)
        let body = NSView(); body.addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
        bodyInsets = [webView.topAnchor.constraint(equalTo: body.topAnchor), webView.bottomAnchor.constraint(equalTo: body.bottomAnchor), webView.trailingAnchor.constraint(equalTo: body.trailingAnchor)]
        NSLayoutConstraint.activate(bodyInsets + [webView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Self.textEdge)])
        let stack = NSStackView(views: [header, attachments, body]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        view.addSubview(toolbar); toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), attachments.widthAnchor.constraint(equalTo: stack.widthAnchor), body.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        placeholder.action.onClick = { [weak self] in self?.loadMessage() }
        placeholder.show(message: MailStrings.noSelection)
        view.addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor), placeholder.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)])
        findBar.install(in: view, top: 8, trailing: 12)
        findBar.setResult("")
        findBar.onQueryChange = { [weak self] _ in self?.find(forward: true) }; findBar.onStep = { [weak self] in self?.find(forward: $0) }; findBar.onClose = { [weak self] in self?.closeFind() }
        attachments.isHidden = true; header.isHidden = true; webView.isHidden = true; card.isHidden = true; toolbar.isHidden = true
    }
    func show(_ message: MailMessageSummary?) {
        _ = view
        if messageID == message?.id {
            if let message, detail?.summary != message { detail?.summary = message; updateHeader() }
            return
        }
        messageID = message?.id; loadToken = UUID(); loadTask?.cancel(); detail = nil
        scheme.messageID = message?.id; scheme.files = [:]; webView.stopLoading(); webView.isHidden = true
        closeFind(); header.isHidden = true; attachments.isHidden = true
        placeholder.isHidden = false; placeholder.show(message: MailStrings.noSelection); card.isHidden = true; toolbar.isHidden = true
        guard message != nil else { return }
        // The optimistic flag action happens as soon as a message is shown, before downloading its body.
        if let message, !message.flags.contains(MailFlags.seen) { model.perform(.seen(true), message: message) }
        loadMessage()
    }
    private func loadMessage() {
        guard let id = messageID else { return }
        loadTask?.cancel(); placeholder.isHidden = false; placeholder.show(message: "", loading: true)
        let token = loadToken
        loadTask = Task { [weak self, source = model.source] in
            do {
                let value = try await source.detail(id)
                guard let self, !Task.isCancelled, loadToken == token else { return }
                detail = value; updateHeader(); renderBody()
            } catch {
                guard let self, !Task.isCancelled, loadToken == token else { return }
                placeholder.show(message: MailStrings.loadFailed, actionTitle: MailStrings.retry)
            }
        }
    }
    private func updateHeader() {
        guard let detail else { return }
        header.arrangedSubviews.forEach { header.removeArrangedSubview($0); $0.removeFromSuperview() }
        func label(_ text: String, style: MistTextStyle = .secondary) -> NSTextField {
            NSTextField.mistWrappingLabel(text, style: style, selectable: true)
        }
        let subject = label(MailPresentation.subject(detail.summary.subject), style: .cardTitle)
        header.addArrangedSubview(subject); header.setCustomSpacing(10, after: subject)
        header.addArrangedSubview(label(detail.headers.from.map { address in address.name.map { "\($0) <\(address.email)>" } ?? address.email }.joined(separator: ", "), style: .headline))
        header.addArrangedSubview(label(String(format: MailStrings.to, MailPresentation.addresses(detail.headers.to))))
        if !detail.headers.cc.isEmpty { header.addArrangedSubview(label(String(format: MailStrings.cc, MailPresentation.addresses(detail.headers.cc)))) }
        let account = model.state.accounts.first { $0.id == detail.summary.accountID }?.config.displayName ?? ""
        header.addArrangedSubview(label(DateFormatter.localizedString(from: detail.headers.date, dateStyle: .full, timeStyle: .short) + " · " + account))
        toolbar.arrangedSubviews.forEach { toolbar.removeArrangedSubview($0); $0.removeFromSuperview() }
        let archive = MistButton(symbol: "archivebox", title: MailStrings.archive, size: .regular)
        archive.isHidden = true; archive.onClick = { [weak self] in self?.model.perform(.archive) }; toolbar.addArrangedSubview(archive)
        Task { [self, weak archive] in
            let allowed = await self.model.source.canArchive(detail.summary.id)
            if self.messageID == detail.summary.id { archive?.isHidden = !allowed }
        }
        for (symbol, action) in [("trash", MailPageAction.delete), ("flag", .flagged(!detail.summary.flags.contains(MailFlags.flagged))), ("envelope.badge", .seen(false))] {
            let button = MistButton(symbol: symbol, title: action.title, size: .regular)
            button.onClick = { [weak self] in self?.model.perform(action) }; toolbar.addArrangedSubview(button)
        }
        let move = MistPopUpButton(pullsDown: true); move.menu = MailMessageMenus.moveMenu(for: detail.summary, model: model)
        move.menu?.insertItem(withTitle: MailStrings.move, action: nil, keyEquivalent: "", at: 0); toolbar.addArrangedSubview(move)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); toolbar.addArrangedSubview(spacer)
        for (symbol, title, kind) in [
            ("arrowshape.turn.up.left.2", MailStrings.replyAll, MailReplyKind.replyAll),
            ("arrowshape.turn.up.right", MailStrings.forward, .forward),
            ("arrowshape.turn.up.left", MailStrings.reply, .reply)] {
            let button = kind == .reply ? MistButton(title: title, role: .primary, size: .regular) : MistButton(symbol: symbol, title: title, size: .regular)
            button.onClick = { [model] in
                Task {
                    if kind == .forward { await model.forward(detail.summary) }
                    else { await model.reply(to: detail.summary, all: kind == .replyAll) }
                }
            }
            toolbar.addArrangedSubview(button)
        }
        header.isHidden = false
        attachments.setCards(detail.attachments.map { attachment in
            let filename = attachment.part.filename ?? MailStrings.attachment
            let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension).flatMap { $0.isDynamic ? nil : $0 } ?? UTType(mimeType: attachment.part.mimeType)
            let card = MistAttachmentFileCard(icon: NSWorkspace.shared.icon(for: type ?? .data), name: filename, kind: type?.localizedDescription,
                size: ByteCountFormatter.string(fromByteCount: Int64(attachment.part.size), countStyle: .file),
                onOpen: { [weak self] in self?.openAttachment(attachment, mode: .preview) }, onRemove: nil)
            card.contextMenu = { [weak self] in
                let menu = NSMenu(); menu.addItem(MailMenuItem(MailStrings.openAttachment) { self?.openAttachment(attachment, mode: .open) }); menu.addItem(MailMenuItem(MailStrings.saveAttachment) { self?.openAttachment(attachment, mode: .save) }); return menu
            }
            return card
        })
        attachments.isHidden = detail.attachments.isEmpty
    }
    private func renderBody() {
        guard let detail else { return }
        scheme.files = Dictionary(detail.inlineFiles.map { (MailBodyPreparation.normalizedCID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        let textColor = view.themeStateProvider.currentTheme.color(for: .textPrimary, appearance: view.currentAppearance).mailCSS
        let background = ThemedColor.mistCardFill.resolve(theme: view.themeStateProvider.currentTheme, appearance: view.currentAppearance).mailCSS
        // In dark mode HTML keeps its white background, shown as a page with room above and below.
        let framed = detail.html != nil && view.currentAppearance == .dark
        let prepared = MailBodyPreparation.prepare(html: detail.html, text: detail.plainText, messageID: detail.summary.id, textColor: textColor, background: background, framed: framed, gutter: gutter)
        bodyInsets[0].constant = framed ? 12 : 0; bodyInsets[1].constant = framed ? -12 : 0; bodyInsets[2].constant = framed ? -Self.textEdge : 0
        webView.stopLoading(); initialLoad = true; webView.loadHTMLString(prepared.html, baseURL: nil); webView.isHidden = false
        placeholder.show(message: ""); placeholder.isHidden = true; card.isHidden = false; toolbar.isHidden = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if initialLoad, navigationAction.navigationType == .other, navigationAction.request.url?.absoluteString == "about:blank" { initialLoad = false; decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url { activateLink(url) }
        decisionHandler(.cancel)
    }
    /// A zoom change while the body loaded reached the previous page.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyGutter() }
    /// Content JavaScript is off; Mist's own script still runs, in a client world sharing the page's DOM.
    private func applyGutter() {
        webView?.evaluateJavaScript("document.documentElement.style.setProperty('\(MailBodyPreparation.gutterProperty)', '\(MailBodyPreparation.cssPixels(gutter))')", in: nil, in: .defaultClient)
    }
    /// A `target=_blank` click or the context menu's Open Link; the menu's request comes as `.other`.
    /// With JavaScript off, a page can't open a window by itself.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { activateLink(url) }
        return nil
    }
    private func activateLink(_ url: URL) {
        if let prefill = MailComposeFormatting.mailto(url, accountID: detail?.summary.accountID) {
            Task { [model] in await model.newMessage(prefill: prefill) }
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { openLink?(url) }
    }
    func performPageCommand(_ command: CommandWrapper) {
        switch command {
        case .IDC_ZOOM_PLUS: zoom = MarkdownReaderZoom.step(zoom, up: true)
        case .IDC_ZOOM_MINUS: zoom = MarkdownReaderZoom.step(zoom, up: false)
        case .IDC_ZOOM_NORMAL: zoom = 1
        case .IDC_FIND: findBar.open(); find(forward: true)
        case .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS: findBar.open(); find(forward: command == .IDC_FIND_NEXT)
        default: break
        }
    }
    private func find(forward: Bool) {
        let query = findBar.query, token = loadToken
        guard !query.isEmpty else { findBar.setResult(""); return }
        let config = WKFindConfiguration(); config.backwards = !forward; config.wraps = true; config.caseSensitive = false
        webView.find(query, configuration: config) { [weak self] result in
            guard let self, loadToken == token, findBar.query == query else { return }
            findBar.setResult(result.matchFound ? MailStrings.found : MailStrings.notFound)
        }
    }
    func closeFind() {
        let wasOpen = findBar.isOpen
        findBar.hide()
        // WebKit ignores an empty find string, and clearing the selection leaves the yellow match:
        // only a search that matches nothing clears it.
        if wasOpen { webView?.find("\u{1}" + UUID().uuidString, configuration: WKFindConfiguration()) { _ in } }
    }
    var isFindOpen: Bool { findBar.isOpen }
    override func cancelOperation(_ sender: Any?) { if findBar.isOpen { closeFind() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) } }
    private enum AttachmentMode { case preview, open, save }
    private func openAttachment(_ attachment: MailAttachment, mode: AttachmentMode) {
        Task { [weak self, source = model.source] in
            do {
                let file = try await source.attachmentFile(attachment.id)
                guard let self else { return }
                switch mode {
                case .open: NSWorkspace.shared.open(file)
                case .preview:
                    previewFile = file
                    view.window?.makeFirstResponder(webView)
                    if let panel = QLPreviewPanel.shared() { panel.updateController(); panel.reloadData(); panel.makeKeyAndOrderFront(nil) }
                case .save:
                    let panel = NSSavePanel(); panel.nameFieldStringValue = attachment.part.filename ?? MailStrings.attachment
                    guard let window = view.window else { return }
                    panel.beginSheetModal(for: window) { response in
                        guard response == .OK, let destination = panel.url else { return }
                        do {
                            try Data(contentsOf: file, options: .mappedIfSafe).write(to: destination, options: .atomic)
                        } catch { self.model.showError(MailStrings.attachmentFailed) }
                    }
                }
            } catch { self?.model.showError(MailStrings.attachmentFailed) }
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewFile == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewFile as NSURL? }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewFile != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

private extension NSColor {
    var mailCSS: String {
        let color = usingColorSpace(.deviceRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
