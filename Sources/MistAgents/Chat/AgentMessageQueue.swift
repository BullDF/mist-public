import Foundation

enum AgentTaskFinishStatus: String, Codable, Sendable { case done, blocked }

struct AgentMessageSender: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case peer, parent, report, question, slack, task, schedule, checkIn }
    let id: String
    let title: String
    var kind: Kind = .peer
    var reportsPaused = false
    var taskStatus: AgentTaskFinishStatus?
    /// The note for a Slack, task or scheduled message.
    var note: String?
    /// Set on a message that wakes a Slack thread's chat whose turn will post to that thread.
    var postsToSlack = false
    var label: String { title.isEmpty ? id : "\(id) (\(title))" }
    var header: String {
        let text: String
        switch kind {
        case .task, .checkIn: text = note ?? "Background task \(label)"
        case .slack: return "[" + (note ?? Self.slackNote(place: "in his DM with you", publicThread: false)) + "]"
        case .schedule:
            let header = note ?? "[Scheduled prompt \(label)]"
            return header + (postsToSlack ? " [" + Self.slackWakeNote + "]" : "")
        case .peer: text = "Message from chat \(label); reply with message_agent"
        case .parent: text = "Message from your parent chat \(label); report back to it only with finish_task, when your task is done or you're blocked"
        case .report:
            let report: String
            switch taskStatus {
            case .done: report = "Report from child chat \(label): it finished its task and sent this with finish_task. No reply is needed"
            case .blocked: report = "Report from child chat \(label): it is blocked and waits for your answer, sent with finish_task. Answer it with message_agent"
            case nil: report = "Report from child chat \(label)"
            }
            text = report + (reportsPaused ? ". Mist has paused automatic reports from this chat until Johnny sends a message here" : "")
        case .question: text = "Question from child chat \(label), which is waiting for an answer: answer it with message_agent"
        }
        return "[" + text + (postsToSlack ? ". " + Self.slackWakeNote : "") + "]"
    }

    /// Everything the agent needs to know about how its reply to a Slack message is posted.
    static func slackNote(place: String, publicThread: Bool) -> String {
        let audience = publicThread
            ? "This channel thread is public: his colleagues read it, so keep your message concise and don't flood the thread."
            : "This is his private DM with Drifter; still keep your message concise."
        return "Message from Johnny in Slack, \(place). \(audience) "
            + "Answer him by calling finish_task: Mist posts its message to this thread when your turn ends, under Drifter's name, converted to Slack formatting. "
            + "Nothing else you write here reaches Slack, and a turn without finish_task posts nothing. "
            + "Make the message answer his request directly and stand on its own: status done when you've answered, blocked when you need his answer to go on. "
            + "Never post it yourself with slack_send_message, which posts as Johnny, not as Drifter. "
            + "Work you hand to a child chat: its report wakes you, and that turn's finish_task message posts to this thread too, "
            + "so promise a follow-up only that way."
    }

    static let slackWakeNote = "Johnny's last message here came from a Slack thread, so this turn answers it there: call finish_task, and Mist posts its message "
        + "to that thread when the turn ends, under Drifter's name; a channel thread is public. "
        + "Keep it concise and make it stand on its own, and never post it with slack_send_message, which posts as Johnny. "
        + "A turn without finish_task posts nothing"

    /// A check-in's still-running tasks, by description: each shows as a task notification row when the check-in is taken.
    var checkInTasks: [String] = []
    var checkInItems: [AgentChatItem] {
        checkInTasks.map {
            AgentChatItem(id: "check-in:" + UUID().uuidString, kind: .taskNotification(summary: "Check-in: \"\($0)\" still running", status: .running))
        }
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, reportsPaused, taskStatus, note, postsToSlack, checkInTasks }
    init(id: String, title: String, kind: Kind = .peer, reportsPaused: Bool = false, note: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.reportsPaused = reportsPaused
        self.note = note
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .peer
        reportsPaused = try values.decodeIfPresent(Bool.self, forKey: .reportsPaused) ?? false
        taskStatus = try values.decodeIfPresent(AgentTaskFinishStatus.self, forKey: .taskStatus)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        postsToSlack = try values.decodeIfPresent(Bool.self, forKey: .postsToSlack) ?? false
        checkInTasks = try values.decodeIfPresent([String].self, forKey: .checkInTasks) ?? []
    }
    func agentText(_ text: String) -> String { header + "\n\n" + text }
}

struct AgentQueuedMessage: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var attachments: [AgentAttachment]
    var mentions: [AgentTabMention]
    var delivering = false
    var sender: AgentMessageSender?
    var draftText: String { sender.map { $0.header + "\n" + text } ?? text }

    init(id: String = UUID().uuidString.lowercased(), text: String, attachments: [AgentAttachment] = [], mentions: [AgentTabMention] = [], sender: AgentMessageSender? = nil) {
        self.sender = sender
        self.id = id
        let prompt = AgentMentionText(text: text, mentions: mentions).normalized
        self.text = prompt.text
        self.attachments = attachments
        self.mentions = prompt.mentions
    }
}

struct AgentMessageQueue {
    private(set) var messages: [AgentQueuedMessage] = []
    private(set) var paused = false

    mutating func enqueue(_ message: AgentQueuedMessage) { messages.append(message) }

    mutating func moveToFront(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages.insert(messages.remove(at: index), at: 0)
    }

    @discardableResult
    mutating func remove(_ id: String) -> AgentQueuedMessage? {
        guard messages.contains(where: { $0.id == id && !$0.delivering }) else { return nil }
        return take(id)
    }

    mutating func markDelivering(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].delivering = true
    }

    @discardableResult
    mutating func take(_ id: String) -> AgentQueuedMessage? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let message = messages.remove(at: index)
        if messages.isEmpty { paused = false }
        return message
    }

    mutating func returnDelivering(_ ids: Set<String>? = nil) {
        let returned = messages.filter { $0.delivering && (ids == nil || ids!.contains($0.id)) }
        let returnedIds = Set(returned.map(\.id))
        messages = returned.map { var message = $0; message.delivering = false; return message }
            + messages.filter { !returnedIds.contains($0.id) }
    }

    mutating func pause() { paused = !messages.isEmpty }
    mutating func resume() { paused = false }
}
