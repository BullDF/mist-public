import AppKit
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class AgentChatViewControllerTests: XCTestCase {
    func testSingleMarkerPopoverSizeAndClosesOnlyWhenItsMarkerLeaves() throws {
        let chat = AgentConversation()
        chat.update(items: [.init(id: "first", kind: .userMessage(text: "First", images: [])),
                            .init(id: "second", kind: .assistantText(text: "Second", isStreaming: false))], status: .dormant)
        chat.toggleMarker(itemId: "first", defaultName: "First")
        chat.toggleMarker(itemId: "second", defaultName: "Second")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 30, y: 100, width: 24, height: 22))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        var closes = 0
        let popover = AgentChatMarkerListPopover.show(conversation: chat, anchor: anchor, only: "first", onClose: { closes += 1 })
        defer { popover.close() }
        XCTAssertTrue(popover.isShown)
        let controller = try XCTUnwrap(popover.contentViewController)
        XCTAssertEqual(controller.view.frame.size, NSSize(width: 280, height: 44))
        XCTAssertEqual(controller.preferredContentSize, NSSize(width: 280, height: 44))
        chat.removeMarker(itemId: "second")
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(closes, 0)
        chat.renameMarker(itemId: "first", to: "Renamed")
        XCTAssertTrue(popover.isShown)
        chat.removeMarker(itemId: "first")
        waitUntilClosed(popover)
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(closes, 1)
    }

    /// `NSPopover.close()` animates: `isShown` and the delegate's close follow a few frames later.
    private func waitUntilClosed(_ popover: NSPopover) {
        let deadline = Date().addingTimeInterval(2)
        while popover.isShown, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testMarkedRowButtonShowsPopoverWithoutAddingAndClosesItOnSecondClick() throws {
        let button = AgentChatMarkerButton()
        button.update(name: "My marker", visible: true, tint: .labelColor)
        XCTAssertEqual(button.accessibilityLabel(), "My marker")
        var adds = 0
        var shows = 0
        button.add = { adds += 1; return nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        button.frame = NSRect(x: 30, y: 100, width: 24, height: 22)
        try XCTUnwrap(window.contentView).addSubview(button)
        window.makeKeyAndOrderFront(nil)
        let chat = AgentConversation()
        chat.update(items: [.init(id: "first", kind: .userMessage(text: "First", images: []))], status: .dormant)
        chat.toggleMarker(itemId: "first", defaultName: "My marker")
        var shown: NSPopover?
        button.showMarker = { [weak button] anchor in
            shows += 1
            let popover = AgentChatMarkerListPopover.show(conversation: chat, anchor: anchor, only: "first",
                onClose: { button?.markerPopoverDidClose() })
            button?.trackMarkerPopover(popover)
            shown = popover
        }
        defer { shown?.close() }
        button.performClick(nil)
        XCTAssertEqual(shows, 1)
        XCTAssertEqual(adds, 0)
        XCTAssertEqual(chat.markers.count, 1)
        XCTAssertTrue(try XCTUnwrap(shown).isShown)
        button.performClick(nil)
        waitUntilClosed(try XCTUnwrap(shown))
        XCTAssertEqual(shows, 1)
        XCTAssertEqual(adds, 0)
        XCTAssertFalse(try XCTUnwrap(shown).isShown)
    }

    func testMarkerPopoversCloseWhenTheMarkerScrollsOutOfSight() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        let chat = AgentConversation()
        chat.update(items: [.init(id: "first", kind: .userMessage(text: "First", images: []))], status: .dormant)
        for marked in [true, false] {
            scroll.contentView.scroll(to: .zero)
            let button = AgentChatMarkerButton()
            button.frame = NSRect(x: 30, y: 100, width: 24, height: 22)
            try XCTUnwrap(scroll.documentView).addSubview(button)
            defer { button.removeFromSuperview() }
            if marked {
                // A marked row's click shows the marker's rename and remove popover.
                chat.toggleMarker(itemId: "first", defaultName: "Marked")
                button.update(name: "Marked", visible: true, tint: .labelColor)
                button.showMarker = { [weak button] anchor in
                    let popover = AgentChatMarkerListPopover.show(conversation: chat, anchor: anchor, only: "first",
                        onClose: { button?.markerPopoverDidClose() })
                    button?.trackMarkerPopover(popover)
                }
            } else {
                // An unmarked row's click adds a marker and opens its name field.
                button.update(name: nil, visible: true, tint: .labelColor)
                button.add = { AgentChatMarker(id: "first", name: "New") }
            }
            button.performClick(nil)
            let popover = try XCTUnwrap(button.popover)
            defer { popover.close() }
            XCTAssertTrue(popover.isShown, "marked: \(marked)")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 110))
            XCTAssertTrue(popover.isShown, "A marker still partly in sight keeps its popover; marked: \(marked)")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
            waitUntilClosed(popover)
            XCTAssertFalse(popover.isShown, "marked: \(marked)")
        }
    }

    func testMarkerNameOfferPreservesUserEdits() {
        let controller = AgentChatMarkerNamePopover(name: "Default", commit: { _ in })
        controller.loadViewIfNeeded()
        controller.offer("New")
        XCTAssertEqual(controller.field.stringValue, "New")
        controller.field.stringValue = "My name"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.field))
        controller.offer("Other")
        XCTAssertEqual(controller.field.stringValue, "My name")
    }

    func testMarkerNameOfferSelectsReplacementInActiveEditor() throws {
        let controller = AgentChatMarkerNamePopover(name: "Default", commit: { _ in })
        controller.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.selectName()
        let editor = try XCTUnwrap(controller.field.currentEditor() as? NSTextView)
        controller.offer("New name")
        XCTAssertEqual(editor.string, "New name")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
    }

    func testComposerLogoRestoresSymbolTintAcrossModes() {
        let editor = MistPromptEditor()
        editor.setPlaceholder(AgentChatStrings.askDrifter, icon: .drifter(engine: .claude))
        XCTAssertNotNil(editor.icon.image)
        XCTAssertFalse(editor.icon.image!.isTemplate)
        XCTAssertNil(editor.icon.contentTintColor)
        editor.setPlaceholder(AgentChatStrings.askDrifter, icon: .drifter(engine: .codex))
        XCTAssertTrue(editor.icon.image!.isTemplate)
        XCTAssertNotNil(editor.icon.contentTintColor)
        editor.setPlaceholder(AgentChatStrings.askDrifter, icon: .drifter(engine: .claude))
        XCTAssertNil(editor.icon.contentTintColor)
        XCTAssertFalse(editor.icon.image!.isTemplate)
        let chat = AgentChatComposer()
        XCTAssertFalse(chat.editor.icon.image!.isTemplate)
        XCTAssertNil(chat.editor.icon.contentTintColor)
    }

    func testPromptMarkedTextDoesNotCycleOrSubmit() throws {
        let input = MistPromptTextView()
        var submissions = 0
        input.onSubmit = { submissions += 1 }
        for code: UInt16 in [36, 48] {
            input.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(input.hasMarkedText())
            input.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: code == 48 ? "\t" : "\r", charactersIgnoringModifiers: code == 48 ? "\t" : "\r", isARepeat: false, keyCode: code)))
        }
        XCTAssertEqual(submissions, 0)
    }

    func testControlReturnQueuesAndSendsNewMessageNow() throws {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .running)
        let composer = AgentChatComposer()
        composer.bind(conversation)
        var queue = AgentMessageQueue()
        queue.enqueue(AgentQueuedMessage(id: "old", text: "Old"))
        conversation.updateQueue(queue)
        conversation.onQueue = { text, attachments, mentions in
            queue.enqueue(AgentQueuedMessage(id: "new", text: text, attachments: attachments, mentions: mentions))
            conversation.updateQueue(queue)
        }
        var sent: [String] = []
        conversation.onSendQueuedNow = { sent.append($0) }
        composer.editor.text = "New"
        composer.editor.textView.contextMenuKeyDown(try promptKeyEvent(36, flags: .control))
        XCTAssertEqual(sent, ["new"])
        XCTAssertEqual(queue.messages.map(\.text), ["Old", "New"])
        XCTAssertEqual(composer.editor.text, "")
    }

    func testControlReturnSendsFirstAvailableQueuedMessage() throws {
        let conversation = AgentConversation()
        let composer = AgentChatComposer()
        composer.bind(conversation)
        var queue = AgentMessageQueue()
        queue.enqueue(AgentQueuedMessage(id: "delivering", text: "Delivering"))
        queue.markDelivering("delivering")
        queue.enqueue(AgentQueuedMessage(id: "first", text: "First"))
        queue.enqueue(AgentQueuedMessage(id: "second", text: "Second"))
        queue.pause()
        conversation.updateQueue(queue)
        var sent: [String] = []
        conversation.onSendQueuedNow = { sent.append($0) }
        composer.editor.textView.contextMenuKeyDown(try promptKeyEvent(76, flags: .control))
        XCTAssertEqual(sent, ["first"])
    }

    func testControlReturnWithEmptyQueueDoesNothing() throws {
        let conversation = AgentConversation()
        let composer = AgentChatComposer()
        composer.bind(conversation)
        var calls = 0
        conversation.onSendQueuedNow = { _ in calls += 1 }
        conversation.onQueue = { _, _, _ in calls += 1 }
        conversation.onSend = { _, _, _ in calls += 1 }
        composer.editor.textView.contextMenuKeyDown(try promptKeyEvent(36, flags: .control))
        XCTAssertEqual(calls, 0)
    }

    func testControlReturnSendsIdleMessageNormally() throws {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        let composer = AgentChatComposer()
        composer.bind(conversation)
        var sent: [String] = []
        conversation.onSend = { text, _, _ in sent.append(text) }
        composer.editor.text = "Hello"
        composer.editor.textView.contextMenuKeyDown(try promptKeyEvent(36, flags: .control))
        XCTAssertEqual(sent, ["Hello"])
        XCTAssertEqual(composer.editor.text, "")
    }

    func testOtherContextMenuKeyDoesNotSendNow() throws {
        let input = MistPromptTextView()
        var calls = 0
        input.onSendNow = { calls += 1 }
        input.contextMenuKeyDown(try promptKeyEvent(0, flags: .control))
        XCTAssertEqual(calls, 0)
    }

    private func promptKeyEvent(_ code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: code))
    }

    func testComposerPromptGrowthAndImagePasteLimit() throws {
        let composer = AgentChatComposer()
        composer.onLaunch = { _, _, _ in true }
        let editor = composer.editor
        editor.text = "one"
        let oneLine = editor.inputHeight
        XCTAssertEqual(oneLine, 64)
        let lineHeight = ceil(editor.textView.layoutManager!.defaultLineHeight(for: AgentChatTypography.font(ofSize: 16)))
        editor.text = "one\ntwo"
        XCTAssertEqual(editor.inputHeight, oneLine + lineHeight + 4)
        editor.text = Array(repeating: "line", count: 8).joined(separator: "\n")
        let eightLines = editor.inputHeight
        editor.text = Array(repeating: "line", count: 12).joined(separator: "\n")
        XCTAssertEqual(editor.inputHeight, eightLines)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                     bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(image.bitmapData, 127, image.bytesPerRow * image.pixelsHigh)
        pasteboard.setData(try XCTUnwrap(image.representation(using: .png, properties: [:])), forType: .png)
        for _ in 0..<12 { editor.textView.paste(from: pasteboard) }
        XCTAssertEqual(composer.attachments.count, 10)
    }
    func testEmptyChatOffersLaunchSettingsAndAskPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentChatStore(route: .init(baseDirectory: root), launchSettings: .init(defaults: makeTestDefaults().defaults), tabExists: { _ in true })
        defer { store.terminate() }
        let chat = try store.createEmpty(tabId: 1)
        let controller = AgentChatViewController(store: store)
        controller.show(chat.id)
        let settings = try XCTUnwrap(controller.composer.browserLaunchRow?.settings)
        XCTAssertNil(settings.lockedEngine)
        XCTAssertTrue(settings.select(engine: .codex, model: "gpt-6.1-sol", effort: "medium"))
        XCTAssertTrue(descendants(controller.composer.editor).compactMap { $0 as? NSTextField }.contains { $0.stringValue == AgentChatStrings.askDrifter })
        chat.update(items: [.init(id: "user", kind: .userMessage(text: "Hello", images: []))], status: .idle)
        XCTAssertTrue(descendants(controller.composer.editor).compactMap { $0 as? NSTextField }.contains { $0.stringValue == AgentChatStrings.reply })
        XCTAssertTrue(controller.performPageCommand(.IDC_ZOOM_PLUS))
        XCTAssertGreaterThan(controller.pageZoom ?? 1, 1)
        XCTAssertTrue(controller.performPageCommand(.IDC_FIND))
        XCTAssertFalse(controller.performPageCommand(.IDC_RELOAD))
    }
    func testMarkerNamesAreCarriedOnlyByMarkedSliceEntries() throws {
        let chat = AgentConversation()
        chat.update(items: [.init(id: "user", kind: .userMessage(text: "Question", images: [])),
                            .init(id: "reply", kind: .assistantText(text: "Answer", isStreaming: false))], status: .idle)
        chat.toggleMarker(itemId: "reply", defaultName: "Named reply")
        let scroll = transcriptScroll(chat)
        let entries = try XCTUnwrap(scroll.slice).entries
        XCTAssertNil(entries.first { $0.row?.id == "user" }?.marker)
        XCTAssertEqual(entries.first { $0.row?.id == "reply" }?.marker, "Named reply")
    }

    func testTogglingAndRenamingMarkerRemeasuresOnlyThatRow() throws {
        let chat = AgentConversation()
        chat.update(items: (0..<8).map { .init(id: "row-\($0)", kind: .assistantText(text: "Reply \($0)", isStreaming: false)) }, status: .idle)
        let scroll = transcriptScroll(chat)
        let height = scroll.contentHeight
        chat.toggleMarker(itemId: "row-2", defaultName: "Second")
        scroll.setContent(.init(conversation: chat))
        XCTAssertEqual(scroll.lastMeasuredRowIDs, ["row-2"])
        XCTAssertEqual(scroll.contentHeight, height, accuracy: 0.5)
        chat.renameMarker(itemId: "row-2", to: "Renamed")
        scroll.setContent(.init(conversation: chat))
        XCTAssertEqual(scroll.lastMeasuredRowIDs, ["row-2"])
        XCTAssertEqual(scroll.contentHeight, height, accuracy: 0.5)
        chat.toggleMarker(itemId: "row-2", defaultName: "Unused")
        scroll.setContent(.init(conversation: chat))
        XCTAssertEqual(scroll.lastMeasuredRowIDs, ["row-2"])
        XCTAssertEqual(scroll.contentHeight, height, accuracy: 0.5)
    }

    func testMarkerTicksFollowMarkerOrderAndScrollerInset() {
        let chat = AgentConversation()
        chat.update(items: (0..<30).map { .init(id: "row-\($0)", kind: .assistantText(text: "Reply \($0)\n\nDetails", isStreaming: false)) }, status: .idle)
        chat.toggleMarker(itemId: "row-20", defaultName: "Later")
        chat.toggleMarker(itemId: "row-5", defaultName: "Earlier")
        let scroll = transcriptScroll(chat)
        scroll.scrollerInsets.right = 80
        scroll.tile()
        XCTAssertEqual(scroll.markerTicks.positions.map(\.id), ["row-5", "row-20"])
        XCTAssertEqual(scroll.markerTicks.subviews.count, 2)
        XCTAssertLessThan(scroll.markerTicks.positions[0].y, scroll.markerTicks.positions[1].y)
        XCTAssertEqual(scroll.markerTicks.frame.minX, scroll.bounds.maxX - 92, accuracy: 0.5)
        XCTAssertTrue(scroll.subviews.last === scroll.markerTicks)
        chat.removeMarker(itemId: "row-5")
        scroll.setContent(.init(conversation: chat))
        XCTAssertEqual(scroll.markerTicks.positions.map(\.id), ["row-20"])
        chat.removeMarker(itemId: "row-20")
        scroll.setContent(.init(conversation: chat))
        XCTAssertTrue(scroll.markerTicks.isHidden)
    }

    func testRevealMarkerAlignsContentTopBelowViewport() throws {
        let chat = longTranscript()
        chat.toggleMarker(itemId: "assistant-10", defaultName: "Middle")
        let scroll = transcriptScroll(chat)
        scroll.revealMarker("assistant-10")
        let window = try XCTUnwrap(scroll.transcriptWindow)
        let index = try XCTUnwrap(window.rows.firstIndex { $0.id == "assistant-10" })
        let top = 16 + window.heights.prefix(index).reduce(0, +) + AgentChatTranscriptRows.spacing(before: window.rows[index], after: window.rows[index - 1])
        XCTAssertEqual(top - scroll.contentView.bounds.minY, 24, accuracy: 0.5)
        XCTAssertTrue(window.shown.contains(index))
        XCTAssertFalse(scroll.followsBottom)
    }

    func testStepMarkerMovesBetweenTwoMarkers() {
        let chat = longTranscript()
        chat.toggleMarker(itemId: "assistant-10", defaultName: "First")
        chat.toggleMarker(itemId: "assistant-20", defaultName: "Second")
        let scroll = transcriptScroll(chat)
        scroll.revealMarker("assistant-10")
        let first = scroll.contentView.bounds.minY
        scroll.stepMarker(forward: true)
        let second = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(second, first)
        scroll.stepMarker(forward: false)
        XCTAssertEqual(scroll.contentView.bounds.minY, first, accuracy: 0.5)
        scroll.stepMarker(forward: false)
        XCTAssertEqual(scroll.contentView.bounds.minY, first, accuracy: 0.5)
    }

    func testStreamingBelowMarkersKeepsTheirNamesAndTicks() {
        let chat = AgentConversation()
        var items: [AgentChatItem] = (0..<20).map { .init(id: "row-\($0)", kind: .assistantText(text: "Reply \($0)", isStreaming: false)) }
        chat.update(items: items, status: .running)
        chat.toggleMarker(itemId: "row-2", defaultName: "Remember")
        let scroll = transcriptScroll(chat)
        let ticks = scroll.markerTicks.positions
        items[19].kind = .assistantText(text: "Other reply", isStreaming: true)
        chat.update(items: items, status: .running)
        scroll.setContent(.init(conversation: chat))
        XCTAssertEqual(scroll.lastMeasuredRowIDs, ["row-19"])
        // Equal-height text below the marker leaves its pixel position unchanged.
        XCTAssertEqual(scroll.markerTicks.positions, ticks)
    }

    func testClearRebuildsOneDrifterPageWithPreviewAndEmptyComposer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var navigated: URL?
        let store = AgentChatStore(route: .init(baseDirectory: root), tabExists: { _ in true },
            navigateTab: { _, url in navigated = url }, browserSessionFactory: { _, _, _ in NSObject() })
        defer { store.terminate() }
        let chat = try store.create(request: .init(prompt: "Hello", config: .init(engine: .codex, folder: root), windowId: 1),
            tabId: 42)
        let controller = AgentChatViewController(store: store)
        controller.show(chat.id)
        XCTAssertNotNil(controller.previewStack)
        controller.composer.editor.text = "A draft"
        try store.clear(chat.id)
        let id = try XCTUnwrap(store.route.conversationId(for: navigated?.absoluteString))
        controller.show(id)
        XCTAssertEqual(controller.conversation?.id, id)
        XCTAssertEqual(controller.conversation?.status, .dormant)
        XCTAssertEqual(controller.composer.editor.text, "")
        XCTAssertNotNil(controller.previewStack)
        XCTAssertEqual(controller.composer.browserLaunchRow?.settings.config.engine, .codex)
    }

    func testTranscriptTextZoomChangesAndRestoresHeight() {
        let conversation = AgentConversation()
        conversation.update(items: [
            .init(id: "user", kind: .userMessage(text: "Please inspect this code", images: [])),
            .init(id: "reply", kind: .assistantText(text: "# Heading\n\nSome explanation.\n\n```swift\nlet value = 42\n```", isStreaming: false)),
            .init(id: "tool", kind: .toolCall(.init(toolUseId: "t", name: "Bash", inputSummary: "List files", inputJSON: #"{"command":"ls"}"#, status: .succeeded)))
        ], status: .idle)
        let scroll = transcriptScroll(conversation)
        let controller = AgentChatViewController()
        controller.setTranscript(scroll)
        let original = scroll.contentHeight
        controller.performPageCommand(.IDC_ZOOM_PLUS)
        controller.performPageCommand(.IDC_ZOOM_PLUS)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentHeight, original)
        controller.performPageCommand(.IDC_ZOOM_NORMAL)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentHeight, original)
        for _ in MarkdownReaderZoom.levels { controller.performPageCommand(.IDC_ZOOM_MINUS) }
        XCTAssertEqual(controller.textScale, MarkdownReaderZoom.levels.first)
        controller.performPageCommand(.IDC_ZOOM_MINUS)
        XCTAssertEqual(controller.textScale, MarkdownReaderZoom.levels.first)
    }

    func testPastedFileMirrorsDraftAndImportsBeforeSend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt")
        try Data("Hello".utf8).write(to: source)
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        conversation.attachmentsFolder = root.appendingPathComponent("attachments")
        let composer = AgentChatComposer(), other = AgentChatComposer()
        composer.bind(conversation)
        other.bind(conversation)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(source.absoluteString, forType: .fileURL)
        item.setString("notes.txt", forType: .string)
        pasteboard.writeObjects([item])
        composer.editor.textView.paste(from: pasteboard)
        XCTAssertEqual(composer.attachments, [.file(.init(url: source))])
        XCTAssertEqual(conversation.draft.attachments, composer.attachments)
        XCTAssertEqual(other.attachments, composer.attachments)
        XCTAssertEqual(composer.editor.text, "")
        let chip = try XCTUnwrap(composer.strip.documentView?.subviews.first)
        XCTAssertEqual(chip.frame.size, NSSize(width: 200, height: 56))
        XCTAssertEqual(chip.accessibilityLabel(), "notes.txt")
        var opened: AgentAttachment?
        conversation.onOpenAttachment = { opened = $0 }
        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertEqual(opened, .file(.init(url: source)))
        var sent: [AgentAttachment] = []
        conversation.onSend = { _, attachments, _ in sent = attachments }
        composer.send()
        let copy = try XCTUnwrap(sent.files.first?.url)
        XCTAssertEqual(copy, root.appendingPathComponent("attachments/notes.txt"))
        XCTAssertEqual(try Data(contentsOf: copy), Data("Hello".utf8))
        XCTAssertTrue(other.attachments.isEmpty)
    }

    func testFileRowsGrowAndMixedHeightAttachmentRowsWrap() {
        let file = AgentFileAttachment(url: URL(fileURLWithPath: "/chat/notes.txt"))
        func height(files: [AgentFileAttachment]) -> CGFloat {
            let host = ThemedHostingView(rootView: AgentChatItemView(item: .init(id: "user", kind: .userMessage(text: "Read this", images: []), files: files), decide: { _, _ in }))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        XCTAssertGreaterThan(height(files: [file]), height(files: []) + 56)
        let sizes = [CGSize(width: 200, height: 56), CGSize(width: 100, height: 120), CGSize(width: 200, height: 56)]
        let (size, points) = AgentChatThumbnailLayout.positions(sizes, width: 320)
        XCTAssertEqual(size.height, 182)
        XCTAssertEqual(points, [CGPoint(x: 14, y: 0), CGPoint(x: 220, y: 0), CGPoint(x: 120, y: 126)])
    }

    func testClearInterceptsBeforeSendingQueueingOrRestartingInEveryActiveStatus() {
        for status in [AgentConversationStatus.starting, .idle, .running, .awaitingPermission, .dormant, .failed("Failed")] {
            let conversation = AgentConversation()
            conversation.update(items: [], status: status)
            let composer = AgentChatComposer()
            composer.bind(conversation)
            composer.editor.slashCommandsEnabled = true
            composer.editor.text = " /reset ignored"
            var cleared = 0
            conversation.onClear = { cleared += 1 }
            conversation.onSend = { _, _, _ in XCTFail("Clear reached send") }
            conversation.onQueue = { _, _, _ in XCTFail("Clear reached queue") }
            conversation.onRestart = { _ in XCTFail("Clear reached restart") }
            XCTAssertTrue(composer.sendButton.isEnabled)
            composer.send()
            XCTAssertEqual(cleared, 1)
            XCTAssertEqual(composer.editor.text, "")
            XCTAssertEqual(conversation.draft.text, "")
            XCTAssertTrue(conversation.items.isEmpty)
        }
    }

    func testLeadingMentionGoesOutAsTypedBeforeAnySlashCommand() {
        for text in ["@News /reset ignored", "@News /compact", "@News /review"] {
            let conversation = AgentConversation()
            conversation.update(items: [], status: .idle)
            let composer = AgentChatComposer()
            composer.bind(conversation)
            composer.editor.slashCommandsEnabled = true
            composer.editor.mentionsEnabled = true
            composer.editor.slashCommands = [.init(name: "compact", description: "", argumentHint: "", builtin: true, isSkill: false),
                                             .init(name: "review", description: "", argumentHint: "", isSkill: true)]
            composer.editor.setText(text, mentions: [.init(tabId: 9, title: "News", url: "https://news.test", range: NSRange(location: 0, length: 5))])
            conversation.onClear = { XCTFail("A mention before /reset makes it text") }
            var sent: (text: String, mentions: [AgentTabMention])?
            conversation.onSend = { text, _, mentions in sent = (text, mentions) }
            composer.send()
            XCTAssertEqual(sent?.text, text)
            XCTAssertEqual(sent?.mentions.map(\.tabId), [9])
            XCTAssertEqual(composer.editor.text, "")
        }
    }



    func testComposerKeepsEachConversationsDraftAndClearsAfterSending() {
        let first = AgentConversation(), second = AgentConversation()
        first.setDraft(.init(text: "First draft"))
        second.setDraft(.init(text: "Second draft"))
        first.update(items: [], status: .idle)
        let composer = AgentChatComposer()
        composer.bind(first)
        XCTAssertEqual(composer.editor.text, "First draft")
        composer.editor.text = "Edited draft"
        XCTAssertEqual(first.draft.text, "Edited draft")
        composer.bind(second)
        XCTAssertEqual(composer.editor.text, "Second draft")
        composer.bind(first)
        XCTAssertEqual(composer.editor.text, "Edited draft")
        var sent = ""
        first.onSend = { text, _, _ in sent = text }
        composer.send()
        XCTAssertEqual(sent, "Edited draft")
        XCTAssertEqual(first.draft.text, "")
        XCTAssertEqual(second.draft.text, "Second draft")
    }

    func testComposersShareDraftAndKeepSelections() throws {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        let a = AgentChatComposer(), b = AgentChatComposer()
        a.editor.mentionsEnabled = true; b.editor.mentionsEnabled = true
        a.bind(conversation); b.bind(conversation)
        let mention = AgentTabMention(tabId: 9, title: "Page", url: "https://example.com", range: NSRange(location: 0, length: 5))
        a.editor.setText("@Page hello", mentions: [mention])
        XCTAssertEqual(b.editor.text, "@Page hello")
        XCTAssertEqual(b.editor.mentions.map(\.tabId), [9])
        XCTAssertNotNil(b.editor.textView.textStorage?.attribute(AgentChatMentionStyle.token, at: 0, effectiveRange: nil))
        b.editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        a.editor.setText("@Page hello!", mentions: [mention])
        XCTAssertEqual(b.editor.textView.selectedRange().location, 7)
        a.editor.setText("@Page XXhello!", mentions: [mention])
        XCTAssertEqual(b.editor.textView.selectedRange().location, 9)
        a.editor.text = "```swift\nlet x = 1\n```"
        XCTAssertEqual(b.editor.text, a.editor.text)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pasteboard.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        XCTAssertTrue(a.addAttachments(from: pasteboard))
        XCTAssertEqual(b.attachments, a.attachments)
        var sent: [(String, [AgentAttachment])] = []
        conversation.onSend = { text, images, _ in sent.append((text, images)) }
        b.send()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "```swift\nlet x = 1\n```")
        XCTAssertEqual(sent.first?.1.count, 1)
        XCTAssertEqual(a.editor.text, ""); XCTAssertEqual(b.editor.text, "")
        XCTAssertTrue(a.attachments.isEmpty); XCTAssertTrue(b.attachments.isEmpty)
        XCTAssertEqual(conversation.draft, AgentComposerDraft())
    }

    func testDraftSelectionMapping() {
        let old = "abc123xyz", new = "abc4567xyz"
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 1, length: 0), from: old, to: new), NSRange(location: 1, length: 0))
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 4, length: 0), from: old, to: new), NSRange(location: 7, length: 0))
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 8, length: 0), from: old, to: new), NSRange(location: 9, length: 0))
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 1, length: 7), from: old, to: new), NSRange(location: 1, length: 8))
        // A caret at the end follows appended text.
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 9, length: 0), from: old, to: old + "!"), NSRange(location: 10, length: 0))
        XCTAssertEqual(AgentComposerDraft.mapSelection(NSRange(location: 0, length: 0), from: "", to: new), NSRange(location: 10, length: 0))
    }

    func testFailedRestartReturnsMessageOnceToBothComposers() {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .failed("Stopped"))
        let a = AgentChatComposer(), b = AgentChatComposer()
        a.bind(conversation); b.bind(conversation)
        conversation.onRestart = { _ in conversation.update(items: [], status: .starting) }
        a.editor.text = "Again"
        a.send()
        XCTAssertEqual(a.editor.text, "")
        XCTAssertEqual(b.editor.text, "")
        conversation.update(items: [], status: .failed("Relaunch failed"))
        XCTAssertEqual(a.editor.text, "Again")
        XCTAssertEqual(b.editor.text, "Again")
        XCTAssertEqual(conversation.draft.text, "Again")
    }

    func testSameChatIdRebuildsControllerAfterRestoration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in false }, browserSessionFactory: { _, _, _ in NSObject() })
        defer { store.terminate() }
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 1)
        conversation.setDraft(.init(text: "Next message"))
        let controller = AgentChatViewController(store: store)
        controller.show(conversation.id)
        store.closeIfTabIsGone(1)
        XCTAssertTrue(store.restoreIfNeeded(conversation.id, tabId: 2))
        controller.show(conversation.id)
        XCTAssertFalse(controller.conversation === conversation)
        XCTAssertTrue(controller.conversation === store.conversation(for: conversation.id))
        XCTAssertEqual(controller.composer.editor.text, "Next message")
    }

    func testRestoredChatSendsItsFirstMessageThroughRestart() {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .dormant)
        let composer = AgentChatComposer()
        composer.bind(conversation)
        XCTAssertTrue(composer.editor.textView.isEditable)
        XCTAssertFalse(composer.sendButton.isEnabled)
        var sent = 0, restarts: [String] = []
        conversation.onSend = { _, _, _ in sent += 1 }
        conversation.onRestart = { message in restarts.append(message.text) }
        composer.editor.text = "Hello"
        XCTAssertTrue(composer.sendButton.isEnabled)
        composer.send()
        XCTAssertEqual(restarts, ["Hello"])
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(composer.editor.text, "Hello", "Nothing launched, so the message comes straight back")
    }

    func testMentionAutoSpaceSwallowsTheNextTypedSpaceAndSendsNormalizedText() throws {
        let composer = AgentChatComposer()
        var sent = ""
        composer.onLaunch = { text, _, _ in sent = text; return true }
        composer.configureLaunch(saved: .init())
        let tab = Tab(guid: 1, url: "https://example.com", isActive: false, index: 0, title: "Page")
        composer.editor.insertMentionIfEmpty(for: tab)
        XCTAssertEqual(composer.editor.text, "@Page ")
        XCTAssertFalse(composer.editor.textView(composer.editor.textView, shouldChangeTextIn: NSRange(location: 6, length: 0), replacementString: " "))
        composer.send()
        XCTAssertEqual(sent, "@Page")
        XCTAssertEqual(composer.editor.text, "")
    }

    func testFailedLaunchKeepsTheDraft() {
        let composer = AgentChatComposer()
        composer.onLaunch = { _, _, _ in false }
        composer.configureLaunch(saved: .init())
        composer.editor.text = "say hi"
        composer.send()
        XCTAssertEqual(composer.editor.text, "say hi")
    }

    func testJumpToBottomAppearsAfterScrollingAwayAndRestoresFollowing() {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "long", kind: .assistantText(text: String(repeating: "A line of output\n", count: 100), isStreaming: false))], status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 240)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertTrue(scroll.jumpButton.isHidden)
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(scroll.followsBottom)
        XCTAssertFalse(scroll.jumpButton.isHidden)
        XCTAssertEqual(scroll.jumpButton.frame.width, 28)
        XCTAssertEqual(scroll.jumpButton.frame.midX, scroll.bounds.midX, accuracy: 0.5)
        scroll.jumpToBottom()
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertTrue(scroll.jumpButton.isHidden)
    }

    func testPageTranscriptSpansItsMarginsAndKeepsRowsToTheColumn() throws {
        let conversation = AgentConversation()
        conversation.update(items: (0..<40).map { .init(id: String($0), kind: .userMessage(text: "Message \($0)", images: [])) }, status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.column = AgentChatColumn(panel: false)
        scroll.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        let content = try XCTUnwrap(document.subviews.first)
        XCTAssertEqual(document.frame.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(content.frame.width, AgentChatColumn.maxWidth, accuracy: 0.5)
        XCTAssertEqual(content.frame.midX, scroll.contentSize.width / 2, accuracy: 0.5)

        scroll.frame.size.width = 500
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(document.frame.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(content.frame.minX, 24, accuracy: 0.5)
        XCTAssertEqual(content.frame.width, scroll.contentSize.width - 48, accuracy: 0.5)
    }

    func testSendingMessageRestoresTranscriptFollowing() {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "long", kind: .assistantText(text: String(repeating: "A line of output\n", count: 100), isStreaming: false))], status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 240)
        scroll.observe(conversation)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(scroll.followsBottom)
        XCTAssertFalse(scroll.jumpButton.isHidden)
        conversation.messageSent.send()
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertTrue(scroll.jumpButton.isHidden)
    }

    func testComposerSignalsAcceptedMessages() {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        conversation.onSend = { _, _, _ in }
        conversation.onQueue = { _, _, _ in }
        let composer = AgentChatComposer()
        composer.bind(conversation)
        var signals = 0
        let subscription = conversation.messageSent.sink { signals += 1 }
        composer.editor.text = "Hello"
        composer.send()
        XCTAssertEqual(signals, 1)
        composer.send()
        XCTAssertEqual(signals, 1)
        conversation.update(items: [], status: .running)
        composer.editor.text = "Next"
        composer.send()
        XCTAssertEqual(signals, 2)
        withExtendedLifetime(subscription) {}
    }

    func testTranscriptLinkDelegateRoutesURLsThroughConversationAndConsumesTheClick() {
        let conversation = AgentConversation()
        let coordinator = AgentChatRichText.Coordinator()
        let textView = AgentChatTextView(frame: .zero, textContainer: nil)
        var opened: [URL] = []
        conversation.onOpenLink = { opened.append($0) }
        coordinator.openLink = { conversation.onOpenLink?($0) }
        let url = URL(string: "https://example.com/path?q=1#section")!
        XCTAssertTrue(coordinator.textView(textView, clickedOnLink: url, at: 0))
        XCTAssertTrue(coordinator.textView(textView, clickedOnLink: url.absoluteString, at: 0))
        XCTAssertEqual(opened, [url, url])
    }
    func testMentionBannerDeduplicatesInTokenOrderDimsClosedTabsAndRemovesEveryToken() throws {
        let composer = AgentChatComposer()
        composer.onLaunch = { _, _, _ in true }
        composer.configure(settings: DrifterSettings(config: .init()))
        let editor = composer.editor
        let tab = Tab(guid: 7, url: "https://example.com", isActive: false, index: 0, title: "Page")
        editor.mentionTabs = { [tab] }
        editor.text = "@Page @Closed @Page draft"
        let tokens = [AgentTabMention(tabId: 7, title: "Page", url: "https://example.com", range: NSRange(location: 0, length: 5)),
                      AgentTabMention(tabId: 8, title: "Closed", url: "https://closed.test", range: NSRange(location: 6, length: 7)),
                      AgentTabMention(tabId: 7, title: "Page", url: "https://example.com", range: NSRange(location: 14, length: 5))]
        AgentChatMentionStyle.apply(tokens, to: try XCTUnwrap(editor.textView.textStorage), pointSize: 16)
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(editor.mentionBanner.mentions.map(\.tabId), [7, 8])
        XCTAssertEqual(editor.mentionBanner.mentions.map(\.closed), [false, true])
        XCTAssertEqual(editor.mentionBanner.rows.map(\.alphaValue), [1, 0.45])
        XCTAssertEqual(editor.mentionBannerHeight, 96)
        composer.frame = NSRect(x: 0, y: 0, width: 300, height: composer.intrinsicContentSize.height)
        composer.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.mentionBanner.frame.width, composer.card.frame.width)
        XCTAssertGreaterThanOrEqual(editor.mentionBanner.frame.minY, composer.card.frame.maxY)
        editor.mentionBanner.rows[0].removeButton.performClick(nil)
        XCTAssertEqual(editor.mentions.map(\.tabId), [8])
        XCTAssertEqual(editor.text, "@Closed draft")
        editor.mentionBanner.rows[0].removeButton.performClick(nil)
        XCTAssertEqual(editor.text, "draft")
        XCTAssertTrue(editor.mentionBanner.isHidden)
        XCTAssertEqual(editor.mentionBannerHeight, 0)
    }

    func testGroupBannerShowsLiveCountDimsClosedGroupAndRemovesEveryToken() throws {
        let composer = AgentChatComposer()
        composer.onLaunch = { _, _, _ in true }
        composer.configure(settings: DrifterSettings(config: .init()))
        let editor = composer.editor
        let tab = Tab(guid: 7, url: "https://example.test", isActive: false, index: 0, title: "Page")
        let info = WebContentGroupInfo(token: "g", title: "PRs", color: .blue, isCollapsed: false)
        editor.mentionTabs = { [tab] }
        editor.mentionGroups = { [MistMentionGroup(info: info, tabs: [tab])] }
        let open = AgentTabMention(tabId: 0, title: "PRs", url: "", range: NSRange(location: 0, length: 4), group: .init(token: "g", color: "blue", tabs: []))
        let closed = AgentTabMention(tabId: 0, title: "Old", url: "", range: NSRange(location: 5, length: 4), group: .init(token: "gone", color: "red", tabs: [AgentTabMention(tab: tab)]))
        var duplicate = open
        duplicate.range = NSRange(location: 10, length: 4)
        editor.setText("@PRs @Old @PRs draft", mentions: [open, closed, duplicate])
        XCTAssertEqual(editor.mentionBanner.mentions.map(\.key), ["group:g", "group:gone"])
        XCTAssertEqual(editor.mentionBanner.mentions.map { $0.group?.tabs.count }, [1, 1])
        XCTAssertEqual(editor.mentionBanner.rows.map(\.alphaValue), [1, 0.45])
        let count = AgentTabMention(group: MistMentionGroup(info: info, tabs: [tab])).secondaryText
        XCTAssertEqual(editor.mentionBanner.rows[0].accessibilityLabel(), "PRs. " + count)
        XCTAssertEqual(editor.mentionBanner.rows[1].accessibilityLabel(), "Old. " + count)
        editor.mentionBanner.rows[0].removeButton.performClick(nil)
        XCTAssertEqual(editor.text, "@Old draft")
        XCTAssertEqual(editor.mentions.map(\.key), ["group:gone"])
        editor.mentionBanner.rows[0].removeButton.performClick(nil)
        XCTAssertEqual(editor.text, "draft")
        XCTAssertTrue(editor.mentionBanner.isHidden)
    }

    func testGroupSendCarriesSnapshotAtSendAndDoesNotCountAsHostTabMention() {
        let composer = AgentChatComposer()
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        composer.bind(conversation)
        composer.configure(settings: DrifterSettings(config: .init(), running: true))
        let first = Tab(guid: 71, url: "https://first.test", isActive: false, index: 0, title: "First")
        let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1, title: "Second")
        let info = WebContentGroupInfo(token: "g", title: "PRs", color: .blue, isCollapsed: false)
        var members = [first]
        composer.editor.mentionGroups = { [MistMentionGroup(info: info, tabs: members)] }
        var mention = AgentTabMention(group: MistMentionGroup(info: info, tabs: members))
        mention.range = NSRange(location: 0, length: 4)
        composer.editor.setText("@PRs", mentions: [mention])
        XCTAssertFalse(AgentComposerDraft(text: "@PRs", mentions: [mention]).isOnlyMention(of: [0]))
        members = [second, first]
        first.title = "Updated"
        var sent: [AgentTabMention] = []
        conversation.onSend = { text, _, mentions in
            XCTAssertEqual(text, "@PRs")
            sent = mentions
        }
        composer.send()
        XCTAssertEqual(sent.first?.group?.token, "g")
        XCTAssertEqual(sent.first?.group?.tabs.map(\.tabId), [72, 71])
        XCTAssertEqual(sent.first?.group?.tabs.map(\.title), ["Second", "Updated"])
        members = []
        first.title = "Later"
        XCTAssertEqual(sent.first?.group?.tabs.map(\.title), ["Second", "Updated"])
        XCTAssertTrue(composer.editor.mentions.isEmpty)
    }
    func testDrifterBandListsClearAndSkillsButNoCLICommands() {
        let composer = AgentChatComposer()
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        composer.bind(conversation)
        let settings = DrifterSettings(config: .init(), running: true)
        composer.configure(settings: settings)
        XCTAssertNotNil(composer.browserLaunchRow)
        // Slash commands list Mist's /clear and Drifter skills, never the CLI's own commands.
        XCTAssertTrue(composer.editor.slashCommandsEnabled)
        XCTAssertTrue(composer.editor.mentionsEnabled)
        XCTAssertEqual(composer.slashCommandNames.subtracting(DrifterSkillCatalog.shared.skills.map(\.name)), ["clear"])
        let menu = composer.browserLaunchRow!.modelMenu()
        XCTAssertTrue(menu.items.contains { $0.title == "Claude" })
        XCTAssertFalse(menu.items.contains { $0.title == "GPT" })
    }

    func testBrowserChatSendCarriesMentionsAndClearsTokens() {
        let composer = AgentChatComposer()
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        composer.bind(conversation)
        composer.configure(settings: DrifterSettings(config: .init(), running: true))
        let mention = AgentTabMention(tabId: 71, title: "Page", url: "https://example.com", range: NSRange(location: 0, length: 5))
        composer.editor.text = "@Page"
        AgentChatMentionStyle.apply([mention], to: composer.editor.textView.textStorage!, pointSize: 16)
        var sent: [AgentTabMention] = []
        conversation.onSend = { text, _, mentions in
            XCTAssertEqual(text, "@Page")
            sent = mentions
        }
        composer.send()
        XCTAssertEqual(sent.map(\.tabId), [71])
        XCTAssertEqual(sent.first?.closed, true)
        XCTAssertTrue(composer.editor.mentions.isEmpty)
        XCTAssertEqual(composer.editor.text, "")
    }

    func testUserBubbleStylesKnownSlashCommandsWithoutChangingTheText() {
        let text = "Please /review, then /usr/bin"
        let styled = AgentChatSlashStyle.plainText(text, commands: ["review", "usr"], font: .systemFont(ofSize: 14), color: .labelColor)
        XCTAssertEqual(styled.string, text)
        var blue: [String] = []
        styled.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: styled.length)) { color, range, _ in
            if color as? NSColor == .systemBlue { blue.append((styled.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(blue, ["/review"])
    }

    func testPermissionCardAttachesToItsToolRowOnly() {
        let tool = AgentChatItem.ToolCall(toolUseId: "t", name: "AskUserQuestion", inputSummary: "", inputJSON: "{}")
        let row = AgentChatDisplayRow.item(.init(id: "p", kind: .permissionRequest(.init(requestId: "p", toolName: "AskUserQuestion", summary: ""))))
        let toolRow = AgentChatDisplayRow.item(.init(id: "t", kind: .toolCall(tool)))
        XCTAssertEqual(AgentChatTranscriptRows.spacing(before: row, after: toolRow), 6)
        XCTAssertEqual(AgentChatTranscriptRows.spacing(before: row, after: .toolGroup([tool, tool])), 6)
        XCTAssertEqual(AgentChatTranscriptRows.spacing(before: toolRow, after: row), 10)
        XCTAssertEqual(AgentChatTranscriptRows.spacing(before: row, after: nil), 0)
    }


    func testQuestionCardSubmitsAnswersThroughConversation() throws {
        let input = try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(#"{"questions":[{"header":"Color","question":"Pick a color","options":[{"label":"Red","description":"Select red"},{"label":"Blue","description":"Select blue"}],"multiSelect":false}]}"#.utf8))
        let request = AgentChatItem.PermissionRequest(requestId: "q", toolName: "AskUserQuestion", summary: "Pick a color", input: input, requiresUserInteraction: true)
        let conversation = AgentConversation()
        var responses: [AgentPermissionResponse] = []
        conversation.onPermissionDecision = { id, response in
            XCTAssertEqual(id, "q")
            responses.append(response)
        }
        let rows = AgentChatTranscriptRows(conversation: conversation)
        let card = AgentChatPermissionCard(request: request, decide: rows.decidePermission)
        card.submit([:])
        XCTAssertTrue(responses.isEmpty)
        card.submit([0: .init(options: [1])])
        guard case let .allowWithInput(updated) = responses.first else { return XCTFail("Missing answer") }
        XCTAssertEqual(updated["answers"]["Pick a color"].string, "Blue")
        XCTAssertEqual(updated["questions"], input["questions"])
    }

    func testPlanCardApprovesBeforeRequestingAcceptEditsAndKeepsFeedback() throws {
        let conversation = AgentConversation()
        var sent: [ClaudeCodeJSON] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: {
            sent.append(try! JSONDecoder().decode(ClaudeCodeJSON.self, from: Data($0.utf8)))
        })
        defer { session.close() }
        let rows = AgentChatTranscriptRows(conversation: conversation)
        let input: ClaudeCodeJSON = .object(["plan": .string("# Plan\n\n1. Make the change.")])
        for index in 0..<2 {
            let id = String(index)
            session.receive(.event(.permission(.object(["request_id": .string(id), "request": .object(["tool_name": .string("ExitPlanMode"), "input": input])]))))
            let card = AgentChatPermissionCard(request: .init(requestId: id, toolName: "ExitPlanMode", summary: "Plan", input: input), decide: rows.decidePermission)
            card.approve()
        }
        XCTAssertEqual(sent.count, 2)
        for reply in sent.prefix(2) {
            XCTAssertEqual(reply["response"]["response"]["behavior"].string, "allow")
            XCTAssertEqual(reply["response"]["response"]["updatedInput"], input)
        }
        var feedback: [AgentPermissionResponse] = []
        let card = AgentChatPermissionCard(request: .init(requestId: "p", toolName: "ExitPlanMode", summary: "Plan", input: input), decide: { _, response in feedback.append(response) })
        card.keepPlanning("  Add validation  ")
        card.keepPlanning("")
        XCTAssertEqual(feedback, [.deny(message: "Add validation"), .deny(message: "The user wants to keep planning.")])
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    func testUserImagesAreAboveAndOutsideTheTextBubble() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(bitmap.bitmapData, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = AgentImageAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), mediaType: "image/png")
        let size = AgentChatThumbnailLayout.thumbnailSize(for: NSSize(width: 300, height: 120))
        XCTAssertEqual(size, CGSize(width: 240, height: 120))
        XCTAssertEqual(AgentChatThumbnailLayout.thumbnailSize(for: NSSize(width: 60, height: 120)), CGSize(width: 60, height: 120))
        let (fit, points) = AgentChatThumbnailLayout.positions(Array(repeating: size, count: 3), width: 525)
        XCTAssertEqual(fit.height, 246)
        XCTAssertEqual(points.map(\.y), [0, 0, 126], "Three wide thumbnails should wrap into two rows")
        XCTAssertEqual(points.map { $0.x + size.width }, [279, 525, 525], "Rows are right-aligned")

        // SwiftUI exposes no accessibility tree in offscreen hosts, so measure heights instead.
        func height(_ text: String) -> CGFloat {
            let host = ThemedHostingView(rootView: AgentChatItemView(item: .init(id: "user", kind: .userMessage(text: text, images: [image, image, image])), decide: { _, _ in }))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        XCTAssertEqual(height(""), 246, accuracy: 1, "Images alone get no bubble padding")
        XCTAssertGreaterThan(height("A caption"), 246 + 8 + 20, "The caption bubble sits below the thumbnails")
    }

    func testAssistantHeightIncludesFinalLineAndInsetsAtDifferentWidths() throws {
        let text = "# A heading\n\nA long paragraph that wraps across several lines. " + String(repeating: "More words with descenders: gyp. ", count: 12) + "\n\n```swift\nlet value = 1\nprint(value)\n```\n\nFinal line: gyp."
        for width in [CGFloat(320), 600] {
            let host = ThemedHostingView(rootView: AgentChatRichText(text: text).fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(NSSize(width: width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(descendants(host).compactMap { $0 as? AgentChatTextView }.first)
            let container = try XCTUnwrap(view.textContainer)
            let manager = try XCTUnwrap(view.layoutManager)
            manager.ensureLayout(for: container)
            // The used rect excludes the final paragraph's spacing, which the measured height trims.
            let last = manager.lineFragmentUsedRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
            // SwiftUI may settle the frame a fraction of a point under the ceiled measurement.
            XCTAssertGreaterThanOrEqual(view.frame.height, last.maxY + view.textContainerInset.height * 2 - 1)
            let style = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.lineHeightMultiple, 1.25, accuracy: 0.01)
            XCTAssertEqual(style.paragraphSpacing, 6)
            var hasCodeBackground = false
            view.textStorage?.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: view.string.utf16.count)) { color, _, _ in
                if color != nil { hasCodeBackground = true }
            }
            XCTAssertTrue(hasCodeBackground)
        }
    }

    /// A new row's text view is filled before SwiftUI sizes it: its code controls wait for a width rather than lay the
    /// text out a character per line, and its first width places them.
    func testCodeButtonsWaitForTheViewsFirstWidth() throws {
        let view = AgentChatTextView(frame: .zero, textContainer: nil)
        view.textContainer?.widthTracksTextView = true
        let renderer = MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .boldSystemFont(ofSize: 20),
            nsFontSubheading: .boldSystemFont(ofSize: 17), nsFontSmall: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
            textNS: .labelColor, dimNS: .secondaryLabelColor)
        view.textStorage?.setAttributedString(renderer.markdownRuns("~~~\n" + String(repeating: "x", count: 5_000) + "\n~~~", color: .labelColor))
        view.layout()
        view.updateCodeControls()
        XCTAssertTrue(view.codeButtons.isEmpty)
        XCTAssertEqual(view.layoutManager?.firstUnlaidCharacterIndex(), 0)
        view.setFrameSize(NSSize(width: 340, height: 600))
        view.layout()
        XCTAssertEqual(view.codeButtons.count, 1)
    }

    func testCodeButtonsReuseUpdateCopyAndDisappear() throws {
        let view = AgentChatTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 600), textContainer: nil)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        let renderer = MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .boldSystemFont(ofSize: 20),
            nsFontSubheading: .boldSystemFont(ofSize: 17), nsFontSmall: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
            textNS: .labelColor, dimNS: .secondaryLabelColor)
        view.textStorage?.setAttributedString(renderer.markdownRuns("~~~swift\nlet a = 1\n~~~", color: .labelColor))
        view.updateCodeControls()
        let button = try XCTUnwrap(view.codeButtons[0])
        XCTAssertEqual(view.codeButtons.count, 1)
        XCTAssertEqual(button.text, "let a = 1\n")
        XCTAssertEqual(button.accessibilityLabel(), "Copy code")
        XCTAssertGreaterThan(button.frame.minX, 0)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        button.copyText(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "let a = 1\n")
        XCTAssertTrue(button.copied)
        let combined = NSMutableAttributedString(attributedString: renderer.markdownRuns("~~~swift\nlet a = 12\n~~~", color: .labelColor))
        combined.append(renderer.markdownRuns("~~~\nsecond\n~~~", color: .labelColor))
        view.textStorage?.setAttributedString(combined)
        view.updateCodeControls()
        XCTAssertTrue(view.codeButtons[0] === button)
        XCTAssertFalse(button.copied)
        XCTAssertEqual(view.codeButtons.count, 2)
        let second = try XCTUnwrap(view.codeButtons[1])
        XCTAssertGreaterThan(second.frame.minY, button.frame.maxY)
        let before = button.frame
        view.setFrameSize(NSSize(width: 240, height: 600))
        view.textContainer?.containerSize.width = 240
        view.updateCodeControls()
        XCTAssertLessThan(button.frame.maxX, before.maxX)
        view.textStorage?.setAttributedString(renderer.markdownRuns("Plain reply", color: .labelColor))
        view.updateCodeControls()
        XCTAssertTrue(view.codeButtons.isEmpty)
        XCTAssertNil(button.superview)
        XCTAssertNil(second.superview)
    }

    func testOneLineReplyMeasuresOneContentLineAndInsets() throws {
        let renderer = MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .boldSystemFont(ofSize: 20),
            nsFontSubheading: .boldSystemFont(ofSize: 17), nsFontSmall: .systemFont(ofSize: 12), textNS: .labelColor, dimNS: .secondaryLabelColor)
        let view = AgentChatTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), textContainer: nil)
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textStorage?.setAttributedString(renderer.markdownRuns("One line gyp.", color: .labelColor))
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let height = AgentChatTextView.measuredHeight(view, manager: manager, container: container)
        XCTAssertEqual(height, manager.defaultLineHeight(for: .systemFont(ofSize: 14)) * AgentChatTypography.lineHeightMultiple + 8, accuracy: 1)
        XCTAssertGreaterThan(manager.usedRect(for: container).maxY + 8 - height, 25)
    }

    func testTurnDividerHasEqualVisualGapsBetweenOneLineReplies() throws {
        let conversation = AgentConversation()
        conversation.update(items: [
            .init(id: "a", kind: .assistantText(text: "Before", isStreaming: false)),
            .init(id: "end", kind: .turnEnd(durationMilliseconds: 1000, finishedAt: Date())),
            .init(id: "b", kind: .assistantText(text: "After", isStreaming: false)),
        ], status: .idle)
        let host = ThemedHostingView(rootView: AgentChatTranscriptRows(conversation: conversation))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        let views = descendants(host).compactMap { $0 as? AgentChatTextView }
        let before = try XCTUnwrap(views.first { $0.string.hasPrefix("Before") })
        let after = try XCTUnwrap(views.first { $0.string.hasPrefix("After") })
        let first = before.convert(before.bounds, to: host)
        let second = after.convert(after.bounds, to: host)
        // A turn row is 16 pt with symmetric 20 pt padding, preceded by the 18 pt row gap.
        let dividerCenter = first.maxY + 18 + 28
        XCTAssertEqual(dividerCenter - (first.maxY - 4), (second.minY + 4) - dividerCenter, accuracy: 2)
    }

    func testStoppedTurnLabelKeepsItsFullWidthWhenRulesCompeteForSpace() {
        let label = NSHostingController(rootView: AgentChatItemView.turnEndLabel(223_000,
            finishedAt: Date(timeIntervalSince1970: 1_790_000_000), stopped: true))
        let natural = label.sizeThatFits(in: NSSize(width: 1000, height: 100))
        let offeredByHStack = NSSize(width: 700 / 3, height: 16)
        let constrained = label.sizeThatFits(in: offeredByHStack)
        XCTAssertGreaterThan(natural.width, offeredByHStack.width, "Exercise the label that used to be truncated")
        XCTAssertEqual(constrained.width, natural.width, accuracy: 1, "The rules must shrink before the label")
        XCTAssertEqual(constrained.height, natural.height, accuracy: 1, "Keep the divider label on one line")
    }

    func testLongUserBubbleDrawsTheSameWrappedLinesItMeasured() throws {
        let text = "Please review the current browser agent implementation and explain how model selection, confirmation settings, and background tab handling work together."
        let controller = NSHostingController(rootView: AgentChatItemView(
            item: .init(id: "long-user", kind: .userMessage(text: text, images: [])), decide: { _, _ in }))
        let column: CGFloat = 700
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: column, height: 1)
        host.layoutSubtreeIfNeeded()
        let measured = controller.sizeThatFits(in: NSSize(width: column, height: 10_000))
        // A later ideal/wider probe used to leave the visible text container at that width.
        _ = controller.sizeThatFits(in: NSSize(width: 1400, height: 10_000))
        host.frame = NSRect(x: 0, y: 0, width: column, height: measured.height)
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(descendants(host).compactMap { $0 as? AgentChatTextView }.first)
        view.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: host)
        let contentWidth = column * 0.75 - 32
        XCTAssertGreaterThanOrEqual(frame.minX, column * 0.25 + 16 - 1)
        XCTAssertLessThanOrEqual(frame.maxX, column - 16 + 1)
        XCTAssertEqual(frame.width, contentWidth, accuracy: 1, "Text stays inside the padded bubble")

        let actualContainer = try XCTUnwrap(view.textContainer)
        let actualManager = try XCTUnwrap(view.layoutManager)
        XCTAssertEqual(actualContainer.containerSize.width, view.bounds.width, accuracy: 0.01)
        let reference = AgentChatTextView(frame: .zero, textContainer: nil)
        reference.textContainerInset = .zero
        let expectedContainer = try XCTUnwrap(reference.textContainer)
        expectedContainer.widthTracksTextView = false
        expectedContainer.lineFragmentPadding = 0
        expectedContainer.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        reference.textStorage?.setAttributedString(view.attributedString())
        let expectedManager = try XCTUnwrap(reference.layoutManager)
        func lines(_ manager: NSLayoutManager, _ container: NSTextContainer) -> Int {
            manager.ensureLayout(for: container)
            var count = 0
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
            return count
        }
        let expectedLines = lines(expectedManager, expectedContainer)
        XCTAssertGreaterThan(expectedLines, 1)
        XCTAssertEqual(lines(actualManager, actualContainer), expectedLines)
        let expectedHeight = AgentChatTextView.measuredHeight(reference, manager: expectedManager, container: expectedContainer)
        XCTAssertEqual(view.frame.height, expectedHeight, accuracy: 1)
        XCTAssertEqual(measured.height, expectedHeight + 24, accuracy: 1, "Bubble height includes the same wrapped lines plus vertical padding")
    }

    func testShortUserBubbleStillHugsItsText() throws {
        let controller = NSHostingController(rootView: AgentChatItemView(
            item: .init(id: "short-user", kind: .userMessage(text: "Thanks!", images: [])), decide: { _, _ in }))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
        host.layoutSubtreeIfNeeded()
        host.setFrameSize(NSSize(width: 700, height: controller.sizeThatFits(in: NSSize(width: 700, height: 10_000)).height))
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(descendants(host).compactMap { $0 as? AgentChatTextView }.first)
        let frame = view.convert(view.bounds, to: host)
        XCTAssertEqual(frame.width, ceil(view.attributedString().size().width), accuracy: 1)
        XCTAssertLessThan(frame.width + 32, 150, "A short bubble must not fill the 75% column")
        XCTAssertEqual(frame.maxX, 700 - 16, accuracy: 1)
    }

    func testFinalBlockPaddingFitsInsideMeasuredReply() throws {
        for source in ["~~~swift\nlet a = 1\n~~~", "| Header | More |\n|---|---|\n| final | cell |"] {
            let host = ThemedHostingView(rootView: AgentChatRichText(text: source).fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 1)
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(NSSize(width: 320, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(descendants(host).compactMap { $0 as? AgentChatTextView }.first)
            let manager = try XCTUnwrap(view.layoutManager)
            let container = try XCTUnwrap(view.textContainer)
            manager.ensureLayout(for: container)
            let measured = AgentChatTextView.measuredHeight(view, manager: manager, container: container)
            view.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                guard let style = value as? NSParagraphStyle else { return }
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                for block in style.textBlocks {
                    let box = manager.boundsRect(for: block, at: glyphs.location, effectiveRange: nil)
                    XCTAssertGreaterThan(box.height, 0)
                    XCTAssertLessThanOrEqual(box.maxY - block.width(for: .margin, edge: .maxY) + view.textContainerInset.height * 2, measured)
                    XCTAssertLessThanOrEqual(box.maxX, container.containerSize.width + 1)
                }
            }
            XCTAssertGreaterThanOrEqual(view.frame.height, measured - 1)
        }
    }

    func testBlankNumberedPreviewLinesKeepTheSameHeightAsText() {
        func height(_ content: String) -> CGFloat {
            let input = ClaudeCodeJSON.object(["file_path": .string("/work/test.txt"), "content": .string(content)])
            let tool = AgentChatItem.ToolCall(toolUseId: "w", name: "Write", inputSummary: "", inputJSON: input.json(), status: .succeeded)
            let host = NSHostingController(rootView: AgentChatToolView(tool: tool, folder: URL(fileURLWithPath: "/work")))
            return host.sizeThatFits(in: NSSize(width: 600, height: 10000)).height
        }
        XCTAssertEqual(height("first\n\nthird"), height("first\nsecond\nthird"), accuracy: 1)
    }

    func testToolRowShowsFormattedSummaryWithoutRawInput() throws {
        let tool = AgentChatItem.ToolCall(toolUseId: "w", name: "Write", inputSummary: "/work/hello.txt",
            inputJSON: #"{"file_path":"/work/hello.txt","content":"Hello\n"}"#, status: .succeeded,
            output: "File created successfully at: /work/hello.txt (file state is current in your context — no need to Read it back)")
        let row = AgentChatToolView(tool: tool, folder: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(row.formatted.header.text, "Write(hello.txt)")
        XCTAssertEqual(row.formatted.summary.first?.text, "Wrote 1 line to hello.txt")
        // The row draws only these lines, so raw input or result text must not reach them.
        let shown = ([row.formatted.header] + row.formatted.summary + row.formatted.preview).map(\.text).joined(separator: "\n")
        XCTAssertFalse(shown.contains("file_path"))
        XCTAssertFalse(shown.contains("file state is current"))
        let host = ThemedHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        var running = tool
        running.status = .running
        let pending = AgentChatToolView(tool: running, folder: URL(fileURLWithPath: "/work"))
        XCTAssertTrue(pending.formatted.summary.isEmpty, "A running Write must not claim the file was written")
        XCTAssertTrue(pending.formatted.preview.isEmpty)
    }




    func testOneMessageStartsAtTopAndLongTranscriptFollowsBottom() throws {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "user", kind: .userMessage(text: "Hello", images: []))], status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        let content = try XCTUnwrap(document.subviews.first)
        XCTAssertTrue(document.isFlipped)
        // The rendered rows start below the stack's top padding.
        XCTAssertEqual(content.frame.minY, 16, accuracy: 1)
        XCTAssertLessThan(content.frame.height, scroll.contentSize.height / 2)
        XCTAssertEqual(document.bounds.height, scroll.contentSize.height, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)

        conversation.update(items: (0..<40).map { .init(id: String($0), kind: .userMessage(text: "Message \($0)", images: [])) }, status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.height, accuracy: 1)
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        conversation.update(items: conversation.items + [.init(id: "last", kind: .userMessage(text: "Last", images: []))], status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1, "Streaming should not pull a reader back down")
    }

    func testChatStripShowsRunningTaskCountsAndDescriptions() throws {
        let conversation = AgentConversation()
        let composer = AgentChatComposer()
        let settings = DrifterSettings(config: .init(folder: URL(fileURLWithPath: "/work")))
        composer.configure(settings: settings)
        composer.bind(conversation)
        let row = try XCTUnwrap(composer.browserLaunchRow)
        let tasks: [AgentBackgroundTask] = [.init(id: "s", kind: .shell, description: "Build"),
            .init(id: "m1", kind: .monitor, description: "Watch logs"), .init(id: "m2", kind: .monitor, description: "Watch tests")]
        conversation.update(items: [], status: .idle, backgroundTasks: tasks)
        row.frame = NSRect(x: 0, y: 0, width: 900, height: 28)
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.backgroundLabel.isHidden)
        XCTAssertEqual(row.backgroundLabel.stringValue, "1 shell · 2 monitors")
        XCTAssertNotNil(row.backgroundLabel.customTooltipRegistration)
        XCTAssertNil(row.backgroundLabel.toolTip)
        XCTAssertGreaterThan(row.backgroundLabel.frame.width, 0)
        XCTAssertTrue(row.bounds.contains(row.backgroundLabel.frame))
        let permission = try XCTUnwrap(row.subviews.compactMap { $0 as? NSButton }.first { $0.title == settings.config.confirmation.title })
        XCTAssertGreaterThan(row.backgroundLabel.frame.minX, permission.frame.maxX)
        let runningTool = AgentChatItem.ToolCall(toolUseId: "m", name: "Monitor", inputSummary: "Watch logs",
            inputJSON: #"{"description":"Watch logs","command":"tail -f log"}"#, background: .running)
        let toolRow = AgentChatToolView(tool: runningTool, folder: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(toolRow.formatted.header.text, "Monitor(Watch logs)")
        XCTAssertEqual(toolRow.formatted.summary.first?.text, "Running in the background")
        XCTAssertTrue(toolRow.formatted.preview.isEmpty)
        conversation.update(items: [], status: .running, backgroundTasks: tasks)
        XCTAssertFalse(composer.stopButton.isHidden)
        conversation.update(items: [], status: .idle)
        XCTAssertTrue(row.backgroundLabel.isHidden)
        XCTAssertNil(row.backgroundLabel.toolTip)

        let launch = MistDrifterLaunchRow(settings: DrifterSettings(config: .init()))
        launch.setBackgroundTasks(tasks)
        XCTAssertFalse(launch.backgroundLabel.isHidden)
    }

    func testPeerMessageExpansionUpdatesMeasuredHeight() throws {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "peer", kind: .peerMessage(name: "mist-3b", body: "# Update\n\n" + String(repeating: "A detailed message. ", count: 80)))], status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        let hosting = try XCTUnwrap(scroll.documentView?.subviews.first as? ThemedHostingView)
        let collapsed = hosting.frame.height
        let origin = scroll.contentView.bounds.origin
        scroll.viewState.expandedPeerMessages.insert("peer")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.frame.height, collapsed + 100)
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y, accuracy: 1)
        scroll.viewState.expandedPeerMessages.removeAll()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.height, collapsed, accuracy: 1)
    }

    /// The message's text view tracks the click in its own loop, which takes the mouse-up before the click monitor.
    func testPlainClickOnExpandedPeerMessageTextCollapsesIt() throws {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "peer", kind: .peerMessage(name: "mist-3b", body: "Done.\n\n" + String(repeating: "A detailed message. ", count: 20)))], status: .idle)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = AgentChatTranscriptScroll()
        window.contentView = scroll
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.viewState.expandedPeerMessages.insert("peer")
        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        let hosting = try XCTUnwrap(scroll.documentView?.subviews.first as? ThemedHostingView)
        hosting.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [AgentChatTextView] {
            view.subviews.flatMap { ($0 as? AgentChatTextView).map { [$0] } ?? textViews(in: $0) }
        }
        let text = try XCTUnwrap(textViews(in: hosting).first)
        let point = text.convert(NSPoint(x: 20, y: 12), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = try mouse(.leftMouseDown)
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        // The click monitor sees the press. An inactive test host's window only takes focus from it, so the text view
        // then gets the press as in a key window, and its tracking loop takes the queued release.
        NSApp.sendEvent(down)
        if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false) != nil {
            text.mouseDown(with: down)
        }
        let deadline = Date().addingTimeInterval(NSEvent.doubleClickInterval + 1)
        while !scroll.viewState.expandedPeerMessages.isEmpty, Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        XCTAssertTrue(scroll.viewState.expandedPeerMessages.isEmpty)
    }

    /// A selection made with the mouse, in a row's text view or SwiftUI's selectable text, is copied at release and cleared.
    func testMouseSelectionInTranscriptCopiesAndClearsIt() throws {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "reply", kind: .assistantText(text: "Copy **this** reply.", isStreaming: false)),
                                    .init(id: "notice", kind: .notice(text: "Copy this notice.", level: .info))], status: .idle)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = AgentChatTranscriptScroll()
        let pasteboard = NSPasteboard(name: .init("mist-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        scroll.copyPasteboard = pasteboard
        window.contentView = scroll
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        let hosting = try XCTUnwrap(scroll.documentView?.subviews.first as? ThemedHostingView)
        hosting.layoutSubtreeIfNeeded()
        func views(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
            view.subviews.flatMap { match($0) ? [$0] : views(in: $0, where: match) }
        }
        let text = try XCTUnwrap(views(in: hosting) { $0 is AgentChatTextView }.first as? AgentChatTextView)
        let label = try XCTUnwrap(views(in: hosting) { !($0 is NSTextView) && $0 is NSServicesMenuRequestor }.first)
        // The test host's window is never key, so a press only focuses it: the selection is set between press and release.
        func select(in view: NSView, _ select: () -> Void) throws -> String? {
            pasteboard.clearContents()
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            NSApp.sendEvent(try mouse(.leftMouseDown))
            select()
            NSApp.sendEvent(try mouse(.leftMouseUp))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return pasteboard.string(forType: .string)
        }
        XCTAssertTrue(scroll.copyToast.isHidden)
        XCTAssertEqual(try select(in: text) { text.setSelectedRange(NSRange(location: 5, length: 4)) }, "this")
        XCTAssertEqual(text.selectedRange().length, 0)
        XCTAssertFalse(scroll.copyToast.isHidden)
        XCTAssertEqual(scroll.copyToast.label.stringValue, AgentChatStrings.copiedCharacters(4))
        XCTAssertTrue(scroll.bounds.contains(scroll.copyToast.frame))
        XCTAssertEqual(try select(in: label) {
            window.makeFirstResponder(label)
            label.setAccessibilitySelectedTextRange(NSRange(location: 5, length: 4))
        }, "this")
        XCTAssertEqual(label.accessibilitySelectedTextRange().length, 0)
        // A plain click selects nothing and copies nothing.
        XCTAssertNil(try select(in: text) {})
    }

    func testCommandOutputExpansionUpdatesMeasuredHeight() throws {
        let conversation = AgentConversation()
        let text = (1...20).map { "Line \($0) with **bold** and `code`" }.joined(separator: "\n")
        conversation.update(items: [.init(id: "command", kind: .commandOutput(command: "usage", text: text, isError: false))], status: .idle)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        let hosting = try XCTUnwrap(scroll.documentView?.subviews.first as? ThemedHostingView)
        let collapsed = hosting.frame.height
        scroll.viewState.expandedTools.insert("command")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.frame.height, collapsed + 100)
        scroll.viewState.expandedTools.removeAll()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.height, collapsed, accuracy: 1)
    }

    func testBackgroundTaskMenuStopsOnlySelectedTask() throws {
        let row = MistDrifterLaunchRow(settings: DrifterSettings(config: .init(folder: URL(fileURLWithPath: "/work"))))
        var stopped: [String] = []
        row.setBackgroundTasks([.init(id: "a", kind: .task, description: "Research"), .init(id: "b", kind: .shell, description: "Build")], onStop: { stopped.append($0) })
        XCTAssertTrue(row.backgroundLabel.isHidden)
        XCTAssertFalse(row.backgroundButton.isHidden)
        let menu = row.backgroundMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Research", "Build"])
        let stop = try XCTUnwrap(menu.items[1].submenu?.items.first)
        XCTAssertEqual(stop.title, AgentChatStrings.stop)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stop.action), to: stop.target, from: stop))
        XCTAssertEqual(stopped, ["b"])
        row.setBackgroundTasks([])
        XCTAssertTrue(row.backgroundButton.isHidden)
    }

    func testScheduleMenuCancelsWithoutAnActiveAgent() throws {
        let row = MistDrifterLaunchRow(settings: DrifterSettings(config: .init(folder: URL(fileURLWithPath: "/work"))))
        let next = Date()
        let schedule = DrifterSchedule(id: "a1234567", title: "Daily report", prompt: "Check", timing: .at(next),
                                      target: .thisChat, owner: UUID(), createdAt: next, nextRun: next)
        var cancelled: [String] = []
        row.setSchedules([schedule], onCancel: { cancelled.append($0) })
        XCTAssertFalse(row.backgroundButton.isHidden)
        XCTAssertEqual(row.backgroundButton.title, AgentChatStrings.scheduleCount(1))
        let entry = try XCTUnwrap(row.backgroundMenu().items.first)
        XCTAssertTrue(entry.title.hasPrefix("Daily report · "))
        let cancel = try XCTUnwrap(entry.submenu?.items.first)
        XCTAssertEqual(cancel.title, AgentChatStrings.cancelSchedule)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(cancel.action), to: cancel.target, from: cancel))
        XCTAssertEqual(cancelled, [schedule.id])

        row.setBackgroundTasks([.init(id: "b", kind: .shell, description: "Build")])
        XCTAssertEqual(row.backgroundButton.title, "1 shell · " + AgentChatStrings.scheduleCount(1))
        let mixed = row.backgroundMenu().items
        XCTAssertEqual(mixed.first?.title, "Build")
        XCTAssertEqual(mixed.first?.submenu?.items.first?.isEnabled, false)
        XCTAssertTrue(mixed[1].isSeparatorItem)
        XCTAssertEqual(mixed.last?.title, entry.title)
    }

    func testNarrowLaunchRowFoldsBackgroundTasksIntoACircle() throws {
        let row = MistDrifterLaunchRow(settings: DrifterSettings(config: .init(folder: URL(fileURLWithPath: "/work"))))
        row.setBackgroundTasks([.init(id: "a", kind: .shell, description: "Build")], onStop: { _ in })
        row.frame = NSRect(x: 0, y: 0, width: 900, height: 28)
        row.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(row.backgroundButton.imagePosition, .imageOnly)
        XCTAssertGreaterThan(row.backgroundButton.frame.width, 28)

        // Just wide enough for model and effort beside the attach button, a folded confirmation and the background
        // circle, whatever the model's label: the catalog fills from the real CLI while the class runs.
        let chips = row.subviews.compactMap { $0 as? MistMenuButton }
        let model = try XCTUnwrap(chips.first { $0.symbolName == "cpu" })
        let effort = try XCTUnwrap(chips.first { $0.symbolName == "brain" })
        row.frame.size.width = 40 + 28 + 12 + 28 + 12 + model.frame.width + 12 + effort.frame.width
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.backgroundButton.imagePosition, .imageOnly)
        XCTAssertEqual(row.backgroundButton.frame.size, NSSize(width: 28, height: 28))
        let chipsAfter = row.subviews.compactMap { $0 as? MistMenuButton }.filter { $0.frame.minX > row.backgroundButton.frame.minX }
        XCTAssertFalse(chipsAfter.isEmpty)
        for chip in chipsAfter { XCTAssertLessThanOrEqual(row.backgroundButton.frame.maxX + 12, chip.frame.minX) }
    }

    func testNarrowLaunchRowFoldsModelAndEffortTogether() throws {
        let row = MistDrifterLaunchRow(settings: DrifterSettings(config: .init(folder: URL(fileURLWithPath: "/work"))))
        let chips = row.subviews.compactMap { $0 as? MistMenuButton }
        let model = try XCTUnwrap(chips.first { $0.symbolName == "cpu" })
        let effort = try XCTUnwrap(chips.first { $0.symbolName == "brain" })
        XCTAssertNotNil(model.customTooltipRegistration)
        XCTAssertNotNil(effort.customTooltipRegistration)
        row.setBackgroundTasks([.init(id: "a", kind: .shell, description: "Build")], onStop: { _ in })
        row.frame = NSRect(x: 0, y: 0, width: 900, height: 28)
        row.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(model.imagePosition, .imageOnly)
        XCTAssertNotEqual(effort.imagePosition, .imageOnly)
        XCTAssertEqual(model.frame.width, model.intrinsicContentSize.width)

        row.frame.size.width = 300
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.imagePosition, .imageOnly)
        XCTAssertEqual(effort.imagePosition, .imageOnly)
        XCTAssertEqual(model.frame.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(effort.frame.size, NSSize(width: 28, height: 28))
        XCTAssertLessThanOrEqual(row.backgroundButton.frame.maxX + 12, model.frame.minX)
    }

    func testWrappedTranscriptMeasuresAtViewportWidthAndReachesLastRow() throws {
        let conversation = AgentConversation()
        let longText = String(repeating: "Long wrapping text needs the actual viewport width to measure its full height. ", count: 8)
        var items: [AgentChatItem] = (0..<24).map { index in
            let kind: AgentChatItem.Kind
            switch index % 4 {
            case 0: kind = .userMessage(text: longText, images: [])
            case 1: kind = .toolCall(.init(toolUseId: "tool\(index)", name: "Bash", inputSummary: "failed",
                inputJSON: #"{"command":"failed"}"#, status: .failed, output: "<tool_use_error>\(longText)</tool_use_error>"))
            case 2: kind = .assistantText(text: longText + "\n\n" + longText, isStreaming: false)
            default: kind = .notice(text: longText, level: .error)
            }
            return .init(id: String(index), kind: kind)
        }
        let last = AgentChatItem(id: "last", kind: .userMessage(text: "Last row must be fully visible", images: []))
        items.append(last)
        conversation.update(items: items, status: .running)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 712, height: 500)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        for width in [CGFloat(712), 420] {
            scroll.setFrameSize(NSSize(width: width, height: 500))
            scroll.layoutSubtreeIfNeeded()
            scroll.finishMeasuring()
            let document = try XCTUnwrap(scroll.documentView)
            // A never-laid-out controller under-measures the assistant text views, so take the
            // height the rows settle at once laid out.
            final class Box { var height: CGFloat = 0 }
            let box = Box()
            let reference = ThemedHostingView(rootView: AgentChatTranscriptRows(conversation: conversation)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { box.height = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in box.height = height }
                }))
            reference.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 30_000)
            for _ in 0..<3 {
                reference.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let measured = CGSize(width: scroll.contentSize.width, height: box.height)
            XCTAssertGreaterThan(measured.height, 0)
            // The transcript renders only rows near the viewport, so check the fixture on the full reference tree.
            XCTAssertGreaterThan(abs(measured.height - reference.fittingSize.height), 200,
                "This fixture must exercise wrapping, not just a tall stack")
            XCTAssertEqual(scroll.contentHeight, measured.height, accuracy: 1)
            XCTAssertEqual(document.frame.height, measured.height, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.maxY, measured.height, accuracy: 1)

            // Derive the last row's bounds from its measured size and the stack's bottom padding.
            let lastHost = ThemedHostingView(rootView: AgentChatItemView(item: last, decide: { _, _ in }))
            let lastHeight = NSHostingController(rootView: lastHost.rootView)
                .sizeThatFits(in: NSSize(width: scroll.contentSize.width, height: 100_000)).height
            let lastFrame = NSRect(x: 0, y: measured.height - 16 - lastHeight,
                width: scroll.contentSize.width, height: lastHeight)
            XCTAssertGreaterThanOrEqual(lastFrame.minY, scroll.contentView.bounds.minY)
            XCTAssertLessThanOrEqual(lastFrame.maxY, scroll.contentView.bounds.maxY)
        }
    }

    func testMeasuredUserAndAssistantRowHeightsMatchTranscriptLayout() throws {
        let text = String(repeating: "Text that wraps across the transcript column. ", count: 20)
        let kinds: [AgentChatItem.Kind] = [
            .userMessage(text: text, images: []),
            .assistantText(text: "## Heading\n\n" + text + "\n\n**Details**\n\n" + text, isStreaming: false)
        ]
        for kind in kinds {
            let conversation = AgentConversation()
            conversation.update(items: [.init(id: "row", kind: kind)], status: .idle)
            let scroll = transcriptScroll(conversation)
            let heights = try XCTUnwrap(scroll.transcriptWindow?.heights)
            XCTAssertEqual(heights.count, 1)
            XCTAssertEqual(try XCTUnwrap(heights.first) + 32, referenceTranscriptHeight(conversation, scroll: scroll), accuracy: 1)
            XCTAssertEqual(scroll.contentHeight, referenceTranscriptHeight(conversation, scroll: scroll), accuracy: 1)
        }
    }

    private func longTranscript() -> AgentConversation {
        let conversation = AgentConversation()
        let text = String(repeating: "Wrapping transcript text exercises the actual viewport width. ", count: 8)
        let patch: ClaudeCodeJSON = .object([
            "oldStart": .number(1), "newStart": .number(1),
            "lines": .array([.string("-let value = 1"), .string("+let value = 2")])
        ])
        var items: [AgentChatItem] = []
        for turn in 0..<40 {
            items.append(.init(id: "user-\(turn)", kind: .userMessage(text: text, images: [])))
            items.append(.init(id: "assistant-\(turn)", kind: .assistantText(text: "## Result\n\n" + text + "\n\n**Details**\n\n" + text, isStreaming: false)))
            items.append(.init(id: "edit-item-\(turn)", kind: .toolCall(.init(toolUseId: "edit-\(turn)", name: "Edit", inputSummary: "file.swift",
                inputJSON: #"{"file_path":"/tmp/mist-fixture/file.swift","old_string":"let value = 1","new_string":"let value = 2"}"#,
                status: .succeeded, structuredResult: .object(["structuredPatch": .array([patch])])))))
            for tool in 0..<2 {
                items.append(.init(id: "shell-item-\(turn)-\(tool)", kind: .toolCall(.init(toolUseId: "shell-\(turn)-\(tool)", name: "Bash",
                    inputSummary: "seq 30", inputJSON: #"{"command":"seq 30"}"#, status: .succeeded,
                    output: (1...30).map { "line \($0)" }.joined(separator: "\n")))))
            }
            items.append(.init(id: "end-\(turn)", kind: .turnEnd(durationMilliseconds: 1000,
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn)))))
        }
        items.append(.init(id: "stream", kind: .assistantText(text: "Latest response", isStreaming: true)))
        conversation.update(items: items, status: .running)
        return conversation
    }

    private func transcriptScroll(_ conversation: AgentConversation, fullyMeasured: Bool = true) -> AgentChatTranscriptScroll {
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        if fullyMeasured { scroll.finishMeasuring() }
        return scroll
    }

    private func scrollTranscript(_ scroll: AgentChatTranscriptScroll, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
    }

    private func referenceTranscriptHeight(_ conversation: AgentConversation, scroll: AgentChatTranscriptScroll) -> CGFloat {
        final class Box { var height: CGFloat = 0 }
        let box = Box()
        let reference = ThemedHostingView(rootView: AgentChatTranscriptRows(conversation: conversation, viewState: scroll.viewState)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { box.height = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in box.height = height }
            }))
        reference.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 100_000)
        for _ in 0..<3 {
            reference.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(box.height, 0)
        return box.height
    }

    private func assertWindowCoversViewport(_ scroll: AgentChatTranscriptScroll, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(scroll.transcriptWindow, file: file, line: line)
        var top: CGFloat = 16
        for index in window.rows.indices {
            let bottom = top + window.heights[index]
            if bottom >= scroll.contentView.bounds.minY && top <= scroll.contentView.bounds.maxY {
                XCTAssertTrue(window.shown.contains(index), "Visible row \(index) must be rendered", file: file, line: line)
            }
            top = bottom
        }
    }

    func testLongTranscriptRendersOnlyRowsNearViewport() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = try XCTUnwrap(scroll.transcriptWindow)
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertTrue(bottom.shown.contains(bottom.rows.count - 1))
        let hosting = try XCTUnwrap(document.subviews.first as? ThemedHostingView)
        XCTAssertEqual(hosting.frame.maxY, document.frame.height - 16, accuracy: 1)
        XCTAssertLessThan(bottom.shown.count, bottom.rows.count / 2)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)
        let height = referenceTranscriptHeight(conversation, scroll: scroll)
        XCTAssertEqual(document.frame.height, height, accuracy: 1)
        try assertWindowCoversViewport(scroll)

        scrollTranscript(scroll, to: 0)
        let top = try XCTUnwrap(scroll.transcriptWindow)
        XCTAssertTrue(top.shown.contains(0))
        XCTAssertFalse(top.shown.contains(top.rows.count - 1))
        XCTAssertEqual(document.frame.height, height, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        try assertWindowCoversViewport(scroll)

        let middle = height / 2
        scrollTranscript(scroll, to: middle)
        XCTAssertEqual(scroll.contentView.bounds.minY, middle, accuracy: 1)
        XCTAssertEqual(document.frame.height, height, accuracy: 1)
        try assertWindowCoversViewport(scroll)
    }

    private func severalHundredRowTranscript() -> AgentConversation {
        let conversation = AgentConversation()
        conversation.update(items: (0..<400).map { index in
            let text = String(repeating: "A wrapped transcript row with several different heights. ", count: 1 + index % 12)
            return AgentChatItem(id: "row-\(index)", kind: index.isMultiple(of: 2)
                ? .userMessage(text: text, images: []) : .assistantText(text: text, isStreaming: false))
        }, status: .idle)
        return conversation
    }

    func testLongTranscriptOpensAtBottomWithoutMeasuringEveryRow() throws {
        let conversation = severalHundredRowTranscript()
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scroll.setContent(.init(conversation: conversation))
        let initiallyMeasured = scroll.lastMeasuredRowIDs
        scroll.layoutSubtreeIfNeeded()
        let window = try XCTUnwrap(scroll.transcriptWindow)
        XCTAssertFalse(initiallyMeasured.isEmpty)
        XCTAssertLessThan(initiallyMeasured.count, window.rows.count / 10)
        XCTAssertLessThan(scroll.lastMeasuredRowIDs.count, window.rows.count / 10)
        XCTAssertTrue(window.shown.contains(window.rows.count - 1))
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertEqual(scroll.contentView.bounds.maxY, try XCTUnwrap(scroll.documentView).frame.height, accuracy: 1)
        try assertWindowCoversViewport(scroll)
    }

    func testFinishingLazyMeasurementMatchesFullyMeasuredTranscript() throws {
        let conversation = severalHundredRowTranscript()
        let scroll = transcriptScroll(conversation, fullyMeasured: false)
        scroll.finishMeasuring()
        let reference = transcriptScroll(conversation)
        XCTAssertEqual(scroll.contentHeight, reference.contentHeight, accuracy: 1)
        XCTAssertEqual(scroll.transcriptWindow?.heights, reference.transcriptWindow?.heights)
        XCTAssertEqual(scroll.contentHeight, 32 + (try XCTUnwrap(scroll.transcriptWindow)).heights.reduce(0, +), accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.maxY, try XCTUnwrap(scroll.documentView).frame.height, accuracy: 1)
    }

    func testFinishingLazyMeasurementKeepsVisibleRowInPlaceDuringLiveScroll() throws {
        let scroll = transcriptScroll(severalHundredRowTranscript(), fullyMeasured: false)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        defer { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) }
        scrollTranscript(scroll, to: try XCTUnwrap(scroll.documentView).frame.height / 2)
        XCTAssertFalse(scroll.followsBottom)
        let before = try XCTUnwrap(scroll.transcriptWindow)
        var top: CGFloat = 16
        let index = try XCTUnwrap(before.rows.indices.first { index in
            defer { top += before.heights[index] }
            return top + before.heights[index] > scroll.contentView.bounds.minY
        })
        let offset = 16 + before.heights.prefix(index).reduce(0, +) - scroll.contentView.bounds.minY
        let slice = scroll.slice
        scroll.finishMeasuring()
        let after = try XCTUnwrap(scroll.transcriptWindow)
        let newTop = 16 + after.heights.prefix(index).reduce(0, +)
        XCTAssertEqual(newTop - scroll.contentView.bounds.minY, offset, accuracy: 1)
        XCTAssertEqual(scroll.slice, slice)
        XCTAssertFalse(scroll.followsBottom)
        try assertWindowCoversViewport(scroll)
    }

    func testLazyMarkerRevealCorrectsEstimatedRowTop() throws {
        let conversation = severalHundredRowTranscript()
        conversation.toggleMarker(itemId: "row-100", defaultName: "Earlier")
        conversation.toggleMarker(itemId: "row-250", defaultName: "Later")
        let scroll = transcriptScroll(conversation, fullyMeasured: false)
        for id in ["row-100", "row-250", "row-100"] {
            scroll.revealMarker(id)
            let window = try XCTUnwrap(scroll.transcriptWindow)
            let index = try XCTUnwrap(window.rows.firstIndex { $0.id == id })
            let top = 16 + window.heights.prefix(index).reduce(0, +)
                + AgentChatTranscriptRows.spacing(before: window.rows[index], after: window.rows[index - 1])
            XCTAssertEqual(top - scroll.contentView.bounds.minY, 24, accuracy: 1)
            XCTAssertTrue(window.shown.contains(index))
            try assertWindowCoversViewport(scroll)
        }
    }

    func testWidthAndZoomChangesKeepOffscreenHeightsAsEstimates() throws {
        let conversation = severalHundredRowTranscript()
        let scroll = transcriptScroll(conversation)
        let oldFirstHeight = try XCTUnwrap(scroll.transcriptWindow?.heights.first)
        scroll.frame.size.width = 360
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.transcriptWindow?.heights.first, oldFirstHeight)
        XCTAssertLessThan(scroll.lastMeasuredRowIDs.count, 40)
        scroll.finishMeasuring()
        let narrowFirstHeight = try XCTUnwrap(scroll.transcriptWindow?.heights.first)
        XCTAssertGreaterThan(narrowFirstHeight, oldFirstHeight)
        scroll.textScale = 1.5
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.transcriptWindow?.heights.first, narrowFirstHeight)
        XCTAssertLessThan(scroll.lastMeasuredRowIDs.count, 40)
        scroll.finishMeasuring()
        let reference = transcriptScroll(conversation, fullyMeasured: false)
        reference.frame.size.width = 360
        reference.textScale = 1.5
        reference.layoutSubtreeIfNeeded()
        reference.finishMeasuring()
        XCTAssertEqual(scroll.contentHeight, reference.contentHeight, accuracy: 1)
    }

    func testFindSearchIncludesNeverMeasuredRowsAndRevealsMatch() throws {
        let conversation = severalHundredRowTranscript()
        var items = conversation.items
        items[100].kind = .userMessage(text: "Unique search target", images: [])
        conversation.update(items: items, status: .idle)
        let scroll = transcriptScroll(conversation, fullyMeasured: false)
        var total = 0
        scroll.onFindChange = { _, count in total = count }
        scroll.setFindQuery("Unique search target")
        scroll.findSearch(from: .visible)
        XCTAssertEqual(total, 1)
        let window = try XCTUnwrap(scroll.transcriptWindow)
        let index = try XCTUnwrap(window.rows.firstIndex { $0.id == "row-100" })
        let top = 16 + window.heights.prefix(index).reduce(0, +)
        let rect = NSRect(x: 0, y: top, width: scroll.contentSize.width, height: window.heights[index])
        XCTAssertTrue(window.shown.contains(index))
        XCTAssertTrue(rect.intersects(scroll.contentView.bounds))
        try assertWindowCoversViewport(scroll)
    }

    func testOffscreenStreamingKeepsMountedSliceAndFrame() throws {
        let conversation = longTranscript()
        var items = conversation.items
        items.append(.init(id: "stream", kind: .assistantText(text: "Start", isStreaming: true)))
        conversation.update(items: items, status: .running)
        let scroll = transcriptScroll(conversation)
        scrollTranscript(scroll, to: 0)
        let document = try XCTUnwrap(scroll.documentView)
        let hosting = try XCTUnwrap(document.subviews.first as? ThemedHostingView)
        let frame = hosting.frame
        let slice = scroll.slice
        let height = document.frame.height
        let oldRowHeight = try XCTUnwrap(scroll.transcriptWindow?.heights.last)
        items[items.count - 1].kind = .assistantText(text: String(repeating: "A long streaming line of text. ", count: 100), isStreaming: true)
        conversation.update(items: items, status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        scroll.finishMeasuring()
        let growth = try XCTUnwrap(scroll.transcriptWindow?.heights.last) - oldRowHeight
        XCTAssertGreaterThan(growth, 0)
        XCTAssertEqual(hosting.frame, frame)
        XCTAssertEqual(scroll.slice, slice)
        XCTAssertEqual(document.frame.height, height + growth, accuracy: 1)
    }

    func testStreamingReplySharesRenderingWithLiveRow() throws {
        let conversation = AgentConversation()
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        func textViews(_ view: NSView) -> [AgentChatTextView] {
            (view as? AgentChatTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        var rendering: AgentChatRichTextRendering?
        for text in ["First reply", "First reply with more **streamed text**"] {
            conversation.update(items: [.init(id: "reply", kind: .assistantText(text: text, isStreaming: true))], status: .running)
            scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
            scroll.layoutSubtreeIfNeeded()
            let shared = try XCTUnwrap(scroll.renderings.rendering(for: "reply"))
            if let rendering { XCTAssertTrue(shared === rendering) }
            rendering = shared
            let host = try XCTUnwrap(scroll.documentView?.subviews.first as? ThemedHostingView)
            host.layoutSubtreeIfNeeded()
            let live = try XCTUnwrap(textViews(host).first { $0.string == shared.rendered?.string })
            XCTAssertEqual(shared.rendered?.string, live.string)
        }
    }

    func testWideningWhileScrolledUpKeepsRowsInTheViewport() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        scroll.frame.size.width = 320
        scroll.layoutSubtreeIfNeeded()
        scroll.finishMeasuring()
        let document = try XCTUnwrap(scroll.documentView)
        scrollTranscript(scroll, to: document.frame.height - scroll.contentSize.height - 300)
        XCTAssertFalse(scroll.followsBottom)
        scroll.frame.size.width = 1400
        scroll.layoutSubtreeIfNeeded()
        scroll.finishMeasuring()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)
        XCTAssertTrue(scroll.followsBottom)
        XCTAssertTrue(scroll.jumpButton.isHidden)
        try assertWindowCoversViewport(scroll)
    }

    func testStreamingIntoWindowedTranscriptKeepsReaderInPlace() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        scrollTranscript(scroll, to: try XCTUnwrap(scroll.documentView).frame.height / 2)
        let origin = scroll.contentView.bounds.origin
        let shown = try XCTUnwrap(scroll.transcriptWindow).shown
        XCTAssertFalse(scroll.followsBottom)
        var items = conversation.items
        items[items.count - 1].kind = .assistantText(text: String(repeating: "More streaming text. ", count: 80), isStreaming: false)
        items.append(.init(id: "next-user", kind: .userMessage(text: "Continue", images: [])))
        items.append(.init(id: "next-assistant", kind: .assistantText(text: "Continuing", isStreaming: true)))
        conversation.update(items: items, status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y, accuracy: 1)
        XCTAssertEqual(scroll.transcriptWindow?.shown, shown)
        try assertWindowCoversViewport(scroll)
        scroll.finishMeasuring()
        XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, referenceTranscriptHeight(conversation, scroll: scroll), accuracy: 1)
    }

    func testUpdatesCarryAnOverscrollPastTheBottomAlong() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = document.frame.height - scroll.contentSize.height
        // Elastic scrolling moves the clip view past the bottom, as scroll(to:) does without clamping.
        scrollTranscript(scroll, to: bottom + 40)
        XCTAssertTrue(scroll.followsBottom)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom + 40, accuracy: 1)

        conversation.update(items: conversation.items + [.init(id: "next-user", kind: .userMessage(text: String(repeating: "Taller than the overscroll. ", count: 40), images: []))],
                            status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(document.frame.height - scroll.contentSize.height, bottom + 40)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height + 40, accuracy: 1)
    }

    func testALiveScrollEndingAtTheBottomBeforeTheLatestUpdateKeepsFollowing() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = document.frame.height - scroll.contentSize.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        conversation.update(items: conversation.items + [.init(id: "next-user", kind: .userMessage(text: String(repeating: "Streamed during the bounce. ", count: 40), images: []))],
                            status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        let growth = document.frame.height - scroll.contentSize.height - bottom
        XCTAssertGreaterThan(growth, 24)
        // AppKit ends the live scroll at the bottom it knew before the update.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        XCTAssertTrue(scroll.followsBottom)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scrollTranscript(scroll, to: bottom - 100)
        XCTAssertFalse(scroll.followsBottom)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    func testAShortLiveScrollUpStopsFollowingAndStaysPut() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = document.frame.height - scroll.contentSize.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scrollTranscript(scroll, to: bottom - 8)
        XCTAssertFalse(scroll.followsBottom)
        XCTAssertFalse(scroll.jumpButton.isHidden)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom - 8, accuracy: 1)
    }

    func testABounceFromPastTheBottomDuringGrowthKeepsFollowing() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let document = try XCTUnwrap(scroll.documentView)
        let bottom = document.frame.height - scroll.contentSize.height
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scrollTranscript(scroll, to: bottom + 40)
        conversation.update(items: conversation.items + [.init(id: "next-user", kind: .userMessage(text: String(repeating: "Streamed during the bounce. ", count: 40), images: []))],
                            status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        XCTAssertGreaterThan(document.frame.height - scroll.contentSize.height - bottom, 24)
        // AppKit's bounce re-derives the position from the bottom it knew before the update.
        scrollTranscript(scroll, to: bottom + 20)
        XCTAssertTrue(scroll.followsBottom)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.height, accuracy: 1)
    }

    func testRunningAgentUpdatesApplyAnIntervalApart() {
        let conversation = AgentConversation()
        conversation.update(items: [.init(id: "user", kind: .userMessage(text: "Hello", images: []))], status: .running)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scroll.updateContent(AgentChatTranscriptRows(conversation: conversation))
        XCTAssertEqual(scroll.transcriptWindow?.rows.count, 1)
        conversation.update(items: conversation.items + [.init(id: "reply", kind: .assistantText(text: "Hi", isStreaming: true))], status: .running)
        scroll.updateContent(AgentChatTranscriptRows(conversation: conversation))
        XCTAssertEqual(scroll.transcriptWindow?.rows.count, 1, "The next streamed update waits for the interval")
        RunLoop.main.run(until: Date().addingTimeInterval(AgentChatTranscriptScroll.runningUpdateInterval + 0.1))
        XCTAssertEqual(scroll.transcriptWindow?.rows.count, 2)
        conversation.update(items: conversation.items + [.init(id: "next", kind: .userMessage(text: "Thanks", images: []))], status: .idle)
        scroll.updateContent(AgentChatTranscriptRows(conversation: conversation))
        XCTAssertEqual(scroll.transcriptWindow?.rows.count, 3, "Updates apply at once when the agent isn't running")
    }

    func testStreamedTextKeepsTheLayoutBeforeItsChange() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let font = NSFont.systemFont(ofSize: 13)
        let text = NSAttributedString(string: (1...200).map { "Line \($0)" }.joined(separator: "\n"), attributes: [.font: font])
        storage.apply(text, over: nil)
        XCTAssertTrue(storage.isEqual(to: text))
        manager.ensureLayout(for: container)
        let grown = NSMutableAttributedString(attributedString: text)
        grown.append(NSAttributedString(string: " and more\nLine 201", attributes: [.font: font]))
        storage.apply(grown, over: text)
        XCTAssertTrue(storage.isEqual(to: grown))
        XCTAssertGreaterThan(manager.firstUnlaidCharacterIndex(), text.length / 2)
        // A closing fence or a heading underline restyles earlier text, which is replaced from its first restyled character.
        let restyled = NSMutableAttributedString(attributedString: grown)
        restyled.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 4))
        restyled.append(NSAttributedString(string: "!", attributes: [.font: font]))
        storage.apply(restyled, over: grown)
        XCTAssertTrue(storage.isEqual(to: restyled))
    }

    func testStreamedMarkdownKeepsEarlierLayout() {
        final class EditObserver: NSObject, NSTextStorageDelegate {
            var editedRange: NSRange?
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range editedRange: NSRange, changeInLength delta: Int) {
                self.editedRange = editedRange
            }
        }
        let renderer = MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .boldSystemFont(ofSize: 20),
            nsFontSubheading: .boldSystemFont(ofSize: 17), nsFontSmall: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textNS: .labelColor, dimNS: .secondaryLabelColor)
        // TextKit lays out a text block again whole when its content changes, so a streaming code block
        // keeps only the layout above it.
        for (source, kept) in [(String(repeating: "plain words\n", count: 100) + "\n```swift\n" + String(repeating: "line\n", count: 100), "swift"),
                               ("```swift\ncode\n```\n\n> quote\n\n| a | b |\n|---|---|\n\n" + String(repeating: "plain words\n", count: 100), "plain")] {
            let cache = MarkdownRenderCache()
            let old = renderer.markdownRuns(source, color: .labelColor, cache: cache)
            let storage = NSTextStorage(attributedString: old)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let new = renderer.markdownRuns(source + "more", color: .labelColor, cache: cache)
            let observer = EditObserver()
            storage.delegate = observer
            storage.apply(new, over: old)
            XCTAssertGreaterThan(observer.editedRange?.location ?? 0, old.length / 2)
            XCTAssertGreaterThanOrEqual(manager.firstUnlaidCharacterIndex(), (old.string as NSString).range(of: kept).location)
            XCTAssertTrue(storage.isEqual(to: new))
        }
    }

    func testClosingCodeSpanEditsFromTheCharacterItKerns() {
        final class EditObserver: NSObject, NSTextStorageDelegate {
            var editedRange: NSRange?
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range editedRange: NSRange, changeInLength delta: Int) {
                self.editedRange = editedRange
            }
        }
        let renderer = MarkdownRenderer(nsFont: .systemFont(ofSize: 14), nsFontHeading: .boldSystemFont(ofSize: 20),
            nsFontSubheading: .boldSystemFont(ofSize: 17), nsFontSmall: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textNS: .labelColor, dimNS: .secondaryLabelColor)
        let source = String(repeating: "plain words\n\n", count: 50) + "Same pattern, question `has_ta"
        let cache = MarkdownRenderCache()
        let old = renderer.markdownRuns(source, color: .labelColor, cache: cache)
        let storage = NSTextStorage(attributedString: old)
        let new = renderer.markdownRuns(source + "sk`", color: .labelColor, cache: cache)
        let observer = EditObserver()
        storage.delegate = observer
        storage.apply(new, over: old)
        // The space before the pill gains its kerning, so the edit starts there rather than rewriting the whole reply.
        let space = (new.string as NSString).range(of: "question ").location + 8
        XCTAssertEqual(new.attribute(.kern, at: space, effectiveRange: nil) as? CGFloat, MarkdownRenderer.inlineCodeInset)
        XCTAssertEqual(observer.editedRange?.location, space)
        XCTAssertTrue(storage.isEqual(to: new))
    }

    func testStreamingUpdatesHeightsAndExpansion() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let before = try XCTUnwrap(scroll.transcriptWindow)
        var items = conversation.items
        items[items.count - 1].kind = .assistantText(text: String(repeating: "more streaming text ", count: 200), isStreaming: true)
        conversation.update(items: items, status: .running)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        let after = try XCTUnwrap(scroll.transcriptWindow)
        XCTAssertEqual(Array(before.heights.dropLast()), Array(after.heights.dropLast()))
        XCTAssertGreaterThan(try XCTUnwrap(after.heights.last), try XCTUnwrap(before.heights.last))
        let index = try XCTUnwrap(after.rows.indices.first { if case .toolGroup = after.rows[$0] { return true }; return false })
        scroll.viewState.expandedToolGroups.insert(after.rows[index].id)
        scroll.layoutSubtreeIfNeeded()
        scroll.finishMeasuring()
        XCTAssertGreaterThan(try XCTUnwrap(scroll.transcriptWindow).heights[index], after.heights[index])
    }

    func testExpandingRowInsideWindowKeepsItInPlace() throws {
        let conversation = longTranscript()
        let scroll = transcriptScroll(conversation)
        let initial = try XCTUnwrap(scroll.transcriptWindow)
        let index = try XCTUnwrap(initial.rows.indices.first { index in
            if case .toolGroup = initial.rows[index] { return index >= initial.rows.count / 2 }
            return false
        })
        let top = 16 + initial.heights.prefix(index).reduce(0, +)
        scrollTranscript(scroll, to: top - 100)
        let before = try XCTUnwrap(scroll.transcriptWindow)
        XCTAssertTrue(before.shown.contains(index))
        let origin = scroll.contentView.bounds.origin
        let height = try XCTUnwrap(scroll.documentView).frame.height
        scroll.viewState.expandedToolGroups.insert(before.rows[index].id)
        scroll.layoutSubtreeIfNeeded()
        let after = try XCTUnwrap(scroll.transcriptWindow)
        let growth = after.heights[index] - before.heights[index]
        XCTAssertGreaterThan(growth, 0)
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, height + growth, accuracy: 1)
        try assertWindowCoversViewport(scroll)
    }

    func testExpandedToolOutputAndPlanFeedbackResizeTranscript() throws {
        let conversation = AgentConversation()
        conversation.update(items: [
            .init(id: "t", kind: .toolCall(.init(toolUseId: "t", name: "Bash", inputSummary: "seq 30", inputJSON: #"{"command":"seq 30"}"#,
                status: .succeeded, output: (1...30).map { "line \($0)" }.joined(separator: "\n")))),
            .init(id: "p", kind: .permissionRequest(.init(requestId: "p", toolName: "ExitPlanMode", summary: "", input: .object(["plan": .string("Plan")])))),
        ], status: .awaitingPermission)
        let scroll = AgentChatTranscriptScroll()
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        scroll.setContent(AgentChatTranscriptRows(conversation: conversation))
        scroll.layoutSubtreeIfNeeded()
        let collapsed = scroll.contentHeight

        let origin = scroll.contentView.bounds.origin
        // The row measurer renders its own copy of each row, so these must change both copies' heights.
        scroll.viewState.expandedToolGroups.insert("t")
        scroll.viewState.expandedTools.insert("t")
        scroll.layoutSubtreeIfNeeded()
        let expanded = scroll.contentHeight
        XCTAssertGreaterThan(expanded, collapsed + 200, "Twenty more output lines must enlarge the transcript")
        let reference = ThemedHostingView(rootView: AgentChatTranscriptRows(conversation: conversation, viewState: scroll.viewState))
        XCTAssertEqual(expanded, reference.fittingSize.height, accuracy: 1, "Unwrapped rows: the full tree's ideal height is exact")
        scroll.viewState.planFeedbackOpen.insert("p")
        scroll.layoutSubtreeIfNeeded()
        // The expanded output pushed the plan row out of the rendered window, where its height stays an estimate.
        scroll.finishMeasuring()
        XCTAssertGreaterThan(scroll.contentHeight, expanded + 40, "The feedback field and its button must enlarge the transcript")
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y, accuracy: 1, "Expansions open downward without moving the clicked row")

        scroll.viewState.expandedTools.removeAll()
        scroll.viewState.expandedToolGroups.removeAll()
        scroll.viewState.planFeedbackOpen.removeAll()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentHeight, collapsed, accuracy: 1)
    }

    func testUserBubbleHasVisibleNeutralFillInBothAppearances() {
        let theme = ThemeManager.shared.currentTheme
        for appearance in [Appearance.light, .dark] {
            let fill = ThemedColor.mistChipFill.resolve(theme: theme, appearance: appearance)
            XCTAssertEqual(fill, theme.color(for: .separator, appearance: appearance))
            XCTAssertNotEqual(fill, ThemedColor.contentOverlayBackground.resolve(theme: theme, appearance: appearance))
            XCTAssertNotEqual(fill, theme.color(for: .windowBackground, appearance: appearance))
        }
    }

    func testReplyEditorAndActionsLiveInsideSharedComposerCard() {
        let composer = AgentChatComposer()
        composer.frame = NSRect(x: 0, y: 0, width: 700, height: composer.intrinsicContentSize.height)
        composer.layoutSubtreeIfNeeded()
        XCTAssertTrue(composer.card.superview === composer)
        XCTAssertTrue(composer.editor.superview is MistComposerCard)
        XCTAssertTrue(composer.strip.superview === composer.card)
        XCTAssertTrue(composer.sendButton.superview === composer.card)
        XCTAssertEqual(composer.card.layer?.cornerRadius, 20)
        XCTAssertEqual(composer.card.layer?.borderWidth, 0)
        XCTAssertTrue(composer.card.subviews.first is MistCardView)
        XCTAssertEqual(composer.sendButton.frame.size, NSSize(width: 32, height: 32))
        XCTAssertEqual(composer.sendButton.layer?.cornerRadius, 16)
        XCTAssertTrue(composer.stopButton.superview === composer.card)
        XCTAssertTrue(composer.stopButton.isHidden)
        XCTAssertEqual(composer.stopButton.frame.size, composer.sendButton.frame.size)
        XCTAssertEqual(composer.stopButton.frame.minY, composer.sendButton.frame.minY)
        XCTAssertEqual(composer.sendButton.frame.minX - composer.stopButton.frame.maxX, 8)
        XCTAssertEqual(composer.stopButton.layer?.cornerRadius, 16)
        XCTAssertEqual(composer.editor.textView.font?.pointSize, 16)
    }

    func testComposerThumbnailCroppingSpacingAndPreviewAction() throws {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .idle)
        let composer = AgentChatComposer()
        composer.bind(conversation)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try XCTUnwrap(image.representation(using: .png, properties: [:])), forType: .png)
        XCTAssertTrue(composer.addAttachments(from: pasteboard))
        XCTAssertTrue(composer.addAttachments(from: pasteboard))
        var opened: AgentAttachment?
        conversation.onOpenAttachment = { opened = $0 }
        composer.frame = NSRect(x: 0, y: 0, width: 700, height: composer.intrinsicContentSize.height)
        composer.layoutSubtreeIfNeeded()
        XCTAssertEqual(composer.strip.frame.minX, 46)
        XCTAssertEqual(composer.card.bounds.maxY - composer.strip.frame.maxY, 14)
        let thumbnails = try XCTUnwrap(composer.strip.documentView).subviews
        XCTAssertEqual(thumbnails.map(\.frame.size), [NSSize(width: 56, height: 56), NSSize(width: 56, height: 56)])
        XCTAssertEqual(thumbnails[1].frame.minX - thumbnails[0].frame.maxX, 8)
        XCTAssertEqual(thumbnails[0].layer?.contentsGravity, .resizeAspectFill)
        XCTAssertEqual(thumbnails[0].layer?.cornerRadius, MistKit.Radius.innerCard)
        XCTAssertTrue(thumbnails[0].accessibilityPerformPress())
        XCTAssertEqual(opened, composer.attachments[0])
    }


    func testRendersEveryItemAndWiresConversationActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentChatStore(route: .init(baseDirectory: directory), tabExists: { _ in true }, browserSessionFactory: { _, _, _ in NSObject() })
        let conversation = try store.create(request: .init(prompt: "Hello", attachments: [], config: .init(folder: directory), windowId: 1), tabId: 1)
        defer { store.terminate() }
        let items: [AgentChatItem.Kind] = [
            .userMessage(text: "Hello", images: []), .assistantText(text: "# Hi\n**Hello**", isStreaming: true),
            .toolCall(.init(toolUseId: "t", name: "Bash", inputSummary: "pwd", inputJSON: "{\"command\":\"pwd\"}")),
            .permissionRequest(.init(requestId: "p", toolName: "Bash", summary: "pwd")),
            .notice(text: "Info", level: .info), .notice(text: "Error", level: .error), .turnEnd(durationMilliseconds: 12000, finishedAt: Date()),
            .commandOutput(command: "model", text: "Set model to **Sonnet**", isError: false),
            .contextUsage(ClaudeCodeContextUsage(.object(["total_tokens": .number(100), "raw_max_tokens": .number(1000),
                "percentage": .number(10), "categories": .array([.object(["name": .string("System"), "tokens": .number(100), "kind": .string("used")])])]))),
            .compaction(trigger: .manual, preTokens: 44111, postTokens: 12481),
            .compaction(trigger: .auto, preTokens: nil, postTokens: nil),
        ]
        conversation.update(items: items.enumerated().map { .init(id: String($0.offset), kind: $0.element) }, status: .idle)
        let controller = AgentChatViewController(store: store)
        controller.show(conversation.id)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.conversation === conversation)
        let rows = AgentChatTranscriptRows(conversation: conversation)
        for item in conversation.items {
            let host = ThemedHostingView(rootView: AgentChatItemView(item: item, decide: rows.decidePermission))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        var decisions: [(String, AgentPermissionResponse)] = []
        conversation.onPermissionDecision = { decisions.append(($0, $1)) }
        rows.decidePermission("p", .allow)
        rows.decidePermission("p", .deny(message: nil))
        XCTAssertEqual(decisions.map(\.0), ["p", "p"])
        XCTAssertEqual(decisions.map(\.1), [.allow, .deny(message: nil)])

        var sent: [(String, [AgentAttachment])] = []
        conversation.onSend = { text, images, _ in sent.append((text, images)) }
        controller.composer.editor.text = "Reply"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        pasteboard.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        XCTAssertTrue(controller.composer.addAttachments(from: pasteboard))
        controller.composer.editor.textView.onSubmit?()
        XCTAssertEqual(sent.map(\.0), ["Reply"])
        XCTAssertEqual(sent.first?.1.count, 1)
        XCTAssertEqual(controller.composer.editor.text, "")
        XCTAssertTrue(controller.composer.attachments.isEmpty)

        var stops = 0
        var queued: [(String, [AgentAttachment], [AgentTabMention])] = []
        conversation.onQueue = { queued.append(($0, $1, $2)) }
        conversation.onStop = { stops += 1 }
        for status in [AgentConversationStatus.running, .awaitingPermission] {
            conversation.update(items: conversation.items, status: status)
            controller.composer.editor.text = "Queued"
            XCTAssertTrue(controller.composer.addAttachments(from: pasteboard))
            controller.composer.editor.textView.onSubmit?()
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(controller.composer.editor.text, "")
            XCTAssertTrue(controller.composer.attachments.isEmpty)
            XCTAssertEqual(queued.last?.0, "Queued")
            XCTAssertEqual(queued.last?.1.count, 1)
            XCTAssertEqual(controller.composer.sendButton.accessibilityLabel(), AgentChatStrings.send)
            XCTAssertFalse(controller.composer.sendButton.isEnabled)
            XCTAssertFalse(controller.composer.stopButton.isHidden)
            controller.composer.editor.text = "Clicked"
            XCTAssertTrue(controller.composer.sendButton.isEnabled)
            controller.composer.sendButton.performClick(nil)
            XCTAssertEqual(queued.last?.0, "Clicked")
            controller.composer.stopButton.performClick(nil)
        }
        XCTAssertEqual(queued.count, 4)
        XCTAssertEqual(stops, 2)
        conversation.update(items: conversation.items, status: .idle)
        XCTAssertTrue(controller.composer.stopButton.isHidden)
        conversation.update(items: conversation.items, status: .ended)
        XCTAssertFalse(controller.composer.editor.textView.isEditable)
        XCTAssertFalse(controller.composer.sendButton.isEnabled)
        var restarts: [(String, [AgentAttachment])] = []
        conversation.onRestart = { message in
            restarts.append((message.text, message.attachments))
            conversation.update(items: conversation.items, status: .starting)
        }
        conversation.update(items: conversation.items, status: .failed("Process exited"))
        XCTAssertTrue(controller.composer.editor.textView.isEditable)
        XCTAssertFalse(controller.composer.sendButton.isEnabled)
        controller.composer.editor.text = "Again"
        XCTAssertTrue(controller.composer.addAttachments(from: pasteboard))
        controller.composer.editor.textView.onSubmit?()
        XCTAssertEqual(restarts.map(\.0), ["Again"])
        XCTAssertEqual(restarts.first?.1.count, 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(controller.composer.editor.text, "")
        // A relaunch that dies before taking the message puts it back.
        conversation.update(items: conversation.items, status: .failed("Process exited again"))
        XCTAssertEqual(controller.composer.editor.text, "Again")
        XCTAssertEqual(controller.composer.attachments.count, 1)
        XCTAssertEqual(conversation.draft.text, "Again")
        XCTAssertTrue(controller.composer.sendButton.isEnabled)
        controller.composer.editor.textView.onSubmit?()
        conversation.update(items: conversation.items, status: .running)
        conversation.update(items: conversation.items, status: .failed("Process exited after taking it"))
        XCTAssertEqual(restarts.count, 2)
        XCTAssertEqual(controller.composer.editor.text, "")
        XCTAssertTrue(controller.composer.attachments.isEmpty)
        controller.show(UUID())
        XCTAssertNil(controller.conversation)
        XCTAssertFalse(controller.view.subviews.isEmpty)
    }

    @MainActor
    func testQueueEditPrependsDraftImagesAndStyledMentions() throws {
        let conversation = AgentConversation()
        conversation.update(items: [], status: .running)
        let composer = AgentChatComposer()
        composer.bind(conversation)
        composer.editor.mentionsEnabled = true
        let other = AgentChatComposer()
        other.editor.mentionsEnabled = true
        other.bind(conversation)
        let draft = AgentTabMention(tabId: 2, title: "Draft", url: "https://example.com/draft", range: NSRange(location: 0, length: 6))
        composer.editor.setText("@Draft text", mentions: [draft])
        let mention = AgentTabMention(tabId: 1, title: "Queue", url: "https://example.com/queue", range: NSRange(location: 3, length: 6))
        let image = AgentImageAttachment(data: Data([1]), mediaType: "image/png")
        let message = AgentQueuedMessage(text: "😀 @Queue", attachments: [.image(image)], mentions: [mention])
        var queue = AgentMessageQueue()
        queue.enqueue(message)
        conversation.updateQueue(queue)
        var removed: [String] = []
        conversation.onRemoveQueued = { removed.append($0); queue.remove($0); conversation.updateQueue(queue) }
        composer.editQueued(message)
        XCTAssertEqual(removed, [message.id])
        XCTAssertEqual(composer.editor.text, "😀 @Queue\n@Draft text")
        XCTAssertEqual(other.editor.text, composer.editor.text)
        XCTAssertEqual(other.attachments, [.image(image)])
        XCTAssertEqual(conversation.draft.text, composer.editor.text)
        XCTAssertEqual(composer.editor.mentions.map(\.tabId), [1, 2])
        XCTAssertEqual(composer.editor.mentions.map(\.range), [mention.range, NSRange(location: 10, length: 6)])
        XCTAssertEqual(composer.attachments, [.image(image)])
        XCTAssertNotNil(composer.editor.textView.textStorage?.attribute(AgentChatMentionStyle.token, at: 3, effectiveRange: nil))

        let secondImage = AgentImageAttachment(data: Data([2]), mediaType: "image/png")
        let next = AgentQueuedMessage(text: "More", attachments: Array(repeating: .image(secondImage), count: 10))
        queue.enqueue(next)
        conversation.updateQueue(queue)
        composer.editQueued(next)
        XCTAssertEqual(composer.attachments, Array(repeating: .image(secondImage), count: 10))
        XCTAssertEqual(composer.editor.text, "More\n😀 @Queue\n@Draft text")

        queue.enqueue(message)
        queue.markDelivering(message.id)
        conversation.updateQueue(queue)
        composer.editQueued(message)
        XCTAssertEqual(removed.count, 2)
    }
}
