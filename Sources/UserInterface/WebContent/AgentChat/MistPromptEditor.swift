import AppKit
import Combine

enum MistComposerIcon: Equatable {
    case asset(String)

    static func drifter(engine: DrifterEngine) -> Self {
        .asset(AgentChatIcon.resolve(engine: engine).rawValue)
    }

    var image: NSImage? {
        switch self {
        case let .asset(name):
            if let image = NSImage(named: name)?.copy() as? NSImage {
                image.isTemplate = AgentChatIcon(rawValue: name)?.isTemplate ?? false
                return image
            }
            return nil
        }
    }
}

/// Plain text input for chat; the host owns submission and attachments.
final class MistPromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    var acceptsAttachments: (() -> Bool)?
    /// Whether an attachment drag is over the text view, for the composer card's highlight.
    var onDropTargetChange: ((Bool) -> Void)?
    var onSlashKey: ((NSEvent) -> Bool)?
    var onSlashMove: ((Int) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var codeBlocksEnabled = true
    private(set) var isInsertingText = false
    private(set) var isApplyingCodeEdit = false
    var styledCodeBlocks: [AgentCodeBlocks.Block] = []
    private var isPastingText = false
    private var themeSubscription: AnyCancellable?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeSubscription = themeStateProvider.themeAppearancePublisher.sink { [weak self] _ in
            self?.needsDisplay = true
            self?.applyMistSelection()
        }
        applyMistSelection()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        applyMistSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        if codeBlocksEnabled, let manager = layoutManager, let container = textContainer {
            manager.ensureLayout(for: container)
            let color = themeStateProvider.currentTheme.color(for: .textSecondary, appearance: currentAppearance).withAlphaComponent(0.07)
            let inset = container.lineFragmentPadding
            for block in styledCodeBlocks {
                let top = AgentCodeBlockDrawing.fenceLineRect(block.opening, manager: manager).minY
                let bottom = AgentCodeBlockDrawing.fenceLineRect(block.closing, manager: manager).maxY
                let rect = NSRect(x: inset, y: textContainerOrigin.y + top, width: bounds.width - 2 * inset, height: bottom - top)
                if rect.intersects(dirtyRect) {
                    let header = block.language.isEmpty ? nil : themeStateProvider.currentTheme.color(for: .textSecondary, appearance: currentAppearance).withAlphaComponent(0.04)
                    AgentCodeBlockDrawing.fill(rect, color: color, header: header, headerHeight: 32)
                }
            }
        }
        super.draw(dirtyRect)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let replacesSelection = (replacementRange.location == NSNotFound ? selectedRange() : replacementRange).length > 0
        let mayConvert = !isPastingText && (!replacesSelection || hasMarkedText())
        isInsertingText = true
        defer { isInsertingText = false }
        super.insertText(insertString, replacementRange: replacementRange)
        let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if mayConvert, inserted == "`", codeBlocksEnabled, !hasMarkedText(), selectedRange().length == 0,
           let edit = AgentCodeBlocks.typedBacktick(in: string, caret: selectedRange().location) {
            applyCodeEdit(edit)
        }
    }

    private func applyCodeEdit(_ edit: AgentCodeBlocks.Edit) {
        isApplyingCodeEdit = true
        defer { isApplyingCodeEdit = false }
        if edit.range.length > 0 || !edit.replacement.isEmpty {
            breakUndoCoalescing()
            // Registered before the replacement so it runs after it on undo: NSTextView's undo
            // selects the restored text, and the caret should return to where the edit started.
            let caret = selectedRange()
            undoManager?.registerUndo(withTarget: self) { $0.setSelectedRange(caret) }
            // insertText records a single replacement in NSTextView's undo manager.
            super.insertText(edit.replacement, replacementRange: edit.range)
            breakUndoCoalescing()
        }
        setSelectedRange(NSRange(location: edit.caret, length: 0))
        scrollCaretToVisible()
    }

    /// After an arrow key, scrollRangeToVisible animates. An animation that starts before the input grows to fit
    /// the edit ends past the text once it has, hiding the first lines, so this scroll is immediate.
    private func scrollCaretToVisible() {
        guard let clip = enclosingScrollView?.contentView, let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(for: container)
        let length = (string as NSString).length
        var line = manager.extraLineFragmentRect
        if selectedRange().location < length || line.height == 0, length > 0 {
            line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: min(selectedRange().location, length - 1)), effectiveRange: nil)
        }
        let rect = line.offsetBy(dx: 0, dy: textContainerOrigin.y)
        var origin = clip.bounds.origin
        if rect.maxY > clip.bounds.maxY { origin.y = rect.maxY - clip.bounds.height }
        else if rect.minY < clip.bounds.minY { origin.y = rect.minY }
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func handleCodeCommand(_ selector: Selector) -> Bool {
        guard codeBlocksEnabled, !hasMarkedText(), selectedRange().length == 0 else { return false }
        let caret = selectedRange().location
        let name = NSStringFromSelector(selector)
        let backwards = ["deleteBackward:", "deleteWordBackward:", "deleteToBeginningOfLine:",
                         "deleteToBeginningOfParagraph:", "deleteBackwardByDecomposingPreviousCharacter:"]
        let forwards = ["deleteForward:", "deleteWordForward:", "deleteToEndOfLine:", "deleteToEndOfParagraph:"]
        if backwards.contains(name), let edit = AgentCodeBlocks.backwardDelete(in: string, caret: caret) {
            applyCodeEdit(edit)
            return true
        }
        if forwards.contains(name), let edit = AgentCodeBlocks.forwardDelete(in: string, caret: caret) {
            applyCodeEdit(edit)
            return true
        }
        guard name == "moveUp:" || name == "moveDown:",
              let block = AgentCodeBlocks.containing(selectedRange(), in: string),
              let manager = layoutManager, let container = textContainer else { return false }
        manager.ensureLayout(for: container)
        let down = name == "moveDown:"
        let edge = down ? block.contentEnd : block.content.location
        let currentLine = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: caret), effectiveRange: nil)
        let edgeLine = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: edge), effectiveRange: nil)
        guard currentLine.minY == edgeLine.minY else { return false }
        applyCodeEdit(AgentCodeBlocks.exit(block, down: down, in: string))
        return true
    }

    // Arrows and Ctrl+P/N both arrive as moveUp:/moveDown:, the route the search box's list uses too.
    override func doCommand(by selector: Selector) {
        if selector == #selector(moveUp(_:)), onSlashMove?(-1) == true { return }
        if selector == #selector(moveDown(_:)), onSlashMove?(1) == true { return }
        if handleCodeCommand(selector) { return }
        super.doCommand(by: selector)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        if onSlashKey?(event) == true { return }
        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                if codeBlocksEnabled, selectedRange().length == 0,
                   let edit = AgentCodeBlocks.openFence(in: string, caret: selectedRange().location) {
                    applyCodeEdit(edit)
                } else {
                    insertText("\n", replacementRange: selectedRange())
                }
            } else {
                onSubmit?()
            }
        case 48, 53:
            break
        default:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), acceptsAttachments?() == true,
           NSPasteboard.general.availableType(from: ClaudeCodeImageNormalizer.pasteboardTypes) != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    func paste(from pasteboard: NSPasteboard) {
        isPastingText = true
        defer { isPastingText = false }
        let attached = onPasteAttachments?(pasteboard) == true
        if attached, pasteboard.pasteboardItems?.contains(where: { $0.types.contains(.fileURL) }) == true { return }
        if let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = acceptsAttachments?() == true
        onDropTargetChange?(accepts && sender.draggingPasteboard.availableType(from: ClaudeCodeImageNormalizer.pasteboardTypes) != nil)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDropTargetChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDropTargetChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargetChange?(false)
        return onPasteAttachments?(sender.draggingPasteboard) ?? false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsAttachments?() == true
    }
}

