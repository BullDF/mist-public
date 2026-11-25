import Foundation

struct AgentMailDraftPreview {
    var from: String
    var to: [String], cc: [String], bcc: [String]
    var subject: String, body: String
    var attachments: [String]
}

enum AgentChatStrings {
    static var askDrifter: String { NSLocalizedString("browser.newTabPage.placeholder.drifter", value: "Ask Drifter", comment: "Drifter composer placeholder; never translate the name") }
    static var markerAdd: String { NSLocalizedString("browser.agentChat.markerAdd", value: "Add marker", comment: "Chat row - Bookmark this message or reply") }
    static var markerRemove: String { NSLocalizedString("browser.agentChat.markerRemove", value: "Remove marker", comment: "Chat marker list - Remove this bookmark") }
    static var markerRename: String { NSLocalizedString("browser.agentChat.markerRename", value: "Rename", comment: "Chat marker list - Edit this bookmark's name") }
    static var markerList: String { NSLocalizedString("browser.agentChat.markerList", value: "Markers", comment: "Chat header - Open the list of named bookmarks") }
    static var markerName: String { NSLocalizedString("browser.agentChat.markerName", value: "Marker name", comment: "Chat marker - Name field placeholder and accessibility label") }
    static func markerNumber(_ position: Int) -> String {
        String(format: NSLocalizedString("browser.agentChat.markerNumber", value: "Marker %d", comment: "Chat marker - Default name for a message without text; %d is its position among the chat's markers"), position)
    }
    static var mailDraftPreview: ((String) -> AgentMailDraftPreview?)?
    static var slackChannelName: ((String) -> (name: String, isSelf: Bool)?)?
    static var slackUserName: ((String) -> String?)?
    static func slackDestination(_ id: String) -> String? {
        guard let channel = slackChannelName?(id) else { return nil }
        return channel.isSelf ? NSLocalizedString("browser.agent.slackSelfDM", value: "your own DM", comment: "Slack destination - The user's direct message to themself") : channel.name
    }
    static var agentTabs: String { NSLocalizedString("browser.agentChat.agentTabs", value: "Agent tabs", comment: "Agent chat - Names the tab group holding tabs the browser agent opened") }
    static func attachmentFailed(_ name: String) -> String {
        String(format: NSLocalizedString("browser.agentChat.attachmentFailed", value: "Couldn't attach “%@”.", comment: "Agent chat - error when a file attached to a message can't be copied into the chat; %@ is the file name"), name)
    }

