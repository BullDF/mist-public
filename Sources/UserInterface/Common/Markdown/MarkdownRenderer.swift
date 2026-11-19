import AppKit

enum AgentChatMentionStyle {
    static let token = NSAttributedString.Key("agentChatMentionToken")

    static func attributes(pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: AgentChatTypography.font(ofSize: pointSize, weight: .medium), .foregroundColor: NSColor.controlAccentColor]
    }

    static func apply(_ mentions: [AgentTabMention], to text: NSMutableAttributedString, pointSize: CGFloat) {
        for mention in mentions where NSMaxRange(mention.range) <= text.length {
            text.addAttributes(attributes(pointSize: pointSize), range: mention.range)
            text.addAttribute(token, value: mention, range: mention.range)
        }
    }
}

/// Shared appearance and line-breaking policy for commands in all chat text surfaces.
enum AgentChatSlashStyle {
    static let token = NSAttributedString.Key("agentChatSlashToken")

    static func attributes(pointSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: AgentChatTypography.codeFont(ofSize: pointSize * 0.85),
         .foregroundColor: NSColor.systemBlue, .baselineOffset: 0, token: true]
    }

    static func plainText(_ text: String, commands: Set<String>, font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = AgentChatTypography.lineSpacing * font.pointSize / AgentChatTypography.bodySize
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        for range in ClaudeCodeSlashTokenizer.styledRanges(in: text, commands: commands) {
            result.addAttributes(attributes(pointSize: font.pointSize), range: range)
        }
        return result
    }
}

final class AgentChatSlashLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    static let shared = AgentChatSlashLayoutDelegate()

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var hidden = false
        for index in 0..<glyphRange.length where storage.attribute(.agentHiddenFence, at: charIndexes[index], effectiveRange: nil) != nil {
            properties[index] = .null
            hidden = true
        }
        guard hidden else { return 0 }
        properties.withUnsafeBufferPointer {
            layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let storage = layoutManager.textStorage, charIndex > 0, charIndex < storage.length else { return true }
        var range = NSRange()
        if storage.attribute(AgentChatMentionStyle.token, at: charIndex, effectiveRange: &range) != nil {
            return charIndex == range.location
        }
        guard storage.attribute(AgentChatSlashStyle.token, at: charIndex, effectiveRange: &range) != nil else { return true }
        return charIndex == range.location
    }
}

/// TextKit considers a slash a break opportunity after, rather than before, the slash, and breaks
/// before an emoji or CJK character in a mention without asking the layout delegate.
/// Give the preceding line a boundary before a command or mention so vetoing internal breaks doesn't
/// fall back to character wrapping when there is no earlier word-break opportunity.
final class AgentChatTextContainer: NSTextContainer {
    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                         writingDirection: baseWritingDirection, remaining: remainingRect)
        guard let storage = layoutManager?.textStorage, characterIndex < storage.length else { return rect }
        let rest = Self.hardLineRemainder(of: storage.string as NSString, from: characterIndex)
        let available = rect.width - lineFragmentPadding * 2
        for key in [AgentChatSlashStyle.token, AgentChatMentionStyle.token] {
            var moved = false
            storage.enumerateAttribute(key, in: rest) { value, range, stop in
                guard value != nil, range.location > characterIndex else { return }
                let prefix = storage.attributedSubstring(from: NSRange(location: characterIndex, length: range.location - characterIndex)).size().width
                let tokenWidth = storage.attributedSubstring(from: range).size().width
                if prefix < available, prefix + tokenWidth > available, tokenWidth <= available {
                    rect.size.width = ceil(prefix) + lineFragmentPadding * 2
                    moved = true
                    stop.pointee = true
                }
            }
            if moved { break }
        }
        return rect
    }

    /// A token past the next line break, U+2028 included, can't share this line. A reply's plain lines are one
    /// paragraph, so scanning to the paragraph's bounds for every line fragment made its layout quadratic.
    static func hardLineRemainder(of source: NSString, from characterIndex: Int) -> NSRange {
        var end = 0
        source.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: characterIndex, length: 0))
        return NSRange(location: characterIndex, length: end - characterIndex)
    }
}

enum AgentChatTypography {
    static let bodySize: CGFloat = 15
    static let lineHeightMultiple: CGFloat = 1.25
    static let lineSpacing = bodySize * (lineHeightMultiple - 1)
    /// The chats' and the Markdown reader's typeface, bundled in `Resources/Fonts` (OFL) and registered through
    /// `ATSApplicationFontsPath`. Builds without the bundle (hostless scripts) fall back to the system fonts.
    static let family = "Google Sans Code"
    private static let familyInstalled = NSFontManager.shared.availableFontFamilies.contains(family)

    /// A chat's text: messages, mentions and the composer.
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard familyInstalled, let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [
            .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ]), size: size) else { return .systemFont(ofSize: size, weight: weight) }
        return font
    }

    /// Code and slash commands in a chat.
    static func codeFont(ofSize size: CGFloat) -> NSFont {
        familyInstalled ? font(ofSize: size) : .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSFont {
    /// This font's family at `weight`. A named font ignores a weight trait added to its own descriptor, so the family
    /// is looked up again when the descriptor kept the same face.
    func withWeight(_ weight: NSFont.Weight) -> NSFont? {
        let traits: [NSFontDescriptor.AttributeName: Any] = [.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]]
        if let font = NSFont(descriptor: fontDescriptor.addingAttributes(traits), size: pointSize), font.fontName != fontName { return font }
        guard let familyName else { return nil }
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: familyName]).addingAttributes(traits), size: pointSize)
    }
}

extension NSAttributedString.Key {
    static let agentHiddenFence = NSAttributedString.Key("agentHiddenFence")
    static let markdownCodeBlock = NSAttributedString.Key("markdownCodeBlock")
    static let markdownInlineCode = NSAttributedString.Key("markdownInlineCode")
}

