import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AgentChatViewController: NSViewController, MistAppPage {
    enum Presentation { case page, panel }
    let presentation: Presentation
    private let store: AgentChatStore
    private(set) var conversation: AgentConversation?
    private var conversationId: UUID?
    private var pageVisible = false
    let composer = AgentChatComposer()
    private(set) var previewStack: BrowserAgentPreviewStack?
    private var pageTrailingConstraint: NSLayoutConstraint?
    private let pageLayout = DrifterChatPageLayout()
    private let mountAnchor = AgentChatMountAnchor()
    private let findBar = NativeFindBar()
    private weak var transcriptScroll: AgentChatTranscriptScroll?
    private(set) var textScale: CGFloat = 1 {
        didSet { if textScale != oldValue { transcriptScroll?.textScale = textScale } }
    }
    var onPreviewVisibilityChanged: (() -> Void)?

    init(store: AgentChatStore? = nil, presentation: Presentation = .page) {
        self.store = store ?? .shared
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = AgentChatBackgroundView()
        findBar.install(in: view, top: presentation == .page ? 38 : 8, trailing: presentation == .page ? 18 : 12)
        findBar.onQueryChange = { [weak self] query in
            self?.transcriptScroll?.setFindQuery(query)
            self?.transcriptScroll?.findSearch(from: .visible)
        }
        findBar.onStep = { [weak self] in self?.transcriptScroll?.stepFind(forward: $0) }
        findBar.onClose = { [weak self] in self?.closeFind() }
    }

    func show(_ id: UUID) {
        _ = view
        guard conversationId != id || conversation !== store.conversation(for: id) else { return }
        conversationId = id
        conversation = store.conversation(for: id)
        hideFind()
        transcriptScroll?.onFindChange = nil
        transcriptScroll = nil
        view.subviews.filter { $0 !== findBar }.forEach { $0.removeFromSuperview() }
        previewStack = nil
        let hosting: MistKitHostingView
        if let entry = store.entry(for: id) {
            let settings = entry.settings
            composer.configure(settings: settings, skillFolders: entry.conversation.skillFolders)
            hosting = MistKitHostingView(rootView: DrifterChatPage(conversation: entry.conversation, settings: settings, composer: composer, layout: pageLayout,
                                                                       origin: .init(store: store, chatId: id, anchor: mountAnchor), panel: presentation == .panel,
                                                                       onTranscriptScroll: { [weak self] in self?.setTranscript($0) },
                                                                       onRevealMarker: { [weak self] in self?.revealMarker($0) }))
        } else {
            hosting = MistKitHostingView(rootView: MistPlaceholder(message: AgentChatStrings.unavailable)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        // After configuring, which turns mentions on: restyling with them off strips the draft's mention tokens.
        composer.bind(conversation)
        // The constraints below size the page. Its own size constraints re-measured the whole page,
        // header candidates included, on every frame of a transcript scroll while an agent ran.
        hosting.sizingOptions = []
        view.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let trailing = hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        pageTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailing,
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if presentation == .page, conversation != nil {
            let card = BrowserAgentPreviewStack()
            card.isHidden = true
            card.onVisibilityChanged = { [weak self] in self?.view.needsLayout = true }
            view.addSubview(card)
            previewStack = card
        }
        view.addSubview(findBar, positioned: .above, relativeTo: nil)
        onPreviewVisibilityChanged?()
    }

    func setTranscript(_ scroll: AgentChatTranscriptScroll) {
        guard transcriptScroll !== scroll else { return }
        transcriptScroll = scroll
        scroll.onRevealMarker = { [weak self] in self?.revealMarker($0) }
        scroll.textScale = textScale
        scroll.onFindChange = { [weak self] in self?.findBar.setCount(current: $0, total: $1) }
        if findBar.isOpen {
            scroll.setFindQuery(findBar.query)
            scroll.findSearch(from: .visible)
        }
    }

    func revealMarker(_ id: String) { transcriptScroll?.revealMarker(id) }
    func stepMarker(forward: Bool) { transcriptScroll?.stepMarker(forward: forward) }

    /// Opens the header's Mount to Tab picker; false when the chat is mounted or the page shows no header.
    func showMountPicker() -> Bool {
        guard presentation == .page, let id = conversationId, store.panelHost(of: id) == nil,
              let anchor = mountAnchor.view, anchor.window != nil else { return false }
        AgentChatMountPicker.show(chatId: id, store: store, relativeTo: anchor)
        return true
    }

    var pageZoom: CGFloat? { textScale }

    func show(_ address: MistAppAddress, tab: Tab, state: BrowserState) {
        guard let id = address.chatId else { return }
        composer.editor.mentionTabs = { [weak state, weak tab] in state?.tabs.filter { $0.guid != tab?.guid } ?? [] }
        composer.editor.mentionGroups = { [weak state] in state?.agentMentionGroups ?? [] }
        composer.editor.currentTab = { [weak state] in state?.lastActiveWebTab }
        if !store.restoreIfNeeded(id, tabId: tab.guid), let url = tab.url.flatMap(URL.init(string:)) {
            _ = store.recreate(id, tabId: tab.guid, at: url)
        }
        show(id)
    }

    @discardableResult func performPageCommand(_ command: CommandWrapper) -> Bool {
        switch command {
        case .IDC_ZOOM_PLUS: textScale = MarkdownReaderZoom.step(textScale, up: true); return true
        case .IDC_ZOOM_MINUS: textScale = MarkdownReaderZoom.step(textScale, up: false); return true
        case .IDC_ZOOM_NORMAL: textScale = 1; return true
        case .IDC_FIND, .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS: break
        default: return false
        }
        let wasClosed = !findBar.isOpen
        findBar.open()
        if wasClosed {
            transcriptScroll?.setFindQuery(findBar.query)
            transcriptScroll?.findSearch(from: command == .IDC_FIND ? .visible : .current)
        }
        if command != .IDC_FIND { transcriptScroll?.stepFind(forward: command == .IDC_FIND_NEXT) }
        return true
    }

    private func closeFind() {
        hideFind()
        focusContent()
    }

    private func hideFind() {
        findBar.hide()
        transcriptScroll?.setFindQuery(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        // NSViewController doesn't implement cancelOperation:, so a super call throws unrecognized selector.
        if findBar.isOpen { closeFind() } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        previewStack?.layoutCards(pageSize: view.bounds.size)
        let card = previewStack.flatMap { $0.isHidden ? nil : $0.frame }
        let inset = card.map { BrowserAgentPreviewLayout.chatTrailingInset(pageWidth: view.bounds.width, cardLeading: $0.minX) } ?? 0
        if pageTrailingConstraint?.constant != -inset { pageTrailingConstraint?.constant = -inset }
        // The narrowed page still ends under the card's leading edge; keep the transcript's scroller beside the card.
        let overlap = card.map { inset > 0 ? view.bounds.width - inset - $0.minX : 0 } ?? 0
        if let scroll = transcriptScroll, scroll.scrollerInsets.right != overlap { scroll.scrollerInsets.right = overlap }
        if pageLayout.cardOverlap != overlap { pageLayout.cardOverlap = overlap }
    }


    /// The page narrowed for the preview card leaves empty space below the card; scrolling there
    /// scrolls the transcript, as in the page's own margins.
    override func scrollWheel(with event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        guard let scroll = transcriptScroll, let card = previewStack, !card.isHidden, !card.frame.contains(point) else {
            return super.scrollWheel(with: event)
        }
        let band = scroll.convert(scroll.bounds, to: view)
        guard point.y >= band.minY, point.y <= band.maxY else { return super.scrollWheel(with: event) }
        scroll.scrollWheel(with: event)
    }

    func focusContent() {
        guard conversation != nil else { return }
        view.window?.makeFirstResponder(composer.editor.textView)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        pageVisible = true
        if presentation == .page { focusContent() }
        onPreviewVisibilityChanged?()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        pageVisible = false
        onPreviewVisibilityChanged?()
    }
}

/// How far the chat page runs under the preview cards' leading edge (`viewDidLayout`).
private final class DrifterChatPageLayout: ObservableObject {
    @Published var cardOverlap: CGFloat = 0
}

private struct DrifterChatPage: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var conversation: AgentConversation
    @ObservedObject var settings: DrifterSettings
    @ObservedObject var composer: AgentChatComposer
    @ObservedObject var layout: DrifterChatPageLayout
    let origin: AgentChatPanelOriginButton
    var panel = false
    var onTranscriptScroll: (AgentChatTranscriptScroll) -> Void = { _ in }
    var onRevealMarker: (String) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 0) {
            if !panel {
                HStack(spacing: 14) {
                    MistIconTile(content: .logo(NSImage(named: DrifterApp.logo) ?? NSImage()), side: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title).mistText(.headerTitle).lineLimit(1).truncationMode(.tail)
                        // Value-only info keeps streaming transcript updates outside its Equatable boundary.
                        DrifterChatHeaderInfo(chatId: conversation.id, model: settings.modelTitle,
                            context: ClaudeCodeSessionMetadata.context(tokens: conversation.contextTokens, size: conversation.contextWindowSize))
                            .equatable().mistText(.secondary)
                    }
                    Spacer(minLength: 0)
                    if conversation.status == .awaitingPermission { Text(AgentChatStrings.waiting(for: conversation.items)).mistText(.secondary) }
                    HStack(spacing: 4) {
                        AgentChatMarkerListButton(markers: conversation.markers, conversation: conversation, jump: onRevealMarker).equatable()
                        origin
                    }
                }.lineLimit(1).padding(.vertical, 14).agentChatColumn(panel: panel)
                // Ends at the cards' leading edge.
                Rectangle().themedFill(.mistHairline).frame(height: 1 / displayScale).padding(.trailing, layout.cardOverlap)
            }
            Group {
                if conversation.items.isEmpty {
                    DrifterEmptyState().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AgentChatTranscript(conversation: conversation, folder: settings.config.folder, slashCommands: composer.slashCommandNames, engine: settings.config.engine,
                                        onMake: onTranscriptScroll).placed(panel: panel)
                }
            }
            if let handOff = conversation.handOff {
                AgentChatHandOffView(handOff: handOff, done: conversation.finishHandOff).padding(.top, 8).agentChatColumn(panel: panel)
            }
            if !conversation.queue.isEmpty {
                AgentChatQueueView(conversation: conversation, edit: composer.editQueued).padding(.top, 8).agentChatColumn(panel: panel)
            }
            AgentChatComposerHost(composer: composer).padding(.top, 8).padding(.bottom, 16).agentChatColumn(panel: panel)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await settings.refreshModels() }
    }
}

private struct DrifterChatHeaderInfo: View, Equatable {
    let chatId: UUID
    let model: String
    let context: ClaudeCodeSessionMetadata.Context?
    var body: some View {
        HStack(spacing: 14) {
            Text(MistAppID.drifter.name)
            AgentChatIDButton(id: chatId)
            Label(model, systemImage: "cpu")
            if let context { AgentChatContextUsage(context: context) }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date, format: Date.FormatStyle().hour().minute())
            }
        }
    }
}

struct AgentChatIDButton: View {
    let id: UUID
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    private var label: String {
        NSLocalizedString("browser.agentChat.copyChatId", value: "Copy Chat ID", comment: "Chat header - Copy this chat's short ID")
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(AgentChatShortID.short(id), forType: .string)
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                copied = false
            }
        } label: {
            Label(AgentChatShortID.short(id), systemImage: copied ? "checkmark" : "number")
        }.buttonStyle(.plain)
            .mistPointingHand()
            .customTooltip(label).accessibilityLabel(label)
            .accessibilityIdentifier("agentChat.chatId")
            .onDisappear { resetTask?.cancel(); copied = false }
    }
}

/// The header's Mount to Tab button, which the picker opens from, whether clicked or by Switch Between Chat Panel and Tab.
private final class AgentChatMountAnchor { weak var view: NSView? }

/// Shows the linked panel and unmounts the chat from it, or offers to mount an unlinked chat to a tab.
private struct AgentChatPanelOriginButton: View {
    @ObservedObject var store: AgentChatStore
    let chatId: UUID
    let anchor: AgentChatMountAnchor
    var body: some View {
        if store.panelHost(of: chatId) != nil {
            HStack(spacing: 4) {
                Button {
                    store.unmount(chatId)
                } label: { Image(systemName: "personalhotspot.slash") }
                    .buttonStyle(.mistIcon).customTooltip(Self.unmountTitle).accessibilityLabel(Self.unmountTitle)
                Button {
                    MistChatPanelViewController.showInOriginPanel(chatId, store: store)
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.mistIcon).customTooltip(Self.title).accessibilityLabel(Self.title)
            }
        } else {
            Button {
                if let view = anchor.view { AgentChatMountPicker.show(chatId: chatId, store: store, relativeTo: view) }
            } label: { Image(systemName: "link.badge.plus") }
                .buttonStyle(.mistIcon).customTooltip(Self.mountTitle).accessibilityLabel(Self.mountTitle)
                .background(HeaderControlAnchorView { anchor.view = $0 })
        }
    }
    private static var title: String {
        NSLocalizedString("browser.agentChat.showInChatPanel", value: "Show in Chat Panel",
                          comment: "Agent chat page - Go back to the tab whose Chat panel started this chat and show the chat there")
    }
    private static var mountTitle: String {
        NSLocalizedString("browser.agentChat.mountToTab", value: "Mount to Tab",
                          comment: "Agent chat page - Link this chat, which no tab's Chat panel shows, to an open tab and show it in that tab's Chat panel")
    }
    private static var unmountTitle: String {
        NSLocalizedString("browser.agentChat.unmountFromTab", value: "Unmount from Tab",
                          comment: "Agent chat page - Unlink this chat from the tab it is mounted to: that tab's Chat panel goes back to empty, and the chat keeps running in this page")
    }
}

struct AgentChatContextUsage: View {
    @AgentChatColors private var colors
    let context: ClaudeCodeSessionMetadata.Context
    private var tint: Color {
        switch context.level {
        case .normal: colors.resolve(.textSecondary)
        case .warning: .orange
        case .critical: .red
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(colors.resolve(.mistChipFill))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: 56 * context.fraction)
                }.frame(width: 56, height: 5)
            Text(verbatim: "\(context.percent)%").foregroundStyle(tint)
        }.customTooltip(String(format: NSLocalizedString("browser.claudeCode.contextTokens",
            value: "%@ of %@ tokens", comment: "Claude Code header - Used tokens and context window size"),
            context.tokens.formatted(), context.size.formatted()))
    }
}

enum AgentChatTerminalFont {
    static func font(scale: CGFloat = 1) -> NSFont {
        let families = NSFontManager.shared.availableFontFamilies
        if let family = families.first(where: { $0 == "JetBrainsMono Nerd Font" }),
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12 * scale) { return font }
        let base = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        let fallbacks = families.filter { $0.contains("Nerd Font") }.sorted().map {
            NSFontDescriptor(fontAttributes: [.family: $0])
        }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: fallbacks]), size: 12 * scale) ?? base
    }

    /// A line's height at `scale`, for centering a card row's first line on its tile; cached per scale.
    @MainActor static func lineHeight(scale: CGFloat) -> CGFloat { metrics(scale: scale).lineHeight }
    /// The cap height at `scale`, for starting a wrapped card row's text level with its tile; cached per scale.
    @MainActor static func capHeight(scale: CGFloat) -> CGFloat { metrics(scale: scale).capHeight }
    @MainActor private static func metrics(scale: CGFloat) -> (lineHeight: CGFloat, capHeight: CGFloat) {
        if let cached = cachedMetrics[scale] { return cached }
        let font = font(scale: scale)
        let metrics = (MistTileCard<EmptyView, EmptyView>.lineHeight(font), font.capHeight)
        cachedMetrics[scale] = metrics
        return metrics
    }
    @MainActor private static var cachedMetrics: [CGFloat: (lineHeight: CGFloat, capHeight: CGFloat)] = [:]
}

/// The centered column a chat page's header, transcript rows, queue and composer keep to.
struct AgentChatColumn: Equatable {
    static let maxWidth: CGFloat = 760
    var margin: CGFloat
    init(panel: Bool) { margin = panel ? 16 : 24 }
    /// The column's leading edge and width in a page `width` wide.
    func frame(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let column = max(1, min(Self.maxWidth, width - 2 * margin))
        return ((width - column) / 2, column)
    }
}

private extension View {
    func agentChatColumn(panel: Bool) -> some View {
        frame(maxWidth: AgentChatColumn.maxWidth).padding(.horizontal, AgentChatColumn(panel: panel).margin)
            .frame(maxWidth: .infinity)
    }
}

/// AppKit owns scroll position so streamed height changes don't count as the user scrolling up.
private struct AgentChatTranscript: NSViewRepresentable {
    @ObservedObject var conversation: AgentConversation
    let folder: URL
    let slashCommands: Set<String>
    var engine: DrifterEngine = .claude
    var column: AgentChatColumn?
    var onMake: (AgentChatTranscriptScroll) -> Void = { _ in }
    func makeNSView(context: Context) -> AgentChatTranscriptScroll {
        AgentChatTranscriptScroll()
    }
    func updateNSView(_ view: AgentChatTranscriptScroll, context: Context) {
        view.column = column
        view.observe(conversation)
        view.updateContent(AgentChatTranscriptRows(conversation: conversation, folder: folder, engine: engine, slashCommands: slashCommands))
        onMake(view)
    }

    /// The scroll view spans the tab or panel while its rows keep to the column, so the margins beside the rows
    /// scroll them too and the overlay scroll bar draws in the right margin instead of over them.
    func placed(panel: Bool) -> Self {
        var transcript = self
        transcript.column = AgentChatColumn(panel: panel)
        return transcript
    }
}

struct AgentChatFindMark: Equatable {
    var query: String
    var rowId: String?
    var ordinal: Int?
}

struct AgentChatFindHighlight: Equatable {
    var query: String
    var current: Int?

    func shifted(past lines: [ClaudeCodeToolSummary.Line]) -> Self {
        let count = lines.reduce(0) { $0 + TextFind.ranges(of: query, in: $1.text).count }
        return Self(query: query, current: current.flatMap { $0 >= count ? $0 - count : nil })
    }

    func line(_ index: Int, in lines: [ClaudeCodeToolSummary.Line]) -> Self {
        shifted(past: Array(lines.prefix(index)))
    }