final class MistPromptEditor: NSView, NSTextViewDelegate {
    let textView = MistPromptTextView()
    let commandPopup = MistSlashCommandPopup()
    let mentionPopup = MistTabMentionPopup()
    let mentionBanner = MistTabMentionBanner()
    var mentionTabs: () -> [Tab] = { [] } { didSet { updateMentionBanner() } }
    var mentionGroups: () -> [MistMentionGroup] = { [] } { didSet { updateMentionBanner() } }
    var currentTab: () -> Tab? = { nil }
    private var tabCloseObserver: NSObjectProtocol?
    private var mentionedTabIds: Set<Int> = []
    private var mentionedGroupInfos: Set<ObjectIdentifier> = []
    private var mentionedTabsSubscription: AnyCancellable?
    var mentionsEnabled = false { didSet { restyleCommands(); updateSlashCommands() } }
    var popupHeight: CGFloat { commandPopup.listHeight + mentionPopup.listHeight }
    var mentionBannerHeight: CGFloat { mentionBanner.isHidden ? 0 : mentionBanner.listHeight + 8 }
    var mentions: [AgentTabMention] {
        guard mentionsEnabled, let storage = textView.textStorage else { return [] }
        var result: [AgentTabMention] = []
        storage.enumerateAttribute(AgentChatMentionStyle.token, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard var mention = value as? AgentTabMention,
                  storage.attributedSubstring(from: range).string == mention.tokenText else { return }
            mention.range = range
            result.append(mention)
        }
        return result
    }
    /// The draft with every token refreshed to its tab's current title and URL.
    func promptForSend() -> AgentMentionText {
        refreshMentions()
        return AgentMentionText(text: text, mentions: mentions).refreshed(from: mentionTabs().map { AgentTabMention(tab: $0) }, groups: mentionGroups().map { AgentTabMention(group: $0) })
    }
    var slashCommands: [ClaudeCodeSlashCommand] = [] { didSet { restyleCommands(); updateSlashCommands() } }
    var slashCommandsEnabled = false { didSet { restyleCommands(); updateSlashCommands() } }
    /// Called when a `/` query starts, so the owner can rescan skills before the popup's matches settle.
    var onSlashQuery: (() -> Void)?
    private var slashQueryOpen = false
    /// The command being typed: from its slash to the caret its last edit left. It stays editable letter by letter
    /// while the caret stays there; every other highlighted command edits as one unit, like a mention.
    private var typedCommand: NSRange?
    /// The replacement of the edit in progress, from `shouldChangeTextIn` to `textDidChange`.
    private var pendingReplacement: String?
    private var modeIcon: MistComposerIcon?
    private let inputFont = AgentChatTypography.font(ofSize: 16)
    /// The 2 pt caret is centered on its insertion point, so at a line's start the clip view would cut off its
    /// left half. The text keeps this padding inside a scroll view widened by as much on each side.
    private let caretInset: CGFloat = 2
    private let editorUndoManager = UndoManager()
    private var dismissedText: String?
    private let scrollView = NSScrollView()
    private let placeholderLabel = MistPromptPlaceholder(labelWithString: "")
    let icon = NSImageView()
    var onChange: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private(set) var inputHeight: CGFloat = 64
    var hasAttachments = false { didSet { if oldValue != hasAttachments { updateHeight(); needsLayout = true } } }

