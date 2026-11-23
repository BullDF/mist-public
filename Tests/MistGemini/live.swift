import Foundation

@main
enum GeminiLive {
    struct Audit: Decodable { let model: String; let thinking: String?; let tools: [String] }
    enum Failure: Error {
        case missingEnvironment, timedOut, badPermission, toolDidNotRun, missingPrompt, badModelOrEffort, badToolList, badResume, slowExit
    }

    static func main() async {
        do { try await run() }
        catch let failure as Failure {
            print("Gemini ACP live check failed: \(failure)")
            exit(1)
        } catch {
            // CLI and SDK errors can contain sensitive request details.
            print("Gemini ACP live check failed (\(type(of: error))).")
            exit(1)
        }
    }

    static func run() async throws {
        let inherited = ProcessInfo.processInfo.environment
        guard let key = inherited[GeminiEnvironment.keyName], !key.isEmpty,
              CommandLine.arguments.count == 4,
              let node = ClaudeCodeEnvironment.findExecutable(name: "node", environment: inherited,
                  home: FileManager.default.homeDirectoryForCurrentUser) else { throw Failure.missingEnvironment }
        let cwd = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let log = cwd.appendingPathComponent("api-audit.jsonl")
        var variables = inherited
        variables["NODE_OPTIONS"] = "--import=" + fixtures.appendingPathComponent("audit-request.mjs").absoluteString
        variables["MIST_GEMINI_AUDIT"] = log.path
        let environment = ClaudeCodeEnvironment(variables: variables, executable: nil)
        let model = "gemini-3.8-flash", effort = "low"
        let text = "Call run_shell_command exactly once with the shell command printf 'mist-gemini-acp-ok\\n'. Then call the fixture_status tool exactly once. Then report that both ran. Do not use any other tool."
        let request = GeminiLaunchRequest(prompt: text, model: model, effort: effort, cwd: cwd, drifterHome: cwd,
            cliHome: cwd.appendingPathComponent("Gemini"), preload: URL(fileURLWithPath: CommandLine.arguments[3]), instructions: "",
            server: .init(command: node.path, args: [fixtures.appendingPathComponent("mcp-fixture.mjs").path], env: [:]))
        let process = try await GeminiProcess.launch(request, environment: environment, readKey: { _ in key })
        defer { process.transport.terminateNow() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            process.transport.terminate()
        }
        defer { watchdog.cancel() }
        _ = try await process.initialize()
        let id = try await process.open(request, resumeId: nil)
        try await process.select(sessionId: id, model: model, effort: effort)
        let turnId = UUID().uuidString
        process.transport.requestInStream(id: turnId, method: "session/prompt",
            params: GeminiProtocol.prompt(sessionId: id, text: request.prompt, attachments: [], supportsImages: true))
        let mcpName = "mcp__mistbrowser__fixture_status"
        var permissions = 0, shellRuns = 0, mcpRuns = 0, ended = false, toolStatuses: [String] = []
        for await output in process.transport.output {
            guard case let .message(message) = output else { throw Failure.timedOut }
            let params = message["params"], update = params["update"]
            if let status = update["status"].string, let call = GeminiToolCall(update) {
                toolStatuses.append("\(call.name)/\(status)")
            }
            if message["method"].string == "session/request_permission" {
                // MCP calls must reach Mist's permission path too: Gemini CLI's own policy must never decide them.
                guard params["sessionId"].string == id, let call = GeminiToolCall(params["toolCall"]),
                      (call.name == "Bash" && call.title.contains("mist-gemini-acp-ok")) || call.name == mcpName
                else { throw Failure.badPermission }
                let permission = GeminiPermission(rpcId: message["id"], tool: call, options: params["options"].array)
                let reply = permission.reply(allows: true)
                guard reply["outcome"]["optionId"].string == "proceed_once" else { throw Failure.badPermission }
                process.transport.reply(id: permission.rpcId, result: reply)
                permissions += 1
            } else if update["sessionUpdate"].string == "tool_call_update", update["status"].string == "completed",
                      let call = GeminiToolCall(update), call.name == "Bash",
                      call.item(update, denied: false).output.contains("mist-gemini-acp-ok") {
                shellRuns += 1
            } else if update["sessionUpdate"].string == "tool_call_update", update["status"].string == "completed",
                      let call = GeminiToolCall(update), call.name == mcpName {
                mcpRuns += 1
            } else if message["id"].string == turnId {
                ended = message["result"]["stopReason"].string == "end_turn"
                break
            }
        }
        guard ended else { throw Failure.missingPrompt }
        let audit = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(Audit.self, from: Data($0.utf8))
        }
        guard !audit.isEmpty, audit.allSatisfy({ $0.model == model && $0.thinking?.lowercased() == effort }) else {
            print("Observed model/effort: \(audit.map { "\($0.model)/\($0.thinking ?? "missing")" })")
            throw Failure.badModelOrEffort
        }
        let tools = Set(audit.flatMap(\.tools))
        print("Gemini API model and effort: \(model) / \(effort)")
        print("Gemini API tools: " + tools.sorted().joined(separator: ", "))
        guard permissions == 2 && shellRuns == 1 && mcpRuns == 1 else {
            print("Observed \(permissions) permission requests, \(shellRuns) completed shell calls with the expected output and \(mcpRuns) completed MCP calls. Tool updates: \(toolStatuses)")
            throw Failure.toolDidNotRun
        }
        // v0.70 exposes read_many_files through ACP's @file preprocessing, outside the model's tool list.
        let expected = Set(GeminiProtocol.builtInNames.keys).subtracting(["read_many_files"]).union(["mcp_mistbrowser_fixture_status"])
        guard tools == expected else { throw Failure.badToolList }

        try await stop(process)
        let reopened = try await GeminiProcess.launch(request, environment: environment, readKey: { _ in key })
        defer { reopened.transport.terminateNow() }
        _ = try await reopened.initialize()
        let restored = try await reopened.open(request, resumeId: id)
        guard restored == id else { throw Failure.badResume }
        try await stop(reopened)
        print("Gemini ACP shell and MCP permissions, tool output, dormant session load, and exit on stdin EOF passed.")
    }

    /// `terminate()` closes stdin and sends SIGTERM only 2 s later, so an exit well before that is the CLI
    /// leaving with its pipe, which is what keeps a Mist quit or crash from orphaning it.
    private static func stop(_ process: GeminiProcess) async throws {
        let start = Date()
        process.transport.terminate()
        for await _ in process.transport.output {}
        guard Date().timeIntervalSince(start) < 1.5 else { throw Failure.slowExit }
    }
}
