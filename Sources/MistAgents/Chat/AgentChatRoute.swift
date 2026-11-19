import Foundation

struct AgentChatRoute {
    let directory: URL
    private let apps: MistAppRoute

    var legacyBrowserAgentDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent("BrowserAgent", isDirectory: true)
    }

    init(baseDirectory: URL) {
        apps = MistAppRoute(baseDirectory: baseDirectory)
        directory = baseDirectory.appendingPathComponent("MistAgents/Chats", isDirectory: true).standardizedFileURL
    }

    func placeholderURL(for id: UUID) -> URL {
        apps.placeholderURL(.drifter, instance: id)
    }

    func chatDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func attachmentsDirectory(for id: UUID) -> URL {
        chatDirectory(for: id).appendingPathComponent("attachments", isDirectory: true)
    }

    func recordURL(for id: UUID) -> URL { chatDirectory(for: id).appendingPathComponent("chat.json") }

    func writeRecord(_ record: AgentChatRecord, for id: UUID) throws {
        let encoder = JSONEncoder()
        encoder.userInfo[.agentChatImages] = chatDirectory(for: id).appendingPathComponent("images", isDirectory: true)
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: chatDirectory(for: id), withIntermediateDirectories: true)
        try data.write(to: recordURL(for: id), options: .atomic)
    }

    func readRecord(for id: UUID) -> AgentChatRecord? {
        let decoder = JSONDecoder()
        decoder.userInfo[.legacyBrowserAgentDirectory] = legacyBrowserAgentDirectory
        decoder.userInfo[.agentChatAttachments] = attachmentsDirectory(for: id)
        decoder.userInfo[.agentChatImages] = chatDirectory(for: id).appendingPathComponent("images", isDirectory: true)
        guard let data = try? Data(contentsOf: recordURL(for: id)) else { return nil }
        return try? decoder.decode(AgentChatRecord.self, from: data)
    }

    /// Materialize on demand, using a stable name so repeated previews reuse the same file.
    func imageURL(_ image: AgentImageAttachment, for id: UUID) throws -> URL {
        try image.write(to: chatDirectory(for: id).appendingPathComponent("images", isDirectory: true))
    }

    func conversationId(for urlString: String?) -> UUID? {
        apps.resolve(urlString)?.chatId
    }

    static func title(for prompt: String, attachments: [AgentAttachment] = []) -> String {
        guard let line = AgentCodeBlocks.firstTitleLine(in: prompt) else {
            return attachments.files.first?.url.lastPathComponent ?? AgentChatStrings.image
        }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    static func html(title: String, background: String, engine: DrifterEngine, iconPNGBase64: String? = nil) -> String {
        MistAppPlaceholder.html(title: title, background: background, iconPNGBase64: iconPNGBase64,
                                app: .drifter, agent: "drifter \(engine.rawValue)")
    }

    func canonicalURL(for id: UUID) -> URL { apps.url(.drifter, instance: id) }
    func legacyURL(for id: UUID) -> URL { apps.legacyURL(.drifter, instance: id)! }

    func canRecreate(_ id: UUID) -> Bool {
        [recordURL(for: id), canonicalURL(for: id), legacyURL(for: id)].allSatisfy {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)) == nil
        }
    }

    /// Recheck the raw record after pending writes finish; a failed decode never means empty.
    func deleteEmptyChat(_ id: UUID) -> Bool {
        let manager = FileManager.default
        let folder = chatDirectory(for: id)
        guard folder.standardizedFileURL.deletingLastPathComponent().path == directory.path,
              folder.lastPathComponent == id.uuidString,
              let attributes = try? manager.attributesOfItem(atPath: folder.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let names = try? manager.contentsOfDirectory(atPath: folder.path),
              Set(names).isSubset(of: ["chat.json", "attachments", "images"]),
              let data = try? Data(contentsOf: recordURL(for: id)),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = record["items"] as? [Any], items.isEmpty,
              record["queued"] == nil || (record["queued"] as? [Any])?.isEmpty == true,
              record["sessionId"] == nil || record["sessionId"] is NSNull else { return false }
        let placeholders = [canonicalURL(for: id), legacyURL(for: id)]
        for url in placeholders {
            if let attributes = try? manager.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType != .typeRegular { return false }
        }
        do {
            try manager.removeItem(at: folder)
            for url in placeholders where manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return true
        } catch { return false }
    }

    /// The title in a chat's file. Chromium restores a chat tab with the title of its first load,
    /// even after a reload showed the generated one.
    func storedTitle(for id: UUID) -> String? {
        guard let html = try? String(contentsOf: placeholderURL(for: id), encoding: .utf8),
              let start = html.range(of: "<title>"),
              let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex) else { return nil }
        let title = String(html[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
        return title.isEmpty ? nil : title
    }

    /// The agent recorded in a chat's file, which outlives the session that wrote it.
    func storedAgent(for id: UUID) -> DrifterEngine? {
        guard let html = try? String(contentsOf: placeholderURL(for: id), encoding: .utf8),
              let start = html.range(of: "<meta name=\"mist-agent\" content=\""),
              let end = html[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let words = html[start.upperBound..<end].split(separator: " ").map(String.init)
        switch words.first {
        case "claudeCode": return .claude
        case "browserAgent", "drifter": return words.dropFirst().first.flatMap(DrifterEngine.init(rawValue:)) ?? .claude
        default: return nil
        }
    }
}
