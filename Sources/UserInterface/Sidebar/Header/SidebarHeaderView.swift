// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import Combine
import SwiftUI

class SidebarHeaderView: NSView, TitlebarAwareHitTestable {
    private enum AccessibilityID {
        static let sidebarButton = "sidebarHeader.sidebarButton"
        static let searchTabsButton = "sidebarHeader.searchTabsButton"
        static let backButton = "sidebarHeader.backButton"
        static let forwardButton = "sidebarHeader.forwardButton"
        static let refreshButton = "sidebarHeader.refreshButton"
        static let stopButton = "sidebarHeader.stopButton"
    }

    private lazy var cancellables = Set<AnyCancellable>()
    private var sidebarButtonLeftConstraint: Constraint?
    private var addressViewHeightConstraint: Constraint?
    private let defaultSidebarButtonTopOffset: CGFloat = 8
    private let legacySidebarButtonTopOffset: CGFloat = 15.5
    private let addressViewHeight: CGFloat = 32
    private var sidebarButtonLeftOffset: CGFloat = 78
    private let defaultSidebarButtonTrailingInset: CGFloat = 5
    private let balancedSidebarButtonTrailingInset: CGFloat = 9
    private var layoutSettleCancellable: AnyCancellable?
    /// Frame observer of the zoom button the sidebar button is aligned to;
    /// see `observeFrameChanges(zoomButton:)`.
    private var zoomButtonFrameObserver: NSObjectProtocol?
    private weak var observedZoomButton: NSButton?
    private var hasSetupConfigObserver = false
    private var isRefreshButtonHovered = false
    private var didPlayRefreshAnimationForCurrentHover = false

    /// The mounted Spaces-switch row (owned by the sidebar view controller);
    /// the header positions it and toggles its visibility with the feature flag.
    private weak var spaceSwitchView: NSView?
    /// Last-applied switch visibility, so the toggle observer only remakes
    /// constraints when the master Spaces flag actually flips.
    private var spaceSwitchVisible: Bool?
    /// Forces the Spaces-switch row visible even with a single Space. Set while
    /// the sidebar create-Space overlay is open so the icon row stays visible
    /// above the form (the user is managing Spaces, so the row is relevant even
    /// when there is nothing to switch to yet). See
    /// `SidebarViewController.showCreateSpaceOverlay`.
    var forcesSpaceSwitchVisible = false {
        didSet {
            guard oldValue != forcesSpaceSwitchVisible else { return }
            updateSpaceSwitchVisibility()
        }
    }

    private var isFloating: Bool = false
    private lazy var floatingTrafficLightsView = FloatingTrafficLightsView(browserState: browserState)
    
    private lazy var sidebarButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(image: .leftSidebarToggle,
//                                           imageSize: .init(width: 18, height: 13),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(sidebarButtonClicked))
        return button
    }()

