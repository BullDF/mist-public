import Foundation

enum MistAppPlaceholder {
    static func html(title: String, background: String, iconPNGBase64: String?, app: MistAppID, agent: String? = nil) -> String {
        let icon = iconPNGBase64.map { "<link rel=\"icon\" href=\"data:image/png;base64,\(escape($0))\">" } ?? ""
        let agentMeta = agent.map { "<meta name=\"mist-agent\" content=\"\(escape($0))\">" } ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"mist-app\" content=\"\(app.rawValue)\">\(agentMeta)<title>\(escape(title))</title>\(icon)<style>html{background:\(background)}</style></head><body></body></html>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