enum AgentCodeBlockDrawing {
    /// The composer keeps a fence line's first character as a real glyph, so it locates the line.
    /// The used rect leaves out the paragraph spacing that separates the box from the lines around it.
    static func fenceLineRect(_ fence: NSRange, manager: NSLayoutManager) -> NSRect {
        manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: fence.location), effectiveRange: nil)
    }

    static func fill(_ rect: NSRect, color: NSColor, header: NSColor? = nil, headerHeight: CGFloat = 0) {
        color.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.fill()
        if let header {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            header.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// All paragraphs of a fence share this block and its untouched copy source.
final class MarkdownCodeBlock: NSObject {
    /// The shaded strip holding the language label and Copy button: 10 pt padding, an 18 pt line, 10 pt below.
    static let headerHeight: CGFloat = 38
    var code: String
    let language: String
    let block: NSTextBlock
    let background: NSColor
    let foreground: NSColor
    init(code: String, language: String, block: NSTextBlock, background: NSColor, foreground: NSColor) {
        self.code = code
        self.language = language
        self.block = block
        self.background = background
        self.foreground = foreground
    }
}

final class MarkdownRenderCache {
    struct Checkpoint {
        let line: Int
        let count: Int
        let paragraphStart: Int
        let indents: [Int]
        let items: [MarkdownRenderer.ListItem]
    }
    struct Piece {
        let block: MarkdownRenderer.MDBlock
        let first: Bool
        let previousSpacing: CGFloat
        let hasNext: Bool
        let nextIsList: Bool
        let text: NSAttributedString
        let spacing: CGFloat
    }
    var signature: [AnyHashable] = []
    var source = ""
    var lineStarts: [Int] = []
    var lines: [String] = []
    var blocks: [MarkdownRenderer.MDBlock] = []
    var checkpoints: [Checkpoint] = []
    var pieces: [Piece] = []
    var output = NSAttributedString(string: "")
    var paragraphHead: String?
    var paragraphHeadRuns: NSAttributedString?
    var paragraphSource = ""
    var paragraphResult: NSAttributedString?
    var paragraphTailStart: Int?
    var paragraphTailResultStart = 0
}

/// NSTextTable's automatic layout splits the width evenly between columns, which squeezed a long cell (a formula,
/// a sentence) beside short ones. This table sizes its columns like a browser's automatic table layout, from each
/// column's narrowest and widest content, once layout gives it the width to fill.
final class MarkdownTextTable: NSTextTable {
    /// Per column: the widest piece that can't wrap, and the widest cell on one line, both content widths.
    var minimumWidths: [CGFloat] = []
    var maximumWidths: [CGFloat] = []
    /// Per column, a cell's padding and borders.
    var insets: [CGFloat] = []
    /// The table's cells, which retain the table.
    let cells = NSHashTable<NSTextTableBlock>.weakObjects()
    private var laidOutWidth: CGFloat?

    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
                       textContainer: NSTextContainer, characterRange charRange: NSRange) -> NSRect {
        // Layout can run at a provisional width first; every cell takes the new widths before any is placed.
        if laidOutWidth != rect.width {
            laidOutWidth = rect.width
            let widths = Self.columnWidths(minimum: zip(minimumWidths, insets).map(+), maximum: zip(maximumWidths, insets).map(+), available: rect.width)
            for cell in cells.allObjects where cell.startingColumn < widths.count {
                cell.setValue(max(1, widths[cell.startingColumn] - insets[cell.startingColumn]), type: .absoluteValueType, for: .width)
            }
        }
        return super.rect(for: block, layoutAt: startingPoint, in: rect, textContainer: textContainer, characterRange: charRange)
    }

    /// Whole-point column widths that fill `available`, from each column's minimum and maximum outer widths.
    /// When the minimums fit, every column starts at its minimum and the rest goes out by maximum width, no
    /// column past its maximum, so short columns stay on one line; anything left over widens them all by
    /// maximum width. Otherwise each column gets a share of `available` by its minimum.
    static func columnWidths(minimum: [CGFloat], maximum: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !minimum.isEmpty else { return [] }
        let maximum = zip(minimum, maximum).map { max($0, $1) }
        let totalMinimum = minimum.reduce(0, +), totalMaximum = maximum.reduce(0, +)
        var widths: [CGFloat]
        if totalMaximum <= available {
            widths = maximum.map { $0 + (available - totalMaximum) * $0 / max(totalMaximum, 1) }
        } else if totalMinimum <= available {
            widths = minimum
            var rest = available - totalMinimum
            var growing = widths.indices.filter { widths[$0] < maximum[$0] }
            // Each pass either hands out all of the rest or brings a column to its maximum.
            while rest > 0.01, !growing.isEmpty {
                let weight = growing.reduce(0) { $0 + maximum[$1] }
                var granted: CGFloat = 0
                for index in growing {
                    let grant = min(rest * maximum[index] / weight, maximum[index] - widths[index])
                    widths[index] += grant
                    granted += grant
                }
                rest -= granted
                growing.removeAll { widths[$0] >= maximum[$0] - 0.01 }
            }
        } else {
            widths = minimum.map { available * $0 / max(totalMinimum, 1) }
        }
        // Rounding each column's right edge keeps every width within a point of its share and the total exact.
        var edge: CGFloat = 0, previous: CGFloat = 0
        return widths.indices.map { index in
            edge += widths[index]
            let rounded = index == widths.count - 1 ? available.rounded(.down) : edge.rounded()
            defer { previous = rounded }
            return rounded - previous
        }
    }

    /// Each column's minimum and maximum content widths over its cells: the widest run without whitespace,
    /// not counting formulas, which scale down to fit, and the widest cell laid out on one line.
    static func contentWidths(_ cells: [[NSAttributedString]], columns: Int) -> (minimum: [CGFloat], maximum: [CGFloat]) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 1_000_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var minimum = Array(repeating: CGFloat(0), count: columns)
        var maximum = minimum
        for row in cells {
            for (column, text) in row.enumerated() where column < columns && text.length > 0 {
                storage.setAttributedString(text)
                layout.ensureLayout(for: container)
                maximum[column] = max(maximum[column], layout.usedRect(for: container).width.rounded(.up))
                let string = text.string as NSString
                var start = 0
                while start < string.length {
                    let space = string.rangeOfCharacter(from: .whitespacesAndNewlines, range: NSRange(location: start, length: string.length - start))
                    let end = space.location == NSNotFound ? string.length : space.location
                    if end > start {
                        let word = NSRange(location: start, length: end - start)
                        let glyphs = layout.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
                        var width = layout.boundingRect(forGlyphRange: glyphs, in: container).width
                        text.enumerateAttribute(.attachment, in: word) { value, _, _ in
                            if let math = value as? MarkdownMathAttachment { width -= math.typeset.image.size.width }
                        }
                        minimum[column] = max(minimum[column], width.rounded(.up))
                    }
                    start = end + max(1, space.length)
                }
            }
        }
        return (minimum, maximum)
    }
}

