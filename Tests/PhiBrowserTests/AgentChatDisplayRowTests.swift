import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentChatDisplayRowTests: XCTestCase {
    func testSlackKindsAndGroupStrings() {
        let kinds: [(String, AgentChatToolGroupKind)] = [
            ("slack_search_public", .slackSearch), ("slack_search_public_and_private", .slackSearch), ("slack_search_emojis", .slackSearch),
            ("slack_read_channel", .slackRead), ("slack_read_thread", .slackRead), ("slack_read_canvas", .slackRead),
            ("slack_list_channel_members", .slackRead), ("slack_list_user_channels", .slackRead), ("slack_get_reactions", .slackRead),
            ("slack_send_message", .slackSend), ("slack_schedule_message", .slackSend), ("slack_add_reaction", .slackChange),
            ("slack_complete_file_upload", .slackChange),
            ("slack_create_canvas", .slackChange), ("slack_future_tool", .slackChange)]
        for (name, kind) in kinds { XCTAssertEqual(AgentChatToolGroupKind("mcp__mistbrowser__" + name), kind) }
        for (kind, running, done) in [(AgentChatToolGroupKind.slackRead, "reading Slack", "read Slack"),
            (.slackSearch, "searching Slack", "searched Slack"), (.slackChange, "using Slack", "used Slack")] {
            for count in [1, 2] {
                let suffix = count == 1 ? " 1 time" : " 2 times"
                XCTAssertEqual(AgentChatStrings.toolGroup(kind, count: count, running: true), running + suffix)
                XCTAssertEqual(AgentChatStrings.toolGroup(kind, count: count), done + suffix)
            }
        }
        XCTAssertEqual(AgentChatStrings.toolGroup(.slackSend, count: 1, running: true), "sending 1 Slack message")
        XCTAssertEqual(AgentChatStrings.toolGroup(.slackSend, count: 2, running: true), "sending 2 Slack messages")
        XCTAssertEqual(AgentChatStrings.toolGroup(.slackSend, count: 1), "sent 1 Slack message")
        XCTAssertEqual(AgentChatStrings.toolGroup(.slackSend, count: 2), "sent 2 Slack messages")
        var tools = ["slack_read_channel", "slack_send_message"].map {
            AgentChatItem.ToolCall(toolUseId: $0, name: "mcp__mistbrowser__" + $0, inputSummary: "", inputJSON: "{}", status: .failed)
        }
        XCTAssertEqual(AgentChatToolGroupKind.status(tools), .failed)
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Couldn't complete 2 Slack actions")
        tools[1].status = .succeeded
        tools[1].permissionDenied = true
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Couldn't complete 2 Slack actions")
        tools[0].status = .succeeded
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Read Slack 1 time, 1 action denied")
        let deniedShell = ["a", "b"].map {
            var tool = AgentChatItem.ToolCall(toolUseId: $0, name: "Bash", inputSummary: "", inputJSON: "{}", status: .failed)
            tool.permissionDenied = true
            return tool
        }
        XCTAssertEqual(AgentChatToolGroupKind.summary(deniedShell).text, "2 actions denied")
        tools[1].permissionDenied = false
        XCTAssertEqual(AgentChatToolGroupKind.status(tools), .succeeded)
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Read Slack 1 time, sent 1 Slack message")
    }
    func testCachedRowsMatchAcrossUpdates() {
        let cwd = URL(fileURLWithPath: "/project")
        let cache = AgentChatDisplayRowCache()
        var call = memoryTool("Write", path: "memory/a")
        let input = ClaudeCodeJSON.object(["file_path": .string("memory/a")])
        let request = AgentChatItem(id: "request", kind: .permissionRequest(.init(requestId: "request", toolName: "Write", summary: "", input: input, status: .allowed)))
        var items = [request]
        let empty = AgentMemoryFiles.none
        let memory = AgentMemoryFiles(folders: [cwd.appendingPathComponent("memory")])
        func check(_ memory: AgentMemoryFiles, _ cwd: URL) {
            XCTAssertEqual(AgentChatDisplayRow.rows(from: items, memory: memory, cwd: cwd, cache: cache),
                           AgentChatDisplayRow.rows(from: items, memory: memory, cwd: cwd))
        }
        check(empty, cwd)
        items.append(.init(id: "call", kind: .toolCall(call)))
        check(empty, cwd)
        check(memory, cwd)
        call.inputJSON = ClaudeCodeJSON.object(["file_path": .string("other")]).json()
        items[1] = .init(id: "call", kind: .toolCall(call))
        check(memory, cwd)
        check(memory, URL(fileURLWithPath: "/elsewhere"))
        check(empty, cwd)
        items.append(tool("other"))
        check(memory, cwd)
    }
    private func memoryTool(_ name: String, path: String, status: AgentChatItem.ToolStatus = .succeeded) -> AgentChatItem.ToolCall {
        .init(toolUseId: UUID().uuidString, name: name, inputSummary: path,
              inputJSON: ClaudeCodeJSON.object(["file_path": .string(path)]).json(), status: status)
    }

    func testMemoryWritesGroupWithReadsAndShellWhileOtherWritesStayStandalone() {
        let cwd = URL(fileURLWithPath: "/project", isDirectory: true)
        let memory = AgentMemoryFiles(folders: [cwd.appendingPathComponent("memory", isDirectory: true)])
        let writes = ["Write", "Edit", "MultiEdit"].map { memoryTool($0, path: "memory/\($0).md") }
        let read = memoryTool("Read", path: "memory/MEMORY.md")
        let calls = [read] + writes + [memoryTool("Bash", path: "")]
        let items = calls.map { AgentChatItem(id: $0.toolUseId, kind: .toolCall($0)) }
        XCTAssertEqual(AgentChatDisplayRow.rows(from: items, memory: memory, cwd: cwd), [.toolGroup(calls)])
        XCTAssertEqual(AgentChatDisplayRow.rows(from: items).count, 5)
        XCTAssertFalse(memory.contains(read, cwd: cwd))
        for name in ["Write", "Edit", "MultiEdit"] {
            for path in ["other/file.md", "memory-other/file.md", "memory/../file.md", ""] {
                let call = memoryTool(name, path: path)
                XCTAssertFalse(AgentChatDisplayRow.isGroupable(call, memory: memory, cwd: cwd))
            }
        }
        var background = writes[0]
        background.background = .running
        XCTAssertFalse(AgentChatDisplayRow.isGroupable(background, memory: memory, cwd: cwd))
        let line = AgentChatToolGroupKind.summary([memoryTool("Read", path: "notes.md")] + Array(writes.prefix(2)), memory: memory, cwd: cwd)
        XCTAssertEqual(line.text, "Read 1 file, saved 2 memories")
        XCTAssertEqual(line.spans.filter { $0.style == .bold }.map(\.text), ["1", "2"])
        XCTAssertEqual(AgentChatToolGroupKind.summary([writes[0]], memory: memory, cwd: cwd).text, "Saved 1 memory")
        var running = writes[0]; running.status = .running
        XCTAssertEqual(AgentChatToolGroupKind.summary([running], memory: memory, cwd: cwd).text, "Saving 1 memory")
        running.status = .failed
        XCTAssertEqual(AgentChatToolGroupKind.status([running]), .failed)
    }

    func testEmptyAssistantTextShowsNoRow() {
        let reply = AgentChatItem(id: "reply", kind: .assistantText(text: "Still running.", isStreaming: false))
        let end = AgentChatItem(id: "end", kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(timeIntervalSince1970: 0), stopped: false))
        let items = [reply, AgentChatItem(id: "empty", kind: .assistantText(text: "", isStreaming: false)), end,
                     AgentChatItem(id: "blank", kind: .assistantText(text: " \n", isStreaming: false)),
                     AgentChatItem(id: "started", kind: .assistantText(text: "", isStreaming: true))]
        XCTAssertEqual(AgentChatDisplayRow.rows(from: items), [.item(reply), .item(end)])
    }

    func testFileEditShowsOnlyOnceItsPathStreamed() {
        let cwd = URL(fileURLWithPath: "/project", isDirectory: true)
        let memory = AgentMemoryFiles(folders: [cwd.appendingPathComponent("memory", isDirectory: true)])
        let read = memoryTool("Read", path: "memory/MEMORY.md")
        for name in ["Write", "Edit", "MultiEdit"] {
            var edit = AgentChatItem.ToolCall(toolUseId: name, name: name, inputSummary: "", inputJSON: "{}")
            func rows() -> [AgentChatDisplayRow] {
                AgentChatDisplayRow.rows(from: [read, edit].map { AgentChatItem(id: $0.toolUseId, kind: .toolCall($0)) },
                                         memory: memory, cwd: cwd)
            }
            XCTAssertEqual(rows(), [.toolGroup([read])], name)
            edit.inputJSON = ClaudeCodeJSON.object(["file_path": .string("memory/new.md")]).json()
            XCTAssertEqual(rows(), [.toolGroup([read, edit])], name)
            edit.inputJSON = ClaudeCodeJSON.object(["file_path": .string("notes.md")]).json()
            XCTAssertEqual(rows().count, 2, name)
            edit.inputJSON = "{}"
            edit.status = .failed
            XCTAssertEqual(rows().count, 2, "A finished edit shows whatever its input")
        }
    }

    func testMemoryReadsShowAsRecalledMemoriesByTheWriteLabelsPathRule() {
        let cwd = URL(fileURLWithPath: "/agent", isDirectory: true)
        let memory = AgentMemoryFiles(folders: [cwd.appendingPathComponent("memory", isDirectory: true)],
                                      skillFolders: [cwd.appendingPathComponent("skills", isDirectory: true)])
        let read = memoryTool("Read", path: "memory/ema/reference_feature_flags.md")
        XCTAssertTrue(memory.readsMemory(read, cwd: cwd))
        XCTAssertFalse(memory.contains(read, cwd: cwd))
        XCTAssertEqual(AgentChatToolGroupKind.summary([read], memory: memory, cwd: cwd).text, "Recalled 1 memory")
        XCTAssertEqual(AgentChatToolGroupKind.summary([read], cwd: cwd).text, "Read 1 file")
        var running = read; running.status = .running
        XCTAssertEqual(AgentChatToolGroupKind.summary([running], memory: memory, cwd: cwd).text, "Recalling 1 memory")
        let mixed = [read, memoryTool("Read", path: "/agent/notes.md"), memoryTool("Read", path: "/agent/memory/MEMORY.md"),
                     memoryTool("Write", path: "memory/new.md"), memoryTool("Read", path: "/agent/other.md")]
        let line = AgentChatToolGroupKind.summary(mixed, memory: memory, cwd: cwd)
        XCTAssertEqual(line.text, "Recalled 2 memories, read 2 files, saved 1 memory")
        XCTAssertEqual(line.spans.filter { $0.style == .bold }.map(\.text), ["2", "2", "1"])
        let items = mixed.map { AgentChatItem(id: $0.toolUseId, kind: .toolCall($0)) }
        XCTAssertEqual(AgentChatDisplayRow.rows(from: items, memory: memory, cwd: cwd), [.toolGroup(mixed)])
        for path in ["other/file.md", "memory-other/file.md", "memory/../file.md", ""] {
            XCTAssertFalse(memory.readsMemory(memoryTool("Read", path: path), cwd: cwd), path)
        }
        for name in ["Write", "Edit", "Grep"] {
            XCTAssertFalse(memory.readsMemory(memoryTool(name, path: read.inputSummary), cwd: cwd))
        }
        XCTAssertFalse(AgentMemoryFiles(folders: [], skillFolders: [cwd.appendingPathComponent("memory")]).readsMemory(read, cwd: cwd))

        func command(_ actions: [(String, String)], cwd: String = "/elsewhere") -> AgentChatItem.ToolCall {
            var tool = AgentChatItem.ToolCall(toolUseId: UUID().uuidString, name: "Bash", inputSummary: "cat",
                inputJSON: ClaudeCodeJSON.object(["command": .string("cat"), "cwd": .string(cwd)]).json(), status: .succeeded)
            tool.structuredResult = .object(["commandActions": .array(actions.map {
                .object(["type": .string($0.0), "command": .string("cat"), "path": .string($0.1)])
            })])
            return tool
        }
        XCTAssertTrue(memory.readsMemory(command([("read", "/agent/memory/a.md"), ("read", "/agent/memory/b/c.md")]), cwd: cwd))
        XCTAssertTrue(memory.readsMemory(command([("read", "a.md")], cwd: "/agent/memory/ema"), cwd: cwd))
        XCTAssertFalse(memory.readsMemory(command([("read", "memory/a.md")]), cwd: cwd))
        XCTAssertFalse(memory.readsMemory(command([("read", "/agent/memory/a.md"), ("read", "/agent/notes.md")]), cwd: cwd))
        XCTAssertFalse(memory.readsMemory(command([("read", "/agent/memory/a.md"), ("search", "/agent/memory")]), cwd: cwd))
        XCTAssertFalse(memory.readsMemory(command([]), cwd: cwd))
        XCTAssertEqual(AgentChatToolGroupKind.summary([command([("read", "/agent/memory/a.md")])], memory: memory, cwd: cwd).text,
                       "Recalled 1 memory")
    }

    func testSkillReadsGroupAsSkillsOnlyForASkillFolderSKILLFile() {
        let cwd = URL(fileURLWithPath: "/agent", isDirectory: true)
        let files = AgentMemoryFiles(folders: [], skillFolders: [cwd.appendingPathComponent("skills", isDirectory: true)])
        let read = memoryTool("Read", path: "/agent/skills/team/SKILL.md")
        XCTAssertEqual(AgentChatToolGroupKind.summary([read], memory: files, cwd: cwd).text, "Used 1 skill")
        XCTAssertEqual(AgentChatToolGroupKind.summary([read], cwd: cwd).text, "Read 1 file")
        var running = read; running.status = .running
        XCTAssertEqual(AgentChatToolGroupKind.summary([running], memory: files, cwd: cwd).text, "Using 1 skill")
        var failed = read; failed.status = .failed
        XCTAssertEqual(AgentChatToolGroupKind.summary([failed], memory: files, cwd: cwd).text, "Used 1 skill")
        XCTAssertEqual(AgentChatToolGroupKind.summary([memoryTool("Read", path: "skills/team/SKILL.md"), memoryTool("Read", path: "notes.md")],
                                                      memory: files, cwd: cwd).text, "Used 1 skill, read 1 file")
        for path in ["/agent/skills/team/notes.md", "/agent/skills/SKILL.md", "/agent/skills/team/deep/SKILL.md",
                     "/agent/skills-other/team/SKILL.md", "/agent/skills/team/../SKILL.md", ""] {
            XCTAssertFalse(files.readsSkill(memoryTool("Read", path: path), cwd: cwd), path)
        }
        for name in ["Write", "Edit"] {
            let edit = memoryTool(name, path: read.inputSummary)
            XCTAssertFalse(files.readsSkill(edit, cwd: cwd))
            XCTAssertFalse(AgentChatDisplayRow.isGroupable(edit, memory: files, cwd: cwd))
        }

        func command(_ actions: [(String, String)], cwd: String = "/elsewhere") -> AgentChatItem.ToolCall {
            var tool = AgentChatItem.ToolCall(toolUseId: UUID().uuidString, name: "Bash", inputSummary: "cat",
                inputJSON: ClaudeCodeJSON.object(["command": .string("cat"), "cwd": .string(cwd)]).json(), status: .succeeded)
            tool.structuredResult = .object(["commandActions": .array(actions.map {
                .object(["type": .string($0.0), "command": .string("cat"), "path": .string($0.1)])
            })])
            return tool
        }
        XCTAssertTrue(files.readsSkill(command([("read", "/agent/skills/team/SKILL.md")]), cwd: cwd))
        XCTAssertTrue(files.readsSkill(command([("read", "SKILL.md")], cwd: "/agent/skills/team"), cwd: cwd))
        XCTAssertFalse(files.readsSkill(command([("read", "skills/team/SKILL.md")]), cwd: cwd))
        XCTAssertFalse(files.readsSkill(command([("read", "/agent/skills/team/SKILL.md"), ("read", "/agent/notes.md")]), cwd: cwd))
        XCTAssertFalse(files.readsSkill(command([("read", "/agent/skills/team/SKILL.md"), ("unknown", "")]), cwd: cwd))
        XCTAssertFalse(files.readsSkill(command([]), cwd: cwd))
    }

    func testMemoryMatcherUsesBothSymlinkAndTargetAndExpandsTilde() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let link = directory.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let memory = AgentMemoryFiles(folders: [link])
        for folder in [link, link.resolvingSymlinksInPath()] {
            XCTAssertTrue(memory.contains(memoryTool("Write", path: folder.appendingPathComponent("file.md").path), cwd: directory))
            XCTAssertTrue(memory.contains(memoryTool("Edit", path: folder.path), cwd: directory))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(AgentMemoryFiles(folders: [home.appendingPathComponent("memory")])
            .contains(memoryTool("Write", path: "~/memory/file.md"), cwd: directory))
        var malformed = memoryTool("Write", path: target.path)
        malformed.inputJSON = "{"
        XCTAssertFalse(memory.contains(malformed, cwd: directory))
    }

    func testDecidedToolCardsDisappearOnlyWhenTheirMatchingToolIsPresent() {
        for name in ["Bash", "mcp__mistbrowser__click"] {
            let call = AgentChatItem(id: "tool", kind: .toolCall(.init(toolUseId: "t", name: name, inputSummary: "", inputJSON: "{\n\"a\":1,\"b\":2\n}")))
            let input = ClaudeCodeJSON.object(["b": .number(2), "a": .number(1)])
            let pending = AgentChatItem.PermissionRequest(requestId: "p", toolName: name, summary: "", input: input)
            XCTAssertEqual(AgentChatDisplayRow.rows(from: [call, .init(id: "p", kind: .permissionRequest(pending))]).count, 2)
            for status in [AgentChatItem.PermissionStatus.allowed, .denied] {
                var request = pending; request.status = status
                let card = AgentChatItem(id: "p", kind: .permissionRequest(request))
                XCTAssertEqual(AgentChatDisplayRow.rows(from: [call, card]).count, 1)
                XCTAssertEqual(AgentChatDisplayRow.rows(from: [card]), [.item(card)])
                request.input = .object(["b": .number(2), "a": .number(1), "__artifactConsentAskCanReachUser": .bool(true)])
                XCTAssertEqual(AgentChatDisplayRow.rows(from: [call, .init(id: "p", kind: .permissionRequest(request))]).count, 1,
                               "The CLI's hidden fields don't count")
                request.input = .object(["different": .bool(true)])
                XCTAssertEqual(AgentChatDisplayRow.rows(from: [call, .init(id: "p", kind: .permissionRequest(request))]).count, 2)
            }
        }
        for name in ["AskUserQuestion", "ExitPlanMode"] {
            let request = AgentChatItem.PermissionRequest(requestId: "p", toolName: name, summary: "", input: .object([:]), status: .allowed)
            XCTAssertEqual(AgentChatDisplayRow.rows(from: [tool("t", name), .init(id: "p", kind: .permissionRequest(request))]).count, 2)
        }
    }

    func testWaitingStatusDescribesPendingQuestionsAndPlans() {
        func permission(_ name: String, _ status: AgentChatItem.PermissionStatus = .pending) -> AgentChatItem {
            .init(id: name, kind: .permissionRequest(.init(requestId: name, toolName: name, summary: "", status: status)))
        }
        XCTAssertEqual(AgentChatStrings.waiting(for: [permission("Bash")]), "Waiting for permission")
        XCTAssertEqual(AgentChatStrings.waiting(for: [permission("ExitPlanMode")]), "Waiting for plan approval")
        XCTAssertEqual(AgentChatStrings.waiting(for: [permission("Bash"), permission("AskUserQuestion")]), "Waiting for your answer")
        XCTAssertEqual(AgentChatStrings.waiting(for: [permission("AskUserQuestion", .allowed)]), "Waiting for permission")
    }

    private func tool(_ id: String, _ name: String = "Bash", status: AgentChatItem.ToolStatus = .succeeded,
                      background: AgentChatItem.BackgroundState? = nil) -> AgentChatItem {
        .init(id: "item-" + id, kind: .toolCall(.init(toolUseId: id, name: name, inputSummary: "", inputJSON: "{}", status: status, background: background)))
    }

    func testGroupsOnlyConsecutiveRunsAndKeepsFirstToolIdentityWhileGrowing() {
        let first = tool("a"), second = tool("b"), third = tool("c", "Read")
        let single = AgentChatDisplayRow.rows(from: [first])
        guard case let .toolGroup(tools) = single.first else { return XCTFail("Single calls must collapse") }
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Ran 1 shell command")
        let group = AgentChatDisplayRow.rows(from: [first, second])
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group.first?.id, "a")
        XCTAssertEqual(AgentChatDisplayRow.rows(from: [first, second, third]).first?.id, "a")
        let text = AgentChatItem(id: "text", kind: .assistantText(text: "Done", isStreaming: false))
        let separated = AgentChatDisplayRow.rows(from: [first, text, second])
        XCTAssertEqual(separated.map(\.id), ["a", "text", "b"])
        XCTAssertEqual(separated[1], .item(text))
    }

    func testExcludedToolsAndBackgroundSplitRunsWhileFailuresStayGrouped() {
        for name in ["Edit", "MultiEdit", "Write", "NotebookEdit", "AskUserQuestion", "ExitPlanMode"] {
            XCTAssertEqual(AgentChatDisplayRow.rows(from: [tool("a"), tool("b", name), tool("c")]).count, 3, name)
        }
        for background in [AgentChatItem.BackgroundState.running, .finished] {
            XCTAssertEqual(AgentChatDisplayRow.rows(from: [tool("a"), tool("b", background: background), tool("c")]).count, 3)
        }
        let items = [tool("a"), tool("b"), tool("c", status: .failed), tool("d"), tool("e")]
        let rows = AgentChatDisplayRow.rows(from: items)
        XCTAssertEqual(rows.map(\.id), ["a"])
        guard case let .toolGroup(tools) = rows[0] else { return XCTFail("Missing group") }
        XCTAssertEqual(tools[2].status, .failed)
        XCTAssertEqual(AgentChatToolGroupKind.status(tools), .succeeded)
        XCTAssertEqual(AgentChatToolGroupKind.status([]), .succeeded)
        let failed = AgentChatItem.ToolCall(toolUseId: "failed", name: "Read", inputSummary: "", inputJSON: "{}", status: .failed)
        var denied = AgentChatItem.ToolCall(toolUseId: "denied", name: "Read", inputSummary: "", inputJSON: "{}", status: .succeeded)
        denied.permissionDenied = true
        let running = AgentChatItem.ToolCall(toolUseId: "running", name: "Read", inputSummary: "", inputJSON: "{}")
        XCTAssertEqual(AgentChatToolGroupKind.status([failed, denied]), .failed)
        XCTAssertEqual(AgentChatToolGroupKind.status([failed, running]), .running)
        XCTAssertEqual(AgentChatToolGroupKind.status([.init(toolUseId: "r", name: "Read", inputSummary: "", inputJSON: "{}")]), .running)
        XCTAssertEqual(AgentChatDisplayRow.rows(from: [tool("a"), tool("b", status: .running)]).count, 1)
    }

    /// The tools the first group's row describes, as the transcript shows it.
    private func shownGroup(_ items: [AgentChatItem], _ status: AgentConversationStatus) -> [AgentChatItem.ToolCall] {
        let rows = AgentChatDisplayRow.rows(from: items)
        guard let index = rows.firstIndex(where: { if case .toolGroup = $0 { return true }; return false }),
              case let .toolGroup(tools) = rows[index] else { return [] }
        return AgentChatToolGroupKind.shown(tools, open: AgentChatDisplayRow.isOpen(at: index, of: rows, status: status))
    }

    private func assertRunning(_ shown: [AgentChatItem.ToolCall], keys: Int, current: String, line: UInt = #line) {
        XCTAssertEqual(AgentChatToolGroupKind.status(shown), .running, line: line)
        XCTAssertEqual(AgentChatToolGroupKind.summary(shown).text, keys == 1 ? "Pressing Delete" : "Pressing \(keys) keys", line: line)
        XCTAssertEqual(shown.first { $0.status == .running }?.toolUseId, current, line: line)
    }

    func testOpenGroupStaysRunningBetweenCodexActionsUntilItEnds() throws {
        func event(_ text: String) throws -> CodexJSON { try JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8)) }
        func key(_ id: String, _ method: String) throws -> CodexJSON {
            try event(#"{"method":"item/\#(method)","params":{"item":{"id":"\#(id)","type":"mcpToolCall","server":"mistbrowser","tool":"press_key","status":"\#(method == "started" ? "inProgress" : "completed")","arguments":{"key":"Delete"},"result":{"content":[]}}}}"#)
        }
        var transcript = CodexTranscript()
        transcript.userSent(text: "Delete it", attachments: [])
        transcript.apply(try event(#"{"method":"turn/started","params":{"turn":{"id":"turn"}}}"#))
        for (index, id) in ["k1", "k2", "k3"].enumerated() {
            transcript.apply(try key(id, "started"))
            assertRunning(shownGroup(transcript.items, transcript.status), keys: index + 1, current: id)
            transcript.apply(try key(id, "completed"))
            assertRunning(shownGroup(transcript.items, transcript.status), keys: index + 1, current: id)
        }
        var ended = transcript
        ended.apply(try event(#"{"method":"item/agentMessage/delta","params":{"itemId":"reply","delta":"Done"}}"#))
        XCTAssertEqual(ended.status, .running)
        XCTAssertEqual(AgentChatToolGroupKind.status(shownGroup(ended.items, ended.status)), .succeeded)
        transcript.apply(try event(#"{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}"#))
        let finished = shownGroup(transcript.items, transcript.status)
        XCTAssertEqual(AgentChatToolGroupKind.status(finished), .succeeded)
        XCTAssertEqual(AgentChatToolGroupKind.summary(finished).text, "Pressed 3 keys")
    }

    func testOpenGroupStaysRunningBetweenClaudeActionsUntilTheTurnEnds() throws {
        var transcript = ClaudeCodeTranscript()
        transcript.userSent(text: "Delete it", attachments: [])
        for (index, id) in ["k1", "k2", "k3"].enumerated() {
            transcript.apply(.assistant(.object(["message": .object(["id": .string("m" + id), "content": .array([
                .object(["type": .string("tool_use"), "id": .string(id), "name": .string("mcp__mistbrowser__press_key"),
                         "input": .object(["key": .string("Delete")])])
            ])])])))
            assertRunning(shownGroup(transcript.items, transcript.status), keys: index + 1, current: id)
            transcript.apply(.user(.object(["message": .object(["content": .array([
                .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string("Pressed")])
            ])])])))
            assertRunning(shownGroup(transcript.items, transcript.status), keys: index + 1, current: id)
        }
        transcript.apply(.result(.object(["duration_ms": .number(1000)])))
        XCTAssertEqual(transcript.status, .idle)
        let finished = shownGroup(transcript.items, transcript.status)
        XCTAssertEqual(AgentChatToolGroupKind.status(finished), .succeeded)
        XCTAssertEqual(AgentChatToolGroupKind.summary(finished).text, "Pressed 3 keys")
        var failed = finished
        failed[2].status = .failed
        XCTAssertEqual(AgentChatToolGroupKind.shown(failed, open: true).last?.status, .running)
        XCTAssertEqual(AgentChatToolGroupKind.shown(failed, open: false), failed)
    }

    func testEveryNonToolItemBreaksTheRun() {
        let kinds: [AgentChatItem.Kind] = [.userMessage(text: "Hi", images: []), .assistantText(text: "Hi", isStreaming: true),
            .permissionRequest(.init(requestId: "p", toolName: "Bash", summary: "")), .notice(text: "Hi", level: .info),
            .turnEnd(durationMilliseconds: 1, finishedAt: Date()), .peerMessage(name: "peer", body: "Hello")]
        for kind in kinds {
            XCTAssertEqual(AgentChatDisplayRow.rows(from: [tool("a"), .init(id: "break", kind: kind), tool("b")]).count, 3)
        }
    }

    func testSummaryCountsKindsInFirstAppearanceOrderAndBoldsCounts() {
        let tools = ["Bash", "Read", "Bash", "Glob", "Grep", "WebFetch", "WebSearch", "Unknown"].enumerated().map {
            AgentChatItem.ToolCall(toolUseId: String($0.offset), name: $0.element, inputSummary: "", inputJSON: "{}", status: .succeeded)
        }
        let line = AgentChatToolGroupKind.summary(tools)
        XCTAssertEqual(line.text, "Ran 2 shell commands, read 1 file, searched 2 patterns, fetched 1 page, searched the web 1 time, used Unknown 1 time")
        XCTAssertEqual(line.spans.filter { $0.style == .bold }.map(\.text), ["2", "1", "2", "1", "1", "1"])
    }

    func testEveryKnownToolHasItsOwnCategoryAndOthersAreNamedAfterThemselves() {
        let browser = ["list_tabs", "group_tabs", "use_tab", "open_tab", "navigate", "reload", "go_back", "go_forward", "snapshot", "read_page", "evaluate", "read_console", "read_network", "click", "drag", "fill", "type_text",
            "upload_files", "press_key", "select_option", "select_text", "hover", "scroll", "scroll_until", "wait_for", "handle_dialog", "close_tab", "screenshot", "save_screenshot", "start_recording", "stop_recording", "save_page", "export_bookmarks", "mount_to_tab", "unmount_from_tab", "list_downloads", "search_history", "list_agents", "message_agent", "hand_off"]
        let builtIn = ["Read", "Grep", "Glob", "Bash", "WebFetch", "WebSearch", "Sleep", "ImageGeneration", "Monitor", "TaskStop", "ToolSearch",
            "Skill", "LSP", "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "EnterPlanMode",
            "PushNotification", "ListMcpResourcesTool", "ReadMcpResourceTool", "ReadMcpResourceDirTool"]
        for name in browser.map({ "mcp__mistbrowser__" + $0 }) + builtIn {
            let kind = AgentChatToolGroupKind(name)
            XCTAssertNotEqual(kind, .tool(name), name)
            for count in [1, 2] {
                XCTAssertNotEqual(AgentChatStrings.toolGroup(kind, count: count), AgentChatStrings.toolGroup(kind, count: count, running: true), name)
            }
        }
        XCTAssertEqual(AgentChatStrings.toolGroup(.tool("lookup"), count: 1), "used lookup 1 time")
        for name in ["Task", "Agent", "Workflow", "SendMessage", "ListAgents", "RemoteTrigger", "ReportFindings",
                     "ShareOnboardingGuide", "DesignSync", "PublishPlugin", "EnterWorktree", "ExitWorktree", "SendToProject", "SendToProjectContext"] {
            XCTAssertEqual(AgentChatToolGroupKind(name), .tool(name))
            XCTAssertEqual(AgentChatToolGroupKind(name).symbol, "wrench")
            XCTAssertTrue(AgentChatDisplayRow.isGroupable(.init(toolUseId: name, name: name, inputSummary: "", inputJSON: "{}")))
        }
        XCTAssertEqual(AgentChatStrings.toolGroup(.tool("lookup"), count: 2, running: true), "using lookup 2 times")
        let tools = ["mcp__claude_ai_Slack__slack_read_channel", "mcp__aws__ec2_list", "mcp__aws__ec2_list", "mcp__mistbrowser__wait_for", "TodoWrite"]
            .enumerated().map { AgentChatItem.ToolCall(toolUseId: String($0.offset), name: $0.element, inputSummary: "", inputJSON: "{}", status: .succeeded) }
        let line = AgentChatToolGroupKind.summary(tools)
        XCTAssertEqual(line.text, "Used slack_read_channel 1 time, used ec2_list 2 times, waited for 1 page, used TodoWrite 1 time")
        XCTAssertEqual(line.spans.filter { $0.style == .bold }.map(\.text), ["1", "2", "1", "1"])
        XCTAssertEqual(AgentChatToolGroupKind.displayName("mcp__server__"), "mcp__server__")
    }

    func testRunningGroupsAndBrowserKindsDescribeTheirActions() {
        let kinds: [(String, AgentChatToolGroupKind)] = [("snapshot", .browserRead), ("read_page", .browserRead),
            ("screenshot", .browserScreenshot), ("click", .browserClick), ("fill", .browserType), ("type_text", .browserType),
            ("press_key", .browserKey), ("select_option", .browserOption), ("select_text", .browserSelectText), ("navigate", .browserOpen), ("open_tab", .browserOpen), ("reload", .browserReload),
            ("go_back", .browserOpen), ("go_forward", .browserOpen), ("drag", .browserDrag), ("group_tabs", .browserGroup),
            ("evaluate", .browserScript), ("read_console", .browserLogs), ("read_network", .browserLogs),
            ("save_page", .pagesSaved), ("list_downloads", .browserDownloads), ("search_history", .browserHistory), ("hand_off", .message),
            ("hover", .browserHover), ("scroll_until", .browserScroll),
            ("scroll", .browserScroll), ("list_tabs", .browserTabs), ("use_tab", .browserConnect), ("close_tab", .browserClose),
            ("wait_for", .browserWait), ("handle_dialog", .browserDialog),
            ("save_screenshot", .screenshotsSaved), ("upload_files", .browserUpload), ("list_agents", .agents), ("message_agent", .message),
            ("start_recording", .recordingStarted), ("stop_recording", .recordingsSaved),
            ("export_bookmarks", .bookmarksExported), ("mount_to_tab", .chatMounted), ("unmount_from_tab", .chatUnmounted),
            ("list_mail_accounts", .mailList), ("list_mail", .mailList), ("search_mail", .mailSearch), ("read_mail", .mailRead),
            ("write_mail_draft", .mailDraft), ("send_mail", .mailSend), ("update_mail", .mailChange)]
        for (name, kind) in kinds {
            XCTAssertEqual(AgentChatToolGroupKind("mcp__mistbrowser__" + name), kind)
            for count in [1, 2] {
                XCTAssertNotEqual(AgentChatStrings.toolGroup(kind, count: count), AgentChatStrings.toolGroup(kind, count: count, running: true))
            }
        }
        XCTAssertEqual(AgentChatToolGroupKind.browserDrag.symbol, "hand.draw")
        XCTAssertEqual(AgentChatToolGroupKind.bookmarksExported.symbol, "square.and.arrow.up")
        XCTAssertEqual(AgentChatToolGroupKind.chatMounted.symbol, "link.badge.plus")
        XCTAssertEqual(AgentChatToolGroupKind.chatUnmounted.symbol, "personalhotspot.slash")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserDrag, count: 1, running: true), "dragging 1 element")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserDrag, count: 2), "dragged 2 elements")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserGroup, count: 1, running: true), "organizing tabs 1 time")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserGroup, count: 2), "organized tabs 2 times")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserScript, count: 1), "ran JavaScript 1 time")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserLogs, count: 2, running: true), "reading page logs 2 times")
        XCTAssertEqual(AgentChatStrings.toolGroup(.pagesSaved, count: 2), "saved 2 pages")
        XCTAssertEqual(AgentChatToolGroupKind.recordingStarted.symbol, "record.circle")
        XCTAssertEqual(AgentChatToolGroupKind.recordingsSaved.symbol, "record.circle")
        XCTAssertEqual(AgentChatStrings.toolGroup(.recordingStarted, count: 1), "started 1 recording")
        XCTAssertEqual(AgentChatStrings.toolGroup(.recordingStarted, count: 2, running: true), "starting 2 recordings")
        XCTAssertEqual(AgentChatStrings.toolGroup(.recordingsSaved, count: 2), "saved 2 recordings")
        XCTAssertEqual(AgentChatStrings.toolGroup(.recordingsSaved, count: 1, running: true), "saving 1 recording")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserDownloads, count: 1, running: true), "listing downloads 1 time")
        XCTAssertEqual(AgentChatStrings.toolGroup(.browserHistory, count: 2), "searched history 2 times")
        let failedMail = ["list_mail", "search_mail", "write_mail_draft", "send_mail", "update_mail"].map { AgentChatItem.ToolCall(toolUseId: $0, name: "mcp__mistbrowser__" + $0, inputSummary: "", inputJSON: "{}", status: .failed) }
        XCTAssertEqual(AgentChatToolGroupKind.summary(failedMail).text, "Couldn't complete 5 mail actions")
        var tools = [AgentChatItem.ToolCall(toolUseId: "b", name: "mcp__mistbrowser__navigate", inputSummary: "",
                                          inputJSON: #"{"url":"https://www.google.com/search?q=test"}"#)]
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Navigating to www.google.com")
        tools[0].status = .succeeded
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Navigated to www.google.com")
        tools.append(.init(toolUseId: "r", name: "mcp__mistbrowser__read_page", inputSummary: "", inputJSON: "{}"))
        XCTAssertEqual(AgentChatToolGroupKind.summary(tools).text, "Opening 1 page, reading 1 page")
        let shell = AgentChatItem.ToolCall(toolUseId: "s", name: "Bash", inputSummary: "", inputJSON: "{}")
        XCTAssertEqual(AgentChatToolGroupKind.summary([shell]).text, "Running 1 shell command")
    }
}
