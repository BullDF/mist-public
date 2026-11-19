import AppKit

final class MistTabMentionPopup: NSView {
    private let scroll = NSScrollView()
    private let document = MistSlashCommandDocument()
    private var rows: [MistTabMentionRow] = []
    private(set) var matches: [AgentTabMention] = []
    private(set) var currentTabId: Int?
    private var selectedIndex = 0
    private var initialMouseLocation = NSEvent.mouseLocation
    var onComplete: ((AgentTabMention) -> Void)?
    var onHeightChange: (() -> Void)?
    var listHeight: CGFloat { CGFloat(min(6, matches.count)) * 44 }
    var selectedMention: AgentTabMention? { matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil }

    init() {
        super.init(frame: .zero)
        isHidden = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityRole(.list)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ matches: [AgentTabMention], current: AgentTabMention? = nil, icon: (AgentTabMention) -> NSImage? = { _ in nil }) {
        let matches = current.map { [$0] + matches } ?? matches
        guard self.matches != matches || currentTabId != current?.tabId else { return }
        let oldHeight = listHeight
        self.matches = matches
        currentTabId = current?.tabId
        selectedIndex = 0
        initialMouseLocation = NSEvent.mouseLocation
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.enumerated().map { index, mention in
            let pinned = !mention.isGroup && mention.tabId == currentTabId
            let row = MistTabMentionRow(mention: mention, image: icon(mention),
                                       primaryText: pinned ? AgentChatStrings.currentTab : nil,
                                       secondaryText: pinned ? mention.title : mention.secondaryLabel(in: matches),
                                       secondaryLineBreakMode: pinned ? .byTruncatingTail : .byTruncatingMiddle)
            row.onHover = { [weak self] in
                guard let self, NSEvent.mouseLocation != self.initialMouseLocation else { return }
                self.select(index, scroll: false)
            }
            row.onClick = { [weak self] in self?.onComplete?(mention) }
            document.addSubview(row)
            return row
        }
        setAccessibilityChildren(rows)
        isHidden = matches.isEmpty
        needsLayout = true
        select(0)
        if oldHeight != listHeight { onHeightChange?() }
    }
    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        initialMouseLocation = NSEvent.mouseLocation
        select((selectedIndex + delta + matches.count) % matches.count)
    }
    private func select(_ index: Int, scroll: Bool = true) {
        selectedIndex = index
        for (offset, row) in rows.enumerated() { row.isSelected = offset == index }
        if scroll, rows.indices.contains(index) {
            layoutSubtreeIfNeeded()
            document.scrollToVisible(rows[index].frame)
        }
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(rows.count) * 44)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * 44, width: scroll.contentSize.width, height: 44)
        }
    }
}

/// The draft's tab mentions above the composer, on the kit's inner card.
final class MistTabMentionBanner: NSView {
    private(set) var mentions: [AgentTabMention] = []
    private(set) var rows: [MistTabMentionRow] = []
    private let surface = MistCardView(style: .inner)
    var onRemove: ((String) -> Void)?
    var listHeight: CGFloat { CGFloat(mentions.count) * 44 }

    init() {
        super.init(frame: .zero)
        isHidden = true
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ tokens: [AgentTabMention], tabs: [Tab], groups: [MistMentionGroup] = []) {
        let open = Dictionary(tabs.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let mentions = tokens.filter { seen.insert($0.key).inserted }.map {
            var mention = $0
            if let group = mention.group {
                if let live = groups.first(where: { $0.info.token == group.token }) {
                    mention = AgentTabMention(group: live)
                    mention.range = $0.range
                } else {
                    mention.closed = true
                }
            } else {
                mention.closed = open[mention.tabId] == nil
            }
            return mention
        }
        guard self.mentions != mentions else { return }
        self.mentions = mentions
        rows.forEach { $0.removeFromSuperview() }
        rows = mentions.map { mention in
            var image: NSImage?
            if let group = mention.group, let color = GroupColor(rawValue: group.color) {
                image = NSImage.tabGroupColorSwatch(for: color, cornerRadius: 6)
            } else if !mention.isGroup {
                image = open[mention.tabId].flatMap { $0.liveFaviconData ?? $0.cachedFaviconData }.flatMap(NSImage.init(data:))
            }
            let row = MistTabMentionRow(mention: mention, image: image)
            row.onRemove = { [weak self] in self?.onRemove?(mention.key) }
            row.alphaValue = mention.closed ? 0.45 : 1
            addSubview(row)
            return row
        }
        isHidden = mentions.isEmpty
        needsLayout = true
    }
    override func layout() {
        super.layout()
        surface.frame = bounds
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: bounds.height - CGFloat(index + 1) * 44, width: bounds.width, height: 44)
        }
    }
}

