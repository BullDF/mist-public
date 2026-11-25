import Foundation

final class AgentChatDisplayRowCache {
    private struct InputKey: Hashable { let id: String; let json: String }
    private struct MemoryKey: Hashable { let id: String; let name: String; let json: String }
    private var inputs: [InputKey: ClaudeCodeJSON?] = [:]
    private var matches: [MemoryKey: Bool] = [:]
    private var memory: AgentMemoryFiles?
    private var cwd: URL?

    func prepare(memory: AgentMemoryFiles, cwd: URL) {
        if self.memory != memory || self.cwd != cwd {
            matches.removeAll()
            self.memory = memory
            self.cwd = cwd
        }
    }

    func input(_ tool: AgentChatItem.ToolCall) -> ClaudeCodeJSON? {
        let key = InputKey(id: tool.toolUseId, json: tool.inputJSON)
        if let cached = inputs[key] { return cached }
        let decoded = try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8))
        inputs[key] = .some(decoded)
        return decoded
    }

    func contains(_ tool: AgentChatItem.ToolCall, memory: AgentMemoryFiles, cwd: URL) -> Bool {
        guard ["Write", "Edit", "MultiEdit"].contains(tool.name) else { return false }
        let key = MemoryKey(id: tool.toolUseId, name: tool.name, json: tool.inputJSON)
        if let cached = matches[key] { return cached }
        let result = memory.contains(tool, cwd: cwd, input: input(tool))
        matches[key] = result
        return result
    }
}

enum AgentChatDisplayRow: Identifiable, Equatable {
    case item(AgentChatItem)
    case toolGroup([AgentChatItem.ToolCall])

    var id: String {
        switch self {
        case let .item(item): item.id
        case let .toolGroup(tools): tools[0].toolUseId
        }
    }

    static func rows(from items: [AgentChatItem], memory: AgentMemoryFiles = .none,
                     cwd: URL = FileManager.default.homeDirectoryForCurrentUser, cache: AgentChatDisplayRowCache? = nil) -> [Self] {
        let cache = cache ?? AgentChatDisplayRowCache()
        cache.prepare(memory: memory, cwd: cwd)
        let tools = items.compactMap { item -> AgentChatItem.ToolCall? in
            if case let .toolCall(tool) = item.kind { return tool }
            return nil
        }
        let toolsByName = Dictionary(grouping: tools, by: \.name)
        var rows: [Self] = []
        var run: [AgentChatItem] = []
        func flush() {
            if !run.isEmpty {
                rows.append(.toolGroup(run.compactMap {
                    if case let .toolCall(tool) = $0.kind { return tool }
                    return nil
                }))
            }
            run.removeAll()
        }
        for item in items {
            if case let .permissionRequest(request) = item.kind, request.status != .pending,
               !["AskUserQuestion", "ExitPlanMode"].contains(request.toolName),
               (toolsByName[request.toolName] ?? []).contains(where: { cache.input($0) == toolInput(of: request) }) { continue }
            if case let .toolCall(tool) = item.kind, awaitsFile(tool, cache: cache) { continue }
            if case let .toolCall(tool) = item.kind, isGroupable(tool, memory: memory, cwd: cwd, cache: cache) { run.append(item) }
            else { flush(); rows.append(.item(item)) }
        }
        flush()
        return rows
    }

    /// The CLI adds hidden `__`-prefixed fields to a permission's input (the Artifact tools' `__artifactConsentAskCanReachUser`),
    /// which the tool call's own input lacks.
    private static func toolInput(of request: AgentChatItem.PermissionRequest) -> ClaudeCodeJSON {
        guard case let .object(fields) = request.input else { return request.input }
        return .object(fields.filter { !$0.key.hasPrefix("__") })
    }

