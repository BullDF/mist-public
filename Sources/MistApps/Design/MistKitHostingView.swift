import AppKit
import SwiftUI

/// The hosting view of a SwiftUI app page. It shows the pointing hand over the kit's buttons and anything marked
/// `mistPointingHand()` while they're enabled, over AppKit controls inside it that ask for it
/// (`MistPointingHandControl`), over links in SwiftUI's selectable text (`MistSelectableTextLinks`), plus wherever
/// `extraHandTarget` says (a drop area that opens a chooser).
///
/// AppKit sends `cursorUpdate` to the hosting view, never to a subview, and SwiftUI's `.pointerStyle(.link)` left
/// the hand on after the pointer left sideways in browser windows, so the cursor is set here. It follows
/// `mouseMoved`, because the areas move with SwiftUI's layout and scrolling.
///
/// Its content takes the theme color as SwiftUI's tint, so nothing on an app page falls back to the macOS accent color.
class MistKitHostingView: ThemedHostingView {
    /// Whether a point in the window, outside the marked areas, takes the hand.
    var extraHandTarget: ((NSPoint) -> Bool)?
    /// The marked areas, which register themselves while in the window.
    let handAreas = NSHashTable<MistPointingHandArea.AreaView>.weakObjects()
    private let selectableTextLinks = MistSelectableTextLinks()
    private var showsHand = false
    private var area: NSTrackingArea?
    private var refreshScheduled = false
    private var sheetObservers: [NSObjectProtocol] = []

    override init<Content: View>(rootView content: Content, themeSource: ThemeStateProvider? = nil) {
        super.init(rootView: content.themedTint(.themeColor), themeSource: themeSource)
    }
    @MainActor @preconcurrency required init(rootView: AnyView) { super.init(rootView: rootView) }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { sheetObservers.forEach(NotificationCenter.default.removeObserver) }

    override func themedRootView<Content: View>(_ content: Content) -> AnyView {
        super.themedRootView(content.themedTint(.themeColor))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }
    override func cursorUpdate(with event: NSEvent) {
        guard handShows(at: event.locationInWindow) else { return super.cursorUpdate(with: event) }
        showsHand = true
        NSCursor.pointingHand.set()
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshCursor(at: event.locationInWindow)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { resetCursor() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        resetCursor()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { resetCursor() }
        super.viewWillMove(toWindow: newWindow)
    }
    // A sheet opening or closing changes the answer under a still pointer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sheetObservers.forEach(NotificationCenter.default.removeObserver)
        sheetObservers = []
        guard let window else { return }
        sheetObservers = [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsCursorRefresh() }
            }
        }
    }

    /// Rechecks the cursor under a still pointer once SwiftUI has applied the change that asked for it.
    func setNeedsCursorRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            guard let window else { return resetCursor() }
            layoutSubtreeIfNeeded()
            refreshCursor(at: window.mouseLocationOutsideOfEventStream)
        }
    }
    /// Whether `point`, in the window, is over an enabled marked area or `extraHandTarget`, whatever the window's
    /// key state.
    func handTarget(at point: NSPoint) -> Bool {
        guard let window else { return false }
        if extraHandTarget?(point) == true { return true }
        if handAreas.allObjects.contains(where: { $0.enabled && $0.window === window && $0.visiblyContains(point) }) { return true }
        guard let superview, let hit = hitTest(superview.convert(point, from: nil)) else { return false }
        if selectableTextLinks.link(at: point, in: hit) { return true }
        return sequence(first: hit, next: { $0.superview }).prefix(while: { $0 !== self })
            .contains { ($0 as? MistPointingHandControl)?.showsPointingHand == true }
    }

    private func refreshCursor(at point: NSPoint?) {
        guard let point, handShows(at: point) else { return resetCursor(at: point) }
        showsHand = true
        NSCursor.pointingHand.set()
    }
    private func handShows(at point: NSPoint) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return false }
        return handTarget(at: point)
    }
    /// Over SwiftUI's selectable text the hand gives way to the I-beam: that text sets its cursor only when its own
    /// pointer style changes, which moving off a link inside it doesn't, so the arrow stuck there.
    private func resetCursor(at point: NSPoint? = nil) {
        guard showsHand else { return }
        showsHand = false
        (point.map(overSelectableText) == true ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    private func overSelectableText(_ point: NSPoint) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, let superview,
              let hit = hitTest(superview.convert(point, from: nil)) else { return false }
        return MistSelectableTextLinks.isSelectableText(hit)
    }
}

/// Finds a link under the pointer in SwiftUI's selectable text (`.textSelection(.enabled)`), whose view shows the
/// I-beam over its links too. That view exposes the text it draws (fonts, paragraph style, links) only through
/// accessibility, never glyph frames, so the text is laid out again at the view's width: TextKit's line breaks and
/// glyph positions matched SwiftUI's rendering exactly. The last layout is kept until the view, its width or its text
/// changes.
@MainActor final class MistSelectableTextLinks {
    private struct Layout {
        weak var view: NSView?
        let width: CGFloat
        let text: NSAttributedString
        /// Nil when the text holds no link. The storage owns its layout manager, which owns the container.
        let storage: NSTextStorage?
    }
    private var layout: Layout?

