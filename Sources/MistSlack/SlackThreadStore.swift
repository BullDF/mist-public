import Foundation

struct SlackThreadRecord: Codable, Equatable {
    var key: SlackThreadKey
    var kind: SlackThreadKind
    var chatId: UUID?
    var context: String?
    var lastHandledTs: String?
    var updatedAt: Date
    /// A model picked by a prefix-only message before the thread has a chat.
    var model: SlackModelChoice?
}

struct SlackModelChoice: Codable, Equatable {
    var engine: String
    var model: String
    var effort: String
}

@MainActor final class SlackThreadStore {
    private struct Contents: Codable {
        var threads: [SlackThreadRecord] = []
        var dmChannel: String?
        var lastConnectedAt: Date?
    }

    private let url: URL
    private let log: (String) -> Void
    private var contents = Contents()
    private var loggedWriteFailure = false

    init(url: URL, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.url = url
        self.log = log
        do { contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url)) }
        catch { log("slack: thread store unavailable; starting empty") }
    }

    var dmChannel: String? {
        get { contents.dmChannel }
        set { contents.dmChannel = newValue; save() }
    }

    var lastConnectedAt: Date? {
        get { contents.lastConnectedAt }
        set { contents.lastConnectedAt = newValue; save() }
    }

    func record(for key: SlackThreadKey) -> SlackThreadRecord? { contents.threads.first { $0.key == key } }
    func record(forChat chatId: UUID) -> SlackThreadRecord? { contents.threads.first { $0.chatId == chatId } }

    func upsert(_ record: SlackThreadRecord) {
        if let index = contents.threads.firstIndex(where: { $0.key == record.key }) { contents.threads[index] = record }
        else { contents.threads.append(record) }
        save()
    }

    // Mutations need an existing record: its kind is chosen by the inbound router.
    private func update(_ key: SlackThreadKey, _ change: (inout SlackThreadRecord) -> Void) {
        guard let index = contents.threads.firstIndex(where: { $0.key == key }) else { return }
        change(&contents.threads[index])
        contents.threads[index].updatedAt = Date()
        save()
    }

    func setChat(_ chatId: UUID?, for key: SlackThreadKey) { update(key) { $0.chatId = chatId; $0.model = nil } }
    func setModel(_ model: SlackModelChoice?, for key: SlackThreadKey) { update(key) { $0.model = model } }
    func setContext(_ context: String?, for key: SlackThreadKey) { update(key) { $0.context = context } }

    func replaceChat(_ old: UUID, with new: UUID) {
        for index in contents.threads.indices where contents.threads[index].chatId == old {
            contents.threads[index].chatId = new
            contents.threads[index].updatedAt = Date()
        }
        save()
    }

    func markHandled(ts: String, for key: SlackThreadKey) {
        guard !isHandled(ts: ts, for: key) else { return }
        update(key) { $0.lastHandledTs = ts }
    }

    func isHandled(ts: String, for key: SlackThreadKey) -> Bool {
        guard let last = record(for: key)?.lastHandledTs else { return false }
        return Self.compare(ts, last) != .orderedDescending
    }

    func recentThreads(kind: SlackThreadKind, since: Date) -> [SlackThreadRecord] {
        contents.threads.filter { $0.kind == kind && $0.updatedAt >= since }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // Compare decimal components without Double rounding or fixed-width integer overflow.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ ts: String) -> (String, String) {
            let parts = ts.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let seconds = String(parts[0].drop(while: { $0 == "0" }))
            return (seconds.isEmpty ? "0" : seconds, parts.count == 2 ? String(parts[1]) : "")
        }
        let (as_, af) = parts(a), (bs, bf) = parts(b)
        if as_.count != bs.count { return as_.count < bs.count ? .orderedAscending : .orderedDescending }
        if as_ != bs { return as_ < bs ? .orderedAscending : .orderedDescending }
        let width = max(af.count, bf.count)
        let ap = af + String(repeating: "0", count: width - af.count)
        let bp = bf + String(repeating: "0", count: width - bf.count)
        return ap == bp ? .orderedSame : ap < bp ? .orderedAscending : .orderedDescending
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: url, options: .atomic)
            loggedWriteFailure = false
        } catch {
            if !loggedWriteFailure { log("slack: could not save thread store"); loggedWriteFailure = true }
        }
    }
}
