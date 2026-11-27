import AppKit

// AppKit counterparts of the kit's SwiftUI views, for pages built from AppKit views. Colors bind through the AppKit
// base classes (`CALayer`, `NSTextField`, `NSImageView`), so a caller rebinding one replaces the kit's binding
// rather than fighting it.

// MARK: - Surfaces

/// `MistCard` for AppKit pages: fill, hairline and the elevation's two shadows. Content goes in `contentView`, which
/// clips to the rounded shape.
final class MistCardView: NSView {
    let style: MistCardStyle
    let contentView = NSView()
    /// One per shadow, widest lowest; each draws its shadow under an opaque fill of the card's shape.
    private let shadowLayers: [CALayer]
    private let surface = CALayer()
    private let shadowOnly: Bool

    /// `shadowOnly` leaves the surface clear and masks each shadow outside the card, for content with a live hole.
    init(style: MistCardStyle = .content, shadowOnly: Bool = false) {
        self.style = style
        self.shadowOnly = shadowOnly
        let shadows = Array(style.elevation.shadows.reversed())
        shadowLayers = shadows.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        for (shadowLayer, shadow) in zip(shadowLayers, shadows) {
            shadowLayer.cornerRadius = style.radius
            shadowLayer.cornerCurve = .continuous
            if !shadowOnly { shadowLayer.phi(source: self).setBackgroundColor(.mistCardFill) }
            shadowLayer.shadowOpacity = 1
            shadowLayer.shadowRadius = shadow.blur / 2
            shadowLayer.shadowOffset = CGSize(width: 0, height: -shadow.y)
            shadowLayer.phi(source: self)[\.shadowColor] = Mapper { _, appearance in
                NSColor.black.withAlphaComponent(shadow.opacity(appearance)).cgColor
            }.optional
            layer?.addSublayer(shadowLayer)
        }
        surface.cornerRadius = style.radius
        surface.cornerCurve = .continuous
        surface.phi(source: self).setBackgroundColor(.mistCardFill)
        surface.phi(source: self).setBorderColor(.mistHairline)
        if !shadowOnly { layer?.addSublayer(surface) }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = style.radius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     contentView.topAnchor.constraint(equalTo: topAnchor),
                                     contentView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(roundedRect: bounds, cornerWidth: style.radius, cornerHeight: style.radius, transform: nil)
        for shadowLayer in shadowLayers {
            shadowLayer.frame = bounds
            shadowLayer.shadowPath = path
            if shadowOnly {
                let mask = CAShapeLayer()
                // A mask must cover the shadow's overflow as well as the card's bounds.
                mask.frame = bounds.insetBy(dx: -80, dy: -80)
                let outside = CGMutablePath()
                outside.addRect(mask.bounds)
                outside.addRoundedRect(in: bounds.offsetBy(dx: 80, dy: 80), cornerWidth: style.radius, cornerHeight: style.radius)
                mask.path = outside
                mask.fillRule = .evenOdd
                shadowLayer.mask = mask
            }
        }
        surface.frame = bounds
        surface.borderWidth = MistKit.borderWidth
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// A table or outline row's background, for `tableView(_:rowViewForRow:)`: rounded and inset, the hover fill under
/// the pointer and the gray selected fill when selected. Never the accent, and never emphasized, so the row's themed
/// text stays readable.
class MistRowView: NSTableRowView {
    /// Nonselectable rows can opt out of the pointer highlight.
    var showsHover = true { didSet { needsDisplay = true } }
    let style: MistRowStyle
    /// How far the background sits in from the row's edges.
    var backgroundInsets = NSSize(width: 8, height: 1) { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(style: MistRowStyle) {
        self.style = style
        super.init(frame: .zero)
        let view: NSView = self
        _ = view.phi.subscribe { [weak self] _, _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEmphasized: Bool { get { false } set {} }
    override func drawBackground(in dirtyRect: NSRect) {
        if showsHover, hovered, !isSelected { fill(.mistHoverFill) }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        fill(.mistSelectedFill)
    }
    private func fill(_ color: ThemedColor) {
        color.resolve(theme: themeStateProvider.currentTheme, appearance: currentAppearance).setFill()
        let rect = bounds.insetBy(dx: backgroundInsets.width, dy: backgroundInsets.height)
        NSBezierPath(roundedRect: rect, xRadius: style.radius, yRadius: style.radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        readHover()
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); readHover() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false }
    // A reused or hidden row under the pointer gets no exit.
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false }
    override func viewDidHide() { super.viewDidHide(); hovered = false }
    /// Scrolling rebuilds the area as rows slide under a still pointer, and a rebuilt area sends no exit for a
    /// pointer it already lost, so every row the pointer crossed stayed shaded: the hover is read from the pointer.
    private func readHover() {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        hovered = NSApp.isActive && isFrontmost(at: window.mouseLocationOutsideOfEventStream)
    }
}

/// A sidebar row's content, for an outline or table using `MistRowView(style: .sidebar)`: an optional symbol or custom
/// leading view, the title, and a trailing count or spinner.
final class MistSidebarCellView: NSTableCellView {
    static let rowHeight: CGFloat = 32
    enum Trailing { case none, count(String), spinner }

    private let stack = NSStackView()
    private let icon = NSImageView()
    private let title = NSTextField.mistLabel(style: .rowTitle)
    private let count = NSTextField.mistLabel(style: .count)
    private let spinner = NSProgressIndicator()
    private var leading: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        icon.phi.setContentTintColor(.textSecondary)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        stack.setViews([icon, title], in: .leading)
        stack.setViews([count, spinner], in: .trailing)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        textField = title
        imageView = icon
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `leading` takes the symbol's place (an account's status dot), centered in its column so titles stay aligned.
    func configure(symbol: String?, leading: NSView? = nil, title text: String, titleStyle: MistTextStyle = .rowTitle, trailing: Trailing = .none) {
        title.applyMistStyle(titleStyle)
        if self.leading !== leading {
            self.leading?.removeFromSuperview()
            self.leading = leading
            if let leading {
                addSubview(leading)
                leading.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([leading.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                                             leading.centerYAnchor.constraint(equalTo: icon.centerYAnchor)])
            }
        }
        icon.image = leading == nil ? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } : nil
        icon.isHidden = leading == nil && icon.image == nil
        title.stringValue = text
        switch trailing {
        case .none:
            count.isHidden = true
            spinner.isHidden = true
        case let .count(value):
            count.stringValue = value
            count.isHidden = false
            spinner.isHidden = true
        case .spinner:
            count.isHidden = true
            spinner.isHidden = false
        }
        if spinner.isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
    }
}

/// `MistDot` for AppKit: the unread dot, or a status dot in another color.
final class MistDotView: NSView {
    var color: ThemedColor { didSet { phiLayer?.setBackgroundColor(color) } }

    init(color: ThemedColor = .themeColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: MistKit.dotSide, height: MistKit.dotSide))
        wantsLayer = true
        layer?.cornerRadius = MistKit.dotSide / 2
        phiLayer?.setBackgroundColor(color)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: MistKit.dotSide, height: MistKit.dotSide) }
}