    /// A file edit shows once its file is known: memory's group claims a memory file's edit, so one shown while its
    /// input still streamed would stand alone, then jump into the group above.
    private static func awaitsFile(_ tool: AgentChatItem.ToolCall, cache: AgentChatDisplayRowCache) -> Bool {
        ["Write", "Edit", "MultiEdit"].contains(tool.name) && tool.status == .running
            && (cache.input(tool)?["file_path"].string ?? "").isEmpty
    }

    /// Whether the running turn may still add actions to the row at `index`: only the transcript's last row can grow.
    static func isOpen(at index: Int, of rows: [Self], status: AgentConversationStatus) -> Bool {
        status == .running && index == rows.count - 1
    }

    static func isGroupable(_ tool: AgentChatItem.ToolCall, memory: AgentMemoryFiles = .none,
                            cwd: URL = FileManager.default.homeDirectoryForCurrentUser, cache: AgentChatDisplayRowCache? = nil) -> Bool {
        tool.background == nil &&
            ((cache?.contains(tool, memory: memory, cwd: cwd) ?? memory.contains(tool, cwd: cwd)) ||
             !["Edit", "MultiEdit", "Write", "NotebookEdit", "AskUserQuestion", "ExitPlanMode"].contains(tool.name))
    }
}

enum AgentChatToolGroupKind: Hashable {
    case read, search, shell, fetch, web, memory, recall, sleep, imageGeneration
    case browserRead, browserScreenshot, browserClick, browserDrag, browserHover, browserType, browserKey, browserOption, browserSelectText, browserUpload, browserOpen, browserReload
    case browserScroll, browserWait, browserDialog, browserTabs, browserGroup, browserConnect, browserClose, browserScript, browserLogs, browserDownloads, browserHistory, pagesSaved
    case screenshotsSaved, recordingStarted, recordingsSaved, bookmarksExported, chatMounted, chatUnmounted
    case monitor, stopTask, toolSearch, skill, message, agents, code
    case spawnAgent, readAgent, stopAgent, closeAgent, mailList, mailSearch, mailRead, mailDraft, mailSend, mailChange
    case slackRead, slackSearch, slackSend, slackChange
    case scheduleTask, cancelScheduledTask, scheduledTasks, wakeup, planMode
    case notification, mcpResources, mcpResource
    /// A tool Mist doesn't know, such as another MCP server's, named after itself.
    case tool(String)

    /// The family's SF Symbol, shared by tool rows and permission cards without importing UI frameworks.
    var symbol: String {
        switch self {
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .sleep: "hourglass"
        case .imageGeneration: "photo"
        case .shell: "terminal"
        case .fetch, .web, .browserOpen, .browserRead, .browserTabs, .browserConnect, .browserClose, .browserReload: "globe"
        case .browserScreenshot, .screenshotsSaved: "camera.viewfinder"
        case .recordingStarted, .recordingsSaved: "record.circle"
        case .browserClick: "cursorarrow.click"
        case .browserDrag: "hand.draw"
        case .browserGroup: "rectangle.stack"
        case .browserScript: "curlybraces"
        case .browserLogs: "list.bullet.rectangle"
        case .browserDownloads: "arrow.down.circle"
        case .browserHistory: "clock.arrow.circlepath"
        case .pagesSaved: "square.and.arrow.down"
        case .bookmarksExported: "square.and.arrow.up"
        case .chatMounted: "link.badge.plus"
        case .chatUnmounted: "personalhotspot.slash"
        case .browserHover: "cursorarrow.motionlines"
        case .browserType, .browserKey: "keyboard"
        case .browserOption: "filemenu.and.selection"
        case .browserSelectText: "character.cursor.ibeam"
        case .browserUpload: "arrow.up.doc"
        case .browserScroll: "arrow.up.and.down"
        case .browserWait: "hourglass"
        case .browserDialog: "macwindow"
        case .memory, .recall: "brain.head.profile"
        case .monitor: "waveform.path.ecg"
        case .stopTask: "stop.circle"
        case .toolSearch: "wrench.and.screwdriver"
        case .skill: "sparkles"
        case .message: "bubble.left"
        case .agents, .spawnAgent, .readAgent, .stopAgent, .closeAgent: "person.2"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .mailList, .mailSearch, .mailRead, .mailDraft, .mailSend, .mailChange: "envelope"
        case .slackRead, .slackSearch, .slackSend, .slackChange: "number"
        case .scheduleTask, .cancelScheduledTask, .scheduledTasks, .wakeup: "clock"
        case .planMode: "list.bullet.clipboard"
        case .notification: "bell"
        case .mcpResources, .mcpResource: "server.rack"
        case let .tool(name):
            switch name {
            case "Edit", "Write", "NotebookEdit": "pencil"
            default: "wrench"
            }
        }
    }