    var text: String {
        get { textView.string }
        set {
            typedCommand = nil
            textView.string = newValue
            textView.textStorage?.removeAttribute(AgentChatMentionStyle.token, range: NSRange(location: 0, length: (newValue as NSString).length))
            restyleCommands()
            textView.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            updateHeight()
            updateSlashCommands()
            onChange?()
        }
    }

    func setText(_ text: String, mentions: [AgentTabMention]) {
        self.text = text
        if let storage = textView.textStorage {
            AgentChatMentionStyle.apply(mentions, to: storage, pointSize: inputFont.pointSize)
        }
        restyleCommands()
        updateMentionBanner()
        updateHeight()
        onChange?()
    }

    func applyDraft(_ text: String, mentions: [AgentTabMention]) {
        guard self.text != text || self.mentions != mentions else { return }
        typedCommand = nil
        textView.unmarkText()
        let selections = textView.selectedRanges.map { NSValue(range: AgentComposerDraft.mapSelection($0.rangeValue, from: self.text, to: text)) }
        textView.textStorage?.setAttributedString(NSAttributedString(string: text))
        if let storage = textView.textStorage {
            AgentChatMentionStyle.apply(mentions, to: storage, pointSize: inputFont.pointSize)
        }
        editorUndoManager.removeAllActions()
        textView.selectedRanges = selections
        restyleCommands()
        updateHeight()
        updateSlashCommands()
        updateMentionBanner()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

    init() {
        super.init(frame: .zero)
        textView.replaceTextContainer(AgentChatTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)))
        // Attribute runs are internal. Paste still inserts only plain text through MistPromptTextView.
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = inputFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        // Plain lines keep their original 16 pt-font height even when a slash token uses a smaller font.
        let plainLineHeight = ceil(textView.layoutManager?.defaultLineHeight(for: inputFont) ?? 18)
        paragraph.minimumLineHeight = plainLineHeight
        paragraph.maximumLineHeight = plainLineHeight
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: inputFont, .paragraphStyle: paragraph]
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = caretInset
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        mentionBanner.onRemove = { [weak self] in self?.removeMentions(key: $0) }
        tabCloseObserver = NotificationCenter.default.addObserver(forName: .browserTabDidClose, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.updateMentionBanner() }
        }
        textView.layoutManager?.delegate = AgentChatSlashLayoutDelegate.shared
        textView.onSlashKey = { [weak self] in self?.handleSlashKey($0) ?? false }
        textView.onSlashMove = { [weak self] delta in
            guard let self else { return false }
            if !self.mentionPopup.matches.isEmpty { self.mentionPopup.move(delta); return true }
            guard !self.commandPopup.matches.isEmpty else { return false }
            self.commandPopup.move(delta)
            return true
        }
        textView.onFocusChange = { [weak self] focused in
            self?.onFocusChange?(focused)
            // The first responder is assigned after become/resignFirstResponder returns.
            if focused { DispatchQueue.main.async { [weak self] in self?.updateSlashCommands() } }
            else { self?.commandPopup.update([]); self?.mentionPopup.update([]) }
        }
        commandPopup.onComplete = { [weak self] in self?.complete($0, submit: false) }
        commandPopup.onHeightChange = { [weak self] in self?.onHeightChange?() }
        mentionPopup.onComplete = { [weak self] in self?.completeMention($0) }
        mentionPopup.onHeightChange = { [weak self] in self?.onHeightChange?() }
        textView.registerForDraggedTypes(ClaudeCodeImageNormalizer.pasteboardTypes)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)
        placeholderLabel.font = inputFont
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.isSelectable = false
        addSubview(placeholderLabel)
        icon.phi.setContentTintColor(.textSecondary)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let tabCloseObserver { NotificationCenter.default.removeObserver(tabCloseObserver) } }

    func updateMentionBanner() {
        let oldHeight = mentionBannerHeight
        let tabs = mentionTabs()
        let groups = mentionGroups()
        mentionBanner.update(mentions, tabs: tabs, groups: groups)
        observeMentionedTabs(in: tabs, groups: groups)
        if oldHeight != mentionBannerHeight { onHeightChange?() }
    }

    /// Tokens follow their tab while the draft sits unsent.
    private func observeMentionedTabs(in tabs: [Tab], groups: [MistMentionGroup]) {
        let ids = Set(mentions.filter { !$0.isGroup }.map(\.tabId))
        let tabs = tabs.filter { ids.contains($0.guid) }
        let tokens = Set(mentions.compactMap { $0.group?.token })
        let groups = groups.filter { tokens.contains($0.info.token) }
        let infos = Set(groups.map { ObjectIdentifier($0.info) })
        guard Set(tabs.map(\.guid)) != mentionedTabIds || infos != mentionedGroupInfos else { return }
        mentionedTabIds = Set(tabs.map(\.guid))
        mentionedGroupInfos = infos
        // @Published emits before the new value is stored.
        let publishers = tabs.flatMap { [$0.$title.map { _ in }.eraseToAnyPublisher(), $0.$url.map { _ in }.eraseToAnyPublisher()] }
            + groups.map { $0.info.objectWillChange.map { _ in }.eraseToAnyPublisher() }
        mentionedTabsSubscription = Publishers.MergeMany(publishers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshMentions(); self?.updateMentionBanner() }
    }

    /// An undoable edit, so the undo stack's ranges stay valid when a token's length changes.
    private func refreshMentions() {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let tokens = mentions
        let fresh = AgentMentionText(text: text, mentions: tokens).refreshed(from: mentionTabs().map { AgentTabMention(tab: $0) }, groups: mentionGroups().map { AgentTabMention(group: $0) }).mentions
        guard fresh.count == tokens.count else { return }
        var selections = textView.selectedRanges.map(\.rangeValue)
        var changed = false
        for (token, mention) in zip(tokens, fresh).reversed() where !mention.closed && (token.title != mention.title || token.url != mention.url || token.group != mention.group) {
            guard textView.shouldChangeText(in: token.range, replacementString: mention.tokenText) else { continue }
            if !changed { textView.breakUndoCoalescing() }
            changed = true
            var styled = mention
            styled.range = NSRange(location: 0, length: (mention.tokenText as NSString).length)
            let value = NSMutableAttributedString(string: mention.tokenText, attributes: textView.typingAttributes)
            AgentChatMentionStyle.apply([styled], to: value, pointSize: inputFont.pointSize)
            storage.replaceCharacters(in: token.range, with: value)
            textView.didChangeText()
            let delta = styled.range.length - token.range.length
            selections = selections.map {
                var range = $0
                if range.location >= NSMaxRange(token.range) { range.location += delta }
                else if range.location <= token.range.location, NSMaxRange(range) >= NSMaxRange(token.range) { range.length += delta }
                return range
            }
        }
        if changed { textView.selectedRanges = selections.map { NSValue(range: $0) } }
    }

    func removeMentions(key: String) {
        let source = text as NSString
        // A token's auto-inserted space goes with it.
        let ranges = mentions.filter { $0.key == key }.map { mention -> NSRange in
            var range = mention.range
            if NSMaxRange(range) < source.length, source.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == " " { range.length += 1 }
            return range
        }.reversed()
        textView.undoManager?.beginUndoGrouping()
        for range in ranges { textView.insertText("", replacementRange: range) }
        textView.undoManager?.endUndoGrouping()
        updateMentionBanner()
        onChange?()
    }

    func setPlaceholder(_ text: String, icon descriptor: MistComposerIcon?) {
        placeholderLabel.stringValue = text
        textView.setAccessibilityLabel(text)
        modeIcon = descriptor
        updateIcon()
    }

    private func updateIcon() {
        icon.image = modeIcon?.image
        if icon.image?.isTemplate == true {
            icon.phi.setContentTintColor(.textSecondary)
        } else {
            icon.phi[\.contentTintColor] = nil
            icon.contentTintColor = nil
        }
    }

    override func layout() {
        super.layout()
        let lineHeight = ceil(textView.layoutManager?.defaultLineHeight(for: inputFont) ?? 20)
        let topPadding = (64 - lineHeight) / 2
        scrollView.frame = NSRect(x: 46 - caretInset, y: topPadding, width: max(1, bounds.width - 58 + 2 * caretInset),
                                  height: max(lineHeight, bounds.height - topPadding - (hasAttachments ? 8 : topPadding)))
        // The overlay scroll bar draws at the scroll view's right edge, so the text stops short of it.
        let textWidth = max(1, scrollView.contentSize.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        textView.setFrameSize(NSSize(width: textWidth, height: max(textView.frame.height, scrollView.contentSize.height)))
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        // A code edit scrolls its caret into view before the input grows to fit, and the clip view keeps that
        // offset once the text fits, hiding the first lines.
        let clip = scrollView.contentView
        let origin = clip.constrainBoundsRect(clip.bounds).origin
        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
        // A label cell draws its text 2 pt in from its frame, so the placeholder starts where typed text and the caret do.
        placeholderLabel.frame = NSRect(x: 44, y: bounds.height - (hasAttachments ? 8 : topPadding) - lineHeight,
                                        width: max(0, bounds.width - 56), height: lineHeight)
        icon.frame = NSRect(x: 22, y: bounds.height - 40 + (hasAttachments ? topPadding - 8 : 0), width: 16, height: 16)
        updateHeight()
    }

    func textDidChange(_ notification: Notification) {
        noteTypedCommand()
        restyleCommands()
        updateHeight()
        dismissedText = nil
        updateSlashCommands()
        onChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let selection = textView.selectedRange()
        let blocks = AgentCodeBlocks.blocks(in: text, editingAt: selection.length == 0 ? selection.location : nil)
        if blocks != textView.styledCodeBlocks { restyleCommands() }
        // An empty last line takes the typing attributes' height only while the caret is on it, and a code
        // edit moves the caret there after textDidChange measured it at the closing fence's height.
        updateHeight()
        updateSlashCommands()
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                  toCharacterRange newRange: NSRange) -> NSRange {
        let newRange = self.textView.isInsertingText || self.textView.isApplyingCodeEdit ? newRange : AgentCodeBlocks.clamp(newRange, from: oldRange, in: text)
        let atoms = atomicRanges
        if newRange.length > 0 { return AgentMentionText.atomicRange(newRange, atoms: atoms) }
        guard let token = atoms.first(where: { newRange.location > $0.location && newRange.location < NSMaxRange($0) }) else { return newRange }
        return NSRange(location: newRange.location < oldRange.location ? token.location : NSMaxRange(token), length: 0)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let model = AgentMentionText(text: text, mentions: mentions)
        if model.swallowsSpace(at: affectedCharRange, replacement: replacementString) { return false }
        let range = AgentMentionText.atomicRange(affectedCharRange, atoms: atomicRanges)
        guard range != affectedCharRange else {
            pendingReplacement = replacementString
            return true
        }
        // Only a deletion takes the whole token. AppKit's substitutions (smart quotes and dashes, text replacement)
        // rewrite characters inside one, which would otherwise replace the token with the substitute.
        if replacementString == "" { textView.insertText("", replacementRange: range) }
        return false
    }

    // The old attributes' key type must be String, or Swift doesn't take this as the delegate method.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldAttributes: [String: Any],
                  toAttributes newAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        // Caret movement must not carry a highlighted command's font/color into new typing.
        caretTypingAttributes
    }

    private var caretTypingAttributes: [NSAttributedString.Key: Any] {
        if AgentCodeBlocks.containing(textView.selectedRange(), in: text) != nil { return codeAttributes }
        return [.font: inputFont, .foregroundColor: NSColor.labelColor,
                .paragraphStyle: textView.defaultParagraphStyle ?? NSParagraphStyle.default]
    }

    private var codeAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.tailIndent = -12
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 4
        return [.font: AgentChatTypography.codeFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private var caretInCode: Bool { AgentCodeBlocks.containing(textView.selectedRange(), in: text) != nil }

    /// Known commands outside code blocks, the ones the composer highlights.
    private func highlightedCommands(blocks: [AgentCodeBlocks.Block]) -> [ClaudeCodeSlashTokenizer.Token] {
        guard slashCommandsEnabled else { return [] }
        let names = Set(slashCommands.map(\.name))
        return ClaudeCodeSlashTokenizer.tokens(in: text).filter { token in
            names.contains(token.name) && !blocks.contains { NSIntersectionRange($0.range, token.commandRange).length > 0 }
        }
    }

    /// Ranges that edit as one unit: mentions, then every highlighted command but the one being typed.
    private var atomicRanges: [NSRange] {
        let caret = textView.selectedRange()
        let typing = typedCommand.flatMap { caret == NSRange(location: NSMaxRange($0), length: 0) ? $0.location : nil }
        return mentions.map(\.range) + highlightedCommands(blocks: textView.styledCodeBlocks)
            .filter { $0.range.location != typing }.map(\.commandRange)
    }

    private func noteTypedCommand() {
        defer { pendingReplacement = nil }
        let caret = textView.selectedRange()
        guard let replacement = pendingReplacement, caret.length == 0,
              let token = ClaudeCodeSlashTokenizer.tokens(in: text).first(where: { NSMaxRange($0.range) == caret.location }) else {
            typedCommand = nil
            return
        }
        // Typing extends the command; a deletion leaves it being typed only if it already was, so deleting
        // the space after a completed command leaves that command whole.
        let typing = replacement.isEmpty ? typedCommand?.location == token.range.location : !replacement.contains(where: \.isWhitespace)
        typedCommand = typing ? NSRange(location: token.range.location, length: caret.location - token.range.location) : nil
    }

    func updateSlashCommands() {
        updateMentionBanner()
        updateMentions()
        guard !caretInCode, slashCommandsEnabled, textView.isEditable, window?.firstResponder === textView,
              !textView.hasMarkedText(), text != dismissedText,
              let query = ClaudeCodeSlashQuery.at(textView.selectedRange(), in: text) else {
            slashQueryOpen = false
            commandPopup.update([])
            return
        }
        if !slashQueryOpen {
            slashQueryOpen = true
            onSlashQuery?()
        }
        commandPopup.update(ClaudeCodeSlashMatcher.matches(slashCommands, query: query))
    }

    private func handleSlashKey(_ event: NSEvent) -> Bool {
        if !mentionPopup.matches.isEmpty {
            switch event.keyCode {
            case 48: if let mention = mentionPopup.selectedMention { completeMention(mention) }
            case 36, 76:
                guard !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) else { return false }
                if let mention = mentionPopup.selectedMention { completeMention(mention) }
            case 53: dismissedText = text; mentionPopup.update([])
            default: return false
            }
            return true
        }
        guard !commandPopup.matches.isEmpty else { return false }
        switch event.keyCode {
        case 48:
            if let command = commandPopup.selectedCommand { complete(command, submit: false) }
        case 36, 76:
            guard !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) else { return false }
            if let command = commandPopup.selectedCommand { complete(command, submit: command.argumentHint.isEmpty) }
        case 53:
            dismissedText = text
            commandPopup.update([])
        default: return false
        }
        return true
    }

    private func complete(_ command: ClaudeCodeSlashCommand, submit: Bool) {
        guard let query = ClaudeCodeSlashQuery.at(textView.selectedRange(), in: text) else { return }
        textView.insertText("/" + command.name + " ", replacementRange: query.completionRange(in: text))
        commandPopup.update([])
        if submit { textView.onSubmit?() }
    }

    private func restyleCommands() {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        textView.codeBlocksEnabled = true
        let selection = textView.selectedRange()
        let blocks = AgentCodeBlocks.blocks(in: text, editingAt: selection.length == 0 ? selection.location : nil)
        textView.styledCodeBlocks = blocks
        let selections = textView.selectedRanges
        let undo = textView.undoManager
        let registeringUndo = undo?.isUndoRegistrationEnabled == true
        if registeringUndo { undo?.disableUndoRegistration() }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        let retainedMentions = mentions
        storage.removeAttribute(AgentChatMentionStyle.token, range: full)
        storage.removeAttribute(AgentChatSlashStyle.token, range: full)
        storage.removeAttribute(.baselineOffset, range: full)
        storage.removeAttribute(.agentHiddenFence, range: full)
        storage.addAttributes([.font: inputFont, .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: textView.defaultParagraphStyle ?? NSParagraphStyle.default], range: full)
        for command in highlightedCommands(blocks: blocks) {
            storage.addAttributes(AgentChatSlashStyle.attributes(pointSize: inputFont.pointSize), range: command.commandRange)
        }
        AgentChatMentionStyle.apply(retainedMentions.filter { mention in
            !blocks.contains { NSIntersectionRange($0.range, mention.range).length > 0 }
        }, to: storage, pointSize: inputFont.pointSize)
        for block in blocks {
            storage.addAttributes(codeAttributes, range: block.content)
            if !block.language.isEmpty, block.content.length > 0 {
                let paragraph = (codeAttributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                paragraph.paragraphSpacingBefore = 6
                let firstLine = (text as NSString).lineRange(for: NSRange(location: block.content.location, length: 0))
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSIntersectionRange(firstLine, block.content))
            }
            for fence in [block.opening, block.closing] {
                let paragraph = NSMutableParagraphStyle()
                let header = fence == block.opening && block.languageRange != nil
                paragraph.minimumLineHeight = header ? 32 : 10
                paragraph.maximumLineHeight = header ? 32 : 10
                if header { paragraph.firstLineHeadIndent = 12; paragraph.headIndent = 12 }
                // Space between the box and the plain lines around it; the box is drawn inside it.
                if fence == block.opening, fence.location > 0 { paragraph.paragraphSpacingBefore = 6 }
                if fence == block.closing, NSMaxRange(fence) < storage.length { paragraph.paragraphSpacing = 6 }
                let line = NSRange(location: fence.location, length: fence.length + (NSMaxRange(fence) < storage.length ? 1 : 0))
                storage.addAttributes([.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 1)], range: line)
                // The first character stays a real, clear glyph: a line that starts with null glyphs joins the
                // previous line fragment and loses its paragraph spacing, and a final one gets no fragment at all.
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: fence.location, length: min(1, fence.length)))
                if fence.length > 1 {
                    storage.addAttribute(.agentHiddenFence, value: true, range: NSRange(location: fence.location + 1, length: fence.length - 1))
                }
                if header, let language = block.languageRange {
                    storage.removeAttribute(.agentHiddenFence, range: language)
                    let labelFont = NSFont.systemFont(ofSize: 12)
                    // TextKit puts a fixed line height's extra space above the glyphs; split it evenly instead.
                    storage.addAttributes([.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor,
                                           .baselineOffset: (32 - (labelFont.ascender - labelFont.descender)) / 2], range: language)
                }
            }
        }
        storage.endEditing()
        textView.selectedRanges = selections
        // Replacing the whole text keeps the old first character's attributes for typing, which after
        // a sent block are a hidden fence's and draw a 1 pt or indented caret.
        textView.typingAttributes = caretTypingAttributes
        textView.needsDisplay = true
        if registeringUndo { undo?.enableUndoRegistration() }
    }

    private func updateMentions() {
        guard !caretInCode, mentionsEnabled, textView.isEditable, window?.firstResponder === textView,
              !textView.hasMarkedText(), text != dismissedText,
              let range = AgentMentionText.query(in: text, selection: textView.selectedRange(), mentions: mentions) else {
            mentionPopup.update([])
            return
        }
        let tabs = mentionTabs().filter { MistApps.address($0.url) == nil }
        let candidates = tabs.map { AgentTabMention(tab: $0, position: $0.index + 1) }
        let query = (text as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1))
        let groups = mentionGroups().map { AgentTabMention(group: $0) }
        let rows = AgentMentionText.popupRows(candidates, groups: groups, query: query, currentTabId: currentTab()?.guid, mentioned: Set(mentions.map(\.key)))
        mentionPopup.update(rows.groups + rows.others, current: rows.current, icon: { mention in
            if let group = mention.group, let color = GroupColor(rawValue: group.color) {
                return NSImage.tabGroupColorSwatch(for: color, cornerRadius: 6)
            }
            guard !mention.isGroup, let tab = tabs.first(where: { $0.guid == mention.tabId }), let data = tab.liveFaviconData ?? tab.cachedFaviconData else { return nil }
            return NSImage(data: data)
        })
    }

    private func completeMention(_ mention: AgentTabMention) {
        guard let range = AgentMentionText.query(in: text, selection: textView.selectedRange(), mentions: mentions) else { return }
        insertMention(mention, replacing: range)
    }

    /// Uses the same atomic, styled token as an explicit @ completion.
    func insertMentionIfEmpty(for tab: Tab) {
        guard mentionsEnabled, text.isEmpty else { return }
        insertMention(AgentTabMention(tab: tab), replacing: NSRange(location: 0, length: 0))
    }

    private func insertMention(_ mention: AgentTabMention, replacing range: NSRange) {
        var model = AgentMentionText(text: text, mentions: mentions)
        model.replace(range, with: mention.tokenText + " ", mention: mention)
        let replacement = (model.text as NSString).substring(with: NSRange(location: range.location, length: (mention.tokenText as NSString).length + 1))
        let value = NSMutableAttributedString(string: replacement, attributes: textView.typingAttributes)
        guard var inserted = model.mentions.first(where: { $0.range.location == range.location }) else { return }
        inserted.range = NSRange(location: 0, length: (mention.tokenText as NSString).length)
        AgentChatMentionStyle.apply([inserted], to: value, pointSize: inputFont.pointSize)
        textView.insertText(value, replacementRange: range)
        // After plain text was cleared, insertText applies the plain typing attributes instead of value's.
        if let storage = textView.textStorage {
            inserted.range.location = range.location
            AgentChatMentionStyle.apply([inserted], to: storage, pointSize: inputFont.pointSize)
        }
        // Reset insertion attributes so the trailing space never extends a mention.
        textView.typingAttributes = [.font: inputFont, .foregroundColor: NSColor.labelColor,
                                     .paragraphStyle: textView.defaultParagraphStyle ?? NSParagraphStyle.default]
        mentionPopup.update([])
        updateMentionBanner()
        onChange?()
    }

    private func updateHeight() {
        placeholderLabel.isHidden = !text.isEmpty
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let lineHeight = ceil(layout.defaultLineHeight(for: inputFont))
        var measuredHeight: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            measuredHeight = max(measuredHeight, rect.maxY)
        }
        if layout.extraLineFragmentRect.height > 0 {
            measuredHeight = layout.extraLineFragmentRect.maxY
        }
        // TextKit includes spacing only between fragments, including a trailing empty line.
        let contentHeight = max(lineHeight, measuredHeight)
        let capped = min(contentHeight, lineHeight + 7 * (lineHeight + 4))
        let height = 64 - (hasAttachments ? (64 - lineHeight) / 2 - 8 : 0) + capped - lineHeight
        if inputHeight != height {
            inputHeight = height
            onHeightChange?()
        }
    }
}

private final class MistPromptPlaceholder: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension AgentTabMention {
    init(group: MistMentionGroup) {
        self.init(tabId: 0, title: group.info.displayTitle, url: "", group: .init(token: group.info.token, color: group.info.color.rawValue, tabs: group.tabs.map { AgentTabMention(tab: $0) }))
    }

    init(tab: Tab, position: Int? = nil) {
        self.init(tabId: tab.guid, title: tab.title.isEmpty ? (tab.url ?? "") : tab.title, url: tab.url ?? "", position: position)
    }
}

struct MistMentionGroup {
    let info: WebContentGroupInfo
    let tabs: [Tab]
}

extension BrowserState {
    var agentMentionGroups: [MistMentionGroup] {
        var seen = Set<String>()
        return normalTabs.compactMap { tab in
            guard let token = tab.groupToken, seen.insert(token).inserted,
                  let info = groups[token], !BrowserAgentFolderState.isAgentFolderTitle(info.title) else { return nil }
            let members = normalTabs.filter { $0.groupToken == token && MistApps.address($0.url) == nil }
            return members.isEmpty ? nil : MistMentionGroup(info: info, tabs: members)
        }
    }
}
