import AppKit
import Combine
import UniformTypeIdentifiers
import MistMailCore

final class MailComposeViewController: NSViewController, NSTokenFieldDelegate, NSTextFieldDelegate {
    let model: MailComposeModel
    let accounts: [MailAccount]
    private(set) var editor: MailComposeEditor!
    private let from = MistPopUpButton(), to = MailRecipientTokenField(), cc = MailRecipientTokenField(), bcc = MailRecipientTokenField(), subject = NSTextField()
    private let ccButton = MistButton(title: MailStrings.ccBcc, size: .regular)
    private var ccRow: NSView!, bccRow: NSView!
    private let sendButton = MistButton(title: MailStrings.send, role: .primary, size: .regular)
    private let spinner = NSProgressIndicator()
    private let attachmentCards = MailAttachmentCardsView(insets: NSEdgeInsets(top: 0, left: 20, bottom: 8, right: 20))
    private var controls: [NSControl] = []
    private var formatting: [String: NSButton] = [:]
    private let size = MistPopUpButton(), color = MistPopUpButton()
    private var selectionState: [String: Any] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var bodyInsets: [NSLayoutConstraint] = []
    private var attachmentSnapshot: [MailDraftAttachment] = []
    private var showingCopies = false, applyingFields = false
    private var focusedInitially = false
    /// The kit's list under the recipient field being typed in, replacing AppKit's completion list (accent-colored).
    private let suggestionList = MailRecipientSuggestionList()
    private weak var suggestingField: NSTokenField?

