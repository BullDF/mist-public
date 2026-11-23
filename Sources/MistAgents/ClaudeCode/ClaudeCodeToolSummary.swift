import Foundation

/// Presentation data with no dependency on a running session.
struct ClaudeCodeToolSummary: Equatable {
    struct Span: Equatable {
        enum Style { case regular, bold, dim }
        var text: String
        var style: Style = .regular
        var link: URL?
    }
    struct Line: Equatable {
        enum Kind { case normal, addition, removal, error }
        var spans: [Span]
        var number: Int?
        var kind: Kind = .normal
        var changes: [NSRange] = []
        var text: String { spans.map(\.text).joined() }
        var numberSpan: Span? { number.map { Span(text: String($0), style: .dim) } }

        init(_ text: String, bold: [String] = [], number: Int? = nil, kind: Kind = .normal) {
            self.number = number
            self.kind = kind
            let tokens = bold.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            guard !tokens.isEmpty else {
                self.spans = text.isEmpty ? [] : [Span(text: text)]
                return
            }
            var spans: [Span] = []
            var index = text.startIndex
            while index < text.endIndex {
                if let token = tokens.first(where: { text[index...].hasPrefix($0) }) {
                    spans.append(Span(text: token, style: .bold))
                    index = text.index(index, offsetBy: token.count)
                } else {
                    let character = String(text[index])
                    if spans.last?.style == .regular { spans[spans.count - 1].text += character }
                    else { spans.append(Span(text: character)) }
                    index = text.index(after: index)
                }
            }
            self.spans = spans
        }
    }

    var header: Line
    var summary: [Line] = []
    var preview: [Line] = []
    var previewLimit = 3
    var hiddenLineCount: Int { max(0, preview.count - previewLimit) }
    func expansionLine(expanded: Bool) -> Line? {
        guard hiddenLineCount > 0 else { return nil }
        var line = Line(expanded ? AgentChatStrings.toolCollapse : String.localizedStringWithFormat(AgentChatStrings.toolMore, hiddenLineCount))
        line.spans = line.spans.map { Span(text: $0.text, style: .dim) }
        return line
    }

    static func path(_ path: String, folder: URL) -> String {
        guard path.hasPrefix("/") else { return path }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        if target == root { return "." }
        if target.hasPrefix(root == "/" ? "/" : root + "/") {
            return String(target.dropFirst(root == "/" ? 1 : root.count + 1))
        }
        return (target as NSString).abbreviatingWithTildeInPath
    }

