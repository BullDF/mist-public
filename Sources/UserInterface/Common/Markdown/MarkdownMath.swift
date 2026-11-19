import AppKit

struct MarkdownMathSpan: Equatable {
    let range: NSRange
    let latex: String
    let display: Bool
}

enum MarkdownMath {
    static func spans(in text: String) -> [MarkdownMathSpan] {
        let chars = Array(text)
        var result: [MarkdownMathSpan] = []
        var i = 0
        func lineBreak(_ c: Character) -> Bool { c == "\n" || c == "\u{2028}" }
        while i < chars.count {
            if chars[i] == "`" {
                var end = i
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - i
                var j = end
                var close: Int?
                while j < chars.count {
                    if chars[j] != "`" { j += 1; continue }
                    let start = j
                    while j < chars.count && chars[j] == "`" { j += 1 }
                    if j - start == count { close = j; break }
                }
                i = close ?? end
                continue
            }
            let start = i
            var opener = 0, closer = "", display = false, dollar = false
            if chars[i] == "\\" {
                if i + 1 < chars.count && (chars[i + 1] == "(" || chars[i + 1] == "[") {
                    display = chars[i + 1] == "["
                    opener = 2; closer = display ? "\\]" : "\\)"
                } else { i += min(2, chars.count - i); continue }
            } else if chars[i] == "$" {
                if i + 1 < chars.count && chars[i + 1] == "$" { opener = 2; closer = "$$"; display = true }
                else if i + 1 < chars.count && !chars[i + 1].isWhitespace { opener = 1; closer = "$"; dollar = true }
                else { i += 1; continue }
            } else { i += 1; continue }
            var j = i + opener
            var found: Int?
            let closing = Array(closer)
            while j < chars.count && !lineBreak(chars[j]) {
                if j + closing.count <= chars.count && Array(chars[j..<(j + closing.count)]) == closing {
                    if !dollar || (j > i + opener && !chars[j - 1].isWhitespace && (j + 1 == chars.count || !chars[j + 1].isNumber)) { found = j }
                    break
                }
                if chars[j] == "\\" && j + 1 < chars.count && !lineBreak(chars[j + 1]) { j += 2 } else { j += 1 }
            }
            if let end = found {
                let latex = String(chars[(start + opener)..<end])
                if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let location = String(chars[..<start]).utf16.count
                    let length = String(chars[start..<(end + closing.count)]).utf16.count
                    result.append(.init(range: NSRange(location: location, length: length), latex: latex, display: display))
                    i = end + closing.count; continue
                }
            }
            i = start + opener
        }
        return result
    }

    private static let aliases = ["lvert": "vert", "rvert": "vert", "lVert": "Vert", "rVert": "Vert",
                                  "dfrac": "frac", "tfrac": "frac", "operatorname": "mathrm", "dots": "ldots"]
    private static let openingDelimiters: Set<String> = ["(", "[", "\\{", "\\lbrace", "\\langle", "\\lfloor", "\\lceil", "\\lgroup"]
    private static let closingDelimiters: Set<String> = [")", "]", "\\}", "\\rbrace", "\\rangle", "\\rfloor", "\\rceil", "\\rgroup"]
    private static let otherDelimiters: Set<String> = [".", "|", "/", "<", ">", "\\|", "\\vert", "\\Vert", "\\backslash",
                                                       "\\uparrow", "\\downarrow", "\\updownarrow", "\\Uparrow", "\\Downarrow", "\\Updownarrow"]

    /// Rewrites LaTeX that SwiftMath can't parse into what it can: a few common aliases (`\lvert`, `\dfrac`, …),
    /// and TeX's fixed-size delimiters (`\bigl(` … `\Bigr)`), which pair into `\left` … `\right` within one group
    /// and otherwise lose their size.
    static func normalized(_ latex: String) -> String {
        let chars = Array(latex)
        func token(at index: Int) -> (String, Int) {
            guard chars[index] == "\\", index + 1 < chars.count else { return (String(chars[index]), index + 1) }
            var end = index + 2
            if chars[index + 1].isLetter { while end < chars.count && chars[end].isLetter { end += 1 } }
            let name = String(chars[(index + 1)..<end])
            return ("\\" + (aliases[name] ?? name), end)
        }
        var out: [String] = []
        // A sized opener waiting for its closer: the piece that becomes `\left`, its delimiter's piece and its group depth.
        var open: [(size: Int, delimiter: Int, depth: Int)] = []
        var depth = 0
        var i = 0
        while i < chars.count {
            let (piece, next) = token(at: i)
            i = next
            if piece == "{" { depth += 1 }
            if piece == "}" { depth -= 1; open.removeAll { $0.depth > depth } }
            if ["&", "\\\\", "\\begin", "\\end"].contains(piece) { open.removeAll() }
            guard piece.range(of: #"^\\[bB]ig(g)?[lrm]?$"#, options: .regularExpression) != nil else { out.append(piece); continue }
            var start = i
            while start < chars.count && chars[start].isWhitespace { start += 1 }
            guard start < chars.count else { continue }
            let (delimiter, end) = token(at: start)
            let opening = openingDelimiters.contains(delimiter), closing = closingDelimiters.contains(delimiter)
            guard opening || closing || otherDelimiters.contains(delimiter) else { continue }
            i = end
            // `\bigl`/`\bigr`/`\bigm` name their side; a bare `\big` takes it from the delimiter.
            let suffix = piece.last ?? "m"
            switch "lrm".contains(suffix) ? suffix : opening ? "l" : closing ? "r" : "m" {
            case "l":
                open.append((out.count, out.count + 1, depth))
                out += ["", delimiter]
            case "r":
                if let last = open.last, last.depth == depth {
                    open.removeLast()
                    out[last.size] = "\\left"
                    out += ["\\right", delimiter]
                } else if delimiter != "." {
                    out.append(delimiter)
                }
            default:
                if delimiter != "." { out.append(delimiter) }
            }
        }
        // An opener left unpaired keeps its plain delimiter, except `.`, which only stands in for one.
        for entry in open where out[entry.delimiter] == "." { out[entry.delimiter] = "" }
        return out.joined()
    }
}

