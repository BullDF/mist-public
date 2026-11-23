import Foundation

enum DrifterSlackTools {
    static let readOnly = ["slack_search_public", "slack_search_public_and_private", "slack_search_channels", "slack_search_users", "slack_search_emojis",
        "slack_read_channel", "slack_read_thread", "slack_read_canvas", "slack_read_user_profile", "slack_read_file", "slack_read_list",
        "slack_list_channel_members", "slack_list_user_channels", "slack_get_reactions"]
    static let alwaysConfirm = ["slack_send_message", "slack_schedule_message", "slack_complete_file_upload"]
}

struct DrifterCLIServers {
    var userServers: [String: ClaudeCodeJSON] = [:]
    var connectors: [String: ClaudeCodeConnector] = [:]

    static func connectors(_ all: [String: ClaudeCodeConnector], mistSlackConfigured: Bool) -> [String: ClaudeCodeConnector] {
        guard mistSlackConfigured else { return all }
        return all.filter { name, _ in
            let name = name.lowercased()
            let unprefixed = name.hasPrefix("claude.ai ") ? String(name.dropFirst("claude.ai ".count)) : name
            return unprefixed != "slack"
        }
    }

    static func userServers(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: ClaudeCodeJSON] {
        let path = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home
        let file = path.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONDecoder().decode(ClaudeCodeJSON.self, from: data),
              case let .object(servers) = json["mcpServers"] else { return [:] }
        return servers.filter { name, server in
            name.lowercased() != "codex" && server["command"].string.map { URL(fileURLWithPath: $0).lastPathComponent != "codex" } != false
        }
    }
}

struct DrifterLaunchRequest {
    // An allowlist keeps every new CLI tool off until it is listed here.
    static let claudeTools = "Bash,Read,Write,Edit,Glob,Grep,NotebookEdit,AskUserQuestion,EnterPlanMode,ExitPlanMode,Monitor,TaskStop,ToolSearch,WebSearch,WebFetch,ListMcpResourcesTool,ReadMcpResourceTool,ReadMcpResourceDirTool,Artifact,ArtifactComments,ArtifactData,ArtifactCheck"
    let prompt: String
    var attachments: [AgentAttachment] = []
    var config: DrifterConfig
    let windowId: Int
    var mentions: [AgentTabMention] = []
    var sender: AgentMessageSender? = nil
    var parent: AgentMessageSender? = nil
    var slackThread = false
    var finishesTasks: Bool { parent != nil || slackThread }
    var chatId: UUID? = nil
    var resume: AgentChatResume? = nil
    var memory: DrifterMemory? = nil
    var skills: DrifterSkills? = nil
    var cliServers: DrifterCLIServers? = nil
    var inheritsCLIServers = false
    var home: DrifterHome? = nil
    var globalInstructions: String? = nil

    func instructions(for engine: DrifterEngine, home: DrifterHome) -> String {
        let memory = memory ?? DrifterMemory(home: home)
        let skills = skills ?? DrifterSkills(folder: home.skills, repository: home.isRepository ? home.folder : nil)
        var parts = [Self.baseInstructions,
            "Your home is `\(home.folder.path)`. It holds memory and skills, not code. When you start work in a repo, find its root, read its CLAUDE.md or AGENTS.md (both if both exist), and list its .claude/skills; run git, build and test commands in that repo, never in your home.",
            memory.instructions(for: engine),
            "Commit and push finished work as you go, in the repo it belongs to, unless that repo's own rules restrict pushing; stage only the files you changed. When a task is done, your final reply names anything left uncommitted, unpushed or still running.",
            skills.instructions()]
        if let chatId {
            parts.insert("Your chat ID is `\(AgentChatShortID.short(chatId))`. list_agents lists open chats with their parent and children. message_agent messages an existing chat as if Johnny typed it there. What you write in this chat reaches only Johnny, so answer another chat with message_agent when it needs an answer, never only to acknowledge. spawn_agent hands a self-contained task to a new child chat and returns its ID at once; message_agent is for a chat that already exists. A child reports back only through finish_task: its message arrives here when that turn ends, marked done (no reply needed) or blocked (it waits for your answer; send it with message_agent). Any question it waits on, and an error that stops it, arrive at once. After spawning or messaging a chat, end your turn instead of waiting or polling. Answer a child's question with message_agent. read_agent shows any open chat's recent transcript. stop_agent and close_agent act only on your own descendants. Chats nest three levels deep at most: top chat, child, grandchild. spawn_agent's model takes one of these IDs: \(DrifterModel.spawnModelIDs.joined(separator: ", ")); omitted model and effort default to this chat's model and effort. A chat spawns children only on its own model and effort, except that Opus and Fable chats may pick any model at any effort, and Astra chats any GPT model at any effort.", at: 1)
        }
        if let parent {
            parts.append("You are a child chat of \(parent.label), working on the task it gave you. End that task by calling finish_task: status done when it's finished, blocked when you can't go on without an answer from your parent. Its message is the only thing your parent hears from you: what you write in this chat reaches only Johnny, and a turn without finish_task reports nothing. So write the message for your parent and make it stand on its own: what you did or what you need, and anything left uncommitted, unpushed or still running. Mist sends it when your turn ends, so call it last, then end your turn. While background work you started is still running, end your turn without it and call it once that work is done. Never message_agent your parent to report or to ask; after blocked, its answer arrives as your next message.")
        }
        if engine != .codex {
            if let text = try? String(contentsOf: home.folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8) {
                parts.append("Your home's CLAUDE.md:\n" + text)
            }
            if home.isRepository, let globalInstructions { parts.append(globalInstructions) }
        }
        if engine != .claude {
            let polling = engine == .codex ? "exec_command with write_stdin polling or sleep loops" : "shell polling or sleep loops"
            parts.append("For anything long-running (builds, test suites, servers, downloads, waiting on a condition), use mistbrowser's run_in_background (one message when it exits) or monitor (a message per batch of output lines from a watching script), never \(polling). Both return at once: end your turn, and Mist sends you the result as a new message. stop_task stops one. Tasks stop when this chat closes.")
        }
        if !home.isRepository {
            parts.append("Your memory and skills are only the folders named above. Ignore any other memory or skill location your user instructions name, such as ~/Personal/drifter: never read or write it.")
        }
        return parts.joined(separator: "\n\n")
    }