    /// Apply marks in UTF-16 coordinates across spans, retaining fonts, dim text and links.
    static func styled(_ line: ClaudeCodeToolSummary.Line, highlight: Self?, secondary: Color, group: Bool = false, scale: CGFloat = 1) -> Text {
        let source = line.text
        var output = AttributedString(source)
        func range(_ nsRange: NSRange) -> Range<AttributedString.Index>? {
            guard let stringRange = Range(nsRange, in: source),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: output),
                  let upper = AttributedString.Index(stringRange.upperBound, within: output) else { return nil }
            return lower..<upper
        }
        var offset = 0
        for span in line.spans {
            let length = (span.text as NSString).length
            if let range = range(NSRange(location: offset, length: length)) {
                if span.style == .bold { output[range].font = Font(AgentChatTerminalFont.font(scale: scale)).bold() }
                if !group {
                    if let link = span.link { output[range].link = link }
                    if span.style == .dim { output[range].foregroundColor = secondary }
                }
            }
            offset += length
        }
        let changeColor: Color?
        switch line.kind {
        case .addition: changeColor = .green.opacity(0.25)
        case .removal: changeColor = .red.opacity(0.25)
        default: changeColor = nil
        }
        if let changeColor {
            for change in line.changes {
                if let range = range(change) { output[range].backgroundColor = changeColor }
            }
        }
        if let highlight {
            for (ordinal, match) in TextFind.ranges(of: highlight.query, in: source).enumerated() {
                if let range = range(match) {
                    output[range].backgroundColor = Color(nsColor: ordinal == highlight.current ? .systemOrange : .systemYellow)
                    output[range].foregroundColor = .black
                }
            }
        }
        return Text(output)
    }
}

/// The transcript's go-to-bottom button, floating over its bottom edge with the pointing hand over all of it, whatever
/// row lies under it.
final class AgentChatJumpButton: NSButton, MistPointingHandControl {
    private var area: NSTrackingArea?
    var showsPointingHand: Bool { isEnabled }
    override func resetCursorRects() { addPointingHandCursorRect() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }
    override func cursorUpdate(with event: NSEvent) { keepFloatingPointingHand() }
    override func mouseMoved(with event: NSEvent) { keepFloatingPointingHand() }
}

