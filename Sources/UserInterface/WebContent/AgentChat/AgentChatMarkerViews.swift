import AppKit
import Combine
import SwiftUI

/// Kept mounted even while its icon is hidden, so adding a marker doesn't replace the popover's anchor.
struct AgentChatRowMarkerButton: NSViewRepresentable {
    var name: String?
    var visible: Bool
    var add: () -> AgentChatMarker?
    var showMarker: (NSView) -> Void
    var rename: (String) -> Void
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance

    func makeNSView(context: Context) -> AgentChatMarkerButton { AgentChatMarkerButton() }
    func updateNSView(_ button: AgentChatMarkerButton, context: Context) {
        button.add = add
        button.showMarker = showMarker
        button.rename = rename
        button.update(name: name, visible: visible, tint: theme.color(for: name == nil ? .textSecondary : .themeColor, appearance: appearance))
    }
}

final class AgentChatMarkerButton: NSButton {
    var add: (() -> AgentChatMarker?)?
    var showMarker: ((NSView) -> Void)?
    var rename: ((String) -> Void)?
    private(set) var popover: NSPopover?
    private var scrollWatch: AnyCancellable?
    private var closedEvent: NSEvent?
    private var name: String?
    private var configured = false
    private var tint: NSColor = .secondaryLabelColor
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        target = self
        action = #selector(clicked)
        setAccessibilityIdentifier("agentChat.markerButton")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(name: String?, visible: Bool, tint: NSColor) {
        alphaValue = visible || popover?.isShown == true ? 1 : 0
        isEnabled = visible || popover?.isShown == true
        // A hover re-renders the row; the icon and tooltip change only with the marker.
        // A new NSButton already has an image, so the first update is tracked explicitly.
        let first = !configured
        configured = true
        if first || name != self.name {
            self.name = name
            if let name, popover?.isShown == true {
                (popover?.contentViewController as? AgentChatMarkerNamePopover)?.offer(name)
            }
            image = NSImage(systemSymbolName: name == nil ? "bookmark" : "bookmark.fill", accessibilityDescription: nil)
            let title = name ?? AgentChatStrings.markerAdd
            setCustomTooltip(title)
            setAccessibilityLabel(title)
        }
        if first || tint != self.tint {
            self.tint = tint
            applyTint()
        }
    }

    /// SwiftUI lays out a representable's alignment rect, which an inline button insets 4 pt above and 3 pt below:
    /// without this the hover fill spilled past the frame its row gives it.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { hovered = true; applyTint() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyTint() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover?.close() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func applyTint() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = hovered ? tint.withAlphaComponent(0.12).cgColor : nil
        contentTintColor = hovered ? tint.blended(withFraction: 0.5, of: .labelColor) : tint
    }
    func trackMarkerPopover(_ popover: NSPopover) {
        self.popover = popover
        closeWhenScrolledAway()
    }
    func markerPopoverDidClose() {
        closedEvent = NSApp.currentEvent
        popover = nil
        scrollWatch = nil
    }
    /// A popover anchored here closes once its marker scrolls out of sight, instead of staying behind.
    private func closeWhenScrolledAway() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollWatch = NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: clip).sink { [weak self] _ in
            guard let self, let popover = self.popover, popover.isShown, self.visibleRect.isEmpty else { return }
            popover.close()
        }
    }
    @objc private func clicked() {
        // A transient popover can close on mouse-down before this button sends its action.
        if let closedEvent, closedEvent === NSApp.currentEvent { return }
        closedEvent = nil
        if popover?.isShown == true { popover?.close(); return }
        if name != nil { showMarker?(self); return }
        guard let marker = add?() else { return }
        let editor = AgentChatMarkerNamePopover(name: marker.name, commit: rename ?? { _ in })
        editor.loadViewIfNeeded()
        editor.view.subtreeThemeSource = themeStateProvider
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.delegate = editor
        editor.popover = popover
        editor.onClose = { [weak self] in self?.markerPopoverDidClose() }
        trackMarkerPopover(popover)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        editor.selectName()
    }
}

