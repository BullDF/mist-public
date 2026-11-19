import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeEngineTests: XCTestCase {
    @MainActor func testRemoteControlStartup() throws {
        for (_, available, success, _, expected) in [
            (true, true, true, false, true), (false, true, true, false, true),
            (true, false, true, false, false), (true, true, false, false, false),
            (true, true, true, true, true)
        ] {
            var sent: [String] = []
            let conversation = AgentConversation()
            let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")),
                conversation: conversation, controlWriter: { sent.append($0) })
            defer { session.close() }
            session.initialize()
            sent.removeAll()
            session.receive(.event(.controlResponse(.object(["response": .object([
                "request_id": .string(try XCTUnwrap(session.initializeRequestId)),
                "subtype": .string(success ? "success" : "error"),
                "response": .object(["remote_control_available": .bool(available)])
            ])]))))
            XCTAssertEqual(sent.count, expected ? 1 : 0)
            if expected {
                let request = try json(XCTUnwrap(sent.first))
                XCTAssertEqual(request["request"], .object(["subtype": .string("remote_control"), "enabled": .bool(true)]))
                let items = session.transcript.items
                let status = session.transcript.status
                session.receive(.event(.controlResponse(.object(["response": .object([
                    "request_id": request["request_id"], "subtype": .string("error"), "error": .string("failed")
                ])]))))
                session.receive(.event(.system(.object(["subtype": .string("bridge_state"), "state": .string("ready")]))))
                XCTAssertEqual(session.transcript.items, items)
                XCTAssertEqual(session.transcript.status, status)
                XCTAssertEqual(sent.count, 1)
            }
        }
    }

    @MainActor func testRemotePermissionWithdrawal() throws {
        XCTAssertEqual(ClaudeCodeProtocol.decode(Data(#"{"type":"control_cancel_request","request_id":"p1"}"#.utf8)), .permissionWithdrawn(requestId: "p1"))
        XCTAssertNil(ClaudeCodeProtocol.decode(Data(#"{"type":"control_cancel_request"}"#.utf8)))
        for tool in ["Bash", "AskUserQuestion", "ExitPlanMode"] {
            var sent: [String] = []
            let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")),
                conversation: AgentConversation(), controlWriter: { sent.append($0) })
            defer { session.close() }
            session.receive(.event(.permission(.object(["request_id": .string("p1"), "request": .object([
                "tool_name": .string(tool), "input": .object([:])
            ])]))))
            XCTAssertEqual(session.transcript.status, .awaitingPermission)
            let items = session.transcript.items
            session.receive(.event(.permissionWithdrawn(requestId: "unknown")))
            XCTAssertEqual(session.transcript.items, items)
            XCTAssertEqual(session.transcript.status, .awaitingPermission)
            session.receive(.event(.permissionWithdrawn(requestId: "p1")))
            XCTAssertTrue(session.transcript.items.isEmpty)
            XCTAssertEqual(session.transcript.status, .running)
            session.decidePermission(requestId: "p1", response: .allow)
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testLocalizedTaskNotifications() {
        let cases: [(String, String)] = [
            ("Background command \"task\" completed", "Background command “task” completed"),
            ("Background command \"task\" completed (exit code -1)", "Background command “task” completed (exit code -1)"),
            ("Background command \"task\" completed (exit code 1: detail)", "Background command “task” completed (exit code 1: detail)"),
            ("Background command \"task\" failed", "Background command “task” failed"),
            ("Background command \"task\" failed with exit code 2", "Background command “task” failed with exit code 2"),
            ("Background command \"task\" was stopped", "Background command “task” was stopped"),
            ("Background command \"task\" was stopped because the system is running low on memory", "Background command “task” was stopped because the system is running low on memory"),
            ("Background command \"task\" was stopped after reaching its background time limit", "Background command “task” was stopped after reaching its background time limit"),
            ("Monitor \"task\" stream ended", "Monitor “task” stream ended"),
            ("Monitor \"task\" ended without producing output", "Monitor “task” ended without producing output"),
            ("Monitor \"task\" ended without producing output (exit -2)", "Monitor “task” ended without producing output (exit -2)"),
            ("Monitor \"task\" script failed", "Monitor “task” script failed"),
            ("Monitor \"task\" script failed (exit 3)", "Monitor “task” script failed (exit 3)"),
            ("Monitor \"task\" stopped", "Monitor “task” stopped"),
            (#"Background command "echo "hi"" completed (exit code 0)"#, #"Background command “echo "hi"” completed (exit code 0)"#),
            (#"Remote task "x" completed successfully"#, #"Remote task "x" completed successfully"#),
            ("", "")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(AgentChatStrings.taskNotification(raw), expected, raw)
        }
    }

    func testFinishedBackgroundToolLocalizesSummary() {
        let raw = #"Background command "task" completed (exit code 0)"#
        let summary = ClaudeCodeToolSummary.format(tool: "Bash", input: .null, text: raw,
                                                   folder: URL(fileURLWithPath: "/tmp"), background: .finished)
        XCTAssertEqual(summary.summary.map(\.text), ["Background command “task” completed (exit code 0)"])
        let other = ClaudeCodeToolSummary.format(tool: "Bash", input: .null, text: "Launched",
                                                 folder: URL(fileURLWithPath: "/tmp"), background: .finished)
        XCTAssertEqual(other.summary.map(\.text), ["Launched"])
    }

    @MainActor func testMCPCommandsActionsAndSettlement() throws {
        var sent: [String] = []
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
        session.mcpStartupWindow = 0
        defer { session.close() }
        func command(_ id: String, _ args: String = "") -> ClaudeCodeEvent {
            .assistant(.object(["uuid": .string(id), "message": .object(["content": .array([.object(["text": .string("fallback")])])]),
                                "local_command_run": .object(["command": .string("mcp"), "args": .string(args)])]))
        }
        func reply(_ id: ClaudeCodeJSON, _ subtype: String, _ payload: ClaudeCodeJSON = .null, error: String? = nil) {
            var value: [String: ClaudeCodeJSON] = ["request_id": id, "subtype": .string(subtype), "response": payload]
            if let error { value["error"] = .string(error) }
            session.receive(.event(.controlResponse(.object(["response": .object(value)]))))
        }
        session.receive(.event(command("arguments", "foo")))
        XCTAssertTrue(sent.isEmpty)
        session.receive(.event(command("one")))
        XCTAssertEqual(sent.count, 1)
        let request = try json(XCTUnwrap(sent.last))
        XCTAssertEqual(request["request"]["subtype"].string, "mcp_status")
        let payload = try json(#"{"mcpServers":[{"name":"a","status":"connected","scope":"user","tools":[{},{}],"config":{"secret":"discard"},"serverInfo":{"icon":"discard"}}]}"#)
        reply(request["request_id"], "success", payload)
        guard case let .mcpServers(status) = session.transcript.items.last?.kind else { return XCTFail("Missing card") }
        XCTAssertEqual(status.servers.first?.toolCount, 2)
        XCTAssertEqual(status.servers.first?.scope, "user")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains("discard"))
        session.receive(.event(command("one")))
        XCTAssertEqual(sent.count, 1)
        conversation.onMCPServerAction?("a", .disable)
        let action = try json(XCTUnwrap(sent.last))
        XCTAssertEqual(action["request"]["subtype"].string, "mcp_toggle")
        XCTAssertEqual(action["request"]["enabled"], .bool(false))
        guard case let .mcpServers(busy) = session.transcript.items.last?.kind else { return XCTFail("Missing card") }
        XCTAssertTrue(busy.busy.contains("a"))
        reply(action["request_id"], "error", error: "failure")
        guard case let .mcpServers(failed) = session.transcript.items.last?.kind else { return XCTFail("Missing card") }
        XCTAssertFalse(failed.busy.contains("a"))
        XCTAssertEqual(failed.actionErrors["a"], "failure")
        let refresh = try json(XCTUnwrap(sent.last))
        XCTAssertEqual(refresh["request"]["subtype"].string, "mcp_status")
        reply(refresh["request_id"], "success", payload)
        session.receive(.event(command("two")))
        let second = try json(XCTUnwrap(sent.last))
        reply(second["request_id"], "success", payload)
        let first = try XCTUnwrap(session.transcript.items.first { $0.id == "command:one" })
        guard case let .mcpServers(old) = first.kind else { return XCTFail("Missing old card") }
        XCTAssertFalse(old.live)
        let live = try XCTUnwrap(session.transcript.items.last)
        guard case let .mcpServers(settled) = live.settled.kind else { return XCTFail("Missing settled card") }
        XCTAssertFalse(settled.live)
        XCTAssertTrue(settled.busy.isEmpty)
        session.receive(.exited(code: 0, stderr: ""))
        guard case let .mcpServers(ended) = session.transcript.items.first(where: { $0.id == "command:two" })?.kind else { return XCTFail("Missing card") }
        XCTAssertFalse(ended.live)
        XCTAssertTrue(ended.busy.isEmpty)
    }

    @MainActor func testMCPErrorLeavesFallback() throws {
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: AgentConversation(), controlWriter: { sent.append($0) })
        defer { session.close() }
        session.receive(.event(.assistant(try json(#"{"uuid":"error","local_command_run":{"command":"mcp","args":""},"message":{"content":[{"text":"fallback"}]}}"#))))
        let id = try json(XCTUnwrap(sent.last))["request_id"]
        session.receive(.event(.controlResponse(.object(["response": .object(["request_id": id, "subtype": .string("error")])]))))
        XCTAssertEqual(session.transcript.items.last?.kind, .commandOutput(command: "mcp", text: "fallback", isError: false))
    }

    @MainActor func testMCPPollsPendingAndStopsAfterStartup() async throws {
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: AgentConversation(), controlWriter: { sent.append($0) })
        defer { session.close() }
        var now = Date()
        session.mcpClock = { now }
        session.mcpPollDelay = .zero
        session.receive(.event(.assistant(try json(#"{"uuid":"poll","local_command_run":{"command":"mcp"},"message":{"content":[]}}"#))))
        let id = try json(XCTUnwrap(sent.last))["request_id"]
        session.receive(.event(.controlResponse(.object(["response": .object(["request_id": id, "subtype": .string("success"), "response": try json(#"{"mcpServers":[{"name":"a","status":"connected"}]}"#)])]))))
        for _ in 0..<20 where sent.count < 2 { await Task.yield() }
        XCTAssertEqual(sent.count, 2)
        let next = try json(XCTUnwrap(sent.last))["request_id"]
        now.addTimeInterval(11)
        session.receive(.event(.controlResponse(.object(["response": .object(["request_id": next, "subtype": .string("success"), "response": try json(#"{"mcpServers":[{"name":"a","status":"pending"}]}"#)])]))))
        for _ in 0..<20 where sent.count < 3 { await Task.yield() }
        XCTAssertEqual(sent.count, 3)
        let final = try json(XCTUnwrap(sent.last))["request_id"]
        session.receive(.event(.controlResponse(.object(["response": .object(["request_id": final, "subtype": .string("success"), "response": try json(#"{"mcpServers":[{"name":"a","status":"connected"}]}"#)])]))))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sent.count, 3)
    }
    @MainActor func testEmptyResumeRequestsTitleButAnExistingSessionOrItemsDoNot() throws {
        for resume in [AgentChatResume(sessionId: nil, items: []), .init(sessionId: "existing", items: []),
                       .init(sessionId: nil, items: [.init(id: "old", kind: .userMessage(text: "Earlier", images: []))])] {
            let conversation = AgentConversation()
            let session = ClaudeCodeSession(request: .init(prompt: "", attachments: [], config: .init(folder: URL(fileURLWithPath: "/tmp")), launchArguments: [], resume: resume), conversation: conversation)
            defer { session.close() }
            var sent: [String] = []
            session.settings.send = { sent.append($0) }
            session.settings.isEnabled = true
            // An existing resume is confirmed by its first control reply.
            session.receive(.event(.controlResponse(.null)))
            session.receive(.event(.result(.null)))
            sent.removeAll()
            session.send(text: "First fresh message")
            let titles = try sent.map(json).filter { $0["request"]["subtype"].string == "generate_session_title" }
            XCTAssertEqual(titles.count, resume.sessionId == nil && resume.items.isEmpty ? 1 : 0)
        }
    }

    func testLocalCommandOutputUpsertsAndKeepsContextWithoutTurnDivider() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.seedContext(tokens: 44111, windowSize: 200000)
        transcript.userSent(text: "/model sonnet", attachments: [])
        let value = try json(#"{"message":{"id":"local","model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"Set model to **Sonnet**"}]},"local_command_run":{"command":"model","args":"sonnet"},"local_command_source":"<local-command-stdout>Set model</local-command-stdout>"}"#)
        transcript.apply(.assistant(value))
        transcript.apply(.assistant(value))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items.last?.kind, .commandOutput(command: "model", text: "Set model to **Sonnet**", isError: false))
        transcript.apply(.result(try json(#"{"local_command":"model","num_turns":0,"is_error":false}"#)))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.status, .idle)
        XCTAssertEqual(transcript.latestInputTokens, 44111)
        transcript.apply(.assistant(try json(#"{"message":{"id":"error","model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"Bad argument"}]},"local_command_source":"<local-command-stderr>Bad argument</local-command-stderr>"}"#)))
        XCTAssertEqual(transcript.items.last?.kind, .commandOutput(command: "", text: "Bad argument", isError: true))
    }

    func testSyntheticAssistantErrorDoesNotResetUsage() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.seedContext(tokens: 42, windowSize: 200000)
        transcript.apply(.assistant(try json(#"{"message":{"id":"api-error","model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"API error"}]}}"#)))
        XCTAssertEqual(transcript.latestInputTokens, 42)
        XCTAssertEqual(transcript.items.last?.kind, .assistantText(text: "API error", isStreaming: false))
    }

    func testContextCommandAndCompactionUpdateUsageAndPersist() throws {
        var transcript = ClaudeCodeTranscript()
        let value = try json(#"{"uuid":"context-event","message":{"id":"context","content":[{"type":"text","text":"markdown tables"}]},"local_command_run":{"command":"context"},"context_usage":{"model":"sonnet","total_tokens":44111,"raw_max_tokens":200000,"percentage":22.1,"categories":[{"name":"System prompt","tokens":1000,"kind":"used"},{"name":"Tools","tokens":400,"kind":"deferred"},{"name":"Autocompact buffer","tokens":33000,"kind":"buffer"},{"name":"Free space","tokens":122889,"kind":"free"}],"skills":[]}}"#)
        transcript.apply(.assistant(value))
        guard case let .contextUsage(usage) = transcript.items.last?.kind else { return XCTFail("Missing context usage") }
        XCTAssertEqual(usage.model, "sonnet")
        XCTAssertEqual(usage.percentage, 22.1)
        XCTAssertEqual(usage.categories.map(\.kind), ["used", "deferred", "buffer", "free"])
        XCTAssertEqual(transcript.latestInputTokens, 44111)
        XCTAssertEqual(transcript.contextWindowSize, 200000)
        for trigger in ["manual", "auto"] {
            transcript.apply(.system(.object(["subtype": .string("compact_boundary"), "compact_metadata": .object([
                "trigger": .string(trigger), "pre_tokens": .number(44111), "post_tokens": .number(12481)])])))
            XCTAssertEqual(transcript.items.last?.kind, .compaction(trigger: ClaudeCodeCompactionTrigger(rawValue: trigger)!, preTokens: 44111, postTokens: 12481))
            XCTAssertEqual(transcript.latestInputTokens, 12481)
        }
        transcript.apply(.user(try json(#"{"isReplay":true,"message":{"content":"<local-command-stdout>Compacted </local-command-stdout>"}}"#)))
        // Compaction re-sends the kept /context output with its uuid, a new message id and the old usage.
        transcript.apply(.assistant(try json(#"{"uuid":"context-event","message":{"id":"resent","content":[]},"local_command_run":{"command":"context"},"context_usage":{"total_tokens":44111,"raw_max_tokens":200000,"categories":[]}}"#)))
        XCTAssertEqual(transcript.items.count, 3)
        XCTAssertEqual(transcript.latestInputTokens, 12481)
        XCTAssertEqual(try JSONDecoder().decode([AgentChatItem].self, from: JSONEncoder().encode(transcript.items)), transcript.items)
    }

    @MainActor func testLocalModelAndEffortCommandsFollowAppliedSettings() throws {
        var sent: [String] = []
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")),
            conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.initialize()
        session.receive(.event(.controlResponse(.object(["response": .object([
            "request_id": .string(try XCTUnwrap(session.initializeRequestId)), "subtype": .string("success"),
            "response": try json(#"{"commands":[],"models":[{"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5"}]}"#)])]))))
        for command in ["model", "effort"] {
            sent.removeAll()
            session.receive(.event(.result(.object(["local_command": .string(command)]))))
            let request = try json(XCTUnwrap(sent.last))
            XCTAssertEqual(request["request"]["subtype"].string, "get_settings")
            session.receive(.event(.controlResponse(.object(["response": .object([
                "request_id": request["request_id"], "subtype": .string("success"),
                "response": .object(["applied": .object(["model": .string("claude-haiku-5-5"), "effort": .string("medium")])])])]))))
            XCTAssertEqual(session.settings.config.model, .haiku)
            XCTAssertEqual(session.settings.config.effort, .medium)
            XCTAssertEqual(session.transcript.resolvedModelId, "claude-haiku-5-5")
            XCTAssertEqual(sent.count, 1)
        }
        session.receive(.event(.result(.object(["local_command": .string("model")]))))
        let request = try json(XCTUnwrap(sent.last))
        session.receive(.event(.controlResponse(.object(["response": .object([
            "request_id": request["request_id"], "subtype": .string("success"),
            "response": .object(["applied": .object(["model": .string("claude-sonnet-5"), "effort": .string("auto")])])])]))))
        XCTAssertEqual(session.settings.config.model, .haiku)
        XCTAssertEqual(session.settings.config.effort, .medium)
    }

    @MainActor func testRunningSessionRenamesWithHostSourceAndClearsPendingTitle() throws {
        var sent: [String] = []
        let conversation = AgentConversation(firstPrompt: "Automatic")
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")),
            conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.receive(.event(.result(.null)))
        session.send(text: "First message")
        sent.removeAll()
        conversation.pendingSessionTitle = "Manual title"
        session.sendPendingTitle()
        XCTAssertEqual(sent.count, 1)
        let rename = try json(XCTUnwrap(sent.first))
        XCTAssertEqual(rename["type"].string, "control_request")
        XCTAssertNotNil(rename["request_id"].string)
        XCTAssertEqual(rename["request"]["subtype"].string, "rename_session")
        XCTAssertEqual(rename["request"]["title"].string, "Manual title")
        XCTAssertEqual(rename["request"]["source"].string, "host")
        XCTAssertNil(conversation.pendingSessionTitle)
        session.sendPendingTitle()
        XCTAssertEqual(sent.count, 1)
    }

    @MainActor func testSessionTitleChangedEventLeavesConversationAndTranscriptAlone() {
        let conversation = AgentConversation(firstPrompt: "Automatic")
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")),
            conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.receive(.event(.result(.null)))
        let items = conversation.items, status = conversation.status, sessionId = session.sessionId
        var generated = false
        conversation.onTitleGenerated = { _ in generated = true }
        session.receive(.event(.system(.object(["subtype": .string("session_title_changed"),
            "title": .string("CLI title"), "session_id": .string("other")]))))
        XCTAssertEqual(conversation.items, items)
        XCTAssertEqual(conversation.status, status)
        XCTAssertEqual(conversation.title, "Automatic")
        XCTAssertEqual(session.sessionId, sessionId)
        XCTAssertFalse(generated)
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor func testInitPublishesMemoryFoldersAndKeepsRestoredFoldersUntilReported() {
        let auto = URL(fileURLWithPath: "/auto-memory", isDirectory: true)
        let team = URL(fileURLWithPath: "/team-memory", isDirectory: true)
        let conversation = AgentConversation()
        conversation.memoryFolders = [auto]
        let session = ClaudeCodeSession(config: .init(folder: auto), conversation: conversation, controlWriter: { _ in })
        defer { session.close() }
        let missing = ClaudeCodeEvent.system(.object(["subtype": .string("init")]))
        var transcript = ClaudeCodeTranscript()
        transcript.apply(missing)
        XCTAssertEqual(transcript.memoryFolders, [])
        session.receive(.event(missing))
        XCTAssertEqual(conversation.memoryFolders, [auto])
        let event = ClaudeCodeEvent.system(.object(["subtype": .string("init"), "memory_paths": .object([
            "auto": .string(auto.path + "/"), "team": .string(team.path + "/")])]))
        transcript.apply(event)
        XCTAssertEqual(transcript.memoryFolders, [auto, team])
        session.receive(.event(event))
        XCTAssertEqual(conversation.memoryFolders, [auto, team])
    }

    @MainActor private func shell(in conversation: AgentConversation) -> AgentChatItem.ShellCommand? {
        conversation.items.compactMap {
            if case let .shellCommand(command) = $0.kind { return command }; return nil
        }.last
    }




    @MainActor func testBrowserAgentTreatsBangAsNormalText() throws {
        var sent: [String] = []
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: FileManager.default.temporaryDirectory), conversation: conversation,
            controlWriter: { sent.append($0) })
        defer { session.close() }
        session.receive(.event(.result(.null)))
        session.send(text: "! pwd")
        XCTAssertNil(shell(in: conversation))
        XCTAssertEqual(try json(sent[0])["message"]["content"].array[0]["text"].string, "! pwd")
    }




    func testShellOutputKeepsBoundedHeadTailAndOmittedCount() throws {
        var output = ShellOutput()
        output.append(String(repeating: "h", count: 14_999))
        output.append("H" + String(repeating: "x", count: 15_005))
        output.append("end")
        XCTAssertEqual(output.head, String(repeating: "h", count: 14_999) + "H")
        XCTAssertEqual(output.tail, String(repeating: "x", count: 14_997) + "end")
        XCTAssertEqual(output.omitted, 8)
        XCTAssertTrue(output.claudeText.contains("[… 8 characters truncated …]"))
        XCTAssertEqual(try JSONDecoder().decode(ShellOutput.self, from: JSONEncoder().encode(output)), output)
        output.append(String(repeating: "z", count: 40_000))
        XCTAssertEqual(output.tail, String(repeating: "z", count: 15_000))
        XCTAssertEqual(output.omitted, 40_008)
    }





    func testRestoredTranscriptBecomesIdleAndKeepsHistory() {
        let saved = [AgentChatItem(id: "saved", kind: .assistantText(text: "Earlier", isStreaming: false))]
        var transcript = ClaudeCodeTranscript(restoring: saved)
        XCTAssertEqual(transcript.status, .dormant)
        transcript.ready()
        XCTAssertEqual(transcript.status, .dormant)
        transcript.restarting()
        transcript.ready()
        transcript.apply(.controlResponse(.null))
        XCTAssertEqual(transcript.status, .idle)
        XCTAssertEqual(transcript.items, saved)
    }

    func testDeniedPermissionKeepsItsToolIdentityWhenInputFormattingDiffers() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Run", attachments: [])
        transcript.apply(try event(#"{"type":"stream_event","api_message_id":"a","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"bash","name":"Bash","input":{}}}}"#))
        transcript.apply(try event(#"{"type":"stream_event","api_message_id":"a","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{ \"command\" : \"pwd\" }"}}}"#))
        transcript.apply(try event(#"{"type":"control_request","request_id":"p","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"}}}"#))
        transcript.permissionDecided(requestId: "p", response: .deny(message: nil))
        let tool = try XCTUnwrap(transcript.items.compactMap { item -> AgentChatItem.ToolCall? in
            if case let .toolCall(tool) = item.kind { return tool }
            return nil
        }.first)
        XCTAssertEqual(tool.toolUseId, "bash")
        XCTAssertTrue(tool.permissionDenied)
    }
    func testStreamingFileToolLearnsItsPathBeforeItsContentEnds() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Save", attachments: [])
        func input() throws -> ClaudeCodeJSON {
            let tool = try XCTUnwrap(transcript.items.compactMap { item -> AgentChatItem.ToolCall? in
                if case let .toolCall(tool) = item.kind { return tool }
                return nil
            }.first)
            return try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(tool.inputJSON.utf8))
        }
        func delta(_ partial: String) throws {
            let json = String(data: try JSONEncoder().encode(partial), encoding: .utf8)!
            transcript.apply(try event(#"{"type":"stream_event","api_message_id":"a","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"#
                + json + "}}}"))
        }
        transcript.apply(try event(#"{"type":"stream_event","api_message_id":"a","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"write","name":"Write","input":{}}}}"#))
        try delta(#"{"file_path": "/home/memory/a \"b\".m"#)
        XCTAssertEqual(try input(), .object([:]), "The path's string isn't complete yet")
        try delta(##"d", "content": "# Mem"##)
        XCTAssertEqual(try input(), .object(["file_path": .string(#"/home/memory/a "b".md"#)]))
        try delta(#"ory"}"#)
        XCTAssertEqual(try input()["content"].string, "# Memory")
        XCTAssertNil(ClaudeCodeTranscript.streamedFilePath(#"{"content": "x", "file_path": "/a"#))
        XCTAssertNil(ClaudeCodeTranscript.streamedFilePath(#"{"file_path": ""#))
        XCTAssertEqual(ClaudeCodeTranscript.streamedFilePath(" { \"file_path\" : \"/a\\\\\" , "), "/a\\")
    }

    func testForegroundTaskPairPreservesBashOutputAndNeverCountsAsBackground() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{"command":"sleep 4; echo actual"}}]}}"#))
        var before = transcript.items[0]
        transcript.apply(try event(#"{"type":"system","subtype":"task_started","task_id":"foreground","tool_use_id":"bash","is_backgrounded":false}"#))
        guard case var .toolCall(backgroundable) = before.kind else { return XCTFail() }
        backgroundable.canBackground = true
        before.kind = .toolCall(backgroundable)
        XCTAssertEqual(transcript.items[0], before)
        transcript.apply(try event(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"foreground","description":"Long shell"},{"task_id":"explicit","description":"Foreground too","is_backgrounded":false}]}"#))
        XCTAssertTrue(transcript.backgroundTasks.isEmpty)
        transcript.apply(try event(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bash","content":"actual"}]},"tool_use_result":{"stdout":"actual","stderr":""}}"#))
        let result = transcript.items[0]
        transcript.apply(try event(#"{"type":"system","subtype":"task_notification","task_id":"foreground","tool_use_id":"bash","status":"completed","summary":"Long shell description"}"#))
        XCTAssertEqual(transcript.items[0], result)
        XCTAssertEqual(transcript.items.count, 1)
        guard case let .toolCall(tool) = result.kind else { return XCTFail() }
        XCTAssertEqual(tool.output, "actual")
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertNil(tool.background)
        XCTAssertFalse(tool.canBackground)
    }

    func testForegroundBashMovesToBackgroundAndCompletes() throws {
        var transcript = ClaudeCodeTranscript()
        func tool() throws -> AgentChatItem.ToolCall {
            guard case let .toolCall(tool) = transcript.items[0].kind else { throw CocoaError(.coderInvalidValue) }
            return tool
        }
        transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{"command":"sleep 25; echo finished-sleeping"}}]}}"#))
        XCTAssertFalse(try tool().canBackground)
        transcript.apply(try event(#"{"type":"system","subtype":"task_started","task_id":"task","run_id":"run","tool_use_id":"bash","description":"Long shell","is_backgrounded":false,"task_type":"local_bash"}"#))
        XCTAssertTrue(try tool().canBackground)
        transcript.apply(try event(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"task","run_id":"run","task_type":"local_bash","description":"Long shell"}]}"#))
        XCTAssertTrue(transcript.backgroundTasks.isEmpty)
        transcript.apply(try event(#"{"type":"system","subtype":"task_updated","task_id":"task","run_id":"run","patch":{"is_backgrounded":true}}"#))
        XCTAssertFalse(try tool().canBackground)
        XCTAssertEqual(try tool().background, .running)
        XCTAssertEqual(try tool().status, .running)
        XCTAssertEqual(transcript.backgroundTasks, [.init(id: "task", kind: .shell, description: "Long shell")])
        // A repeated update must not add another task.
        transcript.apply(try event(#"{"type":"system","subtype":"task_updated","task_id":"task","patch":{"is_backgrounded":true}}"#))
        XCTAssertEqual(transcript.backgroundTasks.count, 1)
        transcript.apply(try event(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bash","content":"Command was manually backgrounded by user with ID: task.","is_error":false}]}}"#))
        XCTAssertEqual(try tool().background, .running)
        transcript.apply(try event(#"{"type":"result","is_error":false}"#))
        XCTAssertEqual(try tool().background, .running)
        transcript.apply(try event(#"{"type":"system","subtype":"task_updated","task_id":"task","patch":{"status":"completed","end_time":1794675757717}}"#))
        XCTAssertEqual(try tool().background, .running)
        transcript.apply(try event(#"{"type":"system","subtype":"task_notification","task_id":"task","run_id":"run","tool_use_id":"bash","status":"completed","summary":"Background command finished (exit code 0)"}"#))
        XCTAssertEqual(try tool().background, .finished)
        XCTAssertEqual(try tool().status, .succeeded)
        XCTAssertEqual(transcript.items.last?.kind, .taskNotification(summary: "Background command finished (exit code 0)", status: .completed))
        transcript.apply(try event(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#))
        XCTAssertTrue(transcript.backgroundTasks.isEmpty)
    }

    func testBackgroundAffordanceClearsWhenForegroundWorkEnds() throws {
        for ending in [
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"bash","content":"Failed","is_error":true}]}}"#,
            #"{"type":"result","is_error":true}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"task","status":"completed","summary":"Done"}"#
        ] {
            var transcript = ClaudeCodeTranscript()
            transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{}}]}}"#))
            transcript.apply(try event(#"{"type":"system","subtype":"task_started","task_id":"task","tool_use_id":"bash","is_backgrounded":false}"#))
            guard case let .toolCall(running) = transcript.items[0].kind else { return XCTFail() }
            XCTAssertTrue(running.canBackground)
            XCTAssertFalse(transcript.items[0].settled == transcript.items[0])
            transcript.apply(try event(ending))
            guard case let .toolCall(finished) = transcript.items[0].kind else { return XCTFail() }
            XCTAssertFalse(finished.canBackground)
            XCTAssertNil(finished.background)
        }
    }

    func testToolBackgroundAffordanceIsNotPersisted() throws {
        var tool = AgentChatItem.ToolCall(toolUseId: "bash", name: "Bash", inputSummary: "sleep 25", inputJSON: "{}")
        let original = try JSONEncoder().encode(tool)
        tool.canBackground = true
        let encoded = try JSONEncoder().encode(tool)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["canBackground"])
        XCTAssertFalse(try JSONDecoder().decode(AgentChatItem.ToolCall.self, from: encoded).canBackground)
    }

    func testBackgroundFlagTrueAndLegacyMissingFlagStillTrackTasks() throws {
        for flag in [#", "is_backgrounded":true"#, ""] {
            var transcript = ClaudeCodeTranscript()
            transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{}}]}}"#))
            transcript.apply(try event("{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"background\",\"tool_use_id\":\"bash\"" + flag + "}"))
            guard case let .toolCall(running) = transcript.items[0].kind else { return XCTFail() }
            XCTAssertEqual(running.background, .running)
            transcript.apply(try event(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"background","description":"Shell"}]}"#))
            XCTAssertEqual(transcript.backgroundTasks.count, 1)
            transcript.apply(try event(#"{"type":"system","subtype":"task_notification","task_id":"background","status":"completed","summary":"Finished"}"#))
            guard case let .toolCall(finished) = transcript.items[0].kind else { return XCTFail() }
            XCTAssertEqual(finished.background, .finished)
            XCTAssertEqual(finished.status, .succeeded)
            XCTAssertEqual(finished.output, "Finished")
            XCTAssertEqual(transcript.items.last?.kind, .taskNotification(summary: "Finished", status: .completed))
        }
    }

    func testBackgroundTaskNotificationUsesEventIdentityAndStatus() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{}}]}}"#))
        transcript.apply(try event(#"{"type":"system","subtype":"task_started","task_id":"task","tool_use_id":"bash","is_backgrounded":true}"#))
        let notification = try event(#"{"type":"system","subtype":"task_notification","task_id":"task","status":"completed","summary":"Background command finished","uuid":"event"}"#)
        transcript.apply(notification)
        transcript.apply(notification)
        XCTAssertEqual(transcript.items.count, 2)
        guard case let .toolCall(tool) = transcript.items[0].kind else { return XCTFail() }
        XCTAssertEqual(tool.background, .finished)
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertEqual(transcript.items[1].id, "task-notification:event")
        XCTAssertEqual(transcript.items[1].kind, .taskNotification(summary: "Background command finished", status: .completed))

        for (raw, expected) in [("failed", AgentChatItem.TaskNotificationStatus.failed), ("stopped", .stopped), ("unknown", .failed)] {
            var withoutTool = ClaudeCodeTranscript()
            let event = try event("{\"type\":\"system\",\"subtype\":\"task_notification\",\"task_id\":\"task\",\"run_id\":\"run\",\"status\":\"\(raw)\",\"summary\":\"Done\"}")
            withoutTool.apply(event)
            withoutTool.apply(event)
            XCTAssertEqual(withoutTool.items.count, 1)
            XCTAssertEqual(withoutTool.items[0].id, "task-notification:task:run:\(raw)")
            XCTAssertEqual(withoutTool.items[0].kind, .taskNotification(summary: "Done", status: expected))
        }
    }

    func testTaskNotificationRequiresBackgroundTaskAndSummary() throws {
        var transcript = ClaudeCodeTranscript()
        for json in [
            #"{"type":"system","subtype":"task_notification","task_id":"task","is_backgrounded":false,"summary":"Foreground"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"task","summary":""}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"task"}"#,
            #"{"type":"system","subtype":"task_notification","summary":"Missing task"}"#
        ] {
            transcript.apply(try event(json))
        }
        XCTAssertTrue(transcript.items.isEmpty)
    }

    func testPeerReplayUsesRawBodyAndOwnReplayNeverDuplicatesUserOrToolRows() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Own prompt", attachments: [])
        transcript.apply(try event(#"{"type":"user","isReplay":true,"message":{"content":"Own prompt"}}"#))
        transcript.apply(try event(#"{"type":"user","isReplay":true,"message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"ignored"}]}}"#))
        XCTAssertEqual(transcript.items.count, 1)
        let peer = try event(#"{"type":"user","isReplay":true,"isSynthetic":true,"origin":{"kind":"peer","name":"mist-3b","msg_id":"p","body":"Raw **message**\nSecond line"},"message":{"content":"Wrapped message"}}"#)
        transcript.apply(peer)
        transcript.apply(peer)
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items.last?.kind, .peerMessage(name: "mist-3b", body: "Raw **message**\nSecond line"))
        XCTAssertTrue(ClaudeCodeProtocol.arguments(sessionId: "s", launchArguments: []).contains("--replay-user-messages"))
    }

    func testRemoteControlMessagesShowAsUserMessagesOnce() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Own prompt", attachments: [])
        transcript.apply(.result(.object([:])))
        XCTAssertEqual(transcript.status, .idle)
        // Shape captured from a claude -p 2.1.318 session sent a message from claude.ai.
        let remote = try event(#"{"type":"user","message":{"role":"user","content":"remote probe one"},"parent_tool_use_id":null,"uuid":"da4093a2","isReplay":true,"origin":{"kind":"human"}}"#)
        transcript.apply(remote)
        transcript.apply(remote)
        XCTAssertEqual(transcript.status, .running)
        XCTAssertEqual(transcript.items.count, 3)
        XCTAssertEqual(transcript.items.last?.kind, .userMessage(text: "remote probe one", images: []))
        transcript.apply(.assistant(try json(#"{"message":{"id":"m","content":[{"type":"text","text":"Received"}]}}"#)))
        XCTAssertEqual(transcript.items.last?.kind, .assistantText(text: "Received", isStreaming: false))
        XCTAssertEqual(try JSONDecoder().decode([AgentChatItem].self, from: JSONEncoder().encode(transcript.items)), transcript.items)

        let pixel = Data([0x89, 0x50, 0x4E, 0x47])
        transcript.apply(try event(#"{"type":"user","uuid":"b","isReplay":true,"origin":{"kind":"human"},"message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(pixel.base64EncodedString())"}},{"type":"text","text":"With a picture"}]}}"#))
        XCTAssertEqual(transcript.items.last?.kind, .userMessage(text: "With a picture", images: [AgentImageAttachment(data: pixel, mediaType: "image/png")]))
        let count = transcript.items.count
        transcript.apply(try event(#"{"type":"user","uuid":"c","isReplay":true,"message":{"content":[{"type":"text","text":"Queued from Mist"}]}}"#))
        transcript.apply(try event(#"{"type":"user","uuid":"d","isReplay":true,"origin":{"kind":"task-notification"},"message":{"content":"<task-notification/>"}}"#))
        XCTAssertEqual(transcript.items.count, count)
    }

    func testPeerHoldsReleaseAndDropWithoutStartingTurns() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.apply(.result(.object([:])))
        let before = transcript.items.count
        transcript.apply(try event(#"{"type":"system","subtype":"peer_message_hold","state":"held","message_uuid":"p","from_name":"mist-3b"}"#))
        XCTAssertEqual(transcript.items.last?.kind, .notice(text: AgentChatStrings.peerHeld("mist-3b"), level: .info))
        XCTAssertEqual(transcript.status, .idle)
        transcript.apply(try event(#"{"type":"system","subtype":"peer_message_hold","state":"released","message_uuid":"p","from_name":"mist-3b"}"#))
        XCTAssertEqual(transcript.items.count, before)
        transcript.apply(try event(#"{"type":"system","subtype":"peer_message_hold","state":"held","message_uuid":"q","from_name":"mist-4"}"#))
        transcript.apply(try event(#"{"type":"system","subtype":"peer_message_hold","state":"dropped","message_uuid":"q","from_name":"mist-4"}"#))
        XCTAssertEqual(transcript.items.count, before + 1)
        XCTAssertEqual(transcript.items.last?.kind, .notice(text: AgentChatStrings.peerDropped("mist-4"), level: .info))
    }

    func testUsageLimitNoticesNameTheLimitAndShowEachStateOnce() throws {
        var transcript = ClaudeCodeTranscript()
        func limit(_ info: String) throws {
            transcript.apply(try event(#"{"type":"rate_limit_event","rate_limit_info":"# + info + "}"))
        }
        func lastNotice() -> String? {
            if case let .notice(text, .info) = transcript.items.last?.kind { return text }
            return nil
        }
        let weeklyReset = Date(timeIntervalSince1970: 1_793_397_600)
        let resets = AgentChatStrings.usageLimitNotice([], resetsAt: weeklyReset)

        try limit(#"{"status":"allowed","rateLimitType":"five_hour","utilization":0.41}"#)
        XCTAssertTrue(transcript.items.isEmpty)
        try limit(#"{"status":"allowed_warning","resetsAt":1793397600,"rateLimitType":"seven_day","utilization":0.75,"surpassedThreshold":0.75,"unifiedWindows":{"five_hour":{"utilization":0.41,"resetsAt":1793296800,"status":"allowed"}}}"#)
        XCTAssertEqual(lastNotice(), "Weekly limit: \(75.formatted(.percent)) used · \(resets)")
        try limit(#"{"status":"allowed_warning","resetsAt":1793397600,"rateLimitType":"seven_day","utilization":0.76,"surpassedThreshold":0.75}"#)
        XCTAssertEqual(transcript.items.count, 1, "A moving percentage must not repeat the notice")
        try limit(#"{"status":"allowed_warning","resetsAt":1793397600,"rateLimitType":"seven_day","utilization":0.9,"surpassedThreshold":0.9}"#)
        XCTAssertEqual(lastNotice(), "Weekly limit: \(90.formatted(.percent)) used · \(resets)")
        try limit(#"{"status":"rejected","resetsAt":1793397600,"rateLimitType":"seven_day","utilization":1,"surpassedThreshold":1}"#)
        XCTAssertEqual(lastNotice(), "Weekly limit reached · \(resets)")
        try limit(#"{"status":"allowed","resetsAt":1793397600,"rateLimitType":"seven_day","isUsingOverage":true,"overageStatus":"allowed","overageResetsAt":1793491200}"#)
        XCTAssertEqual(lastNotice(), "Weekly limit reached · now using usage credits · \(resets)")
        try limit(#"{"status":"allowed","rateLimitType":"overage","isUsingOverage":true,"overageStatus":"allowed_warning","overageResetsAt":1793491200}"#)
        XCTAssertEqual(lastNotice(), "Usage credit limit: almost reached · " + AgentChatStrings.usageLimitNotice([], resetsAt: Date(timeIntervalSince1970: 1_793_491_200)))
        try limit(#"{"status":"rejected","rateLimitType":"overage","isUsingOverage":true,"overageStatus":"rejected"}"#)
        XCTAssertEqual(lastNotice(), "Usage credit limit reached")
        XCTAssertEqual(transcript.items.count, 6)

        try limit(#"{"status":"allowed","rateLimitType":"five_hour","utilization":0.1}"#)
        XCTAssertEqual(transcript.items.count, 6)
        try limit(#"{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.29}"#)
        XCTAssertEqual(lastNotice(), "5-hour limit: \(29.formatted(.percent)) used")
        try limit(#"{"status":"allowed_warning","resetsAt":1793397600,"rateLimitType":"seven_day","utilization":0.75,"surpassedThreshold":0.75}"#)
        XCTAssertEqual(transcript.items.count, 8, "Usage back under every threshold must warn again")
        try limit(#"{"status":"allowed_warning","rateLimitType":"seven_day_opus","utilization":1.4}"#)
        XCTAssertEqual(lastNotice(), "Weekly Opus limit: \(100.formatted(.percent)) used")
        try limit(#"{"status":"allowed_warning","rateLimitType":"some_new_window"}"#)
        XCTAssertEqual(lastNotice(), "Usage limit: almost reached")
        try limit(#"{"status":"some_new_status","rateLimitType":"seven_day"}"#)
        try limit(#"{}"#)
        transcript.apply(try event(#"{"type":"rate_limit_event"}"#))
        XCTAssertEqual(transcript.items.count, 10, "Unknown or missing statuses add nothing")
        XCTAssertEqual(Set(["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_overage_included", "overage", "other"]
            .map(AgentChatStrings.usageLimitName)).count, 7)
    }

    @MainActor
    func testTitleGenerationFollowsFirstPromptOnceAndIgnoresEmptyOrFailedReplies() throws {
        for response in [#"{"subtype":"success","response":{"title":" Useful title "}}"#,
                         #"{"subtype":"success","response":{"title":" "}}"#,
                         #"{"subtype":"error","error":"Unavailable"}"#] {
            let conversation = AgentConversation(firstPrompt: "Original")
            var sent: [String] = []
            var titles: [String] = []
            conversation.onTitleGenerated = { titles.append($0) }
            let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
            defer { session.close() }
            conversation.update(items: [], status: .idle)
            session.send(text: "Original")
            XCTAssertEqual(try json(sent[0])["type"].string, "user")
            let titleRequest = try json(sent[1])
            XCTAssertEqual(titleRequest["request"], .object(["subtype": .string("generate_session_title"), "description": .string("Original"), "persist": .bool(true)]))
            guard case var .object(reply) = try json(response) else { return XCTFail() }
            reply["request_id"] = titleRequest["request_id"]
            session.receive(.event(.controlResponse(.object(["response": .object(reply)]))))
            XCTAssertEqual(titles, response.contains("Useful title") ? ["Useful title"] : [])
            session.receive(.event(.result(.object([:]))))
            session.send(text: "Next")
            XCTAssertEqual(sent.count, 3)
            XCTAssertEqual(try json(sent[2])["type"].string, "user")
        }
    }

    @MainActor
    func testStartupContextUsageSeedsHeaderUntilLiveUsageArrives() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.initialize()
        let id = try XCTUnwrap(try json(sent[1])["request_id"].string)
        session.receive(.event(.controlResponse(try json(#"{"response":{"subtype":"success","request_id":"\#(id)","response":{"totalTokens":15995,"maxTokens":1000000}}}"#))))
        XCTAssertEqual(conversation.contextTokens, 15995)
        XCTAssertEqual(conversation.contextWindowSize, 1_000_000)
        session.receive(.event(try event(#"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":10,"cache_read_input_tokens":20000},"content":[{"type":"text","text":"Hi"}]}}"#)))
        XCTAssertEqual(conversation.contextTokens, 20010)
        XCTAssertEqual(conversation.contextWindowSize, 1_000_000)
    }

    @MainActor
    func testPerToolBackgroundRequestRequiresForegroundTask() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.initialize()
        conversation.onBackgroundTool?("unknown")
        XCTAssertEqual(sent.count, 2)
        session.receive(.event(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"sleep 25"}}]}}"#)))
        conversation.onBackgroundTool?("tool")
        XCTAssertEqual(sent.count, 2)
        session.receive(.event(try event(#"{"type":"system","subtype":"task_started","task_id":"task","tool_use_id":"tool","is_backgrounded":false}"#)))
        conversation.onBackgroundTool?("tool")
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(try json(sent[2])["type"].string, "control_request")
        XCTAssertEqual(try json(sent[2])["request"]["subtype"].string, "background_tasks")
        XCTAssertEqual(try json(sent[2])["request"]["tool_use_id"].string, "tool")
        XCTAssertNotNil(try json(sent[2])["request_id"].string)
        session.receive(.event(try event(#"{"type":"system","subtype":"task_updated","task_id":"task","patch":{"is_backgrounded":true}}"#)))
        conversation.onBackgroundTool?("tool")
        XCTAssertEqual(sent.count, 3)
        session.close()
        conversation.onBackgroundTool?("tool")
        XCTAssertEqual(sent.count, 3)
    }

    @MainActor
    func testPerTaskStopLeavesTaskRunningUntilNotification() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.initialize()
        XCTAssertEqual(try json(sent[0])["request"]["perTaskStopAffordance"], .bool(true))
        XCTAssertEqual(try json(sent[1])["request"]["subtype"].string, "get_context_usage")
        session.receive(.event(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"sleep 10"}}]}}"#)))
        session.receive(.event(try event(#"{"type":"system","subtype":"task_started","task_id":"task","tool_use_id":"tool","is_backgrounded":true}"#)))
        session.receive(.event(try event(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"task","description":"Research"}]}"#)))
        conversation.onStopTask?("unknown")
        XCTAssertEqual(sent.count, 2)
        conversation.onStopTask?("task")
        XCTAssertEqual(try json(sent[2])["request"]["subtype"].string, "stop_task")
        XCTAssertEqual(try json(sent[2])["request"]["task_id"].string, "task")
        guard case let .toolCall(running) = conversation.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(running.background, .running)
        session.receive(.event(try event(#"{"type":"system","subtype":"task_notification","task_id":"task","status":"stopped","summary":"Stopped"}"#)))
        guard case let .toolCall(stopped) = conversation.items.first?.kind else { return XCTFail() }
        XCTAssertEqual(stopped.background, .finished)
        XCTAssertEqual(stopped.status, .failed)
    }

    func testTurnOutputCountsReplaceEstimatesAndResetForAutomaticTurns() throws {
        var transcript = ClaudeCodeTranscript()
        let start = Date(timeIntervalSince1970: 100)
        transcript.clock = { start }
        transcript.userSent(text: "Go", attachments: [])
        XCTAssertNil(transcript.outputTokens)
        XCTAssertEqual(transcript.turnStartedAt, start)
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"a"}}}"#))
        transcript.apply(try event(#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":40,"estimated_tokens_delta":40}"#))
        transcript.apply(try event(#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":60,"estimated_tokens_delta":20}"#))
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"abcdefgh"}}}"#))
        XCTAssertEqual(transcript.outputTokens, 62)
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":65}}}"#))
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":65}}}"#))
        XCTAssertEqual(transcript.outputTokens, 65)
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"b"}}}"#))
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"12345678"}}}"#))
        XCTAssertEqual(transcript.outputTokens, 67)
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":5}}}"#))
        XCTAssertEqual(transcript.outputTokens, 70)
        transcript.apply(.result(.object([:])))
        transcript.clock = { start.addingTimeInterval(10) }
        transcript.apply(try event(#"{"type":"system","subtype":"init"}"#))
        XCTAssertNil(transcript.outputTokens)
        XCTAssertEqual(transcript.turnStartedAt, start.addingTimeInterval(10))
        transcript.userSent(text: "Again", attachments: [])
        XCTAssertNil(transcript.outputTokens)
    }

    @MainActor
    func testWorkingIndicatorVisibilityAndStableTurnWord() {
        let conversation = AgentConversation()
        XCTAssertTrue(conversation.showsWorkingIndicator)
        let start = Date(timeIntervalSince1970: 100)
        conversation.update(items: [], status: .running, turnStartedAt: start, outputTokens: 12)
        let word = conversation.workingWord
        conversation.update(items: [], status: .running, turnStartedAt: start, outputTokens: 16)
        XCTAssertEqual(conversation.workingWord, word)
        XCTAssertEqual(conversation.outputTokens, 16)
        for status: AgentConversationStatus in [.awaitingPermission, .idle, .ended, .failed("error")] {
            conversation.update(items: [], status: status)
            XCTAssertFalse(conversation.showsWorkingIndicator)
        }
    }

    private func questionRequest(multi: Bool = false) throws -> AgentChatItem.PermissionRequest {
        .init(requestId: "q", toolName: "AskUserQuestion", summary: "Pick a color", input: try json("""
        {"questions":[{"header":"Color","question":"Pick a color","options":[{"label":"Red","description":"Select red"},{"label":"Blue","description":"Select blue"}],"multiSelect":\(multi)}],"extra":"preserved"}
        """), requiresUserInteraction: true)
    }

    func testSingleQuestionAnswerPreservesInput() throws {
        let request = try questionRequest()
        XCTAssertNil(request.answerResponse([:]))
        var selection = AgentPermissionQuestion.Selection()
        selection.toggle(0, multiSelect: false)
        selection.toggle(1, multiSelect: false)
        guard case let .allowWithInput(input) = request.answerResponse([0: selection]) else { return XCTFail("Missing answer") }
        XCTAssertEqual(input["answers"]["Pick a color"].string, "Blue")
        XCTAssertEqual(input["questions"], request.input["questions"])
        XCTAssertEqual(input["extra"].string, "preserved")
    }

    func testMultipleQuestionAnswersAndOther() throws {
        var request = try questionRequest(multi: true)
        var first = AgentPermissionQuestion.Selection()
        first.toggle(1, multiSelect: true)
        first.toggle(0, multiSelect: true)
        first.selectOther(multiSelect: true)
        XCTAssertNil(request.answerResponse([0: first]), "Other needs text")
        first.other = " Green "
        guard case let .allowWithInput(input) = request.answerResponse([0: first]) else { return XCTFail("Missing answer") }
        XCTAssertEqual(input["answers"]["Pick a color"].string, "Red, Blue, Green")
        first.toggle(0, multiSelect: true)
        XCTAssertEqual(request.questions[0].answer(first), "Blue, Green")
        request = try questionRequest()
        first.selectOther(multiSelect: false)
        XCTAssertEqual(request.questions[0].answer(first), "Green")
        if case var .object(object) = request.input {
            object["questions"] = .array(request.input["questions"].array + [.object(["question": .string("Why?")])])
            request.input = .object(object)
        }
        XCTAssertNil(request.answerResponse([0: first]), "Every question needs an answer")
        let second = AgentPermissionQuestion.Selection(otherSelected: true, other: "Because")
        guard case let .allowWithInput(two) = request.answerResponse([0: first, 1: second]) else { return XCTFail("Missing answers") }
        XCTAssertEqual(two["answers"]["Why?"].string, "Because")
    }

    func testPermissionRetainsInputInteractionAndResolution() throws {
        let request = try questionRequest()
        var transcript = ClaudeCodeTranscript()
        transcript.apply(.permission(.object(["request_id": .string("q"), "request": .object([
            "tool_name": .string("AskUserQuestion"), "input": request.input, "requires_user_interaction": .bool(true)
        ])])))
        let response = try XCTUnwrap(request.answerResponse([0: .init(options: [1])]))
        transcript.permissionDecided(requestId: "q", response: response)
        guard case let .permissionRequest(answered) = transcript.items[0].kind else { return XCTFail("Missing request") }
        XCTAssertEqual(answered.input, request.input)
        XCTAssertTrue(answered.requiresUserInteraction)
        XCTAssertEqual(answered.resolution, response)
        XCTAssertEqual(answered.answers["Pick a color"]?.string, "Blue")
        XCTAssertEqual(answered.status, .allowed)
    }

    @MainActor
    func testPermissionCallbackSendsUpdatedInputAndCustomDenialsOnce() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        let request = try questionRequest()
        let responses: [AgentPermissionResponse] = [try XCTUnwrap(request.answerResponse([0: .init(options: [1])])),
            .deny(message: "The user declined to answer."), .deny(message: "Revise the tests"), .allow]
        for (index, response) in responses.enumerated() {
            let id = String(index)
            session.receive(.event(.permission(.object(["request_id": .string(id), "request": .object([
                "tool_name": .string(index == 0 ? "AskUserQuestion" : "ExitPlanMode"), "input": request.input
            ])]))))
            conversation.onPermissionDecision?(id, response)
            conversation.onPermissionDecision?(id, response)
            XCTAssertEqual(sent.count, index + 1)
            let reply = try json(sent[index])["response"]["response"]
            XCTAssertEqual(reply["behavior"].string, response.allows ? "allow" : "deny")
            if case let .deny(message) = response { XCTAssertEqual(reply["message"].string, message) }
            if case let .allowWithInput(input) = response { XCTAssertEqual(reply["updatedInput"], input) }
            guard case let .permissionRequest(item) = conversation.items.last?.kind else { return XCTFail("Missing resolution") }
            XCTAssertEqual(item.resolution, response)
        }
    }

    private func json(_ text: String) throws -> ClaudeCodeJSON {
        try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(text.utf8))
    }

    private func event(_ text: String) throws -> ClaudeCodeEvent {
        try XCTUnwrap(ClaudeCodeProtocol.decode(Data(text.utf8)))
    }

    private func fixture(_ name: String) throws -> [ClaudeCodeEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ClaudeCode/\(name).jsonl")
        return try Data(contentsOf: url).split(separator: 10).map { line in
            try XCTUnwrap(ClaudeCodeProtocol.decode(Data(line)), "Undecodable line in \(name)")
        }
    }

    func testRecordedSingleAndMultiQuestionAnswers() throws {
        var transcript = ClaudeCodeTranscript()
        var sawRequest = false
        for event in try fixture("ask") {
            transcript.apply(event)
            if case .permission = event {
                guard case let .permissionRequest(request) = transcript.items.last?.kind else { return XCTFail("Missing card") }
                XCTAssertEqual(request.toolName, "AskUserQuestion")
                XCTAssertTrue(request.requiresUserInteraction)
                XCTAssertEqual(request.questions.map(\.multiSelect), [false, true])
                let response = try XCTUnwrap(request.answerResponse([0: .init(options: [1]), 1: .init(options: [0, 1])]))
                transcript.permissionDecided(requestId: request.requestId, response: response)
                sawRequest = true
            }
        }
        XCTAssertTrue(sawRequest)
        let tool = try XCTUnwrap(transcript.items.compactMap { item -> AgentChatItem.ToolCall? in
            if case let .toolCall(tool) = item.kind, tool.name == "AskUserQuestion" { return tool }; return nil
        }.first)
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertEqual(tool.structuredResult["answers"]["Pick a color"].string, "Blue")
        XCTAssertEqual(tool.structuredResult["answers"]["Pick features"].string, "Fast, Quiet")
        let summary = ClaudeCodeToolSummary.format(tool: tool.name, input: try json(tool.inputJSON), result: tool.structuredResult, text: tool.output, folder: URL(fileURLWithPath: "/tmp/mist-fixture"))
        XCTAssertEqual(summary.header.text, "AskUserQuestion")
        XCTAssertTrue(summary.summary.isEmpty)
        guard case let .permissionRequest(card) = transcript.items.first(where: { if case .permissionRequest = $0.kind { return true }; return false })?.kind else { return XCTFail("Missing answered card") }
        XCTAssertEqual(card.answers["Pick features"]?.string, "Fast, Quiet")
        XCTAssertEqual(transcript.status, .idle)
    }

    @MainActor
    func testRecordedPlanRecoversMarkdownAndFollowsApprovalMode() throws {
        let conversation = AgentConversation()
        var replies: [ClaudeCodeJSON] = []
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp/mist-fixture")), conversation: conversation, controlWriter: {
            replies.append(try! JSONDecoder().decode(ClaudeCodeJSON.self, from: Data($0.utf8)))
        })
        defer { session.close() }
        var sawPlan = false, sawWrite = false
        for event in try fixture("plan") {
            session.receive(.event(event))
            if case let .permission(value) = event {
                let id = try XCTUnwrap(value["request_id"].string)
                if value["request"]["tool_name"].string == "ExitPlanMode" {
                    XCTAssertEqual(value["request"]["input"], .object([:]), "The recorded CLI strips plan from permission input")
                    guard case let .permissionRequest(card) = conversation.items.last?.kind else { return XCTFail("Missing plan card") }
                    XCTAssertTrue(card.plan?.hasPrefix("# Plan: create hello.txt") == true)
                    XCTAssertEqual(card.summary, "Plan: create hello.txt")
                    conversation.onPermissionDecision?(id, .allow)
                    XCTAssertEqual(replies.last?["response"]["response"]["updatedInput"], .object([:]))
                    sawPlan = true
                } else {
                    XCTAssertEqual(value["request"]["tool_name"].string, "Write")
                    conversation.onPermissionDecision?(id, .deny(message: "Fixture complete. Stop without writing files."))
                    sawWrite = true
                }
            }
        }
        XCTAssertTrue(sawPlan && sawWrite)
        XCTAssertEqual(replies.count, 2)
        let tool = try XCTUnwrap(conversation.items.compactMap { item -> AgentChatItem.ToolCall? in
            if case let .toolCall(tool) = item.kind, tool.name == "ExitPlanMode" { return tool }; return nil
        }.first)
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertTrue(tool.output.hasPrefix("User has approved exiting plan mode."))
        let summary = ClaudeCodeToolSummary.format(tool: tool.name, input: try json(tool.inputJSON), result: tool.structuredResult, text: tool.output, folder: URL(fileURLWithPath: "/tmp/mist-fixture"))
        XCTAssertTrue(summary.summary.isEmpty, "The plan card owns the approval resolution")
        XCTAssertTrue(summary.preview.isEmpty)
        XCTAssertEqual(conversation.status, .idle)
    }

    func testFixtureTranscripts() throws {
        for name in ["text", "permission", "image", "interrupt"] {
            var transcript = ClaudeCodeTranscript()
            transcript.userSent(text: "Fixture", attachments: [])
            var sawStreaming = false
            var sawPermission = false
            var interruptedTextId: String?
            for event in try fixture(name) {
                if name == "interrupt", case .result = event { transcript.stopRequested() }
                transcript.apply(event)
                for item in transcript.items {
                    if case let .assistantText(text, streaming) = item.kind, streaming, !text.isEmpty {
                        sawStreaming = true
                        if name == "interrupt" { interruptedTextId = item.id }
                    }
                }
                if case let .permission(value) = event {
                    XCTAssertEqual(transcript.status, .awaitingPermission)
                    sawPermission = true
                    transcript.permissionDecided(requestId: try XCTUnwrap(value["request_id"].string), response: .allow)
                    XCTAssertEqual(transcript.status, .running)
                }
            }
            XCTAssertTrue(sawStreaming, name)
            XCTAssertEqual(Set(transcript.items.map(\.id)).count, transcript.items.count)
            let textItems = transcript.items.filter { if case .assistantText = $0.kind { return true }; return false }
            XCTAssertEqual(textItems.count, 1, name)
            for item in transcript.items {
                switch item.kind {
                case let .assistantText(_, streaming): XCTAssertFalse(streaming)
                case let .toolCall(tool):
                    XCTAssertEqual(tool.status, .succeeded)
                    XCTAssertEqual(tool.inputSummary, "touch b.txt")
                    XCTAssertEqual(tool.output, "(Bash completed with no output)")
                case let .permissionRequest(request): XCTAssertEqual(request.status, .allowed)
                default: break
                }
            }
            if name == "interrupt" {
                XCTAssertEqual(transcript.status, .idle)
                guard case .turnEnd(_, _, stopped: true) = transcript.items.last?.kind else { return XCTFail("Missing stopped divider") }
                XCTAssertEqual(textItems.first?.id, interruptedTextId)
                XCTAssertEqual(transcript.items.count, 3, "Thinking blocks and stopped notices must not add transcript rows")
            } else { XCTAssertEqual(transcript.status, .idle) }
            if name == "permission" { XCTAssertTrue(sawPermission) }
            if name == "text" { XCTAssertEqual(textItems.first?.kind, .assistantText(text: "Mist fixture ready.", isStreaming: false)) }
            if name == "image" { XCTAssertEqual(textItems.first?.kind, .assistantText(text: "Red", isStreaming: false)) }
            XCTAssertEqual(transcript.items.filter { if case .turnEnd = $0.kind { return true }; return false }.count, 1)
        }
    }

    func testUserAndImageEncoding() throws {
        let image = AgentImageAttachment(data: Data([1, 2, 3]), mediaType: "image/png")
        XCTAssertEqual(try json(ClaudeCodeProtocol.user(text: "hello\nworld", attachments: [.image(image)])),
                       try json(#"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}},{"type":"text","text":"hello\nworld"}]}}"#))
        XCTAssertEqual(try json(ClaudeCodeProtocol.user(text: "hello", attachments: [])),
                       try json(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#))
    }


    func testTurnErrorAllowsRetryAndStopDoesNotLeakIntoNextTurn() throws {
        var transcript = ClaudeCodeTranscript()
        let failure = try event(#"{"type":"result","is_error":true,"result":"Try again","duration_ms":12}"#)
        transcript.userSent(text: "one", attachments: [])
        transcript.stopRequested()
        transcript.apply(failure)
        XCTAssertEqual(transcript.status, .idle)
        guard case .turnEnd(_, _, stopped: true) = transcript.items.last?.kind else { return XCTFail("Missing stopped divider") }
        transcript.userSent(text: "two", attachments: [])
        XCTAssertEqual(transcript.status, .running)
        transcript.apply(failure)
        XCTAssertEqual(transcript.status, .idle)
        XCTAssertEqual(transcript.items.last?.kind, .notice(text: "Try again", level: .error))
        transcript.processExited(expected: false, stderr: "crash")
        guard case .failed = transcript.status else { return XCTFail("Process failures must end the session") }
    }

    func testControlEncoding() throws {
        XCTAssertEqual(try json(ClaudeCodeProtocol.initialize(requestId: "i", perTaskStopAffordance: true))["request"]["perTaskStopAffordance"], .bool(true))
        XCTAssertEqual(try json(ClaudeCodeProtocol.initialize(requestId: "probe"))["request"]["perTaskStopAffordance"], .null)
        XCTAssertEqual(try json(ClaudeCodeProtocol.stopTask("task", requestId: "s")),
            try json(#"{"type":"control_request","request_id":"s","request":{"subtype":"stop_task","task_id":"task"}}"#))
        let input = try json(#"{"command":"touch b.txt","nested":{"safe":true}}"#)
        XCTAssertEqual(try json(ClaudeCodeProtocol.permission(requestId: "p", allow: true, input: input)),
                       try json(#"{"type":"control_response","response":{"subtype":"success","request_id":"p","response":{"behavior":"allow","updatedInput":{"command":"touch b.txt","nested":{"safe":true}}}}}"#))
        XCTAssertEqual(try json(ClaudeCodeProtocol.permission(requestId: "p", allow: false, input: input)),
                       try json(#"{"type":"control_response","response":{"subtype":"success","request_id":"p","response":{"behavior":"deny","message":"The user denied this action."}}}"#))
        XCTAssertEqual(try json(ClaudeCodeProtocol.interrupt(requestId: "i")),
                       try json(#"{"type":"control_request","request_id":"i","request":{"subtype":"interrupt"}}"#))
        XCTAssertEqual(try json(ClaudeCodeProtocol.unsupported(requestId: "u")),
                       try json(#"{"type":"control_response","response":{"subtype":"error","request_id":"u","error":"Unsupported by Mist"}}"#))
    }

    func testArgumentsAndUnknownInput() throws {
        let arguments = ["--model", "sonnet", "--effort", "low", "--permission-mode", "default"]
        let expected = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--replay-user-messages", "--verbose", "--permission-prompt-tool", "stdio", "--allow-dangerously-skip-permissions"]
        XCTAssertEqual(ClaudeCodeProtocol.arguments(sessionId: "new", launchArguments: arguments), expected + ["--session-id", "new"] + arguments)
        XCTAssertEqual(ClaudeCodeProtocol.arguments(sessionId: "old", resume: true, launchArguments: arguments), expected + ["--resume", "old"] + arguments)
        for value in ["not json", "[]", #"{"type":"future"}"#, #"{"type":"control_request"}"#] {
            XCTAssertNil(ClaudeCodeProtocol.decode(Data(value.utf8)))
        }
        XCTAssertEqual(try event(#"{"type":"control_request","request_id":"u","request":{"subtype":"future"}}"#), .unsupportedControl(requestId: "u"))
    }

    func testStreamingReconciliationAndToolResults() throws {
        var transcript = ClaudeCodeTranscript()
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Thinking"}}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"thinking","thinking":"Thought"}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Draft"}}}"#,
        ]
        for line in lines { transcript.apply(try event(line)) }
        let ids = transcript.items.map(\.id)
        XCTAssertEqual(transcript.items.map(\.kind), [.assistantText(text: "Draft", isStreaming: true)])
        transcript.apply(try event(#"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"Final"}]}}"#))
        transcript.apply(try event(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"late"}}}"#))
        XCTAssertEqual(transcript.items.map(\.id), ids)
        XCTAssertEqual(transcript.items.last?.kind, .assistantText(text: "Final", isStreaming: false))
        transcript.apply(try event(#"{"type":"assistant","message":{"id":"t","content":[{"type":"tool_use","id":"tool","name":"Read","input":{}}]}}"#))
        XCTAssertEqual(transcript.items.count, 2)
        transcript.apply(try event(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":[{"type":"text","text":"first"},{"type":"image"},{"type":"text","text":"second"}],"is_error":true}]}}"#))
        guard case let .toolCall(finished) = transcript.items.last?.kind else { return XCTFail("Missing tool") }
        XCTAssertEqual(finished.output, "first\nsecond")
        XCTAssertEqual(finished.status, .failed)
    }

    func testPermissionsNoticesAndProcessExit() throws {
        var transcript = ClaudeCodeTranscript()
        for id in ["one", "two"] {
            transcript.apply(.permission(.object(["request_id": .string(id), "request": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("touch b.txt")])])])))
        }
        transcript.permissionDecided(requestId: "one", response: .deny(message: nil))
        XCTAssertEqual(transcript.status, .awaitingPermission)
        transcript.permissionDecided(requestId: "unknown", response: .allow)
        XCTAssertEqual(transcript.status, .awaitingPermission)
        transcript.permissionDecided(requestId: "two", response: .allow)
        XCTAssertEqual(transcript.status, .running)
        transcript.apply(try event(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#))
        XCTAssertEqual(transcript.items.count, 2)
        transcript.apply(try event(#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#))
        XCTAssertEqual(transcript.items.count, 3)
        transcript.processExited(expected: false, stderr: "diagnostic tail")
        guard case let .failed(message) = transcript.status else { return XCTFail("Expected failure") }
        XCTAssertTrue(message.hasSuffix("diagnostic tail"))
        transcript.processExited(expected: true, stderr: "")
        XCTAssertEqual(transcript.status, .ended)
    }

    func testToolInputSummaries() throws {
        for (tool, key) in [("Bash", "command"), ("Read", "file_path"), ("Edit", "file_path"), ("Write", "file_path"), ("NotebookEdit", "file_path"), ("WebFetch", "url"), ("WebSearch", "query"), ("Grep", "pattern"), ("Glob", "pattern")] {
            XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: tool, input: .object([key: .string("a\nb")])), "a b")
        }
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Other", input: try json(#"{"b":2,"a":1}"#)), #"{"a":1,"b":2}"#)
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Other", input: .string(String(repeating: "a", count: 300))).count, 200)
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Monitor", input: try json(#"{"description":"Watch logs","command":"tail -f log"}"#)), "Watch logs")
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Monitor", input: try json(#"{"command":"tail -f log"}"#)), "tail -f log")
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Monitor", input: try json(#"{"description":"","command":"tail -f log"}"#)), "tail -f log")
        XCTAssertEqual(ClaudeCodeProtocol.inputSummary(tool: "Monitor", input: .object([:])), "")
    }

    func testRecordedBackgroundTaskSetAndToolLifecycle() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Fixture", attachments: [])
        var started = Set<String>()
        var completed = Set<String>()
        var sawOverlap = false
        var sawIdleWithBackgroundWork = false
        for event in try fixture("background") {
            transcript.apply(event)
            if case let .system(value) = event {
                let id = value["task_id"].string ?? ""
                switch value["subtype"].string {
                case "background_tasks_changed":
                    XCTAssertEqual(transcript.backgroundTasks.map(\.id), value["tasks"].array.compactMap { $0["task_id"].string })
                    XCTAssertEqual(transcript.backgroundTasks.map(\.description), value["tasks"].array.compactMap { $0["description"].string })
                    sawOverlap = sawOverlap || transcript.backgroundTasks.count == 2
                case "task_started", "task_notification":
                    let toolId = try XCTUnwrap(value["tool_use_id"].string)
                    let tool = try XCTUnwrap(transcript.items.compactMap { item -> AgentChatItem.ToolCall? in
                        if case let .toolCall(tool) = item.kind, tool.toolUseId == toolId { return tool }; return nil
                    }.first)
                    if value["subtype"].string == "task_started" {
                        started.insert(id)
                        XCTAssertEqual(tool.status, .running)
                        XCTAssertEqual(tool.background, .running)
                        let task = try XCTUnwrap(transcript.backgroundTasks.first { $0.id == id })
                        XCTAssertEqual(task.kind, tool.name == "Monitor" ? .monitor : .shell)
                    } else {
                        completed.insert(id)
                        XCTAssertEqual(tool.background, .finished)
                        XCTAssertEqual(tool.status, .succeeded)
                        XCTAssertEqual(tool.output, value["summary"].string)
                        XCTAssertEqual(transcript.items.last?.kind, .taskNotification(summary: try XCTUnwrap(value["summary"].string), status: .completed))
                    }
                default: break
                }
            }
            if transcript.status == .idle, !transcript.backgroundTasks.isEmpty {
                sawIdleWithBackgroundWork = true
                for item in transcript.items {
                    if case let .toolCall(tool) = item.kind, tool.background == .running { XCTAssertEqual(tool.status, .running) }
                }
            }
        }
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(started, completed)
        XCTAssertTrue(sawOverlap)
        XCTAssertTrue(sawIdleWithBackgroundWork)
        XCTAssertTrue(transcript.backgroundTasks.isEmpty)
    }

    func testRecordedAutomaticTurnsBecomeRunning() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Fixture", attachments: [])
        var restarts = 0
        var taskResults = 0
        for event in try fixture("background") {
            let wasIdle = transcript.status == .idle
            transcript.apply(event)
            if case let .system(value) = event, value["subtype"].string == "init", wasIdle {
                XCTAssertEqual(transcript.status, .running)
                restarts += 1
            }
            if case let .result(value) = event {
                XCTAssertEqual(transcript.status, .idle)
                if value["origin"]["kind"].string == "task-notification" { taskResults += 1 }
            }
        }
        XCTAssertEqual(restarts, 4, "Second user prompt plus three CLI-initiated turns")
        XCTAssertEqual(taskResults, 3)
    }

    func testAutomaticTurnsAlsoStartWithoutInit() throws {
        let events = try fixture("background")
        let assistant = try XCTUnwrap(events.first { if case .assistant = $0 { return true }; return false })
        let stream = try XCTUnwrap(events.first { if case .stream = $0 { return true }; return false })
        for event in [assistant, stream] {
            var transcript = ClaudeCodeTranscript()
            transcript.apply(.result(.null))
            transcript.apply(event)
            XCTAssertEqual(transcript.status, .running)
            transcript.apply(.result(.null))
            XCTAssertEqual(transcript.status, .idle)
            transcript.apply(.permission(try json(#"{"request_id":"p","request":{"tool_name":"Bash"}}"#)))
            transcript.apply(event)
            XCTAssertEqual(transcript.status, .awaitingPermission)
        }
    }

    func testBackgroundTasksClearAtSessionEndAndFailure() throws {
        var running = ClaudeCodeTranscript()
        for event in try fixture("background") {
            running.apply(event)
            if running.backgroundTasks.count == 2 { break }
        }
        XCTAssertFalse(running.backgroundTasks.isEmpty)
        for ending in 0..<3 {
            var transcript = running
            if ending == 0 { transcript.fail("Failed") }
            else { transcript.processExited(expected: ending == 1, stderr: "") }
            XCTAssertTrue(transcript.backgroundTasks.isEmpty)
            for item in transcript.items {
                if case let .toolCall(tool) = item.kind { XCTAssertNotEqual(tool.status, .running) }
            }
        }
    }

    @MainActor
    func testSessionPublishesBackgroundTasksAndLocalizedCounts() throws {
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation, controlWriter: { _ in })
        defer { session.close() }
        for event in try fixture("background") {
            session.receive(.event(event))
            if conversation.backgroundTasks.count == 2,
               conversation.backgroundTasks.contains(where: { $0.kind == .monitor }) { break }
        }
        XCTAssertEqual(AgentChatStrings.backgroundCount(conversation.backgroundTasks), "1 shell · 1 monitor")
        let tasks: [AgentBackgroundTask] = [.init(id: "s", kind: .shell, description: "Shell"),
            .init(id: "m1", kind: .monitor, description: "Monitor one"), .init(id: "m2", kind: .monitor, description: "Monitor two"),
            .init(id: "t", kind: .task, description: "Other")]
        XCTAssertEqual(AgentChatStrings.backgroundCount(tasks), "1 shell · 2 monitors · 1 task")
        XCTAssertEqual(AgentChatStrings.backgroundCount([]), "")
        session.close()
        XCTAssertTrue(conversation.backgroundTasks.isEmpty)
        XCTAssertEqual(conversation.status, .ended)
    }

    func testFinishTimeUsesInjectedClock() throws {
        let time = Date(timeIntervalSince1970: 123456789)
        var transcript = ClaudeCodeTranscript()
        transcript.clock = { time }
        transcript.apply(try event(#"{"type":"result","duration_ms":2300}"#))
        XCTAssertEqual(transcript.items.last?.kind, .turnEnd(durationMilliseconds: 2300, finishedAt: time))
    }

    func testMultipleResultsDoNotShareStructuredData() throws {
        var transcript = ClaudeCodeTranscript()
        for id in ["one", "two"] {
            transcript.apply(.assistant(.object(["message": .object(["id": .string(id), "content": .array([
                .object(["type": .string("tool_use"), "id": .string(id), "name": .string("Bash"), "input": .object([:])])
            ])])])))
        }
        transcript.apply(try event(#"{"type":"user","tool_use_result":{"stdout":"ambiguous"},"message":{"content":[{"type":"tool_result","tool_use_id":"one","content":"first"},{"type":"tool_result","tool_use_id":"two","content":"second"}]}}"#))
        let tools = transcript.items.compactMap { item -> AgentChatItem.ToolCall? in
            if case let .toolCall(tool) = item.kind { return tool }; return nil
        }
        XCTAssertEqual(tools.map(\.output), ["first", "second"])
        XCTAssertEqual(tools.map(\.structuredResult), [.null, .null])
    }

    func testEnvironmentParsingFallbackAndLookup() {
        let data = Data("PATH=/custom/bin:/usr/bin\0VALUE=one=two\0EMPTY=\0CLAUDECODE=1\0CLAUDE_CODE_ENTRYPOINT=sdk\0CLAUDE_API_KEY=keep\0invalid\0".utf8)
        let variables = ClaudeCodeEnvironment.parse(data)
        XCTAssertEqual(variables, ["PATH": "/custom/bin:/usr/bin", "VALUE": "one=two", "EMPTY": "", "CLAUDE_API_KEY": "keep"])
        let home = URL(fileURLWithPath: "/test")
        var checked: [String] = []
        let executable = ClaudeCodeEnvironment.findExecutable(environment: variables, home: home) {
            checked.append($0)
            return $0 == "/test/.local/bin/claude"
        }
        XCTAssertEqual(executable?.path, "/test/.local/bin/claude")
        XCTAssertEqual(checked, ["/custom/bin/claude", "/usr/bin/claude", "/test/.local/bin/claude"])
        let fallback = ClaudeCodeEnvironment.capture(shell: "/fake/fish", home: home, appEnvironment: ["PATH": "/bin", "CLAUDECODE": "1"], runShell: { _ in nil }, isExecutable: { $0 == "/opt/homebrew/bin/claude" })
        XCTAssertEqual(fallback.variables["PATH"], "/test/.local/bin:/opt/homebrew/bin:/usr/local/bin:/bin")
        XCTAssertNil(fallback.variables["CLAUDECODE"])
        XCTAssertEqual(fallback.executable?.path, "/opt/homebrew/bin/claude")
        let captured = ClaudeCodeEnvironment.capture(shell: "/fake/fish", home: home, appEnvironment: [:], runShell: { shell in
            XCTAssertEqual(shell, "/fake/fish")
            return data
        }, isExecutable: { $0 == "/custom/bin/claude" })
        XCTAssertEqual(captured.variables, variables)
        XCTAssertEqual(captured.executable?.path, "/custom/bin/claude")
        XCTAssertNil(ClaudeCodeEnvironment.findExecutable(environment: [:], home: home, isExecutable: { _ in false }))
    }

    func testLineBufferHandlesPartialUTF8AndFinalLine() {
        let bytes = Data("first\nこんにちは\nlast".utf8)
        var buffer = ClaudeCodeLineBuffer()
        var lines: [String] = []
        for byte in bytes { lines += buffer.append(Data([byte])).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(lines, ["first", "こんにちは"])
        XCTAssertEqual(buffer.finish(), Data("last".utf8))
        XCTAssertNil(buffer.finish())
    }

    func testProcessDrainsOutputAndCapsStderr() async throws {
        let process = try ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'invalid\\n{\"type\":'; printf '\"system\",\"subtype\":\"init\"}\\n'; head -c 9000 /dev/zero | tr '\\0' x >&2; printf END >&2"],
            folder: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        var events = 0
        var exited = false
        for await output in process.output {
            switch output {
            case .event: events += 1; XCTAssertFalse(exited)
            case let .exited(code, stderr):
                exited = true
                XCTAssertEqual(code, 0)
                XCTAssertEqual(stderr.utf8.count, 8192)
                XCTAssertTrue(stderr.hasSuffix("END"))
                XCTAssertEqual(events, 1)
            case .writeFailed: XCTFail("Unexpected write")
            }
        }
        XCTAssertTrue(exited)
    }

    func testTerminationEscalatesForUncooperativeProcess() async throws {
        let process = try ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf '{\"type\":\"system\",\"subtype\":\"init\"}\\n'; while :; do sleep 0.1; done"],
            folder: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
        let started = Date()
        var exited = false
        for await output in process.output {
            switch output {
            case .event: process.terminate()
            case let .exited(code, _): exited = true; XCTAssertEqual(code, 9)
            default: break
            }
        }
        XCTAssertTrue(exited)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3.9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    @MainActor
    func testConversationTitleAndMissingExecutable() async throws {
        let conversation = AgentConversation(firstPrompt: String(repeating: "a", count: 70) + "\nignored")
        XCTAssertEqual(conversation.title.count, 60)
        let request = ClaudeCodeLaunchRequest(prompt: "hello", attachments: [], config: .init(folder: FileManager.default.temporaryDirectory), launchArguments: [])
        let session = ClaudeCodeSession(request: request, conversation: conversation, environment: { .init(variables: [:], executable: nil) })
        for _ in 0..<100 where conversation.status == .starting { try await Task.sleep(nanoseconds: 10_000_000) }
        guard case let .failed(message) = conversation.status else { return XCTFail("Missing executable should fail") }
        XCTAssertEqual(message, "Claude Code wasn't found. Install it, then try again.")
        XCTAssertEqual(conversation.items.count, 1)
        session.close()
        XCTAssertEqual(conversation.status, .ended)
    }

    @MainActor
    func testCloseDuringEnvironmentResolutionDoesNotLaunch() async throws {
        let conversation = AgentConversation()
        let request = ClaudeCodeLaunchRequest(prompt: "hello", attachments: [], config: .init(folder: FileManager.default.temporaryDirectory), launchArguments: [])
        let session = ClaudeCodeSession(request: request, conversation: conversation, environment: {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .init(variables: [:], executable: URL(fileURLWithPath: "/must/not/launch"))
        })
        session.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(conversation.status, .ended)
        XCTAssertTrue(conversation.items.isEmpty)
    }
}