/// Shared TextKit 1 block rendering with caller-owned typography.
struct MarkdownRenderer {
    /// How far an inline code pill reaches past its text on each side.
    static let inlineCodeInset: CGFloat = 2
    private static let listMarker = try! NSRegularExpression(pattern: #"^([-*+]|[0-9]+[.)])[ \t]+"#)
    private static func listMarkerEnd(_ text: String) -> String.Index? {
        guard let match = listMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return range.upperBound
    }
    let nsFont: NSFont
    let nsFontHeading: NSFont
    let nsFontSubheading: NSFont
    let nsFontSmall: NSFont
    let textNS: NSColor
    let dimNS: NSColor
    var lineHeightMultiple: CGFloat = AgentChatTypography.lineHeightMultiple
    var blockSpacing: CGFloat = 10
    var codeBackground: NSColor? = nil
    var separatorColor: NSColor = .separatorColor
    var slashCommands: Set<String> = []
    var typesetMath: ((String, Bool, CGFloat, NSColor) -> MarkdownMathTypeset?)? = nil
    var scale: CGFloat = 1
    /// Headings from level 3 down; 15 pt semibold system type at `scale` when nil.
    var nsFontMinorHeading: NSFont? = nil

    /// User prose remains literal. Only closed fences opt into the transcript's code rendering.
    func userMessageRuns(_ text: String, mentions: [AgentTabMention] = []) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let source = text as NSString
        let blocks = AgentCodeBlocks.blocks(in: text)
        func appendPlain(_ range: NSRange, beforeCode: Bool) {
            guard range.length > 0 else { return }
            let part = NSMutableAttributedString(attributedString: AgentChatSlashStyle.plainText(
                source.substring(with: range), commands: slashCommands, font: nsFont, color: textNS))
            let localMentions = mentions.compactMap { mention -> AgentTabMention? in
                guard mention.range.location >= range.location, NSMaxRange(mention.range) <= NSMaxRange(range) else { return nil }
                var shifted = mention
                shifted.range.location -= range.location
                return shifted
            }
            if beforeCode {
                let last = (part.string as NSString).paragraphRange(for: NSRange(location: part.length - 1, length: 0))
                let style = (part.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing = blockSpacing
                part.addAttribute(.paragraphStyle, value: style, range: last)
            }
            let start = out.length
            out.append(part)
            AgentChatMentionStyle.apply(localMentions.map { mention in
                var shifted = mention
                shifted.range.location += start
                return shifted
            }, to: out, pointSize: nsFont.pointSize)
        }
        var offset = 0
        for block in blocks {
            appendPlain(NSRange(location: offset, length: block.opening.location - offset), beforeCode: true)
            appendCode(language: block.language, code: source.substring(with: block.content), to: out)
            offset = NSMaxRange(block.closing)
            // appendCode already supplies the paragraph terminator after the box.
            if offset < source.length { offset += 1 }
        }
        appendPlain(NSRange(location: offset, length: source.length - offset), beforeCode: false)
        return out
    }

    /// NSAttributedString.size() ignores text blocks, so measure their contents and padding explicitly.
    static func userMessageWidth(_ text: NSAttributedString, scale: CGFloat = 1) -> CGFloat {
        var width: CGFloat = 0
        text.enumerateAttribute(.markdownCodeBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let code = value as? MarkdownCodeBlock {
                let font = text.attribute(.font, at: NSMaxRange(range) - 1, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 12.5 * scale, weight: .regular)
                let body = code.code.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                let label = (code.language as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 * scale)]).width
                width = max(width, body + 24, label + 24 + 28)
            } else {
                width = max(width, text.attributedSubstring(from: range).size().width)
            }
        }
        return ceil(width)
    }

    /// `indent` is a list item's text edge, for a fence continuing the item.
    private func appendCode(language: String, code: String, to out: NSMutableAttributedString, reusing old: MarkdownCodeBlock? = nil, indent: CGFloat = 0) {
        let box = (old?.block as? NSTextTableBlock) ?? fullWidthBlock()
        box.setWidth(10, type: .absoluteValueType, for: .padding)
        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        box.setWidth(blockSpacing, type: .absoluteValueType, for: .margin, edge: .maxY)
        box.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        let descriptor = old ?? MarkdownCodeBlock(code: code, language: language, block: box,
            background: codeBackground ?? dimNS.withAlphaComponent(0.07), foreground: dimNS)
        descriptor.code = code
        let start = out.length
        let header = NSMutableParagraphStyle()
        header.textBlocks = [box]
        let labelHeight = max(18, ceil(18 * scale))
        header.minimumLineHeight = labelHeight
        header.maximumLineHeight = labelHeight
        // Center the label in the header strip; the code starts 6 pt below it.
        header.paragraphSpacing = MarkdownCodeBlock.headerHeight - 10 - 18 + 6
        header.tailIndent = -28
        let labelFont = NSFont.systemFont(ofSize: 11 * scale)
        let label = NSMutableAttributedString(attributedString: atr(language.isEmpty ? "\u{200B}" : language, font: labelFont, color: dimNS))
        label.addAttribute(.baselineOffset, value: (labelHeight - (labelFont.ascender - labelFont.descender)) / 2,
                           range: NSRange(location: 0, length: label.length))
        append(label, style: header, to: out)
        let body = NSMutableParagraphStyle()
        body.textBlocks = [box]
        body.lineHeightMultiple = 1.15
        body.lineBreakMode = .byCharWrapping
        // Copy uses the untouched source, including its final newline.
        let visible = code.hasSuffix("\n") ? String(code.dropLast()) : code
        append(atr(visible.isEmpty ? "\u{200B}" : visible, font: nsFontSmall, color: textNS), style: body, to: out)
        out.addAttribute(.markdownCodeBlock, value: descriptor, range: NSRange(location: start, length: out.length - start))
    }

    func markdownRuns(_ text: String, color: NSColor, cache: MarkdownRenderCache? = nil) -> NSAttributedString {
        let signature: [AnyHashable] = [nsFont, nsFontHeading, nsFontSubheading, nsFontMinorHeading ?? NSNull(), nsFontSmall, textNS, dimNS,
                                        lineHeightMultiple, blockSpacing, codeBackground ?? NSNull(), separatorColor, slashCommands, color, typesetMath != nil, scale]
        if let cache, cache.signature != signature {
            cache.signature = signature
            cache.source = ""
            cache.lineStarts = []
            cache.lines = []
            cache.blocks = []
            cache.checkpoints = []
            cache.pieces = []
            cache.output = NSAttributedString(string: "")
            cache.paragraphHead = nil
            cache.paragraphHeadRuns = nil
            cache.paragraphResult = nil
            cache.paragraphTailStart = nil
        }
        let out = NSMutableAttributedString()
        let blocks = parseMarkdown(text, cache: cache)
        var previousSpacing: CGFloat = 0
        var pieces: [MarkdownRenderCache.Piece] = []
        var prefixLength = 0
        var changed = false
        for (index, block) in blocks.enumerated() {
            let hasNext = index + 1 < blocks.count
            let nextIsList: Bool = hasNext && { if case .list = blocks[index + 1] { return true }; return false }()
            let old = cache.flatMap { index < $0.pieces.count ? $0.pieces[index] : nil }
            if let old, old.block == block, old.first == (index == 0), old.previousSpacing == previousSpacing,
               old.hasNext == hasNext, old.nextIsList == nextIsList {
                pieces.append(old)
                previousSpacing = old.spacing
                if changed { out.append(old.text) } else { prefixLength += old.text.length }
                continue
            }
            if !changed {
                if let cache, prefixLength > 0 { out.append(cache.output.attributedSubstring(from: NSRange(location: 0, length: prefixLength))) }
                changed = true
            }
            let piece = NSMutableAttributedString()
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = lineHeightMultiple
            style.paragraphSpacing = blockSpacing
            // A block continuing a list item lays out at the item's text edge.
            var edge: CGFloat = 0
            var content = block
            if case let .listContinuation(level, marker, inner) = block {
                edge = listTextEdge(level: level, marker: marker)
                content = inner
            }
            switch content {
            case let .heading(level, text):
                let font = level == 1 ? nsFontHeading : level == 2 ? nsFontSubheading
                    : nsFontMinorHeading ?? .systemFont(ofSize: 15 * scale, weight: .semibold)
                style.paragraphSpacingBefore = index == 0 ? 0 : max(0, 14 - previousSpacing)
                style.paragraphSpacing = 6
                append(inlineRuns(text, font: font, color: textNS), style: style, to: piece)
            case let .list(level, marker, text):
                style.firstLineHeadIndent = CGFloat(level) * 20
                style.headIndent = listTextEdge(level: level, marker: marker)
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                if index + 1 < blocks.count, case .list = blocks[index + 1] { style.paragraphSpacing = 4 }
                let item = NSMutableAttributedString(attributedString: atr(marker + "\t", font: nsFont, color: dimNS))
                item.append(inlineRuns(text, font: nsFont, color: color))
                append(item, style: style, to: piece)
            case let .code(language, code):
                var descriptor: MarkdownCodeBlock?
                if let old, let key = Self.codeKey(block), Self.codeKey(old.block) == key, old.text.length > 0 {
                    descriptor = old.text.attribute(.markdownCodeBlock, at: 0, effectiveRange: nil) as? MarkdownCodeBlock
                }
                appendCode(language: language, code: code, to: piece, reusing: descriptor, indent: edge)
            case let .paragraph(text):
                style.firstLineHeadIndent = edge
                style.headIndent = edge
                append(paragraphRuns(text, color: color, cache: cache), style: style, to: piece)
            case let .math(source, latex):
                if let math = mathRun(source: source, latex: latex, display: true, attributes: [.font: nsFont, .foregroundColor: color]) {
                    style.alignment = .center
                    style.lineHeightMultiple = 1
                    append(math, style: style, to: piece)
                } else {
                    append(atr(source, font: nsFont, color: color), style: style, to: piece)
                }
            case let .quote(lines):
                // Each `>` depth is a block nested in the one above it, so every level draws its own bar.
                // Leaving a depth drops its block, so a later return to that depth starts a new bar.
                var nesting: [NSTextBlock] = []
                for (lineIndex, line) in lines.enumerated() {
                    nesting.removeLast(max(0, nesting.count - line.level))
                    while nesting.count < line.level {
                        let box = fullWidthBlock()
                        if nesting.isEmpty { box.setWidth(edge, type: .absoluteValueType, for: .margin, edge: .minX) }
                        box.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                        box.setBorderColor(dimNS.withAlphaComponent(0.35), for: .minX)
                        box.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                        box.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
                        box.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
                        nesting.append(box)
                    }
                    let lineStyle = style.mutableCopy() as! NSMutableParagraphStyle
                    lineStyle.textBlocks = nesting
                    lineStyle.paragraphSpacing = lineIndex == lines.count - 1 ? blockSpacing : 0
                    append(inlineRuns(line.text, font: nsFont, color: dimNS), style: lineStyle, to: piece)
                }
                style.paragraphSpacing = blockSpacing
            case .rule:
                let box = fullWidthBlock()
                box.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                box.setBorderColor(separatorColor, for: .minY)
                style.textBlocks = [box]
                style.minimumLineHeight = 1
                style.maximumLineHeight = 1
                style.lineHeightMultiple = 1
                style.paragraphSpacingBefore = max(0, 10 - previousSpacing)
                style.paragraphSpacing = 10
                append(atr("\u{200B}", font: .systemFont(ofSize: 1), color: .clear), style: style, to: piece)
            case let .table(rows, alignments):
                piece.append(tableRuns(rows, alignments: alignments, color: color))
                // AppKit ignores table and cell margins, so an empty fixed-height line separates the table from what follows.
                if index + 1 < blocks.count {
                    let spacer = NSMutableParagraphStyle()
                    spacer.minimumLineHeight = blockSpacing
                    spacer.maximumLineHeight = blockSpacing
                    append(atr("\u{200B}", font: .systemFont(ofSize: 1), color: .clear), style: spacer, to: piece)
                }
            case .listContinuation:
                break // The parser never nests one in another.
            }
            // Code blocks and tables end with a block margin, not paragraph spacing, so a heading after them keeps its full gap.
            switch content {
            case .code, .table: previousSpacing = 0
            default: previousSpacing = style.paragraphSpacing
            }
            pieces.append(.init(block: block, first: index == 0, previousSpacing: pieces.last?.spacing ?? 0,
                                hasNext: hasNext, nextIsList: nextIsList, text: piece, spacing: previousSpacing))
            out.append(piece)
        }
        if !changed, let cache, prefixLength > 0 { out.append(cache.output.attributedSubstring(from: NSRange(location: 0, length: prefixLength))) }
        cache?.pieces = pieces
        cache?.output = out
        return out
    }

    /// A paragraph's lines parse as line breaks, so an autolink or emphasis ends with its line, and render as
    /// line separators, which keep them one paragraph.
    private func paragraphInlineRuns(_ text: String, color: NSColor) -> NSAttributedString {
        let runs = NSMutableAttributedString(attributedString: inlineRuns(text.replacingOccurrences(of: "\u{2028}", with: "\n"), font: nsFont, color: color))
        runs.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: .literal, range: NSRange(location: 0, length: runs.length))
        return runs
    }

    private func paragraphRuns(_ text: String, color: NSColor, cache: MarkdownRenderCache?) -> NSAttributedString {
        guard let cache else { return paragraphInlineRuns(text, color: color) }
        func plain(_ line: String) -> Bool {
            line.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 32 || $0 == 9 || $0 == 47
            }
        }
        func plainRuns(_ source: String) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: atr(source, font: nsFont, color: color))
            for range in ClaudeCodeSlashTokenizer.styledRanges(in: source, commands: slashCommands) {
                result.addAttributes(AgentChatSlashStyle.attributes(pointSize: nsFont.pointSize), range: range)
            }
            return result
        }
        if let start = cache.paragraphTailStart, let previous = cache.paragraphResult,
           text.hasPrefix(cache.paragraphSource) {
            let suffix = (text as NSString).substring(from: start)
            if suffix.components(separatedBy: "\u{2028}").allSatisfy(plain) {
                let result = NSMutableAttributedString(attributedString: previous.attributedSubstring(from: NSRange(location: 0, length: cache.paragraphTailResultStart)))
                result.append(plainRuns(suffix))
                let lastStart = (text as NSString).range(of: "\u{2028}", options: .backwards).location
                let next = lastStart == NSNotFound ? 0 : lastStart + 1
                cache.paragraphSource = text
                cache.paragraphResult = result
                cache.paragraphTailStart = next
                cache.paragraphTailResultStart = result.length - ((text as NSString).length - next)
                return result
            }
        }
        let lines = text.components(separatedBy: "\u{2028}")
        func remember(_ result: NSAttributedString, tail: Bool) -> NSAttributedString {
            cache.paragraphSource = text
            cache.paragraphResult = result
            let lastStart = (text as NSString).range(of: "\u{2028}", options: .backwards).location
            let start = lastStart == NSNotFound ? 0 : lastStart + 1
            cache.paragraphTailStart = tail ? start : nil
            cache.paragraphTailResultStart = result.length - ((text as NSString).length - start)
            return result
        }
        guard let lastMarkup = lines.lastIndex(where: { !plain($0) }) else { return remember(plainRuns(text), tail: true) }
        guard lastMarkup + 1 < lines.count,
              let boundary = (lastMarkup + 1..<lines.count).first(where: { index in
                  let line = lines[index]
                  return (line.contains(" ") || line.contains("\t")) && line.first?.isWhitespace == false && line.last?.isWhitespace == false
              }) else { return remember(paragraphInlineRuns(text, color: color), tail: false) }
        let head = lines[...boundary].joined(separator: "\u{2028}")
        let headRuns: NSAttributedString
        if cache.paragraphHead == head, let cached = cache.paragraphHeadRuns { headRuns = cached }
        else {
            headRuns = paragraphInlineRuns(head, color: color)
            cache.paragraphHead = head
            cache.paragraphHeadRuns = headRuns
        }
        let result = NSMutableAttributedString(attributedString: headRuns)
        if boundary + 1 < lines.count {
            result.append(plainRuns("\u{2028}" + lines[(boundary + 1)...].joined(separator: "\u{2028}")))
        }
        return remember(result, tail: boundary + 1 < lines.count)
    }

    /// Where a list item's text starts: its level's inset, then room for its marker.
    private func listTextEdge(level: Int, marker: String) -> CGFloat {
        CGFloat(level) * 20 + max(20, (marker as NSString).size(withAttributes: [.font: nsFont]).width + 8)
    }

    /// A code block without its body, nested as it is: a piece with an equal key keeps its box.
    private static func codeKey(_ block: MDBlock) -> MDBlock? {
        switch block {
        case let .code(language, _): return .code(language, "")
        case let .listContinuation(level, marker, inner): return codeKey(inner).map { .listContinuation(level, marker, $0) }
        default: return nil
        }
    }

    private func append(_ text: NSAttributedString, style: NSParagraphStyle, to output: NSMutableAttributedString) {
        let paragraph = NSMutableAttributedString(attributedString: text)
        let font = text.length > 0 ? text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont : nil
        paragraph.append(atr("\n", font: font ?? nsFont, color: textNS))
        paragraph.addAttribute(.paragraphStyle, value: style.copy(), range: NSRange(location: 0, length: paragraph.length))
        output.append(paragraph)
    }

    /// TextKit 1 lays out block padding and borders through table cells; a
    /// standalone NSTextBlock does not receive a layout rectangle.
    private func fullWidthBlock() -> NSTextTableBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        table.setValue(100, type: .percentageValueType, for: .maximumWidth)
        return NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
    }

    func inlineRuns(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let spans = typesetMath == nil || text.unicodeScalars.contains(where: { (0xF0000...0xFFFFD).contains($0.value) }) ? [] : MarkdownMath.spans(in: text)
        let replaced = NSMutableString(string: text)
        for (index, span) in spans.enumerated().reversed() where index < 65534 {
            replaced.replaceCharacters(in: span.range, with: String(UnicodeScalar(0xF0000 + index)!))
        }
        guard let parsed = try? AttributedString(markdown: replaced as String, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return atr(text, font: font, color: color) }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var pieceFont = intent.contains(.code) ? NSFont(descriptor: nsFontSmall.fontDescriptor, size: font.pointSize * 0.9) ?? nsFontSmall : font
            if intent.contains(.stronglyEmphasized) { pieceFont = NSFontManager.shared.convert(pieceFont, toHaveTrait: .boldFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: intent.contains(.code) ? textNS : color]
            if intent.contains(.emphasized) {
                let italic = NSFontManager.shared.convert(pieceFont, toHaveTrait: .italicFontMask)
                if NSFontManager.shared.traits(of: italic).contains(.italicFontMask) { pieceFont = italic }
                else { attributes[.obliqueness] = 0.18 }
            }
            attributes[.font] = pieceFont
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) { attributes[.markdownInlineCode] = dimNS.withAlphaComponent(0.10) }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = 0
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        for (index, span) in spans.enumerated().reversed() where index < 65534 {
            let placeholder = String(UnicodeScalar(0xF0000 + index)!)
            let range = (out.string as NSString).range(of: placeholder)
            guard range.location != NSNotFound else { continue }
            let attributes = out.attributes(at: range.location, effectiveRange: nil)
            let source = (text as NSString).substring(with: span.range)
            out.replaceCharacters(in: range, with: mathRun(source: source, latex: span.latex, display: span.display, attributes: attributes) ?? NSAttributedString(string: source, attributes: attributes))
        }
        for range in ClaudeCodeSlashTokenizer.styledRanges(in: out.string, commands: slashCommands) {
            var protected = false
            out.enumerateAttributes(in: range) { attributes, _, _ in
                if attributes[.markdownInlineCode] != nil || attributes[.link] != nil { protected = true }
            }
            guard !protected else { continue }
            out.enumerateAttribute(.font, in: range) { value, part, _ in
                let size = (value as? NSFont)?.pointSize ?? font.pointSize
                out.addAttributes(AgentChatSlashStyle.attributes(pointSize: size), range: part)
            }
        }
        // Kerning the character before a code pill and the pill's last character makes room for its insets,
        // so a space beside it stays as wide as between words instead of disappearing under the pill.
        var codeRanges: [NSRange] = []
        out.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if value != nil { codeRanges.append(range) }
        }
        for range in codeRanges {
            if range.location > 0 {
                out.addAttribute(.kern, value: Self.inlineCodeInset, range: NSRange(location: range.location - 1, length: 1))
            }
            out.addAttribute(.kern, value: Self.inlineCodeInset, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
        return out
    }

    private func mathRun(source: String, latex: String, display: Bool, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        let font = attributes[.font] as? NSFont ?? nsFont
        let color = attributes[.foregroundColor] as? NSColor ?? textNS
        let size = font.pointSize * 1.2
        guard let typeset = typesetMath?(latex, display, size, color) else { return nil }
        let attachment = MarkdownMathAttachment(source: source, display: display, pointSize: size, color: color, typeset: typeset,
                                                minimumAscent: display ? 0 : font.ascender)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func tableRuns(_ rows: [[String]], alignments: [NSTextAlignment], color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = rows.first?.count ?? 0
        guard columns > 0 else { return out }
        let headerFont = nsFont.withWeight(.semibold) ?? NSFontManager.shared.convert(nsFont, toHaveTrait: .boldFontMask)
        let cells = rows.enumerated().map { rowIndex, row in
            (0..<columns).map { column in
                inlineRuns(column < row.count ? row[column] : "", font: rowIndex == 0 ? headerFont : nsFont, color: color)
            }
        }
        let table = MarkdownTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        // Padding and the left border, plus the outer right border on the last column.
        table.insets = (0..<columns).map { 21 + ($0 == columns - 1 ? 1 : 0) }
        (table.minimumWidths, table.maximumWidths) = MarkdownTextTable.contentWidths(cells, columns: columns)
        // Collapsed borders shift the table right by half a border, so when its integer column widths fill
        // the text view, the outer right border lands past the view's bounds and is clipped. Each cell draws
        // its left and top border instead, and only the last column and row add the outer right and bottom.
        table.collapsesBorders = false
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setValue(100, type: .percentageValueType, for: .maximumWidth)
        for rowIndex in rows.indices {
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                table.cells.add(cell)
                cell.setWidth(8, type: .absoluteValueType, for: .padding)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .minX)
                cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                if column == columns - 1 { cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxX) }
                if rowIndex == rows.count - 1 { cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY) }
                cell.setBorderColor(separatorColor)
                if rowIndex == 0 { cell.backgroundColor = dimNS.withAlphaComponent(0.07) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                // A multiple adds its extra height above the glyphs, which would sink the text in its cell;
                // line spacing goes between wrapped lines only, so equal padding keeps text centered.
                style.lineSpacing = AgentChatTypography.lineSpacing * scale
                style.alignment = column < alignments.count ? alignments[column] : .left
                append(cells[rowIndex][column], style: style, to: out)
            }
        }
        return out
    }

    enum MDBlock: Equatable {
        case heading(Int, String)
        case list(Int, String, String)
        case code(String, String)
        case paragraph(String)
        case math(source: String, latex: String)
        case quote([QuoteLine])
        case rule
        case table([[String]], [NSTextAlignment])
        /// A paragraph, code block or quote after a list item's first paragraph, inside the item at `level` with
        /// `marker`: indented past the item's marker, or after a blank line.
        indirect case listContinuation(Int, String, MDBlock)
    }

    struct QuoteLine: Equatable {
        let level: Int
        let text: String
    }

    /// An open list item: blocks indented past its marker continue it.
    struct ListItem: Equatable {
        let level: Int
        let indent: Int
        let marker: String
    }

    private static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// A fenced block's lines drop up to the fence's own indent, as in CommonMark.
    private static func dropIndent(_ line: String, upTo width: Int) -> String {
        var rest = Substring(line)
        var dropped = 0
        while dropped < width, let first = rest.first, first == " " || first == "\t" {
            dropped += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    func parseMarkdown(_ text: String, cache: MarkdownRenderCache? = nil) -> [MDBlock] {
        var lines: [String]
        var starts: [Int]
        var out: [MDBlock] = []
        var index = 0
        var paragraph: [String] = []
        // Accept either two or four spaces per nesting level, and tabs.
        var listIndents = [0]
        var listItems: [ListItem] = []
        var checkpoints: [MarkdownRenderCache.Checkpoint] = []
        if let cache {
            let common = zip(cache.source.utf16, text.utf16).prefix { $0 == $1 }.count
            if let checkpoint = cache.checkpoints.last(where: { $0.line + 1 < cache.lineStarts.count && cache.lineStarts[$0.line + 1] <= common }) {
                index = checkpoint.line
                out = Array(cache.blocks.prefix(checkpoint.count))
                listIndents = checkpoint.indents
                listItems = checkpoint.items
                checkpoints = cache.checkpoints.filter { $0.line < index }
            }
        }
        if let cache, index > 0 {
            let offset = cache.lineStarts[index]
            lines = Array(cache.lines.prefix(index)) + (text as NSString).substring(from: offset).components(separatedBy: "\n")
            starts = Array(cache.lineStarts.prefix(index + 1))
            paragraph = Array(lines[cache.checkpoints.last(where: { $0.line == index })!.paragraphStart..<index])
        } else {
            lines = text.components(separatedBy: "\n")
            starts = [0]
        }
        func endLists() {
            listIndents = [0]
            listItems = []
        }
        /// A block starting at a line indented `indent` continues the deepest open list item whose marker it's
        /// indented past, closing the items below that one; otherwise it ends the list.
        func enter(indent: Int) {
            guard let owner = listItems.last(where: { $0.indent < indent }) else { return endLists() }
            listItems.removeAll { $0.level > owner.level }
            listIndents = Array(listIndents.prefix(owner.level + 1))
        }
        func nested(_ block: MDBlock) -> MDBlock {
            listItems.last.map { .listContinuation($0.level, $0.marker, block) } ?? block
        }
        func addParagraphLine(_ line: String) {
            if paragraph.isEmpty { enter(indent: Self.indentWidth(line)) }
            paragraph.append(line)
        }
        // A paragraph's lines lose their indentation, as in CommonMark.
        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(nested(.paragraph(paragraph.map { String($0.drop { $0 == " " || $0 == "\t" }) }.joined(separator: "\u{2028}"))))
            paragraph = []
        }
        while index < lines.count {
            checkpoints.append(.init(line: index, count: out.count, paragraphStart: index - paragraph.count, indents: listIndents, items: listItems))
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if let fence = AgentCodeBlocks.fence(trimmed) {
                flush()
                let indent = Self.indentWidth(raw)
                enter(indent: indent)
                var code = ""
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if fence.closes(candidate) { index += 1; break }
                    code += Self.dropIndent(lines[index], upTo: indent) + (index < lines.count - 1 ? "\n" : "")
                    index += 1
                }
                out.append(nested(.code(fence.language, code)))
                continue
            }
            if typesetMath != nil, trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                let startIndex = index - 1
                var end = startIndex
                var closed = false
                while end < lines.count {
                    let candidate = lines[end].trimmingCharacters(in: .whitespaces)
                    if end > startIndex && end == lines.count - 1 && candidate.isEmpty { end = lines.count; break }
                    if end > startIndex && (candidate.isEmpty || AgentCodeBlocks.fence(candidate) != nil) { break }
                    if candidate.hasSuffix(close) && (end > startIndex || candidate.count >= 4) { closed = true; break }
                    end += 1
                }
                if closed {
                    let source = lines[startIndex...end].joined(separator: "\n")
                    let content = source.trimmingCharacters(in: .whitespaces)
                    let latex = String(content.dropFirst(2).dropLast(2))
                    // `$$a$$ and $$b$$` closes before the line ends, so it's text with two inline formulas.
                    if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !latex.contains(close) {
                        flush(); out.append(.math(source: source, latex: latex)); index = end + 1; endLists(); continue
                    }
                } else if end == lines.count {
                    lines[startIndex...].forEach(addParagraphLine)
                    index = lines.count
                    continue
                }
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.contains("|"), index < lines.count, Self.isTableSeparator(lines[index]) {
                flush()
                var rows = [Self.tableCells(trimmed)]
                let alignments = Self.tableAlignments(lines[index])
                index += 1
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(Self.tableCells(row))
                    index += 1
                }
                out.append(.table(rows, alignments))
                endLists()
                continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); out.append(.rule); endLists(); continue }
            if trimmed.hasPrefix(">") {
                flush()
                enter(indent: Self.indentWidth(raw))
                var quote = [Self.quoteLine(trimmed)]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(Self.quoteLine(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                // A bare `>` only separates quote paragraphs.
                quote.removeAll { $0.text.isEmpty }
                if !quote.isEmpty { out.append(nested(.quote(quote))) }
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush()
                out.append(.heading(hashes, trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                endLists()
                continue
            }
            if let markerEnd = Self.listMarkerEnd(trimmed) {
                flush()
                let indent = Self.indentWidth(raw)
                while listIndents.count > 1, indent < listIndents.last! { listIndents.removeLast() }
                if indent > listIndents.last! { listIndents.append(indent) }
                let level = listIndents.count - 1
                let sourceMarker = String(trimmed[..<markerEnd]).trimmingCharacters(in: .whitespaces)
                var marker = sourceMarker.first?.isNumber == true ? sourceMarker : ["•", "◦", "▪"][min(level, 2)]
                var content = String(trimmed[markerEnd...])
                if ["[ ]", "[x]", "[X]"].contains(content) || content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                    marker = content.hasPrefix("[ ]") ? "☐" : "☑"
                    content = String(content.dropFirst(min(4, content.count)))
                }
                listItems.removeAll { $0.level >= level }
                listItems.append(ListItem(level: level, indent: indent, marker: marker))
                // A fence or quote line starts a block inside the item rather than continuing its text.
                while index < lines.count {
                    let next = lines[index]
                    let t = next.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, Self.indentWidth(next) > indent,
                          Self.listMarkerEnd(t) == nil,
                          AgentCodeBlocks.fence(t) == nil, !t.hasPrefix(">") else { break }
                    content += " " + t
                    index += 1
                }
                out.append(.list(level, marker, content))
                continue
            }
            addParagraphLine(raw)
        }
        flush()
        cache?.source = text
        if let cache {
            var offset = starts.last!
            for line in lines.dropFirst(starts.count - 1).dropLast() {
                offset += line.utf16.count + 1
                starts.append(offset)
            }
            cache.lineStarts = starts
            cache.lines = lines
        }
        cache?.blocks = out
        cache?.checkpoints = checkpoints
        return out
    }

    /// `> > x` and `>> x` are both depth 2.
    private static func quoteLine(_ text: String) -> QuoteLine {
        let marker = text.prefix { $0 == ">" || $0 == " " }
        return QuoteLine(level: marker.filter { $0 == ">" }.count,
                         text: String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
    }

    /// GFM: `:---` left, `:---:` center, `---:` right.
    private static func tableAlignments(_ separator: String) -> [NSTextAlignment] {
        tableCells(separator.trimmingCharacters(in: .whitespaces)).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    /// Whether `text`'s first block is a code block or a table, which draw their box from their first line; reads only
    /// the leading lines, as `parseMarkdown` would.
    static func opensWithBox(_ text: String) -> Bool {
        var lines: [String] = []
        var rest = Substring(text)
        while lines.count < 2 {
            let end = rest.firstIndex(of: "\n") ?? rest.endIndex
            let line = String(rest[..<end])
            if !lines.isEmpty || !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            guard end < rest.endIndex else { break }
            rest = rest[rest.index(after: end)...]
        }
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return false }
        if AgentCodeBlocks.fence(first) != nil { return true }
        return first.contains("|") && lines.count > 1 && isTableSeparator(lines[1])
    }

    private static func isTableSeparator(_ text: String) -> Bool {
        let cells = tableCells(text.trimmingCharacters(in: .whitespaces))
        return text.contains("|") && !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }

    private static func tableCells(_ text: String) -> [String] {
        var cells: [String] = [], cell = ""
        var escaped = false, inCode = false
        for character in text {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "\u{0060}" { inCode.toggle(); cell.append(character) }
            else if character == "|" && !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if text.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private func atr(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}