final class AgentChatTranscriptScroll: NSScrollView {
    private static let windowOverscan: CGFloat = 0.5
    private static let windowRewindowThreshold: CGFloat = 0.25
    var textScale: CGFloat = 1 { didSet { if textScale != oldValue { needsLayout = true } } }
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }
    private let document = Document()
    private var hosting: MistKitHostingView?
    // One reused controller: building a new one per row re-creates its whole tree.
    private let rowMeasurer = NSHostingController(rootView: AnyView(EmptyView()))
    let renderings = AgentChatRichTextRenderings()
    private var content: AgentChatTranscriptRows?
    private var pendingContent: AgentChatTranscriptRows?
    private var lastContentUpdate: CFTimeInterval = 0
    static let runningUpdateInterval: CFTimeInterval = 0.1
    private(set) var transcriptWindow: AgentChatTranscriptWindow?
    /// The stack's height: its padding, every row's cached height and the working row.
    private(set) var contentHeight: CGFloat = 0
    private(set) var slice: AgentChatTranscriptSlice?
    private var workingRowHeight: (afterRows: Bool, height: CGFloat)?
    private struct HeightKey: Equatable {
        var row: AgentChatDisplayRow
        var spacing: CGFloat
        var open: Bool
        var expandedPeerMessages: Set<String>
        var expandedTools: Set<String>
        var expandedToolGroups: Set<String>
        var planFeedbackOpen: Set<String>
        var marker: String?
    }
    private struct HeightContext: Equatable {
        var width: CGFloat
        var textScale: CGFloat
        var slashCommands: Set<String>
        var folder: URL
        var engine: DrifterEngine
        var memory: AgentMemoryFiles
    }
    private var heightContext: HeightContext?
    private var heightCache: [String: (key: HeightKey, context: HeightContext, height: CGFloat)] = [:]
    // Find needs keys for rows that have never reached the measurer.
    private var heightKeys: [HeightKey] = []
    private var estimatedRows = IndexSet()
    private var idleMeasurementScheduled = false
    private enum Measurement { case shown, idle, all }
    private enum RowKind: Hashable {
        case toolGroup, toolCall, userMessage, assistantText, other

        init(_ row: AgentChatDisplayRow) {
            switch row {
            case .toolGroup: self = .toolGroup
            case let .item(item):
                switch item.kind {
                case .toolCall: self = .toolCall
                case .userMessage: self = .userMessage
                case .assistantText: self = .assistantText
                default: self = .other
                }
            }
        }
    }
    private let displayCache = AgentChatDisplayRowCache()
    private var rows: [AgentChatDisplayRow] = []
    private var contentStatus: AgentConversationStatus = .idle
    private var memory = AgentMemoryFiles.none
    private var itemIDs: [String: Set<String>] = [:]
    private var heights: [CGFloat] = []
    private var markers: [AgentChatMarker] = []
    private var markerNames: [String: String] = [:]
    private struct MarkerPosition {
        var marker: AgentChatMarker
        var index: Int
        var top: CGFloat
        var bottom: CGFloat
    }
    private var markerPositions: [MarkerPosition] = []
    let markerTicks = AgentChatMarkerTickStrip()
    var onRevealMarker: ((String) -> Void)?
    private var markerHighlight: NSView?
    private var markerHighlightTask: Task<Void, Never>?
    private(set) var lastMeasuredRowIDs: [String] = []
    private var findQuery: String?
    private var findTexts: [String] = []
    private var findIDs: [String] = []
    private var findCache: [String: (key: HeightKey, text: String)] = [:]
    private var findDirtyFrom: Int? = 0
    private var findMatches = AgentChatFindMatches()
    private var findMarkdownCache = MarkdownRenderCache()
    private var findMarkdownRowId: String?
    var onFindChange: ((Int?, Int) -> Void)?
    enum FindStart { case visible, current }
    private var viewStateVersion = 0
    private var measuredViewStateVersion = 0
    let viewState = AgentChatTranscriptViewState()
    private var viewStateChange: AnyCancellable?
    private weak var observedConversation: AgentConversation?
    private var messageSentSubscription: AnyCancellable?
    private(set) var followsBottom = true {
        didSet { jumpButton.isHidden = followsBottom }
    }
    let jumpButton = AgentChatJumpButton()
    private var jumping = false
    private var expansionOrigin: NSPoint?
    private var updating = false
    private var observers: [NSObjectProtocol] = []
    /// The reader's gesture, momentum and elastic bounce, during which AppKit owns the scroll position.
    private var liveScrolling = false
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    /// A click under way on selectable text, from its mouse down.
    private struct TextClick {
        var location: NSPoint
        weak var view: NSView?
        var viewStateVersion: Int
        var linkOpens: Int
    }
    private var textClick: TextClick?
    /// Mouse downs in the window; a later one cancels the collapse a click scheduled.
    private var clicks = 0
    /// Whether the trackpad gesture under way began over this transcript; its later events don't hit-test again.
    private var gestureOverTranscript = false
    /// The bottoms the document has had during the live scroll under way, first the one it started at;
    /// AppKit may settle the scroll at any of them.
    private var liveBottoms: [CGFloat] = []
    /// Whether the live scroll under way went past the bottom, so its bounce brings it back up.
    private var liveOverscrolled = false
    private var scrollBottom: CGFloat { max(0, document.frame.height - contentSize.height) }
    /// Keeps the rows to this column of a scroll view spanning the page; otherwise they fill it.
    var column: AgentChatColumn? {
        didSet { if column != oldValue { needsLayout = true } }
    }
    private var columnFrame: (x: CGFloat, width: CGFloat) {
        column?.frame(in: contentSize.width) ?? (0, max(1, contentSize.width))
    }

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = document
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        jumpButton.isBordered = false
        jumpButton.wantsLayer = true
        jumpButton.layer?.cornerRadius = 14
        jumpButton.layer?.borderWidth = MistKit.borderWidth
        jumpButton.phiLayer?.setBackgroundColor(.mistCardFill)
        jumpButton.phiLayer?.setBorderColor(.mistHairline)
        if let shadow = MistElevation.card.shadows.first {
            jumpButton.layer?.shadowOpacity = 1
            jumpButton.layer?.shadowRadius = shadow.blur / 2
            jumpButton.layer?.shadowOffset = CGSize(width: 0, height: -shadow.y)
            jumpButton.phiLayer?[\.shadowColor] = Mapper { _, appearance in
                NSColor.black.withAlphaComponent(shadow.opacity(appearance)).cgColor
            }.optional
        }
        jumpButton.phi.setContentTintColor(.textSecondary)
        let jumpTitle = NSLocalizedString("browser.agentChat.jumpToBottom", value: "Jump to Bottom", comment: "Agent transcript - Scroll to the latest message and follow new output")
        jumpButton.setCustomTooltip(jumpTitle)
        jumpButton.setAccessibilityLabel(jumpTitle)
        jumpButton.target = self
        jumpButton.action = #selector(jumpToBottom)
        jumpButton.isHidden = true
        addSubview(jumpButton)
        addSubview(markerTicks)
        markerTicks.onJump = { [weak self] id in
            guard let self else { return }
            if let onRevealMarker = self.onRevealMarker { onRevealMarker(id) }
            else { self.revealMarker(id) }
        }
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
                guard let self, let document = self.documentView else { return }
                let bottom = self.scrollBottom
                let y = self.contentView.bounds.minY
                if self.liveScrolling && y > bottom + 0.5 { self.liveOverscrolled = true }
                guard !self.updating, !self.jumping else { return }
                if self.followsBottom, self.liveScrolling,
                   AgentChatBottomFollow.scrollsAway(y: y, bottom: bottom, overscrolled: self.liveOverscrolled, earlierBottoms: self.liveBottoms) {
                    self.followsBottom = false
                } else {
                    // A bounce that ends while the agent streams settles at a bottom AppKit knew earlier in the
                    // live scroll, which isn't the reader scrolling away.
                    let slack = self.liveScrolling && self.followsBottom ? max(0, bottom - (self.liveBottoms.first ?? bottom)) : 0
                    self.followsBottom = AgentChatBottomFollow.follows(distance: document.bounds.height - self.contentView.bounds.maxY,
                                                                       following: self.followsBottom, slack: slack)
                }
                if self.needsNewWindow { self.rewindow() }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.liveScrolling = true
                self.liveBottoms = [self.scrollBottom]
                self.liveOverscrolled = false
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.liveScrolling = false
                self.liveBottoms = []
                if self.followsBottom { self.needsLayout = true }
            },
        ]
        viewStateChange = viewState.objectWillChange.sink { [weak self] in
            guard let self else { return }
            self.viewStateVersion += 1
            self.expansionOrigin = self.contentView.bounds.origin
            self.needsLayout = true
        }
        // A monitor rather than a scrollWheel override, which would opt the view out of responsive scrolling.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.noteScrollInput(event)
            return event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.noteClick(event)
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        markerHighlightTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// The window moves by its background, and AppKit walks every view that answers true to find where;
    /// a transcript that answered true got walked whole again after each streamed update moved its rows.
    /// Like a web page, the transcript never moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// A mouse wheel's scroll up stops following, however small. Of a trackpad gesture this sees only the may-begin
    /// and began events, without deltas: AppKit's responsive scrolling tracks the rest itself, so the bounds
    /// observer tells a live scroll up by its position.
    private func noteScrollInput(_ event: NSEvent) {
        // Momentum only carries a gesture on.
        guard event.window === window, event.momentumPhase.isEmpty else { return }
        if event.phase.isEmpty || !event.phase.isDisjoint(with: [.mayBegin, .began]) {
            gestureOverTranscript = window?.contentView?.hitTest(event.locationInWindow)?.isDescendant(of: self) == true
        }
        guard followsBottom, gestureOverTranscript, contentView.bounds.minY > 0,
              AgentChatBottomFollow.scrollsUp(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) else { return }
        followsBottom = false
    }

    /// Collapses the innermost expanded block under a plain click on its selectable text, whose AppKit view takes the
    /// click before SwiftUI's tap can (`agentChatCollapsible`). It waits out the double-click interval, so a double
    /// click still selects a word, and collapses only if the click selected nothing, opened no link and toggled nothing.
    /// An `AgentChatTextView` passes its mouse-up here itself, since its tracking loop takes it before the monitor.
    fileprivate func noteClick(_ event: NSEvent) {
        guard event.window === window, let hosting else { return }
        guard event.type == .leftMouseUp else {
            clicks += 1
            textClick = nil
            guard event.clickCount == 1, event.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]),
                  let hit = window?.contentView?.hitTest(event.locationInWindow), hit !== hosting, hit.isDescendant(of: hosting),
                  !sequence(first: hit, next: { $0.superview }).prefix(while: { $0 !== hosting }).contains(where: { $0 is NSControl })
            else { return }
            textClick = TextClick(location: event.locationInWindow, view: hit, viewStateVersion: viewStateVersion, linkOpens: viewState.linkOpens)
            return
        }
        guard let click = textClick else { return }
        textClick = nil
        guard hypot(event.locationInWindow.x - click.location.x, event.locationInWindow.y - click.location.y) <= 3,
              let area = hosting.handAreas.allObjects.lazy.compactMap({ $0 as? AgentChatCollapseArea.AreaView })
                  .filter({ $0.window === self.window && $0.visiblyContains(click.location) })
                  .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        let clicks = clicks
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self, weak area, weak view = click.view] in
            guard let self, let area, area.window != nil, self.clicks == clicks, viewStateVersion == click.viewStateVersion,
                  viewState.linkOpens == click.linkOpens, (view?.accessibilitySelectedTextRange().length ?? 0) == 0 else { return }
            area.collapse()
        }
    }

    func observe(_ conversation: AgentConversation) {
        guard observedConversation !== conversation else { return }
        observedConversation = conversation
        messageSentSubscription = conversation.messageSent.sink { [weak self] in self?.jumpToBottom() }
    }

    func setContent(_ content: AgentChatTranscriptRows) {
        pendingContent = nil
        var content = content
        content.viewState = viewState
        updating = true
        let newMemory = AgentMemoryFiles(folders: content.conversation.memoryFolders, skillFolders: content.conversation.skillFolders)
        let memoryChanged = newMemory != memory
        memory = newMemory
        let newRows = AgentChatDisplayRow.rows(from: content.conversation.items, memory: memory, cwd: content.folder, cache: displayCache)
        var newItemIDs: [String: Set<String>] = [:]
        for item in content.conversation.items {
            if case let .toolCall(tool) = item.kind { newItemIDs[tool.toolUseId, default: []].insert(item.id) }
        }
        let common = zip(rows, newRows).prefix { $0 == $1 }.count
        var first = min(common, max(0, rows.count - 1), max(0, newRows.count - 1))
        if itemIDs != newItemIDs {
            for index in 0..<common {
                if case let .toolGroup(tools) = newRows[index],
                   tools.contains(where: { itemIDs[$0.toolUseId] != newItemIDs[$0.toolUseId] }) {
                    first = min(first, index)
                    break
                }
            }
        }
        if common < rows.count {
            let ids = Set(newRows.map(\.id))
            heightCache = heightCache.filter { ids.contains($0.key) }
        }
        var dirtyFrom = first
        let nextMarkers = content.conversation.markers
        if markers != nextMarkers {
            let nextNames = Dictionary(uniqueKeysWithValues: nextMarkers.map { ($0.id, $0.name) })
            if let changed = newRows.firstIndex(where: { markerNames[$0.id] != nextNames[$0.id] }) {
                dirtyFrom = min(dirtyFrom, changed)
            }
            markers = nextMarkers
            markerNames = nextNames
        }
        if memoryChanged {
            dirtyFrom = 0
        }
        if findQuery != nil {
            if self.content?.slashCommands != content.slashCommands || self.content?.folder != content.folder || memoryChanged {
                findCache.removeAll()
                findMarkdownCache = MarkdownRenderCache()
                findDirtyFrom = 0
            } else {
                findDirtyFrom = min(findDirtyFrom ?? dirtyFrom, dirtyFrom)
            }
            if common < rows.count {
                let ids = Set(newRows.map(\.id))
                findCache = findCache.filter { ids.contains($0.key) }
            }
        }
        rows = newRows
        itemIDs = newItemIDs
        contentStatus = content.conversation.status
        self.content = content
        refresh()
        resizeDocument()
        updating = false
        lastContentUpdate = CACurrentMediaTime()
    }

    /// A running agent updates the conversation per streamed text chunk, dozens of times a second, and each
    /// update re-renders the transcript; those apply an interval after the last one so the window keeps its frames.
    func updateContent(_ content: AgentChatTranscriptRows) {
        let wait = lastContentUpdate + Self.runningUpdateInterval - CACurrentMediaTime()
        guard content.conversation.status == .running, wait > 0 else { return setContent(content) }
        let scheduled = pendingContent != nil
        pendingContent = content
        guard !scheduled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let content = self.pendingContent else { return }
            self.setContent(content)
        }
    }

    override func layout() {
        updating = true
        super.layout()
        refresh()
        resizeDocument()
        // A shorter document (rows re-measured wider) clamps the scroll position, which the muted
        // bounds observer misses, so the rendered rows can sit above the viewport.
        if !followsBottom, !jumping {
            followsBottom = AgentChatBottomFollow.follows(distance: document.bounds.height - contentView.bounds.maxY, following: false)
        }
        if needsNewWindow {
            refresh()
            resizeDocument()
            hosting?.layoutSubtreeIfNeeded()
        }
        jumpButton.frame = NSRect(x: (bounds.width - 28) / 2,
                                  y: isFlipped ? bounds.height - 40 : 12, width: 28, height: 28)
        // A shadow with no path is derived from the layer's pixels in an offscreen pass.
        jumpButton.layer?.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 28, height: 28), transform: nil)
        updating = false
    }

    override func tile() {
        super.tile()
        markerTicks.frame = NSRect(x: bounds.maxX - scrollerInsets.right - 12, y: bounds.minY, width: 12, height: bounds.height)
        // AppKit may move the scroller above its siblings when it tiles.
        if subviews.last !== markerTicks { addSubview(markerTicks, positioned: .above, relativeTo: nil) }
        updateMarkerTicks()
    }

    @objc func jumpToBottom() {
        followsBottom = true
        jumping = true
        // The rows between here and the bottom aren't rendered, so a long jump would fly over blank
        // spacers; start it one screen above the bottom instead.
        let bottom = max(0, document.bounds.height - contentSize.height)
        if bottom - contentView.bounds.minY > contentSize.height * 2 {
            contentView.scroll(to: NSPoint(x: 0, y: bottom - contentSize.height))
        }
        refresh()
        let animationStart = contentView.bounds.origin
        resizeDocument()
        contentView.scroll(to: NSPoint(x: animationStart.x, y: max(animationStart.y, scrollBottom - contentSize.height)))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, document.bounds.height - contentSize.height)))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.jumping = false
            self.needsLayout = true
        }
        reflectScrolledClipView(contentView)
    }

    private func refresh(measurement: Measurement = .shown) {
        guard var content else { return }
        lastMeasuredRowIDs = []
        if case let .item(item) = rows.last, case .assistantText = item.kind { renderings.sharedID = item.id }
        else { renderings.sharedID = nil }
        let width = columnFrame.width
        let context = HeightContext(width: width, textScale: textScale, slashCommands: content.slashCommands, folder: content.folder,
                                    engine: content.engine, memory: memory)
        if heightContext != context {
            workingRowHeight = nil
            heightContext = context
        }
        if measuredViewStateVersion != viewStateVersion {
            measuredViewStateVersion = viewStateVersion
            findDirtyFrom = 0
        }
        let status = contentStatus
        if hosting == nil {
            content.slice = AgentChatTranscriptSlice(entries: [], memory: memory, find: nil, slashCommands: content.slashCommands, folder: content.folder, engine: content.engine, showsWorking: false, afterRows: false)
            let hosting = MistKitHostingView(rootView: content.environment(\.agentChatRenderings, renderings))
            // The frame is set from the cached heights, so skip measuring the tree on every layout.
            hosting.sizingOptions = []
            self.hosting = hosting
            document.addSubview(hosting)
        }
        guard let hosting else { return }
        func measure<Row: View>(_ row: Row) -> CGFloat {
            rowMeasurer.rootView = hosting.themedRootView(row
                .font(.system(size: NSFont.systemFontSize * textScale))
                .frame(maxWidth: .infinity, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
                .environment(\.agentChatMeasuring, true)
                .environment(\.agentChatTextScale, textScale)
                .environment(\.agentChatRenderings, renderings)
                .environment(\.openURL, content.openURL))
            rowMeasurer.view.setFrameSize(NSSize(width: width, height: 1))
            rowMeasurer.view.layoutSubtreeIfNeeded()
            return rowMeasurer.sizeThatFits(in: NSSize(width: width, height: 10_000_000)).height
        }
        let previousKeys = heightKeys
        let previousValues = heights
        heightKeys = rows.indices.map { index in
            let row = rows[index]
            var ids: Set<String> = [row.id]
            switch row {
            case let .item(item):
                ids.insert(item.id)
                if case let .toolCall(tool) = item.kind { ids.insert(tool.toolUseId) }
                if case let .permissionRequest(request) = item.kind { ids.insert(request.requestId) }
            case let .toolGroup(tools):
                for tool in tools {
                    ids.insert(tool.toolUseId)
                    ids.formUnion(itemIDs[tool.toolUseId] ?? [])
                }
            }
            return HeightKey(row: row, spacing: AgentChatTranscriptRows.spacing(before: row, after: index > 0 ? rows[index - 1] : nil),
                                open: AgentChatDisplayRow.isOpen(at: index, of: rows, status: status),
                                expandedPeerMessages: viewState.expandedPeerMessages.intersection(ids),
                                expandedTools: viewState.expandedTools.intersection(ids),
                                expandedToolGroups: viewState.expandedToolGroups.intersection(ids),
                                planFeedbackOpen: viewState.planFeedbackOpen.intersection(ids), marker: markerNames[row.id])
        }
        var averages: [RowKind: (total: CGFloat, count: Int)] = [:]
        estimatedRows = []
        for index in rows.indices {
            if let cached = heightCache[rows[index].id], cached.key == heightKeys[index], cached.context == context {
                let kind = RowKind(rows[index])
                let average = averages[kind] ?? (0, 0)
                averages[kind] = (average.total + cached.height, average.count + 1)
            } else { estimatedRows.insert(index) }
        }
        heights = rows.indices.map { index in
            if let cached = heightCache[rows[index].id] { return cached.height }
            if let average = averages[RowKind(rows[index])] { return average.total / CGFloat(average.count) }
            return 44
        }
        if !followsBottom {
            // Row IDs can repeat (a streamed reply re-added under its ID), as the ID-keyed height cache already allows.
            let nextHeights = Dictionary(zip(rows, heights).map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
            var top: CGFloat = 16
            var delta: CGFloat = 0
            let visibleTop = (expansionOrigin ?? contentView.bounds.origin).y
            for (key, height) in zip(previousKeys, previousValues) {
                top += height
                if top <= visibleTop, let next = nextHeights[key.row.id] {
                    delta += next - height
                }
            }
            if delta != 0 {
                var origin = expansionOrigin ?? contentView.bounds.origin
                origin.y += delta
                expansionOrigin = origin
            }
        }
        func measureRow(_ index: Int) {
            guard estimatedRows.contains(index) else { return }
            let old = heights[index]
            let bottom = 16 + heights.prefix(index + 1).reduce(0, +)
            let height = measure(content.row(at: index, rows: rows, memory: memory, status: status, marker: markerNames[rows[index].id]))
            heightCache[rows[index].id] = (heightKeys[index], context, height)
            heights[index] = height
            estimatedRows.remove(index)
            lastMeasuredRowIDs.append(rows[index].id)
            if !followsBottom, bottom <= (expansionOrigin ?? contentView.bounds.origin).y, height != old {
                var origin = expansionOrigin ?? contentView.bounds.origin
                origin.y += height - old
                expansionOrigin = origin
            }
        }
        func visibleBounds() -> NSRect {
            var visible = contentView.bounds
            if let origin = expansionOrigin { visible.origin = origin }
            if followsBottom && expansionOrigin == nil {
                visible.origin.y = max(0, 32 + heights.reduce(0, +) - contentSize.height)
                visible.size.height = contentSize.height
            }
            return visible
        }
        func shownRows() -> IndexSet {
            let visible = visibleBounds()
            var shown = IndexSet()
            var top: CGFloat = 16
            for index in rows.indices {
                let bottom = top + heights[index]
                let overscan = contentSize.height * Self.windowOverscan
                if bottom >= visible.minY - overscan && top <= visible.maxY + overscan { shown.insert(index) }
                top = bottom
            }
            if jumping, let window = transcriptWindow {
                let shownIDs = Set(window.shown.map { window.rows[$0].id })
                shown.formUnion(IndexSet(rows.indices.filter { shownIDs.contains(rows[$0].id) }))
            }
            return shown
        }
        var shown: IndexSet
        switch measurement {
        case .all:
            for index in Array(estimatedRows) { measureRow(index) }
            shown = shownRows()
        case .idle:
            // Keep the mounted rows unchanged: offscreen corrections only move their hosting frame.
            shown = transcriptWindow?.shown ?? shownRows()
            let visible = visibleBounds()
            var top: CGFloat = 16
            var candidates: [(index: Int, distance: CGFloat)] = []
            for index in rows.indices {
                let bottom = top + heights[index]
                if estimatedRows.contains(index) {
                    candidates.append((index, max(0, visible.minY - bottom, top - visible.maxY)))
                }
                top = bottom
            }
            candidates.sort { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
            let deadline = CACurrentMediaTime() + 0.006
            for candidate in candidates {
                measureRow(candidate.index)
                if CACurrentMediaTime() >= deadline { break }
            }
        case .shown:
            if followsBottom && expansionOrigin == nil {
                var covered: CGFloat = 16
                for index in rows.indices.reversed() {
                    measureRow(index)
                    covered += heights[index]
                    if covered >= contentSize.height * (1 + Self.windowOverscan) { break }
                }
            }
            shown = shownRows()
            while !shown.intersection(estimatedRows).isEmpty {
                for index in shown.intersection(estimatedRows) { measureRow(index) }
                shown = shownRows()
            }
        }
        // Idle corrections move every downstream marker, even when none of its rows is mounted.
        do {
            markerPositions = []
            var top: CGFloat = 16
            for index in rows.indices {
                let row = rows[index]
                if let name = markerNames[row.id] {
                    let spacing = AgentChatTranscriptRows.spacing(before: row, after: index > 0 ? rows[index - 1] : nil)
                    markerPositions.append(MarkerPosition(marker: .init(id: row.id, name: name), index: index,
                                                          top: top + spacing, bottom: top + heights[index]))
                }
                top += heights[index]
            }
        }
        updateMarkerTicks()
        updateFindTexts()
        var working: CGFloat = 0
        if content.conversation.showsWorkingIndicator {
            // One line whatever its text, so one measurement per width.
            if let cached = workingRowHeight, cached.afterRows == !rows.isEmpty { working = cached.height }
            else {
                working = measure(content.workingRow(afterRows: !rows.isEmpty))
                workingRowHeight = (!rows.isEmpty, working)
            }
        }
        contentHeight = 32 + heights.reduce(0, +) + working
        let next = AgentChatTranscriptWindow(rows: rows, status: status, shown: shown, heights: heights, memory: memory, find: findMark)
        transcriptWindow = next
        let nextSlice = AgentChatTranscriptSlice(window: next, slashCommands: content.slashCommands, folder: content.folder,
                                                 engine: content.engine, showsWorking: content.conversation.showsWorkingIndicator, textScale: textScale, markers: markerNames)
        if nextSlice != slice {
            slice = nextSlice
            content.slice = nextSlice
            hosting.setThemedContent(content.environment(\.agentChatRenderings, renderings))
        }
        let first = shown.first ?? 0
        let last = shown.last
        let sliceHeight = last.map { heights[first...$0].reduce(0, +) } ?? 0
        let column = columnFrame
        let frame = NSRect(x: column.x, y: 16 + heights.prefix(first).reduce(0, +), width: column.width,
                           height: sliceHeight + (nextSlice.showsWorking ? working : 0))
        if hosting.frame != frame { hosting.frame = frame }
        scheduleIdleMeasurement()
    }

    /// Test-only opt-in to exact totals; opening a transcript never needs this work.
    func finishMeasuring() {
        updating = true
        refresh(measurement: .all)
        resizeDocument()
        updating = false
    }

    private func scheduleIdleMeasurement(delay: TimeInterval = 0) {
        guard !estimatedRows.isEmpty, !idleMeasurementScheduled else { return }
        idleMeasurementScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.idleMeasurementScheduled = false
            guard !self.estimatedRows.isEmpty else { return }
            let sinceInput = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
                                 CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
            guard !self.liveScrolling, !self.jumping, self.window != nil, sinceInput >= 0.4 else {
                self.scheduleIdleMeasurement(delay: 0.1)
                return
            }
            self.updating = true
            self.refresh(measurement: .idle)
            self.resizeDocument()
            self.updating = false
        }
    }

    private var findMark: AgentChatFindMark? {
        guard let query = findQuery, !query.isEmpty else { return nil }
        return AgentChatFindMark(query: query, rowId: findMatches.current?.rowId, ordinal: findMatches.current?.ordinal)
    }

    func setFindQuery(_ query: String?) {
        let wasClosed = findQuery == nil
        findQuery = query
        if query == "" {
            findMatches.search("", ids: [], texts: [], start: (0, 0))
            onFindChange?(nil, 0)
            refresh()
            return
        }
        if query == nil {
            findCache.removeAll()
            findTexts.removeAll()
            findIDs.removeAll()
            findMarkdownCache = MarkdownRenderCache()
            findMarkdownRowId = nil
            refresh()
        } else if wasClosed {
            findDirtyFrom = 0
        }
    }

    func findSearch(from start: FindStart) {
        let previous = findMatches.current
        refresh()
        guard let query = findQuery, !query.isEmpty else { return }
        if findTexts.count != rows.count { findDirtyFrom = 0; updateFindTexts() }
        let old = findMatches.current ?? previous
        let position: (row: Int, location: Int)
        switch start {
        case .visible: position = firstVisibleFindPosition()
        case .current: position = (old.flatMap { match in rows.firstIndex { $0.id == match.rowId } } ?? old?.row ?? 0, old?.range.location ?? 0)
        }
        findMatches.search(query, ids: rows.map(\.id), texts: findTexts, start: position)
        onFindChange?(findMatches.currentIndex, findMatches.count)
        refresh()
        revealFindMatch()
    }

    func stepFind(forward: Bool) {
        findMatches.step(forward: forward)
        onFindChange?(findMatches.currentIndex, findMatches.count)
        refresh()
        revealFindMatch()
    }

    /// Called only after content or expansion changes, never by a scroll-only rewindow.
    private func updateFindTexts() {
        guard findQuery?.isEmpty == false, let dirty = findDirtyFrom, let content else { return }
        let first = min(dirty, findTexts.count, rows.count)
        var changed = min(findTexts.count, rows.count)
        let oldIDs = findIDs
        findTexts.removeSubrange(first..<findTexts.count)
        findIDs.removeSubrange(first..<findIDs.count)
        for index in first..<rows.count {
            let row = rows[index]
            findIDs.append(row.id)
            // A cached row that moved, as when a resolved permission row drops out above it, is new at its index.
            if index >= oldIDs.count || oldIDs[index] != row.id { changed = min(changed, index) }
            let key = heightKeys[index]
            if let cached = findCache[row.id], cached.key == key {
                findTexts.append(cached.text)
            } else {
                let text = searchableText(row, open: key.open, content: content, last: index == rows.count - 1)
                findCache[row.id] = (key, text)
                findTexts.append(text)
                changed = min(changed, index)
            }
        }
        findDirtyFrom = nil
        // A newly opened bar still has the previous search's index until findSearch selects its start.
        // Updating here preserves its current row and ordinal while output streams.
        findMatches.update(ids: rows.map(\.id), texts: findTexts, from: changed)
        onFindChange?(findMatches.currentIndex, findMatches.count)
    }

    private func searchableText(_ row: AgentChatDisplayRow, open: Bool, content: AgentChatTranscriptRows, last: Bool) -> String {
        switch row {
        case let .toolGroup(tools):
            return AgentChatToolGroupView.lines(tools, folder: content.folder, memory: memory, open: open,
                                               expanded: viewState.expandedToolGroups.contains(tools[0].toolUseId)).map(\.text).joined(separator: "\n")
        case let .item(item):
            switch item.kind {
            case let .toolCall(tool): return AgentChatToolView.lines(tool, folder: content.folder).map(\.text).joined(separator: "\n")
            case let .taskNotification(summary, _): return AgentChatStrings.taskNotification(summary)
            case let .userMessage(text, _):
                return MarkdownRenderer.agentChat(primary: .textColor, secondary: .secondaryLabelColor, separator: .separatorColor,
                                                  slashCommands: content.slashCommands, typesetMath: nil).userMessageRuns(text, mentions: item.mentions).string
            case let .assistantText(text, _):
                if last, findMarkdownRowId != row.id {
                    findMarkdownCache = MarkdownRenderCache()
                    findMarkdownRowId = row.id
                }
                return MarkdownRenderer.agentChat(primary: .textColor, secondary: .secondaryLabelColor, separator: .separatorColor,
                                                  slashCommands: content.slashCommands, typesetMath: MarkdownMathTypesetter.typeset)
                    .markdownRuns(text, color: .textColor, cache: last ? findMarkdownCache : nil).string
            default: return ""
            }
        }
    }

    /// Only mounted text views belong to this transcript; measuring views never participate.
    private func mountedFindTextViews() -> [AgentChatTextView] {
        func collect(_ view: NSView) -> [AgentChatTextView] {
            if let text = view as? AgentChatTextView { return [text] }
            return view.subviews.flatMap(collect)
        }
        return hosting.map(collect) ?? []
    }

    private func firstVisibleFindPosition() -> (row: Int, location: Int) {
        var top: CGFloat = 16
        let visibleTop = contentView.bounds.minY
        for index in rows.indices {
            let bottom = top + heights[index]
            if bottom > visibleTop {
                if top < visibleTop {
                    for text in mountedFindTextViews() {
                        let rect = text.convert(text.bounds, to: document)
                        guard rect.minY <= visibleTop, rect.maxY > visibleTop, rect.minY >= top,
                              let layout = text.layoutManager, let container = text.textContainer else { continue }
                        let point = text.convert(NSPoint(x: rect.minX, y: visibleTop), from: document)
                        return (index, layout.characterIndex(for: NSPoint(x: 0, y: point.y - text.textContainerOrigin.y), in: container,
                                                             fractionOfDistanceBetweenInsertionPoints: nil))
                    }
                }
                return (index, 0)
            }
            top = bottom
        }
        return (0, 0)
    }

    private func revealFindMatch() {
        guard let match = findMatches.current, match.row < heights.count else { return }
        followsBottom = false
        updating = true
        defer { updating = false }
        func rowRect() -> NSRect {
            NSRect(x: 0, y: 16 + heights.prefix(match.row).reduce(0, +), width: document.bounds.width, height: heights[match.row])
        }
        func scroll(to y: CGFloat) {
            contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, document.bounds.height - contentSize.height))))
        }
        let wasOffscreen = !rowRect().intersects(contentView.bounds)
        if wasOffscreen { scroll(to: rowRect().minY - contentSize.height / 3) }
        refresh()
        resizeDocument()
        if wasOffscreen {
            scroll(to: rowRect().minY - contentSize.height / 3)
            refresh()
            resizeDocument()
        }
        hosting?.layoutSubtreeIfNeeded()
        if let text = mountedFindTextViews().first(where: { $0.findCurrentRange != nil }), let rect = text.findCurrentRect() {
            let target = text.convert(rect, to: document)
            if !contentView.bounds.contains(target) { scroll(to: target.midY - contentSize.height / 2) }
        } else if !contentView.bounds.contains(rowRect()) {
            document.scrollToVisible(rowRect())
        }
        reflectScrolledClipView(contentView)
        refresh()
        resizeDocument()
        followsBottom = AgentChatBottomFollow.follows(distance: document.bounds.height - contentView.bounds.maxY, following: false)
    }

    private func updateMarkerTicks() {
        let height = markerTicks.bounds.height
        let documentHeight = max(1, document.frame.height)
        markerTicks.apply(markerPositions.map {
            .init(id: $0.marker.id, name: $0.marker.name,
                  y: max(4.5, min(max(4.5, height - 4.5), round($0.top / documentHeight * height))))
        })
    }

    func revealMarker(_ id: String) {
        guard let position = markerPositions.first(where: { $0.marker.id == id }) else { return }
        followsBottom = false
        jumping = false
        updating = true
        contentView.scroll(to: NSPoint(x: 0, y: min(scrollBottom, max(0, position.top - 24))))
        refresh()
        resizeDocument()
        guard let exactPosition = markerPositions.first(where: { $0.marker.id == id }) else { updating = false; return }
        contentView.scroll(to: NSPoint(x: 0, y: min(scrollBottom, max(0, exactPosition.top - 24))))
        refresh()
        resizeDocument()
        hosting?.layoutSubtreeIfNeeded()
        reflectScrolledClipView(contentView)
        followsBottom = AgentChatBottomFollow.follows(distance: document.bounds.height - contentView.bounds.maxY, following: false)
        updating = false
        if let exactPosition = markerPositions.first(where: { $0.marker.id == id }) { highlightMarker(exactPosition) }
    }

    func stepMarker(forward: Bool) {
        let tops = markerPositions.map(\.top)
        let targets = tops.map { min(scrollBottom, max(0, $0 - 24)) }
        let current = contentView.bounds.minY
        guard let index = AgentChatMarkerNavigation.step(tops: tops, targets: targets, current: current,
                                                        anchor: current + 24, forward: forward) else { return }
        let id = markerPositions[index].marker.id
        if let onRevealMarker { onRevealMarker(id) }
        else { revealMarker(id) }
    }

    private func highlightMarker(_ position: MarkerPosition) {
        markerHighlightTask?.cancel()
        markerHighlight?.removeFromSuperview()
        let column = columnFrame
        let highlight = AgentChatMarkerHighlight(frame: NSRect(x: column.x - 8, y: position.top - 4,
            width: column.width + 16, height: position.bottom - position.top + 8))
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 10
        highlight.phiLayer?.setBackgroundColor(ThemedColor.themeColor.withAlphaComponent(0.15))
        document.addSubview(highlight, positioned: .above, relativeTo: hosting)
        markerHighlight = highlight
        markerHighlightTask = Task { [weak self, weak highlight] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            guard let highlight else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                highlight.animator().alphaValue = 0
            } completionHandler: {}
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            highlight.removeFromSuperview()
            if self?.markerHighlight === highlight { self?.markerHighlight = nil }
        }
    }

    /// Moves the rendered rows with the reader. Cached heights keep the document height, so nothing scrolls;
    /// marking the scroll view for layout instead would also relayout the page around it.
    private func rewindow() {
        updating = true
        refresh()
        resizeDocument()
        hosting?.layoutSubtreeIfNeeded()
        updating = false
    }

    private var needsNewWindow: Bool {
        guard let window = transcriptWindow, !window.rows.isEmpty else { return false }
        guard let first = window.shown.first, let last = window.shown.last else { return true }
        let top = 16 + window.heights.prefix(first).reduce(0, +)
        let bottom = 16 + window.heights.prefix(last + 1).reduce(0, +)
        let visible = contentView.bounds
        let threshold = contentSize.height * Self.windowRewindowThreshold
        return (first > 0 && top > visible.minY - threshold) ||
            (last < window.rows.count - 1 && bottom < visible.maxY + threshold)
    }

    private func resizeDocument() {
        guard let hosting else { return }
        defer { updateMarkerTicks() }
        hosting.layoutSubtreeIfNeeded()
        let height = max(contentSize.height, contentHeight)
        let oldBottom = max(0, document.frame.height - contentSize.height)
        if liveScrolling, height != document.frame.height { liveBottoms.append(max(0, height - contentSize.height)) }
        document.setFrameSize(NSSize(width: max(1, contentSize.width), height: height))
        if let origin = expansionOrigin {
            contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, height - contentSize.height))))
            reflectScrolledClipView(contentView)
            followsBottom = AgentChatBottomFollow.follows(distance: height - contentView.bounds.maxY, following: followsBottom)
            expansionOrigin = nil
        } else if followsBottom {
            let bottom = max(0, height - contentSize.height)
            let y = contentView.bounds.minY
            // Outside 0...bottom is an elastic overscroll, which AppKit re-derives from the edge on its next
            // frame: one past the bottom moves with the growth, and snapping either back would flash a frame.
            guard y >= 0 else { return }
            contentView.scroll(to: NSPoint(x: 0, y: y > oldBottom ? y + bottom - oldBottom : bottom))
            reflectScrolledClipView(contentView)
        }
    }
}

