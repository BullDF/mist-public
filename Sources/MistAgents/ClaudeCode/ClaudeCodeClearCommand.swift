import Foundation

enum ClaudeCodeClearCommand {
    static var command: ClaudeCodeSlashCommand {
        .init(name: "clear", description: NSLocalizedString("browser.chatPanel.newChat", value: "New Chat", comment: "Start a new conversation: the Chat panel's and the Drifter home page's button, and the description of the /clear command in agent chats"), argumentHint: "", builtin: true, isSkill: false)
    }
    static func matches(_ text: String) -> Bool {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return false }
        return ["/clear", "/reset", "/new"].contains(token)
    }
}
