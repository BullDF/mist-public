import Foundation

struct ShellOutput: Codable, Equatable, Sendable {
    private(set) var head = ""
    private(set) var omitted = 0
    private var headCount = 0
    private var tailCharacters: [Character] = []
    private var tailStart = 0
    static let limit = 15_000

    var tail: String {
        String(tailCharacters[tailStart...] + tailCharacters[..<tailStart])
    }

    init() {}

    mutating func append(_ chunk: String) {
        // A ring avoids rescanning or shifting 15,000 characters for every small read.
        for character in chunk {
            if headCount < Self.limit {
                head.append(character)
                headCount += 1
            } else if tailCharacters.count < Self.limit {
                tailCharacters.append(character)
            } else {
                tailCharacters[tailStart] = character
                tailStart = (tailStart + 1) % Self.limit
                omitted += 1
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case head, tail, omitted }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        head = try values.decode(String.self, forKey: .head)
        headCount = head.count
        tailCharacters = Array(try values.decode(String.self, forKey: .tail))
        omitted = try values.decode(Int.self, forKey: .omitted)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(head, forKey: .head)
        try values.encode(tail, forKey: .tail)
        try values.encode(omitted, forKey: .omitted)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.head == rhs.head && lhs.omitted == rhs.omitted && lhs.tail == rhs.tail
    }

    var claudeText: String {
        let text = omitted > 0
            ? head + "\n[… \(omitted) characters truncated …]\n" + tail : head + tail
        return ClaudeCodeShellText.clean(text).trimmingTrailingNewlines
    }
}

enum ClaudeCodeShellText {
    static func clean(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        // A carriage return redraws its line, so the last text written after one is what a terminal shows.
        return stripped.components(separatedBy: "\n").map {
            $0.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
        }.joined(separator: "\n")
    }
}

private extension String {
    var trimmingTrailingNewlines: String {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isNewline { formIndex(before: &end) }
        return String(self[..<end])
    }
}

enum AgentPermissionResponse: Codable, Equatable, Sendable {
    case allow
    case allowWithInput(ClaudeCodeJSON)
    case deny(message: String?)

    var allows: Bool {
        if case .deny = self { return false }
        return true
    }
}

struct AgentPermissionQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        let description: String
    }
    let header: String
    let question: String
    let options: [Option]
    let multiSelect: Bool

    struct Selection: Equatable {
        var options: Set<Int> = []
        var otherSelected = false
        var other = ""

        mutating func toggle(_ index: Int, multiSelect: Bool) {
            if multiSelect {
                if !options.insert(index).inserted { options.remove(index) }
            } else {
                options = [index]
                otherSelected = false
            }
        }

        mutating func selectOther(multiSelect: Bool) {
            otherSelected = true
            if !multiSelect { options.removeAll() }
        }
    }

    func answer(_ selection: Selection) -> String? {
        var labels = options.indices.filter { selection.options.contains($0) }.map { options[$0].label }
        if selection.otherSelected {
            let text = selection.other.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            labels.append(text)
        }
        guard !labels.isEmpty, multiSelect || labels.count == 1 else { return nil }
        return labels.joined(separator: ", ")
    }
}

enum AgentConversationStatus: Equatable, Sendable {
    /// `dormant`: a restored chat whose agent hasn't launched yet.
    case starting, running, awaitingPermission, idle, failed(String), ended, dormant

    /// A failed or restored chat's next message launches its agent on the saved session.
    var launchesOnSend: Bool {
        if case .failed = self { return true }
        return self == .dormant
    }
}

struct AgentBackgroundTask: Identifiable, Equatable, Sendable {
    enum Kind: CaseIterable, Equatable, Sendable { case shell, monitor, task }
    let id: String
    var kind: Kind
    var description: String
}