/// A tab as a kit list row: its title and a secondary line, gray while selected.
final class MistTabMentionRow: HoverableView {
    private let icon = NSImageView()
    private let title = NSTextField.mistLabel(style: .rowHeadline)
    private let host = NSTextField.mistLabel(style: .secondary)
    private var moveArea: NSTrackingArea?
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    let removeButton = MistIconButton(symbol: "xmark", title: AgentChatStrings.removeMention)
    var onRemove: (() -> Void)? {
        didSet { removeButton.isHidden = onRemove == nil; needsLayout = true }
    }
    init(mention: AgentTabMention, image: NSImage?, primaryText: String? = nil, secondaryText: String? = nil, secondaryLineBreakMode: NSLineBreakMode = .byTruncatingMiddle) {
        super.init(frame: .zero)
        wantsLayer = true
        backgroundColor = .clear
        hoveredColor = .clear
        layer?.cornerRadius = MistRowStyle.list.radius
        phi.selectedColor = ThemedColor.mistSelectedFill.mapper
        icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        title.stringValue = primaryText ?? mention.title
        host.stringValue = secondaryText ?? mention.secondaryText
        host.lineBreakMode = secondaryLineBreakMode
        [icon, title, host].forEach { addSubview($0) }
        removeButton.onClick = { [weak self] in self?.onRemove?() }
        removeButton.isHidden = true
        addSubview(removeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.stringValue + ". " + host.stringValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 14, width: 16, height: 16)
        let reserved: CGFloat = onRemove == nil ? 46 : 76
        title.frame = NSRect(x: 36, y: 23, width: max(0, bounds.width - reserved), height: 17)
        host.frame = NSRect(x: 36, y: 5, width: max(0, bounds.width - reserved), height: 16)
        removeButton.frame = NSRect(x: max(0, bounds.width - 34), y: 10, width: 24, height: 24)
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === removeButton ? hit : self
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// An inline list shared by the NTP and chat cards. The editor owns its interaction.
final class MistSlashCommandPopup: NSView {
    static let rowHeight: CGFloat = 44
    private let scrollView = NSScrollView()
    private let document = MistSlashCommandDocument()
    private var rows: [MistSlashCommandRow] = []
    private(set) var matches: [ClaudeCodeSlashMatch] = []
    private(set) var selectedIndex = 0
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var initialMouseLocation: NSPoint?
    var onComplete: ((ClaudeCodeSlashCommand) -> Void)?
    var onHeightChange: (() -> Void)?
    var listHeight: CGFloat { CGFloat(min(6, matches.count)) * Self.rowHeight }
    var selectedCommand: ClaudeCodeSlashCommand? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex].command : nil
    }

