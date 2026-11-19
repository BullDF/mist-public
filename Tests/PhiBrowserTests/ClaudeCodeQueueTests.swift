import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class ClaudeCodeQueueTests: XCTestCase {
    @MainActor func testPeerDeliveryWrapsTransformedBodyAndKeepsSenderThroughQueueReplay() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        let sender = AgentMessageSender(id: "abcd", title: "/skill title")
        var transformed: [String] = []
        session.agentTextTransform = { transformed.append($0); return "skill-expanded:" + $0 }
        session.receive(.event(.result(.object([:]))))
        conversation.setDraft(.init(text: "My draft"))
        XCTAssertTrue(conversation.deliver(.init(text: "/skill body", sender: sender)))
        XCTAssertEqual(transformed, ["/skill body"])
        XCTAssertEqual(lines.last { $0["type"].string == "user" }?["message"]["content"].array.last?["text"].string,
                       sender.header + "\n\nskill-expanded:/skill body")
        XCTAssertEqual(conversation.items.last?.kind, .peerMessage(name: sender.label, body: "/skill body"))
        XCTAssertEqual(conversation.draft.text, "My draft")
        XCTAssertTrue(conversation.deliver(.init(text: "Queued body", sender: sender)))
        let queued = try XCTUnwrap(conversation.queue.first)
        XCTAssertEqual(queued.sender, sender)
        XCTAssertEqual(lines.last?["message"]["content"].array.last?["text"].string,
                       sender.header + "\n\nskill-expanded:Queued body")
        session.receive(replay(queued.id))
        XCTAssertEqual(conversation.items.last?.kind, .peerMessage(name: sender.label, body: "Queued body"))
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(transformed, ["/skill body", "Queued body"])
    }

    @MainActor func testPausedPeerQueueRetainsSenderWhenSentFromIdle() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Hold", [], [])
        conversation.onStop?()
        let sender = AgentMessageSender(id: "abcd", title: "Sender")
        let before = lines.count
        XCTAssertTrue(conversation.deliver(.init(text: "Peer", sender: sender)))
        XCTAssertEqual(lines.count, before)
        XCTAssertTrue(conversation.queuePaused)
        let peer = try XCTUnwrap(conversation.queue.last)
        session.receive(.event(.result(.object([:]))))
        conversation.onSendQueuedNow?(peer.id)
        XCTAssertEqual(conversation.items.last?.kind, .peerMessage(name: sender.label, body: "Peer"))
        XCTAssertTrue(lines.contains { $0["message"]["content"].array.last?["text"].string == sender.agentText("Peer") })
    }

    @MainActor
    private func session(_ writer: @escaping (ClaudeCodeJSON) -> Void) -> ClaudeCodeSession {
        let conversation = AgentConversation()
        let session = ClaudeCodeSession(config: .init(folder: URL(fileURLWithPath: "/tmp")), conversation: conversation,
            controlWriter: { writer(try! JSONDecoder().decode(ClaudeCodeJSON.self, from: Data($0.utf8))) })
        session.receive(.event(.result(.object([:]))))
        session.send(text: "Start")
        return session
    }

    private func lifecycle(_ id: String, _ state: String) -> ClaudeCodeProcess.Output {
        .event(.commandLifecycle(.object(["command_uuid": .string(id), "state": .string(state)])))
    }

    private func replay(_ id: String) -> ClaudeCodeProcess.Output {
        .event(.user(.object(["uuid": .string(id), "isReplay": .bool(true)])))
    }

    @MainActor func testEnqueueAndReplayPreserveAttachmentsMentionsAndTurn() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        let image = AgentImageAttachment(data: Data([1, 2]), mediaType: "image/png")
        let mention = AgentTabMention(tabId: 4, title: "Tab", url: "https://example.com", range: NSRange(location: 0, length: 4))
        let started = conversation.turnStartedAt
        conversation.onQueue?("@Tab next", [.image(image)], [mention])
        let message = try XCTUnwrap(conversation.queue.first)
        XCTAssertEqual(lines.last?["uuid"].string, message.id)
        XCTAssertEqual(lines.last?["message"]["content"].array.first?["type"].string, "image")
        XCTAssertEqual(lines.last?["message"]["content"].array.last?["text"].string,
                       "@Tab next\n\nTabs the user mentioned (tabId · title · URL):\n4 · Tab · https://example.com")
        XCTAssertEqual(conversation.items.filter { if case .userMessage = $0.kind { return true }; return false }.count, 1)
        session.receive(replay(message.id))
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "@Tab next", images: [image]))
        XCTAssertEqual(conversation.items.last?.mentions, [mention])
        XCTAssertEqual(conversation.turnStartedAt, started)
        session.receive(replay(message.id))
        XCTAssertEqual(conversation.items.filter { if case .userMessage = $0.kind { return true }; return false }.count, 2)
    }

    @MainActor func testWithdrawalRetainsContentForLosingReplayRace() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Race", [], [])
        let id = try XCTUnwrap(conversation.queue.first?.id)
        conversation.onRemoveQueued?(id)
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(lines.last?["request"]["subtype"].string, "cancel_async_message")
        XCTAssertEqual(lines.last?["request"]["message_uuid"].string, id)
        session.receive(replay(id))
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "Race", images: []))
    }

    @MainActor func testStopHoldsQueueAndLaterEnqueuesAcrossFreshTurns() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Held", [], [])
        let id = try XCTUnwrap(conversation.queue.first?.id)
        conversation.onStop?()
        XCTAssertEqual(lines.last?["request"]["cancel_queued"], .bool(true))
        XCTAssertTrue(conversation.queuePaused)
        session.receive(lifecycle(id, "cancelled"))
        session.receive(.event(.result(.object(["is_error": .bool(true)]))))
        session.send(text: "Fresh")
        let count = lines.count
        conversation.onQueue?("Also held", [], [])
        XCTAssertEqual(lines.count, count)
        XCTAssertEqual(conversation.queue.count, 2)
        XCTAssertTrue(conversation.queuePaused)
        conversation.onRemoveQueued?(id)
        XCTAssertEqual(lines.count, count)
    }

    @MainActor func testSendNowWaitsForQueuedLifecycleAndDisablesRemoval() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Now", [], [])
        let id = try XCTUnwrap(conversation.queue.first?.id), count = lines.count
        conversation.onSendQueuedNow?(id)
        XCTAssertEqual(lines.count, count)
        XCTAssertEqual(conversation.queue.first?.delivering, true)
        conversation.onRemoveQueued?(id)
        XCTAssertEqual(conversation.queue.count, 1)
        session.receive(lifecycle(id, "queued"))
        XCTAssertEqual(lines.last?["request"]["send_now"], .bool(true))
        XCTAssertEqual(lines.last?["request"]["message_uuid"].string, id)
        session.receive(.event(.result(.object(["is_error": .bool(true)]))))
        session.receive(replay(id))
        XCTAssertEqual(conversation.status, .running)
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "Now", images: []))
    }

    @MainActor func testSendNowNotStoppedDoesNotMaskLaterError() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Now", [], [])
        let id = try XCTUnwrap(conversation.queue.first?.id)
        session.receive(lifecycle(id, "queued"))
        conversation.onSendQueuedNow?(id)
        let requestId = try XCTUnwrap(lines.last?["request_id"].string)
        session.receive(.event(.controlResponse(.object(["response": .object([
            "request_id": .string(requestId), "response": .object(["send_now": .string("delivering")])
        ])]))))
        session.receive(replay(id))
        session.receive(.event(.result(.object(["is_error": .bool(true), "result": .string("Actual error")]))))
        XCTAssertEqual(conversation.items.last?.kind, .notice(text: "Actual error", level: .error))
    }

    @MainActor func testIdleSendNowResumesOtherRowsWithFreshUUIDs() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("First", [], [])
        conversation.onQueue?("Second", [], [])
        let ids = conversation.queue.map(\.id)
        session.stop()
        ids.forEach { session.receive(lifecycle($0, "cancelled")) }
        session.receive(.event(.result(.object([:]))))
        conversation.onSendQueuedNow?(ids[0])
        XCTAssertFalse(conversation.queuePaused)
        XCTAssertEqual(conversation.queue.map(\.id), [ids[1]])
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "First", images: []))
        let uuid = try XCTUnwrap(lines.last?["uuid"].string)
        XCTAssertNotEqual(uuid, ids[1])
        session.receive(replay(uuid))
        XCTAssertTrue(conversation.queue.isEmpty)
    }

    @MainActor func testLifecycleDecodeAndSessionEndClearQueue() throws {
        XCTAssertEqual(ClaudeCodeProtocol.decode(Data(#"{"type":"command_lifecycle","command_uuid":"q","state":"queued"}"#.utf8)),
            .commandLifecycle(.object(["type": .string("command_lifecycle"), "command_uuid": .string("q"), "state": .string("queued")])))
        let session = session { _ in }
        session.conversation.onQueue?("Waiting", [], [])
        session.close()
        XCTAssertTrue(session.conversation.queue.isEmpty)
        XCTAssertFalse(session.conversation.queuePaused)
    }

    @MainActor func testResumingDuringTurnKeepsFreshUUIDWhenOldCancellationArrives() throws {
        var lines: [ClaudeCodeJSON] = []
        let session = session { lines.append($0) }, conversation = session.conversation
        conversation.onQueue?("Now", [], [])
        let id = try XCTUnwrap(conversation.queue.first?.id)
        session.stop()
        conversation.onSendQueuedNow?(id)
        let uuid = try XCTUnwrap(lines.last?["uuid"].string)
        XCTAssertNotEqual(uuid, id)
        session.receive(lifecycle(id, "cancelled"))
        session.receive(lifecycle(uuid, "queued"))
        XCTAssertEqual(lines.last?["request"]["message_uuid"].string, uuid)
        let requestId = try XCTUnwrap(lines.last?["request_id"].string)
        session.stop()
        session.receive(.event(.controlResponse(.object(["response": .object([
            "request_id": .string(requestId), "response": .object(["send_now": .string("delivering")])
        ])]))))
        session.receive(.event(.result(.object(["is_error": .bool(true)]))))
        guard case let .turnEnd(_, _, stopped) = conversation.items.last?.kind else { return XCTFail("Missing stopped turn") }
        XCTAssertTrue(stopped)
        XCTAssertTrue(conversation.queuePaused)
        session.receive(replay(uuid))
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "Now", images: []))
    }
}