private final class AgentChatMarkerHighlight: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// View state that changes row heights. The transcript's measurer renders its own copy of the rows,
/// where @State would start over, so both copies read this shared object instead.
final class AgentChatTranscriptViewState: ObservableObject {
    @Published var expandedPeerMessages: Set<String> = []
    @Published var expandedTools: Set<String> = []
    @Published var expandedToolGroups: Set<String> = []
    @Published var planFeedbackOpen: Set<String> = []
    /// Links opened from the transcript, so a click that opened one never also collapses its block.
    var linkOpens = 0
}

/// The rows the transcript renders; each run of other rows is one clear spacer of their measured height.
struct AgentChatTranscriptWindow: Equatable {
    var rows: [AgentChatDisplayRow]
    var status: AgentConversationStatus
    var shown: IndexSet
    var heights: [CGFloat]
    var memory: AgentMemoryFiles = .none
    var find: AgentChatFindMark?
}

struct AgentChatTranscriptSlice: Equatable {
    struct Entry: Identifiable, Equatable {
        enum ID: Hashable { case row(String), gap(Int) }
        var id: ID
        var index: Int
        var row: AgentChatDisplayRow?
        var spacing: CGFloat = 0
        var open = false
        var height: CGFloat = 0
        var marker: String? = nil
    }
    var entries: [Entry]
    var memory: AgentMemoryFiles
    var find: AgentChatFindMark?
    var slashCommands: Set<String>
    var folder: URL
    var engine: DrifterEngine
    var showsWorking: Bool
    var afterRows: Bool
    var textScale: CGFloat = 1

    init(entries: [Entry], memory: AgentMemoryFiles, find: AgentChatFindMark?, slashCommands: Set<String>, folder: URL, engine: DrifterEngine, showsWorking: Bool, afterRows: Bool) {
        self.entries = entries
        self.memory = memory
        self.find = find
        self.slashCommands = slashCommands
        self.folder = folder
        self.engine = engine
        self.showsWorking = showsWorking
        self.afterRows = afterRows
    }

    init(window: AgentChatTranscriptWindow, slashCommands: Set<String>, folder: URL, engine: DrifterEngine, showsWorking: Bool, textScale: CGFloat = 1, markers: [String: String] = [:]) {
        var entries: [Entry] = []
        if let first = window.shown.first, let last = window.shown.last {
            var index = first
            while index <= last {
                if window.shown.contains(index) {
                    let row = window.rows[index]
                    entries.append(Entry(id: .row(row.id), index: index, row: row,
                                         spacing: AgentChatTranscriptRows.spacing(before: row, after: index > 0 ? window.rows[index - 1] : nil),
                                         open: AgentChatDisplayRow.isOpen(at: index, of: window.rows, status: window.status), marker: markers[row.id]))
                    index += 1
                } else {
                    let first = index
                    var height: CGFloat = 0
                    while index <= last && !window.shown.contains(index) { height += window.heights[index]; index += 1 }
                    entries.append(Entry(id: .gap(first), index: first, row: nil, height: height))
                }
            }
        }
        self.init(entries: entries, memory: window.memory, find: window.find, slashCommands: slashCommands, folder: folder, engine: engine,
                  showsWorking: showsWorking && (window.rows.isEmpty || window.shown.contains(window.rows.count - 1)), afterRows: !window.rows.isEmpty)
        self.textScale = textScale
    }
}

struct AgentChatTranscriptRows: View {
    var conversation: AgentConversation
    var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    var engine: DrifterEngine = .claude
    var slashCommands: Set<String> = []
    var viewState = AgentChatTranscriptViewState()
    var slice: AgentChatTranscriptSlice? = nil

    func displayRows() -> (rows: [AgentChatDisplayRow], memory: AgentMemoryFiles) {
        let memory = AgentMemoryFiles(folders: conversation.memoryFolders, skillFolders: conversation.skillFolders)
        return (AgentChatDisplayRow.rows(from: conversation.items, memory: memory, cwd: folder), memory)
    }

    func row(at index: Int, rows: [AgentChatDisplayRow], memory: AgentMemoryFiles,
             status: AgentConversationStatus, marker: String? = nil) -> AgentChatTranscriptRow {
        row(rows[index], spacing: Self.spacing(before: rows[index], after: index > 0 ? rows[index - 1] : nil),
            open: AgentChatDisplayRow.isOpen(at: index, of: rows, status: status), memory: memory, find: nil, marker: marker)
    }

    private func row(_ row: AgentChatDisplayRow, spacing: CGFloat, open: Bool, memory: AgentMemoryFiles, find: AgentChatFindMark?, marker: String?) -> AgentChatTranscriptRow {
        AgentChatTranscriptRow(row: row, spacing: spacing, open: open, memory: memory,
                               folder: folder, engine: engine, slashCommands: slashCommands,
                               viewState: viewState, decide: decidePermission, mcpAction: { conversation.onMCPServerAction?($0, $1) }, openAttachment: { conversation.onOpenAttachment?($0) },
                               background: { conversation.onBackgroundTool?($0) },
                               findHighlight: find.map { AgentChatFindHighlight(query: $0.query, current: $0.rowId == row.id ? $0.ordinal : nil) }, textScale: slice?.textScale ?? 1,
                               marker: marker, addMarker: { addMarker(row.id) }, renameMarker: { conversation.renameMarker(itemId: row.id, to: $0) },
                               showMarker: { anchor in
                                   let popover = AgentChatMarkerListPopover.show(conversation: conversation, anchor: anchor, only: row.id,
                                       onClose: { [weak anchor] in (anchor as? AgentChatMarkerButton)?.markerPopoverDidClose() })
                                   (anchor as? AgentChatMarkerButton)?.trackMarkerPopover(popover)
                               })
    }

    private func addMarker(_ id: String) -> AgentChatMarker? {
        guard !conversation.markers.contains(where: { $0.id == id }),
              let index = conversation.items.firstIndex(where: { $0.id == id }),
              let text = conversation.items[index].markerText else { return nil }
        let precedingIDs = Set(conversation.items[..<index].map(\.id))
        let position = conversation.markers.filter { precedingIDs.contains($0.id) }.count + 1
        let defaultName = AgentChatMarkers.defaultName(text: text, position: position)
        guard let marker = conversation.toggleMarker(itemId: id, defaultName: defaultName) else { return nil }
        if let input = AgentChatMarkers.namingInput(items: conversation.items, itemId: id) {
            Task { @MainActor in
                guard let name = await CodexMarkerNamer.name(text: input.text, context: input.context) else { return }
                conversation.applyGeneratedMarkerName(itemId: id, name: name, replacing: defaultName)
            }
        }
        return marker
    }

    var openURL: OpenURLAction {
        OpenURLAction { [viewState] url in
            viewState.linkOpens += 1
            conversation.onOpenLink?(url)
            return .handled
        }
    }

    func workingRow(afterRows: Bool) -> some View {
        AgentChatWorkingRow(conversation: conversation, engine: engine).padding(.top, afterRows ? 18 : 0)
    }

    var body: some View {
        Group {
            if let slice {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slice.entries) { entry in
                        if let value = entry.row {
                            row(value, spacing: entry.spacing, open: entry.open, memory: slice.memory, find: slice.find, marker: entry.marker).equatable()
                        } else { Color.clear.frame(height: entry.height) }
                    }
                    if slice.showsWorking { workingRow(afterRows: slice.afterRows) }
                }
            } else {
                let (rows, memory) = displayRows()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        row(at: index, rows: rows, memory: memory, status: conversation.status).equatable()
                    }
                    if conversation.showsWorkingIndicator { workingRow(afterRows: !rows.isEmpty) }
                }.padding(.vertical, 16)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .font(.system(size: NSFont.systemFontSize * (slice?.textScale ?? 1)))
            .environment(\.agentChatTextScale, slice?.textScale ?? 1)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, openURL)
    }

    static func spacing(before row: AgentChatDisplayRow, after previous: AgentChatDisplayRow?) -> CGFloat {
        guard let previous else { return 0 }
        if case let .item(item) = row, case .permissionRequest = item.kind {
            if case .toolGroup = previous { return 6 }
            if case let .item(prior) = previous, case .toolCall = prior.kind { return 6 }
        }
        return isCard(row) && isCard(previous) ? 10 : 18
    }

    static func isCard(_ row: AgentChatDisplayRow) -> Bool {
        switch row {
        case .toolGroup: return true
        case let .item(item):
            switch item.kind {
            case .toolCall, .shellCommand, .contextUsage, .mcpServers, .peerMessage, .taskNotification: return true
            case let .permissionRequest(request):
                return request.status == .pending || ["AskUserQuestion", "ExitPlanMode"].contains(request.toolName)
            case .userMessage: return true
            default: return false
            }
        }
    }

    func decidePermission(_ requestId: String, _ response: AgentPermissionResponse) {
        conversation.onPermissionDecision?(requestId, response)
    }
}

/// Equatable without its closures, which only reach the conversation, so a transcript update
/// re-renders and re-sizes only the rows that changed.
struct AgentChatTranscriptRow: View, Equatable {
    let row: AgentChatDisplayRow
    let spacing: CGFloat
    let open: Bool
    let memory: AgentMemoryFiles
    let folder: URL
    let engine: DrifterEngine
    let slashCommands: Set<String>
    let viewState: AgentChatTranscriptViewState
    let decide: (String, AgentPermissionResponse) -> Void
    let mcpAction: (String, ClaudeCodeMCPServerAction) -> Void
    let openAttachment: (AgentAttachment) -> Void
    var background: ((String) -> Void)? = nil
    var findHighlight: AgentChatFindHighlight? = nil
    var textScale: CGFloat = 1
    var marker: String? = nil
    var addMarker: () -> AgentChatMarker? = { nil }
    var renameMarker: (String) -> Void = { _ in }
    var showMarker: (NSView) -> Void = { _ in }
    @State private var markerHovering = false
    @Environment(\.agentChatMeasuring) private var measuring

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.spacing == rhs.spacing && lhs.open == rhs.open && lhs.memory == rhs.memory
            && lhs.folder == rhs.folder && lhs.engine == rhs.engine && lhs.slashCommands == rhs.slashCommands
            && lhs.viewState === rhs.viewState && lhs.findHighlight == rhs.findHighlight && lhs.textScale == rhs.textScale && lhs.marker == rhs.marker
    }

    private var isReply: Bool {
        if case let .item(item) = row, case .assistantText = item.kind { return true }
        return false
    }

    /// How far a reply's first capitals sit below its top: the text view's 4 pt inset, the line's extra height and the
    /// font's ascent above its capitals.
    @MainActor static func capInset(textScale: CGFloat) -> CGFloat {
        let font = AgentChatTypography.font(ofSize: AgentChatTypography.bodySize * textScale)
        let leading: CGFloat = MistTileCard<EmptyView, EmptyView>.lineHeight(font) * (AgentChatTypography.lineHeightMultiple - 1)
        return 4 + leading + (font.ascender - font.capHeight)
    }

    /// The reply's marker button, 22 pt tall, centers between the row above and the reply's first capitals.
    /// Centering it in the spacing alone put it against the row above.
    @MainActor static func markerButtonTop(spacing: CGFloat, textScale: CGFloat) -> CGFloat {
        max(0, (spacing + capInset(textScale: textScale) - 22) / 2)
    }

    /// A reply opening with a code block or table draws its box from the text view's 4 pt inset, above where a text
    /// reply's capitals start, so the marker button ran into it. The reply moves down to start its box there instead.
    private var boxInset: CGFloat {
        guard case let .item(item) = row, case let .assistantText(text, _) = item.kind, MarkdownRenderer.opensWithBox(text) else { return 0 }
        return ceil(Self.capInset(textScale: textScale) - 4)
    }

    var body: some View {
        let content = Group {
            switch row {
            case let .item(item):
                AgentChatItemView(item: item, decide: decide, folder: folder, engine: engine,
                                  slashCommands: slashCommands, viewState: viewState, mcpAction: mcpAction, openAttachment: openAttachment, background: background, findHighlight: findHighlight,
                                  marker: marker, addMarker: addMarker, renameMarker: renameMarker, showMarker: showMarker)
            case let .toolGroup(tools):
                AgentChatToolGroupView(tools: tools, folder: folder, viewState: viewState, memory: memory, open: open, background: background, findHighlight: findHighlight)
            }
        }.padding(.top, spacing + boxInset)
        // Only replies get the overlay and hover state: hovering any other row must not re-render it, and the
        // measurer, which re-measures the streamed reply per update, never builds the button.
        if isReply && !measuring {
            content
                .overlay(alignment: .topTrailing) {
                    AgentChatRowMarkerButton(name: marker, visible: markerHovering || marker != nil, add: addMarker, showMarker: showMarker, rename: renameMarker)
                        .frame(width: 24, height: 22).offset(y: Self.markerButtonTop(spacing: spacing, textScale: textScale))
                }
                .onHover { markerHovering = $0 }
        } else {
            content
        }
    }
}

private struct AgentChatFixedIconLabelStyle: LabelStyle {
    var size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: size))
            configuration.title
        }
    }
}

private struct AgentChatWorkingRow: View {
    @Environment(\.agentChatTextScale) private var textScale
    @ObservedObject var conversation: AgentConversation
    let engine: DrifterEngine
    @AgentChatColors private var colors

    var body: some View {
        let icon = AgentChatIcon.resolve(engine: engine)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                // Opacity is computed from the clock, not animated: an animation
                // transaction would also carry the row's first layout and slide the icon.
                TimelineView(.animation) { pulse in
                    Image(icon.rawValue).renderingMode(icon.isTemplate ? .template : .original).resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                        .opacity(0.725 + 0.275 * cos(pulse.date.timeIntervalSinceReferenceDate * .pi / 1.2))
                }
                Text(AgentChatStrings.workingWord(conversation.workingWord))
                    .foregroundStyle(engine == .claude
                        ? Color(red: 0.85, green: 0.47, blue: 0.35) : colors.resolve(.textPrimary))
                Text(AgentChatStrings.workingProgress(elapsed: context.date.timeIntervalSince(conversation.turnStartedAt), tokens: conversation.outputTokens))
                    .foregroundStyle(colors.resolve(.textSecondary))
            }.font(Font(AgentChatTerminalFont.font(scale: textScale))).lineLimit(1)
        }.accessibilityIdentifier("agentChat.working")
    }
}

struct AgentChatItemView: View {
    @Environment(\.agentChatTextScale) private var textScale
    @AgentChatColors private var colors
    let item: AgentChatItem
    let decide: (String, AgentPermissionResponse) -> Void
    var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    var engine: DrifterEngine = .claude
    var slashCommands: Set<String> = []
    var viewState = AgentChatTranscriptViewState()
    var mcpAction: (String, ClaudeCodeMCPServerAction) -> Void = { _, _ in }
    var openAttachment: (AgentAttachment) -> Void = { _ in }
    var background: ((String) -> Void)? = nil
    var findHighlight: AgentChatFindHighlight? = nil

    var marker: String? = nil
    var addMarker: () -> AgentChatMarker? = { nil }
    var renameMarker: (String) -> Void = { _ in }
    var showMarker: (NSView) -> Void = { _ in }

