import AppKit
import Combine
import SwiftUI

final class ClipboardPageViewController: NSViewController, MistAppPage {
    let model: ClipboardPageModel
    private var hosting: ClipboardPageHostingView?

    init(model: ClipboardPageModel? = nil) {
        self.model = model ?? ClipboardPageModel()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = ClipboardPageBackgroundView(model: model)
        let hosting = ClipboardPageHostingView(model: model)
        self.hosting = hosting
        hosting.sizingOptions = []
        view.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    func show(_ address: MistAppAddress, tab: Tab, state: BrowserState) {}
    override func viewDidAppear() { super.viewDidAppear(); model.appear(); focusContent() }
    override func viewDidDisappear() { super.viewDidDisappear(); model.disappear() }
    func focusContent() {
        if model.state == .box, let input = model.inputView { view.window?.makeFirstResponder(input) }
    }
    /// Test hook: whether the pointing hand belongs at `point`, in the window, whatever the window's key state.
    func pointingHandTarget(at point: NSPoint) -> Bool { hosting?.handTarget(at: point) ?? false }
}

/// The kit's hosting view, plus the pointing hand over the drop area while a click there opens the file chooser, and
/// a click anywhere on the page focusing the box.
private final class ClipboardPageHostingView: MistKitHostingView {
    private weak var model: ClipboardPageModel?
    private var subscription: AnyCancellable?

    init(model: ClipboardPageModel) {
        self.model = model
        super.init(rootView: ClipboardPageView(model: model))
        extraHandTarget = { [weak self] point in
            guard let model = self?.model, model.canChooseFile, let input = model.inputView, input.window === self?.window
            else { return false }
            return input.visiblyContains(point)
        }
        // A staged item resizes the drop area under a still pointer.
        subscription = model.$draft.sink { [weak self] _ in self?.setNeedsCursorRefresh() }
    }
    required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // A click on the page focuses the box, so ⌘V pastes there; a click on the box itself opens the chooser.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if let model, model.state == .box, let input = model.inputView, input.window === window {
            window?.makeFirstResponder(input)
        }
    }
}

private final class ClipboardPageBackgroundView: AgentChatBackgroundView {
    let model: ClipboardPageModel
    init(model: ClipboardPageModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v", model.state == .box, pageHasFocus {
            model.paste()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    /// ⌘V pastes into the box while anything on the shown page has focus, or nothing does (Send drops focus to the
    /// window), never while another view such as the address bar has it.
    private var pageHasFocus: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        let responder = window.firstResponder
        return responder === window || (responder as? NSView)?.isDescendant(of: self) == true
    }
}
