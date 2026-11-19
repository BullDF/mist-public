import AppKit
import MistMailCore

/// The toolbar's refresh button. Its arrow turns once per click, so a click shows even when
/// nothing new arrives.
final class MailRefreshButton: MistIconButton {
    init() { super.init(symbol: "arrow.clockwise", title: MailStrings.refresh); target = self; action = #selector(spinAndRun) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func spinAndRun() {
        symbol.addSymbolEffect(.rotate.clockwise.wholeSymbol, options: .speed(3.5).nonRepeating)
        onClick?()
    }
}

/// The reader's and compose's attachment cards, wrapped into rows across the pane, so none is cut off.
final class MailAttachmentCardsView: NSView {
    private let insets: NSEdgeInsets
    private let spacing: CGFloat = 8

    init(insets: NSEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    var cards: [MistAttachmentFileCard] { subviews.compactMap { $0 as? MistAttachmentFileCard } }
    func setCards(_ cards: [MistAttachmentFileCard]) {
        subviews.forEach { $0.removeFromSuperview() }
        cards.forEach(addSubview)
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(width: bounds.width).last.map { $0.maxY + insets.bottom } ?? 0)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
    override func layout() {
        super.layout()
        for (card, frame) in zip(subviews, frames(width: bounds.width)) { card.frame = frame }
    }
    private func frames(width: CGFloat) -> [NSRect] {
        let size = MistAttachmentFileCard.size
        var x = insets.left, y = insets.top
        return subviews.map { _ in
            if x > insets.left, x + size.width > width - insets.right { x = insets.left; y += size.height + spacing }
            defer { x += size.width + spacing }
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
    }
}

final class MailboxOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        if !frame.isEmpty { frame.origin.y = (rect(ofRow: row).midY - frame.height / 2).rounded() }
        // The plain style puts a root row's caret against the pane's edge, outside the rows' rounded
        // fill (inset 8): move every caret into it, still clear of the row's 10 pt leading padding.
        if !frame.isEmpty { frame.origin.x += 5 }
        return frame
    }
}

final class MailMessageTable: NSTableView {
    var onDelete: (() -> Void)?
    var contextMenu: ((Int) -> NSMenu?)?
    /// A click lands on a row's labels, which refuse first responder, so focus stayed where it was
    /// (Delete then edited the search field): the list takes it.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil)); guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); return contextMenu?(row)
    }
}

final class MailMessageCell: NSTableCellView {
    let sender = NSTextField(labelWithString: ""), subject = NSTextField(labelWithString: ""), snippet = NSTextField(wrappingLabelWithString: ""), unread = MistDotView()
    /// Font metrics plus two snippet lines, stack gaps, and 12 pt of padding inside the row fill.
    static var rowHeight: CGFloat {
        func line(_ style: MistTextStyle) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: style.nsFont))
        }
        return line(.rowHeadline) + line(.rowSubheadline) + 2 * line(.secondary) + 6 + 24 + 4
    }
    private let date = NSTextField(labelWithString: ""), account = NSTextField(labelWithString: ""), icons = NSStackView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [sender, spacer, date, account]); top.spacing = 5
        for field in [date, account] { field.setContentCompressionResistancePriority(.required, for: .horizontal) }
        sender.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let middle = NSStackView(views: [subject, icons]); middle.spacing = 4
        let stack = NSStackView(views: [top, middle, snippet]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unread); unread.translatesAutoresizingMaskIntoConstraints = false
        sender.applyMistStyle(.rowHeadline); subject.applyMistStyle(.rowSubheadline)
        date.applyMistStyle(.detail); account.applyMistStyle(.detail); snippet.applyMistStyle(.secondary)
        unread.setAccessibilityLabel(MailStrings.markUnread)
        unread.setAccessibilityElement(true); unread.setAccessibilityRole(.image)
        // Truncating line breaks keep a label to one line; wrap and truncate only the last line.
        snippet.maximumNumberOfLines = 2; snippet.lineBreakMode = .byWordWrapping; snippet.cell?.truncatesLastVisibleLine = true
        // Wrapping labels start selectable; a click there would start a text selection instead of
        // selecting the row, and Backspace would then no longer delete the message.
        snippet.isSelectable = false
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for field in [sender, subject] { field.lineBreakMode = .byTruncatingTail; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), stack.centerYAnchor.constraint(equalTo: centerYAnchor), top.widthAnchor.constraint(equalTo: stack.widthAnchor), middle.widthAnchor.constraint(equalTo: stack.widthAnchor), snippet.widthAnchor.constraint(equalTo: stack.widthAnchor), unread.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), unread.centerYAnchor.constraint(equalTo: sender.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        // A wrapping label measures its height against this width; without it, it stays one line.
        if snippet.preferredMaxLayoutWidth != snippet.frame.width { snippet.preferredMaxLayoutWidth = snippet.frame.width; needsLayout = true }
    }
    func update(_ message: MailMessageSummary, role: MailboxRole?, accountName: String?) {
        let isUnread = !message.flags.contains(MailFlags.seen)
        sender.stringValue = MailPresentation.correspondent(message, role: role)
        date.stringValue = MailPresentation.date(message.date); subject.stringValue = MailPresentation.subject(message.subject); snippet.stringValue = message.snippet
        unread.isHidden = !isUnread
        account.stringValue = accountName ?? ""; account.isHidden = accountName == nil
        icons.arrangedSubviews.forEach { icons.removeArrangedSubview($0); $0.removeFromSuperview() }
        var symbols: [String] = []
        if message.flags.contains(MailFlags.flagged) { symbols.append("flag.fill") }
        if message.hasAttachments { symbols.append("paperclip") }
        if message.flags.contains(MailFlags.answered) { symbols.append("arrowshape.turn.up.left") }
        if message.flags.contains(MailFlags.forwarded) { symbols.append("arrowshape.turn.up.right") }
        for symbol in symbols { let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!); image.symbolConfiguration = .init(pointSize: 11, weight: .regular); image.phi.setContentTintColor(.textTertiary); image.widthAnchor.constraint(equalToConstant: 12).isActive = true; icons.addArrangedSubview(image) }
    }
}