/// `MistIconTile` for AppKit: a rounded chip-fill square holding a symbol, an app logo, a file icon or a thumbnail.
final class MistIconTileView: NSView {
    let side: CGFloat
    private let imageView = NSImageView()

    init(_ content: MistIconTile.Content, side: CGFloat = MistIconTile.defaultSide) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = MistKit.Radius.tile(side)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        phiLayer?.setBackgroundColor(.mistChipFill)
        addSubview(imageView)
        setContent(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func setContent(_ content: MistIconTile.Content) {
        layer?.contents = nil
        imageView.isHidden = false
        switch content {
        case let .symbol(name):
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: side * 0.45, weight: .regular))
            imageView.imageScaling = .scaleNone
            imageView.phi.setContentTintColor(.textPrimary)
            imageView.frame = bounds
        case let .glyph(image):
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.phi.setContentTintColor(.textPrimary)
            let inset = side * (1 - MistIconTile.glyphFraction) / 2
            imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        case let .icon(image), let .logo(image):
            imageView.image = image
            imageView.phi[\.contentTintColor] = nil
            imageView.contentTintColor = nil
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let inset: CGFloat
            if case .logo = content { inset = side * (1 - MistIconTile.logoFraction) / 2 } else { inset = side * 0.12 }
            imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        case let .mark(image, template, scale):
            let mark = image.copy() as? NSImage
            mark?.isTemplate = template
            imageView.image = mark
            if template {
                imageView.phi.setContentTintColor(.textPrimary)
            } else {
                imageView.phi[\.contentTintColor] = nil
                imageView.contentTintColor = nil
            }
            imageView.imageScaling = .scaleProportionallyUpOrDown
            let inset = side * (1 - MistIconTile.logoFraction * scale) / 2
            imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        case let .thumbnail(image):
            imageView.isHidden = true
            layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer?.contentsGravity = .resizeAspectFill
        }
    }
}

