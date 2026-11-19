import Foundation
import XCTest
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

final class CodexLaunchTests: XCTestCase {
    func testMarkerThreadUsesToolsOffLunaInstructions() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let value = CodexProtocol.markerThreadStart(model: "gpt-6-luna", cwd: cwd)
        XCTAssertEqual(value["model"].string, "gpt-6-luna")
        XCTAssertEqual(value["cwd"].string, cwd.path)
        XCTAssertEqual(value["ephemeral"], .bool(true))
        XCTAssertEqual(value["approvalPolicy"].string, "never")
        XCTAssertEqual(value["sandbox"].string, "read-only")
        XCTAssertEqual(value["developerInstructions"].string, CodexProtocol.markerInstructions)
        XCTAssertEqual(value["config"]["mcp_servers"], .object([:]))
        for feature in ["shell_tool", "image_generation", "view_image", "sleep_tool", "unified_exec"] {
            XCTAssertEqual(value["config"]["features." + feature], .bool(false))
        }
        XCTAssertEqual(value["config"]["web_search"].string, "disabled")
        XCTAssertEqual(value["config"]["features.multi_agent_v2.disable_native_tools"], .bool(true))
    }

    func testMarkerInputIncludesOnlyNonemptyContextAndCapsBothParts() {
        XCTAssertEqual(CodexProtocol.markerInput(text: "Reply", context: nil), "Name this message:\n<message>\nReply\n</message>")
        XCTAssertEqual(CodexProtocol.markerInput(text: "Reply", context: " \n"), CodexProtocol.markerInput(text: "Reply", context: nil))
        XCTAssertEqual(CodexProtocol.markerInput(text: "Reply", context: "Question"),
                       "Name this message:\n<context>\nQuestion\n</context>\n<message>\nReply\n</message>")
        XCTAssertEqual(CodexProtocol.markerInput(text: String(repeating: "文", count: 6001), context: String(repeating: "é", count: 2001)),
                       "Name this message:\n<context>\n" + String(repeating: "é", count: 2000) + "\n</context>\n<message>\n" + String(repeating: "文", count: 6000) + "\n</message>")
    }

    func testMarkerReplyCleanup() {
        XCTAssertEqual(CodexProtocol.markerName(fromReply: "\n \n A useful   subject.\nIgnore this"), "A useful subject")
        for (open, close) in [("\"", "\""), ("'", "'"), ("`", "`"), ("“", "”"), ("«", "»")] {
            XCTAssertEqual(CodexProtocol.markerName(fromReply: open + "Relay\tchunk sizes.:;" + close), "Relay chunk sizes")
        }
        XCTAssertNil(CodexProtocol.markerName(fromReply: "\n \t\n"))
        XCTAssertNil(CodexProtocol.markerName(fromReply: "``"))
        XCTAssertNil(CodexProtocol.markerName(fromReply: " .:; "))
        XCTAssertNotNil(CodexProtocol.markerName(fromReply: String(repeating: "字", count: 80)))
        XCTAssertNil(CodexProtocol.markerName(fromReply: String(repeating: "字", count: 81)))
    }

    func testMarkerThreadRoutesFinalReplyAndFinishesOnce() {
        func message(_ thread: String, _ text: String, type: String = "agentMessage") -> CodexJSON {
            .object(["method": .string("item/completed"), "params": .object(["threadId": .string(thread),
                "item": .object(["type": .string(type), "text": .string(text)])])])
        }
        func completed(_ thread: String = "marker", status: String = "completed") -> CodexJSON {
            .object(["method": .string("turn/completed"), "params": .object(["threadId": .string(thread),
                "turn": .object(["status": .string(status)])])])
        }
        var thread = CodexMarkerThread(id: "marker")
        XCTAssertNil(thread.apply(message("other", "Wrong")))
        XCTAssertNil(thread.apply(completed("other")))
        XCTAssertNil(thread.apply(message("marker", "First draft")))
        XCTAssertNil(thread.apply(message("marker", "\n“Relay chunk sizes.”\nExtra")))
        XCTAssertNil(thread.apply(message("marker", "Wrong tool", type: "commandExecution")))
        XCTAssertEqual(thread.apply(completed()), .named("Relay chunk sizes"))
        XCTAssertNil(thread.apply(completed()))
        thread = CodexMarkerThread(id: "marker")
        XCTAssertEqual(thread.apply(completed()), .failed)
        XCTAssertNil(thread.apply(message("marker", "Too late")))
        XCTAssertNil(thread.apply(completed()))
        thread = CodexMarkerThread(id: "marker")
        _ = thread.apply(message("marker", "Clean name"))
        XCTAssertEqual(thread.apply(completed()), .named("Clean name"))
        for status in ["failed", "interrupted", "inProgress"] {
            thread = CodexMarkerThread(id: "marker")
            _ = thread.apply(message("marker", "A name"))
            XCTAssertEqual(thread.apply(completed(status: status)), .failed)
            XCTAssertNil(thread.apply(completed()))
        }
    }

    func testLunaModelPicksHighestNumericIDWithoutFallback() {
        func model(_ id: String) -> CodexModelInfo {
            .init(id: id, displayName: id, efforts: ["none"], defaultEffort: "none", inputModalities: ["text"], isDefault: false)
        }
        let newest = model("gpt-10-Luna")
        XCTAssertEqual(CodexProtocol.lunaModel([model("gpt-6-luna"), newest, model("gpt-99-sol")]), newest)
        XCTAssertNil(CodexProtocol.lunaModel([model("gpt-6-sol")]))
        XCTAssertNil(CodexProtocol.lunaModel([]))
    }

    func testCLIInheritanceChangesOnlyMainArgumentsAndApprovals() {
        var request = CodexLaunchRequest(prompt: "hello", model: "gpt-6-luna", effort: "low", cwd: URL(fileURLWithPath: "/owned"),
            mcpServers: ["mistbrowser": .init(command: "node")])
        XCTAssertEqual(CodexProtocol.arguments(for: request), CodexProtocol.arguments)
        let isolated = CodexProtocol.threadStart(request, inherited: ["aside"])
        XCTAssertEqual(isolated["config"]["mcp_servers"]["aside"]["enabled"], .bool(false))
        XCTAssertEqual(isolated["config"]["apps._default.default_tools_approval_mode"], .null)
        request.inheritsCLIServers = true
        let args = CodexProtocol.arguments(for: request)
        XCTAssertEqual(args, CodexProtocol.arguments.enumerated().filter { index, value in
            value != "mcp_servers={}" && !(value == "-c" && CodexProtocol.arguments[index + 1] == "mcp_servers={}")
        }.map(\.element))
        XCTAssertTrue(args.contains("plugins"))
        let inherited: Set<String> = ["aside", "with.dots", "mistbrowser", "node_repl", "computer-use"]
        let value = CodexProtocol.threadStart(request, inherited: inherited)
        XCTAssertEqual(value["config"]["mcp_servers"]["aside"], .object(["default_tools_approval_mode": .string("writes")]))
        XCTAssertEqual(value["config"]["mcp_servers"]["with.dots"]["default_tools_approval_mode"].string, "writes")
        XCTAssertEqual(value["config"]["apps._default.default_tools_approval_mode"], .null)
        XCTAssertEqual(value["config"]["apps._default.approvals_reviewer"], .null)
        for name in ["node_repl", "computer-use"] {
            XCTAssertEqual(value["config"]["mcp_servers"][name], .object(["enabled": .bool(false)]))
        }
        let resume = CodexProtocol.threadResume(request, threadId: "saved", inherited: inherited)
        XCTAssertEqual(resume["config"], value["config"])
        let title = CodexProtocol.titleThreadStart(request, model: "gpt-6-luna", inherited: ["aside", "node_repl"])
        XCTAssertEqual(title["config"]["features.apps"], .null)
        for name in ["aside", "node_repl", "mistbrowser"] {
            XCTAssertEqual(title["config"]["mcp_servers"][name]["enabled"], .bool(false))
        }
        XCTAssertEqual(title["config"]["mcp_servers"]["aside"]["command"], .null)
    }

    func testFilePathsInStartAndSteer() {
        let file = AgentFileAttachment(url: URL(fileURLWithPath: "/chat/attachments/file.pdf"))
        let attachments: [AgentAttachment] = [.file(file)]
        let expected = "Read\n\nFiles the user attached:\n/chat/attachments/file.pdf"
        let start = CodexProtocol.turnStart(threadId: "t", text: "Read", attachments: attachments, effort: "low")
        XCTAssertEqual(start["input"].array.first?["text"].string, expected)
        let message = AgentQueuedMessage(text: "Read", attachments: attachments)
        let steer = CodexProtocol.turnSteer(threadId: "t", turnId: "turn", message: message)
        XCTAssertEqual(steer["input"].array.first?["text"].string, expected)
        var transcript = CodexTranscript()
        transcript.queuedMessageTaken(message)
        XCTAssertEqual(transcript.items.last?.files, [file])
    }

    func testTitleThreadUsesNewestLunaAndDisablesEveryMCPServer() {
        func model(_ id: String, efforts: [String] = ["low", "high"]) -> CodexModelInfo {
            .init(id: id, displayName: id, efforts: efforts, defaultEffort: "high", inputModalities: ["text"], isDefault: false)
        }
        let models = [model("gpt-6-luna"), model("gpt-5-luna"), model("chat", efforts: ["minimal", "high"])]
        let choice = CodexProtocol.titleModel(models, fallback: "chat", effort: "high")
        XCTAssertEqual(choice.model, "gpt-6-luna")
        XCTAssertEqual(choice.effort, "none")
        let fallback = CodexProtocol.titleModel([models[2]], fallback: "chat", effort: "high")
        XCTAssertEqual(fallback.model, "chat")
        XCTAssertEqual(fallback.effort, "minimal")
        let request = CodexLaunchRequest(prompt: "hello", model: "chat", effort: "high", cwd: URL(fileURLWithPath: "/tmp"),
            mcpServers: ["mistbrowser": .init(command: "node")])
        let value = CodexProtocol.titleThreadStart(request, model: choice.model, inherited: ["inherited"])
        XCTAssertEqual(value["model"].string, "gpt-6-luna")
        XCTAssertEqual(value["approvalPolicy"].string, "never")
        XCTAssertEqual(value["sandbox"].string, "read-only")
        XCTAssertEqual(value["config"]["features.shell_tool"], .bool(false))
        XCTAssertEqual(value["config"]["features.unified_exec"], .bool(false))
        XCTAssertEqual(value["config"]["features.multi_agent_v2.disable_native_tools"], .bool(true))
        XCTAssertEqual(value["config"]["web_search"], .string("disabled"))
        XCTAssertEqual(value["config"]["features.apps"], .null)
        for feature in ["image_generation", "view_image", "sleep_tool"] {
            XCTAssertEqual(value["config"]["features." + feature], .bool(false))
        }
        XCTAssertTrue(value["developerInstructions"].string?.contains("sentence case") == true)
        XCTAssertTrue(value["developerInstructions"].string?.contains("Never answer") == true)
        XCTAssertTrue(value["developerInstructions"].string?.contains("reply with only NONE") == true)
        XCTAssertEqual(CodexProtocol.titleInput("Do X"), "Write a title for this request:\n<request>\nDo X\n</request>")
        XCTAssertTrue(value["ephemeral"].bool)
        for name in ["mistbrowser", "inherited"] { XCTAssertEqual(value["config"]["mcp_servers"][name]["enabled"], .bool(false)) }
    }

    func testTitleThreadRoutesOnlyItsOwnFinalMessageAndDoesNotRetryFailure() {
        var title = CodexTitleThread(id: "title")
        func message(_ thread: String, _ text: String) -> CodexJSON {
            .object(["method": .string("item/completed"), "params": .object(["threadId": .string(thread),
                "item": .object(["type": .string("agentMessage"), "text": .string(text)])])])
        }
        func completed(_ status: String) -> CodexJSON {
            .object(["method": .string("turn/completed"), "params": .object(["threadId": .string("title"),
                "turn": .object(["status": .string(status)])])])
        }
        XCTAssertNil(title.apply(message("main", "Wrong title")))
        XCTAssertNil(title.apply(message("title", " First draft ")))
        XCTAssertNil(title.apply(message("title", "\n  A useful final title \nExtra text\n")))
        XCTAssertEqual(title.apply(completed("completed")), "A useful final title")
        XCTAssertNil(title.apply(completed("completed")))
        title = CodexTitleThread(id: "title")
        XCTAssertNil(title.apply(message("title", "Failed title")))
        XCTAssertNil(title.apply(completed("failed")))
        XCTAssertNil(title.apply(completed("completed")))
        title = CodexTitleThread(id: "title")
        XCTAssertNil(title.apply(message("title", "NONE\n")))
        XCTAssertNil(title.apply(completed("completed")))
        title = CodexTitleThread(id: "title")
        XCTAssertNil(title.apply(message("title", "Find first section headings for kiwi and heron NONE")))
        XCTAssertEqual(title.apply(completed("completed")), "Find first section headings for kiwi and heron")
    }

    func testLockdownArguments() {
        let args = CodexProtocol.arguments
        XCTAssertEqual(Array(args.prefix(3)), ["app-server", "--listen", "stdio://"])
        for feature in ["multi_agent", "multi_agent_v2", "plugins", "apps", "skill_search", "tool_suggest", "browser_use", "browser_use_external", "computer_use", "goals", "hooks", "in_app_browser", "memories"] {
            XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "--disable" && $1 == feature })
        }
        for feature in ["view_image", "sleep_tool", "image_generation"] { XCTAssertFalse(args.contains(feature)) }
        XCTAssertFalse(args.contains("web_search=\"disabled\""))
        for config in ["web_search=\"live\"", "skills.include_instructions=false", "skills.bundled.enabled=false", "notify=[]", "agents.enabled=false", "mcp_servers={}", "sandbox_mode=\"read-only\"", "forced_login_method=\"chatgpt\"", "model_provider=\"openai\""] {
            XCTAssertTrue(args.contains(config))
        }
        let inheriting = CodexProtocol.arguments(for: .init(prompt: "", model: "model", effort: "low", cwd: URL(fileURLWithPath: "/owned"), inheritsCLIServers: true))
        XCTAssertTrue(inheriting.contains("agents.enabled=false"))
        XCTAssertTrue(zip(inheriting, inheriting.dropFirst()).contains { $0 == "--disable" && $1 == "apps" })
    }

    func testResumeKeepsOverridesWithoutEphemeralOrHistoryReplay() {
        let request = CodexLaunchRequest(prompt: "", model: "model", effort: "high", cwd: URL(fileURLWithPath: "/owned"),
            mcpServers: ["mistbrowser": .init(command: "node", env: ["MIST_BROWSER_WINDOW_ID": "222"])])
        guard case var .object(expected) = CodexProtocol.threadStart(request, inherited: ["old"]) else { return XCTFail() }
        expected.removeValue(forKey: "ephemeral")
        expected["threadId"] = .string("saved")
        expected["excludeTurns"] = .bool(true)
        XCTAssertEqual(CodexProtocol.threadResume(request, threadId: "saved", inherited: ["old"]), .object(expected))
    }

    func testThreadConfigDisablesInheritedAndOverridesSameName() {
        let request = CodexLaunchRequest(prompt: "hello", model: "model", effort: "low", cwd: URL(fileURLWithPath: "/tmp"),
            developerInstructions: "Only MCP", mcpServers: ["allowed": .init(command: "node", args: ["server.js"], env: ["TEST": "yes"])])
        let value = CodexProtocol.threadStart(request, inherited: ["old", "allowed"])
        XCTAssertEqual(value["approvalPolicy"].string, "untrusted")
        XCTAssertEqual(value["sandbox"].string, "danger-full-access")
        XCTAssertEqual(value["config"]["features.shell_tool"], .bool(true))
        XCTAssertEqual(value["config"]["features.unified_exec"], .bool(true))
        XCTAssertEqual(value["config"]["features.multi_agent_v2.disable_native_tools"], .bool(false))
        XCTAssertEqual(value["modelProvider"].string, "openai")
        XCTAssertFalse(value["ephemeral"].bool)
        XCTAssertEqual(value["developerInstructions"].string, "Only MCP")
        let servers = value["config"]["mcp_servers"]
        XCTAssertEqual(servers["old"]["enabled"], .bool(false))
        XCTAssertEqual(servers["old"]["command"].string, "true")
        XCTAssertTrue(servers["allowed"]["enabled"].bool)
        XCTAssertEqual(servers["allowed"]["env"]["TEST"].string, "yes")
        XCTAssertEqual(servers["allowed"]["args"].array, [.string("server.js")])
        XCTAssertEqual(servers["allowed"]["default_tools_approval_mode"].string, "writes")
    }

    func testTOMLHeaderScan() {
        XCTAssertEqual(CodexProtocol.serverNames(in: #"""
        # [mcp_servers.ignored]
        [mcp_servers.simple]
        [mcp_servers.simple.env]
        [ mcp_servers . "with.dots" . env ] # comment
        [mcp_servers.'literal name']
        ["mcp_servers"."quote\"and]bracket".env]
        [mcp_servers."escaped\u002dname"]
        [mcp_servers."long\U0000002dname".env]
        [mcp_servers."literal\\U0000002d"]
        text = "[mcp_servers.nope]"
        [features]
        [[mcp_servers.array]]
        [mcp_servers."unclosed]
        """#), ["simple", "with.dots", "literal name", "quote\"and]bracket", "escaped-name", "long-name", "literal\\U0000002d"])
    }

    func testConfigHomeOverride() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "[mcp_servers.fixture.env]".write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexProtocol.inheritedServers(environment: ["CODEX_HOME": folder.path]), ["fixture"])
        XCTAssertEqual(CodexProtocol.inheritedServers(environment: [:], home: folder), [])
    }

    func testExecutableLookupAndEnvironment() {
        let executable = ClaudeCodeEnvironment.findExecutable(name: "codex", environment: ["PATH": "relative:/custom/bin"],
            home: URL(fileURLWithPath: "/test"), isExecutable: { $0 == "/custom/bin/codex" })
        XCTAssertEqual(executable?.path, "/custom/bin/codex")
        XCTAssertEqual(ClaudeCodeEnvironment.findExecutable(name: "codex", environment: [:], home: URL(fileURLWithPath: "/test"),
            isExecutable: { $0 == "/test/.local/bin/codex" })?.path, "/test/.local/bin/codex")
        XCTAssertEqual(CodexProtocol.environment(["PATH": "/bin", "OPENAI_API_KEY": "test-placeholder"]), ["PATH": "/bin"])
    }

    func testTurnInputIncludesImages() {
        let image = AgentImageAttachment(data: Data([1, 2]), mediaType: "image/png")
        let input = CodexProtocol.turnStart(threadId: "thread", text: "hello", attachments: [.image(image)], effort: "low")
        XCTAssertEqual(input["input"].array[0]["text"].string, "hello")
        XCTAssertEqual(input["input"].array[1]["url"].string, "data:image/png;base64,AQI=")
        XCTAssertEqual(input["effort"].string, "low")
    }
}
