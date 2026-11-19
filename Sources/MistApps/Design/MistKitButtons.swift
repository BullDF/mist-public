import AppKit
import SwiftUI

// MARK: - SwiftUI

/// The kit's capsule buttons: primary in the theme color with a white label, secondary in the chip fill. Pressed is a
/// shade deeper, disabled fades, and an enabled one shows the pointing hand inside a `MistKitHostingView`.
struct MistButtonStyle: ButtonStyle {
    enum Role { case primary, secondary }
    enum Size {
        /// Page actions.
        case large
        /// Toolbars and inline actions.
        case regular

        var height: CGFloat { self == .large ? 32 : 28 }
        var padding: CGFloat { self == .large ? 16 : 14 }
    }

    var role: Role = .secondary
    var size: Size = .large

    func makeBody(configuration: Configuration) -> some View {
        MistButtonBody(configuration: configuration, role: role, size: size)
    }

    static func fill(_ role: Role, pressed: Bool) -> ThemedColor {
        switch role {
        case .primary: pressed ? .themeButtonBackgroundOnHover : .themeButtonBackground
        case .secondary: pressed ? .mistSelectedFill : .mistChipFill
        }
    }
    static func ink(_ role: Role) -> ThemedColor { role == .primary ? .themeButtonForeground : .textPrimary }
}

extension ButtonStyle where Self == MistButtonStyle {
    static var mistPrimary: MistButtonStyle { MistButtonStyle(role: .primary) }
    static var mistSecondary: MistButtonStyle { MistButtonStyle(role: .secondary) }
    static func mist(_ role: MistButtonStyle.Role, size: MistButtonStyle.Size) -> MistButtonStyle {
        MistButtonStyle(role: role, size: size)
    }
}

private struct MistButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: MistButtonStyle.Role
    let size: MistButtonStyle.Size
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(MistTextStyle.button.font)
            .themedForeground(MistButtonStyle.ink(role))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .background { Capsule().themedFill(MistButtonStyle.fill(role, pressed: configuration.isPressed)) }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : MistKit.disabledOpacity)
            .mistPointingHand()
    }
}

/// A borderless symbol button for toolbars: a circle of the hover fill under the pointer, dimmed while pressed. An
/// enabled one shows the pointing hand inside a `MistKitHostingView`, like every kit button.
struct MistIconButtonStyle: ButtonStyle {
    var side: CGFloat = 24
    func makeBody(configuration: Configuration) -> some View { MistIconButtonBody(configuration: configuration, side: side) }
}

extension ButtonStyle where Self == MistIconButtonStyle {
    static var mistIcon: MistIconButtonStyle { MistIconButtonStyle() }
}

private struct MistIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let side: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13))
            .themedForeground(.textSecondary)
            .frame(width: side, height: side)
            .background { Circle().themedFill(.mistHoverFill).opacity(hovered && enabled ? 1 : 0) }
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? MistKit.pressedOpacity : 1) : MistKit.disabledOpacity)
            .onHover { hovered = $0 }
            .mistPointingHand()
    }
}

/// A clickable kit row, with the same hover and pressed states as other lists.
struct MistRowButtonStyle: ButtonStyle {
    var style: MistRowStyle
    init(_ style: MistRowStyle = .list) { self.style = style }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.mistRow(style, selected: configuration.isPressed).mistPointingHand()
    }
}

/// A clickable card, padded and outlined by its card style.
struct MistCardButtonStyle: ButtonStyle {
    var style: MistCardStyle
    init(_ style: MistCardStyle = .inner) { self.style = style }
    func makeBody(configuration: Configuration) -> some View {
        MistCardButtonBody(configuration: configuration, style: style)
    }
}

private struct MistCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: MistCardStyle
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        configuration.label.padding(style.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                MistCardSurface(style: style).overlay {
                    shape.themedFill(configuration.isPressed ? .mistSelectedFill : .mistHoverFill)
                        .opacity(configuration.isPressed || hovered ? 1 : 0)
                }
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .mistPointingHand()
    }
}

// MARK: - AppKit

