import AppKit
import Combine
import MistMailCore

final class MailPageViewController: NSViewController, MistAppPage, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    weak var browserState: BrowserState?
    weak var tab: Tab?
    let model: MailPageModel
    let split = MistSplitView()
    let outline = MailboxOutlineView()
    let table = MailMessageTable()
    let readerContainer = AgentChatBackgroundView()
    private lazy var reader = MailReaderViewController(model: model)
    private var composeController: MailComposeViewController?
    private let mailboxScroll = NSScrollView(), messageScroll = NSScrollView(), listPane = NSView()
    private let titleLabel = NSTextField.mistLabel(style: .title)
    private let placeholder = MistPlaceholderView()
    private let mailboxPane = MistSidebarView()
    let searchField = NSSearchField()
    private let serverSearchButton = MistButton(title: MailStrings.searchOnServer, size: .regular)
    private let markAllReadButton = MistIconButton(symbol: "envelope.open", title: MailStrings.markAllRead)
    private let banner = NSStackView(), notice = MistNoticeBar()
    private let noAccounts = MistUnavailableStateView(glyph: .symbol("envelope"), title: MailStrings.noAccountsTitle,
        message: MailStrings.noAccountsMessage, actionTitle: MailStrings.addAccount, onAction: { MailPageViewController.openSettings() })
    private var nodes: [MailboxTreeNode] = []
    private var displayedMessages: [MailMessageSummary] = []
    private var subscriptions = Set<AnyCancellable>()
    private var scrollObserver: NSObjectProtocol?
    private var userCollapsedMailboxes = false, automaticallyCollapsed = false, applyingSelection = false
    /// Fits the longest cross-account name (fr "Tous les messages indésirables") with an unread count.
    private static let mailboxWidth: CGFloat = 270, listWidth: CGFloat = 420
    private static let mailboxLimits: ClosedRange<CGFloat> = 150...320, listMinimum: CGFloat = 260, readerMinimum: CGFloat = 240
    private var needsDefaultPanePositions = false
    private let defaults: UserDefaults
    /// Every render rebuilds the sidebar, so the carets the user closed are kept by key.
    private var collapsedMailboxKeys: Set<String> { didSet { defaults.set(Array(collapsedMailboxKeys).sorted(), forKey: "mist.mail.collapsedMailboxes") } }
    var pageZoom: CGFloat? { reader.zoom }

    func show(_ address: MistAppAddress, tab: Tab, state: BrowserState) {
        browserState = state
        self.tab = tab
    }

    init(source: (any MailPageDataSource)? = nil, defaults: UserDefaults = .standard) {
        model = MailPageModel(source: source ?? EngineMailPageDataSource(engine: MistMailService.shared.engine), defaults: defaults)
        self.defaults = defaults
        collapsedMailboxKeys = Set(defaults.stringArray(forKey: "mist.mail.collapsedMailboxes") ?? [])
        super.init(nibName: nil, bundle: nil)
        if model.source is EngineMailPageDataSource {
            model.takePendingRevealMessageID = { [weak self] in
                guard self?.isFocusedMailPage == true else { return nil }
                return MistMailService.shared.consumePendingRevealMessageID()
            }
            NotificationCenter.default.publisher(for: .mistMailRevealMessage).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.revealPendingMessage() }.store(in: &subscriptions)
            // A notification click posts the reveal before activation makes this window key;
            // take it once the window does.
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self, self.isViewLoaded, (note.object as? NSWindow) === self.view.window else { return }
                    self.revealPendingMessage()
                }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    override func loadView() {
        let background = MailPageBackgroundView()
        background.controller = self
        view = background; view.setFrameSize(NSSize(width: 1100, height: 700))
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        configureMailboxes(); configureMessages(); configureReader()
        // NSSplitView sizes its panes by frame and resizes them in proportion, so panes added at
        // zero width stay there: start them at their default widths.
        mailboxPane.setFrameSize(NSSize(width: Self.mailboxWidth, height: 700)); listPane.setFrameSize(NSSize(width: Self.listWidth, height: 700)); readerContainer.setFrameSize(NSSize(width: 408, height: 700))
        split.addArrangedSubview(mailboxPane); split.addArrangedSubview(listPane); split.addArrangedSubview(readerContainer)
        // Pane limits are constraints, not constrainMin/MaxCoordinate: a delegate implementing those
        // puts NSSplitView in its legacy layout, where adjustSubviews leaves the divider layers drawn
        // at their old positions and holding priorities are ignored. Below required, so a page too
        // narrow for them squeezes the panes instead of breaking constraints.
        for constraint in [mailboxPane.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.mailboxLimits.lowerBound), mailboxPane.widthAnchor.constraint(lessThanOrEqualToConstant: Self.mailboxLimits.upperBound), listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.listMinimum), readerContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.readerMinimum)] {
            constraint.priority = .init(999); constraint.isActive = true
        }
        // Restores only once the panes exist. Renamed when the mailbox default widened, so widths
        // saved at the old 210 pt reset once.
        split.autosaveName = "MistMailPanes2"
        // With nothing saved, the split view scales these frames to its first real width; place the
        // dividers at the defaults instead, once it has one.
        needsDefaultPanePositions = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MistMailPanes2") == nil
        // Window resizes go to the reading pane first.
        split.setHoldingPriority(.init(260), forSubviewAt: 0); split.setHoldingPriority(.init(255), forSubviewAt: 1); split.setHoldingPriority(.defaultLow, forSubviewAt: 2)
        banner.orientation = .vertical; banner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 0, right: 12)
        notice.action.onClick = { Self.openSettings() }
        banner.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalTo: banner.widthAnchor, constant: -24).isActive = true
        let stack = NSStackView(views: [banner, split]); stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        view.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor), split.widthAnchor.constraint(equalTo: stack.widthAnchor), banner.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        configureNoAccounts()
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.render() }.store(in: &subscriptions)
        model.start(); render()
    }
    private func configureNoAccounts() {
        view.addSubview(noAccounts); noAccounts.translatesAutoresizingMaskIntoConstraints = false
        // Sits a little above center, where the eye lands on an empty page.
        NSLayoutConstraint.activate([noAccounts.centerXAnchor.constraint(equalTo: view.centerXAnchor), noAccounts.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24), noAccounts.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)])
    }
    static func openSettings() { AppController.shared?.showSettings(pane: .mistMail) }
    override func viewDidAppear() { super.viewDidAppear(); focusContent(); revealPendingMessage() }
    private var isFocusedMailPage: Bool {
        isViewLoaded && view.window?.isKeyWindow == true && !view.isHiddenOrHasHiddenAncestor && tab != nil && browserState?.focusingTab?.guid == tab?.guid
    }
    private func revealPendingMessage() {
        guard model.didStart, let id = model.takePendingRevealMessageID?() else { return }
        Task { [model] in await model.reveal(messageID: id) }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let composer = composeController {
            composer.commitPendingFields()
            Task { [composer, model = composer.model] in
                do { try await model.saveNow() } catch { model.report(error) }
                withExtendedLifetime(composer) {}
            }
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let narrow = view.bounds.width < 820
        if narrow != automaticallyCollapsed { automaticallyCollapsed = narrow; applyMailboxVisibility() }
        repairPanesIfNeeded()
    }
    /// Frames autosaved from a transient layout can leave a pane at zero width. The panes can't be
    /// dragged below these minimums, so reset to the defaults then. A hidden split view (no
    /// accounts yet) ignores `setPosition`, and so does one mid-layout: run after both.
    private func repairPanesIfNeeded() {
        guard !split.isHidden, split.bounds.width > 0 else { return }
        // A hidden sidebar's divider is hidden too and takes no width.
        let mailboxMinimum: CGFloat = mailboxPane.isHidden ? 0 : Self.mailboxLimits.lowerBound + split.dividerThickness
        let degenerate = listPane.frame.width < Self.listMinimum || readerContainer.frame.width < Self.readerMinimum || (!mailboxPane.isHidden && mailboxPane.frame.width < Self.mailboxLimits.lowerBound)
        let fits = split.bounds.width >= mailboxMinimum + Self.listMinimum + split.dividerThickness + Self.readerMinimum
        guard degenerate || needsDefaultPanePositions, fits else { return }
        needsDefaultPanePositions = false
        DispatchQueue.main.async { [weak self] in self?.resetPanePositions() }
    }
    private func resetPanePositions() {
        if !mailboxPane.isHidden { split.setPosition(Self.mailboxWidth, ofDividerAt: 0) }
        let listStart: CGFloat = mailboxPane.isHidden ? 0 : Self.mailboxWidth + split.dividerThickness
        split.setPosition(listStart + Self.listWidth, ofDividerAt: 1)
    }
    func focusContent() {
        if let composeController { composeController.focusInitial() }
        else { view.window?.makeFirstResponder(table) }
    }
    func refresh() { model.refresh() }
    @objc func undo(_ sender: Any?) {
        guard ownsMessageHistoryFocus, model.canUndo else { return }
        Task { await model.undo() }
    }
    @objc func redo(_ sender: Any?) {
        guard ownsMessageHistoryFocus, model.canRedo else { return }
        Task { await model.redo() }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return ownsMessageHistoryFocus && model.canUndo
        case #selector(redo(_:)): return ownsMessageHistoryFocus && model.canRedo
        default: return true
        }
    }
    private var pageFirstResponder: NSResponder? {
        guard isViewLoaded, !view.isHiddenOrHasHiddenAncestor, let window = view.window, window.isKeyWindow,
              let responder = window.firstResponder else { return nil }
        return responder === window || (responder as? NSView)?.isDescendant(of: view) == true ? responder : nil
    }
    private func ownsTextHistory(_ responder: NSResponder) -> Bool {
        if responder is NSText { return true }
        guard let composer = composeController, let view = responder as? NSView else { return false }
        return view.isDescendant(of: composer.view)
    }
    private var ownsMessageHistoryFocus: Bool {
        guard let responder = pageFirstResponder else { return false }
        return !ownsTextHistory(responder)
    }
    func historyMenuEnabled(redo: Bool) -> Bool? {
        guard let responder = pageFirstResponder else { return nil }
        if ownsTextHistory(responder) {
            return redo ? responder.undoManager?.canRedo == true : responder.undoManager?.canUndo == true
        }
        return redo ? model.canRedo : model.canUndo
    }
    @discardableResult
    func performMessageHistory(redo: Bool) -> Bool {
        guard ownsMessageHistoryFocus, redo ? model.canRedo : model.canUndo else { return false }
        if redo { self.redo(nil) } else { undo(nil) }
        return true
    }
    static func historyShortcut(_ event: NSEvent) -> Bool? {
        guard let key = ShortcutsKey.eventKeys(for: event)?.canonical, key.characters == "z",
              key.modifiers == [.command] || key.modifiers == [.command, .shift] else { return nil }
        return key.modifiers.contains(.shift)
    }
    func performPageCommand(_ command: CommandWrapper) -> Bool {
        if command == .IDC_CONTENT_CONTEXT_UNDO || command == .IDC_CONTENT_CONTEXT_REDO {
            guard let responder = pageFirstResponder else { return false }
            let redo = command == .IDC_CONTENT_CONTEXT_REDO
            if ownsTextHistory(responder) {
                if redo { responder.undoManager?.redo() } else { responder.undoManager?.undo() }
            } else { performMessageHistory(redo: redo) }
            return true
        }
        if command == .IDC_RELOAD || command == .IDC_RELOAD_BYPASSING_CACHE { refresh(); return true }
        guard [.IDC_FIND, .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS, .IDC_ZOOM_PLUS, .IDC_ZOOM_MINUS, .IDC_ZOOM_NORMAL].contains(command) else { return false }
        if let composeController {
            switch command {
            case .IDC_ZOOM_PLUS, .IDC_ZOOM_MINUS, .IDC_ZOOM_NORMAL:
                reader.performPageCommand(command); composeController.editor.pageZoom = reader.zoom
            default: break
            }
        } else { reader.performPageCommand(command) }
        return true
    }
    override func cancelOperation(_ sender: Any?) {
        if reader.isFindOpen { reader.closeFind(); focusContent() }
        else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    private func configureMailboxes() {
        let column = NSTableColumn(identifier: .init("mailbox")); column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column
        // The column follows the pane's width, so the rows' trailing counts stay in view; the
        // plain style drops the inset style's own padding, so the first row lines up with the
        // list's header.
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle; outline.autoresizesOutlineColumn = false; outline.style = .plain
        outline.headerView = nil; outline.rowHeight = MistSidebarCellView.rowHeight; outline.intercellSpacing = .zero; outline.indentationPerLevel = 12
        outline.dataSource = self; outline.delegate = self; outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular; outline.focusRingType = .none; outline.setAccessibilityLabel(MailStrings.mailboxes)
        mailboxScroll.documentView = outline; mailboxScroll.hasVerticalScroller = true; mailboxScroll.drawsBackground = false
        mailboxScroll.automaticallyAdjustsContentInsets = false
        mailboxScroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        mailboxPane.addSubview(mailboxScroll); mailboxScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mailboxScroll.leadingAnchor.constraint(equalTo: mailboxPane.leadingAnchor),
            mailboxScroll.trailingAnchor.constraint(equalTo: mailboxPane.trailingAnchor),
            mailboxScroll.topAnchor.constraint(equalTo: mailboxPane.topAnchor), mailboxScroll.bottomAnchor.constraint(equalTo: mailboxPane.bottomAnchor)])
    }
    private func configureMessages() {
        let toggle = MistIconButton(symbol: "sidebar.left", title: MailStrings.toggleSidebar)
        // From what shows: dragging the divider or a restored autosave can collapse the sidebar too,
        // and its divider hides with it, so this button is the way back.
        toggle.onClick = { [weak self] in guard let self else { return }; userCollapsedMailboxes = !mailboxPane.isHidden; applyMailboxVisibility() }
        let refresh = MailRefreshButton(); refresh.onClick = { [weak self] in self?.refresh() }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let composeSlot = MistIconButton(symbol: "square.and.pencil", title: MailStrings.newMessage)
        composeSlot.onClick = { [weak self] in Task { await self?.model.newMessage() } }
        markAllReadButton.onClick = { [weak self] in Task { await self?.model.markAllRead() } }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView.mistToolbar([toggle, titleLabel, spacer, refresh, markAllReadButton, composeSlot])
        listPane.addSubview(toolbar); toolbar.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = MailStrings.searchMail; searchField.setAccessibilityLabel(MailStrings.searchMail)
        searchField.delegate = self; searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true; searchField.sendsWholeSearchString = false
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        serverSearchButton.onClick = { [weak self] in Task { await self?.model.searchServer() } }
        let searchRow = NSStackView(views: [MistFieldWellView(searchField, shape: .capsule), serverSearchButton]); searchRow.spacing = 8
        listPane.addSubview(searchRow); searchRow.translatesAutoresizingMaskIntoConstraints = false
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        table.headerView = nil; table.style = .plain; table.rowHeight = MailMessageCell.rowHeight; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true; table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.setAccessibilityLabel(MailStrings.messages)
        table.onDelete = { [weak self] in self?.model.perform(.delete) }
        table.contextMenu = { [weak self] row in
            guard let self, displayedMessages.indices.contains(row) else { return nil }
            return MailMessageMenus.menu(for: displayedMessages[row], model: model)
        }
        messageScroll.documentView = table; messageScroll.hasVerticalScroller = true; messageScroll.drawsBackground = false
        messageScroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: messageScroll.contentView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.loadMoreIfNeeded() } }
        listPane.addSubview(messageScroll); messageScroll.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([toolbar.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 14), toolbar.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -14), toolbar.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 10), toolbar.heightAnchor.constraint(equalToConstant: 28), searchRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), searchRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), searchRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), searchRow.heightAnchor.constraint(equalToConstant: 28), messageScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8), messageScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor), messageScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor), messageScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor), placeholder.centerXAnchor.constraint(equalTo: messageScroll.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: messageScroll.centerYAnchor)])
    }
    @objc private func searchChanged() { model.setSearchQuery(searchField.stringValue) }
    func controlTextDidChange(_ notification: Notification) { searchChanged() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(cancelOperation(_:)) else { return false }
        model.clearSearch(); searchField.stringValue = ""; return true
    }
    private func configureReader() {
        addChild(reader); readerContainer.addSubview(reader.view); reader.view.translatesAutoresizingMaskIntoConstraints = false
        reader.openLink = { [weak self] url in self?.browserState?.openMailLink(url) }
        NSLayoutConstraint.activate([reader.view.leadingAnchor.constraint(equalTo: readerContainer.leadingAnchor), reader.view.trailingAnchor.constraint(equalTo: readerContainer.trailingAnchor), reader.view.topAnchor.constraint(equalTo: readerContainer.topAnchor), reader.view.bottomAnchor.constraint(equalTo: readerContainer.bottomAnchor)])
    }
    private func applyMailboxVisibility() {
        // A hidden pane keeps its frame, so the sidebar comes back at the width it had.
        let width = Self.mailboxLimits.contains(mailboxPane.frame.width) ? mailboxPane.frame.width : Self.mailboxWidth
        mailboxPane.isHidden = userCollapsedMailboxes || automaticallyCollapsed; split.adjustSubviews()
        if !mailboxPane.isHidden { split.setPosition(width, ofDividerAt: 0) }
    }
    private func render() {
        guard isViewLoaded else { return }
        noAccounts.isHidden = !model.state.accounts.isEmpty; split.isHidden = model.state.accounts.isEmpty; repairPanesIfNeeded()
        titleLabel.stringValue = model.title
        markAllReadButton.isEnabled = model.canMarkAllRead
        if searchField.stringValue != model.searchQuery { searchField.stringValue = model.searchQuery }
        serverSearchButton.isHidden = !model.isSearching; serverSearchButton.isEnabled = !model.searchingServer
        let failure = model.failedAccounts.first.map { String(format: MailStrings.signInFailed, $0.config.displayName) }
        notice.show(message: model.banner ?? failure ?? "", actionTitle: failure == nil ? nil : MailStrings.settings); banner.isHidden = notice.message.stringValue.isEmpty
        nodes = MailboxTreeNode.build(model.state); applyingSelection = true
        outline.reloadData(); expandMailboxes(nodes)
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? MailboxTreeNode)?.key == model.mailboxKey { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if displayedMessages != model.messages {
            let visible = table.rows(in: messageScroll.contentView.bounds)
            // Scrolled down, the top visible row stays put; at the top, new mail shows above it.
            let validTop = messageScroll.contentView.bounds.minY > 0 && visible.location != NSNotFound && visible.location < displayedMessages.count
            let top = validTop ? displayedMessages[visible.location].id : nil
            let offset = validTop ? messageScroll.contentView.bounds.minY - table.rect(ofRow: visible.location).minY : 0
            displayedMessages = model.messages; table.reloadData()
            if let top, let index = displayedMessages.firstIndex(where: { $0.id == top }) { messageScroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY + offset)); messageScroll.reflectScrolledClipView(messageScroll.contentView) }
        }
        if let id = model.selection, let row = displayedMessages.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } else { table.deselectAll(nil) }
        applyingSelection = false
        placeholder.show(message: model.loading ? MailStrings.loading : (model.isSearching ? MailStrings.noResults : MailStrings.emptyMailbox), loading: model.loading); placeholder.isHidden = !model.messages.isEmpty
        updateReaderSelection()
    }
    func updateReaderSelection() {
        if let compose = model.compose {
            if composeController?.model !== compose {
                removeComposer()
                let controller = MailComposeViewController(model: compose, accounts: model.state.accounts)
                composeController = controller
                if model.source is EngineMailPageDataSource { MistMailService.shared.registerComposer(compose) }
                reader.closeFind(); addChild(controller); readerContainer.addSubview(controller.view)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: readerContainer.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: readerContainer.trailingAnchor), controller.view.topAnchor.constraint(equalTo: readerContainer.topAnchor), controller.view.bottomAnchor.constraint(equalTo: readerContainer.bottomAnchor)])
                controller.editor.pageZoom = reader.zoom; controller.focusInitial()
            }
            reader.view.isHidden = true
        } else {
            removeComposer(); reader.view.isHidden = false; reader.show(model.selectedMessage)
        }
    }
    private func removeComposer() {
        guard let composeController else { return }
        composeController.editor.detach(); composeController.view.removeFromSuperview(); composeController.removeFromParent(); self.composeController = nil
    }
    private func loadMoreIfNeeded() {
        let visible = table.rows(in: messageScroll.contentView.bounds)
        if visible.location != NSNotFound, visible.location + visible.length >= displayedMessages.count - 15 { model.loadMore() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayedMessages.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let row = MistRowView(style: .list); row.backgroundInsets = NSSize(width: 8, height: 2); return row
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("mail.messageRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? MailMessageCell ?? MailMessageCell(frame: .zero); cell.identifier = id
        let message = displayedMessages[row], role = model.state.mailboxes.first { $0.id == displayedMessages[row].mailboxID }?.role
        cell.update(message, role: role, accountName: model.mailbox == nil ? model.state.accounts.first { $0.id == message.accountID }?.config.displayName : nil)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        model.selectMessage(displayedMessages.indices.contains(table.selectedRow) ? displayedMessages[table.selectedRow].id : nil)
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? MailboxTreeNode)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? MailboxTreeNode)?.children[index] ?? nodes[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! MailboxTreeNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! MailboxTreeNode).canSelect }
    private func expandMailboxes(_ nodes: [MailboxTreeNode]) {
        for node in nodes where !node.children.isEmpty && !collapsedMailboxKeys.contains(node.key) {
            outline.expandItem(node); expandMailboxes(node.children)
        }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !applyingSelection, let node = notification.userInfo?["NSObject"] as? MailboxTreeNode else { return }
        collapsedMailboxKeys.remove(node.key)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applyingSelection, let node = notification.userInfo?["NSObject"] as? MailboxTreeNode else { return }
        collapsedMailboxKeys.insert(node.key)
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let node = outline.item(atRow: outline.selectedRow) as? MailboxTreeNode, node.canSelect else { return }; model.selectMailbox(node.key)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! MailboxTreeNode
        let identifier = NSUserInterfaceItemIdentifier("mail.mailboxRow")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? MistSidebarCellView ?? MistSidebarCellView()
        cell.identifier = identifier
        if let id = node.accountID {
            let status = model.state.statuses[id]
            let leading = MailAccountStatusView(status: status) { [weak self] in
                if self?.model.state.statuses[id] == .authFailed { Self.openSettings() }
            }
            cell.configure(symbol: nil, leading: leading, title: node.title, titleStyle: .sectionHeader)
        } else {
            let count = node.unreadCount(in: model.state)
            let trailing: MistSidebarCellView.Trailing
            if let box = node.mailbox, model.syncing.contains(box.id) { trailing = .spinner }
            else if count > 0 { trailing = .count(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)) }
            else { trailing = .none }
            cell.configure(symbol: MailPresentation.symbol(node.unifiedRole ?? node.mailbox?.role), title: node.title, trailing: trailing)
        }
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = MistRowView(style: .sidebar); row.showsHover = (item as! MailboxTreeNode).canSelect; return row
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === mailboxPane }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { dividerIndex == 0 && mailboxPane.isHidden }
}

private final class MailPageBackgroundView: AgentChatBackgroundView {
    weak var controller: MailPageViewController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let redo = MailPageViewController.historyShortcut(event), controller?.performMessageHistory(redo: redo) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// An account's status dot, with the existing sign-in repair action.
private final class MailAccountStatusView: NSView {
    private let onClick: () -> Void
    init(status: MailAccountStatus?, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        let text = MailPresentation.status(status)
        setCustomTooltip(text); setAccessibilityLabel(text)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        let dot = MistDotView(color: ThemedColor(MailPresentation.statusColor(status)))
        addSubview(dot); dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.centerXAnchor.constraint(equalTo: centerXAnchor), dot.centerYAnchor.constraint(equalTo: centerYAnchor)])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
    @objc private func clicked() { onClick() }
}
