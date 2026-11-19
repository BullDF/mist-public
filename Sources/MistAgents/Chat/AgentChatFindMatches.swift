import Foundation

/// Matches in transcript order. Callers identify the unchanged row prefix on updates.
struct AgentChatFindMatches {
    struct Match: Equatable {
        var row: Int
        var rowId: String
        var ordinal: Int
        var range: NSRange
    }

    private var query = ""
    private var matches: [Match] = []
    private var rowOffsets: [Int] = []
    private(set) var currentIndex: Int?
    var current: Match? { currentIndex.map { matches[$0] } }
    var count: Int { matches.count }

    mutating func search(_ query: String, ids: [String], texts: [String], start: (row: Int, location: Int)) {
        self.query = query
        self.matches = []
        rowOffsets = []
        currentIndex = nil
        update(ids: ids, texts: texts, from: 0)
        select(at: start)
    }

    mutating func update(ids: [String], texts: [String], from first: Int) {
        precondition(ids.count == texts.count)
        let old = current
        let oldIndex = currentIndex
        let first = min(max(0, first), ids.count, rowOffsets.count)
        // No comparisons or searches in the unchanged prefix.
        let kept = first < rowOffsets.count ? rowOffsets[first] : matches.count
        matches.removeSubrange(kept..<matches.count)
        rowOffsets.removeSubrange(first..<rowOffsets.count)
        for row in first..<ids.count {
            rowOffsets.append(matches.count)
            if !query.isEmpty {
                for (ordinal, range) in TextFind.ranges(of: query, in: texts[row]).enumerated() {
                    matches.append(Match(row: row, rowId: ids[row], ordinal: ordinal, range: range))
                }
            }
        }
        if let old, old.row < first {
            currentIndex = oldIndex
            return
        }
        let row = old.flatMap { match in ids[first...].firstIndex(of: match.rowId) }
        if let old, let row {
            let index = rowOffsets[row] + old.ordinal
            let end = row + 1 < rowOffsets.count ? rowOffsets[row + 1] : matches.count
            if index < end { currentIndex = index; return }
        }
        select(at: (row ?? old?.row ?? 0, old?.range.location ?? 0))
    }

    mutating func step(forward: Bool) {
        guard let currentIndex else { return }
        self.currentIndex = TextFind.step(currentIndex, count: count, forward: forward)
    }

    private mutating func select(at start: (row: Int, location: Int)) {
        guard !matches.isEmpty else { currentIndex = nil; return }
        var lower = 0
        var upper = matches.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let match = matches[middle]
            if match.row < start.row || (match.row == start.row && match.range.location < start.location) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        currentIndex = lower < matches.count ? lower : 0
    }
}
