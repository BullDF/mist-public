import AppKit
import Foundation

extension SlackAgentConnection {
    static let shared = SlackAgentConnection(
        service: .shared, defaults: .standard,
        bundleID: Bundle.main.bundleIdentifier ?? "",
        threads: SlackThreadStore(url: AgentChatStore.shared.route.directory.deletingLastPathComponent().appendingPathComponent("SlackThreads.json"),
                                  log: { AppLogDebug($0) }),
        connect: { URLSessionSlackSocket(task: APIClient.shared.slackSocket($0)) },
        terminationNotification: NSApplication.willTerminateNotification,
        log: { AppLogDebug($0) })
}
