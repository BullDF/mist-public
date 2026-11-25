import AppKit
import XCTest
@testable import Phi

@MainActor
final class MistSlashCommandPopupTests: XCTestCase {
    func testGroupPopupOrderFiltersAgentFoldersAndAppOnlyGroups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let current = Tab(guid: 71, url: "https://current.test", isActive: false, index: 0, title: "Current")
        let second = Tab(guid: 72, url: "https://second.test", isActive: false, index: 1, title: "Second")
        let first = Tab(guid: 73, url: "https://first.test", isActive: false, index: 2, title: "First")
        let agent = Tab(guid: 74, url: "https://agent.test", isActive: false, index: 3, title: "Agent")
        let app = Tab(guid: 75, url: AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, isActive: false, index: 4, title: "Chat")
        second.groupToken = "second"; first.groupToken = "first"; agent.groupToken = "agent"; app.groupToken = "app"
        state.tabs = [current, second, first, agent, app]
        state.normalTabs = state.tabs
        state.groups = [
            "first": WebContentGroupInfo(token: "first", title: "First group", color: .blue, isCollapsed: false),
            "second": WebContentGroupInfo(token: "second", title: "", color: .red, isCollapsed: false),
            "agent": WebContentGroupInfo(token: "agent", title: "Agent" + BrowserAgentFolderState.titleMarker, color: .blue, isCollapsed: false),
            "app": WebContentGroupInfo(token: "app", title: "App", color: .blue, isCollapsed: false),
        ]
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        editor.mentionTabs = { state.tabs }
        editor.mentionGroups = { state.agentMentionGroups }
        editor.currentTab = { current }
        editor.text = "@"
        XCTAssertEqual(editor.mentionPopup.matches.map(\.key), ["tab:71", "group:second", "group:first", "tab:72", "tab:73", "tab:74"])
        XCTAssertEqual(state.agentMentionGroups.first?.info.displayTitle, GroupColor.red.localizedName)
        XCTAssertEqual(state.agentMentionGroups.map { $0.tabs.map(\.guid) }, [[72], [73]])
    }

    func testGroupCompletionIsAtomicAndFollowsLiveRenameAndMembership() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let tab = Tab(guid: 71, url: "https://example.test", isActive: false, index: 0, title: "Page")
        let info = WebContentGroupInfo(token: "g", title: "PRs", color: .blue, isCollapsed: false)
        var members = [tab]
        editor.mentionTabs = { [tab] }
        editor.mentionGroups = { [MistMentionGroup(info: info, tabs: members)] }
        editor.text = "Read @"
        editor.textView.keyDown(with: try key(48))
        XCTAssertEqual(editor.text, "Read @PRs ")
        XCTAssertEqual(editor.mentions.map(\.key), ["group:g"])
        XCTAssertEqual(editor.mentions.first?.range, NSRange(location: 5, length: 4))
        editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertFalse((6..<9).contains(editor.textView.selectedRange().location))
        info.title = "Reviews"
        info.color = .red
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(editor.text, "Read @Reviews ")
        XCTAssertEqual(editor.mentions.first?.group?.color, "red")
        let other = Tab(guid: 72, url: "https://other.test", isActive: false, index: 1, title: "Other")
        members.append(other)
        info.objectWillChange.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(editor.mentionBanner.mentions.first?.group?.tabs.map(\.tabId), [71, 72])
        editor.textView.setSelectedRange(NSRange(location: 13, length: 0))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "Read  ")
        XCTAssertTrue(editor.mentions.isEmpty)
    }

    func testCurrentTabMentionIsPinnedAndEnterInsertsItsTitle() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let other = Tab(guid: 71, url: "https://other.test", isActive: false, index: 0, title: "Other")
        let current = Tab(guid: 72, url: "https://example.com", isActive: false, index: 1, title: "Example")
        editor.mentionTabs = { [other, current] }
        editor.currentTab = { current }
        editor.text = "@"
        XCTAssertEqual(editor.mentionPopup.selectedMention?.tabId, current.guid)
        XCTAssertEqual(editor.mentionPopup.matches.map(\.tabId), [72, 71])
        XCTAssertEqual(editor.mentionPopup.currentTabId, current.guid)
        let row = try XCTUnwrap((editor.mentionPopup.accessibilityChildren() as? [MistTabMentionRow])?.first)
        XCTAssertEqual(row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, AgentChatStrings.currentTab)
        XCTAssertEqual(row.accessibilityLabel(), AgentChatStrings.currentTab + ". Example")
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(editor.text, "@Example ")
        editor.textView.insertText("@", replacementRange: editor.textView.selectedRange())
        XCTAssertNil(editor.mentionPopup.currentTabId)
        XCTAssertEqual(editor.mentionPopup.matches.map(\.tabId), [71, 72])
    }

    func testMentionPopupRebuildsWhenOnlyPinnedStatusChanges() throws {
        let popup = MistTabMentionPopup()
        let mention = AgentTabMention(tabId: 71, title: "Example", url: "https://example.com")
        popup.update([], current: mention)
        popup.update([mention])
        XCTAssertNil(popup.currentTabId)
        let row = try XCTUnwrap((popup.accessibilityChildren() as? [MistTabMentionRow])?.first)
        XCTAssertEqual(row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, mention.title)
    }

    func testDescriptionsFlattenWhitespaceAndWrapWithinTwoCenteredLines() throws {
        let popup = MistSlashCommandPopup()
        popup.frame = NSRect(x: 0, y: 0, width: 420, height: 44)
        let command = ClaudeCodeSlashCommand(name: "review", description: "Review\n\nall changes and suggest improvements to the implementation and its tests with a concise explanation", argumentHint: "")
        popup.update(ClaudeCodeSlashMatcher.matches([command], query: ""))
        popup.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields) }
        let label = try XCTUnwrap(fields(popup).first { $0.stringValue == command.displayDescription })
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(label.maximumNumberOfLines, 2)
        XCTAssertTrue(label.cell?.truncatesLastVisibleLine == true)
        XCTAssertGreaterThan(label.frame.height, 18)
        XCTAssertLessThanOrEqual(label.frame.height, 34)
        XCTAssertEqual(label.frame.midY, 22, accuracy: 0.5)
    }

    func testMentionCompletionCaretAtomicDeleteAndUndo() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let tab = Tab(guid: 71, url: "https://example.com", isActive: false, index: 0, title: "Café notes")
        let chat = Tab(guid: 72, url: AgentChatRoute.current.placeholderURL(for: UUID()).absoluteString, isActive: false, index: 1, title: "Chat")
        editor.mentionTabs = { [tab, chat] }
        editor.text = "Read @ca"
        XCTAssertEqual(editor.mentionPopup.matches.map(\.tabId), [71])
        let undo = try XCTUnwrap(editor.textView.undoManager)
        // Direct calls run in one event here; give Tab and Backspace the separate
        // undo groups that AppKit creates for real keyboard events.
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.textView.keyDown(with: try key(48))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.text, "Read @Café notes ")
        XCTAssertEqual(editor.mentions.map(\.tabId), [71])
        XCTAssertEqual(editor.mentions.first?.range, NSRange(location: 5, length: 11))
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        XCTAssertFalse((6..<16).contains(editor.textView.selectedRange().location))
        editor.textView.setSelectedRange(NSRange(location: 16, length: 0))
        undo.beginUndoGrouping()
        editor.textView.deleteBackward(nil)
        undo.endUndoGrouping()
        XCTAssertEqual(editor.text, "Read  ")
        XCTAssertTrue(editor.mentions.isEmpty)
        undo.undo()
        XCTAssertEqual(editor.text, "Read @Café notes ")
        XCTAssertEqual(editor.mentions.map(\.tabId), [71])
        editor.mentionTabs = { [] }
        XCTAssertEqual(editor.promptForSend().mentions.first?.closed, true)
    }

    func testMentionTokensFollowTheirTabLiveAndRefreshAtSend() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let tab = Tab(guid: 71, url: "https://example.com/a", isActive: false, index: 0, title: "A")
        let other = Tab(guid: 72, url: "https://example.com/b", isActive: false, index: 1, title: "B")
        editor.mentionTabs = { [tab, other] }
        let undo = try XCTUnwrap(editor.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.text = "Read @"
        editor.textView.keyDown(with: try key(48))
        editor.textView.insertText("and @", replacementRange: editor.textView.selectedRange())
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        editor.textView.keyDown(with: try key(48))
        editor.textView.insertText("now", replacementRange: editor.textView.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(editor.text, "Read @A and @B now")
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        undo.beginUndoGrouping()
        tab.title = "Longer"
        tab.url = "https://example.com/longer"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        undo.endUndoGrouping()
        XCTAssertEqual(editor.text, "Read @Longer and @B now")
        XCTAssertEqual(editor.mentions.map(\.url), ["https://example.com/longer", "https://example.com/b"])
        XCTAssertEqual(editor.mentions.map(\.range), [NSRange(location: 5, length: 7), NSRange(location: 17, length: 2)])
        XCTAssertEqual(editor.mentionBanner.mentions.map(\.title), ["Longer", "B"])
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 16, length: 0))
        undo.undo()
        XCTAssertEqual(editor.text, "Read @A and @B now")
        XCTAssertEqual(editor.mentions.map(\.title), ["A", "B"])
        // A tab that navigated since the last runloop turn is still fresh when sent.
        other.title = "Other"
        undo.beginUndoGrouping()
        let prompt = editor.promptForSend()
        undo.endUndoGrouping()
        XCTAssertEqual(prompt.text, "Read @Longer and @Other now")
        XCTAssertEqual(prompt.mentions.map(\.title), ["Longer", "Other"])
        XCTAssertEqual(editor.text, prompt.text)
        editor.mentionTabs = { [tab] }
        undo.groupsByEvent = true
        let closed = editor.promptForSend()
        XCTAssertEqual(closed.text, "Read @Longer and @Other now")
        XCTAssertEqual(closed.mentions.map(\.closed), [false, true])
        XCTAssertEqual(closed.mentions.last?.url, "https://example.com/b")
    }

    func testMentionTokensSurviveAutomaticTextSubstitution() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let title = "Rail's \"page\" -- A&B <x> \\ ’ 🙂"
        let tab = Tab(guid: 71, url: "https://example.com", isActive: false, index: 0, title: title)
        editor.mentionTabs = { [tab] }
        editor.textView.isAutomaticQuoteSubstitutionEnabled = true
        editor.textView.isAutomaticDashSubstitutionEnabled = true
        editor.text = "@"
        editor.textView.keyDown(with: try key(48))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(editor.text, "@" + title + " ")
        XCTAssertEqual(editor.mentions.map(\.title), [title])
        // The route AppKit's quote substitution takes for the apostrophe inside the token.
        let apostrophe = (editor.text as NSString).range(of: "'")
        XCTAssertFalse(editor.textView.shouldChangeText(in: apostrophe, replacementString: "’"))
        XCTAssertEqual(editor.text, "@" + title + " ")
        XCTAssertEqual(editor.mentions.map(\.title), [title])
    }

    func testMentionPopupDismissesAndCapsVisibleRows() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommandsEnabled = false
        editor.mentionsEnabled = true
        let tabs = (0..<8).map { Tab(guid: $0, url: "https://example.com/\($0)", isActive: false, index: $0, title: "Page \($0)") }
        editor.mentionTabs = { tabs }
        editor.text = "@"
        XCTAssertEqual(editor.mentionPopup.listHeight, 264)
        editor.textView.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertEqual(editor.mentionPopup.selectedMention?.tabId, 1)
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(editor.text, "@Page 1 ")
        editor.text = "@"
        editor.textView.keyDown(with: try key(53))
        editor.updateSlashCommands()
        XCTAssertTrue(editor.mentionPopup.isHidden)
        editor.text = "@missing"
        XCTAssertTrue(editor.mentionPopup.isHidden)
        editor.text = "@Page "
        XCTAssertTrue(editor.mentionPopup.isHidden)
    }

    private let commands: [ClaudeCodeSlashCommand] = [
        .init(name: "end", description: "End the task", argumentHint: ""),
        .init(name: "review", description: "Review a file", argumentHint: "<file>"),
    ]

    private func host() -> (MistPromptEditor, NSWindow) {
        let editor = MistPromptEditor()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        root.addSubview(editor)
        root.addSubview(editor.commandPopup)
        editor.frame = NSRect(x: 0, y: 300, width: 650, height: 64)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        editor.slashCommandsEnabled = true
        editor.slashCommands = commands
        window.makeFirstResponder(editor.textView)
        return (editor, window)
    }

    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], characters: String = "", ignoringModifiers: String? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false, keyCode: code))
    }

    private func arrow(_ code: UInt16) throws -> NSEvent {
        let scalar = UnicodeScalar(code == 126 ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!
        return try key(code, [.numericPad, .function], characters: String(Character(scalar)))
    }

    func testTabAndShiftTabCompleteAndOtherwiseLeaveTextUnchanged() throws {
        let (editor, window) = host()
        defer { window.close() }
        var submissions = 0
        editor.textView.onSubmit = { submissions += 1 }
        for flags in [NSEvent.ModifierFlags(), .shift] {
            editor.text = "/re"
            XCTAssertEqual(editor.commandPopup.matches.count, 1)
            editor.textView.keyDown(with: try key(48, flags))
            XCTAssertEqual(editor.text, "/review ")
            XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 8, length: 0))
            XCTAssertTrue(editor.commandPopup.isHidden)
        }
        XCTAssertEqual(submissions, 0)
        editor.textView.keyDown(with: try key(48))
        XCTAssertEqual(editor.text, "/review ")
    }

    func testCommandsDeleteWholeExceptWhileBeingTyped() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "/re"
        editor.textView.keyDown(with: try key(48))
        XCTAssertEqual(editor.text, "/review ")
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "/review")
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "")

        for character in "/review" { editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange()) }
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "/revie")
        editor.textView.insertText("w", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText(" ", replacementRange: editor.textView.selectedRange())
        editor.textView.deleteBackward(nil)
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "")

        editor.text = "Run /review now"
        editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.text, "Run  now")
    }

    func testSlashQueryStartAsksOwnerToRescanOnce() {
        let (editor, window) = host()
        defer { window.close() }
        var starts = 0
        editor.onSlashQuery = { starts += 1 }
        editor.text = "/"
        editor.text = "/re"
        XCTAssertEqual(starts, 1)
        editor.slashCommands = commands + [.init(name: "rename", description: "New skill", argumentHint: "")]
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(editor.commandPopup.matches.map(\.command.name), ["rename", "review"])
        editor.text = "plain"
        editor.text = "/e"
        XCTAssertEqual(starts, 2)
    }

    func testEnterSubmitsOnlyCommandsWithoutArgumentHints() throws {
        let (editor, window) = host()
        defer { window.close() }
        var submissions: [String] = []
        editor.textView.onSubmit = { submissions.append(editor.text) }
        editor.text = "/en"
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(submissions, ["/end "])
        editor.text = "/re"
        editor.textView.keyDown(with: try key(76))
        XCTAssertEqual(editor.text, "/review ")
        XCTAssertEqual(submissions, ["/end "])
        for flags in [NSEvent.ModifierFlags.shift, .option] {
            editor.text = "/en"
            editor.textView.keyDown(with: try key(36, flags))
            XCTAssertEqual(editor.text, "/en\n")
            XCTAssertTrue(editor.commandPopup.isHidden)
            XCTAssertEqual(submissions.count, 1)
        }
    }

    func testSelectionWrapsAndEscapeKeepsTextAndFocus() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "/"
        XCTAssertEqual(editor.commandPopup.selectedIndex, 0)
        editor.textView.keyDown(with: try arrow(126))
        XCTAssertEqual(editor.commandPopup.selectedIndex, 1)
        editor.textView.keyDown(with: try arrow(125))
        XCTAssertEqual(editor.commandPopup.selectedIndex, 0)
        // Ctrl+N / Ctrl+P move like the arrows, as in the search box.
        editor.textView.keyDown(with: try key(45, .control, characters: "\u{0E}", ignoringModifiers: "n"))
        XCTAssertEqual(editor.commandPopup.selectedIndex, 1)
        editor.textView.keyDown(with: try key(35, .control, characters: "\u{10}", ignoringModifiers: "p"))
        XCTAssertEqual(editor.commandPopup.selectedIndex, 0)
        XCTAssertEqual(editor.text, "/", "Moving through the list never edits the text")
        editor.textView.keyDown(with: try key(53))
        editor.slashCommands = commands
        XCTAssertTrue(editor.commandPopup.isHidden)
        XCTAssertEqual(editor.text, "/")
        XCTAssertTrue(window.firstResponder === editor.textView)
        editor.textView.insertText("r", replacementRange: editor.textView.selectedRange())
        XCTAssertFalse(editor.commandPopup.isHidden)
        window.makeFirstResponder(nil)
        XCTAssertTrue(editor.commandPopup.isHidden)
    }

    func testRowPressCompletesWithoutSubmittingAndPreservesArguments() throws {
        let (editor, window) = host()
        defer { window.close() }
        var submitted = false
        editor.textView.onSubmit = { submitted = true }
        editor.text = "/re existing.txt"
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.updateSlashCommands()
        let row = try XCTUnwrap(editor.commandPopup.accessibilityChildren()?.first as? NSView)
        XCTAssertEqual(row.accessibilityLabel(), "/review. Review a file")
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(editor.text, "/review existing.txt")
        XCTAssertFalse(submitted)
        XCTAssertTrue(editor.commandPopup.isHidden)
    }

    func testNoMatchAndDisabledModeHaveNoList() {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "/missing"
        XCTAssertEqual(editor.commandPopup.listHeight, 0)
        editor.text = "/"
        XCTAssertGreaterThan(editor.commandPopup.listHeight, 0)
        editor.slashCommandsEnabled = false
        XCTAssertEqual(editor.commandPopup.listHeight, 0)
    }

    func testMidMessageCompletionFiltersBuiltinsAndKeepsSurroundingText() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.slashCommands = commands + [.init(name: "clear", description: "Clear", argumentHint: "", builtin: true)]
        editor.text = "🛠 Please /re existing.txt"
        editor.textView.setSelectedRange(NSRange(location: 13, length: 0))
        editor.updateSlashCommands()
        editor.textView.keyDown(with: try key(48))
        XCTAssertEqual(editor.text, "🛠 Please /review existing.txt")
        editor.text = "Please /"
        XCTAssertEqual(editor.commandPopup.matches.map { $0.command.name }, ["end", "review"])
        editor.setText("@News /", mentions: [.init(tabId: 9, title: "News", url: "https://news.test", range: NSRange(location: 0, length: 5))])
        editor.updateSlashCommands()
        XCTAssertEqual(editor.commandPopup.matches.map { $0.command.name }, ["end", "review"])
    }

    func testComposerCommandStylingPreservesSelectionUndoAndPlainTypingAndPaste() throws {
        let (editor, window) = host()
        defer { window.close() }
        editor.text = "/end"
        let storage = try XCTUnwrap(editor.textView.textStorage)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 16 * 0.85)
        XCTAssertTrue(editor.textView.layoutManager?.delegate === AgentChatSlashLayoutDelegate.shared)
        editor.textView.insertText(" hello", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .labelColor)
        XCTAssertEqual(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont, AgentChatTypography.font(ofSize: 16))
        editor.textView.setSelectedRange(NSRange(location: 6, length: 2))
        editor.slashCommands = commands
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 6, length: 2))
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.text, "/end")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(" plain", forType: .string)
        let rich = NSAttributedString(string: " plain", attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.red])
        pasteboard.setData(rich.rtf(from: NSRange(location: 0, length: rich.length)), forType: .rtf)
        editor.textView.paste(from: pasteboard)
        XCTAssertEqual(editor.text, "/end plain")
        XCTAssertEqual((storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.pointSize, 16)
    }

    func testMatchedNamesKeepTheirFullWidthOnOneLine() throws {
        let popup = MistSlashCommandPopup()
        popup.frame = NSRect(x: 0, y: 0, width: 650, height: 264)
        let names = ["keepalive", "deep-research", "consolidate-memory", "explore"]
        popup.update(ClaudeCodeSlashMatcher.matches(names.map { .init(name: $0, description: "Use this skill", argumentHint: "") }, query: "ee"))
        popup.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields) }
        let labels = fields(popup).filter { $0.stringValue.hasPrefix("/") }
        XCTAssertEqual(labels.count, names.count)
        for label in labels {
            // Bold matched letters widen a name; sized to the bare string and word-wrapping, it broke at "/" or "-".
            XCTAssertGreaterThanOrEqual(label.frame.width, ceil(label.attributedStringValue.size().width) + 4, label.stringValue)
            let style = label.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.lineBreakMode, .byTruncatingTail, label.stringValue)
        }
    }

    func testHoverRequiresCursorMovementAfterRebuildAndKeyboardScroll() throws {
        let popup = MistSlashCommandPopup()
        var point = NSPoint(x: 100, y: 100)
        popup.mouseLocation = { point }
        popup.update(ClaudeCodeSlashMatcher.matches(commands, query: ""))
        let rows = try XCTUnwrap(popup.accessibilityChildren() as? [NSView])
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        rows[1].mouseEntered(with: event)
        XCTAssertEqual(popup.selectedIndex, 0)
        point.x += 1
        rows[1].mouseMoved(with: event)
        XCTAssertEqual(popup.selectedIndex, 1)
        rows[1].mouseMoved(with: event)
        XCTAssertEqual(popup.selectedIndex, 1)
        popup.move(1)
        rows[1].mouseEntered(with: event)
        XCTAssertEqual(popup.selectedIndex, 0)
        point.x += 1
        rows[1].mouseMoved(with: event)
        XCTAssertEqual(popup.selectedIndex, 1)
        popup.update(ClaudeCodeSlashMatcher.matches(commands, query: "e"))
        let rebuilt = try XCTUnwrap(popup.accessibilityChildren() as? [NSView])
        rebuilt[1].mouseEntered(with: event)
        XCTAssertEqual(popup.selectedIndex, 0)
    }
}
