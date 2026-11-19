import AppKit
import Combine
import SnapKit

/// A fixed header toggles the flat bookmark rows in the scrolling tab outline.
final class MistSidebarBookmarksHeader: NSButton {
    private var rootSubscription: AnyCancellable?
    private var expandedSubscription: AnyCancellable?

    private static let expandedKey = "mist.sidebar.bookmarksExpanded"
    private static let expandedSubject = CurrentValueSubject<Bool, Never>(
        UserDefaults.standard.object(forKey: expandedKey) as? Bool ?? true
    )

    static var isExpanded: Bool {
        get { expandedSubject.value }
        set {
            UserDefaults.standard.set(newValue, forKey: expandedKey)
            expandedSubject.send(newValue)
        }
    }

    static var expandedPublisher: AnyPublisher<Bool, Never> {
        expandedSubject.eraseToAnyPublisher()
    }

    static func flattenedBookmarks(in root: Bookmark) -> [Bookmark] {
        root.children.flatMap { bookmark in
            bookmark.isFolder ? flattenedBookmarks(in: bookmark) : [bookmark]
        }
    }

    static func outlineItems(from root: Bookmark, isExpanded: Bool = MistSidebarBookmarksHeader.isExpanded) -> [SidebarItem] {
        isExpanded ? flattenedBookmarks(in: root) : []
    }

    static func shouldShow(root: Bookmark, isIncognito: Bool) -> Bool {
        !isIncognito && !flattenedBookmarks(in: root).isEmpty
    }

    static func mount(in stack: NSStackView, state: BrowserState) {
        let button = MistSidebarBookmarksHeader(state: state)
        stack.addArrangedSubview(button)
        button.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(36)
        }
    }

    private static var headerTitle: String {
        NSLocalizedString("mist.sidebar.bookmarks.title", value: "Bookmarks", comment: "Mist sidebar - Fixed bookmarks header title and accessibility label")
    }

    init(state: BrowserState) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(toggleExpanded)
        setAccessibilityLabel(Self.headerTitle)

        let content = MistSidebarSectionHeaderView(title: Self.headerTitle,
            image: NSImage(systemSymbolName: "book", accessibilityDescription: nil))
        addSubview(content)
        content.snp.makeConstraints { $0.edges.equalToSuperview() }

        expandedSubscription = Self.expandedPublisher
            .sink { isExpanded in
                content.isExpanded = isExpanded
            }

        isHidden = !Self.shouldShow(root: state.bookmarkManager.rootFolder, isIncognito: state.isIncognito)
        rootSubscription = state.bookmarkManager.$rootFolder
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state] root in
                guard let self, let state else { return }
                self.isHidden = !Self.shouldShow(root: root, isIncognito: state.isIncognito)
            }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func toggleExpanded() {
        Self.isExpanded.toggle()
    }
}

/// Shared visual content for the fixed bookmarks button and scrolling agent headers.
final class MistSidebarSectionHeaderView: NSView {
    private let chevron = NSImageView()
    var isExpanded = true {
        didSet { updateChevron() }
    }

    /// A wider `iconSize` stays centered on the 16-pt icon slot, so titles share one edge.
    init(title: String, image: NSImage?, iconSize: NSSize = NSSize(width: 16, height: 16)) {
        super.init(frame: .zero)
        let background = HoverableView()
        background.backgroundColor = .clear
        background.hoveredColor = NSColor(resource: .sidebarTabHovered)
        background.responseToClickAction = false
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        addSubview(background)
        background.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.bottom.equalToSuperview().inset(2)
        }
        let icon = NSImageView()
        icon.image = image
        icon.phi.setContentTintColor(.textTertiary)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.phi.setTextColor(.textTertiary)
        label.lineBreakMode = .byTruncatingTail
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        chevron.phi.setContentTintColor(.textTertiary)
        updateChevron()
        [icon, label, chevron].forEach { background.addSubview($0) }
        icon.snp.makeConstraints { make in
            make.centerX.equalTo(background.snp.leading).offset(14)
            make.centerY.equalToSuperview()
            make.size.equalTo(iconSize)
        }
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(30)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-8)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(12)
        }
    }

    private func updateChevron() {
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
