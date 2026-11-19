import Foundation

@main
struct CodexLiveSmoke {
    struct Failure: Error { let message: String }

    @MainActor
    static func main() async throws {
        let snapshot = try await CodexModelCatalog.shared.load()
        guard snapshot.account == .chatgpt else { throw CodexError.chatGPTLoginRequired }
        // Prefer the oldest available Luna: this is a tiny protocol smoke test.
        let models = snapshot.models.sorted { $0.id < $1.id }
        guard let model = models.first(where: { $0.id.contains("luna") }) ?? models.last,
              let effort = model.efforts.first else { throw Failure(message: "No models") }
        let captured = await ClaudeCodeEnvironment.shared.value
        guard let node = ClaudeCodeEnvironment.findExecutable(name: "node", environment: captured.variables,
            home: FileManager.default.homeDirectoryForCurrentUser) else { throw Failure(message: "Node is missing") }
        let server = CodexMCPServer(command: node.path, args: [CommandLine.arguments[1]])
        let conversation = AgentConversation()
        let request = CodexLaunchRequest(prompt: "Call the mist_test poke tool exactly once with text hello, then say done. Do not retry a declined tool.",
                model: model.id, effort: effort, cwd: FileManager.default.temporaryDirectory,
                developerInstructions: "Use only the mist_test MCP tools. Use exec to invoke them if needed.",
                mcpServers: ["mist_test": server])
        let session = CodexSession(request: request, conversation: conversation)
        defer { session.close() }
        try await wait(conversation, for: .awaitingPermission)
        guard let permission = conversation.items.compactMap({ item -> AgentChatItem.PermissionRequest? in
            if case let .permissionRequest(value) = item.kind, value.status == .pending { return value }; return nil
        }).first, permission.toolName == "mcp__mist_test__poke" else { throw Failure(message: "No write approval") }
        conversation.onPermissionDecision?(permission.requestId, .deny(message: nil))
        try await wait(conversation, for: .idle)
        guard conversation.items.contains(where: { item in
            if case let .toolCall(value) = item.kind {
                return value.name == "mcp__mist_test__poke" && value.status == .failed && value.output.contains("rejected")
            }
            return false
        }), conversation.items.contains(where: { if case .turnEnd = $0.kind { return true }; return false }) else {
            throw Failure(message: "Missing tool result or turn end")
        }
        print("PASS declined write: tool result and turn end")
        session.close()
        try await wait(conversation, for: .ended)
        print("PASS process shutdown")
        guard let name = await CodexMarkerNamer.name(text: "Keep the relay payload under 64 KiB and split larger files into chunks.",
            context: "How should we send large files through the sync relay?") else { throw Failure(message: "No marker name") }
        print("PASS marker name: \(name)")
    }

    @MainActor
    static func wait(_ conversation: AgentConversation, for status: AgentConversationStatus) async throws {
        let deadline = Date().addingTimeInterval(100)
        while conversation.status != status {
            if case let .failed(message) = conversation.status { throw Failure(message: message) }
            guard Date() < deadline else { throw Failure(message: "Timed out waiting for \(status)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