    private static let mailTools = Set(["list_mail_accounts", "list_mail", "search_mail", "read_mail", "write_mail_draft", "send_mail", "update_mail"].map { "mcp__mistbrowser__" + $0 })

    static func status(_ tools: [AgentChatItem.ToolCall]) -> AgentChatItem.ToolStatus {
        if !tools.isEmpty, tools.allSatisfy({ $0.status == .failed || $0.permissionDenied }) { return .failed }
        return tools.contains(where: { $0.status == .running }) ? .running : .succeeded
    }

    /// The tools a group's row describes. Between two actions of an open group, its last action stays running,
    /// so the row keeps its running form and current-action line, at the same height, until the group really ends.
    static func shown(_ tools: [AgentChatItem.ToolCall], open: Bool) -> [AgentChatItem.ToolCall] {
        guard open, !tools.contains(where: { $0.status == .running }), var last = tools.last else { return tools }
        last.status = .running
        last.permissionDenied = false
        return tools.dropLast() + [last]
    }

    init(_ name: String) {
        let name = DrifterBackgroundTools.nativeName(name)
        if name.hasPrefix("mcp__mistbrowser__slack_") {
            if name.hasPrefix("mcp__mistbrowser__slack_search_") { self = .slackSearch }
            else if name.hasPrefix("mcp__mistbrowser__slack_read_") || name.hasPrefix("mcp__mistbrowser__slack_list_") || name == "mcp__mistbrowser__slack_get_reactions" { self = .slackRead }
            else if name == "mcp__mistbrowser__slack_send_message" || name == "mcp__mistbrowser__slack_schedule_message" { self = .slackSend }
            else { self = .slackChange }
            return
        }
        switch name {
        case "mcp__mistbrowser__snapshot", "mcp__mistbrowser__read_page": self = .browserRead
        case "mcp__mistbrowser__evaluate": self = .browserScript
        case "mcp__mistbrowser__read_console", "mcp__mistbrowser__read_network": self = .browserLogs
        case "mcp__mistbrowser__screenshot": self = .browserScreenshot
        case "mcp__mistbrowser__click": self = .browserClick
        case "mcp__mistbrowser__drag": self = .browserDrag
        case "mcp__mistbrowser__hover": self = .browserHover
        case "mcp__mistbrowser__fill", "mcp__mistbrowser__type_text": self = .browserType
        case "mcp__mistbrowser__press_key": self = .browserKey
        case "mcp__mistbrowser__select_option": self = .browserOption
        case "mcp__mistbrowser__select_text": self = .browserSelectText
        case "mcp__mistbrowser__upload_files": self = .browserUpload
        case "mcp__mistbrowser__navigate", "mcp__mistbrowser__open_tab", "mcp__mistbrowser__go_back", "mcp__mistbrowser__go_forward": self = .browserOpen
        case "mcp__mistbrowser__reload": self = .browserReload
        case "mcp__mistbrowser__scroll", "mcp__mistbrowser__scroll_until": self = .browserScroll
        case "mcp__mistbrowser__wait_for": self = .browserWait
        case "mcp__mistbrowser__handle_dialog": self = .browserDialog
        case "mcp__mistbrowser__save_screenshot": self = .screenshotsSaved
        case "mcp__mistbrowser__start_recording": self = .recordingStarted
        case "mcp__mistbrowser__stop_recording": self = .recordingsSaved
        case "mcp__mistbrowser__save_page": self = .pagesSaved
        case "mcp__mistbrowser__export_bookmarks": self = .bookmarksExported
        case "mcp__mistbrowser__mount_to_tab": self = .chatMounted
        case "mcp__mistbrowser__unmount_from_tab": self = .chatUnmounted
        case "mcp__mistbrowser__list_downloads": self = .browserDownloads
        case "mcp__mistbrowser__search_history": self = .browserHistory
        case "mcp__mistbrowser__list_tabs": self = .browserTabs
        case "mcp__mistbrowser__group_tabs": self = .browserGroup
        case "mcp__mistbrowser__list_agents": self = .agents
        case "mcp__mistbrowser__list_mail_accounts", "mcp__mistbrowser__list_mail": self = .mailList
        case "mcp__mistbrowser__search_mail": self = .mailSearch
        case "mcp__mistbrowser__read_mail": self = .mailRead
        case "mcp__mistbrowser__write_mail_draft": self = .mailDraft
        case "mcp__mistbrowser__send_mail": self = .mailSend
        case "mcp__mistbrowser__update_mail": self = .mailChange
        case "mcp__mistbrowser__message_agent", "mcp__mistbrowser__finish_task", "mcp__mistbrowser__hand_off": self = .message
        case "mcp__mistbrowser__spawn_agent": self = .spawnAgent
        case "mcp__mistbrowser__read_agent": self = .readAgent
        case "mcp__mistbrowser__stop_agent": self = .stopAgent
        case "mcp__mistbrowser__close_agent": self = .closeAgent
        case "mcp__mistbrowser__use_tab": self = .browserConnect
        case "mcp__mistbrowser__close_tab": self = .browserClose
        case "Read": self = .read
        case "Grep", "Glob": self = .search
        case "Bash": self = .shell
        case "WebFetch": self = .fetch
        case "WebSearch": self = .web
        case "Sleep": self = .sleep
        case "ImageGeneration": self = .imageGeneration
        case "Monitor": self = .monitor
        case "TaskStop": self = .stopTask
        case "ToolSearch": self = .toolSearch
        case "Skill": self = .skill
        case "LSP": self = .code
        case "CronCreate", "mcp__mistbrowser__schedule_prompt": self = .scheduleTask
        case "CronDelete", "mcp__mistbrowser__cancel_schedule": self = .cancelScheduledTask
        case "CronList", "mcp__mistbrowser__list_schedules": self = .scheduledTasks
        case "ScheduleWakeup": self = .wakeup
        case "EnterPlanMode": self = .planMode
        case "PushNotification", "mcp__mistbrowser__notify": self = .notification
        case "ListMcpResourcesTool": self = .mcpResources
        case "ReadMcpResourceTool", "ReadMcpResourceDirTool": self = .mcpResource
        default: self = .tool(name)
        }
    }