    /// Whether `view` is SwiftUI's selectable text.
    static func isSelectableText(_ view: NSView) -> Bool {
        view.accessibilityRole() == .staticText && !(view is NSControl) && !(view is NSTextView)
    }

    /// Whether `point`, in the window, falls on a link's glyph in `view`.
    func link(at point: NSPoint, in view: NSView) -> Bool {
        guard Self.isSelectableText(view) else { return false }
        let length = view.accessibilityNumberOfCharacters()
        guard length > 0, let text = view.accessibilityAttributedString(for: NSRange(location: 0, length: length)) else { return false }
        if layout?.view !== view || layout?.width != view.bounds.width || layout?.text != text {
            layout = Layout(view: view, width: view.bounds.width, text: text, storage: Self.storage(text, width: view.bounds.width))
        }
        guard let manager = layout?.storage?.layoutManagers.first, let container = manager.textContainers.first else { return false }
        var local = view.convert(point, from: nil)
        if !view.isFlipped { local.y = view.bounds.height - local.y }
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
        return text.attribute(.link, at: manager.characterIndexForGlyph(at: glyph), effectiveRange: nil) != nil
    }

    private static func storage(_ text: NSAttributedString, width: CGFloat) -> NSTextStorage? {
        var hasLink = false
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { hasLink = true; stop.pointee = true }
        }
        guard hasLink else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        // The view is as wide as its longest line; a point more keeps that line's last word on it.
        let container = NSTextContainer(size: NSSize(width: width + 1, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return storage
    }
}

/// Marks a view for its page's pointing hand, shown while the view is enabled. Apply it inside the view's `.disabled`
/// (the kit's button styles do). It only marks the area and never takes clicks.
struct MistPointingHandArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) { view.enabled = context.environment.isEnabled }

    class AreaView: NSView {
        private weak var owner: MistKitHostingView?
        var enabled = true {
            didSet { if enabled != oldValue { owner?.setNeedsCursorRefresh() } }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // An area appearing or disappearing under a still pointer changes the cursor too.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.handAreas.remove(self)
            owner?.setNeedsCursorRefresh()
            owner = window == nil ? nil
                : sequence(first: self as NSView, next: { $0.superview }).first(where: { $0 is MistKitHostingView })
                    as? MistKitHostingView
            owner?.handAreas.add(self)
            owner?.setNeedsCursorRefresh()
        }
    }
}

/// An AppKit control that shows the pointing hand while `showsPointingHand`: through its cursor rect in an AppKit
/// view, and through its `MistKitHostingView` inside a SwiftUI page, where AppKit applies no subview's cursor rect.
protocol MistPointingHandControl: NSView {
    var showsPointingHand: Bool { get }
}

extension MistPointingHandControl {
    /// The hand's cursor rect, for `resetCursorRects`.
    func addPointingHandCursorRect() {
        if showsPointingHand { addCursorRect(bounds, cursor: .pointingHand) }
    }
    /// Rechecks the cursor under a still pointer after `showsPointingHand` changed.
    func pointingHandDidChange() {
        window?.invalidateCursorRects(for: self)
        let host = sequence(first: self as NSView, next: { $0.superview }).lazy.compactMap { $0 as? MistKitHostingView }.first
        host?.setNeedsCursorRefresh()
    }

    /// Keeps the hand over a control floating in front of views that set their own cursor whatever covers them
    /// (SwiftUI's selectable text, a `MistKitHostingView`, an `NSTextView`). Call it from the control's `cursorUpdate`
    /// and from `mouseMoved` of its own tracking area: those views get the same move in no set order, so the hand is
    /// set again once they all had it.
    func keepFloatingPointingHand() {
        guard showsPointingHand else { return }
        NSCursor.pointingHand.set()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, window.isKeyWindow, window.attachedSheet == nil, showsPointingHand,
                  !isHiddenOrHasHiddenAncestor, isFrontmost(at: window.mouseLocationOutsideOfEventStream) else { return }
            NSCursor.pointingHand.set()
        }
    }
}

extension NSView {
    /// Whether `point`, in the window, falls on the view's visible part. A view no longer clips to its bounds by
    /// default, so its visibleRect alone reaches past them.
    func visiblyContains(_ point: NSPoint) -> Bool {
        bounds.intersection(visibleRect).contains(convert(point, from: nil))
    }
    /// Whether `point`, in the window, falls on this view or a subview of it rather than on a view in front of it,
    /// which neither its tracking areas nor its own hit test see.
    func isFrontmost(at point: NSPoint) -> Bool {
        guard let root = window?.contentView, let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point) else { return false }
        return hit.isDescendant(of: self)
    }
    /// Whether no view in front of this one covers `point`, in the window. Unlike `isFrontmost`, it holds for a view
    /// that lets clicks through to its ancestors (a SwiftUI tooltip anchor) and for one outside the content view.
    func isUncovered(at point: NSPoint) -> Bool {
        guard let root = window?.contentView, isDescendant(of: root),
              let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point) else { return true }
        return hit.isDescendant(of: self) || isDescendant(of: hit)
    }
}

extension View {
    /// Shows the page's pointing hand over this view while it's enabled; apply it before `.disabled`.
    func mistPointingHand() -> some View { background(MistPointingHandArea().allowsHitTesting(false)) }
}
