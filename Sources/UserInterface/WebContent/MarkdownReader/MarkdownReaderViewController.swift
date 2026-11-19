import AppKit
import Combine
import SwiftUI

final class MarkdownReaderViewController: NSViewController {
    private let model = MarkdownReaderModel()
    private var key: String?
    private var watcher: MarkdownFileWatcher?
    private var subscription: AnyCancellable?
    private weak var textView: NSTextView?
    private let findBar = NativeFindBar()
    private var matches: [NSRange] = []
    private var currentMatch: Int?
    private var lastMatchLocation = 0
    private(set) var zoom: CGFloat = 1
    var openLink: ((URL, Bool) -> Void)?

    override func loadView() {
        view = AgentChatBackgroundView()
        let hosting = ThemedHostingView(rootView: MarkdownReaderPage(model: model, onView: { [weak self] in self?.readerUpdated($0) }, openLink: { [weak self] url, background in self?.openLink?(url, background) }))
        hosting.sizingOptions = []
        view.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor), hosting.topAnchor.constraint(equalTo: view.topAnchor), hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        findBar.install(in: view, top: 38, trailing: 18)
        findBar.onQueryChange = { [weak self] _ in guard let self else { return }; self.search(from: self.visibleLocation()) }
        findBar.onStep = { [weak self] in self?.stepMatch(forward: $0) }
        findBar.onClose = { [weak self] in self?.closeFind() }
    }

    func performPageCommand(_ command: CommandWrapper) {
        switch command {
        case .IDC_FIND: showFind()
        case .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS:
            if findBar.isHidden { showFind(from: lastMatchLocation) }
            stepMatch(forward: command == .IDC_FIND_NEXT)
        case .IDC_ZOOM_PLUS: setZoom(MarkdownReaderZoom.step(zoom, up: true))
        case .IDC_ZOOM_MINUS: setZoom(MarkdownReaderZoom.step(zoom, up: false))
        case .IDC_ZOOM_NORMAL: setZoom(1)
        default: break
        }
    }

    private func showFind(from location: Int? = nil) {
        // ⌘F on an open bar only focuses it, keeping the current match.
        if findBar.isHidden || location != nil {
            findBar.isHidden = false
            search(from: location ?? visibleLocation())
        }
        findBar.open()
    }

    @objc private func closeFind() {
        findBar.isHidden = true
        clearHighlights()
        focusContent()
    }
    @objc private func previousMatch() { stepMatch(forward: false) }
    @objc private func nextMatch() { stepMatch(forward: true) }
    override func cancelOperation(_ sender: Any?) {
        // NSViewController doesn't implement cancelOperation:, so a super call throws unrecognized selector.
        if findBar.isHidden { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) } else { closeFind() }
    }
    private func visibleLocation() -> Int {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        // In text-container coordinates: the first visible line's start, not a point the column inset into it.
        let point = NSPoint(x: 0, y: textView.visibleRect.minY - textView.textContainerOrigin.y)
        return layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    }

    private func readerUpdated(_ text: NSTextView) {
        let oldLocation = currentMatch.flatMap { $0 < matches.count ? matches[$0].location : nil } ?? lastMatchLocation
        let changedView = textView !== text
        textView = text
        if changedView { text.enclosingScrollView?.magnification = zoom }
        if !findBar.isHidden { search(from: oldLocation) }
    }

    private func search(from location: Int) {
        guard let textView else { return }
        clearHighlights()
        matches = TextFind.ranges(of: findBar.query, in: textView.string)
        currentMatch = TextFind.current(in: matches, at: location)
        if let currentMatch { lastMatchLocation = matches[currentMatch].location }
        updateHighlights(scroll: true)
    }

    private func clearHighlights() {
        guard let textView, let layout = textView.layoutManager else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    }

    private func updateHighlights(scroll: Bool) {
        guard let textView, let layout = textView.layoutManager else { return }
        clearHighlights()
        for (index, range) in matches.enumerated() {
            layout.addTemporaryAttributes([.backgroundColor: index == currentMatch ? NSColor.systemOrange : NSColor.systemYellow, .foregroundColor: NSColor.black], forCharacterRange: range)
        }
        findBar.setCount(current: currentMatch, total: matches.count)
        if scroll, let currentMatch { textView.scrollRangeToVisible(matches[currentMatch]) }
    }

    private func stepMatch(forward: Bool) {
        guard let currentMatch, let next = TextFind.step(currentMatch, count: matches.count, forward: forward) else { return }
        self.currentMatch = next
        lastMatchLocation = matches[next].location
        updateHighlights(scroll: true)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = value
        guard let textView, let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        guard !textView.string.isEmpty else { scroll.magnification = value; return }
        layout.ensureLayout(for: container)
        let location = visibleLocation()
        let glyph = layout.glyphIndexForCharacter(at: min(location, max(0, (textView.string as NSString).length - 1)))
        let oldY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerInset.height
        let offset = scroll.contentView.bounds.minY - oldY
        scroll.magnification = value
        scroll.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        let newY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerInset.height
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: max(0, newY + offset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func show(_ tab: Tab) {
        guard let url = tab.url, let newKey = AgentChatLink.matchKey(url), key != newKey else { return }
        key = newKey
        watcher?.cancel()
        watcher = nil
        subscription = nil
        model.text = ""
        model.url = URL(string: url)
        model.documentKey = newKey
        if let file = MarkdownDocumentRoute.localFile(for: url) {
            watcher = MarkdownFileWatcher(url: file) { [weak self] text in
                guard let self, self.key == newKey else { return }
                self.model.text = text
            }
        } else {
            subscription = tab.$remoteMarkdown.compactMap { $0 }.sink { [weak model] text in model?.text = text }
        }
    }

    func focusContent() { if let textView { view.window?.makeFirstResponder(textView) } }
}

private final class MarkdownReaderModel: ObservableObject {
    @Published var text = ""
    @Published var documentKey = ""
    var url: URL?
}

private struct MarkdownReaderPage: View {
    @ObservedObject var model: MarkdownReaderModel
    var onView: (NSTextView) -> Void
    var openLink: (URL, Bool) -> Void
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    var body: some View {
        MarkdownReaderText(text: model.text, url: model.url, primary: theme.color(for: .textPrimary, appearance: appearance), secondary: theme.color(for: .textSecondary, appearance: appearance), separator: theme.color(for: .separator, appearance: appearance), onView: onView, openLink: openLink)
            .id(model.documentKey)
    }
}

private final class MarkdownReaderScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        let inset = AgentChatColumn(panel: false).frame(in: width).x
        if text.textContainerInset.width != inset { text.textContainerInset = NSSize(width: inset, height: 24) }
    }
}

