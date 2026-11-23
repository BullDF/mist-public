import Foundation

struct AgentChatResume: Equatable, Sendable {
    var sessionId: String?
    var items: [AgentChatItem]
}

/// The CLI engines share lifecycle and browser-tool approval hooks.
@MainActor
protocol AgentChatSession: AnyObject {
    var resumeId: String? { get }
    var automaticallyAllows: ((String, Bool) -> Bool)? { get set }
    var onToolPaths: (([String]) -> Void)? { get set }
    var agentTextTransform: ((String) -> String)? { get set }
    var onStarted: ((Int32) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    func approvePendingBrowserTools()
    func close()
    func terminateNow()
}

@MainActor
protocol DrifterBackgroundTaskSession: AgentChatSession {
    func backgroundTaskEnded(taskId: String, summary: String, status: AgentChatItem.TaskNotificationStatus)
}