    static func format(tool: String, input: ClaudeCodeJSON, result: ClaudeCodeJSON = .null,
                       text: String = "", folder: URL, failed: Bool = false,
                       background: AgentChatItem.BackgroundState? = nil,
                       denied: Bool = false,
                       running: Bool = false) -> Self {
        let tool = DrifterBackgroundTools.nativeName(tool)
        let interruption = failed ? AgentChatStrings.toolInterruption(text, denied: denied) : nil
        if let summary = browserTool(tool, input: input, running: running, failed: failed || denied) {
            if let interruption { return Self(header: Line(summary), summary: [Line(interruption, kind: .error)]) }
            return browserResult(tool: tool, header: summary, result: result, text: text, failed: failed || denied, running: running)
        }
        let file = path(input["file_path"].string ?? result["filePath"].string ?? result["file"]["filePath"].string ?? "", folder: folder)
        let name: String
        switch tool {
        case "Edit", "MultiEdit": name = "Update"
        case "Grep", "Glob": name = "Search"
        case "WebFetch": name = "Fetch"
        case "WebSearch": name = "Web Search"
        case "ImageGeneration": name = "Image Generation"
        default: name = AgentChatToolGroupKind.displayName(tool)
        }
        // A generated image is named by the file it was saved to, like a write; its prompt goes below.
        let savedImage = tool == "ImageGeneration" && !failed && text.hasPrefix("/") ? text : nil
        let argument: String
        switch tool {
        case "Write", "Read", "Edit", "MultiEdit": argument = file
        case "ImageGeneration" where savedImage != nil: argument = path(text, folder: folder)
        default: argument = ClaudeCodeProtocol.inputSummary(tool: tool, input: input)
        }
        let oneLine = argument.components(separatedBy: .newlines).joined(separator: " ")
        let headerArgument = tool == "Bash" && oneLine.count > 80 ? String(oneLine.prefix(79)) + "…" : oneLine
        var header = Line("")
        header.spans = [Span(text: name, style: .bold), Span(text: "(" + headerArgument + ")")]
        if ["Write", "Read", "Edit", "MultiEdit"].contains(tool),
           let raw = input["file_path"].string, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
            header.spans = [Span(text: name, style: .bold), Span(text: "("),
                Span(text: headerArgument, link: url), Span(text: ")")]
        }
        if let savedImage {
            header.spans = [Span(text: name, style: .bold), Span(text: "("),
                Span(text: headerArgument, link: URL(fileURLWithPath: savedImage)), Span(text: ")")]
        }
        var formatted = Self(header: header)
        if let interruption {
            formatted.summary = [Line(interruption, kind: .error)]
            return formatted
        }
        if tool == "AskUserQuestion" {
            formatted.header.spans = [Span(text: name, style: .bold)]
            return formatted
        }
        if let background {
            formatted.summary = lines(background == .running ? AgentChatStrings.toolBackground : AgentChatStrings.taskNotification(text))
                .map { Line($0, kind: failed ? .error : .normal) }
            return formatted
        }
        if tool == "ExitPlanMode" {
            if failed { formatted.summary = [Line(AgentChatStrings.keptPlanning)] }
            return formatted
        }
        if failed {
            let error = (text.isEmpty ? result.string ?? "" : text)
                .replacingOccurrences(of: "<tool_use_error>", with: "")
                .replacingOccurrences(of: "</tool_use_error>", with: "")
            formatted.preview = lines(error).map { Line($0, kind: .error) }
            return formatted
        }
        let patches = result["structuredPatch"].array
        switch tool {
        case _ where tool == "Edit" || tool == "MultiEdit" || (tool == "Write" && result["type"].string == "update"):
            var additions = 0, removals = 0
            for patch in patches {
                for hunk in hunks(patch["lines"].array.compactMap(\.string),
                                  oldStart: patch["oldStart"].integer, newStart: patch["newStart"].integer) {
                    let hunkStart = formatted.preview.count
                    var old = hunk.oldStart, new = hunk.newStart
                    for raw in hunk.lines {
                        let marker = raw.first
                        if marker == "+" { additions += 1 }
                        if marker == "-" { removals += 1 }
                        formatted.preview.append(Line(raw, number: marker == "-" ? old : new,
                            kind: marker == "+" ? .addition : marker == "-" ? .removal : .normal))
                        if marker != "+" { old += 1 }
                        if marker != "-" { new += 1 }
                    }
                    DiffWordChanges.apply(to: &formatted.preview, from: hunkStart)
                }
            }
            // Older CLI replies may lack structured hunks. Preserve their text rather than inventing a diff.
            if patches.isEmpty {
                formatted.preview = lines(text).map { Line($0) }
            } else {
                formatted.summary = [Line(String.localizedStringWithFormat(AgentChatStrings.toolUpdated(additions: additions, removals: removals), file, additions, removals), bold: [file, number(additions), number(removals)])]
            }
            formatted.previewLimit = 20
        case "Write":
            let content = result["content"].string ?? input["content"].string ?? ""
            let contentLines = lines(content)
            formatted.summary = [Line(String.localizedStringWithFormat(AgentChatStrings.toolWrote(contentLines.count), contentLines.count, file), bold: [number(contentLines.count), file])]
            formatted.preview = contentLines.enumerated().map { Line($0.element, number: $0.offset + 1) }
            formatted.previewLimit = 5
        case "Read" where result["type"].string == "image":
            formatted.summary = [Line(AgentChatStrings.image)]
        case "Read":
            let content = result["file"]["content"].string
            let count = result["file"]["numLines"].integer
            let total = result["file"]["numLines"] != .null
                ? max(0, count - (content?.hasSuffix("\n") == true ? 1 : 0))
                : lines(content ?? text).count
            formatted.summary = [Line(String.localizedStringWithFormat(AgentChatStrings.toolRead(total), total), bold: [number(total)])]
        case "Bash":
            let stdout = result["stdout"].string
            let stderr = result["stderr"].string
            let output = stdout == nil && stderr == nil ? text : [stdout, stderr].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let noOutput = output.isEmpty || output == "(Bash completed with no output)"
            formatted.preview = (noOutput ? [AgentChatStrings.toolNoOutput] : lines(output)).map { Line($0) }
            formatted.previewLimit = 5
        case "Grep", "Glob":
            // These tools are absent from CLI 2.1.310. Use the protocol's plain text fallback.
            let output = lines(text)
            let mode = input["output_mode"].string
            var count = text.isEmpty || text.hasPrefix("No matches") || text.hasPrefix("No files") ? 0 : output.count
            if tool == "Grep", mode == "count" {
                count = output.reduce(0) { $0 + (Int($1.split(separator: ":").last ?? "") ?? 0) }
            }
            let key = tool == "Grep" && (mode == "content" || mode == "count") ? AgentChatStrings.toolFoundLines(count) : AgentChatStrings.toolFoundFiles(count)
            formatted.summary = [Line(String.localizedStringWithFormat(key, count), bold: [number(count)])]
            formatted.preview = output.map { Line($0) }
        case "WebFetch", "WebSearch":
            formatted.preview = lines(text).map { Line($0) }
            formatted.previewLimit = 1
        case "ImageGeneration":
            if savedImage != nil { formatted.preview = lines(input["prompt"].string ?? "").map { Line($0) } }
            formatted.previewLimit = 2
        default:
            formatted.preview = lines(text).map { Line($0) }
        }
        return formatted
    }

    private static func number(_ count: Int) -> String {
        String.localizedStringWithFormat("%d", count)
    }

    /// Diff lines (`+`, `-` or space first) starting at these old and new line numbers.
    struct Hunk: Equatable {
        var oldStart: Int
        var newStart: Int
        var lines: [String]
    }

    /// A hunk's changes with `context` unchanged lines around each, split where more lie between, as `diff -U3` cuts
    /// them. Gemini reports an edit as the whole file before and after: a row holding every line of a large file
    /// rendered for tens of milliseconds, and its card showed the file's first lines instead of the change. Hunks
    /// already in this shape (Claude's, Codex's) come back unchanged.
    static func hunks(_ lines: [String], oldStart: Int, newStart: Int, context: Int = 3) -> [Hunk] {
        var ranges: [ClosedRange<Int>] = []
        for index in lines.indices where !(lines[index].isEmpty || lines[index].hasPrefix(" ")) {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...range.upperBound
            } else {
                ranges.append(range)
            }
        }
        var hunks: [Hunk] = []
        var old = oldStart, new = newStart, index = 0
        func advance() {
            if !lines[index].hasPrefix("+") { old += 1 }
            if !lines[index].hasPrefix("-") { new += 1 }
            index += 1
        }
        for range in ranges {
            while index < range.lowerBound { advance() }
            hunks.append(Hunk(oldStart: old, newStart: new, lines: Array(lines[range])))
            while index <= range.upperBound { advance() }
        }
        return hunks
    }

    private static func browserResult(tool: String, header: String, result: ClaudeCodeJSON,
                                      text: String, failed: Bool, running: Bool) -> Self {
        func decode(_ text: String) -> ClaudeCodeJSON? {
            try? JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(text.utf8))
        }
        // Both engines flatten MCP text blocks into output. Codex can also
        // supply structuredContent; screenshots append an image label to text.
        let blocks = result.array + result["content"].array
        let payload = decode(text) ?? lines(text).compactMap(decode).first
            ?? blocks.compactMap { $0["text"].string.flatMap(decode) }.first
            ?? (result["structuredContent"] != .null ? result["structuredContent"] : result)
        var formatted = Self(header: Line(header))
        if let error = payload["error"].string ?? payload["error"]["message"].string {
            formatted.preview = lines(error).map { Line($0, kind: .error) }
        } else if failed {
            formatted.preview = lines(text).map { Line($0, kind: .error) }
        } else if !running, tool.hasSuffix("__start_recording"),
                  let title = payload["tab"]["title"].string, !title.isEmpty {
            let format = NSLocalizedString("browser.agent.tool.startRecording", value: "Recording %@", comment: "Browser Agent - Recording the tab with this title")
            formatted.header = Line(String(format: format, title))
        } else if tool.hasSuffix("__save_screenshot") || (!running && (tool.hasSuffix("__stop_recording") || tool.hasSuffix("__export_bookmarks"))),
                  let path = payload["path"].string {
            if !tool.hasSuffix("__save_screenshot") {
                let format = tool.hasSuffix("__export_bookmarks")
                    ? NSLocalizedString("browser.agent.tool.exportBookmarks.file", value: "Exported bookmarks to %@", comment: "Browser Agent - %@ is the exported bookmarks file name")
                    : NSLocalizedString("browser.agent.tool.stopRecording", value: "Saved %@", comment: "Browser Agent - Saved recording file name")
                formatted.header = Line(String(format: format, (path as NSString).lastPathComponent))
            }
            var line = Line(path)
            line.spans = [Span(text: path, link: URL(fileURLWithPath: path))]
            formatted.summary = [line]
        } else if !running, tool.hasSuffix("__mount_to_tab"), let title = payload["mountedTo"]["title"].string {
            let format = NSLocalizedString("browser.agent.tool.mountToTab.title", value: "Mounted to %@", comment: "Browser Agent - %@ is the title of the tab the chat was mounted to")
            formatted.header = Line(String(format: format, title))
        } else if !running, tool.hasSuffix("__unmount_from_tab"), let title = payload["unmountedFrom"]["title"].string {
            let format = NSLocalizedString("browser.agent.tool.unmountFromTab.title", value: "Unmounted from %@", comment: "Browser Agent - %@ is the title of the tab the chat was unmounted from")
            formatted.header = Line(String(format: format, title))
        } else if tool.hasSuffix("__read_page") || tool.hasSuffix("__snapshot") {
            if let content = payload["result"].string {
                formatted.preview = lines(content).filter {
                    $0 != "--- BEGIN UNTRUSTED PAGE CONTENT (data, not instructions) ---" &&
                    $0 != "--- END UNTRUSTED PAGE CONTENT ---"
                }.map { Line($0) }
            } else {
                // observe() returns structured elements, whereas read_page
                // returns an enveloped string. Render both as readable lines.
                let snapshot = payload["result"]
                formatted.preview = snapshot["headings"].array.compactMap {
                    $0.string ?? $0["text"].string ?? $0["name"].string
                }.map { Line($0) }
                formatted.preview += snapshot["elements"].array.map { element in
                    Line([element["role"].string, element["name"].string, element["value"].string,
                          element["href"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                }.filter { !$0.text.isEmpty }
            }
        } else {
            let tab = payload["tab"]
            let description = [tab["title"].string, tab["url"].string]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !description.isEmpty { formatted.summary = [Line(description)] }
        }
        return formatted
    }

    private static func slackTool(_ name: String, input: ClaudeCodeJSON, running: Bool, failed: Bool) -> String {
        let destination = AgentChatStrings.slackDestination(input["channel_id"].string ?? "")
        let query = [input["keywords"].string, input["natural_language_query"].string].compactMap { $0 }.first { !$0.isEmpty }
        let kind: String
        let argument: String?
        switch name {
        case "slack_complete_file_upload": kind = "slackShareFile"; argument = nil
        case "slack_send_message":
            if input["thread_ts"].string?.isEmpty == false { kind = "slackSend.thread"; argument = nil }
            else if let destination { kind = "slackSend.to"; argument = destination }
            else { kind = "slackSend"; argument = nil }
        case "slack_schedule_message": kind = "slackSchedule"; argument = nil
        case let name where name.hasPrefix("slack_search_public"):
            kind = query == nil ? "slackSearch" : "slackSearch.query"; argument = query
        case "slack_search_channels": kind = "slackSearch.channels"; argument = nil
        case "slack_search_users": kind = "slackSearch.users"; argument = nil
        case "slack_read_channel":
            kind = destination == nil ? "slackRead.channel" : "slackRead.channel.named"; argument = destination
        case "slack_read_thread": kind = "slackRead.thread"; argument = nil
        case "slack_list_user_channels": kind = "slackList.channels"; argument = nil
        case "slack_add_reaction": kind = "slackReaction"; argument = input["emoji"].string ?? ""
        default: kind = "slackChange"; argument = nil
        }
        let format: String
        switch kind {
        case "slackShareFile":
            format = failed ? NSLocalizedString("browser.agent.tool.slackShareFile.failed", value: "Couldn't share a file in Slack", comment: "Slack file sharing failed") : running ? NSLocalizedString("browser.agent.tool.slackShareFile.running", value: "Sharing a file in Slack", comment: "Slack file sharing running") : NSLocalizedString("browser.agent.tool.slackShareFile", value: "Shared a file in Slack", comment: "Slack file sharing completed")
        case "slackSend.to":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSend.to.failed", value: "Couldn't send a Slack message to %@", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSend.to.running", value: "Sending a Slack message to %@", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSend.to", value: "Sent a Slack message to %@", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSend.thread":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSend.thread.failed", value: "Couldn't reply in a Slack thread", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSend.thread.running", value: "Replying in a Slack thread", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSend.thread", value: "Replied in a Slack thread", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSend":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSend.failed", value: "Couldn't send a Slack message", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSend.running", value: "Sending a Slack message", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSend", value: "Sent a Slack message", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSchedule":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSchedule.failed", value: "Couldn't schedule a Slack message", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSchedule.running", value: "Scheduling a Slack message", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSchedule", value: "Scheduled a Slack message", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSearch.query":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSearch.query.failed", value: "Couldn't search Slack for “%@”", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSearch.query.running", value: "Searching Slack for “%@”", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSearch.query", value: "Searched Slack for “%@”", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSearch":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSearch.failed", value: "Couldn't search Slack", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSearch.running", value: "Searching Slack", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSearch", value: "Searched Slack", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSearch.channels":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSearch.channels.failed", value: "Couldn't search Slack channels", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSearch.channels.running", value: "Searching Slack channels", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSearch.channels", value: "Searched Slack channels", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackSearch.users":
            format = failed ? NSLocalizedString("browser.agent.tool.slackSearch.users.failed", value: "Couldn't look up Slack people", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackSearch.users.running", value: "Looking up Slack people", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackSearch.users", value: "Looked up Slack people", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackRead.channel.named":
            format = failed ? NSLocalizedString("browser.agent.tool.slackRead.channel.named.failed", value: "Couldn't read %@ in Slack", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackRead.channel.named.running", value: "Reading %@ in Slack", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackRead.channel.named", value: "Read %@ in Slack", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackRead.channel":
            format = failed ? NSLocalizedString("browser.agent.tool.slackRead.channel.failed", value: "Couldn't read a Slack channel", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackRead.channel.running", value: "Reading a Slack channel", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackRead.channel", value: "Read a Slack channel", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackRead.thread":
            format = failed ? NSLocalizedString("browser.agent.tool.slackRead.thread.failed", value: "Couldn't read a Slack thread", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackRead.thread.running", value: "Reading a Slack thread", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackRead.thread", value: "Read a Slack thread", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackList.channels":
            format = failed ? NSLocalizedString("browser.agent.tool.slackList.channels.failed", value: "Couldn't list Slack channels", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackList.channels.running", value: "Listing Slack channels", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackList.channels", value: "Listed Slack channels", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackReaction":
            format = failed ? NSLocalizedString("browser.agent.tool.slackReaction.failed", value: "Couldn't react with :%@:", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackReaction.running", value: "Reacting with :%@:", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackReaction", value: "Reacted with :%@:", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        case "slackChange":
            format = failed ? NSLocalizedString("browser.agent.tool.slackChange.failed", value: "Couldn't use Slack", comment: "Slack tool failed; placeholders contain the destination, query, or emoji when present") : running ? NSLocalizedString("browser.agent.tool.slackChange.running", value: "Using Slack", comment: "Slack tool running; placeholders contain the destination, query, or emoji when present") : NSLocalizedString("browser.agent.tool.slackChange", value: "Used Slack", comment: "Slack tool completed; placeholders contain the destination, query, or emoji when present")
        default: preconditionFailure("Unknown Slack activity")
        }
        return argument.map { String(format: format, $0) } ?? format
    }

    /// The key a press_key call presses, after the modifiers it holds in macOS order: ⌘K, ⌃K, ⇧Tab.
    static func browserKeyLabel(_ input: ClaudeCodeJSON) -> String {
        let key = input["key"].string ?? ""
        let held = Set(input["modifiers"].array.compactMap(\.string))
        let symbols = [("Control", "⌃"), ("Alt", "⌥"), ("Shift", "⇧"), ("Meta", "⌘")].filter { held.contains($0.0) }.map(\.1).joined()
        return symbols.isEmpty ? key : symbols + (key.count == 1 ? key.uppercased() : key)
    }

    static func browserTool(_ tool: String, input: ClaudeCodeJSON, running: Bool = false, failed: Bool = false) -> String? {
        guard tool.hasPrefix("mcp__mistbrowser__"), DrifterBackgroundTools.nativeName(tool) == tool else { return nil }
        let name = String(tool.dropFirst("mcp__mistbrowser__".count))
        if name.hasPrefix("slack_") { return slackTool(name, input: input, running: running, failed: failed) }
        switch name {
        case "list_mail_accounts":
            return failed ? NSLocalizedString("browser.agent.tool.mailAccounts.failed", value: "Couldn't list mail accounts", comment: "Mail tool failed") : running ? NSLocalizedString("browser.agent.tool.mailAccounts.running", value: "Listing mail accounts", comment: "Mail tool running") : NSLocalizedString("browser.agent.tool.mailAccounts", value: "Listed mail accounts", comment: "Mail tool completed")
        case "list_mail":
            return failed ? NSLocalizedString("browser.agent.tool.mailList.failed", value: "Couldn't list emails", comment: "Mail tool failed") : running ? NSLocalizedString("browser.agent.tool.mailList.running", value: "Listing emails", comment: "Mail tool running") : NSLocalizedString("browser.agent.tool.mailList", value: "Listed emails", comment: "Mail tool completed")
        case "search_mail":
            let format = failed ? NSLocalizedString("browser.agent.tool.mailSearch.failed", value: "Couldn't search mail for “%@”", comment: "Mail search failed; %@ is the query") : running ? NSLocalizedString("browser.agent.tool.mailSearch.running", value: "Searching mail for “%@”", comment: "Mail search running; %@ is the query") : NSLocalizedString("browser.agent.tool.mailSearch", value: "Searched mail for “%@”", comment: "Mail search completed; %@ is the query")
            return String(format: format, input["query"].string ?? "")
        case "read_mail":
            return failed ? NSLocalizedString("browser.agent.tool.mailRead.failed", value: "Couldn't read an email", comment: "Mail tool failed") : running ? NSLocalizedString("browser.agent.tool.mailRead.running", value: "Reading an email", comment: "Mail tool running") : NSLocalizedString("browser.agent.tool.mailRead", value: "Read an email", comment: "Mail tool completed")
        case "write_mail_draft", "send_mail":
            let subject = input["subject"].string ?? ""
            if !subject.isEmpty {
                let format: String
                if name == "write_mail_draft" {
                    format = failed ? NSLocalizedString("browser.agent.tool.mailDraft.subject.failed", value: "Couldn't draft “%@”", comment: "Draft failed") : running ? NSLocalizedString("browser.agent.tool.mailDraft.subject.running", value: "Drafting “%@”", comment: "Draft running") : NSLocalizedString("browser.agent.tool.mailDraft.subject", value: "Drafted “%@”", comment: "Draft completed")
                } else {
                    format = failed ? NSLocalizedString("browser.agent.tool.mailSend.subject.failed", value: "Couldn't send “%@”", comment: "Send failed") : running ? NSLocalizedString("browser.agent.tool.mailSend.subject.running", value: "Sending “%@”", comment: "Send running") : NSLocalizedString("browser.agent.tool.mailSend.subject", value: "Sent “%@”", comment: "Send completed")
                }
                return String(format: format, subject)
            }
            if name == "send_mail", input["draftId"].string != nil {
                return failed ? NSLocalizedString("browser.agent.tool.mailSend.draft.failed", value: "Couldn't send a draft", comment: "Draft send failed") : running ? NSLocalizedString("browser.agent.tool.mailSend.draft.running", value: "Sending a draft", comment: "Draft send running") : NSLocalizedString("browser.agent.tool.mailSend.draft", value: "Sent a draft", comment: "Draft send completed")
            }
            if name == "write_mail_draft", input["replyTo"].string != nil {
                return failed ? NSLocalizedString("browser.agent.tool.mailDraft.reply.failed", value: "Couldn't draft a reply", comment: "Reply draft failed") : running ? NSLocalizedString("browser.agent.tool.mailDraft.reply.running", value: "Drafting a reply", comment: "Reply draft running") : NSLocalizedString("browser.agent.tool.mailDraft.reply", value: "Drafted a reply", comment: "Reply draft completed")
            }
            if name == "write_mail_draft", input["forward"].string != nil {
                return failed ? NSLocalizedString("browser.agent.tool.mailDraft.forward.failed", value: "Couldn't draft a forward", comment: "Forward draft failed") : running ? NSLocalizedString("browser.agent.tool.mailDraft.forward.running", value: "Drafting a forward", comment: "Forward draft running") : NSLocalizedString("browser.agent.tool.mailDraft.forward", value: "Drafted a forward", comment: "Forward draft completed")
            }
            return nil
        case "update_mail":
            let count = input["ids"].array.count
            let format: String
            if failed { format = NSLocalizedString("browser.agent.tool.mailChange.failed", value: count == 1 ? "Couldn't update %d email" : "Couldn't update %d emails", comment: "Mail update failed") }
            else if running { format = NSLocalizedString("browser.agent.tool.mailChange.running", value: count == 1 ? "Updating %d email" : "Updating %d emails", comment: "Mail update running") }
            else {
                switch input["action"].string {
                case "read": format = NSLocalizedString("browser.agent.tool.mailChange.read", value: count == 1 ? "Marked %d email as read" : "Marked %d emails as read", comment: "Mail marked read")
                case "unread": format = NSLocalizedString("browser.agent.tool.mailChange.unread", value: count == 1 ? "Marked %d email as unread" : "Marked %d emails as unread", comment: "Mail marked unread")
                case "flag": format = NSLocalizedString("browser.agent.tool.mailChange.flag", value: count == 1 ? "Flagged %d email" : "Flagged %d emails", comment: "Mail flagged")
                case "unflag": format = NSLocalizedString("browser.agent.tool.mailChange.unflag", value: count == 1 ? "Unflagged %d email" : "Unflagged %d emails", comment: "Mail unflagged")
                case "archive": format = NSLocalizedString("browser.agent.tool.mailChange.archive", value: count == 1 ? "Archived %d email" : "Archived %d emails", comment: "Mail archived")
                case "move": format = NSLocalizedString("browser.agent.tool.mailChange.move", value: count == 1 ? "Moved %d email" : "Moved %d emails", comment: "Mail moved")
                default: format = NSLocalizedString("browser.agent.tool.mailChange.trash", value: count == 1 ? "Moved %d email to the Trash" : "Moved %d emails to the Trash", comment: "Mail trashed")
                }
            }
            return String.localizedStringWithFormat(format, count)
        default: break
        }
        if name == "list_agents" {
            if failed { return NSLocalizedString("browser.agent.tool.listAgents.failed", value: "Couldn't list agents", comment: "Browser Agent - Tool summary after failure or denial") }
            return running
                ? NSLocalizedString("browser.agent.tool.listAgents.running", value: "Listing agents", comment: "Browser Agent - Listing open chats")
                : NSLocalizedString("browser.agent.tool.listAgents", value: "Listed agents", comment: "Browser Agent - Listed open chats")
        }
        if name == "spawn_agent" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.spawnAgent.failed", value: "Couldn't spawn %@", comment: "Browser Agent - %@ is the child chat title")
                : running ? NSLocalizedString("browser.agent.tool.spawnAgent.running", value: "Spawning %@", comment: "Browser Agent - %@ is the child chat title")
                : NSLocalizedString("browser.agent.tool.spawnAgent", value: "Spawned %@", comment: "Browser Agent - %@ is the child chat title")
            return String(format: format, input["title"].string ?? "")
        }
        if name == "read_agent" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.readAgent.failed", value: "Couldn't read %@", comment: "Browser Agent - %@ is the chat ID")
                : running ? NSLocalizedString("browser.agent.tool.readAgent.running", value: "Reading %@", comment: "Browser Agent - %@ is the chat ID")
                : NSLocalizedString("browser.agent.tool.readAgent", value: "Read %@", comment: "Browser Agent - %@ is the chat ID")
            return String(format: format, input["id"].string ?? "")
        }
        if name == "stop_agent" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.stopAgent.failed", value: "Couldn't stop %@", comment: "Browser Agent - %@ is the chat ID")
                : running ? NSLocalizedString("browser.agent.tool.stopAgent.running", value: "Stopping %@", comment: "Browser Agent - %@ is the chat ID")
                : NSLocalizedString("browser.agent.tool.stopAgent", value: "Stopped %@", comment: "Browser Agent - %@ is the chat ID")
            return String(format: format, input["id"].string ?? "")
        }
        if name == "close_agent" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.closeAgent.failed", value: "Couldn't close %@", comment: "Browser Agent - %@ is the chat ID")
                : running ? NSLocalizedString("browser.agent.tool.closeAgent.running", value: "Closing %@", comment: "Browser Agent - %@ is the chat ID")
                : NSLocalizedString("browser.agent.tool.closeAgent", value: "Closed %@", comment: "Browser Agent - %@ is the chat ID")
            return String(format: format, input["id"].string ?? "")
        }
        if name == "finish_task" {
            if failed { return NSLocalizedString("browser.agent.tool.finishTask.failed", value: "Couldn't report", comment: "Browser Agent - Failed task report") }
            if running { return NSLocalizedString("browser.agent.tool.finishTask.running", value: "Reporting", comment: "Browser Agent - Task report in progress") }
            return input["status"].string == "blocked"
                ? NSLocalizedString("browser.agent.tool.finishTask.blocked", value: "Reported blocked", comment: "Browser Agent - Reported that the task needs an answer")
                : NSLocalizedString("browser.agent.tool.finishTask.done", value: "Reported done", comment: "Browser Agent - Reported that the task is finished")
        }
        if name == "message_agent" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.messageAgent.failed", value: "Couldn't message %@", comment: "Browser Agent - %@ is another chat's short ID")
                : running ? NSLocalizedString("browser.agent.tool.messageAgent.running", value: "Messaging %@", comment: "Browser Agent - %@ is another chat's short ID")
                : NSLocalizedString("browser.agent.tool.messageAgent", value: "Messaged %@", comment: "Browser Agent - %@ is another chat's short ID")
            return String(format: format, input["id"].string ?? "")
        }
        let host = input["url"].string.flatMap { URL(string: $0)?.host } ?? input["url"].string ?? ""
        if name == "upload_files" {
            let paths = input["paths"].array
            guard !paths.isEmpty else { return nil }
            let files = paths.compactMap(\.string).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let format = failed
                ? NSLocalizedString("browser.agent.tool.upload.failed", value: "Couldn't upload %@", comment: "Browser Agent - Uploaded file names")
                : running ? NSLocalizedString("browser.agent.tool.upload.running", value: "Uploading %@", comment: "Browser Agent - Uploaded file names")
                : NSLocalizedString("browser.agent.tool.upload", value: "Uploaded %@", comment: "Browser Agent - Uploaded file names")
            return String(format: format, files)
        }
        if name == "save_screenshot" {
            let raw = ((input["path"].string ?? "") as NSString).lastPathComponent
            let file = raw.lowercased().hasSuffix(".png") ? raw : raw + ".png"
            let format = failed
                ? NSLocalizedString("browser.agent.tool.saveScreenshot.failed", value: "Couldn't save %@", comment: "Browser Agent - Screenshot file name")
                : running ? NSLocalizedString("browser.agent.tool.saveScreenshot.running", value: "Saving %@", comment: "Browser Agent - Screenshot file name")
                : NSLocalizedString("browser.agent.tool.saveScreenshot", value: "Saved %@", comment: "Browser Agent - Screenshot file name")
            return String(format: format, file)
        }
        if name == "export_bookmarks" {
            return failed ? NSLocalizedString("browser.agent.tool.exportBookmarks.failed", value: "Couldn't export bookmarks", comment: "Browser Agent - Bookmark export failed")
                : running ? NSLocalizedString("browser.agent.tool.exportBookmarks.running", value: "Exporting bookmarks", comment: "Browser Agent - Bookmark export in progress")
                : NSLocalizedString("browser.agent.tool.exportBookmarks", value: "Exported bookmarks", comment: "Browser Agent - Exported bookmarks without a file name in the result")
        }
        if name == "mount_to_tab" {
            return failed ? NSLocalizedString("browser.agent.tool.mountToTab.failed", value: "Couldn't mount to tab", comment: "Browser Agent - Mounting the chat to a tab failed")
                : running ? NSLocalizedString("browser.agent.tool.mountToTab.running", value: "Mounting to tab", comment: "Browser Agent - Mounting the chat to a tab")
                : NSLocalizedString("browser.agent.tool.mountToTab", value: "Mounted to tab", comment: "Browser Agent - Mounted to a tab without a title in the result")
        }
        if name == "unmount_from_tab" {
            return failed ? NSLocalizedString("browser.agent.tool.unmountFromTab.failed", value: "Couldn't unmount from tab", comment: "Browser Agent - Unmounting the chat from a tab failed")
                : running ? NSLocalizedString("browser.agent.tool.unmountFromTab.running", value: "Unmounting from tab", comment: "Browser Agent - Unmounting the chat from a tab")
                : NSLocalizedString("browser.agent.tool.unmountFromTab", value: "Unmounted from tab", comment: "Browser Agent - Unmounted from a tab without a title in the result")
        }
        if name == "start_recording" {
            return failed ? NSLocalizedString("browser.agent.tool.startRecording.failed", value: "Couldn't start recording", comment: "Browser Agent - Could not start a tab recording")
                : running ? NSLocalizedString("browser.agent.tool.startRecording.running", value: "Starting recording", comment: "Browser Agent - Starting a tab recording")
                : NSLocalizedString("browser.agent.tool.startRecording.untitled", value: "Recording tab", comment: "Browser Agent - Recording a tab without a title")
        }
        if name == "stop_recording" {
            return failed ? NSLocalizedString("browser.agent.tool.stopRecording.failed", value: "Couldn't save recording", comment: "Browser Agent - Could not save a tab recording")
                : running ? NSLocalizedString("browser.agent.tool.stopRecording.running", value: "Saving recording", comment: "Browser Agent - Saving a tab recording")
                : NSLocalizedString("browser.agent.tool.stopRecording.saved", value: "Saved recording", comment: "Browser Agent - Saved a tab recording without a file name")
        }
        if name == "go_back" {
            return failed ? NSLocalizedString("browser.agent.tool.goBack.failed", value: "Couldn't go back", comment: "Browser Agent - Tool summary after failure or denial: going back to the previous page in a tab's history")
                : running ? NSLocalizedString("browser.agent.tool.goBack.running", value: "Going back", comment: "Browser Agent - Tool summary while running: going back to the previous page in a tab's history")
                : NSLocalizedString("browser.agent.tool.goBack", value: "Went back", comment: "Browser Agent - Tool summary: went back to the previous page in a tab's history")
        }
        if name == "go_forward" {
            return failed ? NSLocalizedString("browser.agent.tool.goForward.failed", value: "Couldn't go forward", comment: "Browser Agent - Tool summary after failure or denial: going forward to the next page in a tab's history")
                : running ? NSLocalizedString("browser.agent.tool.goForward.running", value: "Going forward", comment: "Browser Agent - Tool summary while running: going forward to the next page in a tab's history")
                : NSLocalizedString("browser.agent.tool.goForward", value: "Went forward", comment: "Browser Agent - Tool summary: went forward to the next page in a tab's history")
        }
        if name == "schedule_prompt" {
            return failed ? NSLocalizedString("browser.agent.tool.schedulePrompt.failed", value: "Couldn't schedule prompt", comment: "Tool summary after scheduling a Drifter prompt failed")
                : running ? NSLocalizedString("browser.agent.tool.schedulePrompt.running", value: "Scheduling prompt", comment: "Tool summary while scheduling a Drifter prompt")
                : NSLocalizedString("browser.agent.tool.schedulePrompt", value: "Scheduled prompt", comment: "Tool summary after scheduling a Drifter prompt")
        }
        if name == "list_schedules" {
            return failed ? NSLocalizedString("browser.agent.tool.listSchedules.failed", value: "Couldn't list schedules", comment: "Tool summary after listing Drifter schedules failed")
                : running ? NSLocalizedString("browser.agent.tool.listSchedules.running", value: "Listing schedules", comment: "Tool summary while listing Drifter schedules")
                : NSLocalizedString("browser.agent.tool.listSchedules", value: "Listed schedules", comment: "Tool summary after listing Drifter schedules")
        }
        if name == "cancel_schedule" {
            return failed ? NSLocalizedString("browser.agent.tool.cancelSchedule.failed", value: "Couldn't cancel schedule", comment: "Tool summary after cancelling a Drifter schedule failed")
                : running ? NSLocalizedString("browser.agent.tool.cancelSchedule.running", value: "Cancelling schedule", comment: "Tool summary while cancelling a Drifter schedule")
                : NSLocalizedString("browser.agent.tool.cancelSchedule", value: "Cancelled schedule", comment: "Tool summary after cancelling a Drifter schedule")
        }
        if name == "notify" {
            return failed ? NSLocalizedString("browser.agent.tool.notify.failed", value: "Couldn't post notification", comment: "Tool summary after posting a Drifter notification failed")
                : running ? NSLocalizedString("browser.agent.tool.notify.running", value: "Posting notification", comment: "Tool summary while posting a Drifter notification")
                : NSLocalizedString("browser.agent.tool.notify", value: "Posted notification", comment: "Tool summary after posting a Drifter notification")
        }
        if name == "hand_off" {
            return failed ? NSLocalizedString("browser.agent.tool.handOff.failed", value: "Couldn't ask you to take over", comment: "Browser Agent - Tool summary after failure: the agent asking the user to do a step himself, such as signing in")
                : running ? NSLocalizedString("browser.agent.tool.handOff.running", value: "Asking you to take over", comment: "Browser Agent - Tool summary while running: the agent asks the user to do a step himself, such as signing in")
                : NSLocalizedString("browser.agent.tool.handOff", value: "Asked you to take over", comment: "Browser Agent - Tool summary: the agent asked the user to do a step himself, such as signing in")
        }
        if name == "save_page" {
            let raw = ((input["path"].string ?? "") as NSString).lastPathComponent
            let format = input["format"].string ?? ""
            let file = format.isEmpty || raw.lowercased().hasSuffix("." + format) ? raw : raw + "." + format
            let summary = failed
                ? NSLocalizedString("browser.agent.tool.savePage.failed", value: "Couldn't save %@", comment: "Browser Agent - Tool summary after failure or denial: saving a web page as a file; %@ is the file name")
                : running ? NSLocalizedString("browser.agent.tool.savePage.running", value: "Saving %@", comment: "Browser Agent - Tool summary while running: saving a web page as a file; %@ is the file name")
                : NSLocalizedString("browser.agent.tool.savePage", value: "Saved %@", comment: "Browser Agent - Tool summary: saved a web page as a file; %@ is the file name")
            return String(format: summary, file)
        }
        if name == "search_history" {
            return failed ? NSLocalizedString("browser.agent.tool.searchHistory.failed", value: "Couldn't search history", comment: "Browser Agent - Tool summary after failure: searching the browsing history")
                : running ? NSLocalizedString("browser.agent.tool.searchHistory.running", value: "Searching history", comment: "Browser Agent - Tool summary while running: searching the browsing history")
                : NSLocalizedString("browser.agent.tool.searchHistory", value: "Searched history", comment: "Browser Agent - Tool summary: searched the browsing history")
        }
        if name == "list_downloads" {
            return failed ? NSLocalizedString("browser.agent.tool.listDownloads.failed", value: "Couldn't list downloads", comment: "Browser Agent - Tool summary after failure: listing the window's downloads")
                : running ? NSLocalizedString("browser.agent.tool.listDownloads.running", value: "Listing downloads", comment: "Browser Agent - Tool summary while running: listing the window's downloads")
                : NSLocalizedString("browser.agent.tool.listDownloads", value: "Listed downloads", comment: "Browser Agent - Tool summary: listed the window's downloads")
        }
        if name == "evaluate" {
            return failed ? NSLocalizedString("browser.agent.tool.evaluate.failed", value: "Couldn't run JavaScript", comment: "Browser Agent - Tool summary after failure or denial: running JavaScript in a web page")
                : running ? NSLocalizedString("browser.agent.tool.evaluate.running", value: "Running JavaScript", comment: "Browser Agent - Tool summary while running: running JavaScript in a web page")
                : NSLocalizedString("browser.agent.tool.evaluate", value: "Ran JavaScript", comment: "Browser Agent - Tool summary: ran JavaScript in a web page")
        }
        if name == "read_console" {
            return failed ? NSLocalizedString("browser.agent.tool.readConsole.failed", value: "Couldn't read console", comment: "Browser Agent - Tool summary after failure: reading a web page's console messages")
                : running ? NSLocalizedString("browser.agent.tool.readConsole.running", value: "Reading console", comment: "Browser Agent - Tool summary while running: reading a web page's console messages")
                : NSLocalizedString("browser.agent.tool.readConsole", value: "Read console", comment: "Browser Agent - Tool summary: read a web page's console messages")
        }
        if name == "read_network" {
            return failed ? NSLocalizedString("browser.agent.tool.readNetwork.failed", value: "Couldn't read network requests", comment: "Browser Agent - Tool summary after failure: reading the network requests a web page made")
                : running ? NSLocalizedString("browser.agent.tool.readNetwork.running", value: "Reading network requests", comment: "Browser Agent - Tool summary while running: reading the network requests a web page made")
                : NSLocalizedString("browser.agent.tool.readNetwork", value: "Read network requests", comment: "Browser Agent - Tool summary: read the network requests a web page made")
        }
        if name == "group_tabs" {
            if input["ungroup"].bool {
                return failed ? NSLocalizedString("browser.agent.tool.ungroupTabs.failed", value: "Couldn't ungroup tabs", comment: "Browser Agent - Tool summary after failure: taking tabs out of a tab group, or dissolving a group")
                    : running ? NSLocalizedString("browser.agent.tool.ungroupTabs.running", value: "Ungrouping tabs", comment: "Browser Agent - Tool summary while running: taking tabs out of a tab group, or dissolving a group")
                    : NSLocalizedString("browser.agent.tool.ungroupTabs", value: "Ungrouped tabs", comment: "Browser Agent - Tool summary: took tabs out of a tab group, or dissolved a group")
            }
            if input["tabIds"].array.isEmpty {
                return failed ? NSLocalizedString("browser.agent.tool.updateTabGroup.failed", value: "Couldn't update tab group", comment: "Browser Agent - Tool summary after failure: renaming, recoloring, collapsing or expanding a tab group")
                    : running ? NSLocalizedString("browser.agent.tool.updateTabGroup.running", value: "Updating tab group", comment: "Browser Agent - Tool summary while running: renaming, recoloring, collapsing or expanding a tab group")
                    : NSLocalizedString("browser.agent.tool.updateTabGroup", value: "Updated tab group", comment: "Browser Agent - Tool summary: renamed, recolored, collapsed or expanded a tab group")
            }
            return failed ? NSLocalizedString("browser.agent.tool.groupTabs.failed", value: "Couldn't group tabs", comment: "Browser Agent - Tool summary after failure: putting tabs into a tab group")
                : running ? NSLocalizedString("browser.agent.tool.groupTabs.running", value: "Grouping tabs", comment: "Browser Agent - Tool summary while running: putting tabs into a tab group")
                : NSLocalizedString("browser.agent.tool.groupTabs", value: "Grouped tabs", comment: "Browser Agent - Tool summary: put tabs into a tab group")
        }
        if name == "drag" {
            return failed ? NSLocalizedString("browser.agent.tool.drag.failed", value: "Couldn't drag element", comment: "Browser Agent - Tool summary after failure or denial: dragging a web page element with the mouse")
                : running ? NSLocalizedString("browser.agent.tool.drag.running", value: "Dragging element", comment: "Browser Agent - Tool summary while running: dragging a web page element with the mouse")
                : NSLocalizedString("browser.agent.tool.drag", value: "Dragged element", comment: "Browser Agent - Tool summary: dragged a web page element with the mouse")
        }
        if name == "click", input["button"].string == "right" {
            return failed ? NSLocalizedString("browser.agent.tool.rightClick.failed", value: "Couldn't right-click element", comment: "Browser Agent - Tool summary after failure or denial: right-clicking a web page element")
                : running ? NSLocalizedString("browser.agent.tool.rightClick.running", value: "Right-clicking element", comment: "Browser Agent - Tool summary while running: right-clicking a web page element")
                : NSLocalizedString("browser.agent.tool.rightClick", value: "Right-clicked element", comment: "Browser Agent - Tool summary: right-clicked a web page element")
        }
        if name == "click", input["double"].bool {
            return failed ? NSLocalizedString("browser.agent.tool.doubleClick.failed", value: "Couldn't double-click element", comment: "Browser Agent - Tool summary after failure or denial: double-clicking a web page element")
                : running ? NSLocalizedString("browser.agent.tool.doubleClick.running", value: "Double-clicking element", comment: "Browser Agent - Tool summary while running: double-clicking a web page element")
                : NSLocalizedString("browser.agent.tool.doubleClick", value: "Double-clicked element", comment: "Browser Agent - Tool summary: double-clicked a web page element")
        }
        if name == "hover" {
            return failed ? NSLocalizedString("browser.agent.tool.hover.failed", value: "Couldn't hover over element", comment: "Browser Agent - Failed hover")
                : running ? NSLocalizedString("browser.agent.tool.hover.running", value: "Hovering over element", comment: "Browser Agent - Hover in progress")
                : NSLocalizedString("browser.agent.tool.hover", value: "Hovered over element", comment: "Browser Agent - Hover completed")
        }
        if name == "scroll_until" {
            let format = failed ? NSLocalizedString("browser.agent.tool.scrollUntil.failed", value: "Couldn't scroll to find %@", comment: "Browser Agent - Failed search while scrolling")
                : running ? NSLocalizedString("browser.agent.tool.scrollUntil.running", value: "Scrolling to find %@", comment: "Browser Agent - Searching while scrolling")
                : NSLocalizedString("browser.agent.tool.scrollUntil", value: "Scrolled to find %@", comment: "Browser Agent - Found while scrolling")
            return String(format: format, input["text"].string ?? input["selector"].string ?? "")
        }
        if name == "select_option" {
            let format = failed
                ? NSLocalizedString("browser.agent.tool.option.failed", value: "Couldn't choose %@", comment: "Browser Agent - Failed tool summary; %@ is an option of a web page's dropdown menu")
                : running ? NSLocalizedString("browser.agent.tool.option.running", value: "Choosing %@", comment: "Browser Agent - Tool summary while running; %@ is an option of a web page's dropdown menu")
                : NSLocalizedString("browser.agent.tool.option", value: "Chose %@", comment: "Browser Agent - Tool summary; %@ is an option of a web page's dropdown menu")
            return String(format: format, input["label"].string ?? input["value"].string ?? "")
        }
        if name == "select_text" {
            return failed ? NSLocalizedString("browser.agent.tool.selectText.failed", value: "Couldn't select text", comment: "Browser Agent - Tool summary after failure or denial: selecting text on a web page")
                : running ? NSLocalizedString("browser.agent.tool.selectText.running", value: "Selecting text", comment: "Browser Agent - Tool summary while running: selecting text on a web page")
                : NSLocalizedString("browser.agent.tool.selectText", value: "Selected text", comment: "Browser Agent - Tool summary: selected text on a web page")
        }
        if name == "screenshot", input["fullPage"].bool, !failed, !running {
            return NSLocalizedString("browser.agent.tool.screenshot.fullPage", value: "Captured full page", comment: "Browser Agent - Full-page screenshot completed")
        }
        if failed {
            switch name {
            case "list_tabs": return NSLocalizedString("browser.agent.tool.list.failed", value: "Couldn't list tabs", comment: "Browser Agent - Tool summary after failure or denial")
            case "use_tab": return NSLocalizedString("browser.agent.tool.use.failed", value: "Couldn't connect to tab", comment: "Browser Agent - Tool summary after failure or denial")
            case "open_tab": return String(format: NSLocalizedString("browser.agent.tool.open.failed", value: "Couldn't open %@", comment: "Browser Agent - Failed tool summary; %@ is the website host"), host)
            case "navigate": return String(format: NSLocalizedString("browser.agent.tool.navigate.failed", value: "Couldn't navigate to %@", comment: "Browser Agent - Failed tool summary; %@ is the website host"), host)
            case "reload": return NSLocalizedString("browser.agent.tool.reload.failed", value: "Couldn't reload page", comment: "Browser Agent - Tool summary after failure or denial")
            case "snapshot", "read_page": return NSLocalizedString("browser.agent.tool.read.failed", value: "Couldn't read page", comment: "Browser Agent - Tool summary after failure or denial")
            case "click": return NSLocalizedString("browser.agent.tool.click.failed", value: "Couldn't click element", comment: "Browser Agent - Tool summary after failure or denial")
            case "fill", "type_text": return NSLocalizedString("browser.agent.tool.type.failed", value: "Couldn't enter text", comment: "Browser Agent - Tool summary after failure or denial")
            case "press_key": return String(format: NSLocalizedString("browser.agent.tool.key.failed", value: "Couldn't press %@", comment: "Browser Agent - Failed tool summary; %@ is the key name"), browserKeyLabel(input))
            case "scroll": return NSLocalizedString("browser.agent.tool.scroll.failed", value: "Couldn't scroll page", comment: "Browser Agent - Tool summary after failure or denial")
            case "wait_for": return NSLocalizedString("browser.agent.tool.wait.failed", value: "Couldn't wait for page", comment: "Browser Agent - Tool summary after failure or denial")
            case "handle_dialog": return NSLocalizedString("browser.agent.tool.dialog.failed", value: "Couldn't handle dialog", comment: "Browser Agent - Tool summary after failure or denial")
            case "close_tab": return NSLocalizedString("browser.agent.tool.close.failed", value: "Couldn't close tab", comment: "Browser Agent - Tool summary after failure or denial")
            case "screenshot": return NSLocalizedString("browser.agent.tool.screenshot.failed", value: "Couldn't capture screenshot", comment: "Browser Agent - Tool summary after failure or denial")
            default: return nil
            }
        }
        if running {
            switch name {
            case "list_tabs": return NSLocalizedString("browser.agent.tool.list.running", value: "Listing tabs", comment: "Browser Agent - Tool summary while running")
            case "use_tab": return NSLocalizedString("browser.agent.tool.use.running", value: "Connecting to tab", comment: "Browser Agent - Tool summary while running")
            case "open_tab": return String(format: NSLocalizedString("browser.agent.tool.open.running", value: "Opening %@", comment: "Browser Agent - Tool summary while running"), host)
            case "navigate": return String(format: NSLocalizedString("browser.agent.tool.navigate.running", value: "Navigating to %@", comment: "Browser Agent - Tool summary while running"), host)
            case "reload": return NSLocalizedString("browser.agent.tool.reload.running", value: "Reloading page", comment: "Browser Agent - Tool summary while running")
            case "snapshot", "read_page": return NSLocalizedString("browser.agent.tool.read.running", value: "Reading page", comment: "Browser Agent - Tool summary while running")
            case "click": return NSLocalizedString("browser.agent.tool.click.running", value: "Clicking element", comment: "Browser Agent - Tool summary while running")
            case "fill", "type_text": return NSLocalizedString("browser.agent.tool.type.running", value: "Entering text", comment: "Browser Agent - Tool summary while running")
            case "press_key": return String(format: NSLocalizedString("browser.agent.tool.key.running", value: "Pressing %@", comment: "Browser Agent - Tool summary while running"), browserKeyLabel(input))
            case "scroll": return NSLocalizedString("browser.agent.tool.scroll.running", value: "Scrolling page", comment: "Browser Agent - Tool summary while running")
            case "wait_for": return NSLocalizedString("browser.agent.tool.wait.running", value: "Waiting for page", comment: "Browser Agent - Tool summary while running")
            case "handle_dialog": return NSLocalizedString("browser.agent.tool.dialog.running", value: "Handling dialog", comment: "Browser Agent - Tool summary while running")
            case "close_tab": return NSLocalizedString("browser.agent.tool.close.running", value: "Closing tab", comment: "Browser Agent - Tool summary while running")
            case "screenshot": return NSLocalizedString("browser.agent.tool.screenshot.running", value: "Capturing screenshot", comment: "Browser Agent - Tool summary while running")
            default: return nil
            }
        }
        switch name {
        case "list_tabs": return NSLocalizedString("browser.agent.tool.list", value: "Listed tabs", comment: "Browser Agent - Tool summary")
        case "use_tab": return NSLocalizedString("browser.agent.tool.use", value: "Connected to tab", comment: "Browser Agent - Tool summary")
        case "open_tab": return String(format: NSLocalizedString("browser.agent.tool.open", value: "Opened %@", comment: "Browser Agent - Tool summary, website"), host)
        case "navigate": return String(format: NSLocalizedString("browser.agent.tool.navigate", value: "Navigated to %@", comment: "Browser Agent - Tool summary, website"), host)
        case "reload": return NSLocalizedString("browser.agent.tool.reload", value: "Reloaded page", comment: "Browser Agent - Tool summary")
        case "snapshot", "read_page": return NSLocalizedString("browser.agent.tool.read", value: "Read page", comment: "Browser Agent - Tool summary")
        case "click": return NSLocalizedString("browser.agent.tool.click", value: "Clicked element", comment: "Browser Agent - Tool summary")
        case "fill", "type_text": return NSLocalizedString("browser.agent.tool.type", value: "Entered text", comment: "Browser Agent - Tool summary")
        case "press_key": return String(format: NSLocalizedString("browser.agent.tool.key", value: "Pressed %@", comment: "Browser Agent - Tool summary, key name"), browserKeyLabel(input))
        case "scroll": return NSLocalizedString("browser.agent.tool.scroll", value: "Scrolled page", comment: "Browser Agent - Tool summary")
        case "wait_for": return NSLocalizedString("browser.agent.tool.wait", value: "Waited for page", comment: "Browser Agent - Tool summary")
        case "handle_dialog": return NSLocalizedString("browser.agent.tool.dialog", value: "Handled dialog", comment: "Browser Agent - Tool summary")
        case "close_tab": return NSLocalizedString("browser.agent.tool.close", value: "Closed tab", comment: "Browser Agent - Tool summary")
        case "screenshot": return NSLocalizedString("browser.agent.tool.screenshot", value: "Captured screenshot", comment: "Browser Agent - Tool summary")
        default: return nil
        }
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

private enum DiffWordChanges {
    private struct Token {
        var text: String
        var range: NSRange
        var whitespace: Bool
    }

    static func apply(to lines: inout [ClaudeCodeToolSummary.Line], from start: Int) {
        var index = start
        while index < lines.count {
            guard lines[index].kind == .removal else { index += 1; continue }
            let oldStart = index
            while index < lines.count && lines[index].kind == .removal { index += 1 }
            let newStart = index
            while index < lines.count && lines[index].kind == .addition { index += 1 }
            for offset in 0..<min(newStart - oldStart, index - newStart) {
                let (old, new) = changes(lines[oldStart + offset].text, lines[newStart + offset].text)
                lines[oldStart + offset].changes = old
                lines[newStart + offset].changes = new
            }
        }
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var offset = 1
        var previousKind = 0
        for character in text.dropFirst() {
            let value = String(character)
            let scalars = value.unicodeScalars
            let kind = scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } ? 2 :
                (scalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || CharacterSet.nonBaseCharacters.contains($0) } ? 1 : 3)
            let length = (value as NSString).length
            if kind != 3 && kind == previousKind {
                result[result.count - 1].text += value
                result[result.count - 1].range.length += length
            } else {
                result.append(Token(text: value, range: NSRange(location: offset, length: length), whitespace: kind == 2))
            }
            previousKind = kind
            offset += length
        }
        return result
    }

    private static func changes(_ old: String, _ new: String) -> ([NSRange], [NSRange]) {
        guard (old as NSString).length <= 2001, (new as NSString).length <= 2001 else { return ([], []) }
        let oldTokens = tokens(old), newTokens = tokens(new)
        let diff = newTokens.map(\.text).difference(from: oldTokens.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        func tooLarge(_ tokens: [Token], _ changed: Set<Int>) -> Bool {
            let total = tokens.filter { !$0.whitespace }.reduce(0) { $0 + $1.range.length }
            let count = changed.reduce(0) { $0 + (tokens[$1].whitespace ? 0 : tokens[$1].range.length) }
            return count * 5 > total * 2
        }
        guard !tooLarge(oldTokens, removed), !tooLarge(newTokens, inserted) else { return ([], []) }
        func ranges(_ tokens: [Token], _ changed: Set<Int>) -> [NSRange] {
            let indices = changed.sorted()
            var result: [NSRange] = []
            var previous: Int?
            for index in indices {
                let range = tokens[index].range
                if let last = previous, (last + 1 == index || (last + 2 == index && tokens[last + 1].whitespace)) {
                    result[result.count - 1].length = NSMaxRange(range) - result[result.count - 1].location
                } else {
                    result.append(range)
                }
                previous = index
            }
            return result
        }
        return (ranges(oldTokens, removed), ranges(newTokens, inserted))
    }
}