/// `MistButtonStyle` for AppKit pages: a capsule `NSButton` drawn by its layer, since system bezel tints don't follow
/// the theme. Colors bind through `CALayer` and are re-resolved on theme changes.
class MistButton: NSButton, MistPointingHandControl {
    /// A symbol as the kit's buttons draw it, in the label's size and weight; tint it with the label's ink.
    static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    typealias Role = MistButtonStyle.Role
    typealias Size = MistButtonStyle.Size
    let role: Role
    let size: Size
    var onClick: (() -> Void)?
    private var pressed = false { didSet { updateFill() } }
    private var symbolName: String?
    private var circle = false

    /// An icon-only capsule or circle, with its title available as a tooltip and accessibility label.
    convenience init(symbol: String, title: String, role: Role = .secondary, size: Size = .large, circle: Bool = false) {
        self.init(title: "", role: role, size: size)
        symbolName = symbol
        self.circle = circle
        setCustomTooltip(title)
        setAccessibilityLabel(title)
        updateTitle()
    }

    init(title: String, role: Role = .secondary, size: Size = .large) {
        self.role = role
        self.size = size
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(run)
        self.title = title
        let view: NSView = self
        _ = view.phi.subscribe { [weak self] _, _ in self?.updateTitle() }
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override class var cellClass: AnyClass? {
        get { MistButtonCell.self }
        set {}
    }
    override var title: String { didSet { updateTitle() } }
    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : MistKit.disabledOpacity
            pointingHandDidChange()
        }
    }
    var showsPointingHand: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        NSSize(width: symbolName == nil ? ceil(attributedTitle.size().width) + size.padding * 2 : size.height + (circle ? 0 : 8), height: size.height)
    }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func resetCursorRects() { addPointingHandCursorRect() }
    /// The cell's tracking highlight never reaches the layer, so the press shows around the tracking loop that
    /// `super.mouseDown` runs.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        pressed = true
        super.mouseDown(with: event)
        pressed = false
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    private var updatingTitle = false
    private func updateTitle() {
        guard !updatingTitle else { return }
        updatingTitle = true
        defer { updatingTitle = false }
        let ink = MistButtonStyle.ink(role).resolve(theme: themeStateProvider.currentTheme, appearance: currentAppearance)
        if let symbolName {
            image = Self.symbolImage(symbolName)
            imagePosition = .imageOnly
            // The button fades as a whole when disabled; a dimmed image would fade twice.
            (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            contentTintColor = ink
        }
        attributedTitle = NSAttributedString(string: title, attributes: [.font: MistTextStyle.button.nsFont, .foregroundColor: ink])
        invalidateIntrinsicContentSize()
    }
    private func updateFill() { phiLayer?.setBackgroundColor(MistButtonStyle.fill(role, pressed: pressed)) }
    @objc private func run() { onClick?() }

    /// Draws the button's own title: a disabled cell passes a dimmed copy, which would fade on top of the button's fade.
    private final class MistButtonCell: NSButtonCell {
        override func drawTitle(_ dimmed: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
            let title = attributedTitle
            let size = title.size()
            let rect = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            title.draw(in: rect.integral)
            return rect
        }
    }
}

