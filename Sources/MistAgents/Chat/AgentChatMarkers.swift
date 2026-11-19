import Foundation

struct AgentChatMarker: Codable, Equatable, Identifiable {
    /// The persisted transcript item's ID.
    var id: String
    var name: String
}

enum AgentChatMarkers {
    static func ordered(_ markers: [AgentChatMarker], itemIDs: [String]) -> [AgentChatMarker] {
        var byID: [String: AgentChatMarker] = [:]
        for marker in markers where byID[marker.id] == nil { byID[marker.id] = marker }
        return itemIDs.compactMap { byID[$0] }
    }

    @discardableResult
    static func toggle(_ markers: inout [AgentChatMarker], itemId: String, defaultName: String,
                       itemIDs: [String]) -> AgentChatMarker? {
        if let index = markers.firstIndex(where: { $0.id == itemId }) {
            markers.remove(at: index)
            return nil
        }
        guard itemIDs.contains(itemId) else { return nil }
        let marker = AgentChatMarker(id: itemId, name: defaultName)
        markers = ordered(markers + [marker], itemIDs: itemIDs)
        return marker
    }

    static func rename(_ markers: inout [AgentChatMarker], itemId: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = markers.firstIndex(where: { $0.id == itemId }) else { return }
        markers[index].name = name
    }

    static func defaultName(text: String, position: Int) -> String {
        var line = AgentCodeBlocks.firstTitleLine(in: text) ?? ""
        // Repeated prefixes handle nested quotes and lists, e.g. "> - **Heading**".
        while true {
            let stripped = line.replacingOccurrences(of: #"^(?:#+\s*|>\s*|[-*+]\s+|\d+\.\s+)"#,
                                                      with: "", options: .regularExpression)
            if stripped == line { break }
            line = stripped
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Inline code and bold markers anywhere in the line, as in "I stopped the `main-live` stack".
        for syntax in ["`", "**", "__"] { line = line.replacingOccurrences(of: syntax, with: "") }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !line.isEmpty else { return AgentChatStrings.markerNumber(position) }
        guard line.count > 40 else { return line }
        let prefix = String(line.prefix(40))
        // A boundary exactly after the fortieth character keeps that whole word.
        if line.dropFirst(40).first?.isWhitespace == true { return prefix + "…" }
        if let space = prefix.lastIndex(of: " ") { return String(prefix[..<space]) + "…" }
        return prefix + "…"
    }

    static func applyGeneratedName(_ markers: inout [AgentChatMarker], itemId: String, name: String, replacing defaultName: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != defaultName,
              let index = markers.firstIndex(where: { $0.id == itemId }), markers[index].name == defaultName else { return }
        markers[index].name = name
    }

    static func namingInput(items: [AgentChatItem], itemId: String) -> (text: String, context: String?)? {
        guard let index = items.firstIndex(where: { $0.id == itemId }), let text = items[index].markerText else { return nil }
        var context: String?
        if case .assistantText = items[index].kind {
            context = items[..<index].last(where: { if case .userMessage = $0.kind { return true }; return false })?.markerText
        }
        return (text, context)
    }
}

enum AgentChatMarkerNavigation {
    static func step(tops: [CGFloat], targets: [CGFloat], current: CGFloat, anchor: CGFloat, forward: Bool) -> Int? {
        precondition(tops.count == targets.count)
        let indices = forward ? Array(tops.indices) : Array(tops.indices.reversed())
        return indices.first { index in
            abs(targets[index] - current) > 1 && (forward ? tops[index] > anchor + 1 : tops[index] < anchor - 1)
        }
    }
}

extension AgentChatItem {
    var markerText: String? {
        switch kind {
        case let .userMessage(text, _), let .assistantText(text, _): return text
        default: return nil
        }
    }
}
