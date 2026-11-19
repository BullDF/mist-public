import AppKit

extension NSMenu {
    var mistPositioningItem: NSMenuItem? {
        update()
        return items.first { $0.state == .on } ?? items.first { $0.isEnabled && !$0.isSeparatorItem }
    }
}

/// A menu on the kit's chip capsule, with primary title ink and secondary symbols. A symbol that's the only label
/// takes the primary ink, like the kit's icon-only `MistButton`.
final class MistMenuButton: NSButton, MistPointingHandControl {
    /// The SF Symbol drawn with the title, as the kit's buttons draw symbols.
    var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            image = symbolName.flatMap { MistButton.symbolImage($0) }
        }
    }
    private var primarySymbolInk: Bool?
    // Added to the cell's width; the chevron also overlaps the title's trailing padding.
    static let chevronSpace: CGFloat = 14
    static let horizontalInset: CGFloat = 10
    private let chevron = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateHoverBackground() } }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : MistKit.disabledOpacity; updateHoverBackground(); pointingHandDidChange() }
    }
    var showsPointingHand: Bool { isEnabled }
    override func resetCursorRects() { addPointingHandCursorRect() }
    override var imagePosition: NSControl.ImagePosition { didSet { updateChevron(); updateSymbolInk() } }
    override var title: String { didSet { updateTitle() } }
    private var updatingTitle = false

    override class var cellClass: AnyClass? {
        get { MistMenuButtonCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 13, weight: .medium)
        (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        alignment = .left
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        addSubview(chevron)
        let view: NSView = self
        _ = view.phi.subscribe { [weak self] _, _ in self?.updateTitle() }
        updateHoverBackground()
        updateSymbolInk()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Match the tracking and themed-layer pattern used by PeekControlButton.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovered = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovered = false }
    override func viewDidHide() { super.viewDidHide(); isHovered = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); isHovered = false }

    private func updateHoverBackground() {
        phiLayer?.setBackgroundColor(isHovered && isEnabled ? .mistSelectedFill : .mistChipFill)
    }

    private func updateSymbolInk() {
        let primary = imagePosition == .imageOnly
        guard primary != primarySymbolInk else { return }
        primarySymbolInk = primary
        phi.setContentTintColor(primary ? .textPrimary : .textSecondary)
    }

    private func updateChevron() {
        let visible = imagePosition != .imageOnly
        chevron.isHidden = !visible
        (cell as? MistMenuButtonCell)?.showsChevron = visible
        invalidateIntrinsicContentSize()
    }
    private func updateTitle() {
        guard !updatingTitle else { return }
        updatingTitle = true
        defer { updatingTitle = false }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: ThemedColor.textPrimary.resolve(theme: themeStateProvider.currentTheme, appearance: currentAppearance)])
        invalidateIntrinsicContentSize()
    }

    override var contentTintColor: NSColor? {
        didSet { chevron.contentTintColor = contentTintColor }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let size = chevron.image?.size ?? .zero
        chevron.frame = NSRect(x: bounds.width - Self.horizontalInset - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                               width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === chevron ? self : hit
    }
}

private final class MistMenuButtonCell: NSButtonCell {
    var showsChevron = true
    override var cellSize: NSSize {
        var size = super.cellSize
        if imagePosition == .imageOnly { return NSSize(width: 28, height: 28) }
        size.width += MistMenuButton.horizontalInset * 2
        if showsChevron { size.width += MistMenuButton.chevronSpace }
        return size
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = imagePosition == .imageOnly ? cellFrame : cellFrame.insetBy(dx: MistMenuButton.horizontalInset, dy: 0)
        if showsChevron { frame.size.width -= MistMenuButton.chevronSpace }
        super.drawInterior(withFrame: frame, in: controlView)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        // The control applies the disabled opacity once to the whole chip.
        super.drawTitle(attributedTitle, withFrame: frame, in: controlView)
    }
}
