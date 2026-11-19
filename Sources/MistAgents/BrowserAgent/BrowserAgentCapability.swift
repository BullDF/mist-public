import Foundation

/// How Mist admits a connection presenting a Drifter chat's capability.
enum BrowserAgentAdmission: Equatable {
    case refused
    /// No turn runs: only a `/phi-agent` channel, serving `BrowserAgentCapability.outsideTurnTypes`.
    case outsideTurn
    case turn
}

enum BrowserAgentCapability {
    /// Requests a chat's helpers may make outside a turn. Codex lists a resumed chat's MCP tools
    /// once per process, before Mist starts its first turn (#72).
    static let outsideTurnTypes: Set<String> = ["agentSpace.slack.tools"]

    /// The CLI must still be Mist's direct child; helpers must descend from that exact launch.
    static func admits(peer: Int32?, cli: Int32?, mist: Int32, sameLaunch: Bool,
                       parent: (Int32) -> Int32?) -> Bool {
        guard sameLaunch, let cli, cli > 1, parent(cli) == mist, var pid = peer else { return false }
        var seen = Set<Int32>()
        for _ in 0..<64 {
            guard pid > 1, seen.insert(pid).inserted else { return false }
            if pid == cli { return true }
            guard let next = parent(pid) else { return false }
            pid = next
        }
        return false
    }
}
