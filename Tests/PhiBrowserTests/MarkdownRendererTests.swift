import AppKit
import XCTest
#if !MIST_MARKDOWN_HOSTLESS_TESTS
@testable import Phi
#endif

final class MarkdownRendererTests: XCTestCase {
    private var mathRenderer: MarkdownRenderer {
        var value = renderer
        value.typesetMath = { _, _, _, _ in MarkdownMathTypeset(image: NSImage(size: NSSize(width: 10, height: 10)), baseline: 2) }
        return value
    }

    func testMathScanning() {
        let text = #"\(a\) $x^2$ mid $$z$$ and \[w\] ` $no$ ` costs $5 and $10; $x$5; $ x$; $x $; \$x\$"#
        XCTAssertEqual(MarkdownMath.spans(in: text).map(\.latex), ["a", "x^2", "z", "w"])
        XCTAssertTrue(MarkdownMath.spans(in: "$x\ny$ and \\(unfinished").isEmpty)
        for literal in ["$20,000 and $30,000", "$x$5", "$ x$", "$x $", #"\$x\$"#, "`$x$`", "$$unfinished", "$x\u{2028}y$"] {
            XCTAssertTrue(MarkdownMath.spans(in: literal).isEmpty, literal)
        }
        XCTAssertEqual(MarkdownMath.spans(in: "😀 $x$").first?.range, NSRange(location: 3, length: 3))
        XCTAssertEqual(MarkdownMath.spans(in: "`` `$x$` `` $y$").map(\.latex), ["y"])
    }

