import Foundation

/// The saved chats a restore can bring back, open or closed, most recently
/// active first. Each record is decoded again only after its file changes.
final class AgentChatHistory {
    struct Chat: Equatable {
        let id: UUID
        let title: String
        let lastLine: String?
        let engine: DrifterEngine
        /// When its last turn ended; a chat with no finished turn counts from
        /// its record's last save.
        let lastActivity: Date
    }

    let route: AgentChatRoute
    private var cache: [UUID: (modified: Date, chat: Chat?)] = [:]

    init(route: AgentChatRoute) { self.route = route }

    func chats(excluding excluded: Set<UUID> = []) -> [Chat] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: route.directory.path)) ?? []
        var listed = cache.filter { excluded.contains($0.key) }
        for folder in folders {
            guard let id = UUID(uuidString: folder) else { continue }
            if excluded.contains(id) {
                listed[id] = cache[id]
                continue
            }
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: route.recordURL(for: id).path))?[.modificationDate] as? Date
            else { continue }
            if let cached = cache[id], cached.modified == modified {
                listed[id] = cached
                continue
            }
            let chat = route.readRecord(for: id).flatMap { record in
                !record.items.isEmpty
                    ? Chat(id: id, title: record.title, lastLine: AgentChatTranscriptText.lastLine(record.items),
                           engine: record.drifter.engine, lastActivity: record.lastTurnEnd ?? modified)
                    : nil
            }
            listed[id] = (modified, chat)
        }
        cache = listed
        return listed.filter { !excluded.contains($0.key) }.values.compactMap(\.chat).sorted {
            ($0.lastActivity, $0.id.uuidString) > ($1.lastActivity, $1.id.uuidString)
        }
    }
}