final class MailMenuItem: NSMenuItem {
    private var handler: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) { handler = action; super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self }
    // AppKit's copy calls this initializer, and ShortcutMenuPresentation copies every item of a menu
    // that opens; without it Swift traps. A copy keeps its target, the original item, and so its action.
    override init(title string: String, action selector: Selector?, keyEquivalent charCode: String) { super.init(title: string, action: selector, keyEquivalent: charCode) }
    required init(coder: NSCoder) { super.init(coder: coder) }
    @objc private func run() { handler?() }
}

enum MailMessageMenus {
    @MainActor static func menu(for message: MailMessageSummary, model: MailPageModel) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(MailMenuItem(MailStrings.reply) { Task { await model.reply(to: message) } })
        menu.addItem(MailMenuItem(MailStrings.replyAll) { Task { await model.reply(to: message, all: true) } })
        menu.addItem(MailMenuItem(MailStrings.forward) { Task { await model.forward(message) } })
        menu.addItem(.separator())
        let seen = message.flags.contains(MailFlags.seen), flagged = message.flags.contains(MailFlags.flagged)
        menu.addItem(MailMenuItem(seen ? MailStrings.markUnread : MailStrings.markRead) { model.perform(.seen(!seen), message: message) })
        menu.addItem(MailMenuItem(flagged ? MailStrings.unflag : MailStrings.flag) { model.perform(.flagged(!flagged), message: message) })
        let archive = MailMenuItem(MailStrings.archive) { model.perform(.archive, message: message) }; archive.isEnabled = false; menu.addItem(archive)
        Task { archive.isEnabled = await model.source.canArchive(message.id) }
        let move = NSMenuItem(title: MailStrings.move, action: nil, keyEquivalent: ""); move.submenu = moveMenu(for: message, model: model); menu.addItem(move)
        menu.addItem(MailMenuItem(MailStrings.delete) { model.perform(.delete, message: message) })
        return menu
    }
    @MainActor static func moveMenu(for message: MailMessageSummary, model: MailPageModel) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let boxes = model.state.mailboxes.filter { $0.accountID == message.accountID && $0.id != message.mailboxID && !$0.attributes.contains { $0.lowercased() == "\\noselect" } }
        for box in boxes.sorted(by: { MailPresentation.mailboxName($0).localizedStandardCompare(MailPresentation.mailboxName($1)) == .orderedAscending }) { menu.addItem(MailMenuItem(MailPresentation.mailboxName(box)) { model.perform(.move(box.id), message: message) }) }
        return menu
    }
}