    init(model: MailComposeModel, accounts: [MailAccount]) {
        self.model = model; self.accounts = accounts
        super.init(nibName: nil, bundle: nil)
        model.commitFieldEdits = { [weak self] in self?.commitPendingFields() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = MailComposeDropView(); root.setFrameSize(NSSize(width: 528, height: 700))
        root.onFiles = { [weak model] in model?.addFiles($0) }; view = root
        root.themeChanged = { [weak self] in self?.updateInsets() }
        editor = MailComposeEditor(model: model)
        editor.onState = { [weak self] in self?.updateSelection($0) }
        editor.onShortcut = { [weak self] command in if command == "send" { self?.send() } else { self?.showLinkSheet() } }
        editor.onReady = { [weak self] in self?.focusInitial() }
        let attach = MistButton(symbol: "paperclip", title: MailStrings.attachFiles, size: .regular); attach.onClick = { [weak self] in self?.attachFiles() }
        let discard = MistButton(symbol: "trash", title: MailStrings.discardDraft, size: .regular); discard.onClick = { [weak self] in self?.discard() }
        let close = MistButton(symbol: "xmark", title: MailStrings.closeCompose, size: .regular); close.onClick = { [weak self] in self?.close() }
        sendButton.onClick = { [weak self] in self?.send() }; sendButton.keyEquivalent = "\r"; sendButton.keyEquivalentModifierMask = [.command]
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView.mistToolbar([close, attach, discard, spinner, spacer, sendButton])
        controls = [sendButton, attach, discard, close, from, to, cc, bcc, subject]
        let fields = NSStackView(); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 6
        fields.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 8, right: 20)
        func row(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField.mistLabel(title, style: .secondary)
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let stack = NSStackView(views: [label, control]); stack.spacing = 8
            fields.addArrangedSubview(stack); stack.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -40).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal); control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return stack
        }
        accounts.forEach { from.addItem(withTitle: MailComposeFormatting.display(.init($0.config.email, name: $0.config.senderName))) }
        from.target = self; from.action = #selector(changeFrom)
        let fromRow = row(MailStrings.fromField, from); fromRow.isHidden = accounts.count < 2
        for field in [to, cc, bcc] {
            // AppKit's rounded token draws as a wide flat box; the squared one hugs its text (padded in its display string).
            field.delegate = self; field.applyMistStyle(.body); field.tokenStyle = .squared
            field.tokenizingCharacterSet = CharacterSet(charactersIn: ",;\n\r")
        }
        to.setAccessibilityLabel(MailStrings.toField); cc.setAccessibilityLabel(MailStrings.ccField); bcc.setAccessibilityLabel(MailStrings.bccField)
        let recipientRow = NSStackView(views: [MistFieldWellView(to), ccButton]); recipientRow.spacing = 6
        ccButton.setContentHuggingPriority(.required, for: .horizontal)
        ccButton.onClick = { [weak self] in self?.showingCopies = true; self?.updateCopyVisibility(); self?.view.window?.makeFirstResponder(self?.cc) }
        controls.append(ccButton)
        _ = row(MailStrings.toField, recipientRow)
        ccRow = row(MailStrings.ccField, MistFieldWellView(cc)); bccRow = row(MailStrings.bccField, MistFieldWellView(bcc))
        subject.delegate = self; subject.applyMistStyle(.body); subject.setAccessibilityLabel(MailStrings.subjectField)
        _ = row(MailStrings.subjectField, MistFieldWellView(subject))
        let toolbar = makeFormattingToolbar()
        let body = NSView(); body.addSubview(editor); editor.translatesAutoresizingMaskIntoConstraints = false
        bodyInsets = [editor.leadingAnchor.constraint(equalTo: body.leadingAnchor), editor.trailingAnchor.constraint(equalTo: body.trailingAnchor), editor.topAnchor.constraint(equalTo: body.topAnchor), editor.bottomAnchor.constraint(equalTo: body.bottomAnchor)]
        NSLayoutConstraint.activate(bodyInsets)
        // Attachments sit under the fields, as in the reader under its header.
        let stack = NSStackView(views: [fields, attachmentCards, toolbar, body]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        let card = MistCardView(style: .content)
        view.addSubview(actions); actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card); card.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), actions.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 12), card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor), stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor)])
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        suggestionList.onChoose = { [weak self] in self?.acceptSuggestion($0) }
        view.addSubview(suggestionList)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.render() }.store(in: &subscriptions)
        render(); updateInsets()
    }
    override func viewDidAppear() { super.viewDidAppear(); focusInitial() }
    override func viewDidLayout() { super.viewDidLayout(); positionSuggestions() }
    func focusInitial() {
        guard !focusedInitially, view.window != nil else { return }
        focusedInitially = true
        if model.initialFocus == .recipients { view.window?.makeFirstResponder(to) }
        else { editor.focus(atStart: true) }
    }
    private func render() {
        applyingFields = true; defer { applyingFields = false }
        if let index = accounts.firstIndex(where: { $0.id == model.draft.accountID }) { from.selectItem(at: index) }
        for (field, addresses) in [(to, model.draft.to), (cc, model.draft.cc), (bcc, model.draft.bcc)] {
            if field.currentEditor() == nil, fieldAddresses(field) != addresses { field.objectValue = addresses.map(MailAddressToken.init) }
        }
        if subject.currentEditor() == nil { subject.stringValue = model.draft.subject }
        controls.forEach { $0.isEnabled = !model.isSending }; editor.isUserInteractionEnabledForCompose = !model.isSending
        spinner.isHidden = !model.isSending; if model.isSending { spinner.startAnimation(nil); hideSuggestions() } else { spinner.stopAnimation(nil) }
        updateCopyVisibility()
        let attachments = model.draft.attachments.filter { $0.contentID == nil }
        attachmentCards.isHidden = attachments.isEmpty
        if attachmentSnapshot != attachments {
            attachmentSnapshot = attachments
            attachmentCards.setCards(attachments.map { attachment in
                let size = (try? attachment.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let card = MistAttachmentFileCard(icon: NSWorkspace.shared.icon(forFile: attachment.file.path), name: attachment.filename,
                    kind: UTType(filenameExtension: URL(fileURLWithPath: attachment.filename).pathExtension)?.localizedDescription,
                    size: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                    onOpen: { NSWorkspace.shared.open(attachment.file) }, onRemove: { [weak model] in model?.removeAttachment(attachment.id) }, removeLabel: MailStrings.remove)
                card.contextMenu = { [weak self] in
                    let menu = NSMenu()
                    menu.addItem(MailMenuItem(MailStrings.openAttachment) { NSWorkspace.shared.open(attachment.file) })
                    menu.addItem(MailMenuItem(MailStrings.remove) { self?.model.removeAttachment(attachment.id) })
                    return menu
                }
                return card
            })
        }
        // Sending starts and ends without changing the attachments, so the cards' state follows it here.
        attachmentCards.cards.forEach { $0.isEnabled = !model.isSending }
    }
    private func updateCopyVisibility() {
        let visible = showingCopies || !model.draft.cc.isEmpty || !model.draft.bcc.isEmpty
        ccRow.isHidden = !visible; bccRow.isHidden = !visible; ccButton.isHidden = visible
        let order: [NSView] = (accounts.count > 1 ? [from] : []) + [to] + (visible ? [cc, bcc] : []) + [subject, editor]
        for pair in zip(order, order.dropFirst() + [order[0]]) { pair.0.nextKeyView = pair.1 }
    }
    private func updateInsets() {
        let inset: CGFloat = view.currentAppearance == .dark ? 12 : 0
        for (index, constraint) in bodyInsets.enumerated() { constraint.constant = index == 1 || index == 3 ? -inset : inset }
    }
    @objc private func changeFrom() {
        guard accounts.indices.contains(from.indexOfSelectedItem) else { return }
        model.update { $0.accountID = accounts[from.indexOfSelectedItem].id }
    }
    private func fieldAddresses(_ field: NSTokenField) -> [MailAddress] {
        precondition(field.currentEditor() == nil)
        return endedFieldAddresses(field)
    }
    private func endedFieldAddresses(_ field: NSTokenField) -> [MailAddress] {
        let objects = field.objectValue as? [Any] ?? []
        return objects.flatMap { value -> [MailAddress] in
            if let token = value as? MailAddressToken { return [token.address] }
            return MailComposeFormatting.addresses(value as? String ?? "")
        }
    }
    private func publishFields(ending: NSTokenField? = nil) {
        guard !applyingFields else { return }
        model.update { draft in
            if ending === to { draft.to = endedFieldAddresses(to) } else if to.currentEditor() == nil { draft.to = fieldAddresses(to) }
            if ending === cc { draft.cc = endedFieldAddresses(cc) } else if cc.currentEditor() == nil { draft.cc = fieldAddresses(cc) }
            if ending === bcc { draft.bcc = endedFieldAddresses(bcc) } else if bcc.currentEditor() == nil { draft.bcc = fieldAddresses(bcc) }
            draft.subject = subject.currentEditor()?.string ?? subject.stringValue
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTokenField { updateSuggestions(field); return }
        publishFields()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTokenField === suggestingField { hideSuggestions() }
        publishFields(ending: obj.object as? NSTokenField)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === suggestingField, !suggestionList.isHidden else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): suggestionList.move(1)
        case #selector(NSResponder.moveUp(_:)): suggestionList.move(-1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // Nothing is selected until an arrow key picks a row, so Return keeps what was typed.
            guard let address = suggestionList.selectedAddress else { hideSuggestions(); return false }
            acceptSuggestion(address)
        case #selector(NSResponder.cancelOperation(_:)): hideSuggestions()
        default: return false
        }
        return true
    }
    /// Recipients matching what's typed in a field, minus the ones already in that list.
    func recipientSuggestions(for field: NSTokenField, matching query: String) -> [MailAddress] {
        let addresses = field === to ? model.draft.to : field === cc ? model.draft.cc : model.draft.bcc
        return MailComposeFormatting.suggestions(model.suggestions, matching: query, excluding: addresses)
    }
    /// The text between the tokens around the caret: the recipient being typed.
    private static func typedRange(in editor: NSTextView) -> NSRange? {
        let text = editor.string as NSString, selection = editor.selectedRange()
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let attachment = String(Character(UnicodeScalar(NSTextAttachment.character)!))
        let before = text.range(of: attachment, options: .backwards, range: NSRange(location: 0, length: selection.location))
        let after = text.range(of: attachment, range: NSRange(location: selection.location, length: text.length - selection.location))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before), end = after.location == NSNotFound ? text.length : after.location
        return NSRange(location: start, length: end - start)
    }
    private func updateSuggestions(_ field: NSTokenField) {
        guard let editor = field.currentEditor() as? NSTextView, let range = Self.typedRange(in: editor) else { return hideSuggestions() }
        let matches = recipientSuggestions(for: field, matching: (editor.string as NSString).substring(with: range))
        guard !matches.isEmpty else { return hideSuggestions() }
        suggestingField = field
        suggestionList.update(matches)
        positionSuggestions()
    }
    private func hideSuggestions() { suggestingField = nil; suggestionList.update([]) }
    /// Under the field's well, its rows' text on the field's text edge, and as far past the well's right edge as left.
    private func positionSuggestions() {
        guard let field = suggestingField, let well = field.superview, !suggestionList.isHidden else { return }
        let frame = well.convert(well.bounds, to: view)
        // The field editor draws its text its line fragment padding in from the field's edge.
        let padding = (field.currentEditor() as? NSTextView)?.textContainer?.lineFragmentPadding ?? 2
        let textX = field.convert(field.bounds, to: view).minX + padding
        let x = max(0, textX - MailRecipientSuggestionList.textInset), height = suggestionList.listHeight
        suggestionList.frame = NSRect(x: x, y: view.isFlipped ? frame.maxY + 4 : frame.minY - 4 - height,
                                      width: max(0, frame.maxX + (frame.minX - x) - x), height: height)
    }
    private func acceptSuggestion(_ address: MailAddress) {
        guard let field = suggestingField, let editor = field.currentEditor() as? NSTextView, let range = Self.typedRange(in: editor) else { return hideSuggestions() }
        hideSuggestions()
        // Typing a separator is what turns text into a token, and AppKit splits at every one, so a quoted name's
        // comma would split it: for this insert the only separator is one no address contains.
        let separators = field.tokenizingCharacterSet, separator = "\u{1F}"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: separator)
        editor.insertText(MailComposeFormatting.display(address) + separator, replacementRange: range)
        field.tokenizingCharacterSet = separators
    }
    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject object: Any) -> String? {
        // Thin spaces pad the squared token, which AppKit draws tight to its text.
        (object as? MailAddressToken).map { "\u{2009}" + MailPresentation.address($0.address) + "\u{2009}" }
    }
    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject object: Any) -> String? {
        (object as? MailAddressToken).map { MailComposeFormatting.display($0.address) }
    }
    func tokenField(_ tokenField: NSTokenField, representedObjectForEditing editingString: String) -> Any? {
        MailAddressToken(MailComposeFormatting.addresses(editingString).first ?? .init(editingString))
    }
    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        tokens.flatMap { value -> [MailAddressToken] in
            if let token = value as? MailAddressToken { return [token] }
            return MailComposeFormatting.addresses(value as? String ?? "").map(MailAddressToken.init)
        }
    }
    func tokenField(_ tokenField: NSTokenField, readFrom pasteboard: NSPasteboard) -> [Any]? {
        pasteboard.string(forType: .string).map { MailComposeFormatting.addresses($0).map(MailAddressToken.init) }
    }
    func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(objects.compactMap { ($0 as? MailAddressToken).map { MailComposeFormatting.display($0.address) } }.joined(separator: ", "), forType: .string)
    }
    private func commitFields() { view.window?.makeFirstResponder(nil); to.validateEditing(); cc.validateEditing(); bcc.validateEditing(); publishFields() }
    func commitPendingFields() { commitFields() }
    private func send() {
        commitFields()
        Task { [model] in do { try await model.send() } catch { model.report(error) } }
    }
    private func close() {
        commitFields()
        Task { [model] in do { try await model.close() } catch { model.report(error) } }
    }
    private func discard() {
        commitFields()
        Task { [self] in
            do { try await model.refreshEditor(); confirmDiscard() }
            catch { model.report(error) }
        }
    }
    private func confirmDiscard() {
        let perform: () -> Void = { [model] in Task { do { try await model.discard() } catch { model.report(error) } } }
        guard model.hasContent else { perform(); return }
        // A second press while the first one's sheet is up would stack another sheet.
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = MailStrings.discardConfirmation; alert.informativeText = MailStrings.discardMessage
        alert.addButton(withTitle: MailStrings.discardDraft); alert.addButton(withTitle: MailStrings.cancel)
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { perform() } }
    }
    private func attachFiles() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak model] response in if response == .OK { model?.addFiles(panel.urls) } }
    }
    private func makeFormattingToolbar() -> NSView {
        // Wide enough apart for each symbol's 24 pt hover circle.
        let bar = NSStackView(); bar.spacing = 12; bar.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 6, right: 20)
        func button(_ command: String, _ symbol: String, _ title: String, toggle: Bool = false) {
            let button = MistIconButton(symbol: symbol, title: title)
            if toggle { button.setButtonType(.toggle); formatting[command] = button }
            button.onClick = { [weak self] in self?.exec(command) }; controls.append(button); bar.addArrangedSubview(button)
        }
        button("bold", "bold", MailStrings.bold, toggle: true); button("italic", "italic", MailStrings.italic, toggle: true)
        button("underline", "underline", MailStrings.underline, toggle: true); button("strikeThrough", "strikethrough", MailStrings.strikethrough, toggle: true)
        size.addItems(withTitles: [MailStrings.small, MailStrings.normal, MailStrings.large, MailStrings.huge]); size.selectItem(at: 1)
        size.setAccessibilityLabel(MailStrings.textSize); size.setCustomTooltip(MailStrings.textSize); size.target = self; size.action = #selector(changeSize)
        color.addItems(withTitles: [MailStrings.defaultColor, MailStrings.gray, MailStrings.red, MailStrings.orange, MailStrings.green, MailStrings.blue, MailStrings.purple])
        color.setAccessibilityLabel(MailStrings.textColor); color.setCustomTooltip(MailStrings.textColor); color.target = self; color.action = #selector(changeColor)
        controls += [size, color]; bar.addArrangedSubview(size); bar.addArrangedSubview(color)
        button("insertUnorderedList", "list.bullet", MailStrings.bulletedList, toggle: true); button("insertOrderedList", "list.number", MailStrings.numberedList, toggle: true)
        button("outdent", "decrease.indent", MailStrings.decreaseIndent); button("indent", "increase.indent", MailStrings.increaseIndent)
        let link = MistIconButton(symbol: "link", title: MailStrings.link); link.setButtonType(.toggle); link.onClick = { [weak self] in self?.showLinkSheet() }; formatting["link"] = link; controls.append(link); bar.addArrangedSubview(link)
        button("removeFormat", "textformat", MailStrings.clearFormatting)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), bar.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), bar.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor), scroll.heightAnchor.constraint(equalToConstant: 40)])
        return scroll
    }
    private func exec(_ command: String, value: String? = nil) {
        Task { [self] in do { try await editor.exec(command, value: value) } catch { model.report(error) } }
    }
    /// Gmail's scale over a 13px body: legacy sizes 1, 2, 4 and 6, so Normal is the body's own size.
    private static let sizes = ["1", "2", "4", "6"]
    @objc private func changeSize() { exec("fontSize", value: Self.sizes[size.indexOfSelectedItem]) }
    private static let palette = ["#000000", "#808080", "#cc0000", "#e67300", "#008000", "#0066cc", "#800080"]
    @objc private func changeColor() { exec("foreColor", value: Self.palette[color.indexOfSelectedItem]) }
    private func updateSelection(_ state: [String: Any]) {
        selectionState = state
        for (command, button) in formatting { button.state = state[command] as? Bool == true ? .on : .off }
        if let value = state["fontSize"] as? String, let index = Self.sizes.firstIndex(of: value) { size.selectItem(at: index) }
        if let value = state["foreColor"] as? String {
            let rgb = value.replacingOccurrences(of: " ", with: "").lowercased()
            let values = ["rgb(0,0,0)", "rgb(128,128,128)", "rgb(204,0,0)", "rgb(230,115,0)", "rgb(0,128,0)", "rgb(0,102,204)", "rgb(128,0,128)"]
            if let index = values.firstIndex(of: rgb) ?? Self.palette.firstIndex(of: rgb) { color.selectItem(at: index) }
        }
    }
    private func showLinkSheet() {
        guard let window = view.window, !model.isSending else { return }
        Task { [self] in
            do {
                try await editor.call("window.MistMailCompose.saveSelection()")
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 136), styleMask: [.titled], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.title = MailStrings.link
                let field = NSTextField(string: selectionState["href"] as? String ?? ""); field.placeholderString = "https://"; field.setAccessibilityLabel(MailStrings.linkURL)
                let ok = MistButton(title: MailStrings.ok, role: .primary, size: .regular), cancel = MistButton(title: MailStrings.cancel, size: .regular), remove = MistButton(title: MailStrings.removeLink, size: .regular)
                ok.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
                ok.onClick = { window.endSheet(panel, returnCode: .OK) }; cancel.onClick = { window.endSheet(panel, returnCode: .cancel) }
                remove.onClick = { window.endSheet(panel, returnCode: .init(rawValue: 42)) }; remove.isHidden = selectionState["link"] as? Bool != true
                let actions = NSStackView(views: [remove, NSView(), cancel, ok]); actions.spacing = 8
                let well = MistFieldWellView(field, shape: .rounded)
                let stack = NSStackView(views: [NSTextField.mistLabel(MailStrings.linkURL, style: .secondary), well, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
                panel.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20), well.widthAnchor.constraint(equalTo: stack.widthAnchor), actions.widthAnchor.constraint(equalTo: stack.widthAnchor)])
                window.beginSheet(panel) { [self] response in
                    Task { [self] in
                        do {
                            try await self.editor.call("window.MistMailCompose.restoreSelection()")
                            if response.rawValue == 42 { try await self.editor.exec("unlink") }
                            else if response == .OK {
                                let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !raw.isEmpty { try await self.editor.exec("createLink", value: URLComponents(string: raw)?.scheme == nil ? "https://" + raw : raw) }
                            }
                        } catch { self.model.report(error) }
                    }
                }
                panel.makeFirstResponder(field)
            } catch { model.report(error) }
        }
    }
}

