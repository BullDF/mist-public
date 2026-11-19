import Foundation

enum AgentSidebarStatus: Equatable {
    case none, running, background, needsInput, done, failed

    /// `background`: an idle chat with a background task or Monitor still running, shown over the done dot.
    /// `waitsForUser`: a hand-off card waits for Johnny's Done, which needs him once the turn is over.
    static func marker(for status: AgentConversationStatus?, isUnseenCompletion: Bool, hasBackgroundTasks: Bool = false,
                       waitsForUser: Bool = false) -> Self {
        switch status {
        case .starting, .running: return .running
        case .awaitingPermission: return .needsInput
        case .failed: return .failed
        case .idle where !waitsForUser: return hasBackgroundTasks ? .background : isUnseenCompletion ? .done : .none
        case .idle, .ended, .dormant, nil: return waitsForUser ? .needsInput : .none
        }
    }
}
