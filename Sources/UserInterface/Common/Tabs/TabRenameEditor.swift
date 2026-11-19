import AppKit
import Combine

/// Keep the field in AppKit: SwiftUI updates must not replace its field editor.
@MainActor
final class TabRenameEditor: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    private weak var tab: Tab?
    private weak var state: BrowserState?
    private weak var anchor: NSView?
    private weak var titleView: NSView?
    private var titleRect: (() -> NSRect?)?
    private var observation: AnyCancellable?
    private var popover: NSPopover?
    private var editing = false
    private let field = NSTextField()

    override init() {
        super.init()
        // Same field as the bookmark rows' rename, so the text stays where the title was.
        field.cell = VerticallyCenteredTextFieldCell()
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(Tab.renameTabLabel)
    }

    func configure(tab: Tab, state: BrowserState?, anchor: NSView,
                   titleView: NSView? = nil, titleRect: @escaping () -> NSRect?) {
        let sameTab = self.tab === tab
        if !sameTab { reset() }
        self.state = state
        self.anchor = anchor
        self.titleView = titleView
        self.titleRect = titleRect
        guard !sameTab else { layout(); return }
        self.tab = tab
        observation = tab.$isRenaming.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] renaming in
                if renaming { self?.begin() }
                else { self?.dismiss() }
            }
    }

    func reset() {
        if editing { finish(commit: true) }
        observation = nil
        tab = nil
        dismiss()
    }

    func layout() {
        guard editing, popover == nil, let rect = titleRect?() else { return }
        // The cell draws its text 2 points in from the field's leading edge.
        field.frame = rect.insetBy(dx: -2, dy: -2)
        titleView?.isHidden = true
    }

    private func begin() {
        guard !editing, let tab, let anchor, anchor.window?.isVisible == true,
              !anchor.isHiddenOrHasHiddenAncestor else { return }
        editing = true
        field.stringValue = tab.title
        if let rect = titleRect?(), rect.width > 0 {
            anchor.addSubview(field)
            layout()
        } else {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
            field.frame = NSRect(x: 12, y: 10, width: 216, height: 24)
            controller.view.addSubview(field)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = controller
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
        DispatchQueue.main.async { [weak self] in
            // A popover focuses its field itself, and focusing a field that is
            // already editing ends that editing, which commits it.
            guard let self, self.editing,
                  self.field.currentEditor() != nil
                    || self.field.window?.makeFirstResponder(self.field) == true else { return }
            // Not `selectText`: it ends the editing that just began, which commits it.
            self.field.currentEditor()?.selectAll(nil)
            self.configureFieldEditor()
        }
    }

    private func configureFieldEditor() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.focusRingType = .none
    }

    private func finish(commit: Bool) {
        guard editing else { return }
        editing = false
        let name = field.currentEditor()?.string ?? field.stringValue
        if commit, let tab {
            let owner = state ?? SpaceSessionControllersManager.shared.controller(for: tab.windowId)?.browserState
            owner?.renameTab(tab, to: name)
        }
        tab?.isRenaming = false
        dismiss()
    }

    private func dismiss() {
        editing = false
        if field.superview === anchor { titleView?.isHidden = false }
        field.removeFromSuperview()
        let previous = popover
        popover = nil
        previous?.close()
    }

    func controlTextDidBeginEditing(_ obj: Notification) { configureFieldEditor() }

    func controlTextDidEndEditing(_ obj: Notification) {
        let cancelled = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        finish(commit: !cancelled)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        return false
    }

    func popoverWillClose(_ notification: Notification) { finish(commit: true) }
}