    static var contextUsage: String { NSLocalizedString("browser.claudeCode.contextUsage", value: "Context usage", comment: "Claude Code - Context usage card title") }
    static var mcpTitle: String { NSLocalizedString("browser.claudeCode.mcp.title", value: "MCP servers", comment: "Claude Code - MCP servers card title") }
    static func mcpServers(_ count: Int) -> String { String(format: NSLocalizedString("browser.claudeCode.mcp.servers", value: "%d servers", comment: "Claude Code - Number of MCP servers"), count) }
    static func mcpTools(_ count: Int) -> String { String(format: NSLocalizedString("browser.claudeCode.mcp.tools", value: "%d tools", comment: "Claude Code - Number of tools on an MCP server"), count) }
    static func mcpNeedsCount(_ count: Int) -> String { String(format: NSLocalizedString("browser.claudeCode.mcp.needsCount", value: "%d need authentication", comment: "Claude Code - Number of MCP servers needing authentication"), count) }
    static var mcpAuthenticate: String { NSLocalizedString("browser.claudeCode.mcp.authenticate", value: "Authenticate with /mcp in a terminal.", comment: "Claude Code - MCP authentication hint") }
    static var mcpReconnect: String { NSLocalizedString("browser.claudeCode.mcp.reconnect", value: "Reconnect", comment: "Claude Code - Reconnect an MCP server") }
    static var mcpEnable: String { NSLocalizedString("browser.claudeCode.mcp.enable", value: "Enable", comment: "Claude Code - Enable an MCP server") }
    static var mcpDisable: String { NSLocalizedString("browser.claudeCode.mcp.disable", value: "Disable", comment: "Claude Code - Disable an MCP server") }
    static func mcpGroup(_ status: String) -> String {
        switch status {
        case "pending": return NSLocalizedString("browser.claudeCode.mcp.connecting", value: "Connecting", comment: "Claude Code - Connecting MCP server group")
        case "connected": return NSLocalizedString("browser.claudeCode.mcp.connected", value: "Connected", comment: "Claude Code - Connected MCP server group")
        case "needs-auth": return NSLocalizedString("browser.claudeCode.mcp.needsAuth", value: "Needs authentication", comment: "Claude Code - MCP servers needing authentication")
        case "disabled": return NSLocalizedString("browser.claudeCode.mcp.disabled", value: "Disabled", comment: "Claude Code - Disabled MCP server group")
        default: return NSLocalizedString("browser.claudeCode.mcp.failed", value: "Failed", comment: "Claude Code - Failed MCP server group")
        }
    }
    static func compaction(_ trigger: ClaudeCodeCompactionTrigger, preTokens: Int?, postTokens: Int?) -> String {
        let title = trigger == .auto
            ? NSLocalizedString("browser.claudeCode.compactedAutomatically", value: "Conversation compacted automatically", comment: "Claude Code - Automatic conversation compaction divider")
            : NSLocalizedString("browser.claudeCode.compacted", value: "Conversation compacted", comment: "Claude Code - Manual conversation compaction divider")
        guard let preTokens, let postTokens else { return title }
        return title + " · " + String(format: NSLocalizedString("browser.claudeCode.compactionTokens", value: "%1$@ → %2$@ tokens",
            comment: "Claude Code - Token counts before and after compaction"), preTokens.formatted(), postTokens.formatted())
    }
    static var currentTab: String { NSLocalizedString("browser.agentChat.mentionCurrentTab", value: "Current tab", comment: "Tab mention popup - Pinned first row that mentions the page beside the chat, or the window's last web page") }
    static var historyUnavailable: String { NSLocalizedString("browser.agentChat.historyUnavailable", value: "This chat's history can't be resumed, so your next message starts a new conversation.", comment: "Agent chat - Notice when the agent's saved session is gone and the chat continues in a new one") }
    static var restartHint: String { NSLocalizedString("browser.agentChat.restartHint", value: "Send a message to restart the chat.", comment: "Agent chat - Last line of the error shown when the agent stopped; the next message relaunches it") }
    /// The error notice of a chat whose agent stopped, which the next message restarts.
    static func failureNotice(_ message: String) -> String { message + "\n" + restartHint }
    /// Every name ends in the same noun, so the formats below agree with any of them.
    static func usageLimitName(_ window: String?) -> String {
        switch window {
        case "five_hour": return NSLocalizedString("browser.claudeCode.usageLimit.fiveHour", value: "5-hour limit", comment: "Claude Code usage limit name - The rolling 5-hour usage window")
        case "seven_day": return NSLocalizedString("browser.claudeCode.usageLimit.weekly", value: "Weekly limit", comment: "Claude Code usage limit name - The weekly usage window")
        case "seven_day_opus": return NSLocalizedString("browser.claudeCode.usageLimit.weeklyOpus", value: "Weekly Opus limit", comment: "Claude Code usage limit name - The weekly usage window of the Opus models")
        case "seven_day_sonnet": return NSLocalizedString("browser.claudeCode.usageLimit.weeklySonnet", value: "Weekly Sonnet limit", comment: "Claude Code usage limit name - The weekly usage window of the Sonnet models")
        case "seven_day_overage_included": return NSLocalizedString("browser.claudeCode.usageLimit.weeklyFable", value: "Weekly Fable limit", comment: "Claude Code usage limit name - The weekly usage window of the Fable models")
        case "overage": return NSLocalizedString("browser.claudeCode.usageLimit.credits", value: "Usage credit limit", comment: "Claude Code usage limit name - The spending cap on paid usage credits")
        default: return NSLocalizedString("browser.claudeCode.usageLimit.other", value: "Usage limit", comment: "Claude Code usage limit name - A usage limit Claude Code doesn't name")
        }
    }
    static func usageLimitUsed(_ window: String?, percent: Int) -> String {
        String(format: NSLocalizedString("browser.claudeCode.usageLimit.used", value: "%1$@: %2$@ used", comment: "Claude Code usage notice - %1$@ is the limit's name, such as Weekly limit; %2$@ is the percentage of it used"), usageLimitName(window), percent.formatted(.percent))
    }
    static func usageLimitNearlyReached(_ window: String?) -> String {
        String(format: NSLocalizedString("browser.claudeCode.usageLimit.nearlyReached", value: "%@: almost reached", comment: "Claude Code usage notice - %@ is the limit's name, such as Weekly limit"), usageLimitName(window))
    }
    static func usageLimitReached(_ window: String?) -> String {
        String(format: NSLocalizedString("browser.claudeCode.usageLimit.reached", value: "%@ reached", comment: "Claude Code usage notice - %@ is the limit's name, such as Weekly limit"), usageLimitName(window))
    }
    static var usingUsageCredits: String { NSLocalizedString("browser.claudeCode.usageLimit.usingCredits", value: "now using usage credits", comment: "Claude Code usage notice - Follows 'Weekly limit reached ·'; requests continue on paid usage credits") }
    /// Joins the notice's parts and the limit's localized reset time with middle dots.
    static func usageLimitNotice(_ parts: [String], resetsAt: Date?) -> String {
        let reset = resetsAt.map {
            String(format: NSLocalizedString("browser.claudeCode.usageLimit.resets", value: "resets %@", comment: "Claude Code usage notice - Follows the limit's state after a middle dot; %@ is the localized weekday, date and time the limit resets"),
                $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
        }
        return (parts + [reset].compactMap { $0 }).joined(separator: " · ")
    }
    static var removeMention: String { NSLocalizedString("browser.agentChat.removeMention", value: "Remove tab mention", comment: "Mention banner - Remove every mention of this tab from the draft") }
    static func browserPermission(_ request: AgentChatItem.PermissionRequest) -> (title: String, detail: String?, message: String?)? {
        // Some providers supply only a human-readable summary of the call.
        guard request.input != .null else { return nil }
        guard request.toolName.hasPrefix("mcp__mistbrowser__"), DrifterBackgroundTools.nativeName(request.toolName) == request.toolName else { return nil }
        let tool = String(request.toolName.dropFirst("mcp__mistbrowser__".count))
        let url = request.input["url"].string ?? ""
        let host = URL(string: url)?.host ?? url
        let action: String
        let detail: String?
        var message: String?
        switch tool {
        case "slack_complete_file_upload":
            if let channel = request.input["channel_id"].string, !channel.isEmpty {
                action = String(format: NSLocalizedString("browser.agent.permission.slackShareFile", value: "share a file in %@", comment: "Permission to share a Slack file; %@ is the destination"), slackDestination(channel) ?? channel)
            } else {
                action = NSLocalizedString("browser.agent.permission.slackUploadFile", value: "upload a file to Slack", comment: "Permission to upload a file without a Slack destination")
            }
            let lines = [request.input["title"].string, request.input["initial_comment"].string].compactMap { $0 }
            detail = lines.isEmpty ? nil : lines.joined(separator: "\n")
        case "slack_send_message", "slack_schedule_message":
            let channel = request.input["channel_id"].string ?? ""
            let destination = slackDestination(channel) ?? channel
            message = SlackMrkdwn.resolvingMentions(String((request.input["message"].string ?? "").prefix(2000)),
                user: { slackUserName?($0) }, channel: { slackChannelName?($0)?.name })
            if tool == "slack_schedule_message" {
                action = String(format: NSLocalizedString("browser.agent.permission.slackSchedule", value: "schedule a Slack message to %@", comment: "Permission to schedule a Slack message; %@ is the destination"), destination)
                let postAt = request.input["post_at"].double ?? request.input["post_at"].string.flatMap(Double.init)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let date = postAt.flatMap { $0.isFinite ? formatter.string(from: Date(timeIntervalSince1970: $0)) : nil } ?? request.input["post_at"].string ?? ""
                detail = String(format: NSLocalizedString("browser.agent.permission.slackScheduledFor", value: "Scheduled for %@", comment: "Slack schedule preview; %@ is the localized date and time"), date)
            } else {
                let format = request.input["thread_ts"].string?.isEmpty == false
                    ? NSLocalizedString("browser.agent.permission.slackReply", value: "reply in a Slack thread in %@", comment: "Permission to reply in a Slack thread; %@ is the destination")
                    : NSLocalizedString("browser.agent.permission.slackSend", value: "send a Slack message to %@", comment: "Permission to send a Slack message; %@ is the destination")
                action = String(format: format, destination)
                detail = nil
            }
        case "slack_add_reaction":
            let channel = request.input["channel_id"].string ?? ""
            action = String(format: NSLocalizedString("browser.agent.permission.slackReaction", value: "react with :%1$@: in %2$@", comment: "Permission to react in Slack; %1$@ is the emoji name and %2$@ is the destination"), request.input["emoji"].string ?? "", slackDestination(channel) ?? channel)
            detail = nil
        case let name where name.hasPrefix("slack_"):
            action = NSLocalizedString("browser.agent.permission.slackChange", value: "make a change in Slack", comment: "Permission to use another Slack tool")
            detail = name
        case "update_mail":
            let count = request.input["ids"].array.count
            let verb = request.input["action"].string ?? ""
            let format: String
            switch verb {
            case "read": format = NSLocalizedString("browser.agent.permission.mailRead", value: count == 1 ? "mark %d email as read" : "mark %d emails as read", comment: "Permission to mark mail read")
            case "unread": format = NSLocalizedString("browser.agent.permission.mailUnread", value: count == 1 ? "mark %d email as unread" : "mark %d emails as unread", comment: "Permission to mark mail unread")
            case "flag": format = NSLocalizedString("browser.agent.permission.mailFlag", value: count == 1 ? "flag %d email" : "flag %d emails", comment: "Permission to flag mail")
            case "unflag": format = NSLocalizedString("browser.agent.permission.mailUnflag", value: count == 1 ? "unflag %d email" : "unflag %d emails", comment: "Permission to unflag mail")
            case "archive": format = NSLocalizedString("browser.agent.permission.mailArchive", value: count == 1 ? "archive %d email" : "archive %d emails", comment: "Permission to archive mail")
            case "move": format = NSLocalizedString("browser.agent.permission.mailMove", value: count == 1 ? "move %1$d email to %2$@" : "move %1$d emails to %2$@", comment: "Permission to move mail to a mailbox")
            default: format = NSLocalizedString("browser.agent.permission.mailTrash", value: count == 1 ? "move %d email to the Trash" : "move %d emails to the Trash", comment: "Permission to trash mail")
            }
            action = String.localizedStringWithFormat(format, count, request.input["mailbox"].string ?? "")
            detail = nil
        case "send_mail", "write_mail_draft":
            let id = request.input["draftId"].string
            let preview = tool == "send_mail" ? id.flatMap { mailDraftPreview?($0) } : nil
            let subject = preview?.subject ?? request.input["subject"].string ?? ""
            let to = preview?.to ?? request.input["to"].array.compactMap(\.string)
            let cc = preview?.cc ?? request.input["cc"].array.compactMap(\.string)
            let bcc = preview?.bcc ?? request.input["bcc"].array.compactMap(\.string)
            let from = preview?.from ?? request.input["account"].string ?? ""
            let body = preview?.body ?? request.input["body"].string ?? ""
            let attachments = preview?.attachments ?? request.input["attachments"].array.compactMap(\.string).map { URL(fileURLWithPath: $0).lastPathComponent }
            if tool == "write_mail_draft" { action = NSLocalizedString("browser.agent.permission.mailDraft", value: "save an email draft", comment: "Permission to save a mail draft") }
            else if id != nil && preview == nil { action = NSLocalizedString("browser.agent.permission.mailSendDraft", value: "send a draft", comment: "Permission to send a draft without a preview") }
            else if subject.isEmpty { action = NSLocalizedString("browser.agent.permission.mailSend", value: "send an email", comment: "Permission to send mail") }
            else { action = String(format: NSLocalizedString("browser.agent.permission.mailSendSubject", value: "send “%1$@” to %2$@", comment: "Permission to send subject to recipients"), subject, to.joined(separator: ", ")) }
            if let id, preview == nil, tool == "send_mail" { detail = id }
            else {
                var lines: [String] = []
                if !from.isEmpty { lines.append(String(format: NSLocalizedString("mail.message.from", value: "From: %@", comment: "Mail sender"), from)) }
                if !to.isEmpty { lines.append(String(format: NSLocalizedString("mail.message.to", value: "To: %@", comment: "Mail recipients"), to.joined(separator: ", "))) }
                if !cc.isEmpty { lines.append(String(format: NSLocalizedString("mail.message.cc", value: "Cc: %@", comment: "Mail copy recipients"), cc.joined(separator: ", "))) }
                if !bcc.isEmpty { lines.append(String(format: NSLocalizedString("mail.message.bcc", value: "Bcc: %@", comment: "Mail blind copy recipients"), bcc.joined(separator: ", "))) }
                if !body.isEmpty || !attachments.isEmpty { lines.append(""); if !body.isEmpty { lines.append(body) } }
                lines.append(contentsOf: attachments)
                detail = lines.joined(separator: "\n")
            }
        case "spawn_agent":
            action = NSLocalizedString("browser.agent.permission.spawnAgent", value: "start a chat", comment: "Browser tool permission action phrase: start a child chat")
            detail = [request.input["title"].string, request.input["brief"].string].compactMap { $0 }.joined(separator: "\n\n")
        case "schedule_prompt":
            action = NSLocalizedString("browser.agent.permission.schedulePrompt", value: "schedule a prompt", comment: "Permission action phrase for scheduling a Drifter prompt")
            detail = [request.input["title"].string, request.input["prompt"].string].compactMap { $0 }.joined(separator: "\n\n")
        case "cancel_schedule":
            action = String(format: NSLocalizedString("browser.agent.permission.cancelSchedule", value: "cancel schedule %@", comment: "Permission action phrase; %@ is the schedule ID"), request.input["schedule_id"].string ?? "")
            detail = nil
        case "stop_agent":
            action = String(format: NSLocalizedString("browser.agent.permission.stopAgent", value: "stop %@", comment: "Browser tool permission action phrase; %@ is a child chat's ID"), request.input["id"].string ?? "")
            detail = nil
        case "close_agent":
            action = String(format: NSLocalizedString("browser.agent.permission.closeAgent", value: "close %@", comment: "Browser tool permission action phrase; %@ is a child chat's ID"), request.input["id"].string ?? "")
            detail = nil
        case "message_agent":
            action = String(format: NSLocalizedString("browser.agent.permission.messageAgent", value: "message %@", comment: "Browser tool permission action phrase; %@ is another chat's short ID"), request.input["id"].string ?? "")
            detail = request.input["text"].string
        case "click" where request.input["button"].string == "right":
            action = NSLocalizedString("browser.agent.permission.rightClick", value: "right-click an element", comment: "Browser tool permission action phrase: right-click a web page element to open its menu")
            detail = nil
        case "click" where request.input["double"].bool:
            action = NSLocalizedString("browser.agent.permission.doubleClick", value: "double-click an element", comment: "Browser tool permission action phrase: double-click a web page element")
            detail = nil
        case "click":
            action = NSLocalizedString("browser.agent.permission.click", value: "click an element", comment: "Browser tool permission action phrase")
            detail = nil
        case "save_page":
            action = NSLocalizedString("browser.agent.permission.savePage", value: "save a page", comment: "Browser tool permission action phrase: save a web page as a PDF or MHTML file")
            detail = request.input["path"].string
        case "evaluate":
            action = NSLocalizedString("browser.agent.permission.evaluate", value: "run JavaScript on a page", comment: "Browser tool permission action phrase: run a JavaScript expression in a web page")
            detail = request.input["expression"].string
        case "drag":
            action = NSLocalizedString("browser.agent.permission.drag", value: "drag an element", comment: "Browser tool permission action phrase: drag a web page element with the mouse")
            detail = nil
        case "go_back":
            action = NSLocalizedString("browser.agent.permission.goBack", value: "go back a page", comment: "Browser tool permission action phrase: go back to the previous page in a tab's history")
            detail = nil
        case "go_forward":
            action = NSLocalizedString("browser.agent.permission.goForward", value: "go forward a page", comment: "Browser tool permission action phrase: go forward to the next page in a tab's history")
            detail = nil
        case "navigate":
            action = String(format: NSLocalizedString("browser.agent.permission.navigate", value: "go to %@", comment: "Browser tool permission action phrase; %@ is the website host"), host)
            detail = url
        case "open_tab":
            action = String(format: NSLocalizedString("browser.agent.permission.open", value: "open %@ in a new tab", comment: "Browser tool permission action phrase; %@ is the website host"), host)
            detail = url
        case "reload":
            action = NSLocalizedString("browser.agent.permission.reload", value: "reload a page", comment: "Browser tool permission action phrase")
            detail = nil
        case "fill", "type_text":
            action = NSLocalizedString("browser.agent.permission.type", value: "enter text", comment: "Browser tool permission action phrase")
            detail = request.input["text"].string
        case "press_key":
            let key = ClaudeCodeToolSummary.browserKeyLabel(request.input)
            action = String(format: NSLocalizedString("browser.agent.permission.key", value: "press %@", comment: "Browser tool permission action phrase; %@ is the key"), key)
            detail = key
        case "select_option":
            action = NSLocalizedString("browser.agent.permission.option", value: "choose an option", comment: "Browser tool permission action phrase: pick an option in a web page's dropdown menu")
            detail = request.input["label"].string ?? request.input["value"].string
        case "close_tab":
            action = NSLocalizedString("browser.agent.permission.close", value: "close a tab", comment: "Browser tool permission action phrase")
            detail = nil
        case "handle_dialog":
            action = NSLocalizedString("browser.agent.permission.dialog", value: "respond to a dialog", comment: "Browser tool permission action phrase")
            detail = nil
        case "scroll":
            action = NSLocalizedString("browser.agent.permission.scroll", value: "scroll a page", comment: "Browser tool permission action phrase")
            detail = nil
        case "save_screenshot":
            action = NSLocalizedString("browser.agent.permission.saveScreenshot", value: "save a screenshot", comment: "Browser tool permission action phrase")
            detail = request.input["path"].string
        case "export_bookmarks":
            action = NSLocalizedString("browser.agent.permission.exportBookmarks", value: "export bookmarks", comment: "Browser tool permission action phrase")
            detail = request.input["path"].string ?? request.input["space"].string
        case "start_recording":
            action = NSLocalizedString("browser.agent.permission.startRecording", value: "record this tab", comment: "Browser tool permission action phrase")
            detail = request.input["path"].string
        case "upload_files":
            action = NSLocalizedString("browser.agent.permission.upload", value: "upload files", comment: "Browser tool permission action phrase")
            detail = request.input["paths"].array.compactMap(\.string).joined(separator: "\n")
        default:
            action = NSLocalizedString("browser.agent.permission.other", value: "use a browser tool", comment: "Browser tool permission action phrase for other tools")
            detail = nil
        }
        let name = MistAppID.drifter.name
        return (String(format: NSLocalizedString("browser.agent.permission.title", value: "%1$@ wants to %2$@", comment: "Browser tool permission title; %1$@ is Browser Agent, %2$@ is the action phrase"), name, action), detail, message)
    }
    static var handOffTitle: String {
        String(format: NSLocalizedString("browser.agentChat.handOff.title", value: "%@ is waiting for you", comment: "Card above the chat composer while the agent waits for the user to do a step himself, such as signing in; %@ is the app name Drifter"), MistAppID.drifter.name)
    }
    static var handOffTab: String { NSLocalizedString("browser.agentChat.handOff.tab", value: "In the tab “%@”", comment: "Hand-off card line naming the tab the user should use; %@ is the tab title") }
    static var handOffDone: String { NSLocalizedString("browser.agentChat.handOff.done", value: "Done", comment: "Hand-off card button the user presses once he has done the step the agent asked for") }
    static var queueSendNow: String { NSLocalizedString("browser.agentChat.queue.sendNow", value: "Send now", comment: "Button sending a queued message right away") }
    static var queueEdit: String { NSLocalizedString("browser.agentChat.queue.edit", value: "Edit", comment: "Move a queued message back into the composer") }
    static var queueDelete: String { NSLocalizedString("browser.agentChat.queue.delete", value: "Delete", comment: "Remove a queued message") }
    static var queuePaused: String { NSLocalizedString("browser.agentChat.queue.paused", value: "Queue paused because you interrupted", comment: "Queued messages wait after the user stopped the turn") }
    static func toolInterruption(_ text: String, denied: Bool) -> String? {
        let text = text.lowercased()
        guard text.contains("the user doesn't want to proceed") || text.contains("tool use rejected") ||
              text.contains("tool use was rejected") || text.contains("request interrupted") ||
              text.contains("interrupted by user") || text.contains("interrupted by the user") ||
              text.contains("rejected by user") || text.contains("tool call was cancelled") else { return nil }
        return denied ? self.denied : stopped
    }
    static func peerMessage(_ name: String, firstLine: String) -> String {
        String(format: NSLocalizedString("browser.agentChat.peerMessage", value: "› Message from @%1$@: %2$@", comment: "Incoming peer message: sender name and first line"), name, firstLine)
    }
    static func peerHeld(_ name: String) -> String {
        String(format: NSLocalizedString("browser.agentChat.peerHeld", value: "Message from @%@ is held because the permission modes differ", comment: "Incoming message waiting for compatible permission modes"), name)
    }
    static func peerDropped(_ name: String) -> String {
        String(format: NSLocalizedString("browser.agentChat.peerDropped", value: "Message from @%@ was not delivered", comment: "Incoming message dropped by the CLI"), name)
    }
    /// Calls Johnny denied, which never ran; the last part of a group's summary.
    static func toolGroupDenied(count: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString("browser.agentChat.toolGroup.denied", value: count == 1 ? "%d action denied" : "%d actions denied", comment: "Grouped tools the user denied, which never ran; %d is the count; part of a comma-separated summary"), count)
    }
    static func toolGroup(_ kind: AgentChatToolGroupKind, count: Int, running: Bool = false) -> String {
        if running {
            let format: String
            switch kind {
            case .memory: format = NSLocalizedString("browser.agentChat.toolGroup.memory.running", value: count == 1 ? "saving %d memory" : "saving %d memories", comment: "Grouped tools currently running: memory files the agent is saving; part of a comma-separated summary")
            case .recall: format = NSLocalizedString("browser.agentChat.toolGroup.recall.running", value: count == 1 ? "recalling %d memory" : "recalling %d memories", comment: "Grouped tools currently running: memory files the agent is reading back; part of a comma-separated summary")
            case .read: format = NSLocalizedString("browser.agentChat.toolGroup.read.running", value: count == 1 ? "reading %d file" : "reading %d files", comment: "Grouped tools currently running; number of operations")
            case .search: format = NSLocalizedString("browser.agentChat.toolGroup.search.running", value: count == 1 ? "searching %d pattern" : "searching %d patterns", comment: "Grouped tools currently running; number of operations")
            case .shell: format = NSLocalizedString("browser.agentChat.toolGroup.shell.running", value: count == 1 ? "running %d shell command" : "running %d shell commands", comment: "Grouped tools currently running; number of operations")
            case .fetch: format = NSLocalizedString("browser.agentChat.toolGroup.fetch.running", value: count == 1 ? "fetching %d page" : "fetching %d pages", comment: "Grouped tools currently running; number of operations")
            case .web: format = NSLocalizedString("browser.agentChat.toolGroup.web.running", value: count == 1 ? "searching the web %d time" : "searching the web %d times", comment: "Grouped tools currently running; number of operations")
            case .sleep: format = NSLocalizedString("browser.agentChat.toolGroup.sleep.running", value: count == 1 ? "pausing %d time" : "pausing %d times", comment: "Grouped pauses currently running; number of pauses")
            case .imageGeneration: format = NSLocalizedString("browser.agentChat.toolGroup.imageGeneration.running", value: count == 1 ? "generating %d image" : "generating %d images", comment: "Grouped image generation currently running; number of images")
            case .browserRead: format = NSLocalizedString("browser.agentChat.toolGroup.browserRead.running", value: count == 1 ? "reading %d page" : "reading %d pages", comment: "Grouped tools currently running; number of operations")
            case .browserScreenshot: format = NSLocalizedString("browser.agentChat.toolGroup.browserScreenshot.running", value: count == 1 ? "capturing %d screenshot" : "capturing %d screenshots", comment: "Grouped tools currently running: page screenshots being captured; part of a comma-separated summary")
            case .screenshotsSaved: format = NSLocalizedString("browser.agentChat.toolGroup.screenshotsSaved.running", value: count == 1 ? "saving %d screenshot" : "saving %d screenshots", comment: "Grouped screenshot saves running; number of screenshots")
            case .bookmarksExported: format = NSLocalizedString("browser.agentChat.toolGroup.bookmarksExported.running", value: count == 1 ? "exporting bookmarks %d time" : "exporting bookmarks %d times", comment: "Grouped bookmark exports in progress; number of exports")
            case .chatMounted: format = NSLocalizedString("browser.agentChat.toolGroup.chatMounted.running", value: count == 1 ? "mounting to a tab %d time" : "mounting to a tab %d times", comment: "Grouped chat mounts in progress; number of mounts")
            case .chatUnmounted: format = NSLocalizedString("browser.agentChat.toolGroup.chatUnmounted.running", value: count == 1 ? "unmounting from a tab %d time" : "unmounting from a tab %d times", comment: "Grouped chat unmounts in progress; number of unmounts")
            case .recordingStarted: format = NSLocalizedString("browser.agentChat.toolGroup.recordingStarted.running", value: count == 1 ? "starting %d recording" : "starting %d recordings", comment: "Grouped tab recordings starting; number of recordings")
            case .recordingsSaved: format = NSLocalizedString("browser.agentChat.toolGroup.recordingsSaved.running", value: count == 1 ? "saving %d recording" : "saving %d recordings", comment: "Grouped tab recording saves running; number of recordings")
            case .browserClick: format = NSLocalizedString("browser.agentChat.toolGroup.browserClick.running", value: count == 1 ? "clicking %d element" : "clicking %d elements", comment: "Grouped tools currently running; number of operations")
            case .browserDrag: format = NSLocalizedString("browser.agentChat.toolGroup.browserDrag.running", value: count == 1 ? "dragging %d element" : "dragging %d elements", comment: "Grouped tools currently running: elements being dragged with the mouse on a web page; part of a comma-separated summary")
            case .browserType: format = NSLocalizedString("browser.agentChat.toolGroup.browserType.running", value: count == 1 ? "entering text %d time" : "entering text %d times", comment: "Grouped tools currently running; number of operations")
            case .browserKey: format = NSLocalizedString("browser.agentChat.toolGroup.browserKey.running", value: count == 1 ? "pressing %d key" : "pressing %d keys", comment: "Grouped tools currently running: keyboard keys being pressed on a page; part of a comma-separated summary")
            case .browserOption: format = NSLocalizedString("browser.agentChat.toolGroup.browserOption.running", value: count == 1 ? "choosing %d option" : "choosing %d options", comment: "Grouped tools currently running: options being chosen in a web page's dropdown menus; part of a comma-separated summary")
            case .browserSelectText: format = NSLocalizedString("browser.agentChat.toolGroup.browserSelectText.running", value: count == 1 ? "selecting text %d time" : "selecting text %d times", comment: "Grouped tools currently running: text being selected on a web page; number of times; part of a comma-separated summary")
            case .browserHover: format = NSLocalizedString("browser.agentChat.toolGroup.browserHover.running", value: count == 1 ? "hovering over %d element" : "hovering over %d elements", comment: "Grouped tools currently running: hovering over web page elements; number of elements")
            case .browserUpload: format = NSLocalizedString("browser.agentChat.toolGroup.browserUpload.running", value: count == 1 ? "uploading files %d time" : "uploading files %d times", comment: "Grouped tools currently running; number of operations")
            case .browserOpen: format = NSLocalizedString("browser.agentChat.toolGroup.browserOpen.running", value: count == 1 ? "opening %d page" : "opening %d pages", comment: "Grouped tools currently running; number of operations")
            case .browserReload: format = NSLocalizedString("browser.agentChat.toolGroup.browserReload.running", value: count == 1 ? "reloading %d page" : "reloading %d pages", comment: "Grouped tools currently running: pages being reloaded; part of a comma-separated summary")
            case .browserScroll: format = NSLocalizedString("browser.agentChat.toolGroup.browserScroll.running", value: count == 1 ? "scrolling %d page" : "scrolling %d pages", comment: "Grouped tools currently running; number of operations")
            case .browserWait: format = NSLocalizedString("browser.agentChat.toolGroup.browserWait.running", value: count == 1 ? "waiting for %d page" : "waiting for %d pages", comment: "Grouped tools currently running: waits for a page to load or change; part of a comma-separated summary")
            case .browserDialog: format = NSLocalizedString("browser.agentChat.toolGroup.browserDialog.running", value: count == 1 ? "handling %d dialog" : "handling %d dialogs", comment: "Grouped tools currently running: web page dialogs being accepted or dismissed; part of a comma-separated summary")
            case .browserTabs: format = NSLocalizedString("browser.agentChat.toolGroup.browserTabs.running", value: count == 1 ? "listing tabs %d time" : "listing tabs %d times", comment: "Grouped tools currently running: lists of the window's tabs; number of times; part of a comma-separated summary")
            case .browserHistory: format = NSLocalizedString("browser.agentChat.toolGroup.browserHistory.running", value: count == 1 ? "searching history %d time" : "searching history %d times", comment: "Grouped tools currently running: searches of the browsing history; number of times; part of a comma-separated summary")
            case .browserDownloads: format = NSLocalizedString("browser.agentChat.toolGroup.browserDownloads.running", value: count == 1 ? "listing downloads %d time" : "listing downloads %d times", comment: "Grouped tools currently running: lists of the window's downloads; number of times; part of a comma-separated summary")
            case .pagesSaved: format = NSLocalizedString("browser.agentChat.toolGroup.pagesSaved.running", value: count == 1 ? "saving %d page" : "saving %d pages", comment: "Grouped tools currently running: web pages being saved as PDF or MHTML files; number of pages; part of a comma-separated summary")
            case .browserScript: format = NSLocalizedString("browser.agentChat.toolGroup.browserScript.running", value: count == 1 ? "running JavaScript %d time" : "running JavaScript %d times", comment: "Grouped tools currently running: JavaScript the agent runs in a web page; number of times; part of a comma-separated summary")
            case .browserLogs: format = NSLocalizedString("browser.agentChat.toolGroup.browserLogs.running", value: count == 1 ? "reading page logs %d time" : "reading page logs %d times", comment: "Grouped tools currently running: the agent reads a web page's console messages or network requests; number of times; part of a comma-separated summary")
            case .browserGroup: format = NSLocalizedString("browser.agentChat.toolGroup.browserGroup.running", value: count == 1 ? "organizing tabs %d time" : "organizing tabs %d times", comment: "Grouped tools currently running: the agent groups, renames or ungroups tab groups; number of times; part of a comma-separated summary")
            case .browserConnect: format = NSLocalizedString("browser.agentChat.toolGroup.browserConnect.running", value: count == 1 ? "connecting to %d tab" : "connecting to %d tabs", comment: "Grouped tools currently running: the agent attaches to tabs to work in them; part of a comma-separated summary")
            case .browserClose: format = NSLocalizedString("browser.agentChat.toolGroup.browserClose.running", value: count == 1 ? "closing %d tab" : "closing %d tabs", comment: "Grouped tools currently running: tabs being closed; part of a comma-separated summary")
            case .monitor: format = NSLocalizedString("browser.agentChat.toolGroup.monitor.running", value: count == 1 ? "starting %d monitor" : "starting %d monitors", comment: "Grouped tools currently running: background monitors being started; part of a comma-separated summary")
            case .stopTask: format = NSLocalizedString("browser.agentChat.toolGroup.stopTask.running", value: count == 1 ? "stopping %d background task" : "stopping %d background tasks", comment: "Grouped tools currently running: background tasks being stopped; part of a comma-separated summary")
            case .toolSearch: format = NSLocalizedString("browser.agentChat.toolGroup.toolSearch.running", value: count == 1 ? "looking up tools %d time" : "looking up tools %d times", comment: "Grouped tools currently running: the agent looks up which tools it can use; number of times; part of a comma-separated summary")
            case .skill: format = NSLocalizedString("browser.agentChat.toolGroup.skill.running", value: count == 1 ? "using %d skill" : "using %d skills", comment: "Grouped tools currently running: Claude Code skills being used; part of a comma-separated summary")
            case .message: format = NSLocalizedString("browser.agentChat.toolGroup.message.running", value: count == 1 ? "sending %d message" : "sending %d messages", comment: "Grouped tools currently running: messages being sent to other agent sessions; part of a comma-separated summary")
            case .agents: format = NSLocalizedString("browser.agentChat.toolGroup.agents.running", value: count == 1 ? "listing agents %d time" : "listing agents %d times", comment: "Grouped tools currently running: lists of other agent sessions; number of times; part of a comma-separated summary")
            case .spawnAgent: format = NSLocalizedString("browser.agentChat.toolGroup.spawnAgent.running", value: count == 1 ? "spawning %d agent" : "spawning %d agents", comment: "Grouped chat tools running; number of agents")
            case .readAgent: format = NSLocalizedString("browser.agentChat.toolGroup.readAgent.running", value: count == 1 ? "reading agents %d time" : "reading agents %d times", comment: "Grouped chat tools running; number of reads")
            case .slackRead: format = NSLocalizedString("browser.agentChat.toolGroup.slackRead.running", value: count == 1 ? "reading Slack %d time" : "reading Slack %d times", comment: "Grouped Slack actions running; %d is the count")
            case .slackSearch: format = NSLocalizedString("browser.agentChat.toolGroup.slackSearch.running", value: count == 1 ? "searching Slack %d time" : "searching Slack %d times", comment: "Grouped Slack actions running; %d is the count")
            case .slackSend: format = NSLocalizedString("browser.agentChat.toolGroup.slackSend.running", value: count == 1 ? "sending %d Slack message" : "sending %d Slack messages", comment: "Grouped Slack actions running; %d is the count")
            case .slackChange: format = NSLocalizedString("browser.agentChat.toolGroup.slackChange.running", value: count == 1 ? "using Slack %d time" : "using Slack %d times", comment: "Grouped Slack actions running; %d is the count")
            case .mailList: format = NSLocalizedString("browser.agentChat.toolGroup.mailList.running", value: count == 1 ? "listing mail %d time" : "listing mail %d times", comment: "Grouped mail listings running")
            case .mailSearch: format = NSLocalizedString("browser.agentChat.toolGroup.mailSearch.running", value: count == 1 ? "searching mail %d time" : "searching mail %d times", comment: "Grouped mail searches running")
            case .mailRead: format = NSLocalizedString("browser.agentChat.toolGroup.mailRead.running", value: count == 1 ? "reading %d email" : "reading %d emails", comment: "Grouped email reads running")
            case .mailDraft: format = NSLocalizedString("browser.agentChat.toolGroup.mailDraft.running", value: count == 1 ? "writing %d draft" : "writing %d drafts", comment: "Grouped draft writes running")
            case .mailSend: format = NSLocalizedString("browser.agentChat.toolGroup.mailSend.running", value: count == 1 ? "sending %d email" : "sending %d emails", comment: "Grouped mail sends running")
            case .mailChange: format = NSLocalizedString("browser.agentChat.toolGroup.mailChange.running", value: count == 1 ? "updating emails %d time" : "updating emails %d times", comment: "Grouped mail updates running")
            case .stopAgent: format = NSLocalizedString("browser.agentChat.toolGroup.stopAgent.running", value: count == 1 ? "stopping %d agent" : "stopping %d agents", comment: "Grouped chat tools running; number of agents")
            case .closeAgent: format = NSLocalizedString("browser.agentChat.toolGroup.closeAgent.running", value: count == 1 ? "closing %d agent" : "closing %d agents", comment: "Grouped chat tools running; number of agents")
            case .code: format = NSLocalizedString("browser.agentChat.toolGroup.code.running", value: count == 1 ? "looking up code %d time" : "looking up code %d times", comment: "Grouped tools currently running: code lookups such as definitions or references; number of times; part of a comma-separated summary")
            case .scheduleTask: format = NSLocalizedString("browser.agentChat.toolGroup.scheduleTask.running", value: count == 1 ? "scheduling %d task" : "scheduling %d tasks", comment: "Grouped tools currently running: recurring tasks being scheduled; part of a comma-separated summary")
            case .cancelScheduledTask: format = NSLocalizedString("browser.agentChat.toolGroup.cancelScheduledTask.running", value: count == 1 ? "canceling %d scheduled task" : "canceling %d scheduled tasks", comment: "Grouped tools currently running: scheduled tasks being canceled; part of a comma-separated summary")
            case .scheduledTasks: format = NSLocalizedString("browser.agentChat.toolGroup.scheduledTasks.running", value: count == 1 ? "listing scheduled tasks %d time" : "listing scheduled tasks %d times", comment: "Grouped tools currently running: lists of scheduled tasks; number of times; part of a comma-separated summary")
            case .wakeup: format = NSLocalizedString("browser.agentChat.toolGroup.wakeup.running", value: count == 1 ? "scheduling %d wakeup" : "scheduling %d wakeups", comment: "Grouped tools currently running: times for the agent to resume on its own being scheduled; part of a comma-separated summary")
            case .planMode: format = NSLocalizedString("browser.agentChat.toolGroup.planMode.running", value: count == 1 ? "entering plan mode %d time" : "entering plan mode %d times", comment: "Grouped tools currently running: switches to Claude Code's Plan permission mode; number of times; part of a comma-separated summary")
            case .notification: format = NSLocalizedString("browser.agentChat.toolGroup.notification.running", value: count == 1 ? "sending %d notification" : "sending %d notifications", comment: "Grouped tools currently running: notifications being sent to the user; part of a comma-separated summary")
            case .mcpResources: format = NSLocalizedString("browser.agentChat.toolGroup.mcpResources.running", value: count == 1 ? "listing MCP resources %d time" : "listing MCP resources %d times", comment: "Grouped tools currently running: lists of MCP server resources; number of times; part of a comma-separated summary")
            case .mcpResource: format = NSLocalizedString("browser.agentChat.toolGroup.mcpResource.running", value: count == 1 ? "reading %d MCP resource" : "reading %d MCP resources", comment: "Grouped tools currently running: MCP server resources being read; part of a comma-separated summary")
            case let .tool(name):
                format = NSLocalizedString("browser.agentChat.toolGroup.tool.running", value: count == 1 ? "using %2$@ %1$d time" : "using %2$@ %1$d times", comment: "Grouped tools currently running: %1$d is how many times; %2$@ is the tool's own name, shown as is; part of a comma-separated summary")
                return String.localizedStringWithFormat(format, count, name)
            }
            return String.localizedStringWithFormat(format, count)
        }
        let format: String
        switch kind {
        case .read: format = NSLocalizedString("browser.agentChat.toolGroup.read", value: count == 1 ? "read %d file" : "read %d files", comment: "Grouped tools: number of files read")
        case .memory: format = NSLocalizedString("browser.agentChat.toolGroup.memory", value: count == 1 ? "saved %d memory" : "saved %d memories", comment: "Grouped tools: memory files the agent saved; part of a comma-separated summary")
        case .recall: format = NSLocalizedString("browser.agentChat.toolGroup.recall", value: count == 1 ? "recalled %d memory" : "recalled %d memories", comment: "Grouped tools: memory files the agent read back; part of a comma-separated summary")
        case .search: format = NSLocalizedString("browser.agentChat.toolGroup.search", value: count == 1 ? "searched %d pattern" : "searched %d patterns", comment: "Grouped tools: number of patterns searched")
        case .shell: format = NSLocalizedString("browser.agentChat.toolGroup.shell", value: count == 1 ? "ran %d shell command" : "ran %d shell commands", comment: "Grouped tools: number of shell commands run")
        case .fetch: format = NSLocalizedString("browser.agentChat.toolGroup.fetch", value: count == 1 ? "fetched %d page" : "fetched %d pages", comment: "Grouped tools: number of pages fetched")
        case .web: format = NSLocalizedString("browser.agentChat.toolGroup.web", value: count == 1 ? "searched the web %d time" : "searched the web %d times", comment: "Grouped tools: number of web searches")
        case .sleep: format = NSLocalizedString("browser.agentChat.toolGroup.sleep", value: count == 1 ? "paused %d time" : "paused %d times", comment: "Grouped pauses completed; number of pauses")
        case .imageGeneration: format = NSLocalizedString("browser.agentChat.toolGroup.imageGeneration", value: count == 1 ? "generated %d image" : "generated %d images", comment: "Grouped image generation completed; number of images")
        case .browserRead: format = NSLocalizedString("browser.agentChat.toolGroup.browserRead", value: count == 1 ? "read %d page" : "read %d pages", comment: "Grouped browser tools completed; number of operations")
        case .browserScreenshot: format = NSLocalizedString("browser.agentChat.toolGroup.browserScreenshot", value: count == 1 ? "captured %d screenshot" : "captured %d screenshots", comment: "Grouped tools completed: page screenshots captured; part of a comma-separated summary")
        case .screenshotsSaved: format = NSLocalizedString("browser.agentChat.toolGroup.screenshotsSaved", value: count == 1 ? "saved %d screenshot" : "saved %d screenshots", comment: "Grouped screenshot saves completed; number of screenshots")
        case .bookmarksExported: format = NSLocalizedString("browser.agentChat.toolGroup.bookmarksExported", value: count == 1 ? "exported bookmarks %d time" : "exported bookmarks %d times", comment: "Grouped bookmark exports completed; number of exports")
        case .chatMounted: format = NSLocalizedString("browser.agentChat.toolGroup.chatMounted", value: count == 1 ? "mounted to a tab %d time" : "mounted to a tab %d times", comment: "Grouped chat mounts completed; number of mounts")
        case .chatUnmounted: format = NSLocalizedString("browser.agentChat.toolGroup.chatUnmounted", value: count == 1 ? "unmounted from a tab %d time" : "unmounted from a tab %d times", comment: "Grouped chat unmounts completed; number of unmounts")
        case .recordingStarted: format = NSLocalizedString("browser.agentChat.toolGroup.recordingStarted", value: count == 1 ? "started %d recording" : "started %d recordings", comment: "Grouped tab recordings started; number of recordings")
        case .recordingsSaved: format = NSLocalizedString("browser.agentChat.toolGroup.recordingsSaved", value: count == 1 ? "saved %d recording" : "saved %d recordings", comment: "Grouped tab recording saves completed; number of recordings")
        case .browserClick: format = NSLocalizedString("browser.agentChat.toolGroup.browserClick", value: count == 1 ? "clicked %d element" : "clicked %d elements", comment: "Grouped browser tools completed; number of operations")
        case .browserDrag: format = NSLocalizedString("browser.agentChat.toolGroup.browserDrag", value: count == 1 ? "dragged %d element" : "dragged %d elements", comment: "Grouped tools completed: elements dragged with the mouse on a web page; part of a comma-separated summary")
        case .browserType: format = NSLocalizedString("browser.agentChat.toolGroup.browserType", value: count == 1 ? "entered text %d time" : "entered text %d times", comment: "Grouped browser tools completed; number of operations")
        case .browserKey: format = NSLocalizedString("browser.agentChat.toolGroup.browserKey", value: count == 1 ? "pressed %d key" : "pressed %d keys", comment: "Grouped tools completed: keyboard keys pressed on a page; part of a comma-separated summary")
        case .browserOption: format = NSLocalizedString("browser.agentChat.toolGroup.browserOption", value: count == 1 ? "chose %d option" : "chose %d options", comment: "Grouped tools completed: options chosen in a web page's dropdown menus; part of a comma-separated summary")
        case .browserSelectText: format = NSLocalizedString("browser.agentChat.toolGroup.browserSelectText", value: count == 1 ? "selected text %d time" : "selected text %d times", comment: "Grouped tools completed: text selected on a web page; number of times; part of a comma-separated summary")
        case .browserHover: format = NSLocalizedString("browser.agentChat.toolGroup.browserHover", value: count == 1 ? "hovered over %d element" : "hovered over %d elements", comment: "Grouped tools completed: hovered over web page elements; number of elements")
        case .browserUpload: format = NSLocalizedString("browser.agentChat.toolGroup.browserUpload", value: count == 1 ? "uploaded files %d time" : "uploaded files %d times", comment: "Grouped browser tools completed; number of operations")
        case .browserOpen: format = NSLocalizedString("browser.agentChat.toolGroup.browserOpen", value: count == 1 ? "opened %d page" : "opened %d pages", comment: "Grouped browser tools completed; number of operations")
        case .browserReload: format = NSLocalizedString("browser.agentChat.toolGroup.browserReload", value: count == 1 ? "reloaded %d page" : "reloaded %d pages", comment: "Grouped tools completed: pages reloaded; part of a comma-separated summary")
        case .browserScroll: format = NSLocalizedString("browser.agentChat.toolGroup.browserScroll", value: count == 1 ? "scrolled %d page" : "scrolled %d pages", comment: "Grouped browser tools completed; number of operations")
        case .browserWait: format = NSLocalizedString("browser.agentChat.toolGroup.browserWait", value: count == 1 ? "waited for %d page" : "waited for %d pages", comment: "Grouped tools completed: waits for a page to load or change; part of a comma-separated summary")
        case .browserDialog: format = NSLocalizedString("browser.agentChat.toolGroup.browserDialog", value: count == 1 ? "handled %d dialog" : "handled %d dialogs", comment: "Grouped tools completed: web page dialogs accepted or dismissed; part of a comma-separated summary")
        case .browserTabs: format = NSLocalizedString("browser.agentChat.toolGroup.browserTabs", value: count == 1 ? "listed tabs %d time" : "listed tabs %d times", comment: "Grouped tools completed: lists of the window's tabs; number of times; part of a comma-separated summary")
        case .browserHistory: format = NSLocalizedString("browser.agentChat.toolGroup.browserHistory", value: count == 1 ? "searched history %d time" : "searched history %d times", comment: "Grouped tools completed: searches of the browsing history; number of times; part of a comma-separated summary")
        case .browserDownloads: format = NSLocalizedString("browser.agentChat.toolGroup.browserDownloads", value: count == 1 ? "listed downloads %d time" : "listed downloads %d times", comment: "Grouped tools completed: lists of the window's downloads; number of times; part of a comma-separated summary")
        case .pagesSaved: format = NSLocalizedString("browser.agentChat.toolGroup.pagesSaved", value: count == 1 ? "saved %d page" : "saved %d pages", comment: "Grouped tools completed: web pages saved as PDF or MHTML files; number of pages; part of a comma-separated summary")
        case .browserScript: format = NSLocalizedString("browser.agentChat.toolGroup.browserScript", value: count == 1 ? "ran JavaScript %d time" : "ran JavaScript %d times", comment: "Grouped tools completed: JavaScript the agent ran in a web page; number of times; part of a comma-separated summary")
        case .browserLogs: format = NSLocalizedString("browser.agentChat.toolGroup.browserLogs", value: count == 1 ? "read page logs %d time" : "read page logs %d times", comment: "Grouped tools completed: the agent read a web page's console messages or network requests; number of times; part of a comma-separated summary")
        case .browserGroup: format = NSLocalizedString("browser.agentChat.toolGroup.browserGroup", value: count == 1 ? "organized tabs %d time" : "organized tabs %d times", comment: "Grouped tools completed: the agent grouped, renamed or ungrouped tab groups; number of times; part of a comma-separated summary")
        case .browserConnect: format = NSLocalizedString("browser.agentChat.toolGroup.browserConnect", value: count == 1 ? "connected to %d tab" : "connected to %d tabs", comment: "Grouped tools completed: the agent attached to tabs to work in them; part of a comma-separated summary")
        case .browserClose: format = NSLocalizedString("browser.agentChat.toolGroup.browserClose", value: count == 1 ? "closed %d tab" : "closed %d tabs", comment: "Grouped tools completed: tabs closed; part of a comma-separated summary")
        case .monitor: format = NSLocalizedString("browser.agentChat.toolGroup.monitor", value: count == 1 ? "started %d monitor" : "started %d monitors", comment: "Grouped tools completed: background monitors started; part of a comma-separated summary")
        case .stopTask: format = NSLocalizedString("browser.agentChat.toolGroup.stopTask", value: count == 1 ? "stopped %d background task" : "stopped %d background tasks", comment: "Grouped tools completed: background tasks stopped; part of a comma-separated summary")
        case .toolSearch: format = NSLocalizedString("browser.agentChat.toolGroup.toolSearch", value: count == 1 ? "looked up tools %d time" : "looked up tools %d times", comment: "Grouped tools completed: the agent looked up which tools it can use; number of times; part of a comma-separated summary")
        case .skill: format = NSLocalizedString("browser.agentChat.toolGroup.skill", value: count == 1 ? "used %d skill" : "used %d skills", comment: "Grouped tools completed: Claude Code skills used; part of a comma-separated summary")
        case .message: format = NSLocalizedString("browser.agentChat.toolGroup.message", value: count == 1 ? "sent %d message" : "sent %d messages", comment: "Grouped tools completed: messages sent to other agent sessions; part of a comma-separated summary")
        case .agents: format = NSLocalizedString("browser.agentChat.toolGroup.agents", value: count == 1 ? "listed agents %d time" : "listed agents %d times", comment: "Grouped tools completed: lists of other agent sessions; number of times; part of a comma-separated summary")
        case .spawnAgent: format = NSLocalizedString("browser.agentChat.toolGroup.spawnAgent", value: count == 1 ? "spawned %d agent" : "spawned %d agents", comment: "Grouped chat tools completed; number of agents")
        case .readAgent: format = NSLocalizedString("browser.agentChat.toolGroup.readAgent", value: count == 1 ? "read agents %d time" : "read agents %d times", comment: "Grouped chat tools completed; number of reads")
        case .slackRead: format = NSLocalizedString("browser.agentChat.toolGroup.slackRead", value: count == 1 ? "read Slack %d time" : "read Slack %d times", comment: "Grouped Slack actions completed; %d is the count")
        case .slackSearch: format = NSLocalizedString("browser.agentChat.toolGroup.slackSearch", value: count == 1 ? "searched Slack %d time" : "searched Slack %d times", comment: "Grouped Slack actions completed; %d is the count")
        case .slackSend: format = NSLocalizedString("browser.agentChat.toolGroup.slackSend", value: count == 1 ? "sent %d Slack message" : "sent %d Slack messages", comment: "Grouped Slack actions completed; %d is the count")
        case .slackChange: format = NSLocalizedString("browser.agentChat.toolGroup.slackChange", value: count == 1 ? "used Slack %d time" : "used Slack %d times", comment: "Grouped Slack actions completed; %d is the count")
        case .mailList: format = NSLocalizedString("browser.agentChat.toolGroup.mailList", value: count == 1 ? "listed mail %d time" : "listed mail %d times", comment: "Grouped mail listings completed")
        case .mailSearch: format = NSLocalizedString("browser.agentChat.toolGroup.mailSearch", value: count == 1 ? "searched mail %d time" : "searched mail %d times", comment: "Grouped mail searches completed")
        case .mailRead: format = NSLocalizedString("browser.agentChat.toolGroup.mailRead", value: count == 1 ? "read %d email" : "read %d emails", comment: "Grouped email reads completed")
        case .mailDraft: format = NSLocalizedString("browser.agentChat.toolGroup.mailDraft", value: count == 1 ? "wrote %d draft" : "wrote %d drafts", comment: "Grouped draft writes completed")
        case .mailSend: format = NSLocalizedString("browser.agentChat.toolGroup.mailSend", value: count == 1 ? "sent %d email" : "sent %d emails", comment: "Grouped mail sends completed")
        case .mailChange: format = NSLocalizedString("browser.agentChat.toolGroup.mailChange", value: count == 1 ? "updated emails %d time" : "updated emails %d times", comment: "Grouped mail updates completed")
        case .stopAgent: format = NSLocalizedString("browser.agentChat.toolGroup.stopAgent", value: count == 1 ? "stopped %d agent" : "stopped %d agents", comment: "Grouped chat tools completed; number of agents")
        case .closeAgent: format = NSLocalizedString("browser.agentChat.toolGroup.closeAgent", value: count == 1 ? "closed %d agent" : "closed %d agents", comment: "Grouped chat tools completed; number of agents")
        case .code: format = NSLocalizedString("browser.agentChat.toolGroup.code", value: count == 1 ? "looked up code %d time" : "looked up code %d times", comment: "Grouped tools completed: code lookups such as definitions or references; number of times; part of a comma-separated summary")
        case .scheduleTask: format = NSLocalizedString("browser.agentChat.toolGroup.scheduleTask", value: count == 1 ? "scheduled %d task" : "scheduled %d tasks", comment: "Grouped tools completed: recurring tasks scheduled; part of a comma-separated summary")
        case .cancelScheduledTask: format = NSLocalizedString("browser.agentChat.toolGroup.cancelScheduledTask", value: count == 1 ? "canceled %d scheduled task" : "canceled %d scheduled tasks", comment: "Grouped tools completed: scheduled tasks canceled; part of a comma-separated summary")
        case .scheduledTasks: format = NSLocalizedString("browser.agentChat.toolGroup.scheduledTasks", value: count == 1 ? "listed scheduled tasks %d time" : "listed scheduled tasks %d times", comment: "Grouped tools completed: lists of scheduled tasks; number of times; part of a comma-separated summary")
        case .wakeup: format = NSLocalizedString("browser.agentChat.toolGroup.wakeup", value: count == 1 ? "scheduled %d wakeup" : "scheduled %d wakeups", comment: "Grouped tools completed: times for the agent to resume on its own scheduled; part of a comma-separated summary")
        case .planMode: format = NSLocalizedString("browser.agentChat.toolGroup.planMode", value: count == 1 ? "entered plan mode %d time" : "entered plan mode %d times", comment: "Grouped tools completed: switches to Claude Code's Plan permission mode; number of times; part of a comma-separated summary")
        case .notification: format = NSLocalizedString("browser.agentChat.toolGroup.notification", value: count == 1 ? "sent %d notification" : "sent %d notifications", comment: "Grouped tools completed: notifications sent to the user; part of a comma-separated summary")
        case .mcpResources: format = NSLocalizedString("browser.agentChat.toolGroup.mcpResources", value: count == 1 ? "listed MCP resources %d time" : "listed MCP resources %d times", comment: "Grouped tools completed: lists of MCP server resources; number of times; part of a comma-separated summary")
        case .mcpResource: format = NSLocalizedString("browser.agentChat.toolGroup.mcpResource", value: count == 1 ? "read %d MCP resource" : "read %d MCP resources", comment: "Grouped tools completed: MCP server resources read; part of a comma-separated summary")
        case let .tool(name):
            format = NSLocalizedString("browser.agentChat.toolGroup.tool", value: count == 1 ? "used %2$@ %1$d time" : "used %2$@ %1$d times", comment: "Grouped tools completed: %1$d is how many times; %2$@ is the tool's own name, shown as is; part of a comma-separated summary")
            return String.localizedStringWithFormat(format, count, name)
        }
        return String.localizedStringWithFormat(format, count)
    }
    static var other: String { NSLocalizedString("browser.agentChat.other", value: "Other", comment: "Question answer: custom text option") }
    static var submit: String { NSLocalizedString("browser.agentChat.submit", value: "Submit", comment: "Submit answers to Claude's questions") }
    static var skip: String { NSLocalizedString("browser.agentChat.skip", value: "Skip", comment: "Decline to answer Claude's questions") }
    static var answered: String { NSLocalizedString("browser.agentChat.answered", value: "Answered", comment: "Questions have been answered") }
    static var planTitle: String { NSLocalizedString("browser.agentChat.planTitle", value: "Claude's plan", comment: "Title above the plan awaiting approval") }
    static var approve: String { NSLocalizedString("browser.agentChat.approve", value: "Approve", comment: "Approve Claude's plan") }
    static var keepPlanning: String { NSLocalizedString("browser.agentChat.keepPlanning", value: "Keep planning", comment: "Ask Claude to revise the plan") }
    static var planFeedback: String { NSLocalizedString("browser.agentChat.planFeedback", value: "Feedback for Claude (optional)", comment: "Optional feedback when declining a plan") }
    static var planApproved: String { NSLocalizedString("browser.agentChat.planApproved", value: "Plan approved", comment: "Plan approval result") }
    static var keptPlanning: String { NSLocalizedString("browser.agentChat.keptPlanning", value: "Kept planning", comment: "Plan was declined so Claude can keep planning") }
    static var toolCollapse: String { NSLocalizedString("browser.agentChat.tool.collapse", value: "(click to collapse)", comment: "Tool output action to return to the preview") }
    static var toolBackground: String { NSLocalizedString("browser.agentChat.tool.background", value: "Running in the background", comment: "Tool output while a background task is running") }
    static var runInBackground: String { NSLocalizedString("browser.agentChat.tool.runInBackground", value: "Run in background", comment: "Button on a running shell command in an agent chat; moves the command to the background so the agent can continue") }
    private enum TaskNotificationArguments { case one, number, numberText }
    private static let taskNotificationPatterns: [(NSRegularExpression, String, TaskNotificationArguments)] = [
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" completed\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.completed", value: "Background command “%@” completed", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" completed \(exit code (-?\d+)\)\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.completedExit", value: "Background command “%1$@” completed (exit code %2$d)", comment: "Claude Code background task notification: %1$@ is the task's description; %2$d is its exit code"), .number),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" completed \(exit code (-?\d+): (.+)\)\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.completedExitNote", value: "Background command “%1$@” completed (exit code %2$d: %3$@)", comment: "Claude Code background task notification: %1$@ is the task's description; %2$d is its exit code; %3$@ is untranslated error text from Claude Code"), .numberText),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" failed\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.failed", value: "Background command “%@” failed", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" failed with exit code (-?\d+)\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.failedExit", value: "Background command “%1$@” failed with exit code %2$d", comment: "Claude Code background task notification: %1$@ is the task's description; %2$d is its exit code"), .number),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" was stopped\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.stopped", value: "Background command “%@” was stopped", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" was stopped because the system is running low on memory\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.stoppedMemory", value: "Background command “%@” was stopped because the system is running low on memory", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\ABackground command "(.+)" was stopped after reaching its background time limit\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.shell.stoppedTimeLimit", value: "Background command “%@” was stopped after reaching its background time limit", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" stream ended\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.streamEnded", value: "Monitor “%@” stream ended", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" ended without producing output\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.noOutput", value: "Monitor “%@” ended without producing output", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" ended without producing output \(exit (-?\d+)\)\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.noOutputExit", value: "Monitor “%1$@” ended without producing output (exit %2$d)", comment: "Claude Code background task notification: %1$@ is the task's description; %2$d is its exit code"), .number),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" script failed\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.scriptFailed", value: "Monitor “%@” script failed", comment: "Claude Code background task notification: %@ is the task's description"), .one),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" script failed \(exit (-?\d+)\)\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.scriptFailedExit", value: "Monitor “%1$@” script failed (exit %2$d)", comment: "Claude Code background task notification: %1$@ is the task's description; %2$d is its exit code"), .number),
        (try! NSRegularExpression(pattern: #"\AMonitor "(.+)" stopped\z"#, options: .dotMatchesLineSeparators),
         NSLocalizedString("browser.agentChat.taskNotification.monitor.stopped", value: "Monitor “%@” stopped", comment: "Claude Code background task notification: %@ is the task's description"), .one),
    ]

    /// An unrecognized summary shows only its first line.
    static func taskNotification(_ summary: String) -> String {
        localizedTaskNotification(summary) ?? summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? summary
    }

    /// The localized form of a summary in one of the CLI's formats, or nil.
    static func localizedTaskNotification(_ summary: String) -> String? {
        let range = NSRange(summary.startIndex..., in: summary)
        for (pattern, format, arguments) in taskNotificationPatterns {
            guard let match = pattern.firstMatch(in: summary, range: range),
                  let descriptionRange = Range(match.range(at: 1), in: summary) else { continue }
            let description = String(summary[descriptionRange])
            func capture(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: summary) else { return nil }
                return String(summary[range])
            }
            switch arguments {
            case .one:
                return String.localizedStringWithFormat(format, description)
            case .number:
                guard let raw = capture(2), let number = Int32(raw) else { return nil }
                return String.localizedStringWithFormat(format, description, number)
            case .numberText:
                guard let raw = capture(2), let number = Int32(raw), let detail = capture(3) else { return nil }
                return String.localizedStringWithFormat(format, description, number, detail)
            }
        }
        return nil
    }

    static func backgroundCount(_ tasks: [AgentBackgroundTask]) -> String {
        AgentBackgroundTask.Kind.allCases.compactMap { kind -> String? in
            let count = tasks.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            let format: String
            switch kind {
            case .shell: format = NSLocalizedString("browser.agentChat.background.shells", value: count == 1 ? "%d shell" : "%d shells", comment: "Running background shell count")
            case .monitor: format = NSLocalizedString("browser.agentChat.background.monitors", value: count == 1 ? "%d monitor" : "%d monitors", comment: "Running background monitor count")
            case .task: format = NSLocalizedString("browser.agentChat.background.tasks", value: count == 1 ? "%d task" : "%d tasks", comment: "Running background task count")
            }
            return String.localizedStringWithFormat(format, count)
        }.joined(separator: " · ")
    }
    static func scheduleCount(_ count: Int) -> String {
        let format = NSLocalizedString("browser.agentChat.background.schedules", value: count == 1 ? "%d schedule" : "%d schedules",
                                       comment: "Number of scheduled prompts for this chat")
        return String.localizedStringWithFormat(format, count)
    }
    static var cancelSchedule: String {
        NSLocalizedString("browser.agentChat.background.cancelSchedule", value: "Cancel", comment: "Button or menu item that cancels a scheduled prompt")
    }
    static var settingFailed: String { NSLocalizedString("browser.agentChat.settingFailed", value: "Couldn't change this chat setting.", comment: "Fallback error notice when the CLI rejects a session setting without a message") }
    static func toolWrote(_ count: Int) -> String { NSLocalizedString("browser.agentChat.tool.wrote", value: count == 1 ? "Wrote %1$d line to %2$@" : "Wrote %1$d lines to %2$@", comment: "Tool summary: %1$d is the number of lines; %2$@ is the file path") }
    static func toolUpdated(additions: Int, removals: Int) -> String { NSLocalizedString("browser.agentChat.tool.updated", value: "Updated %1$@ with %2$d \(additions == 1 ? "addition" : "additions") and %3$d \(removals == 1 ? "removal" : "removals")", comment: "Tool summary: %1$@ is the file path; %2$d additions; %3$d removals") }
    static func toolRead(_ count: Int) -> String { NSLocalizedString("browser.agentChat.tool.read", value: count == 1 ? "Read %d line" : "Read %d lines", comment: "Tool summary: %d is the number of lines read") }
    static func toolFoundFiles(_ count: Int) -> String { NSLocalizedString("browser.agentChat.tool.foundFiles", value: count == 1 ? "Found %d file" : "Found %d files", comment: "Tool summary: %d is the number of matching files") }
    static func toolFoundLines(_ count: Int) -> String { NSLocalizedString("browser.agentChat.tool.foundLines", value: count == 1 ? "Found %d line" : "Found %d lines", comment: "Tool summary: %d is the number of matching lines") }
    static var toolNoOutput: String { NSLocalizedString("browser.agentChat.tool.noOutput", value: "(No output)", comment: "Tool completed without any output") }
    static var shellExitCode: String { NSLocalizedString("browser.agentChat.shell.exitCode", value: "Exit code %d", comment: "Shell command output - %d is the command's nonzero exit code") }
    static var shellTruncated: String { NSLocalizedString("browser.agentChat.shell.truncated", value: "… output truncated …", comment: "Shell command output - output was omitted between the beginning and end") }
    static var toolMore: String { NSLocalizedString("browser.agentChat.tool.more", value: "… +%d lines (click to expand)", comment: "Tool output: %d is the number of hidden lines; clicking toggles the full output") }
    static var image: String { NSLocalizedString("browser.agentChat.image", value: "Image", comment: "Agent chat - image") }
    static var copyMessage: String { NSLocalizedString("browser.agentChat.copyMessage", value: "Copy message", comment: "Agent chat - Copy button beside the user's own message, accessibility label and tooltip") }
    static func copiedCharacters(_ count: Int) -> String {
        String(format: NSLocalizedString("browser.agentChat.copiedCharacters", value: "Copied %d characters", comment: "Agent chat - Toast after text selected in the transcript is copied to the clipboard; %d is the number of characters copied"), count)
    }
    static var unavailable: String { NSLocalizedString("browser.agentChat.unavailable", value: "This chat can't be restored.", comment: "Agent chat - Shown for a chat tab whose saved transcript is missing") }
    static func workingWord(_ index: Int) -> String {
        let words = ["Lollygagging", "Pondering", "Noodling", "Mulling", "Tinkering", "Percolating", "Ruminating", "Brewing", "Musing", "Puttering", "Cogitating", "Simmering"]
        let word = words[index % words.count]
        return NSLocalizedString("browser.agentChat.working." + word, value: word + "…", comment: "Playful activity word while an agent works")
    }
    // The working row formats its elapsed time on every streamed update, and building a formatter each time cost
    // more than the rest of the row.
    private static let secondsFormatter = elapsedFormatter([.second])
    private static let minutesFormatter = elapsedFormatter([.minute, .second])
    private static func elapsedFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = units
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        (seconds >= 60 ? minutesFormatter : secondsFormatter).string(from: max(0, seconds)) ?? "0 s"
    }
    static func workingProgress(elapsed seconds: TimeInterval, tokens: Int?) -> String {
        if let tokens {
            return String(format: NSLocalizedString("browser.agentChat.workingProgressTokens", value: "(%1$@ · ↓ %2$@ tokens)", comment: "Working progress: elapsed duration and estimated output tokens"), elapsed(seconds), tokens.formatted())
        }
        return String(format: NSLocalizedString("browser.agentChat.workingProgress", value: "(%@)", comment: "Working progress: elapsed duration"), elapsed(seconds))
    }
    static var waiting: String { NSLocalizedString("browser.agentChat.waiting", value: "Waiting for permission", comment: "Agent chat - waiting") }
    static func waiting(for items: [AgentChatItem]) -> String {
        let tools = items.compactMap { item -> String? in
            if case let .permissionRequest(request) = item.kind, request.status == .pending { return request.toolName }
            return nil
        }
        if tools.contains("AskUserQuestion") {
            return NSLocalizedString("browser.agentChat.waitingForAnswer", value: "Waiting for your answer", comment: "Agent header - A question awaits the user's answer")
        }
        if tools.contains("ExitPlanMode") {
            return NSLocalizedString("browser.agentChat.waitingForPlan", value: "Waiting for plan approval", comment: "Agent header - A plan awaits the user's approval")
        }
        return waiting
    }
    static var permission: String { NSLocalizedString("browser.agentChat.permission", value: "Drifter wants to use %@", comment: "Agent chat - permission; %@ is the tool name") }
    static var allow: String { NSLocalizedString("browser.agentChat.allow", value: "Allow", comment: "Agent chat - allow") }
    static var deny: String { NSLocalizedString("browser.agentChat.deny", value: "Deny", comment: "Agent chat - deny") }
    static var allowed: String { NSLocalizedString("browser.agentChat.allowed", value: "Allowed", comment: "Agent chat - allowed") }
    static var denied: String { NSLocalizedString("browser.agentChat.denied", value: "Denied", comment: "Agent chat - denied") }
    static var stopped: String { NSLocalizedString("browser.agentChat.stopped", value: "Stopped", comment: "Agent chat - stopped") }
    static var turnFinished: String { NSLocalizedString("browser.agentChat.turnFinished", value: "Duration: %1$@ · finished %2$@", comment: "Turn divider: %1$@ is the elapsed duration; %2$@ is the localized finish date and time") }
    static var reply: String { NSLocalizedString("browser.agentChat.reply", value: "Reply to Drifter", comment: "Agent chat - reply") }
    static var send: String { NSLocalizedString("browser.agentChat.send", value: "Send", comment: "Agent chat - send") }
    static var stop: String { NSLocalizedString("browser.agentChat.stop", value: "Stop", comment: "Agent chat - stop") }
}