private struct MarkdownReaderText: NSViewRepresentable {
    let text: String
    let url: URL?
    let primary: NSColor
    let secondary: NSColor
    let separator: NSColor
    let onView: (NSTextView) -> Void
    let openLink: (URL, Bool) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var url: URL?
        var openLink: (URL, Bool) -> Void = { _, _ in }
        var rendered: NSAttributedString?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? URL)?.relativeString ?? (link as? String)
            guard let value, let base = url, let destination = URL(string: value, relativeTo: base)?.absoluteURL,
                  AgentChatLink.matchKey(destination.absoluteString) != AgentChatLink.matchKey(base.absoluteString) else { return true }
            openLink(destination, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownReaderScrollView()
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 5
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = AgentChatTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        // A text view's maxSize defaults to its initial zero frame, which would cap it at one screen.
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        scroll.documentView = view
        onView(view)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AgentChatTextView else { return }
        let coordinator = context.coordinator
        coordinator.url = url
        coordinator.openLink = openLink
        let renderer = MarkdownRenderer.agentChat(primary: primary, secondary: secondary, separator: separator, typesetMath: MarkdownMathTypesetter.typeset)
        let rendered = renderer.markdownRuns(text, color: primary)
        if let storage = view.textStorage, !storage.isEqual(to: rendered) {
            let position = scroll.contentView.bounds.origin
            let selection = view.selectedRanges.filter { NSMaxRange($0.rangeValue) <= rendered.length }
            storage.apply(rendered, over: coordinator.rendered)
            view.selectedRanges = selection
            view.updateCodeControls()
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
            onView(view)
        }
        coordinator.rendered = rendered
    }
}