    var body: some View {
        Group {
            switch item.kind {
            case let .userMessage(text, images):
                AgentChatUserMessageView(text: text, images: images, files: item.files, mentions: item.mentions,
                                         slashCommands: slashCommands, openAttachment: openAttachment, findHighlight: findHighlight,
                                         marker: marker, addMarker: addMarker, renameMarker: renameMarker, showMarker: showMarker)
            case let .assistantText(text, _):
                AgentChatRichText(text: text, slashCommands: slashCommands, findHighlight: findHighlight, renderKey: item.id)
            case let .peerMessage(name, body):
                AgentChatPeerMessageView(id: item.id, name: name, text: body, slashCommands: slashCommands, viewState: viewState)
            case let .toolCall(tool):
                AgentChatToolView(tool: tool, folder: folder, viewState: viewState, background: background, findHighlight: findHighlight)
            case let .shellCommand(command):
                AgentChatShellCommandView(id: item.id, command: command, viewState: viewState)
            case let .commandOutput(_, text, isError):
                AgentChatCommandOutputView(id: item.id, text: text, isError: isError, viewState: viewState)
            case let .contextUsage(usage):
                AgentChatContextUsageCard(usage: usage)
            case let .mcpServers(status):
                AgentChatMCPServersCard(id: item.id, status: status, viewState: viewState, action: mcpAction)
            case let .compaction(trigger, pre, post):
                HStack {
                    Rectangle().fill(colors.resolve(.mistHairline)).frame(height: 1)
                    Text(AgentChatStrings.compaction(trigger, preTokens: pre, postTokens: post))
                        .font(.system(size: 11 * textScale)).foregroundStyle(colors.resolve(.textSecondary)).fixedSize()
                    Rectangle().fill(colors.resolve(.mistHairline)).frame(height: 1)
                }.frame(minHeight: 16).padding(.vertical, 20)
            case let .permissionRequest(request):
                if request.status != .pending, !["AskUserQuestion", "ExitPlanMode"].contains(request.toolName) {
                    Text(request.status == .allowed ? AgentChatStrings.allowed : AgentChatStrings.denied)
                        .foregroundStyle(colors.resolve(.textSecondary))
                } else {
                    AgentChatPermissionCard(request: request, folder: folder, engine: engine, decide: decide, viewState: viewState)
                }
            case let .notice(text, level):
                Label(text, systemImage: level == .error ? "exclamationmark.circle" : "info.circle")
                    .labelStyle(AgentChatFixedIconLabelStyle(size: NSFont.systemFontSize))
                    .foregroundStyle(level == .error ? Color.red : colors.resolve(.textSecondary)).agentChatSelectable()
            case let .taskNotification(summary, status):
                MistTileCard(symbol: "clock.arrow.circlepath", firstLineHeight: AgentChatTerminalFont.lineHeight(scale: textScale),
                             capHeight: AgentChatTerminalFont.capHeight(scale: textScale)) {
                    Text(verbatim: AgentChatStrings.taskNotification(summary)).foregroundStyle(colors.resolve(.textPrimary)).agentChatSelectable()
                } trailing: {
                    MistDot(color: status == .completed ? .mistSuccess : status == .failed ? .mistError : .textTertiary)
                }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
                    .accessibilityIdentifier("agentChat.taskNotification")
            case let .turnEnd(milliseconds, finishedAt, stopped):
                HStack {
                    Rectangle().fill(colors.resolve(.mistHairline)).frame(height: 1)
                    Self.turnEndLabel(milliseconds, finishedAt: finishedAt, stopped: stopped, scale: textScale)
                        .foregroundStyle(colors.resolve(.textSecondary))
                    Rectangle().fill(colors.resolve(.mistHairline)).frame(height: 1)
                }.frame(minHeight: 16).padding(.vertical, 20)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(colors.resolve(.textPrimary))
    }

    /// Only file tools carry a path; shortening a command could change what the user approves.
    static func permissionArgument(_ request: AgentChatItem.PermissionRequest, folder: URL) -> String {
        ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(request.toolName)
            ? ClaudeCodeToolSummary.path(request.summary, folder: folder) : request.summary
    }

    static func duration(_ milliseconds: Int, finishedAt: Date) -> String {
        let finish = DateFormatter()
        finish.timeStyle = .short
        finish.dateStyle = .medium
        return String(format: AgentChatStrings.turnFinished, AgentChatStrings.elapsed(Double(milliseconds) / 1000), finish.string(from: finishedAt))
    }

    static func turnEndLabel(_ milliseconds: Int, finishedAt: Date, stopped: Bool, scale: CGFloat = 1) -> some View {
        ((stopped ? Text(AgentChatStrings.stopped).fontWeight(.semibold).foregroundColor(Color(nsColor: .systemOrange)) + Text(" · ") : Text(""))
            + Text(duration(milliseconds, finishedAt: finishedAt)))
            .font(.system(size: 11 * scale)).fixedSize()
    }
}

struct AgentChatCommandOutputView: View {
    @Environment(\.agentChatTextScale) private var textScale
    let id: String
    let text: String
    let isError: Bool
    @ObservedObject var viewState: AgentChatTranscriptViewState
    @AgentChatColors private var colors

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let expanded = viewState.expandedTools.contains(id)
        let visible = (expanded ? lines : Array(lines.prefix(10))).joined(separator: "\n")
        HStack(alignment: .top, spacing: 8) {
            Text("⎿").foregroundStyle(colors.resolve(.textSecondary))
            VStack(alignment: .leading, spacing: 5) {
                Text((try? AttributedString(markdown: visible,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(visible))
                    .agentChatSelectable().foregroundStyle(isError ? Color.red : colors.resolve(.textPrimary))
                    .tint(Color(nsColor: .linkColor))
                    .fixedSize(horizontal: false, vertical: true)
                if lines.count > 10 {
                    Button(expanded ? AgentChatStrings.toolCollapse : String(format: AgentChatStrings.toolMore, lines.count - 10)) {
                        viewState.expandedTools.formSymmetricDifference([id])
                    }.buttonStyle(.plain).foregroundStyle(colors.resolve(.textSecondary)).agentChatHand()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
            .agentChatCollapsible(expanded && lines.count > 10) { _ = viewState.expandedTools.remove(id) }
    }
}

struct AgentChatMCPServersCard: View {
    @Environment(\.agentChatTextScale) private var textScale
    let id: String
    let status: ClaudeCodeMCPStatus
    @ObservedObject var viewState: AgentChatTranscriptViewState
    let action: (String, ClaudeCodeMCPServerAction) -> Void
    @AgentChatColors private var colors

    private func group(_ server: ClaudeCodeMCPStatus.Server) -> String {
        ["pending", "connected", "needs-auth", "disabled"].contains(server.status) ? server.status : "failed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AgentChatStrings.mcpTitle).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(AgentChatStrings.mcpServers(status.servers.count)).foregroundStyle(colors.resolve(.textSecondary))
            }
            ForEach(["failed", "pending", "connected", "needs-auth", "disabled"], id: \.self) { kind in
                let servers = status.servers.filter { group($0) == kind }
                if !servers.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        if kind == "needs-auth" {
                            Button {
                                viewState.expandedTools.formSymmetricDifference([id])
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: viewState.expandedTools.contains(id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 12))
                                    Text(AgentChatStrings.mcpNeedsCount(servers.count))
                                }
                            }.buttonStyle(.plain).foregroundStyle(colors.resolve(.textSecondary)).agentChatHand()
                        } else {
                            Text("\(AgentChatStrings.mcpGroup(kind)) · \(servers.count)")
                                .foregroundStyle(colors.resolve(.textSecondary))
                        }
                        if kind != "needs-auth" || viewState.expandedTools.contains(id) {
                            ForEach(servers.indices, id: \.self) { index in
                                AgentChatMCPServerRow(server: servers[index], live: status.live,
                                    busy: status.busy.contains(servers[index].name), error: status.actionErrors[servers[index].name], action: action)
                            }
                            if kind == "needs-auth" {
                                Text(AgentChatStrings.mcpAuthenticate).foregroundStyle(colors.resolve(.textSecondary))
                            }
                        }
                    }
                }
            }
        }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mistCardBackground(.inner)
    }
}

private struct AgentChatMCPServerRow: View {
    @Environment(\.agentChatTextScale) private var textScale
    let server: ClaudeCodeMCPStatus.Server
    let live: Bool
    let busy: Bool
    let error: String?
    let action: (String, ClaudeCodeMCPServerAction) -> Void
    @State private var hovering = false
    @AgentChatColors private var colors

    private var dot: Color {
        switch server.status {
        case "connected": return .green
        case "needs-auth": return .orange
        case "pending", "disabled": return colors.resolve(.textSecondary)
        default: return .red
        }
    }
    private var actions: [(String, ClaudeCodeMCPServerAction)] {
        switch server.status {
        case "pending": return []
        case "needs-auth": return [(AgentChatStrings.mcpDisable, .disable)]
        case "disabled": return [(AgentChatStrings.mcpEnable, .enable)]
        default: return [(AgentChatStrings.mcpReconnect, .reconnect), (AgentChatStrings.mcpDisable, .disable)]
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(verbatim: server.name).lineLimit(1)
            if let scope = server.scope, scope != "claudeai" {
                Text(verbatim: scope).font(.system(size: 10 * textScale)).foregroundStyle(colors.resolve(.textSecondary)).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let error { Text(verbatim: error).foregroundStyle(.red).lineLimit(1) }
                else if server.status == "pending" { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                else if server.status == "connected", let count = server.toolCount {
                    Text(AgentChatStrings.mcpTools(count)).foregroundStyle(colors.resolve(.textSecondary)).lineLimit(1)
                } else if server.status != "disabled" && server.status != "needs-auth" {
                    Text(verbatim: server.status == "failed" ? (server.error ?? "") : server.status)
                        .foregroundStyle(colors.resolve(.textSecondary)).lineLimit(1)
                }
                if live && busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                else if live && hovering {
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].0) { action(server.name, actions[index].1) }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 18)
        }.frame(height: 18).onHover { hovering = $0 }
    }
}

struct AgentChatContextUsageCard: View {
    @Environment(\.agentChatTextScale) private var textScale
    let usage: ClaudeCodeContextUsage
    @AgentChatColors private var colors
    private let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .yellow]
    private var track: Color { colors.resolve(.textSecondary).opacity(0.2) }

    private func color(at index: Int) -> Color {
        switch usage.categories[index].kind {
        case "used": return palette[usage.categories.prefix(index).filter { $0.kind == "used" }.count % palette.count]
        case "buffer": return colors.resolve(.textSecondary).opacity(0.4)
        default: return track
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AgentChatStrings.contextUsage).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(String(format: NSLocalizedString("browser.claudeCode.contextTokens", value: "%@ of %@ tokens",
                    comment: "Claude Code header - Used tokens and context window size"),
                    usage.totalTokens.formatted(), usage.maxTokens.formatted()) + " · \(usage.percentage.formatted())%")
                    .foregroundStyle(colors.resolve(.textSecondary))
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(usage.categories.indices, id: \.self) { index in
                        if ["used", "buffer"].contains(usage.categories[index].kind) {
                            color(at: index).frame(width: geometry.size.width * fraction(usage.categories[index].tokens))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).background(track).clipShape(Capsule())
            }.frame(height: 6)
            ForEach(usage.categories.indices, id: \.self) { index in
                let category = usage.categories[index]
                HStack(spacing: 8) {
                    if category.kind == "deferred" {
                        Circle().strokeBorder(colors.resolve(.textSecondary), lineWidth: 1).frame(width: 8, height: 8)
                    } else { Circle().fill(color(at: index)).frame(width: 8, height: 8) }
                    Text(verbatim: category.name)
                        .foregroundStyle(colors.resolve(category.kind == "deferred" ? .textSecondary : .textPrimary))
                    Spacer(minLength: 8)
                    Text(verbatim: category.tokens.formatted())
                    Text(verbatim: fraction(category.tokens).formatted(.percent.precision(.fractionLength(1))))
                        .frame(minWidth: 60, alignment: .trailing)
                }.foregroundStyle(colors.resolve(.textSecondary))
            }
        }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mistCardBackground(.inner)
    }

    private func fraction(_ tokens: Int) -> Double { usage.maxTokens > 0 ? min(1, max(0, Double(tokens) / Double(usage.maxTokens))) : 0 }
}

struct AgentChatShellCommandView: View {
    @Environment(\.agentChatTextScale) private var textScale
    let id: String
    let command: AgentChatItem.ShellCommand
    @ObservedObject var viewState: AgentChatTranscriptViewState
    @AgentChatColors private var colors
    private var expanded: Bool { viewState.expandedTools.contains(id) }
    private var running: Bool { command.status == .running }

    struct Line {
        enum Style { case normal, error, dim }
        let text: String
        let style: Style
    }

    static func lines(_ output: ShellOutput, stderr: Bool) -> [Line] {
        func lines(_ text: String) -> [Line] {
            let clean = ClaudeCodeShellText.clean(text)
            guard !clean.isEmpty else { return [] }
            var lines = clean.components(separatedBy: "\n")
            while lines.last == "" { lines.removeLast() }
            return lines.map { Line(text: $0, style: stderr ? .error : .normal) }
        }
        if output.omitted > 0 {
            return lines(output.head) + [Line(text: AgentChatStrings.shellTruncated, style: .dim)] + lines(output.tail)
        }
        return lines(output.head + output.tail)
    }

    var body: some View {
        let lines = Self.lines(command.stdout, stderr: false) + Self.lines(command.stderr, stderr: true)
        let visible = expanded ? lines : running ? Array(lines.suffix(10)) : Array(lines.prefix(10))
        MistTileCard(symbol: "terminal", firstLineHeight: AgentChatTerminalFont.lineHeight(scale: textScale),
                     capHeight: AgentChatTerminalFont.capHeight(scale: textScale)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimelineView(.animation(paused: !running)) { context in
                        Text("!").bold().foregroundStyle(colors.resolve(.textSecondary))
                            .opacity(running ? 0.675 + 0.325 * cos(context.date.timeIntervalSinceReferenceDate * .pi) : 1)
                    }
                    Text(verbatim: command.command).agentChatSelectable().fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.text.isEmpty ? " " : line.text).agentChatSelectable()
                        .foregroundStyle(line.style == .error ? Color.red : colors.resolve(line.style == .dim ? .textSecondary : .textPrimary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.isEmpty && !running {
                    Text(AgentChatStrings.toolNoOutput).foregroundStyle(colors.resolve(.textSecondary))
                }
                if let code = command.exitCode, code != 0, command.status != .stopped {
                    Text(String(format: AgentChatStrings.shellExitCode, code)).foregroundStyle(Color.red)
                }
                if lines.count > 10 {
                    Button(expanded ? AgentChatStrings.toolCollapse : String(format: AgentChatStrings.toolMore, lines.count - 10)) {
                        viewState.expandedTools.formSymmetricDifference([id])
                    }.buttonStyle(.plain).foregroundStyle(colors.resolve(.textSecondary)).agentChatHand()
                }
            }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
        }
            .agentChatCollapsible(expanded && lines.count > 10) { _ = viewState.expandedTools.remove(id) }
            .accessibilityIdentifier("agentChat.shellCommand")
    }
}

private struct AgentChatPeerMessageView: View {
    @Environment(\.agentChatTextScale) private var textScale
    let id: String
    let name: String
    let text: String
    let slashCommands: Set<String>
    @ObservedObject var viewState: AgentChatTranscriptViewState
    @AgentChatColors private var colors
    private var expanded: Bool { viewState.expandedPeerMessages.contains(id) }

    var body: some View {
        MistTileCard(symbol: "bubble.left", firstLineHeight: AgentChatTerminalFont.lineHeight(scale: textScale)) {
            VStack(alignment: .leading, spacing: 8) {
                Button { viewState.expandedPeerMessages.formSymmetricDifference([id]) } label: {
                    Text(AgentChatStrings.peerMessage(name, firstLine: text.components(separatedBy: .newlines).first ?? ""))
                        .font(Font(AgentChatTerminalFont.font(scale: textScale))).foregroundStyle(colors.resolve(.textSecondary))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).agentChatHand()
                if expanded {
                    AgentChatRichText(text: text, slashCommands: slashCommands)
                }
            }
        }
            .agentChatCollapsible(expanded) { _ = viewState.expandedPeerMessages.remove(id) }
            .accessibilityIdentifier("agentChat.peerMessage")
    }
}

struct AgentChatPermissionCard: View {
    @Environment(\.agentChatTextScale) private var textScale
    let request: AgentChatItem.PermissionRequest
    var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    var engine: DrifterEngine = .claude
    let decide: (String, AgentPermissionResponse) -> Void
    @ObservedObject var viewState = AgentChatTranscriptViewState()
    @AgentChatColors private var colors
    @State private var selections: [Int: AgentPermissionQuestion.Selection] = [:]
    @State private var feedback = ""

    private var givingFeedback: Bool { viewState.planFeedbackOpen.contains(request.requestId) }
    private var symbol: String {
        if request.toolName == "AskUserQuestion" { return "questionmark.bubble" }
        if request.toolName == "ExitPlanMode" { return "list.bullet.clipboard" }
        return AgentChatStrings.browserPermission(request) == nil ? AgentChatToolGroupKind(request.toolName).symbol : "globe"
    }

    func submit(_ selections: [Int: AgentPermissionQuestion.Selection]) {
        guard request.status == .pending, let response = request.answerResponse(selections) else { return }
        decide(request.requestId, response)
    }

    func approve() {
        guard request.status == .pending else { return }
        decide(request.requestId, .allow)
    }

    func keepPlanning(_ feedback: String) {
        guard request.status == .pending else { return }
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        decide(request.requestId, .deny(message: text.isEmpty ? "The user wants to keep planning." : text))
    }