/// `MistFieldWell` for AppKit: a text, search or token field in the chip fill, ringed in the theme color while it
/// edits, with an optional leading symbol. A click in the padding focuses the field. While it edits, its field editor
/// takes the kit's selection and caret (`MistFieldEditors`).
///
/// An unbezeled search field draws its magnifier over its text, so the well removes the field's search button and
/// draws the magnifier itself; the field keeps its cancel button.
final class MistFieldWellView: NSView {
    enum Shape { case capsule, rounded }
    static let height: CGFloat = 28
    let field: NSTextField
    private let shape: Shape
    private var isFocused = false

    init(_ field: NSTextField, shape: Shape = .rounded, symbol: String? = nil, height: CGFloat = MistFieldWellView.height) {
        self.field = field
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        phiLayer?.setBackgroundColor(.mistChipFill)
        updateBorder()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        let search = field.cell as? NSSearchFieldCell
        search?.searchButtonCell = nil
        let inset: CGFloat = shape == .capsule ? 12 : 8
        var leading = leadingAnchor
        var leadingInset = inset
        if let name = symbol ?? (search == nil ? nil : "magnifyingglass") {
            let icon = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage())
            icon.phi.setContentTintColor(.textTertiary)
            addSubview(icon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                                         icon.centerYAnchor.constraint(equalTo: centerYAnchor)])
            leading = icon.trailingAnchor
            leadingInset = 5
        }
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        // A label-like field draws its text 2 pt in.
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: height),
                                     field.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     field.leadingAnchor.constraint(equalTo: leading, constant: leadingInset - 2),
                                     field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset - 4))])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = shape == .capsule ? bounds.height / 2 : MistKit.Radius.field
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setFocused(false)
        MistFieldEditors.claim(self, owns: { [weak field] in field?.currentEditor() === $0 },
                               focusChanged: { [weak self] in self?.setFocused($0) })
    }
    private func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        updateBorder()
    }
    /// The kit's outline at rest, the theme color's ring while the field has focus.
    private func updateBorder() {
        layer?.borderWidth = isFocused ? 2 : MistKit.borderWidth
        phiLayer?.setBorderColor(isFocused ? .mistFocusRing : .mistHairline)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

/// A selectable kit label (`NSTextField.mistWrappingLabel(_:style:selectable:)`): its selection takes the kit's color.
final class MistSelectableLabel: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MistFieldEditors.claim(self, owns: { [weak self] in self?.currentEditor() === $0 })
    }
}

// MARK: - Selection and field editors

extension NSTextView {
    /// Shows the selection on `mistTextSelection` instead of the macOS highlight color, which follows the accent
    /// color. A text view of the apps' own calls it when it becomes first responder and when its appearance changes,
    /// the times its selection can show in a new look; kit fields get it from `MistFieldEditors`.
    func applyMistSelection() {
        selectedTextAttributes = MistFieldEditors.selectionAttributes(theme: themeStateProvider.currentTheme,
                                                                      appearance: currentAppearance)
    }
}