    func testMathNormalizesWhatSwiftMathLacks() {
        XCTAssertEqual(MarkdownMath.normalized(#"\exp\!\bigl(-4\,\lvert x \rvert\bigr)"#), #"\exp\!\left(-4\,\vert x \vert\right)"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\min\!\Bigl(1,\, \dfrac{\tau}{t_m}\Bigr)^{2}"#), #"\min\!\left(1,\, \frac{\tau}{t_m}\right)^{2}"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\big( a \big) \Bigg\langle b \Bigg\rangle"#), #"\left( a \right) \left\langle b \right\rangle"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\bigl\{ x \bigr\}"#), #"\left\{ x \right\}"#)
        // Pairs never cross a group or an alignment cell; unpaired sizes just drop.
        XCTAssertEqual(MarkdownMath.normalized(#"{\bigl( a} \bigr)"#), #"{( a} )"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\bigl( a & b \bigr)"#), #"( a & b )"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\bigl. a \bigr| \bigm| \big|"#), #"\left. a \right| | |"#)
        XCTAssertEqual(MarkdownMath.normalized(#"\Bigl( x"#), "( x")
        XCTAssertEqual(MarkdownMath.normalized(#"\bigl. x"#), " x")
        XCTAssertEqual(MarkdownMath.normalized(#"\operatorname{arg\,max} \dots \bigstar \Big"#), #"\mathrm{arg\,max} \ldots \bigstar "#)
        XCTAssertEqual(MarkdownMath.normalized(#"a \\ b \{c\}"#), #"a \\ b \{c\}"#)
    }

    func testTableColumnsSizeByContent() {
        // Everything fits: each column gets its maximum, and the rest goes out by maximum width.
        XCTAssertEqual(MarkdownTextTable.columnWidths(minimum: [50, 100], maximum: [100, 300], available: 800), [200, 600])
        // Minimums fit: short columns reach their maximum before a long one takes the rest.
        XCTAssertEqual(MarkdownTextTable.columnWidths(minimum: [50, 80, 40], maximum: [50, 500, 52], available: 380), [50, 278, 52])
        // Nothing fits: shares by minimum. Widths are whole points that fill the available width.
        XCTAssertEqual(MarkdownTextTable.columnWidths(minimum: [100, 300], maximum: [100, 300], available: 200.5), [50, 150])
        XCTAssertEqual(MarkdownTextTable.columnWidths(minimum: [10, 10, 10], maximum: [10, 10, 10], available: 100).reduce(0, +), 100)
    }

    func testMathBlocksAndStreaming() {
        let renderer = mathRenderer
        let source = "inline $x$\n\n$$\na+b\n$$\n\n\\[\nc\n\\]\n\ncosts $5 and $10\n\n```\n$x$\n$$\n```"
        let cache = MarkdownRenderCache()
        let chars = Array(source)
        for offset in 0...chars.count {
            let prefix = String(chars.prefix(offset))
            assertEquivalent(renderer.markdownRuns(prefix, color: .labelColor, cache: cache), renderer.markdownRuns(prefix, color: .labelColor), source: prefix)
            XCTAssertEqual(cache.blocks, renderer.parseMarkdown(prefix), prefix)
        }
        XCTAssertEqual(renderer.parseMarkdown("$$x$$"), [.math(source: "$$x$$", latex: "x")])
        XCTAssertEqual(renderer.parseMarkdown("$$a$$ and $$b$$"), [.paragraph("$$a$$ and $$b$$")])
        XCTAssertEqual(renderer.parseMarkdown("\\[ x \\]"), [.math(source: "\\[ x \\]", latex: " x ")])
        XCTAssertEqual(renderer.parseMarkdown("$$\na"), [.paragraph("$$\u{2028}a")])
        XCTAssertEqual(renderer.parseMarkdown("$$\na\n\n$$"), [.paragraph("$$\u{2028}a"), .paragraph("$$")])
        XCTAssertEqual(self.renderer.parseMarkdown("$$x$$"), [.paragraph("$$x$$")])
    }
    private func assertEquivalent(_ actual: NSAttributedString, _ expected: NSAttributedString, source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.string, expected.string, source, file: file, line: line)
        guard actual.string == expected.string else { return }
        for index in 0..<actual.length {
            var a = actual.attributes(at: index, effectiveRange: nil)
            var b = expected.attributes(at: index, effectiveRange: nil)
            if let x = a.removeValue(forKey: .paragraphStyle) as? NSParagraphStyle,
               let y = b.removeValue(forKey: .paragraphStyle) as? NSParagraphStyle {
                XCTAssertEqual(x.textBlocks.map { String(describing: type(of: $0)) }, y.textBlocks.map { String(describing: type(of: $0)) }, source, file: file, line: line)
                let xc = x.mutableCopy() as! NSMutableParagraphStyle
                let yc = y.mutableCopy() as! NSMutableParagraphStyle
                xc.textBlocks = []; yc.textBlocks = []
                XCTAssertEqual(xc, yc, source, file: file, line: line)
            }
            let x = a.removeValue(forKey: .markdownCodeBlock) as? MarkdownCodeBlock
            let y = b.removeValue(forKey: .markdownCodeBlock) as? MarkdownCodeBlock
            XCTAssertEqual(x?.code, y?.code, source, file: file, line: line)
            XCTAssertEqual(x?.language, y?.language, source, file: file, line: line)
            XCTAssertEqual(a as NSDictionary, b as NSDictionary, source, file: file, line: line)
        }
    }

    func testStreamingMarkdownEquivalence() {
        var renderer = renderer
        renderer.slashCommands = ["review"]
        let source = "# Heading\n- first\n  - child\n    continuation\n12. ordered\n- [x] done\n\nplain words\n*cross\nline* and `code\nspan`\nhttps://a.org/x\n/y\nmail@example.com\n_start\n trailing \n leading\nplain words\n/review here\nmore plain words\n\n```swift\nlet x = 1\n```\n\n> quote\n>> nested\n\n---\n\n| a | b |\n|---|---|\n| c | d |\n\nlast words\nmore words"
        let cache = MarkdownRenderCache()
        var seed: UInt64 = 42
        var offset = 0
        let chars = Array(source)
        while offset < chars.count {
            seed = seed &* 6364136223846793005 &+ 1
            offset = min(chars.count, offset + Int(seed % 9) + 1)
            let prefix = String(chars.prefix(offset))
            assertEquivalent(renderer.markdownRuns(prefix, color: .labelColor, cache: cache), renderer.markdownRuns(prefix, color: .labelColor), source: prefix)
            XCTAssertEqual(cache.blocks, renderer.parseMarkdown(prefix), prefix)
        }
        let parseCache = MarkdownRenderCache()
        for offset in 0...chars.count {
            let prefix = String(chars.prefix(offset))
            XCTAssertEqual(renderer.parseMarkdown(prefix, cache: parseCache), renderer.parseMarkdown(prefix), prefix)
            if offset == chars.count || (offset > 0 && chars[offset - 1] == "\n") {
                assertEquivalent(renderer.markdownRuns(prefix, color: .labelColor, cache: cache), renderer.markdownRuns(prefix, color: .labelColor), source: prefix)
            }
        }
    }

    func testFuzzParagraphStreamingEquivalence() {
        var renderer = renderer
        renderer.slashCommands = ["review"]
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        var seed: UInt64 = 7
        let cache = MarkdownRenderCache()
        var source = ""
        for index in 0..<120 {
            seed = seed &* 6364136223846793005 &+ 1
            var line = index % 3 == 0 ? "ordinary plain words" : ""
            if line.isEmpty {
                for _ in 0..<Int(seed % 24 + 1) {
                    seed = seed &* 6364136223846793005 &+ 1
                    line.append(alphabet[Int(seed % UInt64(alphabet.count))])
                }
            }
            source += (source.isEmpty ? "" : "\n") + line
            assertEquivalent(renderer.markdownRuns(source, color: .labelColor, cache: cache), renderer.markdownRuns(source, color: .labelColor), source: source)
            XCTAssertEqual(cache.blocks, renderer.parseMarkdown(source))
        }
    }

    func testLongPlainParagraphStreamingEquivalence() {
        var renderer = renderer
        renderer.slashCommands = ["review"]
        let source = (0..<180).map { "\($0) /review words and /review more" }.joined(separator: "\n")
            + "\n**bold** https://example.com\n" + (180..<240).map { "\($0) /review plain words" }.joined(separator: "\n")
        let chars = Array(source)
        let cache = MarkdownRenderCache()
        var seed: UInt64 = 91
        var offset = 0
        while offset < chars.count {
            seed = seed &* 6364136223846793005 &+ 1
            offset = min(chars.count, offset + Int(seed % 37) + 1)
            let prefix = String(chars.prefix(offset))
            assertEquivalent(renderer.markdownRuns(prefix, color: .labelColor, cache: cache), renderer.markdownRuns(prefix, color: .labelColor), source: prefix)
            XCTAssertEqual(cache.blocks, renderer.parseMarkdown(prefix))
        }
    }

    func testStreamingBlockIdentity() throws {
        let cache = MarkdownRenderCache()
        let source = "```swift\nlet x = 1\n```\n\n> quote\n\n| a | b |\n|---|---|\n\ntail"
        let first = renderer.markdownRuns(source, color: .labelColor, cache: cache)
        let second = renderer.markdownRuns(source + " more", color: .labelColor, cache: cache)
        for word in ["swift", "quote", "a"] {
            let index = (first.string as NSString).range(of: word).location
            XCTAssertTrue(try style(first, at: index).textBlocks.first === style(second, at: index).textBlocks.first)
        }
        XCTAssertTrue(first.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as AnyObject === second.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as AnyObject)
        let streaming = MarkdownRenderCache()
        let a = renderer.markdownRuns("```swift\nabc", color: .labelColor, cache: streaming)
        let descriptor = try XCTUnwrap(a.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock)
        let b = renderer.markdownRuns("```swift\nabcd", color: .labelColor, cache: streaming)
        XCTAssertTrue(descriptor === b.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock)
        XCTAssertTrue(try style(a).textBlocks.first === style(b).textBlocks.first)
        XCTAssertEqual(descriptor.code, "abcd")
    }
    func testHiddenFenceGlyphsKeepTenPointPaddingLines() {
        let storage = NSTextStorage(string: "```\nx\n```", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: 1000))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.delegate = AgentChatSlashLayoutDelegate.shared
        let padding = NSMutableParagraphStyle()
        padding.minimumLineHeight = 10
        padding.maximumLineHeight = 10
        // As the composer styles fences: the first backtick stays a real, clear glyph and the rest are hidden.
        for range in [NSRange(location: 0, length: 3), NSRange(location: 6, length: 3)] {
            storage.addAttribute(.agentHiddenFence, value: true, range: NSRange(location: range.location + 1, length: 2))
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: range.location, length: 1))
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: padding],
                                  range: NSRange(location: range.location, length: range.length + (range.location == 0 ? 1 : 0)))
        }
        manager.ensureLayout(for: container)
        for index in [1, 2, 7, 8] {
            XCTAssertTrue(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null))
        }
        for index in [0, 4, 6] {
            XCTAssertFalse(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null))
        }
        for index in [0, 6] {
            XCTAssertEqual(AgentCodeBlockDrawing.fenceLineRect(NSRange(location: index, length: 3), manager: manager).height, 10)
        }
        XCTAssertGreaterThan(AgentCodeBlockDrawing.fenceLineRect(NSRange(location: 6, length: 3), manager: manager).minY,
                             manager.lineFragmentRect(forGlyphAt: 4, effectiveRange: nil).minY)
    }

    func testUserMessageKeepsPlainMarkdownAndRendersExactCode() throws {
        let text = renderer.userMessageRuns("**x**\n```swift\nlet x = 1\n\n```\n_after_")
        XCTAssertEqual(text.string, "**x**\nswift\nlet x = 1\n\n_after_")
        let index = (text.string as NSString).range(of: "let x").location
        let block = try XCTUnwrap(text.attribute(.markdownCodeBlock, at: index, effectiveRange: nil) as? MarkdownCodeBlock)
        XCTAssertEqual(block.code, "let x = 1\n\n")
        XCTAssertEqual(block.language, "swift")
        XCTAssertEqual(try style(text).paragraphSpacing, 10)
        XCTAssertEqual((text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
        XCTAssertEqual(block.block.width(for: .padding, edge: .minX), 12)
        XCTAssertEqual(block.block.width(for: .margin, edge: .maxY), 10)
    }

    func testUserMessageCodeMatchesTranscriptCode() throws {
        let source = "~~~python\nprint('🙂')\n~~~~"
        let user = renderer.userMessageRuns(source)
        let assistant = renderer.markdownRuns(source, color: .labelColor)
        XCTAssertEqual(user.string, assistant.string)
        for index in 0..<user.length {
            XCTAssertEqual(user.attribute(.font, at: index, effectiveRange: nil) as? NSFont,
                           assistant.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            let lhs = try style(user, at: index)
            let rhs = try style(assistant, at: index)
            XCTAssertEqual(lhs.lineHeightMultiple, rhs.lineHeightMultiple)
            XCTAssertEqual(lhs.paragraphSpacing, rhs.paragraphSpacing)
            XCTAssertEqual(lhs.maximumLineHeight, rhs.maximumLineHeight)
        }
        let code = try XCTUnwrap(user.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock)
        XCTAssertEqual(code.code, "print('🙂')\n")
        XCTAssertEqual(code.language, "python")
    }

    func testUserMessageShiftsMentionsAndDropsCodeMentions() throws {
        let source = "@Before\n```swift\n@Inside\n```\n🙂 @After"
        let mentions = ["Before", "Inside", "After"].enumerated().map { index, title in
            AgentTabMention(tabId: index, title: title, url: "https://example.com", range: (source as NSString).range(of: "@" + title))
        }
        let text = renderer.userMessageRuns(source, mentions: mentions)
        for title in ["Before", "After"] {
            let range = (text.string as NSString).range(of: "@" + title)
            let mention = try XCTUnwrap(text.attribute(AgentChatMentionStyle.token, at: range.location, effectiveRange: nil) as? AgentTabMention)
            XCTAssertEqual(mention.range, range)
            XCTAssertEqual(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .controlAccentColor)
        }
        let inside = (text.string as NSString).range(of: "@Inside").location
        XCTAssertNil(text.attribute(AgentChatMentionStyle.token, at: inside, effectiveRange: nil))
    }

    func testUserMessageStylesCommandsOnlyOutsideCode() {
        var renderer = renderer
        renderer.slashCommands = ["usr"]
        let text = renderer.userMessageRuns("/usr\n```\n/usr\n```\n/usr")
        var ranges: [NSRange] = []
        text.enumerateAttribute(AgentChatSlashStyle.token, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.location, 0)
        XCTAssertEqual(ranges.last?.location, text.length - 4)
    }

    func testUserMessageWithoutClosedFenceIsUnchanged() {
        var renderer = renderer
        renderer.slashCommands = ["review"]
        for source in ["", "**x** _y_ `z`\n/review @Page", "```swift\nunfinished", "line\n\n"] {
            let range = (source as NSString).range(of: "@Page")
            let mentions = range.location == NSNotFound ? [] : [AgentTabMention(tabId: 1, title: "Page", url: "https://example.com", range: range)]
            let previous = NSMutableAttributedString(attributedString: AgentChatSlashStyle.plainText(source, commands: renderer.slashCommands, font: renderer.nsFont, color: renderer.textNS))
            AgentChatMentionStyle.apply(mentions, to: previous, pointSize: renderer.nsFont.pointSize)
            let current = renderer.userMessageRuns(source, mentions: mentions)
            XCTAssertTrue(previous.isEqual(to: current), source)
            XCTAssertEqual(MarkdownRenderer.userMessageWidth(current), ceil(previous.size().width))
        }
    }

    func testUserMessageWidthIncludesCodePaddingAndHeaderControls() {
        let code = String(repeating: "x", count: 80)
        let body = renderer.userMessageRuns("```\n" + code + "\n```")
        XCTAssertEqual(MarkdownRenderer.userMessageWidth(body), ceil((code as NSString).size(withAttributes: [.font: renderer.nsFontSmall]).width + 24))
        let language = "a-long-language-label"
        let header = renderer.userMessageRuns("```" + language + "\n\n```")
        XCTAssertEqual(MarkdownRenderer.userMessageWidth(header), ceil((language as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 52))
        let plain = String(repeating: "wide plain line ", count: 20)
        let mixed = renderer.userMessageRuns(plain + "\n```\nx\n```")
        XCTAssertEqual(MarkdownRenderer.userMessageWidth(mixed), ceil((plain as NSString).size(withAttributes: [.font: renderer.nsFont]).width))
    }

    private var renderer: MarkdownRenderer {
        MarkdownRenderer(nsFont: .systemFont(ofSize: 14),
                         nsFontHeading: .systemFont(ofSize: 20, weight: .semibold),
                         nsFontSubheading: .systemFont(ofSize: 17, weight: .semibold),
                         nsFontSmall: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                         textNS: .labelColor, dimNS: .secondaryLabelColor)
    }

    private func style(_ text: NSAttributedString, at index: Int = 0) throws -> NSParagraphStyle {
        try XCTUnwrap(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    }

    func testBlankLinesSeparateBlocksAndSoftLinesStayInOneParagraph() throws {
        let rendered = renderer.markdownRuns("First line\ncontinues.\n\n\nSecond paragraph.\n\n", color: .labelColor)
        XCTAssertEqual(rendered.string, "First line\u{2028}continues.\nSecond paragraph.\n")
        XCTAssertEqual(try style(rendered).lineHeightMultiple, 1.25)
        XCTAssertEqual(try style(rendered).paragraphSpacing, 10)
        XCTAssertEqual(renderer.parseMarkdown("\n\n"), [])
    }

    func testOpensWithBoxMatchesTheFirstParsedBlock() {
        let cases = ["\n```swift\nlet a = 1\n```\nAfter.", "```", "  ~~~\ncode", "| a | b |\n|---|:-:|\n| 1 | 2 |",
                     "Text first.\n\n```\ncode\n```", "| not a table", "a | b\nnext line", "> ```\n> quoted", "- item\n\n  ```\n  code\n  ```", "", "\n\n"]
        for text in cases {
            let parsed: Bool
            switch renderer.parseMarkdown(text).first {
            case .code, .table: parsed = true
            default: parsed = false
            }
            XCTAssertEqual(MarkdownRenderer.opensWithBox(text), parsed, text)
        }
    }

    func testParagraphLinesEndAutolinksAndOpenEmphasis() throws {
        let rendered = renderer.markdownRuns("ends with https://example.org/plain\nand _italic_ starts\n_this_ line", color: .labelColor)
        let source = rendered.string as NSString
        XCTAssertEqual(rendered.string, "ends with https://example.org/plain\u{2028}and italic starts\u{2028}this line\n")
        var linkRange = NSRange()
        let link = rendered.attribute(.link, at: source.range(of: "https").location, effectiveRange: &linkRange)
        XCTAssertEqual((link as? URL)?.absoluteString, "https://example.org/plain")
        XCTAssertEqual(NSMaxRange(linkRange), source.range(of: "\u{2028}").location)
        XCTAssertNil(rendered.attribute(.link, at: source.range(of: "and").location, effectiveRange: nil))
        for word in ["italic", "this"] {
            let font = try XCTUnwrap(rendered.attribute(.font, at: source.range(of: word).location, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask) ||
                          rendered.attribute(.obliqueness, at: source.range(of: word).location, effectiveRange: nil) != nil, word)
        }
    }

    func testSingleNewlinesKeepChecklistLinesWithoutParagraphGaps() throws {
        let source = "✅ A\n✅ B\n✅ C"
        XCTAssertEqual(renderer.parseMarkdown(source), [.paragraph("✅ A\u{2028}✅ B\u{2028}✅ C")])
        let rendered = renderer.markdownRuns(source, color: .labelColor)
        XCTAssertEqual(rendered.string, "✅ A\u{2028}✅ B\u{2028}✅ C\n")
        XCTAssertEqual((rendered.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)).length, rendered.length)
        XCTAssertEqual(try style(rendered).paragraphSpacing, 10)
    }

    func testHeadingsHaveNativeSizesAndSpacing() throws {
        let text = renderer.markdownRuns("# One\n\n## Two\n\n### Three\n#### Four\n##### Five\n###### Six", color: .labelColor)
        XCTAssertEqual(text.string, "One\nTwo\nThree\nFour\nFive\nSix\n")
        for (word, size) in [("One", 20.0), ("Two", 17), ("Three", 15), ("Four", 15), ("Five", 15), ("Six", 15)] {
            let index = (text.string as NSString).range(of: word).location
            XCTAssertEqual((text.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize, CGFloat(size))
            XCTAssertEqual(try style(text, at: index).paragraphSpacing, 6)
        }
        XCTAssertEqual(try style(text, at: 4).paragraphSpacingBefore, 8, "Six points below the previous heading plus eight above this one")
    }

    func testInlineFontsStrikeCodeAndLinks() throws {
        let text = renderer.inlineRuns("**bold** *italic* ~~gone~~ `code` [link](https://example.com)", font: .systemFont(ofSize: 14), color: .labelColor)
        XCTAssertEqual(text.string, "bold italic gone code link")
        func attributes(_ word: String) -> [NSAttributedString.Key: Any] {
            text.attributes(at: (text.string as NSString).range(of: word).location, effectiveRange: nil)
        }
        let bold = try XCTUnwrap(attributes("bold")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertFalse(bold.isFixedPitch)
        let italic = try XCTUnwrap(attributes("italic")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask) || attributes("italic")[.obliqueness] != nil)
        XCTAssertEqual(attributes("gone")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        let code = try XCTUnwrap(attributes("code")[.font] as? NSFont)
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertEqual(code.pointSize, 12.6, accuracy: 0.01)
        XCTAssertEqual(attributes("code")[.foregroundColor] as? NSColor, .labelColor)
        XCTAssertNotNil(attributes("code")[.markdownInlineCode])
        XCTAssertEqual(attributes("link")[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(attributes("link")[.foregroundColor] as? NSColor, .linkColor)
        XCTAssertEqual(attributes("link")[.underlineStyle] as? Int, 0)
    }

    func testSlashCommandsStyleOnlyKnownPlainTextOutsideCodeAndLinks() throws {
        var renderer = renderer
        renderer.slashCommands = ["review", "end", "usr"]
        let text = renderer.markdownRuns("Use /review, then (/end). /usr/bin\n\n`/review` [/end](https://example.com)\n\n```\n/review\n```", color: .labelColor)
        let source = text.string as NSString
        let first = source.range(of: "/review").location
        XCTAssertEqual(text.attribute(.foregroundColor, at: first, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual((text.attribute(.font, at: first, effectiveRange: nil) as? NSFont)?.pointSize, 14 * 0.85)
        XCTAssertEqual((text.attribute(.font, at: first, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)
        let path = source.range(of: "/usr/bin").location
        XCTAssertEqual(text.attribute(.foregroundColor, at: path, effectiveRange: nil) as? NSColor, .labelColor)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            if attributes[.markdownInlineCode] != nil || attributes[.markdownCodeBlock] != nil {
                XCTAssertNotEqual(attributes[.foregroundColor] as? NSColor, .systemBlue)
            }
            if attributes[.link] != nil { XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .linkColor) }
        }
    }

    func testSlashTokenMovesIntactToNextLine() throws {
        let text = AgentChatSlashStyle.plainText("Prefix /launch-codex suffix", commands: ["launch-codex"], font: .systemFont(ofSize: 16), color: .labelColor)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.delegate = AgentChatSlashLayoutDelegate.shared
        let container = AgentChatTextContainer(size: NSSize(width: 140, height: 1000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let token = (text.string as NSString).range(of: "/launch-codex")
        for index in (token.location + 1)..<NSMaxRange(token) {
            XCTAssertFalse(AgentChatSlashLayoutDelegate.shared.layoutManager(manager, shouldBreakLineByWordBeforeCharacterAt: index))
        }
        let first = manager.glyphIndexForCharacter(at: token.location)
        let last = manager.glyphIndexForCharacter(at: NSMaxRange(token) - 1)
        XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                       manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY)
        XCTAssertGreaterThan(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY, 0)
        XCTAssertEqual(text.string, "Prefix /launch-codex suffix")
    }

    func testTokenScanStopsAtTheLineBreak() {
        let source = "first line\u{2028}second /review\u{2028}third\nnext" as NSString
        XCTAssertEqual(AgentChatTextContainer.hardLineRemainder(of: source, from: 2), NSRange(location: 2, length: 9))
        XCTAssertEqual(AgentChatTextContainer.hardLineRemainder(of: source, from: 11), NSRange(location: 11, length: 15))
        XCTAssertEqual(AgentChatTextContainer.hardLineRemainder(of: source, from: 26), NSRange(location: 26, length: 6))
        XCTAssertEqual(AgentChatTextContainer.hardLineRemainder(of: source, from: 32), NSRange(location: 32, length: 4))
    }

    func testSlashTokenOnALaterSoftLineMovesIntactToNextLine() throws {
        let lines = (1...400).map { "Line \($0) alpha beta" }.joined(separator: "\n") + "\nPrefix /launch-codex suffix"
        let text = MarkdownRenderer(nsFont: .systemFont(ofSize: 16), nsFontHeading: .systemFont(ofSize: 20), nsFontSubheading: .systemFont(ofSize: 17),
                                    nsFontSmall: .monospacedSystemFont(ofSize: 12, weight: .regular), textNS: .labelColor, dimNS: .secondaryLabelColor,
                                    slashCommands: ["launch-codex"]).markdownRuns(lines, color: .labelColor)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.delegate = AgentChatSlashLayoutDelegate.shared
        let container = AgentChatTextContainer(size: NSSize(width: 140, height: 100_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let source = text.string as NSString
        XCTAssertEqual(source.paragraphRange(for: NSRange(location: 0, length: 0)).length, source.length, "the lines stay one paragraph")
        let prefix = source.range(of: "Prefix")
        let token = source.range(of: "/launch-codex")
        let first = manager.glyphIndexForCharacter(at: token.location)
        let last = manager.glyphIndexForCharacter(at: NSMaxRange(token) - 1)
        XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                       manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY)
        XCTAssertGreaterThan(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                             manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: prefix.location), effectiveRange: nil).minY)
    }

    func testEmojiAndCJKMentionTokensMoveIntactToNextLine() throws {
        for title in ["Party 🎉 emoji 👩‍💻 page", "易思汇 留学 缴费"] {
            let mention = AgentTabMention(tabId: 1, title: title, url: "https://example.com")
            let prefix = "Prefix words "
            let text = NSMutableAttributedString(string: prefix + mention.tokenText + " suffix", attributes: [.font: NSFont.systemFont(ofSize: 16)])
            var token = mention
            token.range = NSRange(location: (prefix as NSString).length, length: (mention.tokenText as NSString).length)
            AgentChatMentionStyle.apply([token], to: text, pointSize: 16)
            let prefixWidth = text.attributedSubstring(from: NSRange(location: 0, length: token.range.location)).size().width
            let tokenWidth = text.attributedSubstring(from: token.range).size().width
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            manager.delegate = AgentChatSlashLayoutDelegate.shared
            let container = AgentChatTextContainer(size: NSSize(width: ceil(max(prefixWidth + tokenWidth * 0.6, tokenWidth + 10)), height: 1000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let first = manager.glyphIndexForCharacter(at: token.range.location)
            let last = manager.glyphIndexForCharacter(at: NSMaxRange(token.range) - 1)
            XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                           manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY, title)
            XCTAssertGreaterThan(manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY, 0, title)
        }
    }

    func testNestedListsTasksSourceNumbersAndHangingIndents() throws {
        let source = "- First\n  - Child\n    - Grandchild\n- [ ] Pending\n- [x] Done\n12. Number\n    continuation"
        XCTAssertEqual(renderer.parseMarkdown(source), [
            .list(0, "•", "First"), .list(1, "◦", "Child"), .list(2, "▪", "Grandchild"),
            .list(0, "☐", "Pending"), .list(0, "☑", "Done"), .list(0, "12.", "Number continuation"),
        ])
        let text = renderer.markdownRuns(source, color: .labelColor)
        XCTAssertTrue(text.string.contains("12.\tNumber continuation"))
        let first = try style(text)
        XCTAssertEqual(first.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(first.headIndent, first.firstLineHeadIndent)
        XCTAssertEqual(first.paragraphSpacing, 4)
        let child = try style(text, at: (text.string as NSString).range(of: "Child").location)
        XCTAssertEqual(child.firstLineHeadIndent, 20)
        XCTAssertEqual(renderer.parseMarkdown("- One\n    - Two\n        - Three"), [.list(0, "•", "One"), .list(1, "◦", "Two"), .list(2, "▪", "Three")])
        XCTAssertEqual(renderer.parseMarkdown("- One\n\t- Two"), [.list(0, "•", "One"), .list(1, "◦", "Two")])
        XCTAssertEqual(renderer.parseMarkdown("- [ ]\n- [x]"), [.list(0, "☐", ""), .list(0, "☑", "")])
    }

    func testListItemContinuationsStayInTheItemAtItsTextEdge() throws {
        let source = "- **Neither.** Two paths:\n  - the sub-agent turn;\n  - the bash turn.\n\n  Both build the runner\n  on the current model.\n"
            + "- Next item\n\n  ```sh\n  make\n    indented\n  ```\n\n  > quoted\n\n    deeper\n- a\n  - b\n\n    c\n\nTop level\n   tail words"
        XCTAssertEqual(renderer.parseMarkdown(source), [
            .list(0, "•", "**Neither.** Two paths:"), .list(1, "◦", "the sub-agent turn;"), .list(1, "◦", "the bash turn."),
            .listContinuation(0, "•", .paragraph("Both build the runner\u{2028}on the current model.")),
            .list(0, "•", "Next item"),
            .listContinuation(0, "•", .code("sh", "make\n  indented\n")),
            .listContinuation(0, "•", .quote([.init(level: 1, text: "quoted")])),
            .listContinuation(0, "•", .paragraph("deeper")),
            .list(0, "•", "a"), .list(1, "◦", "b"), .listContinuation(1, "◦", .paragraph("c")),
            .paragraph("Top level\u{2028}tail words"),
        ])
        // A fence or quote right under the item's text still starts a block in the item.
        XCTAssertEqual(renderer.parseMarkdown("1. Run:\n   ```sh\n   make\n   ```\n2. Quote:\n   > q"), [
            .list(0, "1.", "Run:"), .listContinuation(0, "1.", .code("sh", "make\n")),
            .list(0, "2.", "Quote:"), .listContinuation(0, "2.", .quote([.init(level: 1, text: "q")])),
        ])
        // An indented fence drops its indent from its lines at the top level too.
        XCTAssertEqual(renderer.parseMarkdown("  ```\n  x\n   y\n  ```"), [.code("", "x\n y\n")])

        let text = renderer.markdownRuns(source, color: .labelColor)
        let string = text.string as NSString
        let item = try style(text)
        let continuation = try style(text, at: string.range(of: "Both build").location)
        XCTAssertEqual(continuation.firstLineHeadIndent, item.headIndent)
        XCTAssertEqual(continuation.headIndent, item.headIndent)
        let code = try XCTUnwrap(text.attribute(.markdownCodeBlock, at: string.range(of: "make").location, effectiveRange: nil) as? MarkdownCodeBlock)
        XCTAssertEqual(code.code, "make\n  indented\n")
        XCTAssertEqual(code.block.width(for: .margin, edge: .minX), item.headIndent)
        let quote = try style(text, at: string.range(of: "quoted").location)
        XCTAssertEqual(quote.textBlocks.first?.width(for: .margin, edge: .minX), item.headIndent)
        let child = try style(text, at: string.range(of: "b\n").location)
        XCTAssertEqual(try style(text, at: string.range(of: "c\n").location).firstLineHeadIndent, child.headIndent)

        // Every line of the continuation, and the item's own text, start at one x.
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 10000))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        func x(_ word: String) -> CGFloat {
            manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: string.range(of: word).location)).x
                + manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: string.range(of: word).location), effectiveRange: nil).minX
        }
        XCTAssertEqual(x("Both"), x("Neither"), accuracy: 0.5)
        XCTAssertEqual(x("on the current"), x("Neither"), accuracy: 0.5)
        XCTAssertGreaterThan(x("make"), x("Neither"))
        XCTAssertGreaterThan(x("quoted"), x("Neither"))
        XCTAssertEqual(x("tail words"), x("Top level"), accuracy: 0.5)
        XCTAssertLessThan(x("Top level"), x("Neither"))

        let cache = MarkdownRenderCache()
        let chars = Array(source)
        for offset in 0...chars.count {
            let prefix = String(chars.prefix(offset))
            assertEquivalent(renderer.markdownRuns(prefix, color: .labelColor, cache: cache), renderer.markdownRuns(prefix, color: .labelColor), source: prefix)
            XCTAssertEqual(cache.blocks, renderer.parseMarkdown(prefix), prefix)
        }
    }

    func testFencesAreLiteralPaddedBlocksWithExactCopySource() throws {
        let source = "````swift\n# literal\n**not bold**\n```\n  indented\n````"
        let exact = "# literal\n**not bold**\n```\n  indented\n"
        XCTAssertEqual(renderer.parseMarkdown(source), [.code("swift", exact)])
        let text = renderer.markdownRuns(source, color: .labelColor)
        XCTAssertEqual(text.string, "swift\n" + exact)
        let descriptor = try XCTUnwrap(text.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock)
        XCTAssertEqual(descriptor.code, exact)
        XCTAssertEqual(descriptor.block.width(for: .padding, edge: .minX), 12)
        XCTAssertEqual(descriptor.block.width(for: .padding, edge: .maxY), 10)
        XCTAssertTrue(try style(text).textBlocks.first === descriptor.block)
        XCTAssertTrue(try style(text, at: 6).textBlocks.first === descriptor.block)
        XCTAssertEqual(try style(text, at: 6).lineHeightMultiple, 1.15)
        XCTAssertEqual((text.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize, 12.5)
        XCTAssertEqual(renderer.parseMarkdown("~~~python\nprint(1)"), [.code("python", "print(1)")])
    }

    func testTablesUseRealCellsAndInlineMarkdown() throws {
        let source = "| A | Long |\n|---|:---:|\n| **BB** | `C` |\n\na | b"
        let text = renderer.markdownRuns(source, color: .labelColor)
        XCTAssertEqual(text.string, "A\nLong\nBB\nC\n\u{200B}\na | b\n", "A spacer line separates the table from the next block")
        let header = try XCTUnwrap(try style(text).textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(header.table.numberOfColumns, 2)
        XCTAssertEqual(header.table.layoutAlgorithm, .fixedLayoutAlgorithm, "MarkdownTextTable sets its own column widths")
        let table = try XCTUnwrap(header.table as? MarkdownTextTable)
        XCTAssertEqual(table.insets, [21, 22], "Padding and borders, plus the outer right border on the last column")
        XCTAssertEqual(table.maximumWidths.count, 2)
        XCTAssertGreaterThan(table.maximumWidths[1], table.maximumWidths[0], "`Long` is wider than `A`")
        XCTAssertEqual(table.cells.count, 4)
        XCTAssertFalse(header.table.collapsesBorders, "A collapsed outer right border is clipped at the view's edge")
        XCTAssertEqual(header.width(for: .border, edge: .minX), 1)
        XCTAssertEqual(header.width(for: .border, edge: .maxX), 0, "Only the last column draws the outer right border")
        XCTAssertEqual(header.width(for: .border, edge: .maxY), 0, "Only the last row draws the outer bottom border")
        XCTAssertEqual(header.width(for: .padding, edge: .minX), 10)
        XCTAssertEqual(header.width(for: .padding, edge: .minY), 8)
        XCTAssertEqual(header.width(for: .padding, edge: .maxY), 8)
        XCTAssertEqual(try style(text).lineHeightMultiple, 0, "A multiple would sink single-line cells to the bottom")
        XCTAssertNotNil(header.backgroundColor)
        let boldIndex = (text.string as NSString).range(of: "BB").location
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(text.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
        let secondRow = try XCTUnwrap(try style(text, at: boldIndex).textBlocks.first as? NSTextTableBlock)
        XCTAssertTrue(secondRow.table === header.table)
        XCTAssertEqual(secondRow.startingRow, 1)
        XCTAssertEqual(renderer.parseMarkdown("a | b"), [.paragraph("a | b")])
        XCTAssertEqual(renderer.parseMarkdown("| a\\|b | c |\n|---|---|"), [.table([["a|b", "c"]], [.left, .left])])
        XCTAssertEqual(renderer.parseMarkdown("| L | C | R |\n|:---|:---:|---:|"), [.table([["L", "C", "R"]], [.left, .center, .right])])
        let longIndex = (text.string as NSString).range(of: "Long").location
        XCTAssertEqual(try style(text, at: longIndex).alignment, .center, "`:---:` centers its column")
        XCTAssertEqual(try style(text).alignment, .left)
    }

    func testQuotesNestByDepthAndHaveALeftBorder() throws {
        XCTAssertEqual(renderer.parseMarkdown("> One\n>\n>> **Two**\n> > Three\n> Four"), [.quote([
            .init(level: 1, text: "One"), .init(level: 2, text: "**Two**"), .init(level: 2, text: "Three"), .init(level: 1, text: "Four"),
        ])])
        let text = renderer.markdownRuns("> One\n>> **Two**\n> Three\n>> Four", color: .labelColor)
        XCTAssertEqual(text.string, "One\nTwo\nThree\nFour\n")
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        let outer = try style(text).textBlocks
        XCTAssertEqual(outer.count, 1)
        let block = try XCTUnwrap(outer.first)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 3)
        XCTAssertEqual(block.width(for: .padding, edge: .minX), 12)
        XCTAssertEqual(try style(text).paragraphSpacing, 0)
        let nested = try style(text, at: 4).textBlocks
        XCTAssertEqual(nested.count, 2, "A deeper quote sits inside the outer one with its own bar")
        XCTAssertTrue(nested[0] === block)
        XCTAssertEqual(nested[1].width(for: .border, edge: .minX), 3)
        XCTAssertTrue(try style(text, at: 8).textBlocks == [block], "Returning to depth 1 stays in the outer quote")
        let reentered = try style(text, at: 14).textBlocks
        XCTAssertFalse(reentered[1] === nested[1], "Re-entering depth 2 starts a new inner bar")
        XCTAssertEqual(try style(text, at: 14).paragraphSpacing, 10)
    }

    func testRulesUseAOnePointBorder() throws {
        XCTAssertEqual(renderer.parseMarkdown("---\n***\n___"), [.rule, .rule, .rule])
        let text = renderer.markdownRuns("---", color: .labelColor)
        let paragraph = try style(text)
        XCTAssertEqual(paragraph.minimumLineHeight, 1)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 10)
        XCTAssertEqual(paragraph.paragraphSpacing, 10)
        XCTAssertEqual(paragraph.textBlocks.first?.width(for: .border, edge: .minY), 1)
    }

    func testCallerFontsRemainUsable() {
        let panel = MarkdownRenderer(nsFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
            nsFontHeading: .boldSystemFont(ofSize: 18), nsFontSubheading: .boldSystemFont(ofSize: 14),
            nsFontSmall: .monospacedSystemFont(ofSize: 10, weight: .regular),
            textNS: .labelColor, dimNS: .secondaryLabelColor)
        let bold = panel.inlineRuns("**bold**", font: panel.nsFont, color: .labelColor).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bold?.pointSize, 12)
        XCTAssertEqual(bold?.isFixedPitch, true)
    }

    func testBlockLayoutHasPaddingAndStaysWithinColumn() throws {
        for width in [CGFloat(240), 600] {
            for source in ["~~~swift\nlet a = 1\n~~~", "| Header | More |\n|---|---|\n| " + String(repeating: "longword", count: 20) + " | cell |"] {
                let storage = NSTextStorage(attributedString: renderer.markdownRuns(source, color: .labelColor))
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let style = value as? NSParagraphStyle else { return }
                    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    for block in style.textBlocks {
                        let box = manager.boundsRect(for: block, at: glyphs.location, effectiveRange: nil)
                        XCTAssertGreaterThan(box.height, 0)
                        XCTAssertLessThanOrEqual(box.maxX, width + 1)
                    }
                }
                if let descriptor = storage.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock {
                    let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
                    let box = manager.boundsRect(for: descriptor.block, at: glyphs.location, effectiveRange: nil)
                    XCTAssertEqual(box.width, width, accuracy: 1)
                    let lastLine = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
                    XCTAssertGreaterThanOrEqual(box.maxY - lastLine.maxY, 9.5)
                }
            }
        }
    }
}
