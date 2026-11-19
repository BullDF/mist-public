import Foundation

/// The agent folders seen lately, by group token. Chromium's recently-closed
/// stack outlives the folders, relaunches included, so ⌘⇧T can tell an entry
/// of agent tabs from the user's and skip it.
struct BrowserAgentClosedFolders {
    static let limit = 100
    let url: URL
    private(set) var tokens: [String]

    init(url: URL) {
        self.url = url
        tokens = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
    }

    mutating func insert(_ token: String) {
        let token = token.uppercased()
        guard !token.isEmpty, !tokens.contains(token) else { return }
        tokens.append(token)
        if tokens.count > Self.limit { tokens.removeFirst(tokens.count - Self.limit) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(tokens).write(to: url, options: .atomic)
    }

    func contains(_ token: String) -> Bool { !token.isEmpty && tokens.contains(token.uppercased()) }

    enum Pick: Equatable {
        /// The newest entry isn't the agent's: Chromium's own restore runs.
        case chromium
        /// Restore this entry, skipping the newer agent ones.
        case entry(Int64)
        /// Only agent entries are left.
        case nothing
    }

    /// `tabs` lists the recently-closed tabs newest entry first, each with its
    /// entry's session id and the group it was closed from. An entry whose
    /// tabs all come from agent folders is skipped.
    func pick(_ tabs: [(entry: Int64, group: String)]) -> Pick {
        let known = Set(tokens)
        var order: [Int64] = []
        var agentOnly: [Int64: Bool] = [:]
        for tab in tabs {
            let isAgent = known.contains(tab.group.uppercased())
            if let current = agentOnly[tab.entry] {
                agentOnly[tab.entry] = current && isAgent
            } else {
                order.append(tab.entry)
                agentOnly[tab.entry] = isAgent
            }
        }
        guard let newest = order.first, agentOnly[newest] == true else { return .chromium }
        return order.first { agentOnly[$0] == false }.map(Pick.entry) ?? .nothing
    }
}