/// The kit's look for field editors. While a kit field edits or selects, its window's field editor shows the selection
/// on `mistTextSelection` and the caret in the primary ink, like the composers'. A window shares one field editor
/// among all its fields, so once no kit field holds it, its selection goes back to the system's. The caret stays: Mist's
/// other native fields set the same ink when they start editing.
@MainActor final class MistFieldEditors {
    private final class Claim {
        weak var view: NSView?
        let owns: (NSTextView) -> Bool
        let focusChanged: (Bool) -> Void
        var focused = false
        init(view: NSView, owns: @escaping (NSTextView) -> Bool, focusChanged: @escaping (Bool) -> Void) {
            self.view = view
            self.owns = owns
            self.focusChanged = focusChanged
        }
    }

    private static let windows = NSMapTable<NSWindow, MistFieldEditors>.weakToStrongObjects()
    /// Views that restyle their window's editor on theme and appearance changes.
    private static let themed = NSHashTable<NSView>.weakObjects()
    private static let systemSelection: [NSAttributedString.Key: Any] = [.backgroundColor: NSColor.selectedTextBackgroundColor,
                                                                         .foregroundColor: NSColor.selectedTextColor]
    private weak var window: NSWindow?
    private let claims = NSMapTable<NSView, Claim>.weakToStrongObjects()
    private let styled = NSHashTable<NSTextView>.weakObjects()
    private var observation: NSKeyValueObservation?

    static func selectionAttributes(theme: Theme, appearance: Appearance) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: ThemedColor.mistTextSelection.resolve(theme: theme, appearance: appearance),
         .foregroundColor: NSColor.selectedTextColor]
    }

    /// Registers a view's field in the view's window, from `viewDidMoveToWindow`: `owns` tells whether a field editor
    /// is editing it, and `focusChanged` hears when it starts or stops.
    static func claim(_ view: NSView, owns: @escaping (NSTextView) -> Bool, focusChanged: @escaping (Bool) -> Void = { _ in }) {
        guard let window = view.window else { return }
        let editors = windows.object(forKey: window) ?? MistFieldEditors(window)
        windows.setObject(editors, forKey: window)
        editors.claims.setObject(Claim(view: view, owns: owns, focusChanged: focusChanged), forKey: view)
        if !themed.contains(view) {
            themed.add(view)
            _ = view.phi.subscribe { [weak view] _, _ in
                guard let window = view?.window else { return }
                windows.object(forKey: window)?.update()
            }
        }
        editors.update()
    }

    private init(_ window: NSWindow) {
        self.window = window
        observation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            // At once, so a field that edits next configures the shared editor after this hands it back; and again
            // once the editor has taken over, which happens after the first responder changes.
            MainActor.assumeIsolated { self?.update() }
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func update() {
        guard let window else { return }
        let editor = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
        var owner: Claim?
        // A snapshot: a focus handler may claim again.
        for case let claim as Claim in claims.objectEnumerator()?.allObjects ?? [] {
            guard claim.view?.window === window else { continue }
            let focused = owner == nil && editor.map(claim.owns) == true
            if focused { owner = claim }
            if claim.focused != focused {
                claim.focused = focused
                claim.focusChanged(focused)
            }
        }
        for styledEditor in styled.allObjects where owner == nil || styledEditor !== editor {
            styledEditor.selectedTextAttributes = Self.systemSelection
            styled.remove(styledEditor)
        }
        guard let editor, let view = owner?.view else { return }
        editor.selectedTextAttributes = Self.selectionAttributes(theme: view.themeStateProvider.currentTheme,
                                                                 appearance: view.currentAppearance)
        editor.insertionPointColor = .labelColor
        styled.add(editor)
    }
}

/// A split view whose dividers are the kit's hairline.
final class MistSplitView: NSSplitView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
        let view: NSView = self
        _ = view.phi.subscribe { [weak self] _, _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var dividerColor: NSColor {
        ThemedColor.mistHairline.resolve(theme: themeStateProvider.currentTheme, appearance: currentAppearance)
    }
}

