// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

/// State model for the sidebar bottom bar.
class SidebarBottomBarState: ObservableObject {
    /// Single-row height.
    static let singleRowHeight: CGFloat = 24
    /// Two-row height.
    static let doubleRowHeight: CGFloat = 54
    /// Legacy compact layout flag, kept for compatibility.
    @Published var isCompact: Bool = false


    func height(for compact: Bool) -> CGFloat {
        return compact ? Self.doubleRowHeight : Self.singleRowHeight
    }
    /// Whether the chat button is hidden.
    @Published var isChatHidden: Bool = false
    @Published var showsMarkAsPrimary = false

    /// Whether the downloads popover is visible.
    @Published var isDownloadPopoverShown: Bool = false
}

/// SwiftUI implementation of the sidebar bottom bar.
struct SidebarBottomBarSwiftUI: View {
    @ObservedObject var state: SidebarBottomBarState
    @ObservedObject var downloadViewModel: DownloadButtonViewModel
    @ObservedObject var cardManager: NotificationCardManager

    let onChatTap: () -> Void
    let onCardEntryTap: () -> Void
    let onDownloadTap: () -> Void
    let onMarkAsPrimaryTap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            regularLayout(availableWidth: geometry.size.width)
        }
        .frame(height: SidebarBottomBarState.singleRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.footer")
    }

    // MARK: - Regular Layout


    private func regularLayout(availableWidth: CGFloat) -> some View {
        let iconCount = 1 + (showCardEntry ? 1 : 0) + (state.showsMarkAsPrimary ? 1 : 0)
        let gapCount = iconCount + (state.isChatHidden ? 0 : 1)
        let controlsWidth = CGFloat(iconCount) * 24
            + (state.isChatHidden ? 0 : ChatButton.preferredContentWidth)
        // Compress the gaps if the row cannot fit.
        let spacing = min(4, max(0, (availableWidth - controlsWidth
            - 2 * WebContentConstant.edgesSpacing) / CGFloat(gapCount)))
        return HStack(spacing: spacing) {
            if state.showsMarkAsPrimary {
                MarkAsPrimaryButton(action: onMarkAsPrimaryTap)
            }
            cardEntryButton

            Spacer(minLength: 0)

            downloadButton


            if !state.isChatHidden {
                ChatButton(action: onChatTap)
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, WebContentConstant.edgesSpacing)
    }

    // MARK: - Download Button

    @ViewBuilder
    private var downloadButton: some View {
        DownloadButtonView(
            viewModel: downloadViewModel,
            onTap: {
                onDownloadTap()
                state.isDownloadPopoverShown.toggle()
            }
        )
        .background(
            SidebarDownloadsPopoverPresenter(
                isPresented: $state.isDownloadPopoverShown,
                downloadsManager: downloadViewModel.downloadsManager
            )
        )
    }

    // MARK: - Legacy Compact Layout

    private var showCardEntry: Bool {
        cardManager.latestCard != nil
    }

    @ViewBuilder
    private var cardEntryButton: some View {
        if showCardEntry {
            CardEntryButton(action: onCardEntryTap)
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .identity
                    )
                )
        }
    }
}

// MARK: - Downloads Popover

private struct SidebarDownloadsPopoverPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let downloadsManager: DownloadsManager?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        PassthroughAnchorView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            downloadsManager: downloadsManager,
            anchorView: nsView,
            onDismiss: {
                isPresented = false
            }
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    private final class PassthroughAnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private static let contentSize = NSSize(width: 340, height: 317)
        private static let screenEdgeMargin: CGFloat = 8

        private var popover: NSPopover?
        private var onDismiss: (() -> Void)?

        func update(
            isPresented: Bool,
            downloadsManager: DownloadsManager?,
            anchorView: NSView,
            onDismiss: @escaping () -> Void
        ) {
            self.onDismiss = onDismiss

            guard isPresented else {
                dismiss()
                return
            }
            guard popover == nil,
                  let downloadsManager,
                  anchorView.window != nil else { return }

            present(downloadsManager: downloadsManager, anchorView: anchorView)
        }

        func dismiss() {
            guard let popover else { return }
            self.popover = nil
            popover.delegate = nil
            popover.performClose(nil)
        }

        private func present(downloadsManager: DownloadsManager, anchorView: NSView) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = Self.contentSize
            popover.appearance = anchorView.themeStateProvider.currentAppearance.nsAppearance
            popover.contentViewController = ThemedHostingController(
                rootView: DownloadsListView(downloadsManager: downloadsManager) { [weak self, weak anchorView] in
                    self?.dismiss()
                    self?.onDismiss?()
                    guard let anchorView, let window = anchorView.window,
                          let owner = SpaceSessionControllersManager.shared.findControllerWith(window: window) else { return }
                    owner.showLibrary(from: anchorView, section: .downloads)
                }
                    .frame(width: Self.contentSize.width, height: Self.contentSize.height),
                themeSource: anchorView.themeStateProvider
            )
            popover.delegate = self
            popover.setValue(shouldHideAnchor(for: anchorView), forKeyPath: "shouldHideAnchor")

            self.popover = popover
            popover.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .maxY
            )
        }

        private func shouldHideAnchor(for anchorView: NSView) -> Bool {
            guard let window = anchorView.window else { return false }

            let anchorWindowRect = anchorView.convert(anchorView.bounds, to: nil)
            let anchorScreenRect = window.convertToScreen(anchorWindowRect)
            let anchorCenter = NSPoint(x: anchorScreenRect.midX, y: anchorScreenRect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(anchorCenter) } ?? window.screen
            guard let visibleFrame = screen?.visibleFrame else { return false }

            let centeredMinX = anchorScreenRect.midX - Self.contentSize.width / 2
            let centeredMaxX = anchorScreenRect.midX + Self.contentSize.width / 2
            return centeredMinX < visibleFrame.minX + Self.screenEdgeMargin
                || centeredMaxX > visibleFrame.maxX - Self.screenEdgeMargin
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closedPopover = notification.object as? NSPopover,
                  closedPopover === popover else { return }
            popover = nil
            closedPopover.delegate = nil
            onDismiss?()
        }
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let image: NSImage
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Mark as Primary Button