final class AgentChatMarkerNamePopover: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    let field = NSTextField()
    private let original: String
    private let commit: (String) -> Void
    private var cancelled = false
    private var edited = false
    weak var popover: NSPopover?
    var onClose: (() -> Void)?
    init(name: String, commit: @escaping (String) -> Void) {
        original = name
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        field.stringValue = original
        // One line that scrolls: a long default name otherwise wrapped onto a clipped second line.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = AgentChatStrings.markerName
        field.setAccessibilityLabel(AgentChatStrings.markerName)
        field.delegate = self
        let well = MistFieldWellView(field, shape: .rounded)
        view.addSubview(well)
        well.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([well.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                                     well.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                                     well.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    func selectName() { view.window?.makeFirstResponder(field); field.selectText(nil) }
    func controlTextDidChange(_ notification: Notification) { edited = true }
    func offer(_ name: String) {
        guard !edited, name != field.stringValue else { return }
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = name
            editor.selectAll(nil)
        } else {
            field.stringValue = name
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { popover?.close(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelled = true; popover?.close(); return true }
        return false
    }
    func popoverDidClose(_ notification: Notification) {
        if !cancelled { commit(field.stringValue) }
        onClose?()
    }
}

final class AgentChatMarkerTickStrip: NSView {
    struct Position: Equatable {
        var id: String
        var name: String
        var y: CGFloat
    }
    override var isFlipped: Bool { true }
    private(set) var positions: [Position] = []
    private var appliedHeight: CGFloat = -1
    var onJump: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityIdentifier("agentChat.markerTicks")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(_ positions: [Position]) {
        guard positions != self.positions || appliedHeight != bounds.height else { return }
        self.positions = positions
        appliedHeight = bounds.height
        isHidden = positions.isEmpty
        var existing = Dictionary(uniqueKeysWithValues: subviews.compactMap { $0 as? AgentChatMarkerTick }.map { ($0.id, $0) })
        for position in positions {
            let tick = existing.removeValue(forKey: position.id) ?? AgentChatMarkerTick(id: position.id)
            if tick.superview == nil { addSubview(tick) }
            tick.frame = NSRect(x: 0, y: position.y - 4.5, width: 12, height: 9)
            tick.setCustomTooltip(position.name)
            tick.setAccessibilityLabel(position.name)
            tick.onClick = { [weak self] in self?.onJump?(position.id) }
        }
        existing.values.forEach { $0.removeFromSuperview() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private final class AgentChatMarkerTick: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let capsule = NSView()
    private var area: NSTrackingArea?
    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 1.5
        capsule.phiLayer?.setBackgroundColor(.themeColor)
        capsule.alphaValue = 0.75
        addSubview(capsule)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); setHovered(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    private func setHovered(_ hovered: Bool) {
        let height: CGFloat = hovered ? 3 : 2
        capsule.frame = NSRect(x: bounds.maxX - 10, y: (bounds.height - height) / 2, width: 8, height: height)
        capsule.alphaValue = hovered ? 1 : 0.75
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
}

struct AgentChatMarkerListButton: View, Equatable {
    let markers: [AgentChatMarker]
    let conversation: AgentConversation
    var jump: (String) -> Void
    private final class Anchor { weak var view: NSView? }
    @State private var anchor = Anchor()
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.markers == rhs.markers }

    var body: some View {
        if !markers.isEmpty {
            Button(action: show) { Image(systemName: "bookmark") }
                .buttonStyle(.mistIcon).customTooltip(AgentChatStrings.markerList).accessibilityLabel(AgentChatStrings.markerList)
                .background(HeaderControlAnchorView { anchor.view = $0 })
                .accessibilityIdentifier("agentChat.markerList")
        }
    }
    private func show() {
        if let view = anchor.view { AgentChatMarkerListPopover.show(conversation: conversation, anchor: view, jump: jump) }
    }
}

/// Receives only marker changes; transcript chunks never publish through this object.
@MainActor
final class AgentChatMarkerListState: ObservableObject {
    @Published private(set) var markers: [AgentChatMarker]
    private var binding: AnyCancellable?
    init(_ conversation: AgentConversation) {
        markers = conversation.markers
        binding = conversation.$markers.removeDuplicates().sink { [weak self] in
            guard self?.markers != $0 else { return }
            self?.markers = $0
        }
    }
}

final class AgentChatMarkerListPopover: NSViewController, NSPopoverDelegate {
    private static var shown: NSPopover?
    private var binding: AnyCancellable?
    private var onClose: (() -> Void)?
    @discardableResult
    static func show(conversation: AgentConversation, anchor: NSView, only: String? = nil,
                     onClose: (() -> Void)? = nil, jump: @escaping (String) -> Void = { _ in }) -> NSPopover {
        shown?.close()
        let controller = AgentChatMarkerListPopover()
        controller.onClose = onClose
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = controller
        let state = AgentChatMarkerListState(conversation)
        let hosting = MistKitHostingView(rootView: AgentChatMarkerList(state: state, conversation: conversation, only: only) { id in
            jump(id)
            popover.close()
        })
        hosting.subtreeThemeSource = anchor.themeStateProvider
        // The list sets its own size. A hosting view that sized the popover opened it tall, and the popover then
        // shrank toward its bottom edge, far below the header button.
        hosting.sizingOptions = []
        controller.view = hosting
        controller.binding = conversation.$markers.removeDuplicates().sink { [weak controller, weak popover] markers in
            let visible = markers.filter { only == nil || $0.id == only }
            let size = NSSize(width: 280, height: CGFloat(min(10, visible.count)) * 32 + 12)
            controller?.view.setFrameSize(size)
            controller?.preferredContentSize = size
            if visible.isEmpty { popover?.close() }
        }
        shown = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return popover
    }
    func popoverDidClose(_ notification: Notification) {
        binding = nil
        view = NSView() // Releases the SwiftUI jump closure and its popover.
        Self.shown = nil
        onClose?()
        onClose = nil
    }
}

private struct AgentChatMarkerList: View {
    @ObservedObject var state: AgentChatMarkerListState
    let conversation: AgentConversation
    let only: String?
    let jump: (String) -> Void
    private var markers: [AgentChatMarker] { state.markers.filter { only == nil || $0.id == only } }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(markers) { marker in
                    AgentChatMarkerListRow(marker: marker, conversation: conversation, single: only != nil) { jump(marker.id) }
                }
            }.padding(.vertical, 6)
        }.frame(width: 280, height: CGFloat(min(10, markers.count)) * 32 + 12)
    }
}

private struct AgentChatMarkerListRow: View {
    let marker: AgentChatMarker
    let conversation: AgentConversation
    let single: Bool
    let jump: () -> Void
    @State private var hovering = false
    @State private var editing = false
    var body: some View {
        HStack(spacing: 6) {
            if editing {
                AgentChatMarkerInlineName(name: marker.name) { name in
                    if let name { conversation.renameMarker(itemId: marker.id, to: name) }
                    editing = false
                }
            } else {
                if single {
                    Text(verbatim: marker.name).mistText(.rowTitle).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button(action: jump) {
                        Text(verbatim: marker.name).mistText(.rowTitle).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if single || (hovering && !editing) {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.mistIcon).customTooltip(AgentChatStrings.markerRename).accessibilityLabel(AgentChatStrings.markerRename)
                Button { conversation.removeMarker(itemId: marker.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.mistIcon).customTooltip(AgentChatStrings.markerRemove).accessibilityLabel(AgentChatStrings.markerRemove)
            }
        }.padding(.horizontal, 10).frame(height: MistSidebarCellView.rowHeight)
            // A kit sidebar row, inset from the popover's edges like Mail's rows.
            .mistRow(.sidebar, selected: false).onHover { hovering = $0 }
            .padding(.horizontal, 8)
    }
}

/// Becoming first responder selects the whole name, so typing a new name replaces it. Never call `selectText` here:
/// it ends the editing it restarts, and the end saved and closed the field before it could show.
private struct AgentChatMarkerInlineName: NSViewRepresentable {
    let name: String
    let finish: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeNSView(context: Context) -> MistFieldWellView {
        let field = NSTextField(string: name)
        field.placeholderString = AgentChatStrings.markerName
        field.setAccessibilityLabel(AgentChatStrings.markerName)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return MistFieldWellView(field, shape: .rounded, height: 24)
    }
    func updateNSView(_ well: MistFieldWellView, context: Context) {}
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let finish: (String?) -> Void
        private var finished = false
        init(finish: @escaping (String?) -> Void) { self.finish = finish }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { end((control as? NSTextField)?.stringValue); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { end(nil); return true }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) { end((notification.object as? NSTextField)?.stringValue) }
        private func end(_ name: String?) { guard !finished else { return }; finished = true; finish(name) }
    }
}