/// A page's sidebar pane, tinted a shade off the page. Put the sidebar's scroll view in it with `drawsBackground`
/// off: a scroll view copies its background color rather than blending it, so a translucent tint turns opaque gray.
final class MistSidebarView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        phiLayer?.setBackgroundColor(.mistSidebarFill)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension NSStackView {
    /// A pane's toolbar row: views centered on one line, 8 pt apart, 28 pt tall (the regular pill's height).
    static func mistToolbar(_ views: [NSView]) -> NSStackView {
        let toolbar = NSStackView(views: views)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.heightAnchor.constraint(equalToConstant: MistButtonStyle.Size.regular.height).isActive = true
        return toolbar
    }
}

// MARK: - Page header and states

/// `MistPageHeader` for AppKit: a thin glyph, a large bold title and one centered subtitle line.
final class MistPageHeaderView: NSStackView {
    private let glyphView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var title = ""
    private var subtitle: String?

    /// Original-color image glyphs fit the supplied square; template glyphs retain the thin header treatment.
    init(glyph: MistGlyph, title: String, subtitle: String?, glyphSide: CGFloat = MistPageHeader.glyphSide) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 0
        if case .image = glyph {
            glyphView.image = glyph.nsImage
        } else {
            glyphView.image = glyph.nsImage?.withSymbolConfiguration(.init(pointSize: glyphSide * 0.85, weight: .thin))
            glyphView.phi.setContentTintColor(.textPrimary)
        }
        glyphView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([glyphView.widthAnchor.constraint(equalToConstant: glyphSide),
                                     glyphView.heightAnchor.constraint(equalToConstant: glyphSide)])
        titleLabel.alignment = .center
        subtitleLabel.isSelectable = false
        subtitleLabel.preferredMaxLayoutWidth = 520
        subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        setViews([glyphView, titleLabel, subtitleLabel], in: .center)
        setCustomSpacing(14, after: glyphView)
        setCustomSpacing(10, after: titleLabel)
        setTitle(title, subtitle: subtitle)
        let view: NSView = self
        _ = view.phi.subscribe { [weak self] _, _ in self?.applyText() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
        applyText()
    }
    /// The title's tracking and the subtitle's line spacing need attributed strings, rebuilt with their colors on
    /// theme changes. An empty title leaves the glyph alone (the New Tab Page's logo).
    private func applyText() {
        let theme = themeStateProvider.currentTheme, appearance = currentAppearance
        let titleStyle = MistTextStyle.pageTitle, subtitleStyle = MistTextStyle.lead
        titleLabel.isHidden = title.isEmpty
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: titleStyle.nsFont, .kern: titleStyle.tracking,
            .foregroundColor: titleStyle.color.resolve(theme: theme, appearance: appearance)])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        subtitleLabel.isHidden = subtitle == nil
        subtitleLabel.attributedStringValue = NSAttributedString(string: subtitle ?? "", attributes: [
            .font: subtitleStyle.nsFont, .paragraphStyle: paragraph,
            .foregroundColor: subtitleStyle.color.resolve(theme: theme, appearance: appearance)])
    }
}

/// `MistUnavailableState` for AppKit: the page header with one primary action.
final class MistUnavailableStateView: NSStackView {
    let header: MistPageHeaderView
    let action: MistButton

