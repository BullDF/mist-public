import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeSessionSettingsTests: XCTestCase {


    private func json(_ text: String) throws -> ClaudeCodeJSON {
        try JSONDecoder().decode(ClaudeCodeJSON.self, from: Data(text.utf8))
    }

    @MainActor
    func testAllControlRequestsUseTheVerifiedEnvelope() throws {
        let settings = ClaudeCodeSessionSettings(config: .init(folder: URL(fileURLWithPath: "/tmp")))
        var sent: [String] = []
        settings.send = { sent.append($0) }
        settings.isEnabled = true
        let changes: [(ClaudeCodeSessionSettings.Change, String)] = [
            (.model(.sonnet), #"{"subtype":"set_model","model":"sonnet"}"#),
            (.effort(.medium), #"{"subtype":"apply_flag_settings","settings":{"effortLevel":"medium"}}"#),
        ]
        for (index, entry) in changes.enumerated() {
            settings.change(entry.0, requestId: String(index))
            let request = try json(try XCTUnwrap(sent.last))
            XCTAssertEqual(request["type"].string, "control_request")
            XCTAssertEqual(request["request_id"].string, String(index))
            XCTAssertEqual(request["request"], try json(entry.1))
        }
        XCTAssertEqual(settings.config.model, .opus)
        XCTAssertEqual(settings.config.effort, .xhigh)
        settings.end()
        XCTAssertNil(settings.change(.model(.fable)))
    }

    @MainActor
    func testCorrelationSuccessFailureAndDefaultPermissionAlias() throws {
        let config = ClaudeCodeLaunchConfig(folder: URL(fileURLWithPath: "/tmp"))
        let settings = ClaudeCodeSessionSettings(config: config)
        settings.send = { _ in }
        settings.isEnabled = true
        settings.change(.model(.sonnet), requestId: "model")
        settings.change(.effort(.low), requestId: "effort")
        XCTAssertNil(settings.receive(try json(#"{"response":{"request_id":"unknown","subtype":"success"}}"#)))
        XCTAssertEqual(settings.config, config)
        XCTAssertEqual(settings.receive(try json(#"{"response":{"request_id":"effort","subtype":"success"}}"#)), .confirmed(resolvedModel: nil))
        XCTAssertEqual(settings.config.effort, .low)
        XCTAssertEqual(settings.config.model, .opus)
        XCTAssertEqual(settings.receive(try json(#"{"response":{"request_id":"model","subtype":"success","response":{"model":"claude-sonnet-5-5"}}}"#)), .confirmed(resolvedModel: "claude-sonnet-5-5"))
        XCTAssertEqual(settings.config.model, .sonnet)
        XCTAssertNil(settings.receive(try json(#"{"response":{"request_id":"model","subtype":"error","error":"late duplicate"}}"#)))
        settings.change(.model(.fable), requestId: "bad")
        XCTAssertEqual(settings.receive(try json(#"{"response":{"request_id":"bad","subtype":"error","error":"Rejected model","error_code":"invalid_model"}}"#)), .failed("Rejected model"))
        XCTAssertEqual(settings.config.model, .sonnet)
        settings.change(.effort(.max), requestId: "closed")
        settings.end()
        XCTAssertNil(settings.receive(try json(#"{"response":{"request_id":"closed","subtype":"success"}}"#)))
        XCTAssertEqual(settings.config.effort, .low)
    }

    @MainActor
    func testSessionPublishesFailureNoticeAndRefreshesResolvedStatusModelWhileRunning() throws {
        let conversation = AgentConversation()
        var sent: [String] = []
        let config = ClaudeCodeLaunchConfig(folder: URL(fileURLWithPath: "/tmp"))
        let session = ClaudeCodeSession(config: config, conversation: conversation, controlWriter: { sent.append($0) })
        defer { session.close() }
        session.receive(.event(.stream(try json(#"{"event":{"type":"message_start","message":{"id":"m"}}}"#))))
        // Settings remain usable while a turn is running.
        session.receive(.event(.permission(try json(#"{"request_id":"p","request":{"tool_name":"Read","input":{"file_path":"file"}}}"#))))
        session.settings.change(.model(.sonnet), requestId: "model")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(session.settings.config.model, .opus)
        session.receive(.event(.controlResponse(try json(#"{"response":{"subtype":"success","request_id":"model","response":{"model":"claude-sonnet-5-5"}}}"#))))
        XCTAssertEqual(session.settings.config.model, .sonnet)
        XCTAssertEqual(session.transcript.resolvedModelId, "claude-sonnet-5-5")
        XCTAssertEqual(conversation.status, .awaitingPermission)
        session.settings.change(.model(.fable), requestId: "bad")
        session.receive(.event(.controlResponse(try json(#"{"response":{"subtype":"error","request_id":"bad","error":"Not available"}}"#))))
        XCTAssertEqual(session.settings.config.model, .sonnet)
        XCTAssertEqual(conversation.items.last?.kind, .notice(text: "Not available", level: .error))
        XCTAssertEqual(conversation.status, .awaitingPermission)
    }
}