    /// An MCP tool is shown without its `mcp__<server>__` prefix.
    static func displayName(_ name: String) -> String {
        let name = DrifterBackgroundTools.nativeName(name)
        guard name.hasPrefix("mcp__") else { return name }
        let tool = name.dropFirst("mcp__".count).components(separatedBy: "__").dropFirst().joined(separator: "__")
        return tool.isEmpty ? name : tool
    }

    /// The readable server of an MCP tool, such as `Google Drive` for `mcp__claude_ai_Google_Drive__search_files`.
    static func serverName(_ name: String) -> String? {
        let name = DrifterBackgroundTools.nativeName(name)
        guard name.hasPrefix("mcp__"), displayName(name) != name,
              let server = name.dropFirst("mcp__".count).components(separatedBy: "__").first else { return nil }
        let readable = server.hasPrefix("claude_ai_") ? String(server.dropFirst("claude_ai_".count)) : server
        return readable.replacingOccurrences(of: "_", with: " ")
    }

    /// The same contextual family labels a group's text and its icon.
    static func kind(of tool: AgentChatItem.ToolCall, memory: AgentMemoryFiles, cwd: URL) -> Self {
        memory.contains(tool, cwd: cwd) ? .memory : memory.readsSkill(tool, cwd: cwd) ? .skill
            : memory.readsMemory(tool, cwd: cwd) ? .recall : Self(tool.name)
    }

