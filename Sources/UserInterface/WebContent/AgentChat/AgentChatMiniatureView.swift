import AppKit
import Combine
import SwiftUI

/// A child chat's preview card body: a picture of its transcript's end, drawn as its own tab draws the rows.
///
/// The picture is a bitmap of the last rows, drawn from the card's own windowless SwiftUI tree, so the parent's
/// window only composites an image. The tree is kept between renders, so a render redoes only the rows that
/// changed, and without a window its timelines never tick. It's redrawn when the child's status changes, when the
/// card comes on screen or is first sized with what it shows changed, and at most every
/// `AgentChatMiniaturePlan.interval` while the child runs; never while the card is off screen, nor right after a
/// scroll or a key press. Streamed chunks cost only the status subscription's duplicate check.
final class AgentChatMiniatureView: NSView {
    struct Source {
        let conversation: AgentConversation
        let folder: URL
        let engine: DrifterEngine
    }

    private struct Key: Equatable {
        var rows: [AgentChatDisplayRow]
        var status: AgentConversationStatus
        /// While the working row shows, its elapsed time moves on each interval.
        var clock: Int
        var pixelWidth: Int
        var sourceHeight: CGFloat
        var appearance: NSAppearance.Name?
        var theme: Int
    }

    private let picture = CALayer()
    private var source: Source?
    private var statusBinding: AnyCancellable?
    private var themeBinding: AnyCancellable?
    private var occlusionObserver: NSObjectProtocol?
    private var timer: Timer?
    private var lastRender = -CFTimeInterval.infinity
    private var rendered: (key: Key, height: CGFloat)?
    private var theme = 0
    private let displayCache = AgentChatDisplayRowCache()
    private let viewState = AgentChatTranscriptViewState()
    /// The picture's own tree, kept between renders and never in a window.
    private var hosting: ThemedHostingView?
    private weak var hostingTheme: ThemeStateProvider?
    private var rowCount = AgentChatMiniaturePlan.rowCounts[0]
    private(set) var renderCount = 0
    /// Every card's last render, so several busy children never draw in the same run-loop turn.
    private static var lastAnyRender = -CFTimeInterval.infinity
    var image: CGImage? { picture.contents.map { $0 as! CGImage } }
    var pictureFrame: CGRect { picture.frame }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        picture.contentsGravity = .resize
        picture.minificationFilter = .trilinear
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func show(_ source: Source) {
        guard self.source?.conversation !== source.conversation || self.source?.folder != source.folder
                || self.source?.engine != source.engine else { return }
        self.source = source
        rendered = nil
        picture.contents = nil
        hosting = nil
        rowCount = AgentChatMiniaturePlan.rowCounts[0]
        // `status` republishes on every streamed chunk; only a change can change the picture.
        statusBinding = source.conversation.$status.removeDuplicates().sink { [weak self] _ in self?.setNeedsRender() }
    }

    // MARK: Visibility

