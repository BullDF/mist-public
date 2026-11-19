import Foundation

@main
struct ClaudeCodeLiveSmoke {
    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mist-claude-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = AgentConversation()
        let config = ClaudeCodeLaunchConfig(folder: folder, model: .sonnet, effort: .low)
        let session = ClaudeCodeSession(request: .init(prompt: "Reply exactly READY. Do not use tools.", attachments: [], config: config, launchArguments: ["--model", "sonnet", "--effort", "low", "--permission-mode", "default"]), conversation: conversation)
        defer { session.close() }
        try await wait(conversation, for: .idle)
        print("PASS text turn: idle")
        let id = session.sessionId
        conversation.onSend?("Use Bash to run exactly `touch b.txt` in the current directory. Use no other tools or commands. Then say Done.", [], [])
        try await wait(conversation, for: .awaitingPermission)
        guard let request = conversation.items.compactMap({ item -> AgentChatItem.PermissionRequest? in
            if case let .permissionRequest(request) = item.kind, request.status == .pending { return request }
            return nil
        }).first else { throw Failure(message: "No pending permission") }
        guard request.toolName == "Bash", request.summary == "touch b.txt" else { throw Failure(message: "Unexpected permission: \(request)") }
        conversation.onPermissionDecision?(request.requestId, .allow)
        try await wait(conversation, for: .idle)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.txt").path),
              conversation.items.contains(where: { if case let .toolCall(tool) = $0.kind { return tool.status == .succeeded }; return false }) else {
            throw Failure(message: "Permission did not complete the tool")
        }
        print("PASS permission allow: awaitingPermission -> running -> idle; b.txt exists")
        conversation.onSend?("Reply exactly FOLLOWUP. Do not use tools.", [], [])
        try await wait(conversation, for: .idle)
        guard session.sessionId == id else { throw Failure(message: "Session changed between turns") }
        let turns = conversation.items.filter { if case .turnEnd = $0.kind { return true }; return false }.count
        guard turns == 3 else { throw Failure(message: "Expected three turns, got \(turns)") }
        print("PASS follow-up turn: idle; same session")
        conversation.onClose?()
        try await wait(conversation, for: .ended)
        print("PASS termination: ended")
    }

    @MainActor
    static func wait(_ conversation: AgentConversation, for status: AgentConversationStatus) async throws {
        let deadline = Date().addingTimeInterval(90)
        while conversation.status != status {
            if case let .failed(message) = conversation.status { throw Failure(message: message) }
            guard Date() < deadline else { throw Failure(message: "Timed out waiting for \(status); got \(conversation.status)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
