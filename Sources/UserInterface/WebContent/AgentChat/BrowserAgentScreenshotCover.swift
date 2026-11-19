import AppKit

/// A frozen sibling above a page's shared content surface. Never changes the page.
@MainActor
final class BrowserAgentScreenshotCover: NSView {
    private weak var page: NSView?
    private weak var originalParent: NSView?
    private weak var originalWindow: NSWindow?
    private let image: NSImage
    private let displayRect: CGRect
    private let fill: NSColor
    private let isValid: () -> Bool
    private var observer: CFRunLoopObserver?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func isVisible(_ page: NSView) -> Bool {
        page.window != nil && page.window?.isMiniaturized == false && !page.isHiddenOrHasHiddenAncestor
    }

    init?(croppedImage: CGImage, displaySize: CGSize, page: NSView,
          backgroundColor: NSColor, isValid: @escaping () -> Bool) {
        guard let parent = page.superview, Self.isVisible(page), isValid() else { return nil }
        self.page = page
        originalParent = parent
        originalWindow = page.window
        self.image = NSImage(cgImage: croppedImage, size: displaySize)
        displayRect = CGRect(origin: .zero, size: displaySize)
        fill = backgroundColor.withAlphaComponent(1)
        self.isValid = isValid
        super.init(frame: page.frame)
        wantsLayer = true
        layer?.masksToBounds = true
        parent.addSubview(self, positioned: .above, relativeTo: page)
        // Arbitrary Chromium views cannot be subclassed to observe reparenting.
        // Validate before AppKit can flush a handoff or hidden tab to the screen.
        observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true, CFIndex.min) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        displayIfNeeded()
        CATransaction.flush()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        image.draw(in: displayRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func reconcile() {
        guard isValid(), let page, let originalParent,
              page.superview === originalParent, superview === originalParent,
              page.window === originalWindow, Self.isVisible(page) else {
            remove()
            return
        }
        frame = page.frame
    }

    func remove() {
        if let observer { CFRunLoopObserverInvalidate(observer); self.observer = nil }
        removeFromSuperview()
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
    }
}
