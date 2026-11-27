import AppKit
import Combine

private func previewEngineImage(_ engine: DrifterEngine) -> NSImage? {
    let icon = AgentChatIcon.resolve(engine: engine)
    let image = NSImage(named: icon.rawValue)?.copy() as? NSImage
    image?.isTemplate = icon.isTemplate
    return image
}

/// Opaque chat and card fills above the shared page surface.
class AgentChatBackgroundView: NSView {
    private let fill = CAShapeLayer()
    var fillCornerRadius: CGFloat = 0 { didSet { updateFill() } }
    var fillColor: ThemedColor = .windowBackground { didSet { fill.phi(source: self)[\.fillColor] = fillColor.cgColorMapperOptional } }
    var fillPath: CGPath? { fill.path }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.phi(source: self)[\.fillColor] = ThemedColor.windowBackground.cgColorMapperOptional
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateFill()
    }

    private func updateFill() {
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: fillCornerRadius, cornerHeight: fillCornerRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.bounds = bounds
        fill.path = path
        CATransaction.commit()
    }
}

/// Presentation only: pages reach this card as images.
final class BrowserAgentPreviewCard: AgentChatBackgroundView {
    static let bodyCornerRadius = MistKit.Radius.card - 1
    final class Body: NSView {
        var onClick: (() -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) { onClick?() }

    }

    let bodyView = Body()
    private let title = NSTextField(labelWithString: "")
    private let favicon = NSImageView()
    private let stillView = StillView()
    private let miniature = AgentChatMiniatureView()
    private var bindings = Set<AnyCancellable>()
    private weak var tab: Tab?
    private var engine: DrifterEngine?
    var onClose: (() -> Void)?
    var onContentChanged: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue {
                onVisibilityChanged?()
            }
        }
    }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fillCornerRadius = MistKit.Radius.card
        fillColor = .mistCardFill
        // Circular corners match the fill path.
        layer?.cornerRadius = MistKit.Radius.card
        layer?.borderWidth = MistKit.borderWidth
        phiLayer?.setBorderColor(.mistHairline)
        let shadow = MistCardView(style: .content, shadowOnly: true)
        shadow.frame = bounds
        shadow.autoresizingMask = [.width, .height]
        addSubview(shadow, positioned: .below, relativeTo: nil)

        let close = MistIconButton(symbol: "xmark", title: NSLocalizedString("browser.agent.preview.close", value: "Close tab preview",
            comment: "Browser Agent preview - Close button accessibility label"))
        close.target = self
        close.action = #selector(closeCard)
        title.applyMistStyle(.rowHeadline)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bodyView.wantsLayer = true
        bodyView.layer?.cornerRadius = Self.bodyCornerRadius
        bodyView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        bodyView.layer?.masksToBounds = true
        bodyView.phiLayer?.setBackgroundColor(.windowBackground)
        [favicon, title, close, bodyView].forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        bodyView.addSubview(stillView)
        bodyView.addSubview(miniature)
        miniature.frame = bodyView.bounds
        miniature.autoresizingMask = [.width, .height]
        miniature.isHidden = true
        stillView.frame = bodyView.bounds
        stillView.autoresizingMask = [.width, .height]
        stillView.isHidden = true
        NSLayoutConstraint.activate([
            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            favicon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            favicon.widthAnchor.constraint(equalToConstant: 16), favicon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: favicon.centerYAnchor),
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: favicon.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 20), close.heightAnchor.constraint(equalToConstant: 20),
            bodyView.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            bodyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            bodyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            bodyView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private final class StillView: NSView {
        var image: CGImage? { didSet { needsDisplay = true } }
        var opacity: CGFloat = 1 { didSet { needsDisplay = true } }
        var favicon: NSImage? { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                let factor = min(1 / (window?.backingScaleFactor ?? 1), bounds.width / size.width, bounds.height / size.height)
                let rect = CGRect(x: (bounds.width - size.width * factor) / 2, y: (bounds.height - size.height * factor) / 2,
                    width: size.width * factor, height: size.height * factor)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: image, size: size).draw(in: rect, from: .zero,
                    operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: nil)
            } else {
                favicon?.draw(in: CGRect(x: (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24),
                    from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
            }
        }
    }

    func show(tab: Tab, live: Bool, chat: AgentChatMiniatureView.Source? = nil) {
        stillView.opacity = live ? 1 : 0.7
        stillView.isHidden = chat != nil
        miniature.isHidden = chat == nil
        if let chat {
            miniature.show(chat)
        }
        let engine = chat?.engine
        guard self.tab !== tab || self.engine != engine else { return }
        self.tab = tab
        self.engine = engine
        bindings.removeAll()
        tab.$title.combineLatest(tab.$liveFaviconData, tab.$cachedFaviconData)
            .receive(on: DispatchQueue.main).sink { [weak self] title, live, cached in
                self?.title.stringValue = title
                self?.favicon.image = engine.map(previewEngineImage)
                    ?? (live ?? cached).flatMap(NSImage.init(data:))
                    ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                self?.stillView.favicon = self?.favicon.image
            }.store(in: &bindings)
        // @Published sends before the wrapper changes; defer reconciliation.
        Publishers.Merge3(tab.$webContentWrapper.map { _ in () }, tab.$url.map { _ in () }, tab.$isLoading.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onContentChanged?() }.store(in: &bindings)
    }

    func setImage(_ image: CGImage?) {
        stillView.image = image
    }

    @objc private func closeCard() { onClose?() }
}