struct MarkAsPrimaryButton: View {
    let action: () -> Void
    @State private var isHovering = false

    private var title: String {
        NSLocalizedString("sidebar.footer.markAsPrimary", value: "Mark as Primary", comment: "Sidebar footer button tooltip and accessibility label for a non-primary window")
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "macwindow.badge.plus")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .themedForeground(.textPrimary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.sidebarTabHovered : .clear))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .customTooltip(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar.footer.markAsPrimary")
    }
}

// MARK: - Card Entry Button

struct CardEntryButton: View {
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPopping = false

    private let buttonSize: CGFloat = 24
    private let cornerRadius: CGFloat = 6
    private let popScale: CGFloat = 1.18
    private let popDelay: TimeInterval = 0.22
    private let popUpDuration: TimeInterval = 0.12
    private let popDownDuration: TimeInterval = 0.18

    var body: some View {
        Button(action: action) {
            Image(.cardBulbIcon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? Color.sidebarTabHovered : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPopping ? popScale : 1)
        .onAppear {
            isPopping = false
            DispatchQueue.main.asyncAfter(deadline: .now() + popDelay) {
                withAnimation(.easeOut(duration: popUpDuration)) {
                    isPopping = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + popUpDuration) {
                    withAnimation(.easeInOut(duration: popDownDuration)) {
                        isPopping = false
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - NSView Bridge

/// AppKit bridge for the SwiftUI sidebar bottom bar.
class SidebarBottomBarSwiftUIView: NSView {
    private var hostingView: ThemedHostingView?
    private let state = SidebarBottomBarState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var cancellables = Set<AnyCancellable>()
    /// Height change callback.
    var onHeightChange: ((CGFloat) -> Void)?

    /// Button callbacks.
    var onChatTap: (() -> Void)?
    var onCardEntryTap: (() -> Void)?
    var onDownloadTap: (() -> Void)?
    var onMarkAsPrimaryTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
        setupObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
        setupObservers()
    }

    private func setupHostingView() {
        let hosting = ThemedHostingView(
            rootView: SidebarBottomBarSwiftUI(
                state: state,
                downloadViewModel: downloadViewModel,
                cardManager: NotificationCardManager.shared,
                onChatTap: { [weak self] in self?.onChatTap?() },
                onCardEntryTap: { [weak self] in self?.onCardEntryTap?() },
                onDownloadTap: { [weak self] in self?.onDownloadTap?() },
                onMarkAsPrimaryTap: { [weak self] in self?.onMarkAsPrimaryTap?() }
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The wrapper is sized by the sidebar (both edges and its height are
        // pinned there); the SwiftUI content must not pin its own minimum
        // width on the column through the host's default sizing options —
        // see ShellSidebarHostViewController.host.
        hosting.sizingOptions = []
        addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingView = hosting
    }

    private func setupObservers() {
        // Propagate compact-mode height changes to the container.
        state.$isCompact
            .removeDuplicates()
            .sink { [weak self] isCompact in
                guard let self = self else { return }
                self.onHeightChange?(self.state.height(for: isCompact))
            }
            .store(in: &cancellables)

    }

    /// Hides or shows the chat button, for example in private mode.
    func setChatHidden(_ hidden: Bool) {
        state.isChatHidden = hidden
    }

    func setMarkAsPrimaryVisible(_ visible: Bool) {
        state.showsMarkAsPrimary = visible
    }

    /// Hides the hosted controls while the create-Space form covers the bottom
    /// bar. The outer AppKit wrapper stays mounted so its stack height remains
    /// unchanged, while SwiftUI hover and native help tracking are deactivated.
    func setCreateSpaceOverlayInteractionSuppressed(_ suppressed: Bool) {
        hostingView?.isHidden = suppressed
    }

    /// Binds the downloads manager for progress display.
    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }

}