    static let baseInstructions = "You are Drifter, Johnny's agent, running in Mist, his browser, alongside him in his own window. "
        + "Use the mistbrowser tools. Never ask the user to switch tabs. Tabs and tab groups the user mentions are listed by list_tabs, in the order the user's sidebar shows them. "
        + "For Johnny's email use list_mail_accounts, list_mail, search_mail, read_mail, write_mail_draft, send_mail and update_mail, never a webmail tab. send_mail asks Johnny in its own card. "
        + "For Slack use the slack_* tools when listed, never a Slack tab; they act as Johnny. slack_send_message, slack_schedule_message and slack_complete_file_upload ask Johnny in their own card. "
        + "To run a prompt later or on a schedule, use mistbrowser's schedule_prompt (Mist keeps schedules across relaunches); to ping Johnny with a macOS notification, use notify. "
        + "When the user mentions tabs, start with them; their tabId values work with use_tab. "
        + "You can read and write files and run shell commands anywhere on this Mac using your built-in tools. "
        + "To attach local files to a page, use upload_files. "
        + "Always use absolute paths, expanding ~. When no location is named, save to ~/Downloads. "
        + "Report the absolute path of every file you write. Never touch files the user didn't ask about. "
        + "Before buying something, sending a message or post outside email and Slack, or deleting data, ask in chat unless the user already said to go ahead."
    static let readOnlyTools = ["list_agents", "read_agent", "list_schedules", "list_mail_accounts", "list_mail", "search_mail", "read_mail", "list_tabs", "use_tab", "snapshot", "read_page", "read_console", "read_network", "list_downloads", "search_history", "scroll", "scroll_until", "hover", "select_text", "wait_for", "screenshot"] + DrifterSlackTools.readOnly

    static func server(node: URL, resources: URL, bundleId: String, windowId: Int, capability: String) -> CodexMCPServer {
        .init(command: node.path, args: [resources.appendingPathComponent("phi-browser-skill/scripts/mist-browser-mcp.mjs").path],
              env: ["PHI_BUNDLE_ID": bundleId, "MIST_BROWSER_WINDOW_ID": String(windowId), "PHI_AGENT_CAPABILITY": capability])
    }