    var body: some View {
        MistTileCard(symbol: symbol, firstLineHeight: MistTileCard<EmptyView, EmptyView>.lineHeight(.systemFont(ofSize: NSFont.systemFontSize * textScale)),
                     padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            VStack(alignment: .leading, spacing: 10) {
                if request.toolName == "AskUserQuestion" {
                    questions
                } else if request.toolName == "ExitPlanMode" {
                    plan
                } else {
                    if let browser = AgentChatStrings.browserPermission(request) {
                        Text(browser.title)
                        if let message = browser.message, !message.isEmpty {
                            AgentChatRichText(text: message)
                        }
                        if let detail = browser.detail, !detail.isEmpty {
                            Text(verbatim: detail).foregroundStyle(colors.resolve(.textSecondary)).agentChatSelectable()
                        }
                    } else {
                        let name = AgentChatToolGroupKind.displayName(request.toolName)
                        Text(String(format: AgentChatStrings.permission, name))
                        (Text(name).bold() + Text("(" + AgentChatItemView.permissionArgument(request, folder: folder) + ")"))
                            .font(Font(AgentChatTerminalFont.font(scale: textScale))).agentChatSelectable()
                        if let server = AgentChatToolGroupKind.serverName(request.toolName) {
                            Text(verbatim: server).foregroundStyle(colors.resolve(.textSecondary))
                        }
                    }
                    if request.status == .pending {
                        HStack {
                            Button(AgentChatStrings.allow) { decide(request.requestId, .allow) }.keyboardShortcut(.defaultAction)
                                .buttonStyle(.mist(.primary, size: .regular))
                            Button(AgentChatStrings.deny) { decide(request.requestId, .deny(message: nil)) }
                                .buttonStyle(.mist(.secondary, size: .regular))
                        }
                    } else { resolution }
                }
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty {
                        Text(question.header).font(.system(size: 11 * textScale)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(colors.resolve(.mistChipFill), in: Capsule())
                    }
                    Text(question.question).agentChatSelectable()
                    if request.status == .pending {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                            Button {
                                selections[index, default: .init()].toggle(optionIndex, multiSelect: question.multiSelect)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: selectionSymbol(selected: selections[index]?.options.contains(optionIndex) == true, multi: question.multiSelect))
                                        .font(.system(size: NSFont.systemFontSize))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.label).bold()
                                        Text(option.description).foregroundStyle(colors.resolve(.textSecondary))
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.vertical, 4)
                        }
                        HStack(spacing: 8) {
                            Button {
                                if question.multiSelect && selections[index]?.otherSelected == true {
                                    selections[index, default: .init()].otherSelected = false
                                } else { selections[index, default: .init()].selectOther(multiSelect: question.multiSelect) }
                            } label: {
                                Image(systemName: selectionSymbol(selected: selections[index]?.otherSelected == true, multi: question.multiSelect))
                                    .font(.system(size: NSFont.systemFontSize))
                            }.buttonStyle(.plain).accessibilityLabel(AgentChatStrings.other)
                            MistFieldWell(shape: .rounded) {
                                TextField(AgentChatStrings.other, text: Binding(get: { selections[index]?.other ?? "" }, set: { value in
                                    selections[index, default: .init()].other = value
                                    selections[index, default: .init()].selectOther(multiSelect: question.multiSelect)
                                }))
                            }
                        }
                    } else if let answer = request.answers[question.question]?.string {
                        Text(answer).foregroundStyle(colors.resolve(.textSecondary)).agentChatSelectable()
                    }
                }
            }
            if request.status == .pending {
                HStack {
                    Button(AgentChatStrings.submit) { submit(selections) }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.mist(.primary, size: .regular))
                        .disabled(request.answerResponse(selections) == nil)
                    Button(AgentChatStrings.skip) { decide(request.requestId, .deny(message: "The user declined to answer.")) }
                        .buttonStyle(.mist(.secondary, size: .regular))
                }
            } else { resolution }
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AgentChatStrings.planTitle).bold()
            AgentChatRichText(text: request.input["plan"].string ?? request.plan ?? "")
            if request.status == .pending {
                HStack {
                    // Return in the feedback field must not approve the plan.
                    Button(AgentChatStrings.approve) { approve() }
                        .buttonStyle(.mist(.primary, size: .regular))
                    Button(AgentChatStrings.keepPlanning) { viewState.planFeedbackOpen.insert(request.requestId) }
                        .buttonStyle(.mist(.secondary, size: .regular))
                }
                if givingFeedback {
                    // A fixed height keeps typing from changing the row height the measurer can't see.
                    MistFieldWell(shape: .rounded, height: nil) {
                        TextField(AgentChatStrings.planFeedback, text: $feedback, axis: .vertical).lineLimit(3, reservesSpace: true)
                    }
                    Button(AgentChatStrings.keepPlanning) { keepPlanning(feedback) }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.mist(.secondary, size: .regular))
                }
            } else { resolution }
        }
    }

    @ViewBuilder private var resolution: some View {
        if request.toolName == "ExitPlanMode", request.resolution != nil {
            Text(request.status == .allowed ? AgentChatStrings.planApproved : AgentChatStrings.keptPlanning)
                .foregroundStyle(colors.resolve(.textSecondary))
            if case let .deny(message) = request.resolution, let message {
                Text(message).agentChatSelectable().foregroundStyle(colors.resolve(.textSecondary))
            }
        } else {
            Text(request.toolName == "AskUserQuestion" && request.status == .allowed ? AgentChatStrings.answered :
                    request.status == .allowed ? AgentChatStrings.allowed : AgentChatStrings.denied)
                .foregroundStyle(colors.resolve(.textSecondary))
        }
    }

    private func selectionSymbol(selected: Bool, multi: Bool) -> String {
        multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
    }
}

struct AgentChatToolGroupView: View {
    @Environment(\.agentChatTextScale) private var textScale
    let tools: [AgentChatItem.ToolCall]
    let folder: URL
    @ObservedObject var viewState: AgentChatTranscriptViewState
    var memory: AgentMemoryFiles = .none
    /// The running turn may still add actions to this group.
    var open = false
    var background: ((String) -> Void)? = nil
    var findHighlight: AgentChatFindHighlight? = nil
    @AgentChatColors private var colors
    private var expanded: Bool { viewState.expandedToolGroups.contains(tools[0].toolUseId) }
    private var shown: [AgentChatItem.ToolCall] { AgentChatToolGroupKind.shown(tools, open: open) }
    private var running: AgentChatItem.ToolCall? { shown.first { $0.status == .running } }
    private var symbol: String {
        let kinds = Set(tools.map { AgentChatToolGroupKind.kind(of: $0, memory: memory, cwd: folder) })
        return kinds.count == 1 ? kinds.first!.symbol : "square.stack.3d.up"
    }

    static func lines(_ tools: [AgentChatItem.ToolCall], folder: URL, memory: AgentMemoryFiles,
                      open: Bool, expanded: Bool) -> [ClaudeCodeToolSummary.Line] {
        let shown = AgentChatToolGroupKind.shown(tools, open: open)
        let summary = AgentChatToolGroupKind.summary(shown, memory: memory, cwd: folder)
        var lines = [summary]
        if let running = shown.first(where: { $0.status == .running }) {
            let current = AgentChatToolView.lines(running, folder: folder)[0]
            if current.text != summary.text { lines.append(current) }
        }
        if expanded { lines += tools.flatMap { AgentChatToolView.lines($0, folder: folder) } }
        return lines
    }

    var body: some View {
        let headers = Self.lines(tools, folder: folder, memory: memory, open: open, expanded: false)
        let children = expanded ? childHighlights(after: headers) : []
        MistTileCard(symbol: symbol, firstLineHeight: AgentChatTerminalFont.lineHeight(scale: textScale),
                     capHeight: AgentChatTerminalFont.capHeight(scale: textScale)) {
            VStack(alignment: .leading, spacing: 5) {
                Button { toggle() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        styled(headers[0], highlight: findHighlight?.line(0, in: headers))
                        if headers.count > 1 {
                            styled(headers[1], highlight: findHighlight?.line(1, in: headers))
                                .foregroundStyle(colors.resolve(.textSecondary))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).agentChatHand()
                if expanded {
                    ForEach(Array(tools.enumerated()), id: \.element.toolUseId) { index, tool in
                        AgentChatToolView(tool: tool, folder: folder, viewState: viewState, grouped: true,
                                          findHighlight: children[index])
                    }
                    Button(AgentChatStrings.toolCollapse) { toggle() }
                        .buttonStyle(.plain).foregroundStyle(colors.resolve(.textSecondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
        } trailing: {
            HStack(spacing: 8) {
                if let background, tools.contains(where: \.canBackground) {
                    Button(AgentChatStrings.runInBackground) {
                        for tool in tools where tool.canBackground { background(tool.toolUseId) }
                    }.buttonStyle(.mist(.secondary, size: .regular)).agentChatHand()
                }
                TimelineView(.animation(paused: running == nil)) { context in
                    MistDot(color: AgentChatToolGroupKind.status(shown) == .failed ? .mistError : running == nil ? .mistSuccess : .textTertiary)
                        .opacity(running == nil ? 1 : 0.675 + 0.325 * cos(context.date.timeIntervalSinceReferenceDate * .pi))
                }
            }
        }.agentChatCollapsible(expanded) { _ = viewState.expandedToolGroups.remove(tools[0].toolUseId) }
    }

    private func toggle() { viewState.expandedToolGroups.formSymmetricDifference([tools[0].toolUseId]) }
    /// Each expanded child's highlight, its ordinals following the lines above it; one formatting pass per child.
    private func childHighlights(after headers: [ClaudeCodeToolSummary.Line]) -> [AgentChatFindHighlight?] {
        guard var highlight = findHighlight?.shifted(past: headers) else { return tools.map { _ in nil } }
        return tools.map { tool in
            let current = highlight
            highlight = highlight.shifted(past: AgentChatToolView.lines(tool, folder: folder))
            return current
        }
    }
    private func styled(_ line: ClaudeCodeToolSummary.Line, highlight: AgentChatFindHighlight?) -> Text {
        AgentChatFindHighlight.styled(line, highlight: highlight, secondary: colors.resolve(.textSecondary), group: true, scale: textScale)
    }
}

struct AgentChatToolView: View {
    @Environment(\.agentChatTextScale) private var textScale
    let tool: AgentChatItem.ToolCall
    let folder: URL
    @AgentChatColors private var colors
    @ObservedObject var viewState = AgentChatTranscriptViewState()
    var grouped = false
    var background: ((String) -> Void)? = nil
    var findHighlight: AgentChatFindHighlight? = nil
    private var detailIndent: CGFloat { 16 }

    private var expanded: Bool { viewState.expandedTools.contains(tool.toolUseId) }
    private var previewTextIndent: CGFloat { detailIndent + Self.previewGutter(formatted, scale: textScale) }

    private static func previewGutter(_ output: ClaudeCodeToolSummary, scale: CGFloat) -> CGFloat {
        let numbers = output.preview.compactMap { $0.numberSpan?.text }
        if !numbers.isEmpty {
            return max(24, numbers.map { ceil(($0 as NSString).size(withAttributes: [.font: AgentChatTerminalFont.font(scale: scale)]).width) }.max() ?? 0) + 8
        }
        return output.summary.isEmpty && !output.preview.isEmpty
            ? ceil(("⎿" as NSString).size(withAttributes: [.font: AgentChatTerminalFont.font(scale: scale)]).width) + 8 : 0
    }

    var formatted: ClaudeCodeToolSummary { Self.format(tool, folder: folder) }

    static func lines(_ output: ClaudeCodeToolSummary) -> [ClaudeCodeToolSummary.Line] {
        [output.header] + output.summary
    }
    static func lines(_ tool: AgentChatItem.ToolCall, folder: URL) -> [ClaudeCodeToolSummary.Line] {
        lines(format(tool, folder: folder))
    }
    static func format(_ tool: AgentChatItem.ToolCall, folder: URL) -> ClaudeCodeToolSummary {
        let input = (try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8))) ?? .null
        var output = ClaudeCodeToolSummary.format(tool: tool.name, input: input, result: tool.structuredResult,
                                                 text: tool.output, folder: folder, failed: tool.status == .failed,
                                                 background: tool.background, denied: tool.permissionDenied, running: tool.status == .running)
        if tool.status == .running && tool.background == nil {
            output.summary = []
            output.preview = []
        }
        return output
    }

    var body: some View {
        let output = formatted
        let collapsible = expanded && output.hiddenLineCount > 0
        if grouped {
            content(output).agentChatCollapsible(collapsible, collapse: collapse)
        } else {
            // A diff line's tint fills its descent, so a card ending in one keeps its padding below the tint.
            let endsInTint = output.expansionLine(expanded: expanded) == nil && [.addition, .removal].contains(output.preview.last?.kind)
            MistTileCard(symbol: AgentChatToolGroupKind(tool.name).symbol, firstLineHeight: AgentChatTerminalFont.lineHeight(scale: textScale),
                         capHeight: AgentChatTerminalFont.capHeight(scale: textScale), endsInText: !endsInTint) {
                content(output)
            } trailing: {
                HStack(spacing: 8) {
                    if tool.canBackground, let background {
                        Button(AgentChatStrings.runInBackground) { background(tool.toolUseId) }
                            .buttonStyle(.mist(.secondary, size: .regular)).agentChatHand()
                    }
                    TimelineView(.animation(paused: tool.status != .running)) { context in
                        MistDot(color: tool.status == .succeeded ? .mistSuccess : tool.status == .failed ? .mistError : .textTertiary)
                            .opacity(tool.status == .running ? 0.675 + 0.325 * cos(context.date.timeIntervalSinceReferenceDate * .pi) : 1)
                    }
                }
            }.agentChatCollapsible(collapsible, collapse: collapse)
        }
    }

    private func collapse() { viewState.expandedTools.remove(tool.toolUseId) }

    private func content(_ output: ClaudeCodeToolSummary) -> some View {
        let lines = Self.lines(output)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if grouped {
                    TimelineView(.animation(paused: tool.status != .running)) { context in
                        Text("●")
                            .foregroundStyle(tool.status == .succeeded ? Color.green : tool.status == .failed ? Color.red : Color.gray)
                            .opacity(tool.status == .running ? 0.675 + 0.325 * cos(context.date.timeIntervalSinceReferenceDate * .pi) : 1)
                    }
                }
                styled(lines[0], highlight: findHighlight?.line(0, in: lines)).agentChatSelectable()
            }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("⎿").foregroundStyle(colors.resolve(.textSecondary))
                    styled(line, highlight: findHighlight?.line(index + 1, in: lines)).agentChatSelectable()
                }.padding(.leading, grouped ? 16 : 0)
            }
            if expanded && output.hiddenLineCount > 0 {
                previews(output.preview, output: output)
            } else {
                previews(Array(output.preview.prefix(output.previewLimit)), output: output)
            }
            if let expansion = output.expansionLine(expanded: expanded) {
                Button { viewState.expandedTools.formSymmetricDifference([tool.toolUseId]) } label: {
                    styled(expansion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).agentChatHand().padding(.leading, previewTextIndent)
            }
        }.font(Font(AgentChatTerminalFont.font(scale: textScale)))
            // Links read like the prose's, whose text views use the link color; the page's tint is the theme color.
            .tint(Color(nsColor: .linkColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("agentChat.tool")
    }

    private func previews(_ lines: [ClaudeCodeToolSummary.Line], output: ClaudeCodeToolSummary) -> some View {
        let gutter = Self.previewGutter(output, scale: textScale)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if gutter > 0 {
                        Text(line.numberSpan?.text ?? (index == 0 && output.summary.isEmpty ? "⎿" : " "))
                            .foregroundStyle(colors.resolve(.textSecondary)).frame(width: gutter - 8, alignment: .trailing)
                    }
                    (line.text.isEmpty ? Text(verbatim: " ") : styled(line)).agentChatSelectable()
                        .foregroundStyle(line.kind == .error ? Color.red : colors.resolve(.textPrimary))
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .addition ? Color.green.opacity(0.10) : line.kind == .removal ? Color.red.opacity(0.10) : Color.clear)
            }
        }.padding(.leading, detailIndent)
    }

    private func styled(_ line: ClaudeCodeToolSummary.Line, highlight: AgentChatFindHighlight? = nil) -> Text {
        AgentChatFindHighlight.styled(line, highlight: highlight, secondary: colors.resolve(.textSecondary), scale: textScale)
    }
}

private struct AgentChatFileChip: View {
    @Environment(\.agentChatTextScale) private var textScale
    @AgentChatColors private var colors
    let file: AgentFileAttachment

    var body: some View {
        HStack(spacing: 12) {
            MistIconTile(content: .icon(NSWorkspace.shared.icon(forFile: file.url.path)), side: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.url.lastPathComponent).font(.system(size: MistTextStyle.rowHeadline.size * textScale, weight: .semibold))
                    .foregroundStyle(colors.resolve(.textPrimary)).lineLimit(1).truncationMode(.middle)
                if let kind = UTType(filenameExtension: file.url.pathExtension)?.localizedDescription {
                    Text(verbatim: kind).font(.system(size: MistTextStyle.secondary.size * textScale)).foregroundStyle(colors.resolve(.textSecondary)).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).frame(width: 200, height: 56)
            .overlay(RoundedRectangle(cornerRadius: MistKit.Radius.innerCard, style: .continuous)
                .strokeBorder(colors.resolve(.mistHairline), lineWidth: MistKit.borderWidth))
    }
}

private struct AgentChatUserMessageView: View {
    @AgentChatColors private var colors
    let text: String
    let images: [AgentImageAttachment]
    let files: [AgentFileAttachment]
    let mentions: [AgentTabMention]
    let slashCommands: Set<String>
    let openAttachment: (AgentAttachment) -> Void
    var findHighlight: AgentChatFindHighlight? = nil
    var marker: String? = nil
    var addMarker: () -> AgentChatMarker? = { nil }
    var renameMarker: (String) -> Void = { _ in }
    var showMarker: (NSView) -> Void = { _ in }
    @State private var hovering = false
    @Environment(\.agentChatMeasuring) private var measuring

    var body: some View {
        AgentChatUserBubbleLayout {
            VStack(alignment: .trailing, spacing: 8) {
                if !images.isEmpty {
                    AgentChatThumbnailLayout {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, attachment in
                            if let image = NSImage(data: attachment.data) {
                                let size = AgentChatThumbnailLayout.thumbnailSize(for: image.size)
                                Button { openAttachment(.image(attachment)) } label: {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(width: size.width, height: size.height)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                                    .mistPointingHand()
                                    .accessibilityLabel(AgentChatStrings.image)
                                    .accessibilityIdentifier("agentChat.thumbnail")
                            }
                        }
                    }
                }
                if !files.isEmpty {
                    AgentChatThumbnailLayout {
                        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                            Button { openAttachment(.file(file)) } label: { AgentChatFileChip(file: file) }
                                .buttonStyle(.plain)
                                .mistPointingHand()
                                .accessibilityLabel(file.url.lastPathComponent)
                                .accessibilityIdentifier("agentChat.fileChip")
                        }
                    }
                }
                if !text.isEmpty {
                    AgentChatRichText(text: text, slashCommands: slashCommands, plainText: true, mentions: mentions, findHighlight: findHighlight)
                        .padding(.vertical, 12).padding(.horizontal, 16)
                        .background(colors.resolve(.mistChipFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        // Never sizes the row: an overlay inside the bubble's frame.
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(colors.resolve(.mistHairline), lineWidth: MistKit.borderWidth))
                        .accessibilityIdentifier("agentChat.userBubble")
                        .overlay(alignment: .bottomLeading) { markerActions }
                }
            }.overlay(alignment: .bottomLeading) {
                if text.isEmpty { markerActions }
            }
        }.onHover { hovering = $0 }
    }

    /// Both actions stay outside the bubble and never size the row, including image-only messages.
    /// The measurer never builds them.
    @ViewBuilder private var markerActions: some View {
        if !measuring {
            ZStack(alignment: .bottomLeading) {
                AgentChatRowMarkerButton(name: marker, visible: hovering || marker != nil, add: addMarker, showMarker: showMarker, rename: renameMarker)
                    .frame(width: 24, height: 22).offset(x: -30, y: -9)
                if hovering, !text.isEmpty {
                    AgentChatMessageCopyButton(text: text).frame(width: 24, height: 22).offset(x: -56, y: -9)
                }
            }
        }
    }
}

/// The code blocks' copy button, for a user message.
private struct AgentChatMessageCopyButton: NSViewRepresentable {
    let text: String
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    func makeNSView(context: Context) -> AgentChatCopyButton { AgentChatCopyButton(label: AgentChatStrings.copyMessage) }
    func updateNSView(_ button: AgentChatCopyButton, context: Context) {
        button.text = text
        button.tint = theme.color(for: .textSecondary, appearance: appearance)
    }
}

/// Measures wrapped content at three quarters of the column, without a geometry-reader height loop.
private struct AgentChatUserBubbleLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let size = subviews.first?.sizeThatFits(.init(width: width * 0.75, height: nil)) ?? .zero
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                             proposal: .init(width: bounds.width * 0.75, height: nil))
    }
}

