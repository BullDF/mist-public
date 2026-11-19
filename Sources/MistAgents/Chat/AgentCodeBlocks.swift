import Foundation

/// Markdown remains the source of truth. All ranges use NSTextStorage's UTF-16 coordinates.
enum AgentCodeBlocks {
    struct Fence {
        let character: Character
        let count: Int
        let language: String

        func closes(_ line: String) -> Bool {
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.count >= count && text.allSatisfy { $0 == character }
        }
    }

    struct Block: Equatable {
        /// Fence ranges exclude their line terminators; content includes its final line terminator.
        let opening: NSRange
        let content: NSRange
        let closing: NSRange
        let language: String
        let languageRange: NSRange?
        var range: NSRange { NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location) }
        var contentEnd: Int { max(content.location, NSMaxRange(content) - 1) }

        func contains(_ selection: NSRange) -> Bool {
            selection.location >= content.location && NSMaxRange(selection) <= contentEnd
        }
    }

    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let caret: Int

        func applying(to text: String) -> String { (text as NSString).replacingCharacters(in: range, with: replacement) }
    }

    static func fence(_ line: String) -> Fence? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let count = text.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        return Fence(character: first, count: count, language: text.dropFirst(count).trimmingCharacters(in: .whitespaces))
    }

    static func blocks(in text: String, editingAt: Int? = nil) -> [Block] {
        let source = text as NSString
        var result: [Block] = []
        var opening: (NSRange, Fence)?
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(location: offset, length: (line as NSString).length)
            if let (start, rule) = opening {
                if rule.closes(line) {
                    let contentStart = min(NSMaxRange(start) + 1, source.length)
                    let openingText = source.substring(with: start) as NSString
                    let languageRange = rule.language.isEmpty ? nil : openingText.range(of: rule.language, options: .backwards)
                    result.append(Block(opening: start, content: NSRange(location: contentStart, length: offset - contentStart),
                                        closing: range, language: rule.language,
                                        languageRange: languageRange.map { NSRange(location: start.location + $0.location, length: $0.length) }))
                    opening = nil
                }
            } else if !(editingAt.map { $0 >= range.location && $0 <= NSMaxRange(range) } ?? false), let rule = fence(line) {
                opening = (range, rule)
            }
            offset += range.length + 1
        }
        return result
    }

    static func containing(_ selection: NSRange, in text: String) -> Block? {
        blocks(in: text).first { $0.contains(selection) }
    }

    static func firstTitleLine(in text: String) -> String? {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && fence($0) == nil }
    }

    static func line(at caret: Int, in text: NSString) -> NSRange {
        let prefix = text.substring(to: caret) as NSString
        let newline = prefix.range(of: "\n", options: .backwards)
        let start = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        let suffix = text.range(of: "\n", range: NSRange(location: caret, length: text.length - caret))
        return NSRange(location: start, length: (suffix.location == NSNotFound ? text.length : suffix.location) - start)
    }

    /// Called only after insertion of a single backtick. Parse the preceding text so the newly
    /// typed fence cannot prematurely close the block whose content is being split.
    static func typedBacktick(in text: String, caret: Int) -> Edit? {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }
        let typedLine = line(at: caret, in: source)
        guard NSMaxRange(typedLine) == caret, source.substring(with: typedLine) == "```" else { return nil }
        let before = source.replacingCharacters(in: NSRange(location: caret - 1, length: 1), with: "")
        if let old = containing(NSRange(location: caret - 1, length: 0), in: before) {
            let closing = NSRange(location: old.closing.location + 1, length: old.closing.length)
            let above = source.substring(with: NSRange(location: old.content.location, length: typedLine.location - old.content.location))
            let belowStart = min(caret + 1, closing.location)
            let below = source.substring(with: NSRange(location: belowStart, length: closing.location - belowStart))
            let openingText = source.substring(with: old.opening)
            let closingText = source.substring(with: closing)
            let left = above.isEmpty ? "" : openingText + "\n" + above + closingText + "\n"
            let right = below.isEmpty ? "" : "\n" + openingText + "\n" + below + closingText
            return Edit(range: NSRange(location: old.opening.location, length: NSMaxRange(closing) - old.opening.location),
                        replacement: left + right, caret: old.opening.location + (left as NSString).length)
        }
        return nil
    }

    static func openFence(in text: String, caret: Int) -> Edit? {
        let source = text as NSString
        guard caret >= 0, caret <= source.length,
              containing(NSRange(location: caret, length: 0), in: text) == nil else { return nil }
        let range = line(at: caret, in: source)
        let value = source.substring(with: range)
        let count = value.prefix { $0 == "`" }.count
        guard NSMaxRange(range) == caret, count >= 3, !value.dropFirst(count).contains("`") else { return nil }
        return Edit(range: range, replacement: value + "\n\n" + String(repeating: "`", count: count), caret: caret + 1)
    }

    static func unwrap(_ block: Block, in text: String) -> Edit {
        let content = (text as NSString).substring(with: NSRange(location: block.content.location, length: block.contentEnd - block.content.location))
        return Edit(range: block.range, replacement: content, caret: block.opening.location)
    }

    static func joinAfter(_ block: Block, in text: String) -> Edit? {
        let source = text as NSString
        guard NSMaxRange(block.closing) < source.length else { return nil }
        let after = line(at: NSMaxRange(block.closing) + 1, in: source)
        let content = source.substring(with: NSRange(location: block.content.location, length: block.contentEnd - block.content.location))
        let joined = source.substring(with: block.opening) + "\n" + content + source.substring(with: after) + "\n" + source.substring(with: block.closing)
        return Edit(range: NSRange(location: block.opening.location, length: NSMaxRange(after) - block.opening.location),
                    replacement: joined, caret: block.contentEnd)
    }

    static func exit(_ block: Block, down: Bool, in text: String) -> Edit {
        let length = (text as NSString).length
        let edge = down ? NSMaxRange(block.closing) : block.opening.location
        let needsLine = down ? edge == length : edge == 0
        return Edit(range: NSRange(location: edge, length: 0), replacement: needsLine ? "\n" : "",
                    caret: down ? edge + 1 : (needsLine ? 0 : edge - 1))
    }

    static func backwardDelete(in text: String, caret: Int) -> Edit? {
        for block in blocks(in: text) {
            if caret == block.content.location { return unwrap(block, in: text) }
            if caret == NSMaxRange(block.closing) + 1 { return joinAfter(block, in: text) }
        }
        return nil
    }

    static func forwardDelete(in text: String, caret: Int) -> Edit? {
        for block in blocks(in: text) {
            if caret == block.contentEnd {
                return joinAfter(block, in: text) ?? Edit(range: NSRange(location: caret, length: 0), replacement: "", caret: caret)
            }
            if caret == block.opening.location - 1 {
                return Edit(range: NSRange(location: caret, length: 0), replacement: "", caret: caret)
            }
        }
        return nil
    }

    static func clamp(_ selection: NSRange, from old: NSRange, in text: String) -> NSRange {
        var start = selection.location
        var end = NSMaxRange(selection)
        for block in blocks(in: text, editingAt: old.length == 0 ? old.location : nil) {
            for (fence, opening) in [(block.opening, true), (block.closing, false)] {
                if selection.length > 0 {
                    if start > fence.location && start < NSMaxRange(fence) { start = fence.location }
                    if end > fence.location && end < NSMaxRange(fence) { end = NSMaxRange(fence) }
                } else if start >= fence.location && start <= NSMaxRange(fence) {
                    let backwards = start < old.location
                    let target: Int
                    if opening {
                        target = backwards && fence.location > 0 ? fence.location - 1 : block.content.location
                    } else {
                        target = !backwards && NSMaxRange(fence) < (text as NSString).length ? NSMaxRange(fence) + 1 : block.contentEnd
                    }
                    return NSRange(location: target, length: 0)
                }
            }
        }
        return NSRange(location: start, length: end - start)
    }
}