    private var isOnScreen: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor && bounds.width >= 1 && bounds.height >= 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        themeBinding = nil
        guard let window else {
            timer?.invalidate()
            timer = nil
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                  object: window, queue: .main) { [weak self] _ in self?.setNeedsRender() }
        themeBinding = themeStateProvider.themeAppearancePublisher.sink { [weak self] _ in
            self?.theme += 1
            self?.setNeedsRender()
        }
        setNeedsRender()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        setNeedsRender()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setNeedsRender()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placePicture()
        // A new card is shown before it's laid out, so its first render waits for its size here: without it, a card
        // whose child had stopped changing stayed blank until it was hidden and shown again.
        guard let rendered else { return setNeedsRender() }
        if rendered.key.pixelWidth != pixelWidth || rendered.key.sourceHeight != AgentChatMiniaturePlan.sourceHeight(body: bounds.size) {
            setNeedsRender()
        }
    }

    // MARK: Rendering

    private var pixelWidth: Int { Int((bounds.width * (window?.backingScaleFactor ?? 2)).rounded(.up)) }

    /// Schedules one redraw, in the default run-loop mode only, so menus, drags and live resizes never wait on it.
    private func setNeedsRender() {
        guard timer == nil, source != nil, isOnScreen else { return }
        let now = CACurrentMediaTime()
        let delay = AgentChatMiniaturePlan.delay(sinceRender: now - lastRender, sinceInput: Self.secondsSinceInput,
                                                 sinceAnyRender: now - Self.lastAnyRender)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func fire() {
        timer = nil
        guard let source, isOnScreen else { return }
        guard Self.secondsSinceInput >= AgentChatMiniaturePlan.inputQuiet,
              CACurrentMediaTime() - Self.lastAnyRender >= AgentChatMiniaturePlan.spacing else { return setNeedsRender() }
        renderNow()
        if source.conversation.status == .running { setNeedsRender() }
    }

    private static var secondsSinceInput: TimeInterval {
        min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
    }

    /// Draws the picture unless nothing it shows changed. Internal for tests, whose card is never on screen.
    func renderNow() {
        guard let source else { return }
        let start = CACurrentMediaTime()
        let conversation = source.conversation
        let status = conversation.status
        let memory = AgentMemoryFiles(folders: conversation.memoryFolders, skillFolders: conversation.skillFolders)
        let all = AgentChatDisplayRow.rows(from: Array(conversation.items.suffix(AgentChatMiniaturePlan.itemLimit)),
                                           memory: memory, cwd: source.folder, cache: displayCache)
        let candidates = all.suffix(AgentChatMiniaturePlan.rowCounts.last ?? 36).map(Self.trimmed)
        let working = conversation.showsWorkingIndicator
        let sourceHeight = AgentChatMiniaturePlan.sourceHeight(body: bounds.size)
        let key = Key(rows: candidates, status: status, clock: working ? Int(start / AgentChatMiniaturePlan.interval) : 0,
                      pixelWidth: pixelWidth, sourceHeight: sourceHeight, appearance: effectiveAppearance.name, theme: theme)
        lastRender = start
        guard key != rendered?.key, sourceHeight > 0 else { return }
        let width = AgentChatMiniaturePlan.sourceWidth
        let provider = themeStateProvider
        if hosting == nil || hostingTheme !== provider {
            hosting = ThemedHostingView(rootView: EmptyView(), themeSource: provider)
            hostingTheme = provider
        }
        guard let hosting else { return }
        if hosting.appearance?.name != effectiveAppearance.name { hosting.appearance = effectiveAppearance }
        var content: CGFloat = 0
        var rows: [AgentChatDisplayRow] = []
        while true {
            rows = Array(candidates.suffix(rowCount))
            hosting.setThemedContent(page(rows, status: status, memory: memory, working: working, clock: key.clock, source: source))
            content = ceil(hosting.fittingSize.height)
            // Rows enough to fill the card stay in the picture's tree, so later renders only redo what changed.
            guard content < sourceHeight, rows.count < candidates.count, let most = AgentChatMiniaturePlan.rowCounts.last,
                  rowCount < most else { break }
            rowCount = most
        }
        guard content > 0 else { return }
        let height = min(content, sourceHeight)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: content)
        hosting.layoutSubtreeIfNeeded()
        let rect = NSRect(x: 0, y: hosting.isFlipped ? content - height : 0, width: width, height: height)
        let pixelsHigh = Int((height * CGFloat(key.pixelWidth) / width).rounded(.up))
        guard key.pixelWidth > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: key.pixelWidth, pixelsHigh: pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = rect.size
        hosting.cacheDisplay(in: rect, to: bitmap)
        // The working row observes the conversation, which publishes per streamed chunk; it waits for the next render.
        if working {
            hosting.setThemedContent(page(rows, status: status, memory: memory, working: false, clock: key.clock, source: source))
        }
        picture.contents = bitmap.cgImage
        rendered = (key, height)
        placePicture()
        renderCount += 1
        Self.lastAnyRender = CACurrentMediaTime()
    }

    /// The rows as the child's tab lays them out in its column, with the page's margins and background.
    private func page(_ rows: [AgentChatDisplayRow], status: AgentConversationStatus, memory: AgentMemoryFiles,
                      working: Bool, clock: Int, source: Source) -> some View {
        let entries = rows.indices.map { index in
            AgentChatTranscriptSlice.Entry(id: .row(rows[index].id), index: index, row: rows[index],
                                           spacing: AgentChatTranscriptRows.spacing(before: rows[index], after: index > 0 ? rows[index - 1] : nil),
                                           open: AgentChatDisplayRow.isOpen(at: index, of: rows, status: status))
        }
        let slice = AgentChatTranscriptSlice(entries: entries, memory: memory, find: nil, slashCommands: [], folder: source.folder,
                                             engine: source.engine, showsWorking: false, afterRows: !rows.isEmpty)
        // One view state for every render: rows compare it by identity, so a fresh one would redraw them all.
        let transcript = AgentChatTranscriptRows(conversation: source.conversation, folder: source.folder, engine: source.engine,
                                                 viewState: viewState, slice: slice)
        return VStack(alignment: .leading, spacing: 0) {
            transcript
            // A windowless host's timelines don't tick: a new working row per render shows the time it's taken.
            if working { transcript.workingRow(afterRows: !rows.isEmpty).id(clock) }
        }
        .padding(.vertical, 16).padding(.horizontal, (AgentChatMiniaturePlan.sourceWidth - AgentChatColumn.maxWidth) / 2)
        .frame(width: AgentChatMiniaturePlan.sourceWidth)
        .themedBackground(.windowBackground)
    }

    /// Only a message's end can show, so a long one is cut to spare laying out the rest.
    private static func trimmed(_ row: AgentChatDisplayRow) -> AgentChatDisplayRow {
        guard case var .item(item) = row else { return row }
        switch item.kind {
        case let .assistantText(text, streaming):
            item.kind = .assistantText(text: AgentChatMiniaturePlan.tail(text, markdown: true), isStreaming: streaming)
        // Mentions point into the whole text.
        case let .userMessage(text, images) where item.mentions.isEmpty:
            item.kind = .userMessage(text: AgentChatMiniaturePlan.tail(text, markdown: false), images: images)
        default: return row
        }
        return .item(item)
    }

    private func placePicture() {
        guard let rendered else { return }
        let frame = AgentChatMiniaturePlan.pictureFrame(rendered: rendered.height, body: bounds.size)
        guard picture.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = frame
        CATransaction.commit()
    }
}