/// The theme's colors for a chat view, re-rendering it when the theme or appearance changes. The environment's
/// `phiThemeObserver` stays the same object then, so a view that read only it, under an `.equatable()` row,
/// kept the previous appearance's colors: white text on a light transcript.
@propertyWrapper struct AgentChatColors: DynamicProperty {
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    var wrappedValue: Self { self }
    func resolve(_ color: ThemedColor) -> Color { color.swiftUIColor(theme: theme, appearance: appearance) }
}

private struct AgentChatMeasuringKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AgentChatTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

private struct AgentChatRenderingsKey: EnvironmentKey {
    static let defaultValue: AgentChatRichTextRenderings? = nil
}

private extension EnvironmentValues {
    var agentChatTextScale: CGFloat {
        get { self[AgentChatTextScaleKey.self] }
        set { self[AgentChatTextScaleKey.self] = newValue }
    }
    var agentChatMeasuring: Bool {
        get { self[AgentChatMeasuringKey.self] }
        set { self[AgentChatMeasuringKey.self] = newValue }
    }
    var agentChatRenderings: AgentChatRichTextRenderings? {
        get { self[AgentChatRenderingsKey.self] }
        set { self[AgentChatRenderingsKey.self] = newValue }
    }
}

private extension View {
    func agentChatSelectable() -> some View { modifier(AgentChatSelectable()) }

    /// An expanded block that a plain click anywhere in it collapses. SwiftUI's tap takes clicks on its plain parts,
    /// the transcript's click watcher those on its selectable text, whose AppKit view takes them before SwiftUI does
    /// (`AgentChatTranscriptScroll.noteClick`). Buttons and links inside keep their clicks, and an expanded block
    /// inside it takes the click first. The whole block shows the pointing hand.
    func agentChatCollapsible(_ expanded: Bool, collapse: @escaping () -> Void) -> some View {
        modifier(AgentChatCollapsible(expanded: expanded, collapse: collapse))
    }
    /// The pointing hand over a transcript toggle.
    func agentChatHand() -> some View { modifier(AgentChatHand()) }
}

private struct AgentChatSelectable: ViewModifier {
    @Environment(\.agentChatMeasuring) private var measuring

    @ViewBuilder func body(content: Content) -> some View {
        if measuring { content }
        else { content.textSelection(.enabled) }
    }
}

private struct AgentChatCollapsible: ViewModifier {
    let expanded: Bool
    let collapse: () -> Void
    @Environment(\.agentChatMeasuring) private var measuring

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // A mask rather than an `if`, which would rebuild the block's views on every toggle.
            .gesture(TapGesture().onEnded(collapse), including: expanded ? .all : .subviews)
            .background { if expanded && !measuring { AgentChatCollapseArea(collapse: collapse) } }
    }
}

/// Marks an expanded block for the page's pointing hand and for the transcript's click watcher.
private struct AgentChatCollapseArea: NSViewRepresentable {
    let collapse: () -> Void
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) { view.collapse = collapse }

    final class AreaView: MistPointingHandArea.AreaView {
        var collapse: () -> Void = {}
    }
}

private struct AgentChatHand: ViewModifier {
    @Environment(\.agentChatMeasuring) private var measuring
    func body(content: Content) -> some View {
        content.background { if !measuring { MistPointingHandArea().allowsHitTesting(false) } }
    }
}

final class AgentChatRichTextRendering {
    struct Key: Equatable {
        var source: String
        var primary: NSColor
        var secondary: NSColor
        var separator: NSColor
        var slashCommands: Set<String>
        var plainText: Bool
        var mentions: [AgentTabMention]
        var textScale: CGFloat
    }
    let markdownCache = MarkdownRenderCache()
    let measurementView = AgentChatTextView(frame: .zero, textContainer: nil)
    var key: Key?
    var rendered: NSAttributedString?
    var measurement: (width: CGFloat, size: CGSize)?
}

final class AgentChatRichTextRenderings {
    var sharedID: String? { didSet { if sharedID != oldValue { shared = nil } } }
    private var shared: AgentChatRichTextRendering?
    func rendering(for id: String) -> AgentChatRichTextRendering? {
        guard id == sharedID else { return nil }
        if shared == nil { shared = AgentChatRichTextRendering() }
        return shared
    }
}

struct AgentChatRichText: NSViewRepresentable {
    let text: String
    var slashCommands: Set<String> = []
    var plainText = false
    var mentions: [AgentTabMention] = []
    var findHighlight: AgentChatFindHighlight? = nil
    var renderKey: String? = nil
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.openURL) private var openURL
    @Environment(\.agentChatMeasuring) private var measuring
    @Environment(\.agentChatTextScale) private var textScale
    @Environment(\.agentChatRenderings) private var renderings

    final class Coordinator: NSObject, NSTextViewDelegate {
        let own = AgentChatRichTextRendering()
        var rendering: AgentChatRichTextRendering?
        var renderKey: String?
        var shown: NSAttributedString?
        var openLink: (URL) -> Void = { _ in }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { openLink(url) }
            else if let string = link as? String, let url = URL(string: string) { openLink(url) }
            return true
        }
        var findHighlight: AgentChatFindHighlight?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = AgentChatTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: plainText ? 0 : 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openLink = { openURL($0) }
        let primary = theme.color(for: .textPrimary, appearance: appearance)
        let secondary = theme.color(for: .textSecondary, appearance: appearance)
        let separator = theme.color(for: .separator, appearance: appearance)
        let cache = context.coordinator
        let rendering: AgentChatRichTextRendering
        if let renderKey, let shared = renderings?.rendering(for: renderKey) {
            rendering = shared
            cache.renderKey = renderKey
        } else if let renderKey, cache.renderKey == renderKey, let current = cache.rendering {
            rendering = current
        } else {
            rendering = cache.own
            cache.renderKey = nil
        }
        cache.rendering = rendering
        let key = AgentChatRichTextRendering.Key(source: text, primary: primary, secondary: secondary, separator: separator,
                                                 slashCommands: slashCommands, plainText: plainText, mentions: mentions, textScale: textScale)
        if rendering.key != key {
            let renderer = MarkdownRenderer.agentChat(primary: primary, secondary: secondary, separator: separator, slashCommands: slashCommands, scale: textScale, typesetMath: plainText ? nil : MarkdownMathTypesetter.typeset)
            let base = plainText ? renderer.userMessageRuns(text, mentions: mentions)
                : renderer.markdownRuns(text, color: primary, cache: rendering.markdownCache)
            let rendered: NSAttributedString
            if !plainText && !mentions.isEmpty {
                let styled = NSMutableAttributedString(attributedString: base)
                AgentChatMentionStyle.apply(mentions, to: styled, pointSize: AgentChatTypography.bodySize * textScale)
                rendered = styled
            } else { rendered = base }
            rendering.measurementView.textStorage?.apply(rendered, over: rendering.rendered)
            rendering.key = key
            rendering.rendered = rendered
            rendering.measurement = nil
        }
        guard let rendered = rendering.rendered else { return }
        let textChanged = !measuring && cache.shown !== rendered
        let marksChanged = cache.findHighlight != findHighlight
        cache.findHighlight = findHighlight
        if textChanged, let storage = view.textStorage {
            let selection = view.selectedRanges
            // A streamed update changes the length, so the whole-text comparison runs only when it can't tell.
            if storage.length != rendered.length || !storage.isEqual(to: rendered) {
                storage.apply(rendered, over: cache.shown)
            }
            let validSelection = selection.filter { NSMaxRange($0.rangeValue) <= rendered.length }
            if view.selectedRanges != validSelection { view.selectedRanges = validSelection }
            (view as? AgentChatTextView)?.updateCodeControls()
            cache.shown = rendered
        }
        if !measuring && ((textChanged && findHighlight != nil) || marksChanged) {
            (view as? AgentChatTextView)?.applyFindHighlight(findHighlight)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let rendering = context.coordinator.rendering else { return nil }
        let measurement = rendering.measurementView
        let naturalWidth = plainText ? MarkdownRenderer.userMessageWidth(measurement.attributedString(), scale: textScale) : CGFloat.greatestFiniteMagnitude
        let width = max(1, min(proposal.width ?? 700, naturalWidth))
        if let cached = rendering.measurement, cached.width == width { return cached.size }
        if measurement.textContainerInset != nsView.textContainerInset { measurement.textContainerInset = nsView.textContainerInset }
        guard let container = measurement.textContainer, let manager = measurement.layoutManager else { return nil }
        if container.widthTracksTextView { container.widthTracksTextView = false }
        let padding = nsView.textContainer?.lineFragmentPadding ?? 0
        if container.lineFragmentPadding != padding { container.lineFragmentPadding = padding }
        let size = NSSize(width: max(1, width - measurement.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        manager.ensureLayout(for: container)
        let result = CGSize(width: width, height: AgentChatTextView.measuredHeight(measurement, manager: manager, container: container))
        rendering.measurement = (width, result)
        return result
    }
}

extension MarkdownRenderer {
    static func agentChat(primary: NSColor, secondary: NSColor, separator: NSColor, slashCommands: Set<String> = [], scale: CGFloat = 1, typesetMath: ((String, Bool, CGFloat, NSColor) -> MarkdownMathTypeset?)?) -> MarkdownRenderer {
        MarkdownRenderer(nsFont: AgentChatTypography.font(ofSize: AgentChatTypography.bodySize * scale),
            nsFontHeading: AgentChatTypography.font(ofSize: 20 * scale, weight: .semibold),
            nsFontSubheading: AgentChatTypography.font(ofSize: 17 * scale, weight: .semibold),
            nsFontSmall: AgentChatTypography.codeFont(ofSize: 12.5 * scale),
            textNS: primary, dimNS: secondary, lineHeightMultiple: AgentChatTypography.lineHeightMultiple, blockSpacing: 10 * scale,
            codeBackground: secondary.withAlphaComponent(0.07), separatorColor: separator, slashCommands: slashCommands, typesetMath: typesetMath, scale: scale,
            nsFontMinorHeading: AgentChatTypography.font(ofSize: 15 * scale, weight: .semibold))
    }
}

extension NSTextStorage {
    /// Replaces the text rendered as `old` with `new` from their first difference on, so TextKit keeps the
    /// layout before it: a streamed reply changes only at its end, and laying all of it out again per chunk
    /// stalled the window.
    func apply(_ new: NSAttributedString, over old: NSAttributedString?) {
        let common = old.map { ($0.string as NSString).commonPrefix(with: new.string, options: .literal).utf16.count } ?? 0
        apply(new, over: old, common: common)
    }
    func apply(_ new: NSAttributedString, over old: NSAttributedString?, common: Int) {
        guard let old, old.length == length else { return setAttributedString(new) }
        // Markdown can restyle earlier text, as a closing fence does, or kern the character before a code span
        // that just closed: the edit starts where the attributes first differ.
        var equal = 0
        while equal < common {
            var mine = NSRange(), theirs = NSRange()
            let limit = NSRange(location: equal, length: common - equal)
            guard NSDictionary(dictionary: old.attributes(at: equal, longestEffectiveRange: &mine, in: limit))
                .isEqual(to: new.attributes(at: equal, longestEffectiveRange: &theirs, in: limit)) else { break }
            equal = min(NSMaxRange(mine), NSMaxRange(theirs))
        }
        guard equal > 0 else { return setAttributedString(new) }
        replaceCharacters(in: NSRange(location: equal, length: length - equal),
                          with: new.attributedSubstring(from: NSRange(location: equal, length: new.length - equal)))
    }
}

final class AgentChatTextView: NSTextView {
    var findCurrentRange: NSRange?

    // NSTextView tracks a click in its own loop, whose mouse-up never reaches the transcript's click monitor.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let up = NSApp.currentEvent, up.type == .leftMouseUp else { return }
        sequence(first: self as NSView, next: \.superview).lazy.compactMap { $0 as? AgentChatTranscriptScroll }.first?.noteClick(up)
    }

    // A selection starts only in the first responder; a subscription per row would cost every rendered row.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applyMistSelection() }
        return accepted
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if window?.firstResponder === self { applyMistSelection() }
    }

    func applyFindHighlight(_ highlight: AgentChatFindHighlight?) {
        guard let layout = layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        findCurrentRange = nil
        guard let highlight else { return }
        for (ordinal, range) in TextFind.ranges(of: highlight.query, in: string).enumerated() {
            layout.addTemporaryAttributes([.backgroundColor: ordinal == highlight.current ? NSColor.systemOrange : NSColor.systemYellow,
                                           .foregroundColor: NSColor.black], forCharacterRange: range)
            if ordinal == highlight.current { findCurrentRange = range }
        }
    }

    func findCurrentRect() -> NSRect? {
        guard let range = findCurrentRange, let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return super.writeSelection(to: pboard, types: types) }
        let output = NSMutableAttributedString()
        var hasMath = false
        for (index, value) in selectedRanges.enumerated() {
            let range = value.rangeValue
            guard NSMaxRange(range) <= storage.length else { continue }
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            let part = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            var replacements: [(NSRange, MarkdownMathAttachment)] = []
            part.enumerateAttribute(.attachment, in: NSRange(location: 0, length: part.length)) { value, range, _ in
                if let attachment = value as? MarkdownMathAttachment { replacements.append((range, attachment)) }
            }
            for (range, attachment) in replacements.reversed() {
                hasMath = true
                var attributes = part.attributes(at: range.location, effectiveRange: nil)
                attributes.removeValue(forKey: .attachment)
                part.replaceCharacters(in: range, with: NSAttributedString(string: attachment.source, attributes: attributes))
            }
            output.append(part)
        }
        guard hasMath else { return super.writeSelection(to: pboard, types: types) }
        // Copy asks with the legacy names in writablePasteboardTypes. Leave out RTFD and the other rich types,
        // which would carry the formula images instead of their source.
        let wantsString = types.contains(.string) || types.contains(.init("NSStringPboardType"))
        let wantsRTF = types.contains(.rtf) || types.contains(.init("NeXT Rich Text Format v1.0 pasteboard type"))
        pboard.declareTypes((wantsString ? [.string] : []) + (wantsRTF ? [.rtf] : []), owner: nil)
        var written = false
        if wantsString { written = pboard.setString(output.string, forType: .string) || written }
        if wantsRTF, let data = try? output.data(from: NSRange(location: 0, length: output.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            written = pboard.setData(data, forType: .rtf) || written
        }
        return written
    }
    private(set) var codeButtons: [Int: AgentChatCopyButton] = [:]
    private var storageObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // Explicitly construct TextKit 1: all block drawing and sizing use its layout manager.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let textContainer = container ?? AgentChatTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        if textContainer.layoutManager == nil {
            storage.addLayoutManager(manager)
            manager.addTextContainer(textContainer)
        }
        super.init(frame: frameRect, textContainer: textContainer)
        layoutManager?.delegate = AgentChatSlashLayoutDelegate.shared
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: 0, .cursor: NSCursor.pointingHand]
        storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.needsLayout = true
                    self?.needsDisplay = true
                    self?.invalidateIntrinsicContentSize()
                }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) } }

    static func measuredHeight(_ view: NSTextView, manager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
        manager.ensureLayout(for: container)
        var bottom: CGFloat = 0
        // usedRect includes the empty editing line after the final terminator;
        // lineFragmentRect also includes paragraphSpacing. The used line rect excludes both.
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, _, _ in
            bottom = max(bottom, used.maxY)
        }
        // Box edges include padding and borders, but their trailing margins are not content.
        // Intermediate spacing stays intact in the positions of the following lines.
        view.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            for block in style.textBlocks {
                let margin = block.width(for: .margin, edge: .maxY)
                bottom = max(bottom, manager.boundsRect(for: block, at: glyphs.location, effectiveRange: nil).maxY - margin)
                if let cell = block as? NSTextTableBlock {
                    bottom = max(bottom, manager.boundsRect(for: cell.table, at: glyphs.location, effectiveRange: nil).maxY - margin)
                }
            }
        }
        return max(20, ceil(bottom + view.textContainerInset.height * 2))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        synchronizeContainerWidth()
        if widthChanged { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    override func layout() {
        synchronizeContainerWidth()
        super.layout()
        updateCodeControls()
    }

    private func synchronizeContainerWidth() {
        guard let container = textContainer, container.widthTracksTextView else { return }
        let width = max(1, bounds.width - textContainerInset.width * 2)
        if container.containerSize.width != width { container.containerSize.width = width }
    }

    func updateCodeControls() {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        if codeButtons.isEmpty {
            var hasCodeBlock = false
            storage.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value != nil { hasCodeBlock = true; stop.pointee = true }
            }
            guard hasCodeBlock else { return }
        }
        manager.ensureLayout(for: container)
        var live = Set<Int>()
        var ordinal = 0
        storage.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let descriptor = value as? MarkdownCodeBlock else { return }
            // Count across the whole text view, including the transcript panel
            // which concatenates separately rendered messages into one storage.
            let key = ordinal
            ordinal += 1
            live.insert(key)
            let button: AgentChatCopyButton
            if let existing = self.codeButtons[key] { button = existing }
            else {
                button = AgentChatCopyButton(label: NSLocalizedString("browser.agentChat.copyCode", value: "Copy code", comment: "Chat code block - Copy button accessibility label and tooltip"))
                self.codeButtons[key] = button
                self.addSubview(button)
            }
            button.text = descriptor.code
            button.tint = descriptor.foreground
            let rect = self.blockRect(descriptor, range: range)
            button.frame = NSRect(x: max(rect.minX, rect.maxX - 36), y: rect.minY + (MarkdownCodeBlock.headerHeight - 22) / 2, width: 24, height: 22)
            button.isHidden = rect.isEmpty
        }
        for key in Array(codeButtons.keys) where !live.contains(key) {
            codeButtons.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func blockRect(_ descriptor: MarkdownCodeBlock, range: NSRange) -> NSRect {
        guard let manager = layoutManager else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundsRect(for: descriptor.block, at: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // The bounds include the block's margins, which must stay unpainted gaps between blocks.
        let block = descriptor.block
        let top = block.width(for: .margin, edge: .minY), bottom = block.width(for: .margin, edge: .maxY)
        let left = block.width(for: .margin, edge: .minX), right = block.width(for: .margin, edge: .maxX)
        return NSRect(x: bounds.minX + left, y: bounds.minY + top,
                      width: max(0, bounds.width - left - right), height: max(0, bounds.height - top - bottom))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The text view would otherwise set its I-beam over the Copy buttons it hosts.
        if codeButtons.values.contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            NSCursor.pointingHand.set()
            return
        }
        // A view in front of the text (the transcript's go-to-bottom button) sets its own cursor.
        guard isFrontmost(at: event.locationInWindow) else { return }
        super.mouseMoved(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        synchronizeContainerWidth()
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { super.draw(dirtyRect); return }
        manager.ensureLayout(for: container)
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.markdownCodeBlock, in: full) { value, range, _ in
            guard let descriptor = value as? MarkdownCodeBlock else { return }
            let box = self.blockRect(descriptor, range: range)
            guard box.intersects(dirtyRect) else { return }
            AgentCodeBlockDrawing.fill(box, color: descriptor.background, header: descriptor.foreground.withAlphaComponent(0.04), headerHeight: MarkdownCodeBlock.headerHeight)
        }
        storage.enumerateAttribute(.markdownInlineCode, in: full) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            // Line rects include the extra line height above the glyphs, so size the pill from the
            // code font around each line's baseline to keep the text vertically centered in it.
            manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { return }
                let span = manager.boundingRect(forGlyphRange: part, in: container)
                let baseline = line.minY + manager.location(forGlyphAt: part.location).y
                let inset = MarkdownRenderer.inlineCodeInset
                // The code's last character carries the trailing inset as kerning, which its glyph bounds include.
                let trailing = NSMaxRange(part) == NSMaxRange(glyphs) ? 0 : inset
                let box = NSRect(x: span.minX - inset, y: baseline - font.ascender - 1.5,
                                 width: span.width + inset + trailing, height: font.ascender - font.descender + 3)
                    .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                color.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
        // TextKit draws a table cell's background and borders only for cells with glyphs in the drawn rect, so redrawing
        // a band holding just the padding and border between two rows, as streamed updates do, left a gap in the grid.
        // Reaching past that band to the rows' text draws them whole; drawing stays clipped to the dirty area.
        super.draw(dirtyRect.insetBy(dx: 0, dy: -32))
    }
}

