import AppKit
import UniformTypeIdentifiers

final class MistAttachmentStrip: NSScrollView {
    private let strip = NSView()
    var onOpen: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        documentView = strip
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ attachments: [AgentAttachment], onRemove: @escaping (Int) -> Void) {
        strip.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for (index, attachment) in attachments.enumerated() {
            let chip: NSView
            let width: CGFloat
            let open: () -> Void = { [weak self] in self?.onOpen?(index) }
            let remove = { onRemove(index) }
            switch attachment {
            case let .image(image):
                chip = MistAttachmentThumbnail(image: NSImage(data: image.data), onOpen: open, onRemove: remove)
                width = 56
            case let .file(file):
                chip = MistAttachmentFileCard(file: file, onOpen: open, onRemove: remove)
                width = MistAttachmentFileCard.size.width
            }
            chip.frame = NSRect(x: x, y: 0, width: width, height: 56)
            strip.addSubview(chip)
            x += width + 8
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(0, x - 8), height: 56)
    }
}

class MistAttachmentThumbnail: NSView, MistPointingHandControl {
    private let removeButton = NSButton()
    private let onRemove: (() -> Void)?
    private let onOpen: () -> Void
    private var hoverArea: NSTrackingArea?
    /// Under the pointer and in front: a tracking area also fires under a view laid over it (Mail's recipient
    /// suggestions over compose's attachments), so each enter and move is hit-tested.
    private(set) var isHovered = false { didSet { if isHovered != oldValue { hoverDidChange() } } }
    /// The right-click menu; Mail's attachments use it.
    var contextMenu: (() -> NSMenu)?
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.5
            removeButton.isEnabled = isEnabled
            pointingHandDidChange()
        }
    }
    var showsPointingHand: Bool { isEnabled }

    /// Without `onRemove`, the attachment has no remove button.
    init(image: NSImage?, onOpen: @escaping () -> Void, onRemove: (() -> Void)?, removeLabel: String? = nil) {
        self.onRemove = onRemove
        self.onOpen = onOpen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = MistKit.Radius.innerCard
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resizeAspectFill
        phiLayer?.setBackgroundColor(.mistChipFill)
        phiLayer?.setBorderColor(.mistHairline)
        if onRemove != nil {
            removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            removeButton.isBordered = false
            removeButton.contentTintColor = .white
            removeButton.wantsLayer = true
            removeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            removeButton.layer?.cornerRadius = 9
            removeButton.frame = NSRect(x: 36, y: 36, width: 18, height: 18)
            removeButton.target = self
            removeButton.action = #selector(removeAttachment)
            removeButton.setAccessibilityLabel(removeLabel ?? NSLocalizedString("browser.newTabPage.claudeCode.removeImage", value: "Remove Image", comment: "Claude Code - Accessibility label for removing an attached image"))
            // Keep the control in the accessibility tree even outside hover.
            removeButton.alphaValue = 0
            addSubview(removeButton)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(AgentChatStrings.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        layer?.borderWidth = MistKit.borderWidth
        removeButton.frame.origin.x = bounds.width - 20
    }
    override func resetCursorRects() { addPointingHandCursorRect() }
    // A file card's icon and labels are controls that would take its click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit == nil || hit === removeButton ? hit : self
    }
    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenu else { return super.menu(for: event) }
        return isEnabled ? contextMenu() : nil
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onOpen(); return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = isFrontmost(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { isHovered = isFrontmost(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func viewDidHide() { super.viewDidHide(); isHovered = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); isHovered = false }
    func hoverDidChange() { removeButton.alphaValue = isHovered ? 1 : 0 }
    @objc private func removeAttachment() { onRemove?() }
}

/// A file attachment as a card: its icon, its name, and its kind (and size, if given) below.
/// The composers and Mail share it.
final class MistAttachmentFileCard: MistAttachmentThumbnail {
    static let size = NSSize(width: 200, height: 56)
    private static let textWidth: CGFloat = 134
    override var isEnabled: Bool { didSet { updateFill() } }

    convenience init(file: AgentFileAttachment, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.init(icon: NSWorkspace.shared.icon(forFile: file.url.path), name: file.url.lastPathComponent,
            kind: UTType(filenameExtension: file.url.pathExtension)?.localizedDescription, onOpen: onOpen, onRemove: onRemove)
    }

    init(icon: NSImage, name: String, kind: String?, size: String? = nil, onOpen: @escaping () -> Void, onRemove: (() -> Void)?,
         removeLabel: String = NSLocalizedString("browser.newTabPage.claudeCode.removeFile", value: "Remove File", comment: "Claude Code - Accessibility label for removing an attached file")) {
        super.init(image: nil, onOpen: onOpen, onRemove: onRemove, removeLabel: removeLabel)
        setAccessibilityLabel(name)
        updateFill()
        let iconView = MistIconTileView(.icon(icon), side: 32)
        iconView.frame = NSRect(x: 12, y: 12, width: 32, height: 32)
        addSubview(iconView, positioned: .below, relativeTo: nil)
        let detailFont = MistTextStyle.secondary.nsFont
        // A label draws its text 2 pt in from each side.
        let detail = Self.detail(kind: kind, size: size, width: Self.textWidth - 4, font: detailFont)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.applyMistStyle(.rowHeadline)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let nameHeight = ceil(nameLabel.intrinsicContentSize.height)
        let detailHeight = ceil(NSTextField.mistLabel(style: .secondary).intrinsicContentSize.height)
        let bottom = (Self.size.height - nameHeight - detailHeight - 2) / 2
        nameLabel.frame = NSRect(x: 54, y: detail == nil ? (Self.size.height - nameHeight) / 2 : bottom + detailHeight + 2, width: Self.textWidth, height: nameHeight)
        addSubview(nameLabel, positioned: .below, relativeTo: nil)
        if let detail {
            let label = NSTextField(labelWithString: detail)
            label.applyMistStyle(.secondary)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 54, y: bottom, width: Self.textWidth, height: detailHeight)
            addSubview(label, positioned: .below, relativeTo: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hoverDidChange() { super.hoverDidChange(); updateFill() }
    private func updateFill() { phiLayer?.setBackgroundColor(isHovered && isEnabled ? .mistHoverFill : .clear) }

    /// "kind · size"; a kind too long to fit is shortened so the size stays whole.
    private static func detail(kind: String?, size: String?, width: CGFloat, font: NSFont) -> String? {
        guard let kind else { return size }
        guard let size else { return kind }
        let suffix = " · " + size
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: [.font: font]).width <= width }
        if fits(kind + suffix) { return kind + suffix }
        var head = kind
        while !head.isEmpty, !fits(head + "…" + suffix) { head.removeLast() }
        return head.trimmingCharacters(in: .whitespaces) + "…" + suffix
    }
}

final class MistComposerCard: NSView {
    var acceptsAttachments: (() -> Bool)?
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let surface = MistCardView(style: .input)
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        layer?.cornerRadius = MistKit.Radius.input
        layer?.cornerCurve = .continuous
        updateBorder()
        registerForDraggedTypes(ClaudeCodeImageNormalizer.pasteboardTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private(set) var isDropTarget = false

    /// Outlines the card in the theme color while an attachment is dragged over the composer.
    func setDropTarget(_ highlighted: Bool) {
        guard highlighted != isDropTarget else { return }
        isDropTarget = highlighted
        updateBorder()
    }
    private func updateBorder() {
        if isDropTarget {
            layer?.borderWidth = 2
            phiLayer?.setBorderColor(.themeColor)
        } else {
            layer?.borderWidth = 0
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = acceptsAttachments?() == true
        setDropTarget(accepts)
        return accepts ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropTarget(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropTarget(false)
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}
