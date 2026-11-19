import Cocoa
import Combine

/// Owns the NTP card and its submit boundary; navigation remains in the omnibox.
final class MistNewTabComposerViewController: NSViewController {
    static let collapsedHeight: CGFloat = 116
    @Published private(set) var contentSize = NSSize(width: MistKit.readableWidth, height: collapsedHeight)

    let omnibox: OmniBoxViewController
    let viewModel: OmniBoxViewModel
    private var cancellables = Set<AnyCancellable>()
    let sendButton = MistButton(symbol: "arrow.up", title: NSLocalizedString("browser.newTabPage.sendAccessibilityLabel", value: "Send", comment: "New tab page - Accessibility label for the button that submits the search or URL"), role: .primary, size: .large, circle: true)
    private let card = MistComposerCard()

    init(state: BrowserState) {
        viewModel = OmniBoxViewModel(windowState: state)
        omnibox = OmniBoxViewController(viewModel: viewModel, state: state, isEmbeddedComposer: true)
        super.init(nibName: nil, bundle: nil)
        omnibox.onSubmit = { [weak self] command, index in
            self?.submit(commandKeyPressed: command, suggestionIndex: index)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.addSubview(card)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(omnibox)
        card.addSubview(omnibox.view)
        card.addSubview(sendButton)
        omnibox.view.translatesAutoresizingMaskIntoConstraints = true
        sendButton.target = self
        sendButton.action = #selector(send)
        omnibox.$contentSize.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateContentSize()
        }.store(in: &cancellables)
        viewModel.state.$inputText.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateSendButton()
        }.store(in: &cancellables)
        updateSendButton()
    }

    /// Drifter's composer layout: the input across the top, Send in the bottom-right corner.
    override func viewDidLayout() {
        super.viewDidLayout()
        card.frame = view.bounds
        omnibox.view.frame = NSRect(x: 0, y: 52, width: view.bounds.width, height: max(0, card.bounds.height - 52))
        sendButton.frame = NSRect(x: max(0, view.bounds.width - 48), y: 12, width: 32, height: 32)
    }

    func focusInput() { omnibox.focusTextField() }

    /// A query is spent by navigation from this field, but is a draft for other navigation.
    func hasDraft(navigatingFrom omnibox: OmniBoxViewModel? = nil) -> Bool {
        omnibox !== viewModel && !viewModel.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit(commandKeyPressed: Bool = false, suggestionIndex: Int? = nil) {
        omnibox.confirmSelection(commandKeyPressed: commandKeyPressed, suggestionIndex: suggestionIndex)
    }

    private func updateSendButton() {
        let enabled = !viewModel.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = enabled
    }

    private func updateContentSize() {
        let size = NSSize(width: MistKit.readableWidth, height: omnibox.contentSize.height + 52)
        if size != contentSize { contentSize = size }
        view.needsLayout = true
    }

    @objc private func send() { submit() }
}
