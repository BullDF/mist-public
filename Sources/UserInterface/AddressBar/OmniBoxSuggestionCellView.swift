// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
protocol OmniBoxSuggestionCellViewDelegate: AnyObject {
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didClick suggestion: OmniBoxSuggestion, at index: Int)
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didRequestDelete suggestion: OmniBoxSuggestion, at index: Int)
}

/// A suggestion as a kit list row, laid out like the composer's `@` tab rows: its icon, its title over a secondary
/// line, and on the trailing edge the switch-to-tab hint and, while the row is under the pointer or selected, a delete
/// button. Its row view (`OmniBoxSuggestionRowView`) draws the kit's hover and gray selected fills.
class OmniBoxSuggestionCellView: NSTableCellView {
    /// From the row's fill to the icon and to the trailing controls.
    private static let padding: CGFloat = 10
    private static let iconSide: CGFloat = 16

    weak var delegate: OmniBoxSuggestionCellViewDelegate?

    private var suggestion: OmniBoxSuggestion?
    private var index: Int = 0
    private let showsSwitchToTabHint: Bool
    private let switchesToOpenTabByDefault: Bool
    /// The pointer is over the row; its row view reports it.
    var isHovered = false {
        didSet { if isHovered != oldValue { updateAppearance() } }
    }

    private let iconImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Only template images (symbols, app glyphs) take the tint; favicons keep their own colors.
        imageView.phi.setContentTintColor(.textSecondary)
        return imageView
    }()

    private let titleLabel = NSTextField.mistLabel(style: .rowHeadline)

    private let subtitleLabel: NSTextField = {
        let label = NSTextField.mistLabel(style: .secondary)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()

    private lazy var deleteButton: MistIconButton = {
        let button = MistIconButton(symbol: "xmark", title: "Delete")
        // The row's delete button never had a tooltip, and its label isn't a catalog string.
        button.setCustomTooltip(nil)
        button.onClick = { [weak self] in self?.deleteButtonClicked() }
        return button
    }()

    private lazy var switchToTabView: SwitchToTabView = {
        let view = SwitchToTabView()
        view.switchesByDefault = switchesToOpenTabByDefault
        return view
    }()

    init(
        suggestion: OmniBoxSuggestion,
        index: Int,
        showsSwitchToTabHint: Bool,
        switchesToOpenTabByDefault: Bool = false
    ) {
        self.showsSwitchToTabHint = showsSwitchToTabHint
        self.switchesToOpenTabByDefault = switchesToOpenTabByDefault
        super.init(frame: .zero)
        self.suggestion = suggestion
        self.index = index
        [iconImageView, titleLabel, subtitleLabel, switchToTabView, deleteButton].forEach { addSubview($0) }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with suggestion: OmniBoxSuggestion, index: Int) {
        self.suggestion = suggestion
        self.index = index

        let title = suggestion.swapContentsAndDescription ? suggestion.subtitle : suggestion.title
        let subtitle = suggestion.swapContentsAndDescription ? suggestion.title : suggestion.subtitle
        titleLabel.stringValue = title ?? ""
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        OmniSuggestionIconProvier.updateImage(for: iconImageView, with: suggestion)

        updateAppearance()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let inset = OmniBoxSuggestionRowView.insets.width + Self.padding
        iconImageView.frame = NSRect(x: inset, y: (height - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)

        var trailing = bounds.width - inset
        if !deleteButton.isHidden {
            let side = MistIconButton.side
            deleteButton.frame = NSRect(x: trailing - side, y: (height - side) / 2, width: side, height: side)
            trailing = deleteButton.frame.minX - 6
        }
        if !switchToTabView.isHidden {
            let size = switchToTabView.intrinsicContentSize
            switchToTabView.frame = NSRect(x: trailing - size.width, y: (height - size.height) / 2,
                                           width: size.width, height: size.height)
            trailing = switchToTabView.frame.minX - 8
        }

        let textX = iconImageView.frame.maxX + Self.padding
        let textWidth = max(0, trailing - textX)
        if subtitleLabel.isHidden {
            titleLabel.frame = NSRect(x: textX, y: (height - 17) / 2, width: textWidth, height: 17)
        } else {
            titleLabel.frame = NSRect(x: textX, y: height / 2 + 1, width: textWidth, height: 17)
            subtitleLabel.frame = NSRect(x: textX, y: height / 2 - 17, width: textWidth, height: 16)
        }
    }

    // MARK: - Actions

    private func deleteButtonClicked() {
        guard let suggestion = suggestion else { return }
        delegate?.suggestionCellView(self, didRequestDelete: suggestion, at: index)
    }

    // MARK: - Appearance

    func updateAppearance() {
        let isSelected = (superview as? NSTableRowView)?.isSelected ?? false
        let canSwitch = showsSwitchToTabHint && (suggestion?.hasTabMatch ?? false)
        deleteButton.isHidden = !((isHovered || isSelected) && (suggestion?.canDelete ?? false))
        switchToTabView.isHidden = !canSwitch
        switchToTabView.setEmphasized(isSelected || isHovered)
        needsLayout = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateAppearance()
    }
}

/// The trailing hint on a suggestion that can switch to an open tab, in the kit's detail style; it brightens while its
/// row is under the pointer or selected.
class SwitchToTabView: NSView {
    private let label = NSTextField.mistLabel(style: .detail)

    /// Under Cmd+T, Enter switches to the open tab and Cmd opens a new one,
    /// so the hint names the Cmd action there instead.
    var switchesByDefault = false {
        didSet { label.stringValue = Self.hintText(switchesByDefault: switchesByDefault) }
    }

    private static func hintText(switchesByDefault: Bool) -> String {
        switchesByDefault
            ? NSLocalizedString("addressBar.suggestions.openInNewTabHint", value: "Hold ⌘ for new tab →", comment: "Omnibox suggestion - Hint shown in a new-tab omnibox for suggestions that switch to an open tab unless ⌘ is held, which opens a new tab instead")
            : NSLocalizedString("addressBar.suggestions.switchToOpenTabHint", value: "Hold ⌘ to switch →", comment: "Omnibox suggestion - Hint shown for suggestions that can switch to an open tab")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.stringValue = Self.hintText(switchesByDefault: false)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The drawn hint plus the text cell's 2 pt padding on each side; the label's intrinsic width comes out short and
    /// truncated the arrow.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.attributedStringValue.size().width) + 4, height: label.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    func setEmphasized(_ emphasized: Bool) {
        let field: NSTextField = label
        field.phi.setTextColor(emphasized ? .textSecondary : MistTextStyle.detail.color)
    }
}