final class AgentChatCopyButton: NSButton {
    var text = "" {
        didSet { if text != oldValue { reset() } }
    }
    private var resetTask: Task<Void, Never>?
    private(set) var copied = false
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    /// The resting icon color; hovering darkens it and adds a soft background.
    var tint: NSColor? {
        didSet { if tint != oldValue { applyTint() } }
    }

    init(label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        target = self
        action = #selector(copyClicked(_:))
        setAccessibilityLabel(label)
        setCustomTooltip(label)
        reset()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Like the marker button's: a user message's copy button is a SwiftUI representable, whose alignment rect an
    /// inline button would inset, spilling its hover fill past its frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ value: Bool) {
        hovered = value
        applyTint()
    }

    private func applyTint() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = hovered ? tint?.withAlphaComponent(0.12).cgColor : nil
        contentTintColor = hovered ? tint?.blended(withFraction: 0.5, of: .labelColor) : tint
    }

    @objc private func copyClicked(_ sender: Any?) { copyText(to: .general) }

    func copyText(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        resetTask?.cancel()
        copied = true
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        resetTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            self?.reset()
        }
    }

    private func reset() {
        resetTask?.cancel()
        resetTask = nil
        copied = false
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    }
    deinit { resetTask?.cancel() }
}

struct AgentChatThumbnailLayout: Layout {
    static func thumbnailSize(for image: NSSize) -> CGSize {
        CGSize(width: min(240, 120 * image.width / max(1, image.height)), height: 120)
    }

    /// Right-aligned rows that wrap when the next thumbnail would overflow `width`.
    static func positions(_ sizes: [CGSize], width: CGFloat) -> (CGSize, [CGPoint]) {
        var rows: [[Int]] = [[]]
        var widths: [CGFloat] = [0]
        for index in sizes.indices {
            var row = rows.count - 1
            if !rows[row].isEmpty, widths[row] + 6 + sizes[index].width > width {
                rows.append([]); widths.append(0); row += 1
            }
            widths[row] += (rows[row].isEmpty ? 0 : 6) + sizes[index].width
            rows[row].append(index)
        }
        var points = Array(repeating: CGPoint.zero, count: sizes.count)
        var y: CGFloat = 0
        for (row, indices) in rows.enumerated() {
            var x = max(0, width - widths[row])
            for index in indices {
                points[index] = CGPoint(x: x, y: y)
                x += sizes[index].width + 6
            }
            y += (indices.map { sizes[$0].height }.max() ?? 0) + 6
        }
        return (CGSize(width: width, height: sizes.isEmpty ? 0 : y - 6), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.positions(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? 525).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = Self.positions(subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width).1
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), proposal: .unspecified)
        }
    }
}

struct DrifterEmptyState: View {
    var body: some View {
        MistPageHeader(glyph: .image(DrifterApp.logo), title: MistAppID.drifter.name, glyphSide: 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentChatComposerHost: NSViewRepresentable {
    let composer: AgentChatComposer
    func makeNSView(context: Context) -> AgentChatComposer { composer }
    func updateNSView(_ view: AgentChatComposer, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentChatComposer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: nsView.intrinsicContentSize.height)
    }
}

final class AgentChatComposer: NSView, ObservableObject {
    @Published private(set) var slashCommandNames: Set<String> = []
    let card = MistComposerCard()
    let editor = MistPromptEditor()
    let strip = MistAttachmentStrip()
    let sendButton = MistButton(symbol: "arrow.up", title: AgentChatStrings.send, role: .primary, size: .large, circle: true)
    let stopButton = MistButton(symbol: "stop.fill", title: AgentChatStrings.stop, role: .secondary, size: .large, circle: true)
    private(set) var browserLaunchRow: MistDrifterLaunchRow?
    private(set) var attachments: [AgentAttachment] = []
    private weak var conversation: AgentConversation?
    /// Starts a chat from the draft and returns whether it started; a failed launch keeps the draft.
    var onLaunch: ((String, [AgentAttachment], [AgentTabMention]) -> Bool)? {
        didSet { refresh() }
    }
    /// `/clear` sent before any chat exists.
    var onClearWithoutChat: (() -> Void)?
    /// A launch surface's process-local draft, before any conversation exists.
    var onLaunchDraftChange: ((AgentComposerDraft) -> Void)?
    private var statusSubscription: AnyCancellable?
    private var draftSubscription: AnyCancellable?
    private var backgroundSubscription: AnyCancellable?
    private var scheduleSubscription: AnyCancellable?
    private var commandSubscriptions = Set<AnyCancellable>()
    private var skillCatalog: DrifterSkillCatalog?
    private var skillSubscription: AnyCancellable?
    private var commandSource: (() -> [ClaudeCodeSlashCommand])?

    init() {
        super.init(frame: .zero)
        addSubview(card)
        addSubview(editor.mentionBanner)
        [editor, editor.commandPopup, editor.mentionPopup, strip, stopButton, sendButton].forEach { card.addSubview($0) }
        card.acceptsAttachments = { [weak self] in self?.canEdit == true }
        card.onDrop = { [weak self] in self?.addAttachments(from: $0) ?? false }
        editor.setPlaceholder(AgentChatStrings.reply, icon: .drifter(engine: .claude))
        editor.onChange = { [weak self] in
            guard let self else { return }
            self.publishDraft()
            self.refresh()
        }
        editor.onHeightChange = { [weak self] in self?.invalidateIntrinsicContentSize(); self?.needsLayout = true }
        editor.textView.onSubmit = { [weak self] in self?.send() }
        editor.textView.acceptsAttachments = { [weak self] in self?.canEdit == true }
        editor.textView.onPasteAttachments = { [weak self] in self?.addAttachments(from: $0) ?? false }
        editor.textView.onDropTargetChange = { [weak self] in self?.card.setDropTarget($0) }
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        registerForDraggedTypes(ClaudeCodeImageNormalizer.pasteboardTypes)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateCommands() {
        let commands = commandSource?() ?? []
        editor.slashCommands = commands
        let names = Set(commands.map(\.name))
        if slashCommandNames != names { slashCommandNames = names }
    }

    private var placeholderText = AgentChatStrings.reply
    private var placeholderEngine = DrifterEngine.claude
    private var emptySubscription: AnyCancellable?

    func configure(settings: DrifterSettings, skillFolders: [URL] = [], placeholder: String = AgentChatStrings.reply) {
        commandSubscriptions.removeAll()
        let catalog = DrifterSkillCatalog(folder: DrifterHome.current.skills)
        catalog.repoFolders = skillFolders.filter { $0.deletingLastPathComponent().lastPathComponent == ".claude" }
        skillCatalog = catalog
        commandSource = { [ClaudeCodeClearCommand.command] + catalog.commands }
        catalog.$skills.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateCommands() }.store(in: &commandSubscriptions)
        editor.onSlashQuery = { [weak catalog] in Task { await catalog?.refresh() } }
        editor.slashCommandsEnabled = true
        editor.mentionsEnabled = true
        updateCommands()
        Task { await catalog.refresh() }
        placeholderText = placeholder
        placeholderEngine = settings.config.engine
        editor.setPlaceholder(placeholderText, icon: MistComposerIcon.drifter(engine: placeholderEngine))
        settings.$config.receive(on: DispatchQueue.main).sink { [weak self] config in
            guard let self else { return }
            self.placeholderEngine = config.engine
            self.editor.setPlaceholder(self.placeholderText, icon: MistComposerIcon.drifter(engine: config.engine))
        }.store(in: &commandSubscriptions)
        browserLaunchRow?.removeFromSuperview()
        let row = MistDrifterLaunchRow(settings: settings)
        browserLaunchRow = row
        addSubview(row)
        row.onAttachFiles = { [weak self] in self?.addAttachments(from: $0) }
        row.onInteraction = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.editor.textView)
        }
        refresh()
    }

    func configureLaunch(saved: DrifterLaunchSettings = .init()) {
        if conversation != nil { bind(nil) }
        configure(settings: DrifterSettings(config: saved.config, saved: saved),
                  placeholder: AgentChatStrings.askDrifter)
    }

    func bind(_ conversation: AgentConversation?) {
        draftSubscription = nil
        self.conversation = conversation
        emptySubscription = conversation?.$items.map(\.isEmpty).removeDuplicates().sink { [weak self] empty in
            guard let self else { return }
            self.placeholderText = empty ? AgentChatStrings.askDrifter : AgentChatStrings.reply
            self.editor.setPlaceholder(self.placeholderText, icon: MistComposerIcon.drifter(engine: self.placeholderEngine))
        }
        skillSubscription = conversation?.$skillFolders.receive(on: DispatchQueue.main).sink { [weak self] folders in
            guard let catalog = self?.skillCatalog else { return }
            catalog.repoFolders = folders.filter { $0.deletingLastPathComponent().lastPathComponent == ".claude" }
            Task { await catalog.refresh() }
        }
        let draft = conversation?.draft ?? AgentComposerDraft()
        editor.applyDraft(draft.text, mentions: draft.mentions)
        editor.textView.setSelectedRange(NSRange(location: draft.text.utf16.count, length: 0))
        attachments = draft.attachments
        statusSubscription = conversation?.$status.removeDuplicates().sink { [weak self] status in self?.refresh(status: status) }
        draftSubscription = conversation?.draftChanges.sink { [weak self] change in
            guard let self, change.source != ObjectIdentifier(self) else { return }
            self.editor.applyDraft(change.draft.text, mentions: change.draft.mentions)
            self.attachments = change.draft.attachments
            self.refresh()
        }
        backgroundSubscription = conversation?.$backgroundTasks.removeDuplicates().sink { [weak self] tasks in
            self?.browserLaunchRow?.setBackgroundTasks(tasks, onStop: self?.conversation?.onStopTask)
        }
        browserLaunchRow?.setBackgroundTasks(conversation?.backgroundTasks ?? [], onStop: conversation?.onStopTask)
        scheduleSubscription = conversation.map { _ in
            NotificationCenter.default.publisher(for: DrifterScheduleStore.didChange, object: DrifterScheduleStore.shared)
                .sink { [weak self] _ in self?.refreshSchedules() }
        }
        refreshSchedules()
        refresh()
    }

    private func refreshSchedules() {
        let schedules: [DrifterSchedule]
        if let id = conversation?.id {
            schedules = ((try? DrifterScheduleStore.shared.list()) ?? []).filter { $0.owner == id && $0.target == .thisChat }
        } else {
            schedules = []
        }
        browserLaunchRow?.setSchedules(schedules) { DrifterScheduleStore.shared.cancelFromUI($0) }
    }
    private var canEdit: Bool {
        guard let conversation else { return onLaunch != nil }
        return conversation.status != .ended
    }
    private var busy: Bool { conversation?.status == .running || conversation?.status == .awaitingPermission }
    /// A failed or restored chat's next message launches its agent.
    private static func accepts(_ status: AgentConversationStatus?) -> Bool {
        status == nil || status == .idle || status?.launchesOnSend == true
    }

    func send() {
        guard canEdit,
              !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let prompt = editor.promptForSend().normalized
        if ClaudeCodeClearCommand.matches(prompt.text) {
            clearDraft()
            // With no chat yet the composer is already a new chat: nothing to launch.
            if let conversation { conversation.onClear?() } else { onClearWithoutChat?() }
            return
        }
        guard busy || Self.accepts(conversation?.status) else { return }
        if let conversation {
            do { attachments = try conversation.importAttachments(attachments) }
            catch {
                if let window {
                    let alert = NSAlert()
                    alert.messageText = error.localizedDescription
                    alert.beginSheetModal(for: window)
                }
                return
            }
        }
        conversation?.messageSent.send()
        // Any message Johnny sends answers a waiting hand-off in place of its Done.
        conversation?.setHandOff(nil)
        if busy {
            conversation?.onQueue?(prompt.text, attachments, prompt.mentions)
            conversation?.refusePendingPermissions()
        }
        else if let conversation, conversation.status.launchesOnSend {
            // Cleared first, so a launch that can't start puts the message straight back.
            let sentAttachments = attachments
            clearDraft()
            conversation.restart(text: prompt.text, attachments: sentAttachments, mentions: prompt.mentions)
            return
        }
        else if let conversation { conversation.onSend?(prompt.text, attachments, prompt.mentions) }
        else if onLaunch?(prompt.text, attachments, prompt.mentions) != true { return }
        clearDraft()
    }
    @objc private func sendClicked() { send() }
    @objc private func stopClicked() { if busy { conversation?.onStop?() } }

    private func clearDraft() {
        attachments = []
        editor.text = ""
        refresh()
    }

    private func publishDraft() {
        let draft = AgentComposerDraft(text: editor.text, mentions: editor.mentions, attachments: attachments)
        if let conversation { conversation.setDraft(draft, from: self) }
        else { onLaunchDraftChange?(draft) }
    }

    func applyLaunchDraft(_ draft: AgentComposerDraft) {
        guard conversation == nil else { return }
        editor.applyDraft(draft.text, mentions: draft.mentions)
        editor.textView.setSelectedRange(NSRange(location: draft.text.utf16.count, length: 0))
        attachments = draft.attachments
        refresh()
    }

    func editQueued(_ message: AgentQueuedMessage) {
        guard canEdit, let conversation, let current = conversation.queue.first(where: { $0.id == message.id }), !current.delivering else { return }
        conversation.onRemoveQueued?(message.id)
        conversation.setDraft(conversation.draft.prepending(current))
        window?.makeFirstResponder(editor.textView)
    }

    @discardableResult
    func addAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard canEdit else { return false }
        let before = attachments.count
        for item in pasteboard.pasteboardItems ?? [] {
            if let attachment = ClaudeCodeImageNormalizer.attachment(item: item) { addAttachment(attachment) }
        }
        publishDraft()
        refresh()
        return attachments.count > before
    }
    func addAttachments(from urls: [URL]) {
        guard canEdit else { return }
        for url in urls {
            if let attachment = ClaudeCodeImageNormalizer.attachment(fileURL: url) { addAttachment(attachment) }
        }
        publishDraft()
        refresh()
    }
    private func addAttachment(_ attachment: AgentAttachment) {
        if case .image = attachment, attachments.images.count >= 10 { return }
        attachments.append(attachment)
    }

    private func refresh(status: AgentConversationStatus? = nil) {
        let state = status ?? conversation?.status
        let working = state == .running || state == .awaitingPermission
        let editable: Bool
        switch state { case .ended: editable = false; case nil: editable = onLaunch != nil; default: editable = true }
        editor.textView.isEditable = editable
        editor.updateSlashCommands()
        browserLaunchRow?.setAttachmentsEnabled(editable)
        // While the agent works, Send queues the message.
        let clear = conversation != nil && ClaudeCodeClearCommand.matches(editor.text)
        sendButton.isEnabled = editable && (clear || working || Self.accepts(state))
            && (!editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
        stopButton.isHidden = !working
        strip.update(attachments) { [weak self] index in
            guard let self, self.canEdit, self.attachments.indices.contains(index) else { return }
            self.attachments.remove(at: index)
            self.publishDraft()
            self.refresh()
        }
        strip.onOpen = { [weak self] index in
            guard let self, self.attachments.indices.contains(index) else { return }
            self.conversation?.onOpenAttachment?(self.attachments[index])
        }
        editor.hasAttachments = !attachments.isEmpty
        strip.isHidden = attachments.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: editor.inputHeight + 52 + editor.popupHeight + (attachments.isEmpty ? 0 : 70) + (browserLaunchRow == nil ? 0 : 36) + editor.mentionBannerHeight)
    }
    override func layout() {
        super.layout()
        let rowHeight: CGFloat = browserLaunchRow == nil ? 0 : 36
        card.frame = NSRect(x: 0, y: rowHeight, width: bounds.width, height: bounds.height - rowHeight - editor.mentionBannerHeight)
        editor.mentionBanner.frame = NSRect(x: 0, y: card.frame.maxY + 8, width: bounds.width, height: editor.mentionBanner.listHeight)
        browserLaunchRow?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        let popupHeight = editor.popupHeight
        editor.commandPopup.frame = NSRect(x: 12, y: 52, width: max(0, bounds.width - 24), height: popupHeight)
        editor.mentionPopup.frame = editor.commandPopup.frame
        editor.frame = NSRect(x: 0, y: 52 + popupHeight, width: bounds.width, height: editor.inputHeight)
        strip.frame = NSRect(x: 46, y: editor.frame.maxY, width: max(0, bounds.width - 60), height: 56)
        sendButton.frame = NSRect(x: max(0, bounds.width - 48), y: 12, width: 32, height: 32)
        stopButton.frame = NSRect(x: max(0, bounds.width - 88), y: 12, width: 32, height: 32)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        card.setDropTarget(canEdit)
        return canEdit ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { card.setDropTarget(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { card.setDropTarget(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        card.setDropTarget(false)
        return addAttachments(from: sender.draggingPasteboard)
    }
}