    init(glyph: MistGlyph, title: String, message: String, actionTitle: String, onAction: @escaping () -> Void) {
        header = MistPageHeaderView(glyph: glyph, title: title, subtitle: message)
        action = MistButton(title: actionTitle, role: .primary)
        action.onClick = onAction
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 24
        setViews([header, action], in: .center)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// `MistPlaceholder` for AppKit: a quiet centered line for an empty or loading pane, with an optional spinner and
/// secondary action.
final class MistPlaceholderView: NSStackView {
    let action = MistButton(title: "", size: .regular)
    private let spinner = NSProgressIndicator()
    private let message = NSTextField.mistWrappingLabel(style: .placeholder)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .centerX
        spacing = 12
        spinner.style = .spinning
        spinner.controlSize = .small
        message.alignment = .center
        setViews([spinner, message, action], in: .center)
        show(message: "")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the line; `actionTitle` shows the action, whose click goes to `action.onClick`.
    func show(message text: String, loading: Bool = false, actionTitle: String? = nil) {
        message.stringValue = text
        message.isHidden = text.isEmpty
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        action.isHidden = actionTitle == nil
        if let actionTitle { action.title = actionTitle }
    }
}

/// `MistNotice` for AppKit: a message and an optional action on a chip-fill strip, across the top of a pane.
final class MistNoticeBar: NSView {
    let message = NSTextField.mistWrappingLabel(style: .secondary)
    let action = MistButton(title: "", size: .regular)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = MistKit.Radius.innerCard
        layer?.cornerCurve = .continuous
        phiLayer?.setBackgroundColor(.mistChipFill)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [message, action])
        stack.spacing = 12
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     heightAnchor.constraint(greaterThanOrEqualToConstant: 40)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message text: String, actionTitle: String?) {
        message.stringValue = text
        action.isHidden = actionTitle == nil
        if let actionTitle { action.title = actionTitle }
    }
}

// MARK: - Toast

/// A brief confirmation floating over a page, like a terminal's "copied" note: a card-fill capsule holding the success
/// dot and one line, which fades in, stays `duration` and fades out. A newer `show` replaces the line and restarts the
/// clock. It never takes a click, so the content under it keeps them. The host places it at its intrinsic size.
final class MistToastView: NSView {
    static let height: CGFloat = 28
    static let duration: TimeInterval = 1.5
    private static let padding: CGFloat = 12
    private static let gap: CGFloat = 7
    let label = NSTextField.mistLabel(style: .secondary)
    private let dot = MistDotView(color: .mistSuccess)
    private var fadeOut: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = MistKit.borderWidth
        phiLayer?.setBackgroundColor(.mistCardFill)
        phiLayer?.setBorderColor(.mistHairline)
        if let shadow = MistElevation.card.shadows.last {
            layer?.shadowOpacity = 1
            layer?.shadowRadius = shadow.blur / 2
            layer?.shadowOffset = CGSize(width: 0, height: -shadow.y)
            phiLayer?[\.shadowColor] = Mapper { _, appearance in
                NSColor.black.withAlphaComponent(shadow.opacity(appearance)).cgColor
            }.optional
        }
        addSubview(dot)
        addSubview(label)
        isHidden = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The label's cell draws inside its insets, which the label's own intrinsic width leaves out.
    override var intrinsicContentSize: NSSize {
        let labelWidth = label.cell?.cellSize.width ?? label.intrinsicContentSize.width
        return NSSize(width: ceil(2 * Self.padding + MistKit.dotSide + Self.gap + labelWidth), height: Self.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // A shadow with no path is derived from the layer's pixels in an offscreen pass.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        dot.frame = NSRect(x: Self.padding, y: ((bounds.height - MistKit.dotSide) / 2).rounded(), width: MistKit.dotSide, height: MistKit.dotSide)
        let labelHeight = label.intrinsicContentSize.height
        let labelX = dot.frame.maxX + Self.gap
        label.frame = NSRect(x: labelX, y: ((bounds.height - labelHeight) / 2).rounded(), width: max(0, bounds.width - labelX - Self.padding), height: labelHeight)
    }

    /// Shows `text`; the host places the toast at its new `intrinsicContentSize`.
    func show(_ text: String) {
        label.stringValue = text
        needsLayout = true
        fadeOut?.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        let fade = DispatchWorkItem { [weak self] in self?.hide() }
        fadeOut = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: fade)
    }

    private func hide() {
        fadeOut = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A `show` during the fade set the alpha back to 1.
            guard let self, self.alphaValue == 0 else { return }
            self.isHidden = true
        }
    }
}