/// `MistIconButtonStyle` for AppKit pages: a symbol with a circle of the hover fill under the pointer, and the pointing
/// hand while enabled. The circle widens the frame only: the alignment rect stays the symbol's, so a toolbar lays out
/// as with plain image buttons, and the whole circle takes clicks. The symbol is an image view, so it centers in the
/// circle and can run symbol effects.
class MistIconButton: NSButton, MistPointingHandControl {
    static let side: CGFloat = 24
    var onClick: (() -> Void)?
    let symbol = NSImageView()
    private let shade = NSView()
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { updateShade() } } }

    init(symbol name: String, title: String) {
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        target = self
        action = #selector(run)
        setCustomTooltip(title)
        setAccessibilityLabel(title)
        wantsLayer = true
        // Sized by frame in `setFrameSize`, not anchors: the button's anchors follow its alignment rect, the symbol's.
        shade.wantsLayer = true
        shade.phiLayer?.setBackgroundColor(.mistHoverFill)
        shade.isHidden = true
        addSubview(shade)
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbol.imageScaling = .scaleNone
        symbol.phi.setContentTintColor(.textSecondary)
        symbol.setAccessibilityElement(false)
        addSubview(symbol)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     symbol.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { symbol.image?.alignmentRect.size ?? .zero }
    override var alignmentRectInsets: NSEdgeInsets {
        let size = intrinsicContentSize
        let vertical = max(0, Self.side - size.height) / 2, horizontal = max(0, Self.side - size.width) / 2
        return NSEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
    override var isEnabled: Bool { didSet { symbol.isEnabled = isEnabled; updateShade(); pointingHandDidChange() } }
    var showsPointingHand: Bool { isEnabled }
    override func resetCursorRects() { addPointingHandCursorRect() }
    /// A toggle keeps its selected shade and primary ink after the pointer leaves.
    override var state: NSControl.StateValue { didSet { updateShade() } }
    /// Only a toggle shows its state: a momentary button's cell flips its state on every click too, which left the
    /// selected shade on after every other click.
    private var toggles = false
    override func setButtonType(_ type: NSButton.ButtonType) {
        super.setButtonType(type)
        toggles = ![.momentaryLight, .momentaryChange, .momentaryPushIn].contains(type)
        updateShade()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = min(bounds.width, bounds.height)
        shade.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        shade.layer?.cornerRadius = side / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        readHover()
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); readHover() }
    override func mouseMoved(with event: NSEvent) { readHover() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false }
    // A button hidden or moved while under the pointer gets no exit.
    override func viewDidHide() { super.viewDidHide(); hovered = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false }
    /// A rebuilt area sends no exit for a pointer it already lost, as when a layout moves the button out from under
    /// it (Mail's sidebar toggle as the sidebar collapses), and the pointer may leave while the button is pressed.
    /// The area also fires under a view laid over the button (Mail's recipient suggestions), so the hover is hit-tested.
    private func readHover() {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        hovered = NSApp.isActive && isFrontmost(at: window.mouseLocationOutsideOfEventStream)
    }
    private func updateShade() {
        let selected = toggles && state == .on
        shade.phiLayer?.setBackgroundColor(selected ? .mistSelectedFill : .mistHoverFill)
        symbol.phi.setContentTintColor(selected ? .textPrimary : .textSecondary)
        shade.isHidden = !selected && !(hovered && isEnabled)
    }

    /// The cell's tracking highlight never reaches the control, so the press shows around the tracking loop that
    /// `super.mouseDown` runs. A trackpad tap's down and up arrive together and end that loop before a frame is
    /// drawn, so the button fades back from dimmed after release. The hover is read again after the loop, and a
    /// click flips a toggle's state in its cell, past `state`'s observer.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        layer?.removeAnimation(forKey: "press")
        alphaValue = MistKit.pressedOpacity
        super.mouseDown(with: event)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = MistKit.pressedOpacity
        fade.toValue = 1
        fade.duration = 0.25
        alphaValue = 1
        layer?.add(fade, forKey: "press")
        readHover()
        updateShade()
    }
    @objc private func run() { onClick?() }
}

/// A pop-up or pull-down button as a chip: borderless on a chip-fill capsule, its title and arrow inset from the ends,
/// with the pointing hand while enabled.
final class MistPopUpButton: NSPopUpButton, MistPointingHandControl {
    static let height: CGFloat = 28
    private static let inset: CGFloat = 10

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        cell = MistPopUpButtonCell(textCell: "", pullsDown: flag)
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        phiLayer?.setBackgroundColor(.mistChipFill)
    }
    convenience init(pullsDown: Bool = false) { self.init(frame: .zero, pullsDown: pullsDown) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + Self.inset * 2, height: Self.height)
    }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : MistKit.disabledOpacity; pointingHandDidChange() } }
    var showsPointingHand: Bool { isEnabled }
    override func resetCursorRects() { addPointingHandCursorRect() }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private final class MistPopUpButtonCell: NSPopUpButtonCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            super.drawingRect(forBounds: rect.insetBy(dx: MistPopUpButton.inset, dy: 0))
        }
    }
}
