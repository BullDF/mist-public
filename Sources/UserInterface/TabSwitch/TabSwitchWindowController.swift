// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

@MainActor
protocol TabSwitchWindowControllerDelegate: AnyObject {
    func tabSwitchWindowDidClickItem(tabID: Int)
    func tabSwitchWindowDidHoverItem(tabID: Int)
}

final class TabSwitchWindowController: NSWindowController {
    weak var selectionDelegate: TabSwitchWindowControllerDelegate?
    private var cellViews: [TabSwitchCellView] = []
    private let containerView = NSView()
    private let scrollView = NSScrollView()
    private let rowView = NSView()
    private weak var themeProvider: ThemeStateProvider?
    private var displayedTabIDs: [Int] = []
    // A panel that appears under a stationary cursor still gets mouseEntered,
    // as does a cell scrolled under it. Hover selects only after the cursor has
    // moved from where it was at build time or at the last selection scroll.
    private var initialMouseLocation: NSPoint?

    init(parentWindow: NSWindow) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear

        super.init(window: panel)

        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = TabSwitchMetrics.windowCornerRadius
        containerView.layer?.masksToBounds = true

        // Tabs past the window's width scroll sideways; the selection stays in view.
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = rowView
        containerView.addSubview(scrollView)

        panel.contentView = containerView
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [TabSwitchItem], selectedTabID: Int, themeProvider: ThemeStateProvider) {
        self.themeProvider = themeProvider
        applyTheme(themeProvider)

        cellViews.forEach { $0.removeFromSuperview() }
        cellViews.removeAll()
        displayedTabIDs.removeAll()

        guard let parentWindow = window?.parent else { return }
        let metrics = TabSwitchMetrics.self

        let cellWidth = metrics.cellWidth
        let spacing = metrics.cellSpacing
        let count = items.count

        displayedTabIDs = items.map(\.tabID)
        initialMouseLocation = NSEvent.mouseLocation

        let visibleCount = metrics.visibleCellCount(
            fittingPanelWidth: parentWindow.frame.width - metrics.windowParentMargin * 2
        )
        let windowWidth = metrics.panelWidth(cellCount: min(count, visibleCount))
        let windowHeight = metrics.cellHeight + metrics.windowVerticalInset * 2
        let windowX = parentWindow.frame.midX - windowWidth / 2
        let windowY = parentWindow.frame.midY - windowHeight / 2

        window?.setFrame(
            NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            display: false
        )
        containerView.frame = NSRect(origin: .zero, size: NSSize(width: windowWidth, height: windowHeight))
        scrollView.frame = containerView.bounds
        scrollView.tile()
        rowView.frame = NSRect(x: 0, y: 0, width: metrics.panelWidth(cellCount: count), height: windowHeight)

        var x = metrics.windowHorizontalInset
        for item in items {
            let isSelected = item.tabID == selectedTabID
            let cell = TabSwitchCellView(frame: NSRect(
                x: x,
                y: metrics.windowVerticalInset,
                width: cellWidth,
                height: metrics.cellHeight
            ))
            cell.configure(with: item, themeProvider: themeProvider)
            cell.setHighlighted(isSelected, themeProvider: themeProvider)

            let tabID = item.tabID
            cell.onClicked = { [weak self] in
                self?.selectionDelegate?.tabSwitchWindowDidClickItem(tabID: tabID)
            }
            cell.onHovered = { [weak self] hovered in
                guard hovered, let self, NSEvent.mouseLocation != self.initialMouseLocation else { return }
                self.selectionDelegate?.tabSwitchWindowDidHoverItem(tabID: tabID)
            }
            rowView.addSubview(cell)
            cellViews.append(cell)
            x += cellWidth + spacing
        }
        scrollSelectionIntoView(selectedTabID: selectedTabID)
    }

    func updateSelection(selectedTabID: Int) {
        guard let provider = themeProvider else { return }
        for (i, cell) in cellViews.enumerated() {
            let isSelected = (i < displayedTabIDs.count && displayedTabIDs[i] == selectedTabID)
            cell.setHighlighted(isSelected, themeProvider: provider)
        }
        scrollSelectionIntoView(selectedTabID: selectedTabID)
    }

    /// Tabs whose whole cell is inside the panel's visible row.
    var fullyVisibleTabIDs: [Int] {
        let visible = scrollView.contentView.bounds
        return zip(displayedTabIDs, cellViews).compactMap { tabID, cell in
            visible.contains(cell.frame) ? tabID : nil
        }
    }

    /// Scrolls the least distance that shows the selected cell with the panel's
    /// side inset; since the panel is a whole number of cells wide, every
    /// position keeps cells aligned with its edges.
    private func scrollSelectionIntoView(selectedTabID: Int) {
        guard let index = displayedTabIDs.firstIndex(of: selectedTabID),
              cellViews.indices.contains(index) else { return }
        let cell = cellViews[index]
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let target = cell.frame.insetBy(dx: -TabSwitchMetrics.windowHorizontalInset, dy: 0)
        var x = visible.minX
        if target.minX < visible.minX {
            x = target.minX
        } else if target.maxX > visible.maxX {
            x = target.maxX - visible.width
        }
        x = min(max(0, x), max(0, rowView.frame.width - visible.width))
        guard x != visible.minX else { return }
        clipView.scroll(to: NSPoint(x: x, y: visible.minY))
        scrollView.reflectScrolledClipView(clipView)
        initialMouseLocation = NSEvent.mouseLocation
    }

    private func applyTheme(_ provider: ThemeStateProvider) {
        let appearance = provider.currentAppearance
        let bgColor: NSColor = appearance.isDark ? .black : .white
        containerView.layer?.backgroundColor = bgColor.cgColor
        window?.appearance = appearance.nsAppearance
    }

    func dismiss() {
        if let panel = window, let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        window?.orderOut(nil)
    }
}
