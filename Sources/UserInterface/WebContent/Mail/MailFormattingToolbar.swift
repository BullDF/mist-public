import AppKit
import Combine

final class MailFormattingToolbar: NSScrollView {
    private static weak var colorPanelOwner: MailFormattingToolbar?
    private let editor: MailRichTextEditor
    private var controls: [NSControl] = []
    private var formatting: [String: NSButton] = [:]
    private let font = MistPopUpButton(), size = MistPopUpButton(), color = MistPopUpButton()
    private var selectionState: [String: Any] = [:]
    private var colorPanelClose: AnyCancellable?
    var isEnabled = true {
        didSet {
            controls.forEach { $0.isEnabled = isEnabled }
            editor.formattingEnabled = isEnabled
        }
    }

    init(editor: MailRichTextEditor) {
        self.editor = editor
        super.init(frame: .zero)
        editor.onState = { [weak self] in self?.updateSelection($0) }
        // Wide enough apart for each symbol's 24 pt hover circle.
        let bar = NSStackView(); bar.spacing = 12; bar.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 6, right: 20)
        func button(_ command: String, _ symbol: String, _ title: String, toggle: Bool = false) {
            let button = MistIconButton(symbol: symbol, title: title)
            if toggle { button.setButtonType(.toggle); formatting[command] = button }
            button.onClick = { [weak self] in self?.exec(command) }; controls.append(button); bar.addArrangedSubview(button)
        }
        button("bold", "bold", MailStrings.bold, toggle: true); button("italic", "italic", MailStrings.italic, toggle: true)
        button("underline", "underline", MailStrings.underline, toggle: true); button("strikeThrough", "strikethrough", MailStrings.strikethrough, toggle: true)
        font.addItem(withTitle: MailStrings.defaultFont)
        for (family, _) in Self.fonts {
            font.addItem(withTitle: family)
            if let face = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                font.lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [.font: face])
            }
        }
        font.menu?.addItem(.separator()); font.addItem(withTitle: MailStrings.formattingOther)
        font.selectItem(at: 0)
        font.setAccessibilityLabel(MailStrings.font); font.setCustomTooltip(MailStrings.font); font.target = self; font.action = #selector(changeFont)
        size.addItems(withTitles: [MailStrings.small, MailStrings.normal, MailStrings.large, MailStrings.huge]); size.selectItem(at: 1)
        size.setAccessibilityLabel(MailStrings.textSize); size.setCustomTooltip(MailStrings.textSize); size.target = self; size.action = #selector(changeSize)
        color.addItems(withTitles: [MailStrings.defaultColor, MailStrings.gray, MailStrings.red, MailStrings.orange, MailStrings.green, MailStrings.blue, MailStrings.purple])
        color.setAccessibilityLabel(MailStrings.textColor); color.setCustomTooltip(MailStrings.textColor); color.target = self; color.action = #selector(changeColor)
        color.menu?.addItem(.separator()); color.addItem(withTitle: MailStrings.formattingOther)
        controls += [font, size, color]; bar.addArrangedSubview(font); bar.addArrangedSubview(size); bar.addArrangedSubview(color)
        button("insertUnorderedList", "list.bullet", MailStrings.bulletedList, toggle: true); button("insertOrderedList", "list.number", MailStrings.numberedList, toggle: true)
        button("outdent", "decrease.indent", MailStrings.decreaseIndent); button("indent", "increase.indent", MailStrings.increaseIndent)
        let link = MistIconButton(symbol: "link", title: MailStrings.link); link.setButtonType(.toggle); link.onClick = { [weak self] in self?.showLinkSheet() }; formatting["link"] = link; controls.append(link); bar.addArrangedSubview(link)
        button("removeFormat", "textformat", MailStrings.clearFormatting)
        drawsBackground = false; hasHorizontalScroller = true; autohidesScrollers = true; documentView = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), bar.topAnchor.constraint(equalTo: contentView.topAnchor), bar.heightAnchor.constraint(equalTo: contentView.heightAnchor), heightAnchor.constraint(equalToConstant: 40)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func exec(_ command: String, value: String? = nil) {
        guard isEnabled else { return }
        editor.runCommand(command, value: value)
    }
    /// Gmail's scale over a 16px body: legacy sizes 2, 3, 5 and 6, so Normal is the body's own size.
    private static let sizes = ["2", "3", "5", "6"]
    @objc private func changeSize() { exec("fontSize", value: Self.sizes[size.indexOfSelectedItem]) }
    private static let palette = ["#000000", "#808080", "#cc0000", "#e67300", "#008000", "#0066cc", "#800080"]
    private static let fonts = [
        ("Helvetica", "sans-serif"), ("Arial", "sans-serif"), ("Verdana", "sans-serif"),
        ("Georgia", "serif"), ("Times New Roman", "serif"), ("Palatino", "serif"),
        ("Courier New", "monospace"), ("Snell Roundhand", "cursive"), ("Bradley Hand", "cursive")
    ]

    static func fontStack(for family: String) -> String {
        if family.isEmpty || family == "-apple-system" { return MailComposeFormatting.bodyFontStack }
        let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let fallback = fonts.first { $0.0 == family }?.1 ?? "sans-serif"
        return "\"\(escaped)\", \(fallback)"
    }

    private var selectedFamily: String {
        let stack = selectionState["fontName"] as? String ?? ""
        return stack.components(separatedBy: ",").first?.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ").union(.newlines)) ?? ""
    }

    @objc private func changeFont() {
        guard let item = font.selectedItem else { return }
        if item === font.lastItem {
            let family = selectedFamily
            updateSelection(selectionState)
            Task {
                do { try await editor.showFontPanel(family: family) }
                catch { editor.onError?(error) }
            }
        } else if font.indexOfSelectedItem == 0 {
            exec("fontName", value: MailComposeFormatting.bodyFontStack)
        } else {
            exec("fontName", value: Self.fontStack(for: item.title))
        }
    }

    @objc private func changeColor() {
        if color.selectedItem === color.lastItem {
            let current = Self.hexColor(selectionState["foreColor"] as? String ?? "") ?? Self.palette[0]
            updateSelection(selectionState)
            Task {
                do {
                    try await editor.capturePanelSelection(for: "foreColor")
                    guard window != nil, isEnabled else { return }
                    let panel = NSColorPanel.shared
                    Self.colorPanelOwner?.releaseColorPanel()
                    panel.setTarget(nil)
                    if let rgb = UInt32(current.dropFirst(), radix: 16) {
                        panel.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
                    }
                    panel.setTarget(self)
                    panel.setAction(#selector(changeCustomColor(_:)))
                    panel.isContinuous = true
                    Self.colorPanelOwner = self
                    colorPanelClose = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: panel)
                        .sink { [weak self] _ in self?.releaseColorPanel() }
                    panel.orderFront(nil)
                } catch { editor.onError?(error) }
            }
        } else if Self.palette.indices.contains(color.indexOfSelectedItem) {
            exec("foreColor", value: Self.palette[color.indexOfSelectedItem])
        }
    }

    @objc private func changeCustomColor(_ panel: NSColorPanel) {
        guard let window, window.attachedSheet == nil, isEnabled, panel.isVisible,
              NSApp.keyWindow === window || NSApp.keyWindow === panel,
              let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = Self.hex([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) })
        editor.runCommand("foreColor", value: hex, panelSelection: true)
    }

    private func releaseColorPanel() {
        guard Self.colorPanelOwner === self else { return }
        Self.colorPanelOwner = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        colorPanelClose = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow != window { releaseColorPanel() }
        super.viewWillMove(toWindow: newWindow)
    }

    private static func hex(_ components: [Int]) -> String {
        "#" + components.map { String(format: "%02x", min(255, max(0, $0))) }.joined()
    }

    private static func hexColor(_ value: String) -> String? {
        let normalized = value.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized.hasPrefix("#"), normalized.utf8.count == 7, UInt32(normalized.dropFirst(), radix: 16) != nil { return normalized }
        guard normalized.hasPrefix("rgb("), normalized.hasSuffix(")") else { return nil }
        let components = normalized.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0) }
        return components.count == 3 ? hex(components) : nil
    }

    private func select(_ menu: MistPopUpButton, at index: Int?, itemCount: Int, customTitle: String) {
        let custom = menu.numberOfItems > itemCount + 2 ? menu.item(at: itemCount) : nil
        if let index {
            if custom != nil { menu.removeItem(at: itemCount) }
            menu.selectItem(at: index)
        }
        else {
            if let custom { custom.title = customTitle }
            else { menu.insertItem(withTitle: customTitle, at: itemCount) }
            menu.selectItem(at: itemCount)
        }
    }
    private func updateSelection(_ state: [String: Any]) {
        selectionState = state
        for (command, button) in formatting { button.state = state[command] as? Bool == true ? .on : .off }
        if let value = state["fontSize"] as? String, let index = Self.sizes.firstIndex(of: value) { size.selectItem(at: index) }
        let family = selectedFamily
        let fontIndex = family.isEmpty || family == "-apple-system" ? 0 : Self.fonts.firstIndex { $0.0.caseInsensitiveCompare(family) == .orderedSame }.map { $0 + 1 }
        select(font, at: fontIndex, itemCount: Self.fonts.count + 1, customTitle: family)
        let colorValue = state["foreColor"] as? String ?? ""
        let colorIndex = colorValue.isEmpty ? 0 : Self.hexColor(colorValue).flatMap { Self.palette.firstIndex(of: $0) }
        select(color, at: colorIndex, itemCount: Self.palette.count, customTitle: MailStrings.customColor)
    }
    func showLinkSheet() {
        guard let window, isEnabled else { return }
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
                        } catch { self.editor.onError?(error) }
                    }
                }
                panel.makeFirstResponder(field)
            } catch { editor.onError?(error) }
        }
    }
}
