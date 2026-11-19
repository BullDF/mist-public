import Foundation

enum SlackMrkdwn {
    static func resolvingMentions(_ text: String, user: (String) -> String?, channel: (String) -> String?) -> String {
        replace(text, #"<([^<>\n]+)>"#) { match, source in
            let token = source.substring(with: match.range(at: 1))
            let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let id = parts[0]
            let label = parts.count == 2 ? parts[1] : nil
            if id.range(of: #"^@[UW][A-Z0-9]+$"#, options: .regularExpression) != nil {
                let userID = String(id.dropFirst())
                return "@" + (label ?? user(userID) ?? userID)
            }
            if id.range(of: #"^#C[A-Z0-9]+$"#, options: .regularExpression) != nil {
                let channelID = String(id.dropFirst())
                if let label { return "#" + label }
                return channel(channelID) ?? "#" + channelID
            }
            if ["!here", "!channel", "!everyone"].contains(token) { return "@" + token.dropFirst() }
            if id.range(of: #"^!subteam\^S[A-Z0-9]+$"#, options: .regularExpression) != nil {
                if let label { return label.hasPrefix("@") ? label : "@" + label }
                return "@" + id.dropFirst("!subteam^".count)
            }
            if let label, id.hasPrefix("https://") || id.hasPrefix("http://") { return "[" + label + "](" + id + ")" }
            return source.substring(with: match.range)
        }
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            result = (result as NSString).replacingCharacters(in: match.range, with: transform(match, source))
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var protected: [String] = []
        func token(_ value: String) -> String { protected.append(value); return "\u{001F}\(protected.count - 1)\u{001F}" }
        var value = replace(text, "`([^`\\n]+)`") { m, s in token("`" + escape(s.substring(with: m.range(at: 1))) + "`") }
        value = replace(value, #"!?\[([^\]]*)\]\(([^\s)]+)\)|<(https?://[^>]+)>"#) { m, s in
            if m.range(at: 3).location != NSNotFound { return token("<" + escape(s.substring(with: m.range(at: 3))) + ">") }
            return token("<" + escape(s.substring(with: m.range(at: 2))) + "|" + escape(s.substring(with: m.range(at: 1))) + ">")
        }
        value = escape(value)
        for (marker, output) in [("***", "*_"), ("___", "*_"), ("**", "*"), ("__", "*"), ("~~", "~"), ("*", "_"), ("_", "_")] {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            value = replace(value, "(?<![\\p{L}\\p{N}_*])" + escaped + "(?=\\S)(.+?)(?<=\\S)" + escaped + "(?![\\p{L}\\p{N}_*])") { m, s in
                token(output + s.substring(with: m.range(at: 1)) + String(output.reversed()))
            }
        }
        for index in protected.indices.reversed() { value = value.replacingOccurrences(of: "\u{001F}\(index)\u{001F}", with: protected[index]) }
        return value
    }

    static func convert(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        let indentWidth = lines.compactMap { line -> Int? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil else { return nil }
            let count = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            return count > 0 ? count : nil
        }.min() ?? 4
        var result: [String] = [], fence: String?, index = 0
        func cells(_ line: String) -> [String] {
            var parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "|")
            if parts.first == "" { parts.removeFirst() }; if parts.last == "" { parts.removeLast() }
            return parts.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"[*_~`]"#, with: "", options: .regularExpression) }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if let active = fence {
                if trimmed.hasPrefix(active), trimmed.dropFirst(active.count).allSatisfy({ $0 == active.first! || $0.isWhitespace }) { result.append("```"); fence = nil }
                else { result.append(escape(line)) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first! })); result.append("```"); continue
            }
            if index < lines.count, line.contains("|"), lines[index].contains("|"), !cells(lines[index]).isEmpty,
               cells(lines[index]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                var rows = [cells(line)]; index += 1
                while index < lines.count, lines[index].contains("|"), !lines[index].isEmpty { rows.append(cells(lines[index])); index += 1 }
                let widths = (0..<(rows.map(\.count).max() ?? 0)).map { col in rows.map { col < $0.count ? $0[col].count : 0 }.max() ?? 0 }
                result.append("```")
                result += rows.map { row in escape(widths.indices.map { col in let cell = col < row.count ? row[col] : ""; return cell + String(repeating: " ", count: widths[col] - cell.count) }.joined(separator: " | ")) }
                result.append("```"); continue
            }
            if trimmed.range(of: #"^(?:-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { result.append("──────────"); continue }
            if trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                let heading = trimmed.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                result.append("*" + inline(heading) + "*"); continue
            }
            if trimmed.hasPrefix("> ") { result.append("> " + inline(String(trimmed.dropFirst(2)))); continue }
            if trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                let spaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                var body = String(trimmed.dropFirst(2)), bullet = "•"
                if body.hasPrefix("[ ] ") { bullet = "☐"; body = String(body.dropFirst(4)) }
                else if body.lowercased().hasPrefix("[x] ") { bullet = "☑"; body = String(body.dropFirst(4)) }
                result.append(String(repeating: " ", count: (spaces / indentWidth) * 4) + bullet + " " + inline(body)); continue
            }
            result.append(inline(line))
        }
        if fence != nil { result.append("```") }
        return result.joined(separator: "\n")
    }

    static func chunks(_ markdown: String, limit: Int = 3900) -> [String] {
        precondition(limit >= 16)
        var remaining = convert(markdown), result: [String] = [], inCode = false
        while !remaining.isEmpty {
            let prefix = inCode ? "```\n" : ""
            if prefix.count + remaining.count <= limit {
                let chunk = (prefix + remaining).trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { result.append(chunk) }
                break
            }
            let capacity = limit - prefix.count - 4
            var end = remaining.index(remaining.startIndex, offsetBy: min(capacity, remaining.count))
            if end < remaining.endIndex {
                let candidate = String(remaining[..<end])
                if let boundary = candidate.range(of: "\n\n", options: .backwards) ?? candidate.range(of: "\n", options: .backwards), boundary.lowerBound > candidate.startIndex {
                    let before = String(candidate[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if before != "```" { end = boundary.lowerBound }
                }
            }
            let body = String(remaining[..<end])
            for line in body.components(separatedBy: "\n") where line == "```" { inCode.toggle() }
            let chunk = (prefix + body + (inCode ? "\n```" : "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remaining = String(remaining[end...])
            if remaining.hasPrefix("\n") { remaining.removeFirst() }
            if !inCode { remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }
}