private final class MailRecipientTokenField: NSTokenField {
    /// One borderless line; fixed, since a token field sized by its content loops layout while editing.
    private static let singleLineHeight: CGFloat = 18
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.singleLineHeight) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell?.wraps = false; cell?.isScrollable = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Recipient suggestions on a floating kit card: kit list rows, nothing selected until an arrow key or the pointer
/// picks one, gray while selected.
final class MailRecipientSuggestionList: NSView {
    static let rowHeight: CGFloat = 44, padding: CGFloat = 6
    /// From the list's leading edge to its rows' text.
    static let textInset = padding + MailRecipientSuggestionRow.textInset
    private let card = MistCardView(style: .floatingInput)
    private let scroll = NSScrollView()
    private let document = MailRecipientSuggestionDocument()
    private var rows: [MailRecipientSuggestionRow] = []
    private(set) var matches: [MailAddress] = []
    private(set) var selectedIndex = -1
    private var initialMouseLocation = NSEvent.mouseLocation
    var onChoose: ((MailAddress) -> Void)?
    var listHeight: CGFloat { CGFloat(min(6, matches.count)) * Self.rowHeight + 2 * Self.padding }
    var selectedAddress: MailAddress? { matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil }

    init() {
        super.init(frame: .zero)
        isHidden = true
        addSubview(card)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel(MailStrings.suggestions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ matches: [MailAddress]) {
        guard self.matches != matches else { return }
        let selected = selectedAddress
        self.matches = matches
        initialMouseLocation = NSEvent.mouseLocation
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.enumerated().map { index, address in
            let row = MailRecipientSuggestionRow(address: address)
            row.onHover = { [weak self] in
                guard let self, NSEvent.mouseLocation != self.initialMouseLocation, self.selectedIndex != index else { return }
                self.select(index, scroll: false)
            }
            row.onClick = { [weak self] in self?.onChoose?(address) }
            document.addSubview(row)
            return row
        }
        setAccessibilityChildren(rows)
        isHidden = matches.isEmpty
        needsLayout = true
        // A row stays selected while it still matches.
        select(selected.flatMap { matches.firstIndex(of: $0) } ?? -1)
    }
    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        initialMouseLocation = NSEvent.mouseLocation
        select(selectedIndex < 0 ? (delta > 0 ? 0 : matches.count - 1) : (selectedIndex + delta + matches.count) % matches.count)
    }
    private func select(_ index: Int, scroll: Bool = true) {
        selectedIndex = index
        for (offset, row) in rows.enumerated() { row.isSelected = offset == index }
        if scroll, rows.indices.contains(index) { layoutSubtreeIfNeeded(); document.scrollToVisible(rows[index].frame) }
    }
    override func layout() {
        super.layout()
        card.frame = bounds
        scroll.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let width = scroll.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight)
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight) }
    }
    /// AppKit sends the cursor update of a cursor rect under the list (an attachment's or a toolbar button's hand,
    /// the subject's I-beam) to the view under the pointer, which passes it up to here.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

