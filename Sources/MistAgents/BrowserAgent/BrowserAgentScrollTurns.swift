import Foundation

/// Record once per tab in each chat turn; restore only tabs that moved.
struct BrowserAgentScrollTurns {
    struct Turn {
        var recorded: Set<Int> = []
        var scrolled: Set<Int> = []
    }
    private var turns: [UUID: Turn] = [:]

    mutating func record(chat: UUID, tab: Int) -> Bool {
        var turn = turns[chat] ?? Turn()
        let inserted = turn.recorded.insert(tab).inserted
        turns[chat] = turn
        return inserted
    }

    mutating func mark(chat: UUID, tab: Int) {
        guard turns[chat]?.recorded.contains(tab) == true else { return }
        turns[chat]?.scrolled.insert(tab)
    }

    mutating func endTurn(chat: UUID) -> (restore: Set<Int>, cleanup: Set<Int>) {
        guard let turn = turns.removeValue(forKey: chat) else { return ([], []) }
        return (turn.scrolled, turn.recorded.subtracting(turn.scrolled))
    }
}