    func claude(folder: URL, server: CodexMCPServer) -> ClaudeCodeLaunchRequest {
        var server = server
        server.env["MIST_FINISH_TASK"] = finishesTasks ? "1" : nil
        let home = home ?? memory?.home ?? DrifterHome(folder: folder, isRepository: false)
        let memory = memory ?? DrifterMemory(home: home)
        let skills = skills ?? .init(folder: home.skills)
        let canonicalSkillsPath = BrowserAgentFileAccess.canonicalURL(skills.folder)?.path ?? skills.folder.resolvingSymlinksInPath().path
        let settings = ClaudeCodeJSON.object([
            "autoMemoryDirectory": .string(memory.folder.path),
            "enabledPlugins": .object(["cc-plugin-plugin-authoring@builtin": .bool(false)]),
            // The advisor is a server tool (Opus) that `--tools` doesn't cover; it would escalate past the chat's model.
            // `-p` sessions withhold the claude.ai Artifact tools unless CLAUDE_CODE_ARTIFACT is set (`sdk_default_off`).
            "env": .object(["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": .string("1"), "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": .string("1"),
                            "CLAUDE_CODE_ARTIFACT": .string("1")]),
        ]).json()
        var servers = (cliServers?.connectors ?? [:]).mapValues { connector in
            ClaudeCodeJSON.object(["type": .string("claudeai-proxy"), "url": .string(connector.url), "id": .string(connector.id)])
        }
        servers.merge(cliServers?.userServers ?? [:]) { _, user in user }
        servers["mistbrowser"] = .object([
            "type": .string("stdio"), "command": .string(server.command),
            "args": .array(server.args.map(ClaudeCodeJSON.string)), "env": .object(server.env.mapValues(ClaudeCodeJSON.string)),
        ])
        let mcp = ClaudeCodeJSON.object(["mcpServers": .object(servers)]).json()
        let launch = ClaudeCodeLaunchConfig(folder: folder,
            model: ClaudeCodeModel(rawValue: config.model) ?? .opus, effort: ClaudeCodeEffort(rawValue: config.effort) ?? .xhigh)
        var arguments = ["--model", launch.model.rawValue, "--effort", launch.effort.rawValue,
                "--permission-mode", "default", "--tools", Self.claudeTools, "--settings", settings, "--mcp-config", mcp]
        arguments += ["--strict-mcp-config",
                "--disallowedTools", "Skill", "--add-dir", "/", "--setting-sources", "",
                "--allowedTools", "Read", "Glob", "Grep", "Edit(/" + canonicalSkillsPath + "/**)",
                "Edit(/" + (BrowserAgentFileAccess.canonicalURL(memory.folder)?.path ?? memory.folder.path) + "/**)"] + Self.readOnlyTools.map { "mcp__mistbrowser__" + $0 }
                + ["--append-system-prompt", instructions(for: .claude, home: home)]
        return .init(prompt: prompt, attachments: attachments, config: launch, launchArguments: arguments, mentions: mentions, sender: sender, resume: resume)
    }

    func codex(folder: URL, server: CodexMCPServer) -> CodexLaunchRequest {
        let home = home ?? memory?.home ?? DrifterHome(folder: folder, isRepository: false)
        return .init(prompt: prompt, attachments: attachments, model: config.model, effort: config.effort,
              cwd: folder, developerInstructions: instructions(for: .codex, home: home), mcpServers: ["mistbrowser": serverWithBackgroundTasks(server)],
              mentions: mentions, sender: sender, resume: resume,
              inheritsCLIServers: inheritsCLIServers)
    }

    func gemini(folder: URL, server: CodexMCPServer, cliHome: URL, preload: URL) -> GeminiLaunchRequest {
        let home = home ?? memory?.home ?? DrifterHome(folder: folder, isRepository: false)
        return .init(prompt: prompt, attachments: attachments, model: config.model, effort: config.effort,
                     cwd: folder, drifterHome: home.folder, cliHome: cliHome, preload: preload,
                     instructions: instructions(for: .gemini, home: home),
                     server: serverWithBackgroundTasks(server), mentions: mentions, sender: sender, resume: resume)
    }

    private func serverWithBackgroundTasks(_ server: CodexMCPServer) -> CodexMCPServer {
        var server = server
        server.env["MIST_BACKGROUND_TASKS"] = "1"
        server.env["MIST_FINISH_TASK"] = finishesTasks ? "1" : nil
        return server
    }
}

/// Expands only whole-line @ includes, with cycle and depth limits.
enum DrifterInstructionIncludes {
    static func expand(_ file: URL, home: URL, maximumDepth: Int = 5) -> String {
        var included = Set<String>()
        func visit(_ file: URL, depth: Int) -> String {
            let file = file.resolvingSymlinksInPath().standardizedFileURL
            guard depth <= maximumDepth, included.insert(file.path).inserted,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
            return text.components(separatedBy: "\n").map { line in
                guard line.hasPrefix("@"), line.count > 1 else { return line }
                let path = String(line.dropFirst())
                let target: URL
                if path == "~" { target = home }
                else if path.hasPrefix("~/") { target = home.appendingPathComponent(String(path.dropFirst(2))) }
                else if path.hasPrefix("/") { target = URL(fileURLWithPath: path) }
                else { target = file.deletingLastPathComponent().appendingPathComponent(path) }
                return visit(target, depth: depth + 1)
            }.joined(separator: "\n")
        }
        return visit(file, depth: 0)
    }
}