    init() {
        super.init(frame: .zero)
        isHidden = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(NSLocalizedString("browser.claudeCode.slashCommands", value: "Commands and skills", comment: "Claude Code composer - Accessibility label for the slash command suggestion list"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ matches: [ClaudeCodeSlashMatch]) {
        guard self.matches != matches else { return }
        let oldHeight = listHeight
        initialMouseLocation = mouseLocation()
        self.matches = matches
        selectedIndex = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.enumerated().map { index, match in
            let row = MistSlashCommandRow(match: match)
            row.onHover = { [weak self] in
                guard let self, self.mouseLocation() != self.initialMouseLocation,
                      self.selectedIndex != index else { return }
                self.select(index, scroll: false)
            }
            row.onClick = { [weak self] in self?.onComplete?(match.command) }
            document.addSubview(row)
            return row
        }
        setAccessibilityChildren(rows)
        isHidden = matches.isEmpty
        needsLayout = true
        select(0)
        if oldHeight != listHeight { onHeightChange?() }
    }

    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        initialMouseLocation = mouseLocation()
        select((selectedIndex + delta + matches.count) % matches.count)
    }

    private func select(_ index: Int, scroll: Bool = true) {
        selectedIndex = index
        for (offset, row) in rows.enumerated() { row.isSelected = offset == index }
        if scroll, rows.indices.contains(index) {
            layoutSubtreeIfNeeded()
            document.scrollToVisible(rows[index].frame)
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight)
        let nameWidth = min(width * 0.5, rows.map(\.nameWidth).max() ?? 0)
        for (index, row) in rows.enumerated() {
            row.nameColumnWidth = nameWidth
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
        }
    }
}

private final class MistSlashCommandDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A command as a kit list row: its name in monospace, like code, beside its description.
private final class MistSlashCommandRow: HoverableView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField.mistWrappingLabel(style: .secondary)
    private var mouseMoveArea: NSTrackingArea?
    var nameColumnWidth: CGFloat = 0 { didSet { needsLayout = true } }
    /// The drawn name plus the text cell's 2 pt padding on each side; the label's intrinsic width comes out short.
    private var nameTextWidth: CGFloat { ceil(nameLabel.attributedStringValue.size().width) + 4 }
    var nameWidth: CGFloat { nameTextWidth + hintLabel.intrinsicContentSize.width }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(match: ClaudeCodeSlashMatch) {
        super.init(frame: .zero)
        wantsLayer = true
        backgroundColor = .clear
        hoveredColor = .clear
        layer?.cornerRadius = MistRowStyle.list.radius
        phi.selectedColor = ThemedColor.mistSelectedFill.mapper
        let command = match.command
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nameLabel.font = font
        nameLabel.phi.setTextColor(.textPrimary)
        // An attributed value's own paragraph style overrides the label's line break mode; without one it word-wraps.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let name = NSMutableAttributedString(string: "/" + command.name, attributes: [.font: font, .paragraphStyle: style])
        for offset in match.matchedCharacters {
            let start = command.name.index(command.name.startIndex, offsetBy: offset)
            let range = NSRange(start..<command.name.index(after: start), in: command.name)
            name.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                              range: NSRange(location: range.location + 1, length: range.length))
        }
        nameLabel.attributedStringValue = name
        descriptionLabel.stringValue = command.displayDescription
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        addSubview(descriptionLabel)
        // Keep the hint separately themed while the command's matched characters stay bold.
        hintLabel.stringValue = command.argumentHint.isEmpty ? "" : " " + command.argumentHint
        hintLabel.font = font
        hintLabel.phi.setTextColor(.textSecondary)
        hintLabel.lineBreakMode = .byTruncatingTail
        addSubview(hintLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("/" + command.name + ". " + command.displayDescription)
    }
    private let hintLabel = NSTextField(labelWithString: "")
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The label spans the column so a name truncates only when the column itself is capped.
        let nameWidth = min(nameColumnWidth, nameTextWidth)
        nameLabel.frame = NSRect(x: 10, y: 13, width: nameColumnWidth, height: 18)
        hintLabel.frame = NSRect(x: 10 + nameWidth, y: 13, width: max(0, nameColumnWidth - nameWidth), height: 18)
        let x = 10 + nameColumnWidth + 16
        let width = max(0, bounds.width - x - 10)
        let size = descriptionLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 34)) ?? .zero
        let height = min(34, size.height)
        descriptionLabel.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseMoveArea { removeTrackingArea(mouseMoveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mouseMoveArea = area
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
