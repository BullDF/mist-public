import AppKit

/// The native reader and chat find box, sized like Chromium's.
final class NativeFindBar: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "0/0")
    var onQueryChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var query: String { get { field.stringValue } set { field.stringValue = newValue } }
    var isOpen: Bool { !isHidden }

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        // AppKit overwrites shadow properties set on the layer itself.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow
        self.phiLayer?.setBackgroundColor(.contentOverlayBackground)
        self.isHidden = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel(NSLocalizedString("browser.findBar.field", value: "Find", comment: "Find bar - Find field accessibility label"))
        countLabel.phi.setTextColor(.textSecondary)
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.alignment = .right
        let divider = NSBox()
        divider.boxType = .separator
        let previous = findButton("chevron.up", title: NSLocalizedString("browser.findBar.previous", value: "Previous", comment: "Find bar - Previous find match"), action: #selector(previousMatch))
        let next = findButton("chevron.down", title: NSLocalizedString("browser.findBar.next", value: "Next", comment: "Find bar - Next find match"), action: #selector(nextMatch))
        let close = findButton("xmark", title: NSLocalizedString("browser.findBar.close", value: "Close find bar", comment: "Find bar - Close find bar"), action: #selector(closeFind))
        let stack = NSStackView(views: [field, countLabel, divider, previous, next, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 32)
        ] + [previous, next, close].flatMap { [$0.widthAnchor.constraint(equalToConstant: 28), $0.heightAnchor.constraint(equalToConstant: 28)] })
    }

    private func findButton(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.phi.setContentTintColor(.textSecondary)
        button.setCustomTooltip(title)
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        return button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The field selects and shows its caret in the apps' colors, like a kit field.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MistFieldEditors.claim(self, owns: { [weak field] in field?.currentEditor() === $0 })
    }

    func install(in view: NSView, top: CGFloat, trailing: CGFloat) {
        view.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: 370)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor, constant: top),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -trailing),
            width, widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -2 * trailing),
            heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    func open() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    func hide() { isHidden = true }
    func setCount(current: Int?, total: Int) {
        countLabel.stringValue = current.map { "\($0 + 1)/\(total)" } ?? "0/0"
    }
    func setResult(_ text: String) { countLabel.stringValue = text }
    @objc private func previousMatch() { onStep?(false) }
    @objc private func nextMatch() { onStep?(true) }
    @objc private func closeFind() { onClose?() }
    func controlTextDidChange(_ notification: Notification) { onQueryChange?(query) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        }
        return false
    }
}
