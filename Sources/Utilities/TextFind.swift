import Foundation

enum TextFind {
    static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var offset = 0
        var result: [NSRange] = []
        while offset < source.length {
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: source.length - offset))
            guard match.location != NSNotFound, match.length > 0 else { break }
            result.append(match)
            offset = NSMaxRange(match)
        }
        return result
    }

    static func current(in ranges: [NSRange], at location: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        return ranges.firstIndex { $0.location >= location } ?? 0
    }

    static func step(_ index: Int, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        return (index + (forward ? 1 : count - 1)) % count
    }
}