/// One live body, a few frozen cards, and a list of folded tabs. No clock or
/// Chromium ownership lives in the presentation.
final class BrowserAgentPreviewStack: NSView {
    struct Item {
        let tab: Tab
        let mount: BrowserAgentPreviewState.Mount
        var still: CGImage?
        var chat: AgentChatMiniatureView.Source? = nil
        var engine: DrifterEngine? { chat?.engine }
    }
    private var items: [Item] = []
    private var aspect: CGFloat = 10 / 16
    private var cards: [Int: BrowserAgentPreviewCard] = [:]
    private var positions: [Int: (top: NSLayoutConstraint, height: NSLayoutConstraint)] = [:]
    private let chip = MistButton(title: "", size: .regular)
    private var popover: NSPopover?
    private var overflow: Overflow?
    private(set) var visibleCards: [BrowserAgentPreviewCard] = []
    private(set) var visibleTabIds: [Int] = []
    var onSelect: ((Tab) -> Void)?
    var onClose: ((Int) -> Void)?
    var onContentChanged: (() -> Void)?
    var onVisibilityChanged: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isHidden: Bool {
        didSet {
            if oldValue != isHidden {
                if isHidden { popover?.close() }
                superview?.needsLayout = true
                onVisibilityChanged?()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chip.setAccessibilityLabel(NSLocalizedString("browser.agent.preview.more", value: "More tab previews",
            comment: "Browser Agent preview - Accessibility label of the chip listing tab previews that don't fit"))
        chip.onClick = { [weak self] in self?.showOverflow() }
        addSubview(chip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ items: [Item], aspect: CGFloat) {
        self.items = items
        self.aspect = aspect
        superview?.needsLayout = true
        if let size = superview?.bounds.size { layoutCards(pageSize: size) }
    }

    func card(for tabId: Int) -> BrowserAgentPreviewCard? { cards[tabId] }

    func setImage(_ image: CGImage, for tabId: Int) {
        guard let index = items.firstIndex(where: { $0.tab.guid == tabId && $0.chat == nil }) else { return }
        items[index].still = image
        cards[tabId]?.setImage(image)
    }

    func layoutCards(pageSize: CGSize) {
        let chipHeight = MistButton.Size.regular.height
        // Every card has the same size; the folds come from the height that fits.
        let size = BrowserAgentPreviewLayout.cardSize(pageWidth: pageSize.width, aspect: aspect, spacing: 8, chipHeight: chipHeight)
        let width = size.width
        let heights = Array(repeating: size.height, count: items.count)
        let narrow = BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: pageSize.width,
            cardLeading: pageSize.width - 16 - width) == 0
        let count = BrowserAgentPreviewState.visibleCardCount(cardHeights: heights, spacing: 8, chipHeight: chipHeight,
            availableHeight: pageSize.height - 32, narrow: narrow)
        let height = heights.prefix(count).reduce(0, +) + CGFloat(max(0, count - 1)) * 8
            + (count < items.count ? 8 + chipHeight : 0)
        frame = CGRect(x: pageSize.width - 16 - width,
            y: superview?.isFlipped == true ? 16 : pageSize.height - 16 - height,
            width: width, height: height)
        let visible = Array(items.prefix(count))
        let wanted = Set(visible.map { $0.tab.guid })
        for (id, card) in cards where !wanted.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
            positions[id] = nil
        }
        visibleCards = []
        visibleTabIds = []
        var y: CGFloat = 0
        for (index, item) in visible.enumerated() {
            let card = cards[item.tab.guid] ?? BrowserAgentPreviewCard()
            if card.superview !== self {
                addSubview(card)
                cards[item.tab.guid] = card
                card.translatesAutoresizingMaskIntoConstraints = false
                let top = card.topAnchor.constraint(equalTo: topAnchor)
                let height = card.heightAnchor.constraint(equalToConstant: heights[index])
                positions[item.tab.guid] = (top, height)
                NSLayoutConstraint.activate([top, height,
                    card.widthAnchor.constraint(equalTo: widthAnchor),
                    card.trailingAnchor.constraint(equalTo: trailingAnchor)])
            }
            card.onClose = { [weak self] in self?.onClose?(item.tab.guid) }
            card.bodyView.onClick = { [weak self, weak tab = item.tab] in
                if let tab { self?.onSelect?(tab) }
            }
            card.onContentChanged = { [weak self] in self?.onContentChanged?() }
            card.show(tab: item.tab, live: item.mount == .live, chat: item.chat)
            card.setImage(item.still)
            positions[item.tab.guid]?.top.constant = y
            positions[item.tab.guid]?.height.constant = heights[index]
            visibleCards.append(card)
            visibleTabIds.append(item.tab.guid)
            y += heights[index] + 8
        }
        let folded = Array(items.dropFirst(count))
        chip.isHidden = folded.isEmpty
        if !folded.isEmpty {
            chip.title = "+\(folded.count.formatted())"
            let chipWidth = chip.intrinsicContentSize.width
            chip.frame = CGRect(x: width - chipWidth, y: y, width: chipWidth, height: chipHeight)
            y += 8 + chipHeight
        }
        layoutSubtreeIfNeeded()
        refreshOverflow(folded)
    }

    private func showOverflow() {
        let list = Overflow()
        list.onSelect = { [weak self] tab in self?.popover?.close(); self?.onSelect?(tab) }
        list.onClose = { [weak self] id in self?.onClose?(id) }
        list.loadViewIfNeeded()
        list.view.subtreeThemeSource = chip.themeStateProvider
        overflow = list
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = list
        self.popover = popover
        refreshOverflow(Array(items.dropFirst(visibleCards.count)))
        guard !chip.isHidden else { return }
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .minY)
    }

