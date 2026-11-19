import Foundation

struct AgentTabMention: Codable, Equatable, Sendable {
    let tabId: Int
    let title: String
    let url: String
    var closed = false
    var range = NSRange(location: 0, length: 0)
    var position: Int? = nil
    var group: Group? = nil

    struct Group: Codable, Equatable, Sendable {
        let token: String
        var color: String
        var tabs: [AgentTabMention]
    }

    var key: String { group.map { "group:\($0.token)" } ?? "tab:\(tabId)" }
    var isGroup: Bool { group != nil }

    var tokenText: String { "@" + String(title.prefix(40)) + (title.count > 40 ? "…" : "") }
    var secondaryText: String {
        if let group {
            return String(format: NSLocalizedString("browser.agentChat.mentionGroupTabCount", value: "%d tabs", comment: "Tab group mention - Number of tabs in the group"), group.tabs.count)
        }
        guard let url = URLComponents(string: url) else { return self.url }
        return (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path
    }

    func secondaryLabel(in tabs: [Self]) -> String {
        guard !isGroup, let position, tabs.filter({ !$0.isGroup && $0.title == title && $0.secondaryText == secondaryText }).count > 1 else { return secondaryText }
        return secondaryText + " · " + String(format: NSLocalizedString("browser.agentChat.mentionTabPosition", value: "Tab %d", comment: "Tab mention - Window tab position used to tell otherwise identical tabs apart"), position)
    }
}

/// UTF-16 ranges match TextKit. Mention identity is carried as data, never recovered from prompt text.
struct AgentMentionText: Equatable {
    var text: String
    var mentions: [AgentTabMention] = []

    var normalized: Self {
        var value = self
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            let start = NSMaxRange(mention.range)
            let source = value.text as NSString
            guard start <= source.length else { continue }
            var end = start
            while end < source.length, source.substring(with: NSRange(location: end, length: 1)) == " " { end += 1 }
            if end - start > 1 { value.replace(NSRange(location: start, length: end - start), with: " ") }
        }
        while value.text.last?.isWhitespace == true { value.text.removeLast() }
        return value
    }

    func swallowsSpace(at range: NSRange, replacement: String?) -> Bool {
        guard replacement == " ", range.length == 0, range.location > 0, range.location <= text.utf16.count,
              (text as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == " " else { return false }
        return mentions.contains { NSMaxRange($0.range) == range.location - 1 }
    }

    static func query(in text: String, selection: NSRange, mentions: [AgentTabMention]) -> NSRange? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length,
              !mentions.contains(where: { selection.location > $0.range.location && selection.location <= NSMaxRange($0.range) }) else { return nil }
        var start = selection.location
        while start > 0 {
            let char = source.substring(with: NSRange(location: start - 1, length: 1))
            if char == "@" {
                if start > 1 {
                    let previous = source.substring(with: NSRange(location: start - 2, length: 1))
                    guard previous.rangeOfCharacter(from: .whitespacesAndNewlines.union(.punctuationCharacters)) != nil else { return nil }
                }
                var end = selection.location
                while end < source.length,
                      source.substring(with: NSRange(location: end, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                    end += 1
                }
                return NSRange(location: start - 1, length: end - start + 1)
            }
            if char.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return nil }
            start -= 1
        }
        return nil
    }

