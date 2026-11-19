// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
protocol OmniBoxSuggestionViewDelegate: AnyObject {
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didClickSuggestion suggestion: OmniBoxSuggestion, at index: Int)
    func suggestionView(_ suggestionView: OmniBoxSuggestionView, didDeleteSuggestion suggestion: OmniBoxSuggestion, at index: Int)
}

class OmniBoxSuggestionView: NSView {
    weak var delegate: OmniBoxSuggestionViewDelegate?
    var showsSwitchToTabHint = true
    var switchesToOpenTabByDefault = false
    static let topPadding: CGFloat = 2
    static let bottomPadding: CGFloat = 4
    private var suggestions: [OmniBoxSuggestion] = []
    private var isProgrammaticSelection = false
    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.backgroundColor = NSColor.clear
        scrollView.drawsBackground = false
        return scrollView
    }()
    
    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.intercellSpacing = NSSize.zero
        // The rows draw the kit's gray selection (`OmniBoxSuggestionRowView`).
        table.selectionHighlightStyle = .regular
        table.backgroundColor = NSColor.clear
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.refusesFirstResponder = true
        table.rowSizeStyle = .custom
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(handleRowClick(_:))
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = 100
        table.addTableColumn(column)
        
        return table
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        wantsLayer = true
        
        addSubview(scrollView)
        scrollView.documentView = tableView
        
        scrollView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview()
            make.top.equalToSuperview().offset(Self.topPadding)
            make.bottom.equalToSuperview().offset(-Self.bottomPadding)
        }
    }
    
    func updateSuggestions(_ suggestions: [OmniBoxSuggestion], selectedIndex: Int = -1, dataSourceChanged: Bool) {
        self.suggestions = suggestions
        func applySelection(_ index: Int) {
            if selectedIndex >= 0 && selectedIndex < self.suggestions.count {
                let oldSelection = tableView.selectedRow
                self.isProgrammaticSelection = true
                self.tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                // A collapsed list (its height follows the rows, after this) would scroll the row to its top.
                if self.tableView.visibleRect.height > 0 { self.tableView.scrollRowToVisible(selectedIndex) }
                self.isProgrammaticSelection = false
                if oldSelection != selectedIndex {
                    var rowsToReload = IndexSet()
                    if oldSelection >= 0 { rowsToReload.insert(oldSelection) }
                    if selectedIndex >= 0 { rowsToReload.insert(selectedIndex) }
                    if !rowsToReload.isEmpty {
                        tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
                    }
                }
            } else {
                self.tableView.deselectAll(nil)
            }
        }
        if dataSourceChanged {
            tableView.reloadData()
            // New rows start at the top: the default row sits below any app rows, and keeping an
            // earlier offset, or scrolling the default row up, hid the app rows above it.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        applySelection(selectedIndex)
    }
    
    @objc private func handleRowClick(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < suggestions.count else { return }
        let suggestion = suggestions[row]
        delegate?.suggestionView(self, didClickSuggestion: suggestion, at: row)
    }
}

// MARK: - NSTableViewDataSource

extension OmniBoxSuggestionView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return suggestions.count
    }
}

// MARK: - NSTableViewDelegate
extension OmniBoxSuggestionView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < suggestions.count else { return nil }
        let cellView = OmniBoxSuggestionCellView(
            suggestion: suggestions[row],
            index: row,
            showsSwitchToTabHint: showsSwitchToTabHint,
            switchesToOpenTabByDefault: switchesToOpenTabByDefault
        )
        cellView.configure(with: suggestions[row], index: row)
        cellView.delegate = self
        
        return cellView
    }
    
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return OmniBoxSuggestionRowView()
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }
}

// MARK: - Rows

/// A suggestion's row: the kit's list row, its hover and gray selected fills inset from the list's edges. It holds its
/// cell across the whole row, since the table's one column doesn't follow the list's width, and tells the cell when
/// the pointer is over it, which shows the delete button.
final class OmniBoxSuggestionRowView: MistRowView {
    static let insets = NSSize(width: 6, height: 2)
    private var pointerInside = false {
        didSet { cell?.isHovered = pointerInside }
    }
    private var cell: OmniBoxSuggestionCellView? {
        subviews.lazy.compactMap { $0 as? OmniBoxSuggestionCellView }.first
    }

    init() {
        super.init(style: .list)
        backgroundInsets = Self.insets
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool {
        didSet { cell?.updateAppearance() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard let cell = subview as? OmniBoxSuggestionCellView else { return }
        cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cell.topAnchor.constraint(equalTo: topAnchor),
            cell.leadingAnchor.constraint(equalTo: leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: trailingAnchor),
            cell.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        cell.isHovered = pointerInside
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); pointerInside = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); pointerInside = false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); pointerInside = false }
    override func viewDidHide() { super.viewDidHide(); pointerInside = false }
}

// MARK: - OmniBoxSuggestionCellViewDelegate

extension OmniBoxSuggestionView: OmniBoxSuggestionCellViewDelegate {
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didClick suggestion: OmniBoxSuggestion, at index: Int) {
        delegate?.suggestionView(self, didClickSuggestion: suggestion, at: index)
    }
    
    func suggestionCellView(_ cellView: OmniBoxSuggestionCellView, didRequestDelete suggestion: OmniBoxSuggestion, at index: Int) {
        delegate?.suggestionView(self, didDeleteSuggestion: suggestion, at: index)
    }
}
