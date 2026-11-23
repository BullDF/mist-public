import Foundation
import XCTest

final class GeminiTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testKeyParsingAndSymlink() throws {
        XCTAssertEqual(GeminiEnvironment.key(from: "OTHER=discard\n# GEMINI_API_KEY=wrong\nexport GEMINI_API_KEY='fixture#key' # note"), "fixture#key")
        XCTAssertEqual(GeminiEnvironment.key(from: "export\t GEMINI_API_KEY = \"fixture-key\""), "fixture-key")
        XCTAssertEqual(GeminiEnvironment.key(from: "GEMINI_API_KEY=fixture-key # note"), "fixture-key")
        XCTAssertNil(GeminiEnvironment.key(from: "OTHER=fixture-key\n#GEMINI_API_KEY=comment\nGEMINI_API_KEY=\"\""))
        let folder = try temporaryFolder(), target = folder.appendingPathComponent("linked.env")
        try "GEMINI_API_KEY=fixture-one".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: GeminiEnvironment.envFile(in: folder), withDestinationURL: target)
        XCTAssertEqual(GeminiEnvironment.key(in: folder), "fixture-one")
        try "GEMINI_API_KEY=fixture-two".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(GeminiEnvironment.key(in: folder), "fixture-two")
    }

    func testEnvironmentDropsInheritedCredentials() throws {
        let folder = try temporaryFolder()
        let env = GeminiEnvironment.variables(["PATH": "/usr/bin", "GEMINI_API_KEY": "wrong", "GEMINI_CLI_HOME": "/wrong",
            "GOOGLE_APPLICATION_CREDENTIALS": "/wrong", "CLOUDSDK_CONFIG": "/wrong", "ANTHROPIC_API_KEY": "wrong",
            "OPENAI_API_KEY": "wrong", "GOOGLE_API_KEY": "wrong"], key: "fixture-key", cliHome: folder)
        XCTAssertEqual(env, ["PATH": "/usr/bin", "GEMINI_API_KEY": "fixture-key", "GEMINI_CLI_HOME": folder.path,
            "GEMINI_CLI_TRUST_WORKSPACE": "true", "GEMINI_CLI_NO_RELAUNCH": "true",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": folder.appendingPathComponent(".gemini/settings.json").path])
    }

    func testCatalogSelectionAndEfforts() throws {
        let catalog = try GeminiModelCatalog.parse(Data(contentsOf: fixtures.appendingPathComponent("catalog.json")))
        let picks = GeminiModelInfo.picks(from: catalog)
        XCTAssertEqual(picks.map(\.id), ["gemini-4-neon", "gemini-4-carbon", "gemini-4-argon", "gemini-4-hydrogen",
            "gemini-3.10-flash-preview", "gemini-4.1-aurora-preview", "gemini-4-comet"])
        let models = DrifterModel.merged(claude: [:], codex: [], gemini: picks).filter { $0.engine == .gemini }
        XCTAssertEqual(models.map(\.title).suffix(3), ["Gemini 3.10 Flash Preview", "Aurora 4.1 Preview", "Comet 4"])
        XCTAssertEqual(models.map(\.efforts), [
            ["low", "medium", "high", "xhigh", "max"], ["low", "medium", "high", "max"], ["low", "medium", "high", "max"],
            ["low", "medium", "high", "xhigh", "max"], ["low", "medium", "high", "max"], ["low", "medium", "high"], ["low", "medium", "high"],
        ])
        XCTAssertTrue(models.allSatisfy { $0.defaultEffort == "high" })
        XCTAssertEqual(DrifterGeminiPicks.seed, ["gemini-4-neon", "gemini-4-carbon", "gemini-4-argon", "gemini-4-hydrogen", "gemini-3.8-flash"])
        XCTAssertEqual(DrifterModel.spawnModel("hydrogen")?.model, "gemini-4-hydrogen")
        XCTAssertEqual(DrifterModel.spawnModel("gemini 3.8 flash")?.engine, .gemini)
    }

    func testSettingsAndACPPrompt() throws {
        let settings = try JSONDecoder().decode(CodexJSON.self, from: GeminiProtocol.settings(models: DrifterGeminiPicks.seed))
        let aliases = settings["modelConfigs"]["customAliases"]
        let flash = aliases["mist-gemini-3.8-flash-low"]["modelConfig"]
        XCTAssertEqual(flash["model"].string, "gemini-3.8-flash")
        XCTAssertEqual(flash["generateContentConfig"]["thinkingConfig"]["thinkingLevel"].string, "LOW")
        XCTAssertEqual(aliases["mist-gemini-3.8-flash-xhigh"], .null)
        XCTAssertEqual(settings["security"]["auth"]["selectedType"].string, "gemini-api-key")
        XCTAssertEqual(settings["tools"]["confirmationRequired"].array, [.string("*")])
        let file = AgentAttachment.file(.init(url: URL(fileURLWithPath: "/example/attachment.txt")))
        let image = AgentAttachment.image(.init(data: Data([1, 2, 3]), mediaType: "image/png"))
        let prompt = GeminiProtocol.prompt(sessionId: "example", text: "Read this", attachments: [file, image], supportsImages: true)
        let parts = prompt["prompt"].array
        XCTAssertEqual(parts[0]["text"].string, "Read this\n\nFiles the user attached:\n/example/attachment.txt")
        XCTAssertEqual(parts[1]["mimeType"].string, "image/png")
        XCTAssertEqual(parts[1]["data"].string, "AQID")
        XCTAssertEqual(GeminiProtocol.prompt(sessionId: "example", text: "Read this", attachments: [image],
                                             supportsImages: false)["prompt"].array.count, 1)
    }

    func testToolNamesAndTranscript() throws {
        for (name, row) in GeminiProtocol.builtInNames {
            XCTAssertEqual(GeminiToolCall.name(id: name + "__example"), row)
        }
        XCTAssertEqual(GeminiToolCall.name(id: "read_many_files-1234-1"), "Read")
        XCTAssertEqual(GeminiToolCall.name(id: "mcp_mistbrowser_finish_task__1"), "mcp__mistbrowser__finish_task")
        XCTAssertNil(GeminiToolCall.name(id: "invoke_agent__1"))
        var transcript = GeminiTranscript()
        transcript.rows.userSent(text: "Check", attachments: [])
        let recording = try String(contentsOf: fixtures.appendingPathComponent("updates.jsonl"), encoding: .utf8)
        for line in recording.split(whereSeparator: \.isNewline) {
            _ = transcript.apply(try JSONDecoder().decode(CodexJSON.self, from: Data(line.utf8)))
        }
        transcript.finish(.object(["usage": .object(["outputTokens": .number(12)])]), stopped: false)
        XCTAssertEqual(transcript.rows.outputTokens, 12)
        XCTAssertEqual(transcript.rows.status, .idle)
        let items = transcript.rows.items
        XCTAssertEqual(items[1].kind, .assistantText(text: "Running the check.", isStreaming: false))
        guard case let .toolCall(shell) = items[2].kind, case let .toolCall(edit) = items[3].kind,
              case let .toolCall(background) = items[4].kind else { return XCTFail("Expected shell, edit and background rows") }
        XCTAssertEqual(shell.status, .succeeded)
        XCTAssertEqual(shell.output, "mist-gemini-acp-ok")
        XCTAssertEqual(edit.structuredResult["structuredPatch"].array.first?["lines"].array, [.string("-Old note"), .string("+New note")])
        XCTAssertEqual(background.background, .running)
        XCTAssertEqual(items[5].kind, .assistantText(text: "Done.", isStreaming: false))
        guard case .turnEnd = items[6].kind else { return XCTFail("Expected turn end") }
        transcript.rows.backgroundTaskEnded(taskId: "task-example", summary: "Finished", status: .completed)
        guard case let .toolCall(finished) = transcript.rows.items[4].kind else { return XCTFail("Expected completed task") }
        XCTAssertEqual(finished.background, .finished)
    }

    func testEditKeepsOnlyTheChangedHunkAndNotTheFile() throws {
        let original = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let changed = original.replacingOccurrences(of: "line 100\n", with: "line 100\nline 100b\n")
        let call: CodexJSON = .object([
            "toolCallId": .string("replace__example"), "title": .string("example.py: line 100 => line 100b"), "status": .string("completed"),
            "content": .array([.object(["type": .string("diff"), "path": .string("/example/example.py"),
                                        "oldText": .string(original), "newText": .string(changed)])]),
        ])
        let tool = try XCTUnwrap(GeminiToolCall(call))
        XCTAssertEqual(tool.name, "Edit")
        XCTAssertEqual(tool.input, .object(["file_path": .string("/example/example.py")]))
        let patches = tool.item(call, denied: false).structuredResult["structuredPatch"].array
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?["oldStart"].integer, 98)
        XCTAssertEqual(patches.first?["newStart"].integer, 98)
        XCTAssertEqual(patches.first?["lines"].array.compactMap(\.string),
                       [" line 98", " line 99", " line 100", "+line 100b", " line 101", " line 102", " line 103"])
    }

    func testPermissionChoicesAndAlwaysConfirmTools() throws {
        let message = try JSONDecoder().decode(CodexJSON.self, from: Data(contentsOf: fixtures.appendingPathComponent("permission.json")))
        let params = message["params"]
        let tool = try XCTUnwrap(GeminiToolCall(params["toolCall"]))
        let permission = GeminiPermission(rpcId: message["id"], tool: tool, options: params["options"].array)
        XCTAssertEqual(permission.card.toolName, "mcp__mistbrowser__send_mail")
        XCTAssertEqual(permission.card.summary, "send_mail(draft_id: example-draft)")
        XCTAssertEqual(permission.reply(allows: true)["outcome"]["optionId"].string, "proceed_once")
        XCTAssertEqual(permission.reply(allows: false)["outcome"]["optionId"].string, "cancel")
        let onlyPersistent = GeminiPermission(rpcId: .number(1), tool: tool, options: [params["options"].array[0]])
        XCTAssertEqual(onlyPersistent.reply(allows: true), GeminiPermission.cancelled)
        for mode in DrifterConfirmation.allCases {
            for tool in ["send_mail", "slack_send_message", "slack_schedule_message", "slack_complete_file_upload"] {
                let name = try XCTUnwrap(GeminiToolCall.name(id: "mcp_mistbrowser_\(tool)__example"))
                XCTAssertFalse(mode.automaticallyAllows(tool: name, requiresInteraction: false), name)
            }
            XCTAssertTrue(mode.automaticallyAllows(tool: "Read", requiresInteraction: false))
        }
    }

    @MainActor func testSessionStopCancelsPermissionThenQueuedMessageUsesNewEffort() async throws {
        let folder = try temporaryFolder()
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("gemini")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("fake-gemini.mjs"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "GEMINI_API_KEY=fixture-key".write(to: GeminiEnvironment.envFile(in: folder), atomically: true, encoding: .utf8)
        let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/bin:/bin")
        let environment = ClaudeCodeEnvironment(variables: ["PATH": path, "GOOGLE_API_KEY": "discard"], executable: nil)
        let conversation = AgentConversation()
        conversation.manualTitle = "Fixture chat"
        let request = GeminiLaunchRequest(prompt: "Permission probe", model: "gemini-4-neon", effort: "low", cwd: folder,
            drifterHome: folder, cliHome: folder.appendingPathComponent("Gemini"),
            preload: fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/gemini-preload.mjs"),
            instructions: "Fixture instructions")
        let session = GeminiSession(request: request, conversation: conversation, environment: { environment })
        defer { session.close() }
        try await wait(conversation, for: .awaitingPermission)
        conversation.onQueue?("Queued report", [], [])
        let queued = try XCTUnwrap(conversation.queue.first)
        conversation.onStop?()
        try await wait(conversation, for: .idle)
        XCTAssertTrue(conversation.queuePaused)
        XCTAssertTrue(AgentChatTranscriptText.lastTurnStopped(conversation.items))
        XCTAssertEqual(session.resumeId, "gemini-fixture-session")
        session.model = "gemini-3.8-flash"; session.effort = "max"
        conversation.onSendQueuedNow?(queued.id)
        try await wait(conversation, for: .idle)
        XCTAssertFalse(conversation.queuePaused)
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertTrue(conversation.items.contains { $0.kind == .assistantText(text: "mist-gemini-3.8-flash-max: Queued report", isStreaming: false) })
        XCTAssertEqual(conversation.contextTokens, 27)
        XCTAssertEqual(conversation.outputTokens, 5)
    }

    @MainActor private func wait(_ conversation: AgentConversation, for status: AgentConversationStatus) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while conversation.status != status, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard conversation.status == status else {
            XCTFail("Expected \(status), received \(conversation.status)")
            throw CocoaError(.userCancelled)
        }
    }
}

@main
enum GeminiTestsMain {
    static func main() {
        let result = GeminiTests.defaultTestSuite
        result.run()
        guard let stats = result.testRun else { exit(1) }
        exit(stats.executionCount == 8 && stats.totalFailureCount == 0 ? 0 : 1)
    }
}
