import Foundation

struct DrifterBackgroundCheckIns {
    struct State {
        var idleSince: Date?
        var tasksSince: Date?
        var firstSeen: [String: Date] = [:]
        var pendingDot: Bool?
    }
    var states: [UUID: State] = [:]
    let interval: TimeInterval

    mutating func status(_ status: AgentConversationStatus, previous: AgentConversationStatus, id: UUID, now: Date) {
        if status == .idle && previous != .idle { states[id, default: State()].idleSince = now }
    }

    mutating func tasks(_ tasks: [AgentBackgroundTask], id: UUID, now: Date) {
        var state = states[id] ?? State()
        if state.firstSeen.isEmpty && !tasks.isEmpty { state.tasksSince = now }
        let ids = Set(tasks.map(\.id))
        state.firstSeen = state.firstSeen.filter { ids.contains($0.key) }
        for task in tasks where state.firstSeen[task.id] == nil { state.firstSeen[task.id] = now }
        if tasks.isEmpty { state.tasksSince = nil }
        states[id] = state
    }

    func deadline(_ id: UUID) -> Date? {
        guard let state = states[id], let idle = state.idleSince, let tasks = state.tasksSince else { return nil }
        return max(idle, tasks).addingTimeInterval(interval)
    }

    mutating func retry(_ id: UUID, now: Date) { states[id]?.idleSince = now }

    func message(_ tasks: [AgentBackgroundTask], id: UUID, now: Date,
                 output: (String) -> (path: String, tail: String?)?) -> AgentQueuedMessage {
        let duration = DrifterBackgroundTasks.duration(interval)
        let note = "Check-in from Mist, not a completion: this chat has been idle for \(duration) while background work it started is still running. Make sure each task below is still making progress: read its output and look at its processes. If one is stuck (waiting on a lock, on input, or on a process that will never exit), stop it and get the work done another way. If it is making progress or is meant to keep running (a server, a watcher), leave it and end your turn. Don't message Johnny, post to Slack or call finish_task just to say it is still running. The next check-in comes after another \(duration) idle."
        let body = tasks.map { task in
            let elapsed = DrifterBackgroundTasks.duration(max(0, now.timeIntervalSince(states[id]?.firstSeen[task.id] ?? now)))
            var line = "- \(task.id) (\(String(describing: task.kind))) \"\(task.description)\": started \(elapsed) ago"
            if let details = output(task.id) {
                line += ", output file \(details.path)"
                if let tail = details.tail { line += "\n" + tail.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") }
            }
            return line
        }.joined(separator: "\n")
        var sender = AgentMessageSender(id: "check-in", title: "Mist", kind: .checkIn, note: note)
        sender.checkInTasks = tasks.map(\.description)
        return .init(text: body, sender: sender)
    }
}
