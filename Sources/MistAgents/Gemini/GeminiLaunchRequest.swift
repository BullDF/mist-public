import Foundation

struct GeminiLaunchRequest: Sendable {
    let prompt: String
    var attachments: [AgentAttachment] = []
    let model: String
    let effort: String
    let cwd: URL
    let drifterHome: URL
    let cliHome: URL
    /// `gemini-preload.mjs`: enforces the chat's model and thinking level, and exits with stdin.
    let preload: URL
    let instructions: String
    var server: CodexMCPServer?
    var mentions: [AgentTabMention] = []
    var sender: AgentMessageSender?
    var resume: AgentChatResume?

    func prepareHome(models: [String]) throws {
        let settingsFolder = cliHome.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
        try GeminiProtocol.settings(models: models).write(to: settingsFolder.appendingPathComponent("settings.json"), options: .atomic)
        try instructions.write(to: settingsFolder.appendingPathComponent("GEMINI.md"), atomically: true, encoding: .utf8)
    }

    static func writeSelection(model: String, effort: String, in cliHome: URL) throws {
        let value = ["model": model, "thinkingLevel": GeminiProtocol.thinkingLevel(model: model, effort: effort)]
        try JSONEncoder().encode(value).write(to: cliHome.appendingPathComponent("model-selection.json"), options: .atomic)
    }
}
