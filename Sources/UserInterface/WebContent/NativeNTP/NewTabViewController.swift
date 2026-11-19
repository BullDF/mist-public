// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

final class NewTabViewController: NSViewController {
    private let browserState: BrowserState
    private var cancellables = Set<AnyCancellable>()

    private let logoSide: CGFloat = 72
    private let logoGap: CGFloat = 36
    /// The tiles' frame sits this far under the composer, so the tiles themselves sit 32 under it: their hover fill
    /// takes the rest.
    private let appsGap: CGFloat = 32 - MistLauncherTile.padding
    private let collapsedOmniBoxHeight = MistNewTabComposerViewController.collapsedHeight
    private var areControlsHidden = false
    private var keyDownMonitor: Any?
    private weak var currentTab: Tab?
    var appOpener: ((MistAppID, Tab?) -> Void)?

    private(set) lazy var appsWidget: MistAppsWidgetHostingView = {
        let host = MistAppsWidgetHostingView(rootView: MistAppsWidget(apps: MistApps.all) { [weak self] id in
            self?.openApp(id)
        }, themeSource: browserState.themeContext)
        host.sizingOptions = []
        return host
    }()

    private lazy var composerController: MistNewTabComposerViewController = {
        let controller = MistNewTabComposerViewController(state: browserState)
        controller.omnibox.setActionDelegate(self)
        return controller
    }()
    private var omniBoxController: OmniBoxViewController { composerController.omnibox }
    var composer: MistNewTabComposerViewController { composerController }

    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        return scrollView
    }()

    private let contentView = NSView()

    /// The kit's page header: Mist's logo, titled only in an incognito window.
    private(set) lazy var header = MistPageHeaderView(
        glyph: .image("native-NTP-icon"),
        title: browserState.isIncognito
            ? NSLocalizedString("browser.newTabPage.incognitoLabel", value: "Incognito", comment: "Incognito label in the native new tab page")
            : "",
        subtitle: nil, glyphSide: logoSide)

    init(state: BrowserState) {
        self.browserState = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopKeyboardMonitoring()
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.contentOverlayBackground)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupObservers()
        updateContentLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startKeyboardMonitoring()
        composerController.focusInput()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopKeyboardMonitoring()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentLayout()
    }

    /// Runs on every show, including tab switches.
    func updateForTab(_ tab: Tab?) {
        currentTab = tab
        setNativeControlsHidden(false)
        omniBoxController.setCurrentTabForNavigation(tab)
    }

    /// Restores the NTP to its initial clean state — native controls visible and
    /// the omnibox cleared — after a navigation that started here was routed to
    /// another Space and cancelled. Submitting from the omnibox hid the controls
    /// (`omniBoxDidClear`) and can leave the typed text behind; this brings the
    /// clean new-tab page back. `updateForTab` alone does NOT clear the omnibox.
    func resetToInitialState(for tab: Tab?) {
        currentTab = tab
        omniBoxController.reset()
        setNativeControlsHidden(false)
        omniBoxController.setCurrentTabForNavigation(tab)
    }

    func focusOmnibox() {
        composerController.focusInput()
    }
    
    private func setNativeControlsHidden(_ hidden: Bool) {
        guard areControlsHidden != hidden else { return }
        areControlsHidden = hidden
        header.isHidden = hidden
        composerController.view.isHidden = hidden
        updateWidgetVisibility(height: composerController.contentSize.height)
    }

    private func setupViews() {
        view.addSubview(scrollView)
        scrollView.documentView = contentView

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addChild(composerController)
        contentView.addSubview(header)
        contentView.addSubview(composerController.view)
        contentView.addSubview(appsWidget)
        appsWidget.isHidden = browserState.isIncognito

        composerController.view.translatesAutoresizingMaskIntoConstraints = true
        composerController.view.autoresizingMask = []
    }

    private func setupObservers() {
        composerController.$contentSize
            .sink { [weak self] size in
                self?.updateWidgetVisibility(height: size.height)
                self?.updateContentLayout(composerSize: size)
            }
            .store(in: &cancellables)
    }

    func openApp(_ id: MistAppID) {
        let replacing = composerController.hasDraft() ? nil : currentTab
        if let appOpener { appOpener(id, replacing) }
        else { browserState.openApp(id, replacing: replacing) }
    }

    private func updateWidgetVisibility(height: CGFloat) {
        let show = !browserState.isIncognito && !areControlsHidden && height <= collapsedOmniBoxHeight
        guard appsWidget.isHidden == show else { return }
        if !show {
            appsWidget.isHidden = true
            appsWidget.alphaValue = 0
        } else {
            appsWidget.isHidden = false
            let animate = view.window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    appsWidget.animator().alphaValue = 1
                }
            } else { appsWidget.alphaValue = 1 }
        }
    }

    private func startKeyboardMonitoring() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func stopKeyboardMonitoring() {
        guard let keyDownMonitor else { return }
        NSEvent.removeMonitor(keyDownMonitor)
        self.keyDownMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard shouldHandleKeyboardEvent(event) else { return event }

        let isCommandKeyPressed = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76


        guard isCommandKeyPressed && isReturnKey else { return event }

        // Only intercept the composer's field editor, never a floating Cmd+L panel.
        guard let editor = view.window?.firstResponder as? NSTextView,
              editor.isFieldEditor,
              !editor.hasMarkedText(),
              let field = editor.delegate as? NSView,
              field.isDescendant(of: composerController.view) else { return event }
        composerController.submit(commandKeyPressed: true)
        return nil
    }

    private func shouldHandleKeyboardEvent(_ event: NSEvent) -> Bool {
        guard !areControlsHidden,
              let window = view.window,
              let eventWindow = event.window,
              eventWindow === window else {
            return false
        }
        return true
    }

    /// `composerSize` is the value `$contentSize` is about to store; reading the property from its
    /// sink would still see the old one.
    private func updateContentLayout(composerSize: NSSize? = nil) {
        guard isViewLoaded else { return }
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }
        // Fit the composer to the visible clip. Its natural width (the
        // kit's readable width) overflows narrow surfaces — an NTP
        // rendering inside a splitview pane — which pushed the content
        // column wider than the clip: the logo then centered off into the
        // hidden overflow and the box ran edge-to-edge. Capping the width
        // keeps the column within the clip, so everything re-centers as the
        // pane is resized.
        let omniNatural = composerSize ?? composerController.contentSize
        let omniHorizontalInset: CGFloat = 24
        let fittedOmniWidth = min(omniNatural.width,
                                  max(clipSize.width - omniHorizontalInset * 2, 240))
        let omniSize = NSSize(width: fittedOmniWidth, height: omniNatural.height)
        let headerSize = header.fittingSize

        let contentWidth = max(omniSize.width, headerSize.width, MistAppsWidget.width)
        let headerHeight = headerSize.height + logoGap
        // Center the collapsed card itself. Growing suggestions keeps its top fixed.
        let anchorTop = max((clipSize.height + collapsedOmniBoxHeight) / 2, headerHeight + collapsedOmniBoxHeight)
        let widgetHeight: CGFloat = appsWidget.isHidden ? 0 : appsGap + MistAppsWidget.height
        let overflow = max(0, omniSize.height + widgetHeight - anchorTop)

        let documentWidth = max(contentWidth, clipSize.width)
        let documentHeight = max(clipSize.height, anchorTop + headerHeight) + overflow
        let scrollY = scrollView.contentView.bounds.minY + documentHeight - contentView.frame.height
        contentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)

        let originX = (documentWidth - contentWidth) / 2
        let cardTop = anchorTop + overflow

        // The header sits logoGap above the card, centered on the column.
        header.frame = NSRect(x: originX + (contentWidth - headerSize.width) / 2, y: cardTop + logoGap,
                              width: headerSize.width, height: headerSize.height)

        // Suggestions expand down from the fixed card top.
        let omniX = originX + (contentWidth - omniSize.width) / 2
        let omniY = cardTop - omniSize.height
        composerController.view.frame = NSRect(x: omniX, y: omniY, width: omniSize.width, height: omniSize.height)
        appsWidget.frame = NSRect(x: originX + (contentWidth - MistAppsWidget.width) / 2,
                                  y: omniY - appsGap - MistAppsWidget.height,
                                  width: MistAppsWidget.width, height: MistAppsWidget.height)

        // Preserve the visible top when downward growth needs a taller document.
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX,
                                                  y: min(max(0, scrollY), max(0, documentHeight - clipSize.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

extension NewTabViewController: OmniBoxActionDelegate {
    func omniBoxDidClear() {
        setNativeControlsHidden(true)
        omniBoxController.reset()
    }
}