    /// Whitespace is ignored on both sides, so `@myp` (an @ query ends at a space) finds "My PRs".
    static func matches(_ tabs: [AgentTabMention], query: String) -> [AgentTabMention] {
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { !$0.isWhitespace }
        }
        let query = fold(query)
        return tabs.enumerated().filter { query.isEmpty || fold($0.element.title).contains(query) || (!$0.element.isGroup && fold($0.element.url).contains(query)) }
            .sorted {
                let lhs = fold($0.element.title).hasPrefix(query), rhs = fold($1.element.title).hasPrefix(query)
                return lhs == rhs ? $0.offset < $1.offset : lhs
            }.map(\.element)
    }

    static func popupRows(_ tabs: [AgentTabMention], groups: [AgentTabMention] = [], query: String, currentTabId: Int?, mentioned: Set<String>) -> (current: AgentTabMention?, groups: [AgentTabMention], others: [AgentTabMention]) {
        let matches = matches(tabs, query: query)
        let current = matches.first { !$0.isGroup && $0.tabId == currentTabId && !mentioned.contains($0.key) }
        return (current, self.matches(groups, query: query), matches.filter { $0.key != current?.key })
    }

    func atomicRange(_ range: NSRange) -> NSRange {
        Self.atomicRange(range, atoms: mentions.map(\.range))
    }

    /// Widens `range` over every token it touches, so the token edits as one unit.
    static func atomicRange(_ range: NSRange, atoms: [NSRange]) -> NSRange {
        atoms.reduce(range) { result, atom in
            if NSIntersectionRange(result, atom).length > 0 ||
                (result.length == 0 && result.location > atom.location && result.location < NSMaxRange(atom)) {
                return NSUnionRange(result, atom)
            }
            return result
        }
    }

    mutating func replace(_ range: NSRange, with replacement: String, mention: AgentTabMention? = nil) {
        let range = atomicRange(range)
        let delta = (replacement as NSString).length - range.length
        mentions = mentions.compactMap {
            guard NSIntersectionRange($0.range, range).length == 0 else { return nil }
            var value = $0
            if value.range.location >= NSMaxRange(range) { value.range.location += delta }
            return value
        }
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        if var mention {
            mention.range = NSRange(location: range.location, length: (mention.tokenText as NSString).length)
            mentions.append(mention)
            mentions.sort { $0.range.location < $1.range.location }
        }
    }

    /// Tokens take their open tab's current title and URL; a tab missing from `tabs` keeps its stored ones, marked closed.
    func refreshed(from tabs: [AgentTabMention], groups: [AgentTabMention] = []) -> Self {
        let open = Dictionary(tabs.map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
        var value = self
        for mention in mentions.sorted(by: { $0.range.location > $1.range.location }) {
            var current = mention
            if let group = mention.group {
                if let live = groups.first(where: { $0.group?.token == group.token }) {
                    current = live
                    current.range = mention.range
                } else {
                    current.closed = true
                }
            } else if let tab = open[mention.tabId] {
                current = AgentTabMention(tabId: mention.tabId, title: tab.title, url: tab.url, range: mention.range, position: mention.position)
            } else {
                current.closed = true
            }
            if current != mention { value.replace(mention.range, with: current.tokenText, mention: current) }
        }
        return value
    }

    var agentText: String { agentText(tabIds: true) }

    /// Claude Code has no tab tools, so its rows leave tabId out.
    func agentText(tabIds: Bool) -> String {
        let value = normalized
        guard !value.mentions.isEmpty else { return value.text }
        func line(_ value: String) -> String { value.components(separatedBy: .newlines).joined(separator: " ") }
        var result = value.text
        let tabs = value.mentions.filter { !$0.isGroup }
        if !tabs.isEmpty {
            result += "\n\nTabs the user mentioned (\(tabIds ? "tabId · " : "")title · URL):\n" + tabs.map {
            "\(tabIds ? "\($0.tabId) · " : "")\(line($0.title))\($0.closed ? " (closed)" : "") · \(line($0.url))"
        }.joined(separator: "\n")
        }
        var seen = Set<String>()
        let groups = value.mentions.filter { $0.group.map { seen.insert($0.token).inserted } ?? false }
        if !groups.isEmpty {
            result += "\n\nTab groups the user mentioned, with their tabs when the message was sent (\(tabIds ? "groupId · " : "")name, then \(tabIds ? "tabId · " : "")title · URL):\n"
            result += groups.map { mention in
                let group = mention.group!
                let name = "\(tabIds ? "\(line(group.token)) · " : "")\(line(mention.title))\(mention.closed ? " (closed)" : "")"
                return ([name] + group.tabs.map { "  \(tabIds ? "\($0.tabId) · " : "")\(line($0.title)) · \(line($0.url))" }).joined(separator: "\n")
            }.joined(separator: "\n")
        }
        return result
    }
}