struct MarkdownMathTypeset {
    let image: NSImage
    let baseline: CGFloat
}

final class MarkdownMathAttachment: NSTextAttachment {
    let source: String
    let display: Bool
    let pointSize: CGFloat
    let color: NSColor
    let typeset: MarkdownMathTypeset

    init(source: String, display: Bool, pointSize: CGFloat, color: NSColor, typeset: MarkdownMathTypeset, minimumAscent: CGFloat = 0) {
        self.source = source; self.display = display; self.pointSize = pointSize; self.color = color; self.typeset = typeset
        super.init(data: nil, ofType: nil)
        attachmentCell = MarkdownMathAttachmentCell(typeset: typeset, minimumAscent: minimumAscent)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownMathAttachment else { return false }
        return source == other.source && display == other.display && pointSize == other.pointSize && color == other.color
    }
    override var hash: Int { var h = Hasher(); h.combine(source); h.combine(display); h.combine(pointSize); h.combine(color); return h.finalize() }
}

final class MarkdownMathAttachmentCell: NSTextAttachmentCell {
    let typeset: MarkdownMathTypeset
    /// Height above the baseline: at least the surrounding font's ascender, so a line holding only a formula
    /// (a table cell) puts its baseline where a line of text would.
    let ascent: CGFloat
    init(typeset: MarkdownMathTypeset, minimumAscent: CGFloat = 0) {
        self.typeset = typeset
        ascent = max(typeset.image.size.height - typeset.baseline, minimumAscent)
        super.init(imageCell: typeset.image)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: typeset.image.size.width, height: typeset.baseline + ascent) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -typeset.baseline) }
    /// The origin is relative to the glyph's baseline, like `cellBaselineOffset()`.
    override func cellFrame(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let size = cellSize()
        let scale = size.width > 0 ? min(1, max(0, lineFrag.width) / size.width) : 1
        return NSRect(x: 0, y: -typeset.baseline * scale, width: size.width * scale, height: size.height * scale)
    }
    /// The image fills the bottom of the frame; any room kept above it stays empty.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let height = cellFrame.height * typeset.image.size.height / max(cellSize().height, 1)
        let y = controlView?.isFlipped ?? true ? cellFrame.maxY - height : cellFrame.minY
        typeset.image.draw(in: NSRect(x: cellFrame.minX, y: y, width: cellFrame.width, height: height), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) { draw(withFrame: cellFrame, in: controlView) }
    override func wantsToTrackMouse() -> Bool { false }
}
