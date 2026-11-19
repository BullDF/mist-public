import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentSidebarStatusTests: XCTestCase {
    func testStatusMapping() {
        for unseen in [false, true] {
            XCTAssertEqual(AgentSidebarStatus.marker(for: .starting, isUnseenCompletion: unseen), .running)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .running, isUnseenCompletion: unseen), .running)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .awaitingPermission, isUnseenCompletion: unseen), .needsInput)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .idle, isUnseenCompletion: unseen), unseen ? .done : .none)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .failed("error"), isUnseenCompletion: unseen), .failed)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .ended, isUnseenCompletion: unseen), .none)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .dormant, isUnseenCompletion: unseen), .none)
            XCTAssertEqual(AgentSidebarStatus.marker(for: nil, isUnseenCompletion: unseen), .none)
            // Background work shows only on an idle chat, over the done dot.
            XCTAssertEqual(AgentSidebarStatus.marker(for: .idle, isUnseenCompletion: unseen, hasBackgroundTasks: true), .background)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .running, isUnseenCompletion: unseen, hasBackgroundTasks: true), .running)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .awaitingPermission, isUnseenCompletion: unseen, hasBackgroundTasks: true), .needsInput)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .failed("error"), isUnseenCompletion: unseen, hasBackgroundTasks: true), .failed)
            // A hand-off waiting for Done needs Johnny once the turn is over, over the done dot and background ring.
            for status in [AgentConversationStatus.idle, .dormant, .ended, nil] {
                XCTAssertEqual(AgentSidebarStatus.marker(for: status, isUnseenCompletion: unseen, hasBackgroundTasks: true, waitsForUser: true), .needsInput)
            }
            XCTAssertEqual(AgentSidebarStatus.marker(for: .running, isUnseenCompletion: unseen, waitsForUser: true), .running)
            XCTAssertEqual(AgentSidebarStatus.marker(for: .failed("error"), isUnseenCompletion: unseen, waitsForUser: true), .failed)
        }
    }
}