    private func refreshOverflow(_ tabs: [Item]) {
        if tabs.isEmpty { popover?.close() }
        overflow?.update(tabs)
    }

    private final class Overflow: NSViewController {
        /// The list's margin above and below its rows.
        private static let padding: CGFloat = 4
        var onSelect: ((Tab) -> Void)?
        var onClose: ((Int) -> Void)?
        override func loadView() { view = NSView() }
        func update(_ tabs: [Item]) {
            view.subviews.forEach { $0.removeFromSuperview() }
            let height = MistSidebarCellView.rowHeight
            for (index, item) in tabs.enumerated() {
                let tab = item.tab
                let row = Row(tab: tab, engine: item.engine)
                row.onSelect = { [weak self, weak tab] in if let tab { self?.onSelect?(tab) } }
                row.onClose = { [weak self] in self?.onClose?(tab.guid) }
                row.frame = CGRect(x: 0, y: Self.padding + CGFloat(tabs.count - index - 1) * height, width: 280, height: height)
                view.addSubview(row)
            }
            preferredContentSize = CGSize(width: 280, height: max(1, CGFloat(tabs.count) * height + 2 * Self.padding))
        }
    }

    /// A folded tab as a kit sidebar row: its favicon and title, the hover fill under the pointer, and a close button.
    private final class Row: MistRowView {
        var onSelect: (() -> Void)?
        var onClose: (() -> Void)?
        private let cell = MistSidebarCellView()
        private let close = MistIconButton(symbol: "xmark", title: NSLocalizedString("browser.agent.preview.close",
            value: "Close tab preview", comment: "Browser Agent preview - Close button accessibility label"))
        private var binding: AnyCancellable?
        init(tab: Tab, engine: DrifterEngine?) {
            super.init(style: .sidebar)
            let icon = NSImageView()
            icon.phi.setContentTintColor(.textSecondary)
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
            close.onClick = { [weak self] in self?.onClose?() }
            [cell, close].forEach { addSubview($0) }
            binding = tab.$title.combineLatest(tab.$liveFaviconData, tab.$cachedFaviconData)
                .receive(on: DispatchQueue.main).sink { [cell] text, live, cached in
                    icon.image = engine.map(previewEngineImage) ?? (live ?? cached).flatMap(NSImage.init(data:))
                        ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                    cell.configure(symbol: nil, leading: icon, title: text)
                }
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(tab.title)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let inset = backgroundInsets.width
            let side = MistIconButton.side
            close.frame = NSRect(x: bounds.width - inset - 4 - side, y: (bounds.height - side) / 2, width: side, height: side)
            cell.frame = NSRect(x: inset, y: 0, width: max(0, close.frame.minX - inset), height: bounds.height)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            return close.frame.contains(local) ? close : self
        }
        override func mouseDown(with event: NSEvent) { onSelect?() }
        override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    }
}
