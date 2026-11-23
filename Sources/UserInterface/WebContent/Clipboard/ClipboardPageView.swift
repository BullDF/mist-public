import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Clipboard page, drawn from the Mist apps' kit (#73): the page header over the box, a hero card holding the drop
/// zone and its actions, and under it the shared item or a line saying there's none.
struct ClipboardPageView: View {
    @ObservedObject var model: ClipboardPageModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Group {
                        if model.state == .box { box }
                        else { unavailable }
                    }
                    .frame(width: max(0, min(MistKit.readableWidth, geometry.size.width - 48)))
                    Spacer(minLength: 0)
                }
                .padding(.top, 40)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private var box: some View {
        VStack(spacing: 0) {
            MistPageHeader(glyph: .asset("clipboard-favicon"), title: MistAppID.clipboard.name,
                           subtitle: MistSyncStrings.clipboardSubtitle)
            MistCard(style: .hero) {
                VStack(spacing: 0) {
                    inputBox
                    HStack(spacing: 8) {
                        if model.draft != nil {
                            Button(MistSyncStrings.clipboardClearDraft, action: model.clearDraft).buttonStyle(.mistSecondary)
                        }
                        Spacer(minLength: 0)
                        Button(MistSyncStrings.clipboardSend, action: model.send).buttonStyle(.mistPrimary)
                            .disabled(model.draft == nil || model.staging)
                    }
                    .padding(EdgeInsets(top: 14, leading: 4, bottom: 2, trailing: 4))
                }
            }
            .padding(.top, 34)
            if let error = model.error {
                Text(error).mistText(.error).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 10)
            }
            Group {
                if let item = model.source.current { shared(item) }
                else { MistPlaceholder(message: MistSyncStrings.clipboardEmpty) }
            }
            .padding(.top, 26)
        }
    }

    private var unavailable: some View {
        let notSetUp = model.state == .notSetUp
        return MistUnavailableState(glyph: .symbol(notSetUp ? "arrow.triangle.2.circlepath" : "clipboard"),
                                    title: notSetUp ? MistSyncStrings.clipboardNotSetUpTitle : MistSyncStrings.clipboardOffTitle,
                                    message: notSetUp ? MistSyncStrings.clipboardNotSetUpMessage : MistSyncStrings.clipboardOffMessage,
                                    actionTitle: MistSyncStrings.clipboardOpenSettings) {
            AppController.shared?.showSettings(pane: .mistSync)
        }
    }

    /// The drop zone. Empty, it keeps its drop-target size; staged, it hugs the item.
    private var inputBox: some View {
        Group {
            if let text = model.draftText {
                // At least a staged file's row tall, so the box hugs a short line the same way.
                ClipboardDraftText(text: text, onView: { model.draftTextView = $0 }).frame(minHeight: Self.fileIconSide)
            } else if let draft = model.draft {
                let title = draft.name ?? MistSyncStrings.clipboardImage
                let size = ByteCountFormatter.string(fromByteCount: Int64(draft.data.count), countStyle: .file)
                if let image = model.draftImage {
                    MistItemRow(title: title, subtitle: size) { MistImagePreview(image: image) }
                } else {
                    MistItemRow(tile: MistIconTile(content: .icon(Self.fileIcon(draft.type, name: draft.name))),
                                title: title, subtitle: size)
                }
            } else {
                MistDropPrompt(text: String(format: MistSyncStrings.clipboardPlaceholder, MistClipboardSyncSource.sizeLimit))
                    .padding(EdgeInsets(top: 26, leading: 16, bottom: 22, trailing: 16))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mistDropZone(focused: model.focused, targeted: model.hovering)
        .overlay {
            MistClipboardInputOverlay(focused: $model.focused, hovering: $model.hovering, stage: model.stage,
                                      paste: model.paste, choose: model.chooseFile, scrollTarget: { model.draftTextView },
                                      onView: { model.inputView = $0 })
        }
    }

    /// The shared item's card, with the time it has left, and its actions under it.
    private func shared(_ item: MistClipboardItem) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            let card = MistCard {
                MistItemRow(tile: tile(item),
                            title: item.type == .text ? String((item.text ?? "").prefix(500)) : item.name ?? MistSyncStrings.clipboardImage,
                            titleStyle: item.type == .text ? .body : .headline, titleLines: item.type == .text ? 4 : 1,
                            subtitle: subtitle(item)) {
                    MistCountdownRing(deadline: item.expiry, duration: item.lifetime)
                }
            }
            // A file downloads with its button instead.
            if item.receiving || item.type == .file { card } else { card.onDrag { model.drag(item) } }
            HStack(spacing: 8) {
                if item.type == .file {
                    if let file = model.downloadedFile(for: item) {
                        Button(MistSyncStrings.clipboardShowInFinder) { model.showInFinder(file) }.buttonStyle(.mistSecondary)
                    } else {
                        Button(MistSyncStrings.clipboardDownload) { model.download(item) }
                            .buttonStyle(.mistSecondary)
                            .disabled(item.receiving)
                    }
                }
                Button(item.receiving ? MistSyncStrings.clipboardReceiving : MistSyncStrings.clipboardCopy) { model.copy(item) }
                    .buttonStyle(.mistSecondary)
                    .disabled(item.receiving)
                Button(MistSyncStrings.clipboardClear, action: model.clear).buttonStyle(.mistSecondary)
            }
        }
    }

    private func tile(_ item: MistClipboardItem) -> MistIconTile {
        if item.type == .text { return MistIconTile(content: .symbol("text.alignleft")) }
        if item.type == .image, let thumbnail = model.thumbnail { return MistIconTile(content: .thumbnail(thumbnail)) }
        return MistIconTile(content: .icon(Self.fileIcon(item.type, name: item.name)))
    }

    private func subtitle(_ item: MistClipboardItem) -> String {
        let from = String(format: MistSyncStrings.clipboardFrom, item.sender, item.sent.formatted(date: .omitted, time: .shortened))
        return item.type == .text ? from : from + " · " + ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
    }
    private static func fileIcon(_ type: MistClipboardType, name: String?) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: ((name ?? "") as NSString).pathExtension) ??
            (type == .image ? .image : .data))
    }
    /// A file row's height: its tile is taller than the name and size beside it.
    static let fileIconSide = MistIconTile.defaultSide
}

