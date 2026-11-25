import Foundation

struct ClaudeCodeSlashCommand: Equatable, Sendable {
    let name: String
    let description: String
    let argumentHint: String
    var builtin = false
    /// Home and repository skills work anywhere in a message.
    var isSkill: Bool?
    var displayDescription: String { description.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    /// Past a message's first token, a leading tab mention included, a command is plain text that Claude acts on only
    /// by running a skill.
    /// `builtin` marks bundled skills and built-in commands alike, so it decides only without the skill list.
    var worksInText: Bool { isSkill ?? !builtin }


}

/// UTF-16 ranges shared by completion and every surface that highlights commands.
enum ClaudeCodeSlashTokenizer {
    struct Token: Equatable {
        let range: NSRange
        let commandRange: NSRange
        let name: String
    }

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let previous = index == text.startIndex ? nil : text[text.index(before: index)]
            guard text[index] == "/", previous == nil || previous!.isWhitespace || "(\"'".contains(previous!) else {
                index = text.index(after: index)
                continue
            }
            let end = text[index...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
            var commandEnd = end
            while commandEnd > index, ".,;:!?)\"'".contains(text[text.index(before: commandEnd)]) {
                commandEnd = text.index(before: commandEnd)
            }
            let nameStart = text.index(after: index)
            tokens.append(.init(range: NSRange(index..<end, in: text), commandRange: NSRange(index..<commandEnd, in: text),
                                name: String(text[nameStart..<commandEnd])))
            index = end
        }
        return tokens
    }

    static func styledRanges(in text: String, commands: Set<String>) -> [NSRange] {
        tokens(in: text).filter { commands.contains($0.name) }.map(\.commandRange)
    }
}

struct ClaudeCodeSlashQuery: Equatable {
    let text: String
    let tokenRange: NSRange
    let isFirstToken: Bool

    func completionRange(in text: String) -> NSRange {
        var range = tokenRange
        let source = text as NSString
        if NSMaxRange(range) < source.length, source.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == " " {
            range.length += 1
        }
        return range
    }

    /// AppKit caret positions are UTF-16 offsets, not Swift character offsets.
    static func at(_ selection: NSRange, in text: String) -> Self? {
        at(selection, in: text, tokens: ClaudeCodeSlashTokenizer.tokens(in: text))
    }

    /// `tokens` are `text`'s, already scanned.
    static func at(_ selection: NSRange, in text: String, tokens: [ClaudeCodeSlashTokenizer.Token]) -> Self? {
        let length = text.utf16.count
        guard selection.length == 0, selection.location >= 1,
              selection.location != NSNotFound, selection.location <= length,
              selection.location == length || String.Index(utf16Offset: selection.location, in: text).samePosition(in: text) != nil
        else { return nil }
        for token in tokens {
            let range = token.range
            guard selection.location > range.location, selection.location <= NSMaxRange(range),
                  let start = Range(range, in: text)?.lowerBound,
                  start == text.startIndex || text[text.index(before: start)].isWhitespace else { continue }
            return Self(text: (text as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1)),
                        tokenRange: range, isFirstToken: text[..<start].allSatisfy(\.isWhitespace))
        }
        return nil
    }
}

struct ClaudeCodeSlashMatch: Equatable {
    let command: ClaudeCodeSlashCommand
    /// Character offsets in the command name, excluding the slash.
    let matchedCharacters: [Int]
}

enum ClaudeCodeSlashMatcher {
    static func matches(_ commands: [ClaudeCodeSlashCommand], query: ClaudeCodeSlashQuery) -> [ClaudeCodeSlashMatch] {
        matches(commands.filter { query.isFirstToken || $0.worksInText }, query: query.text)
    }
    static func matches(_ commands: [ClaudeCodeSlashCommand], query: String) -> [ClaudeCodeSlashMatch] {
        var ranked = [[ClaudeCodeSlashMatch]](repeating: [], count: 3)
        for command in commands {
            let name = command.name
            if query.isEmpty {
                ranked[0].append(.init(command: command, matchedCharacters: []))
            } else if let range = name.range(of: query, options: .caseInsensitive) {
                let start = name.distance(from: name.startIndex, to: range.lowerBound)
                let end = name.distance(from: name.startIndex, to: range.upperBound)
                ranked[start == 0 ? 0 : 1].append(.init(command: command, matchedCharacters: Array(start..<end)))
            } else {
                let characters = Array(name)
                var offsets: [Int] = []
                var next = 0
                for character in query {
                    guard let index = characters.indices.dropFirst(next).first(where: {
                        String(characters[$0]).compare(String(character), options: .caseInsensitive) == .orderedSame
                    }) else { break }
                    offsets.append(index)
                    next = index + 1
                }
                if offsets.count == query.count { ranked[2].append(.init(command: command, matchedCharacters: offsets)) }
            }
        }
        if !query.isEmpty {
            for index in ranked.indices {
                ranked[index].sort { $0.command.name.compare($1.command.name, options: .caseInsensitive) == .orderedAscending }
            }
        }
        return ranked.flatMap { $0 }
    }
}