    static func summary(_ tools: [AgentChatItem.ToolCall], memory: AgentMemoryFiles = .none,
                        cwd: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeCodeToolSummary.Line {
        if tools.count == 1, let tool = tools.first {
            let input = (try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8))) ?? .null
            switch Self(tool.name) {
            case .bookmarksExported, .chatMounted, .chatUnmounted:
                return ClaudeCodeToolSummary.format(tool: tool.name, input: input, result: tool.structuredResult,
                    text: tool.output, folder: cwd, failed: tool.status == .failed,
                    denied: tool.permissionDenied, running: tool.status == .running).header
            default:
                if let header = ClaudeCodeToolSummary.browserTool(tool.name, input: input,
                    running: tool.status == .running, failed: tool.status == .failed || tool.permissionDenied) {
                    return .init(header)
                }
            }
        }
        if !tools.isEmpty, tools.allSatisfy({ mailTools.contains($0.name) && ($0.status == .failed || $0.permissionDenied) }) {
            return .init(String.localizedStringWithFormat(NSLocalizedString("browser.agentChat.toolGroup.mailFailed", value: "Couldn't complete %d mail actions", comment: "Every mail action failed or was denied"), tools.count))
        }
        if !tools.isEmpty, tools.allSatisfy({ $0.name.hasPrefix("mcp__mistbrowser__slack_") && ($0.status == .failed || $0.permissionDenied) }) {
            return .init(String.localizedStringWithFormat(NSLocalizedString("browser.agentChat.toolGroup.slackFailed", value: "Couldn't complete %d Slack actions", comment: "Every Slack action failed or was denied"), tools.count))
        }
        if !tools.isEmpty, tools.allSatisfy({ DrifterBackgroundTools.nativeName($0.name).hasPrefix("mcp__mistbrowser__") && ($0.status == .failed || $0.permissionDenied) }) {
            return .init(String.localizedStringWithFormat(NSLocalizedString("browser.agentChat.toolGroup.browserFailed",
                value: "Couldn't complete %d browser actions", comment: "Browser tool group - Every action in the group failed or was denied"), tools.count))
        }
        let running = tools.contains { $0.status == .running }
        // A denied call never ran, so it counts only in its own trailing clause.
        let denied = tools.filter(\.permissionDenied).count
        var order: [Self] = []
        var counts: [Self: Int] = [:]
        for tool in tools where !tool.permissionDenied {
            let kind = Self.kind(of: tool, memory: memory, cwd: cwd)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        // Tool names go in as private-use placeholders, so capitalizing and count bolding leave them alone.
        var names: [Character: String] = [:]
        let text = order.map { kind -> String in
            guard case let .tool(name) = kind, let scalar = Unicode.Scalar(0xE000 + names.count) else {
                return AgentChatStrings.toolGroup(kind, count: counts[kind]!, running: running)
            }
            names[Character(scalar)] = displayName(name)
            return AgentChatStrings.toolGroup(.tool(String(Character(scalar))), count: counts[kind]!, running: running)
        } + (denied > 0 ? [AgentChatStrings.toolGroupDenied(count: denied)] : [])
        let joined = text.joined(separator: ", ")
        let capitalized = joined.prefix(1).uppercased() + joined.dropFirst()
        let bold = (Array(counts.values) + (denied > 0 ? [denied] : [])).map { String.localizedStringWithFormat("%d", $0) }
        var line = ClaudeCodeToolSummary.Line(capitalized, bold: bold)
        line.spans = line.spans.map { span in
            var span = span
            span.text = span.text.map { names[$0] ?? String($0) }.joined()
            return span
        }
        return line
    }
}