private final class MailRecipientSuggestionDocument: NSView {
    override var isFlipped: Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

/// A suggested recipient as a kit list row: the name over the address, or the address alone.
final class MailRecipientSuggestionRow: HoverableView {
    static let textInset: CGFloat = 8
    private let name = NSTextField.mistLabel(style: .rowHeadline)
    private let email = NSTextField.mistLabel(style: .secondary)
    private let hasName: Bool
    private var moveArea: NSTrackingArea?
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(address: MailAddress) {
        hasName = address.name?.isEmpty == false
        super.init(frame: .zero)
        wantsLayer = true
        backgroundColor = .clear; hoveredColor = .clear
        layer?.cornerRadius = MistRowStyle.list.radius
        phi.selectedColor = ThemedColor.mistSelectedFill.mapper
        name.stringValue = hasName ? address.name ?? "" : address.email
        email.stringValue = address.email; email.lineBreakMode = .byTruncatingMiddle; email.isHidden = !hasName
        name.lineBreakMode = hasName ? .byTruncatingTail : .byTruncatingMiddle
        addSubview(name); addSubview(email)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(hasName ? name.stringValue + ", " + address.email : address.email)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// The labels' frames start 2 pt before their text.
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 2 * Self.textInset + 4)
        name.frame = NSRect(x: Self.textInset - 2, y: hasName ? 23 : (bounds.height - 17) / 2, width: width, height: 17)
        email.frame = NSRect(x: Self.textInset - 2, y: 5, width: width, height: 16)
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        moveArea = area
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

private final class MailAddressToken: NSObject {
    let address: MailAddress
    init(_ address: MailAddress) { self.address = address }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MailAddressToken else { return false }
        return address.email.lowercased() == other.address.email.lowercased() && address.name == other.address.name
    }
    override var hash: Int {
        var hasher = Hasher(); hasher.combine(address.email.lowercased()); hasher.combine(address.name)
        return hasher.finalize()
    }
}

private final class MailComposeDropView: AgentChatBackgroundView {
    var onFiles: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { MailComposeEditor.fileURLs(sender.draggingPasteboard).isEmpty ? [] : .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !MailComposeEditor.fileURLs(sender.draggingPasteboard).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = MailComposeEditor.fileURLs(sender.draggingPasteboard); guard !files.isEmpty else { return false }; onFiles?(files); return true
    }
}
