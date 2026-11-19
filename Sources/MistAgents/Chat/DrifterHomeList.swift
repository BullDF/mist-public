import Foundation

enum DrifterHomeStatus: Equatable {
    /// `background`: idle, with a background task or Monitor still running.
    case working, needsYou, background, idle, failed

    /// `waitsForUser`: a hand-off card waits for Johnny's Done.
    init(_ status: AgentConversationStatus, hasBackgroundTasks: Bool = false, waitsForUser: Bool = false) {
        switch status {
        case .starting, .running: self = .working
        case .awaitingPermission: self = .needsYou
        case .failed: self = .failed
        case .idle where !waitsForUser: self = hasBackgroundTasks ? .background : .idle
        case .idle, .dormant, .ended: self = waitsForUser ? .needsYou : .idle
        }
    }
}

struct DrifterHomeChat: Equatable, Identifiable {
    let id: UUID
    let title: String
    let lastLine: String?
    let status: DrifterHomeStatus?
    let engine: DrifterEngine
    let time: Date
    let sortDate: Date
    var children: [DrifterHomeChat] = []
}

enum DrifterHomeList {
    static let historyPageSize = 20

    static func ongoing(_ chats: [DrifterHomeChat], parent: [UUID: UUID]) -> [DrifterHomeChat] {
        let ids = Set(chats.map(\.id))
        func ordered(_ rows: [DrifterHomeChat]) -> [DrifterHomeChat] {
            rows.sorted { ($0.sortDate, $0.id.uuidString) > ($1.sortDate, $1.id.uuidString) }
        }
        let children = Dictionary(grouping: chats.filter { parent[$0.id].map(ids.contains) == true }) { parent[$0.id]! }
        var visited = Set<UUID>()
        func descendants(_ id: UUID) -> [DrifterHomeChat] {
            ordered(children[id] ?? []).flatMap { child -> [DrifterHomeChat] in
                guard visited.insert(child.id).inserted else { return [] }
                var row = child
                row.children = []
                return [row] + descendants(child.id)
            }
        }
        var rows: [DrifterHomeChat] = []
        let roots = ordered(chats.filter { parent[$0.id].map(ids.contains) != true })
        // A malformed parent cycle still produces a usable family instead of losing its chats.
        for chat in roots + ordered(chats) where !visited.contains(chat.id) {
            visited.insert(chat.id)
            var row = chat
            row.children = descendants(chat.id)
            rows.append(row)
        }
        return ordered(rows)
    }

    /// Where each chat the Ongoing list shows sits: family by family in list order, each its root then its children.
    /// Changes to it alone animate (a chat joining, leaving or moving), never a chat updating in place.
    static func arrangement(_ rows: [DrifterHomeChat]) -> [[UUID]] {
        rows.map { [$0.id] + $0.children.map(\.id) }
    }

    static func history(_ chats: [AgentChatHistory.Chat], query: String, limit: Int) -> (rows: [AgentChatHistory.Chat], hasMore: Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? chats : chats.filter { $0.title.localizedStandardContains(query) }
        let limit = max(0, limit)
        return (Array(filtered.prefix(limit)), filtered.count > limit)
    }

    static func timeLabel(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            format = format.hour().minute()
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            format = format.month(.abbreviated).day()
        } else {
            format = format.month(.abbreviated).day().year()
        }
        return date.formatted(format)
    }
}