    private lazy var searchTabsButton: HoverableButtonNSView = {
        let label = NSLocalizedString("sidebar.searchTabsButton.accessibilityLabel", value: "Search Tabs", comment: "Search Tabs - Button tooltip and accessibility label")
        let config = HoverableButtonConfig(image: .leftSidebarSearchTab,
                                           imageSize: .init(width: 16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(searchTabsButtonClicked))
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isHidden = true
        return button
    }()

    private lazy var backButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.left", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarBackward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(backButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var forwardButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "chevron.right", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: .sidebarForward,
//                                           imageSize: .init(width:  16, height: 16),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(forwardButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var refreshButton: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: "refresh",
            size: CGSize(width: 24, height: 24),
            hoverBackgroundColor: Color(nsColor: .sidebarTabHovered),
            cornerRadius: 4,
            animationTrigger: .manual,
            themedTintColor: .custom(light: .black, dark: .white),
            reverseOnHoverExit: true
        )
        let button = LottieAnimationNSView(
            config: config,
            target: self,
            selector: #selector(refreshButtonClicked)
        )
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        return button
    }()
    
    private lazy var stopButton: HoverableButtonNSView = {
        let image = NSImage.configureSymbolImage(systemName: "xmark", pointSize: 13, weight: .regular, color: .black)
        let config = HoverableButtonConfig(image: image,
                                           imageSize: .init(width: 14, height: 14),
                                           displayMode: .imageOnly,
                                           hoverBackgroundColor: .hover,
                                           imageTintColor: .textPrimary,
                                           cornerRadius: 4)
        let button = HoverableButtonNSView(config: config, target: self, selector: #selector(stopButtonClicked))
        button.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }
        button.isHidden = true
        return button
    }()

    private lazy var refreshStopButtonContainer: HoverableView = {
        let container = HoverableView()
        container.backgroundColor = .clear
        container.hoveredColor = .clear
        container.selectedColor = .clear
        container.responseToClickAction = false

        container.addSubview(refreshButton)
        container.addSubview(stopButton)

        refreshButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        stopButton.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        container.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        container.hoverStateChanged = { [weak self, weak container] hovered in
            guard let self, let container else { return }

            let hoverChanged = hovered != self.isRefreshButtonHovered
            self.isRefreshButtonHovered = hovered
            guard container.responseToHoverAnimation, hoverChanged else { return }

            if hovered {
                guard self.stopButton.isHidden else { return }
                self.didPlayRefreshAnimationForCurrentHover = true
                self.refreshButton.triggerAnimation()
            } else if self.didPlayRefreshAnimationForCurrentHover {
                self.didPlayRefreshAnimationForCurrentHover = false
                self.refreshButton.triggerReverseAnimation()
            }
        }

        return container
    }()

    private lazy var stackView: NSStackView = {
        let stack = NSStackView(views: [backButton, forwardButton, refreshStopButtonContainer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        return stack
    }()
    
    
    private lazy var addressView: SideAddressBar = {
        let addressView = SideAddressBar(browserState: browserState, isFloating: isFloating)
        addressView.setAccessoryButtonsVisible(isFloating)
        return addressView
    }()

    func setAddressBarButtonsVisible(_ visible: Bool, animated: Bool = true) {
        addressView.setAccessoryButtonsVisible(isFloating || visible, animated: animated)
    }
    
    private weak var browserState: BrowserState?
    
    init(state: BrowserState?, isFloating: Bool = false) {
        self.browserState = state
        self.isFloating = isFloating
        super.init(frame: .zero)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    deinit {
        if let zoomButtonFrameObserver {
            NotificationCenter.default.removeObserver(zoomButtonFrameObserver)
        }
    }
    
    // MARK: - TitlebarAwareHitTestable
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return false
    }
    
    private func setupViews() {
        let initialLayoutMode = browserState?.layoutMode ?? .performance
        let showInSidebar = isSidebarLayout(initialLayoutMode)

        configureAccessibilityIdentifiers()

        addSubview(sidebarButton)
        addSubview(searchTabsButton)

        sidebarButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(sidebarButtonTopOffset(for: showInSidebar))
            sidebarButtonLeftConstraint = make.left.equalToSuperview().offset(78).constraint
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        if isFloating {
            addSubview(floatingTrafficLightsView)
            floatingTrafficLightsView.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(FloatingTrafficLightMetrics.leading)
                make.centerY.equalTo(sidebarButton)
                make.size.equalTo(NSSize(width: FloatingTrafficLightMetrics.width,
                                         height: FloatingTrafficLightMetrics.size))
            }
        }

        searchTabsButton.snp.makeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            make.right.equalTo(sidebarButton.snp.left).offset(-2)
            make.size.equalTo(NSSize(width: 24, height: 24))
        }

        addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.centerY.equalTo(sidebarButton)
            make.height.equalTo(24)
            make.right.equalToSuperview().inset(9)
        }
        
        addSubview(addressView)
        addressView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.top.equalTo(stackView.snp.bottom).offset(12)
            addressViewHeightConstraint = make.height.equalTo(addressViewHeight).constraint
        }

        updateLayoutVisibility(layoutMode: initialLayoutMode)
    }

    private func configureAccessibilityIdentifiers() {
        configureButtonAccessibility(sidebarButton, identifier: AccessibilityID.sidebarButton)
        configureButtonAccessibility(searchTabsButton, identifier: AccessibilityID.searchTabsButton)
        configureButtonAccessibility(backButton, identifier: AccessibilityID.backButton)
        configureButtonAccessibility(forwardButton, identifier: AccessibilityID.forwardButton)
        configureButtonAccessibility(refreshButton, identifier: AccessibilityID.refreshButton)
        configureButtonAccessibility(stopButton, identifier: AccessibilityID.stopButton)
    }

    private func configureButtonAccessibility(_ button: NSView, identifier: String) {
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(identifier)
    }

    /// Mounts the Spaces-switch row between the nav row and the address bar so
    /// it reads as the top-most per-Space control. The view is owned by the
    /// sidebar view controller (a child hosting controller); the header only
    /// positions it and re-points the address bar to sit beneath it.
    func mountSpaceSwitch(_ view: NSView) {
        addSubview(view)
        spaceSwitchView = view
        updateSpaceSwitchVisibility()
    }

    /// Shows or hides the Spaces-switch row, reclaiming the row's height (and
    /// re-pinning the address bar to the nav row) when it is hidden. The row
    /// shows only when the master Spaces feature flag is on AND more than one
    /// Space exists — with a single Space there is nothing to switch to, so the
    /// pip row is pure noise. Called on mount, whenever the toggle flips, and
    /// whenever the Space count crosses the single-Space threshold, so the
    /// header never reserves space for a control the user can't use.
    func updateSpaceSwitchVisibility() {
        guard let view = spaceSwitchView else { return }
        let enabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && (SpaceManager.shared.spaces.count > 1 || forcesSpaceSwitchVisible)
        guard spaceSwitchVisible != enabled else { return }
        spaceSwitchVisible = enabled

        view.isHidden = !enabled
        if enabled {
            view.snp.remakeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.top.equalTo(stackView.snp.bottom).offset(8)
                make.height.equalTo(SpacesStripView.sidebarHeight)
            }
            addressView.snp.remakeConstraints { make in
                make.left.right.equalToSuperview()
                make.top.equalTo(view.snp.bottom).offset(12)
                addressViewHeightConstraint = make.height.equalTo(addressViewHeight).constraint
            }
        } else {
            view.snp.remakeConstraints { make in
                make.leading.trailing.equalToSuperview()
                make.top.equalTo(stackView.snp.bottom)
                make.height.equalTo(0)
            }
            addressView.snp.remakeConstraints { make in
                make.left.right.equalToSuperview()
                make.top.equalTo(stackView.snp.bottom).offset(12)
                addressViewHeightConstraint = make.height.equalTo(addressViewHeight).constraint
            }
        }
        updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)
    }

    private func isSidebarLayout(_ layoutMode: LayoutMode) -> Bool {
        layoutMode == .performance
    }

    private func sidebarButtonTopOffset(for showInSidebar: Bool) -> CGFloat {
        if isFloating {
            return defaultSidebarButtonTopOffset
        }
        return showInSidebar ? defaultSidebarButtonTopOffset : legacySidebarButtonTopOffset
    }

    /// Update view visibility based on configuration
    private func updateLayoutVisibility(layoutMode: LayoutMode) {
        let showInSidebar = isSidebarLayout(layoutMode)
        let inPlaceholder = browserState?.isInPlaceholderMode ?? false
        AppLogDebug("[SidebarHeader] updateLayoutVisibility showInSidebar=\(showInSidebar) inPlaceholder=\(inPlaceholder)")

        // Default layout: navigation buttons and address bar in sidebar.
        // Hide the back/forward/reload stack when in placeholder mode (no tab
        // to act on). Address bar visibility is delegated to SideAddressBar's
        // own placeholder-mode sink (blanks the text field).
        stackView.isHidden = !showInSidebar || inPlaceholder
        addressView.isHidden = !showInSidebar

        // Update addressView height constraint
        addressViewHeightConstraint?.update(offset: showInSidebar ? addressViewHeight : 0)

        // Adjust sidebarButton position
        sidebarButton.snp.remakeConstraints { make in
            make.top.equalToSuperview().offset(sidebarButtonTopOffset(for: showInSidebar))
            make.size.equalTo(NSSize(width: 24, height: 24))

            if showInSidebar {
                // Default layout: sidebarButton on left (after traffic light buttons)
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply default constraints offset=\(sidebarButtonLeftOffset)")
                sidebarButtonLeftConstraint = make.left.equalToSuperview().offset(sidebarButtonLeftOffset).constraint
            } else {
                // Legacy layout: sidebarButton aligned right
                AppLogDebug("[SidebarHeader] updateLayoutVisibility apply legacy constraints")
                let trailingInset = layoutMode == .balanced
                    ? balancedSidebarButtonTrailingInset
                    : defaultSidebarButtonTrailingInset
                make.right.equalToSuperview().inset(trailingInset)
            }
        }

        // In default layout mode, update sidebarButton left position based on window buttons
        if showInSidebar {
            scheduleSidebarButtonUpdateAfterLayoutChange()
        }
        if !isFloating {
            updateSidebarButtonLeftConstraint()
        }

        updateSidebarControlsVisibility(layoutMode: layoutMode)
    }

    /// Observe configuration changes
    private func setupConfigObserver() {
        guard hasSetupConfigObserver == false,
              let browserState else {
            return
        }
        hasSetupConfigObserver = true

        browserState.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink {  [weak self] mode in
                guard let self else {
                    return
                }
                updateLayoutVisibility(layoutMode: mode)
            }
            .store(in: &cancellables)

        // Re-run layout visibility on placeholder-mode transitions so the
        // back/forward/reload stack hides alongside the placeholder shell.
        // Reuse the same method to avoid overshadowing stackView.isHidden.
        browserState.$isInPlaceholderMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateLayoutVisibility(layoutMode: PhiPreferences.GeneralSettings.loadLayoutMode())
            }
            .store(in: &cancellables)

        browserState.$isInFullScreenMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
                self.updateLayoutVisibility(layoutMode: layoutMode)
                if self.isSidebarLayout(layoutMode) {
                    self.updateSidebarButtonLeftConstraint()
                }
            }
            .store(in: &cancellables)
    }
    
    /// Returns the maxX of the leading chrome controls in this header.
    private func leadingChromeMaxXRelativeToSelf() -> CGFloat? {
        if isFloating {
            if browserState?.isInFullScreenMode == true {
                return 0
            }
            return FloatingTrafficLightMetrics.maxX
        }
        return windowButtonMaxXRelativeToSelf(button: .zoomButton)
            ?? windowButtonMaxXRelativeToSelf(button: .closeButton)
    }

    /// Returns the maxX of a standard window button (e.g. .zoomButton or .fullScreenButton)
    /// in the current view's coordinate space. If the button doesn't exist, returns nil.
    private func windowButtonMaxXRelativeToSelf(button type: NSWindow.ButtonType) -> CGFloat? {
        if browserState?.isInFullScreenMode == true {
            return 0
        }
        
        guard let window, let btn = window.standardWindowButton(type) else { return nil }
        // Convert via window coordinates to avoid view-hierarchy mismatches during layout transitions.
        let rectInWindow = btn.convert(btn.bounds, to: nil)
        let rectInSelf = convert(rectInWindow, from: nil)
        AppLogDebug("[SidebarHeader] windowButtonMaxXRelativeToSelf type=\(type.rawValue) maxX=\(rectInSelf.maxX)")
        return rectInSelf.maxX
    }

    /// Updates the left constraint for `sidebarButton` based on the right edge of the leading chrome.
    private func updateSidebarButtonLeftConstraint() {
        observeFrameChanges(zoomButton: isFloating ? nil : window?.standardWindowButton(.zoomButton))
        guard let x = leadingChromeMaxXRelativeToSelf() else {
            AppLogDebug("[SidebarHeader] updateSidebarButtonLeftConstraint maxX=nil (window buttons unavailable)")
            return
        }
        // Keep a small gap after the leading chrome group.
        if !isFloating && abs(sidebarButtonLeftOffset - (x + 10)) < 0.01 { return }
        AppLogDebug("[SidebarHeader] updateSidebarButtonLeftConstraint update offset=\(x + 10)")
        sidebarButtonLeftOffset = x + 10
        sidebarButtonLeftConstraint?.update(offset: sidebarButtonLeftOffset)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Realigns the sidebar button when the zoom button changes frame, which
    /// titlebar layout changes do without resizing the window. Observed as an
    /// object: an observer without one runs for every view resized anywhere
    /// in the app, which an animation does every frame. The block form keeps
    /// neither the button nor the window alive. The observer follows the
    /// button the alignment last looked up: it moves to a button AppKit
    /// replaced and goes when the header leaves its window. The floating
    /// header aligns to its own lights and observes none.
    private func observeFrameChanges(zoomButton: NSButton?) {
        if let zoomButton, zoomButton === observedZoomButton { return }
        if let zoomButtonFrameObserver {
            NotificationCenter.default.removeObserver(zoomButtonFrameObserver)
        }
        zoomButtonFrameObserver = nil
        observedZoomButton = zoomButton
        guard let zoomButton else { return }
        zoomButtonFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: zoomButton,
            queue: .main
        ) { [weak self] _ in
            self?.updateSidebarButtonLeftConstraint()
        }
    }

    private func scheduleSidebarButtonUpdateAfterLayoutChange() {
        layoutSettleCancellable?.cancel()
        // The subscription retains its `object`, this view, until it fires.
        // A header that has left its window gets no layout pass to fire it
        // and would stay alive for good, with the state and slot its
        // subviews hold. Entering a window arms it and realigns directly.
        guard window != nil else {
            layoutSettleCancellable = nil
            return
        }
        postsFrameChangedNotifications = true
        layoutSettleCancellable = NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: self)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLogDebug("[SidebarHeader] frameDidChange settled updateSidebarButtonLeftConstraint")
                self.updateSidebarButtonLeftConstraint()
                self.layoutSettleCancellable?.cancel()
                self.layoutSettleCancellable = nil
            }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // React to layout-mode and preference changes.
        setupConfigObserver()
        updateLayoutVisibility(layoutMode: browserState?.layoutMode ?? .performance)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in Publishers.CombineLatest3(Just(tab), tab.$canGoBack, tab.$canGoForward) }
            .switchToLatest()
            .sink { [weak self] tab, canBack, canForward in
                guard let self else { return }
                self.backButton.isEnabled = canBack
                self.forwardButton.isEnabled = canForward
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                guard let self else { return }
                self.refreshButton.isHidden = false
                self.stopButton.isHidden = true
                self.addressView.currentTab = tab
            }
            .store(in: &cancellables)

        browserState?.$focusingTab
            .compactMap { $0 }
            .map { tab in
                tab.$isLoading.combineLatest(tab.$loadingProgress)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading, progress in
                guard let self else { return }
                self.updateStopRefreshButton(isLoading: isLoading, progress: CGFloat(progress))
            }
            .store(in: &cancellables)
        
        // Position sidebar button relative to the window's traffic-light buttons
        updateSidebarButtonLeftConstraint()

        // Keep updated on window resize. Matched by identity rather than
        // `object:` — a Combine subscription retains its `object`, and a
        // window retained by a view it hosts never deallocates. Titlebar
        // layout changes move the zoom button instead, which
        // `observeFrameChanges(zoomButton:)` observes without retaining it.
        if window != nil {
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification))
                .filter { [weak self] notification in
                    guard let self, let window = self.window else { return false }
                    return notification.object as? NSWindow === window
                }
                .sink { [weak self] _ in self?.updateSidebarButtonLeftConstraint() }
                .store(in: &cancellables)
        }

    }

    func refreshFloatingTrafficLights() {
        guard isFloating else {
            return
        }

        floatingTrafficLightsView.refreshWindowButtons()
    }

    @objc private func sidebarButtonClicked() {
        SpaceSessionControllersManager.shared.activeWindowController?.browserState.toggleSidebar(nil)
    }

    @objc private func searchTabsButtonClicked() {
        browserState?.windowController?.toggleSearchTabs(attachedTo: searchTabsButton)
    }
    
    @objc private func backButtonClicked() {
        if browserState?.closePeekForBackForwardNavigation() == true { return }
        if browserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        browserState?.focusingTab?.goBack()
    }

    @objc private func forwardButtonClicked() {
        if browserState?.closePeekForBackForwardNavigation() == true { return }
        if browserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        browserState?.focusingTab?.goForward()
    }
    
    @objc private func refreshButtonClicked() {
        browserState?.reloadFocusingTab()
    }

    @objc private func stopButtonClicked() {
        browserState?.stopLoadingFocusingTab()
    }

    private func updateStopRefreshButton(isLoading: Bool, progress: CGFloat) {
        let isNTP = browserState?.focusingTab?.isNTP == true
        let showStop = isLoading && !isNTP && progress > 0 && progress < 1.0
        refreshButton.isHidden = showStop
        stopButton.isHidden = !showStop
    }

    private func updateSidebarControlsVisibility(layoutMode: LayoutMode) {
        sidebarButton.isHidden = false
        searchTabsButton.isHidden = layoutMode != .balanced
    }
}