/// Staged text, as tall as its lines up to `maxHeight` and scrolling past it. The box's input overlay sits on top,
/// so clicks still open the chooser and it forwards scrolls here.
struct ClipboardDraftText: NSViewRepresentable {
    private static let style = MistTextStyle.body
    private static let font = style.nsFont
    /// Ten and a half lines: the cut line shows there's more to scroll.
    static let maxHeight = (NSLayoutManager().defaultLineHeight(for: font) * 10.5).rounded()
    /// Measuring stops here: any text this long fills the cap at the box's widths.
    private static let measuredLength = 4000
    let text: String
    var onView: (NSScrollView) -> Void

    final class Coordinator {
        var shown: String?
        var color: NSColor?
        var measured: (text: String, width: CGFloat, height: CGFloat)?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, like `height(of:width:)`, so the measured height is exactly the laid-out one.
        let textView = NSTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        // Embedded first: sized without a flipped superview, the text view kept its top edge by moving its origin up
        // a line, and every text then opened scrolled by that line.
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        onView(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let storage = (scrollView.documentView as? NSTextView)?.textStorage else { return }
        let color = Self.style.color.resolve(theme: context.environment.phiTheme,
                                             appearance: context.environment.phiAppearance)
        let coordinator = context.coordinator
        if coordinator.shown != text {
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color]))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if coordinator.color != color {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        }
        coordinator.shown = text
        coordinator.color = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let coordinator = context.coordinator
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? coordinator.measured?.width ?? 400
        if let measured = coordinator.measured, measured.width == width, measured.text == text {
            return CGSize(width: width, height: measured.height)
        }
        let height = Self.height(of: text, width: width)
        coordinator.measured = (text, width, height)
        return CGSize(width: width, height: height)
    }

    /// The text's height wrapped at `width`, capped at `maxHeight`.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        let sample = text.prefix(measuredLength)
        let storage = NSTextStorage(string: String(sample), attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        return sample.endIndex == text.endIndex ? min(height, maxHeight) : maxHeight
    }
}

private struct MistClipboardInputOverlay: NSViewRepresentable {
    @Binding var focused: Bool
    @Binding var hovering: Bool
    var stage: (NSPasteboard) -> Void
    var paste: () -> Void
    var choose: () -> Void
    var scrollTarget: () -> NSScrollView?
    var onView: (NSView) -> Void

    func makeNSView(context: Context) -> InputView { let view = InputView(); onView(view); return view }
    func updateNSView(_ view: InputView, context: Context) {
        view.stage = stage
        view.pasteAction = paste
        view.choose = choose
        view.scrollTarget = scrollTarget
        view.focusChanged = { if focused != $0 { focused = $0 } }
        view.hoverChanged = { if hovering != $0 { hovering = $0 } }
    }

    final class InputView: NSView, NSMenuItemValidation {
        var stage: ((NSPasteboard) -> Void)?
        var pasteAction: (() -> Void)?
        var choose: (() -> Void)?
        var scrollTarget: (() -> NSScrollView?)?
        var focusChanged: ((Bool) -> Void)?
        var hoverChanged: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes(MistClipboardPasteboard.draggedTypes)
        }
        required init?(coder: NSCoder) { super.init(coder: coder) }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { choose?() }
        }
        override func becomeFirstResponder() -> Bool { focusChanged?(true); return true }
        override func resignFirstResponder() -> Bool { focusChanged?(false); return true }
        /// Staged text that overflows scrolls under this view, which covers the box and so gets its scrolls.
        override func scrollWheel(with event: NSEvent) {
            guard let target = scrollTarget?(), target.window === window, let document = target.documentView,
                  document.frame.height > target.contentView.bounds.height,
                  target.bounds.contains(target.convert(event.locationInWindow, from: nil)) else {
                return super.scrollWheel(with: event)
            }
            target.scrollWheel(with: event)
        }
        @objc func paste(_ sender: Any?) { pasteAction?() }
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.action == #selector(paste(_:)) }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            hoverChanged?(true)
            return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func draggingExited(_ sender: NSDraggingInfo?) { hoverChanged?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { hoverChanged?(false) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            hoverChanged?(false)
            window?.makeFirstResponder(self)
            stage?(sender.draggingPasteboard)
            return true
        }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { hoverChanged?(false) }
    }
}
