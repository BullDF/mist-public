import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor final class ClipboardPageTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var source: MistClipboardSyncSource!
    private var syncSetUp: CurrentValueSubject<Bool, Never>!
    private var model: ClipboardPageModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        source = MistClipboardSyncSource(directory: directory, slot: { "test-slot" }, timersEnabled: false,
                                         defaults: makeTestDefaults().defaults)
        source.onChange = { _ in }
        syncSetUp = CurrentValueSubject(false)
        model = ClipboardPageModel(source: source, syncSetUp: syncSetUp.eraseToAnyPublisher(), pasteboard: pasteboard,
                                   downloadsFolder: directory.appendingPathComponent("Downloads", isDirectory: true))
    }

    override func tearDownWithError() throws {
        model.disappear()
        model = nil; source = nil; syncSetUp = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testStateFollowsSyncSetupAndSharing() {
        XCTAssertEqual(model.state, .notSetUp)
        source.setSharing(false)
        XCTAssertEqual(model.state, .notSetUp)
        syncSetUp.send(true)
        XCTAssertEqual(model.state, .sharingOff)
        source.setSharing(true)
        XCTAssertEqual(model.state, .box)
        syncSetUp.send(false)
        XCTAssertEqual(model.state, .notSetUp)
    }

    func testChosenFileStagesAndSends() throws {
        syncSetUp.send(true)
        let folder = directory.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data("chosen file".utf8).write(to: file)
        pasteboard.setString("staged first", forType: .string)
        model.paste()
        XCTAssertEqual(model.draft?.type, .text)
        XCTAssertTrue(model.canChooseFile)
        model.stage(file: file)
        XCTAssertFalse(model.staging)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.draft?.type, .file)
        XCTAssertEqual(model.draft?.name, "notes.txt")
        model.send()
        XCTAssertNil(model.error)
        XCTAssertNil(model.draft)
        XCTAssertEqual(source.current?.name, "notes.txt")
        model.stage(file: folder)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.draft)
    }

    func testClearDraftUnstagesWithoutTouchingTheSharedItem() throws {
        syncSetUp.send(true)
        pasteboard.setString("shared", forType: .string)
        model.paste()
        model.send()
        let shared = try XCTUnwrap(source.current)
        pasteboard.clearContents()
        pasteboard.setString("staged", forType: .string)
        model.paste()
        XCTAssertNotNil(model.draft)
        model.clearDraft()
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.staging)
        XCTAssertNil(model.error)
        XCTAssertEqual(source.current, shared)
    }

    func testDownloadSavesTheFileUnderItsNameUntilItIsMoved() throws {
        syncSetUp.send(true)
        let file = directory.appendingPathComponent("Mist-Bookmarks.html")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<p>bookmarks</p>".utf8).write(to: file)
        model.stage(file: file)
        model.send()
        let shared = try XCTUnwrap(source.current)
        XCTAssertNil(model.downloadedFile(for: shared))
        model.download(shared)
        XCTAssertNil(model.error)
        let saved = try XCTUnwrap(model.downloadedFile(for: shared))
        XCTAssertEqual(saved.lastPathComponent, "Mist-Bookmarks.html")
        XCTAssertEqual(try Data(contentsOf: saved), Data("<p>bookmarks</p>".utf8))
        try FileManager.default.removeItem(at: saved)
        XCTAssertNil(model.downloadedFile(for: shared))
    }

    func testStagedTextGrowsWithItsLinesAndScrollsPastTheCap() async throws {
        let line = ClipboardDraftText.height(of: "One line", width: 500)
        XCTAssertGreaterThan(line, 0)
        XCTAssertLessThan(line, ClipboardPageView.fileIconSide)
        XCTAssertEqual(ClipboardDraftText.height(of: "One\nTwo\nThree", width: 500), line * 3, accuracy: 1)
        XCTAssertEqual(ClipboardDraftText.height(of: String(repeating: "x", count: 20_000), width: 500),
                       ClipboardDraftText.maxHeight)

        syncSetUp.send(true)
        let page = ClipboardPageViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = page
        // The controller shrinks the window to its view's empty frame.
        window.setContentSize(NSSize(width: 800, height: 800))
        func stage(_ text: String) async throws -> NSScrollView {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            model.paste()
            XCTAssertEqual(model.draftText, text)
            for _ in 0..<50 {
                page.view.layoutSubtreeIfNeeded()
                if let view = model.draftTextView, view.window === window,
                   (view.documentView as? NSTextView)?.string == text { return view }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(nil as NSScrollView?, "The staged text never showed")
        }
        let short = try await stage("One line")
        XCTAssertEqual(short.frame.height, line, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(short.documentView).frame.height, short.contentView.bounds.height + 1)
        let paragraphs = Array(repeating: "A paragraph of staged text that wraps across the box.", count: 30)
        let long = try await stage(paragraphs.joined(separator: "\n\n"))
        XCTAssertEqual(long.frame.height, ClipboardDraftText.maxHeight, accuracy: 1)
        try await Task.sleep(for: .milliseconds(100))
        let document = try XCTUnwrap(long.documentView)
        XCTAssertGreaterThan(document.frame.height, long.contentView.bounds.height)
        XCTAssertEqual(document.frame.minY, 0)
        XCTAssertEqual(long.contentView.bounds.minY, 0, "A newly staged text shows its start")
        model.clearDraft()
        XCTAssertNil(model.draftText)
    }

    func testPointingHandShowsOverEnabledButtonsWithoutTakingTheirClicks() async throws {
        syncSetUp.send(true)
        let page = ClipboardPageViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = page
        window.setContentSize(NSSize(width: 800, height: 800))
        func areas(in view: NSView) -> [MistPointingHandArea.AreaView] {
            view.subviews.flatMap { ($0 as? MistPointingHandArea.AreaView).map { [$0] } ?? areas(in: $0) }
        }
        /// The footer's areas in the window, left to right, once `count` have joined it.
        func footer(_ count: Int) async throws -> [NSRect] {
            for _ in 0..<50 {
                page.view.layoutSubtreeIfNeeded()
                let frames = areas(in: page.view).filter { $0.window === window }.map { $0.convert($0.bounds, to: nil) }
                if frames.count == count { return frames.sorted { $0.minX < $1.minX } }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The footer never showed \(count) buttons")
            return []
        }
        func center(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

        let idle = try await footer(1)
        XCTAssertFalse(page.pointingHandTarget(at: center(idle[0])), "A disabled Send keeps the arrow")
        let input = try XCTUnwrap(model.inputView)
        XCTAssertTrue(page.pointingHandTarget(at: center(input.convert(input.bounds, to: nil))))

        pasteboard.setString("staged", forType: .string)
        model.paste()
        let staged = try await footer(2)
        let (clear, send) = (staged[0], staged[1])
        XCTAssertTrue(page.pointingHandTarget(at: center(clear)))
        XCTAssertTrue(page.pointingHandTarget(at: center(send)))
        XCTAssertFalse(page.pointingHandTarget(at: NSPoint(x: clear.maxX + 8, y: clear.midY)))
        XCTAssertFalse(page.pointingHandTarget(at: NSPoint(x: send.minX - 8, y: send.midY)))
        XCTAssertFalse(page.pointingHandTarget(at: NSPoint(x: send.midX, y: send.minY - 4)))
        let frameView = try XCTUnwrap(page.view.superview)
        func hit(_ point: NSPoint) -> NSView? { page.view.hitTest(frameView.convert(point, from: nil)) }
        let card = try XCTUnwrap(hit(NSPoint(x: clear.maxX + 8, y: clear.midY)))
        for rect in [clear, send] {
            XCTAssertTrue(hit(center(rect)) === card, "SwiftUI still takes the button's click")
        }
    }

    func testCommandVStagesPrivatePasteboardAndSendPublishes() async throws {
        syncSetUp.send(true)
        pasteboard.setString("Clipboard page test", forType: .string)
        let page = ClipboardPageViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = page
        page.view.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(model.inputView)
        XCTAssertTrue(window.makeFirstResponder(input))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(page.view.performKeyEquivalent(with: event))
        for _ in 0..<100 where model.staging { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.staging)
        XCTAssertEqual(model.draft?.data, Data("Clipboard page test".utf8))
        model.send()
        XCTAssertNil(model.error)
        XCTAssertNil(model.draft)
        XCTAssertEqual(source.current?.text, "Clipboard page test")
        XCTAssertTrue(window.makeFirstResponder(window))
        XCTAssertTrue(page.view.performKeyEquivalent(with: event), "With nothing focused, the shown page takes ⌘V")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        page.view.superview?.addSubview(field)
        defer { field.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(page.view.performKeyEquivalent(with: event), "A view outside the page keeps ⌘V")
    }
}