struct AgentChatItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var kind: Kind
    var mentions: [AgentTabMention] = []
    var files: [AgentFileAttachment] = []

    init(id: String, kind: Kind, mentions: [AgentTabMention] = [], files: [AgentFileAttachment] = []) {
        self.id = id
        self.kind = kind
        self.mentions = mentions
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case id, kind, mentions, files }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        mentions = try values.decode([AgentTabMention].self, forKey: .mentions)
        files = try values.decodeIfPresent([AgentFileAttachment].self, forKey: .files) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(mentions, forKey: .mentions)
        if !files.isEmpty { try values.encode(files, forKey: .files) }
    }

    enum Kind: Codable, Equatable, Sendable {
        case userMessage(text: String, images: [AgentImageAttachment])
        case assistantText(text: String, isStreaming: Bool)
        case peerMessage(name: String, body: String)
        case toolCall(ToolCall)
        case shellCommand(ShellCommand)
        case commandOutput(command: String, text: String, isError: Bool)
        case contextUsage(ClaudeCodeContextUsage)
        case mcpServers(ClaudeCodeMCPStatus)
        case compaction(trigger: ClaudeCodeCompactionTrigger, preTokens: Int?, postTokens: Int?)
        case permissionRequest(PermissionRequest)
        case notice(text: String, level: NoticeLevel)
        case taskNotification(summary: String, status: TaskNotificationStatus)
        case turnEnd(durationMilliseconds: Int, finishedAt: Date, stopped: Bool = false)
    }

    struct ShellCommand: Codable, Equatable, Sendable {
        enum Status: Codable, Equatable, Sendable { case running, succeeded, failed, stopped }
        var command: String
        var stdout = ShellOutput()
        var stderr = ShellOutput()
        var exitCode: Int32?
        var status: Status = .running
    }

    struct ToolCall: Codable, Equatable, Sendable {
        let toolUseId: String
        var name: String
        var inputSummary: String
        var inputJSON: String
        var status: ToolStatus = .running
        var output = ""
        var structuredResult: ClaudeCodeJSON = .null
        var background: BackgroundState?
        var permissionDenied = false
        var canBackground = false

        enum CodingKeys: String, CodingKey {
            case toolUseId, name, inputSummary, inputJSON, status, output, structuredResult, background, permissionDenied
        }
    }

    struct PermissionRequest: Codable, Equatable, Sendable {
        let requestId: String
        let toolName: String
        let summary: String
        var input: ClaudeCodeJSON = .null
        var requiresUserInteraction = false
        /// Some CLI versions strip the plan from permission input but retain it on the tool call.
        var plan: String?
        var status: PermissionStatus = .pending
        var resolution: AgentPermissionResponse?

        var questions: [AgentPermissionQuestion] {
            input["questions"].array.map { value in
                AgentPermissionQuestion(header: value["header"].string ?? "", question: value["question"].string ?? "",
                    options: value["options"].array.map { .init(label: $0["label"].string ?? "", description: $0["description"].string ?? "") },
                    multiSelect: value["multiSelect"].bool)
            }
        }

        func answerResponse(_ selections: [Int: AgentPermissionQuestion.Selection]) -> AgentPermissionResponse? {
            guard case var .object(updated) = input, !questions.isEmpty else { return nil }
            var answers: [String: ClaudeCodeJSON] = [:]
            for (index, question) in questions.enumerated() {
                guard let answer = question.answer(selections[index] ?? .init()) else { return nil }
                answers[question.question] = .string(answer)
            }
            updated["answers"] = .object(answers)
            return .allowWithInput(.object(updated))
        }

        var answers: [String: ClaudeCodeJSON] {
            guard case let .allowWithInput(input) = resolution, case let .object(answers) = input["answers"] else { return [:] }
            return answers
        }
    }

    enum ToolStatus: Codable, Equatable, Sendable { case running, succeeded, failed }
    enum BackgroundState: Codable, Equatable, Sendable { case running, finished }
    enum PermissionStatus: Codable, Equatable, Sendable { case pending, allowed, denied }
    enum NoticeLevel: Codable, Equatable, Sendable { case info, error }
    /// `running` marks a background check-in's row: the task hasn't ended.
    enum TaskNotificationStatus: Codable, Equatable, Sendable { case completed, failed, stopped, running }

    var settled: Self {
        var item = self
        switch item.kind {
        case var .mcpServers(status):
            status.live = false
            status.busy.removeAll()
            item.kind = .mcpServers(status)
        case var .shellCommand(command) where command.status == .running:
            command.status = .stopped
            item.kind = .shellCommand(command)
        case let .assistantText(text, _): item.kind = .assistantText(text: text, isStreaming: false)
        case var .toolCall(tool):
            tool.canBackground = false
            if tool.status == .running { tool.status = .failed }
            if tool.background == .running { tool.background = .finished }
            item.kind = .toolCall(tool)
        case var .permissionRequest(request) where request.status == .pending:
            request.status = .denied
            item.kind = .permissionRequest(request)
        default: break
        }
        return item
    }
}

enum ClaudeCodeMCPServerAction { case reconnect, enable, disable }

struct ClaudeCodeMCPStatus: Codable, Equatable, Sendable {
    struct Server: Codable, Equatable, Sendable {
        let name: String
        let status: String
        let scope: String?
        let toolCount: Int?
        let error: String?
    }
    var servers: [Server]
    var live = true
    var busy: Set<String> = []
    var actionErrors: [String: String] = [:]

    init?(reply: ClaudeCodeJSON) {
        guard case let .array(entries) = reply["mcpServers"] else { return nil }
        servers = entries.compactMap { entry in
            guard let name = entry["name"].string, let status = entry["status"].string else { return nil }
            let count: Int? = { if case let .array(tools) = entry["tools"] { return tools.count }; return nil }()
            return Server(name: name, status: status, scope: entry["scope"].string, toolCount: count, error: entry["error"].string)
        }
    }
}

enum ClaudeCodeCompactionTrigger: String, Codable, Equatable, Sendable { case manual, auto }

struct ClaudeCodeContextUsage: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Sendable {
        let name: String
        let tokens: Int
        let kind: String
    }
    let model: String
    let totalTokens: Int
    let maxTokens: Int
    let percentage: Double
    let categories: [Category]

    init(_ value: ClaudeCodeJSON) {
        model = value["model"].string ?? ""
        totalTokens = value["total_tokens"].integer
        maxTokens = value["raw_max_tokens"].integer
        percentage = value["percentage"].double ?? 0
        categories = value["categories"].array.map {
            Category(name: $0["name"].string ?? "", tokens: $0["tokens"].integer, kind: $0["kind"].string ?? "used")
        }
    }
}
