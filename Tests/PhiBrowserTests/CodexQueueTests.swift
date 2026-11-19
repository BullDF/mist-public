import XCTest
#if !MIST_CODEX_HOSTLESS_TESTS
@testable import Phi
#endif

final class CodexQueueTests: XCTestCase {
    @MainActor func testTaskWakeStartsIdleTurnWithoutPeerRow() async throws {
        let sent = expectation(description: "Task starts turn")
        let sender = AgentMessageSender(id: "task-abc123", title: "Build", kind: .task, note: "Background task finished")
        let session = session { method, params in
            XCTAssertEqual(method, "turn/start")
            XCTAssertEqual(params["input"].array.first?["text"].string, sender.agentText("Done"))
            sent.fulfill()
            return self.startedReply
        }
        XCTAssertTrue(session.conversation.deliver(.init(text: "Done", sender: sender)))
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertTrue(session.conversation.items.isEmpty)
        XCTAssertEqual(session.conversation.status, .running)
        session.close()
    }

    @MainActor func testTaskWakeQueuesThenStartsNextTurnWithoutPeerRow() async throws {
        let sent = expectation(description: "Task starts next turn")
        let sender = AgentMessageSender(id: "task-abc123", title: "Build", kind: .task, note: "Background task finished")
        let session = session { method, params in
            XCTAssertEqual(method, "turn/start")
            XCTAssertEqual(params["input"].array.first?["text"].string, sender.agentText("Done"))
            sent.fulfill()
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        XCTAssertTrue(session.conversation.deliver(.init(text: "Done", sender: sender)))
        XCTAssertEqual(session.conversation.queue.count, 1)
        XCTAssertTrue(session.conversation.items.isEmpty)
        session.receive(turn("turn/completed"))
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertTrue(session.conversation.queue.isEmpty)
        XCTAssertFalse(session.conversation.items.contains { if case .peerMessage = $0.kind { return true }; return false })
        XCTAssertEqual(session.conversation.status, .running)
        session.close()
    }

    @MainActor func testTaskWakeSteerEchoDoesNotAppendRow() async throws {
        let steered = expectation(description: "Task steered")
        let session = session { method, _ in
            XCTAssertEqual(method, "turn/steer"); steered.fulfill(); return .null
        }
        session.receive(turn("turn/started"))
        XCTAssertTrue(session.conversation.deliver(.init(text: "Tick", sender: .init(id: "task-abc123", title: "Watch", kind: .task))))
        let id = try XCTUnwrap(session.conversation.queue.first?.id)
        session.receive(item("commandExecution"))
        await fulfillment(of: [steered], timeout: 2)
        let beforeEcho = session.conversation.items
        session.receive(item("userMessage", clientId: id))
        XCTAssertEqual(session.conversation.items, beforeEcho)
        XCTAssertTrue(session.conversation.queue.isEmpty)
        session.close()
    }

    @MainActor func testPeerDeliveryWrapsTransformedBodyAndRetainsSenderThroughSteerEcho() async throws {
        var requests: [(String, CodexJSON)] = []
        let sent = expectation(description: "Started peer turn")
        let steered = expectation(description: "Steered peer message")
        let session = session { method, params in
            requests.append((method, params))
            if method == "turn/start" { sent.fulfill() } else { steered.fulfill() }
            return self.startedReply
        }
        let conversation = session.conversation
        let sender = AgentMessageSender(id: "abcd", title: "/skill title")
        var transformed: [String] = []
        session.agentTextTransform = { transformed.append($0); return "skill-expanded:" + $0 }
        conversation.setDraft(.init(text: "My draft"))
        XCTAssertTrue(conversation.deliver(.init(text: "/skill body", sender: sender)))
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(requests.first?.1["input"].array.first?["text"].string,
                       sender.header + "\n\nskill-expanded:/skill body")
        XCTAssertEqual(transformed, ["/skill body"])
        XCTAssertEqual(conversation.items.last?.kind, .peerMessage(name: sender.label, body: "/skill body"))
        XCTAssertEqual(conversation.draft.text, "My draft")
        session.receive(turn("turn/started"))
        XCTAssertTrue(conversation.deliver(.init(text: "Queued body", sender: sender)))
        let queued = try XCTUnwrap(conversation.queue.first)
        XCTAssertEqual(queued.sender, sender)
        session.receive(item("commandExecution"))
        await fulfillment(of: [steered], timeout: 2)
        XCTAssertEqual(requests.last?.0, "turn/steer")
        XCTAssertEqual(requests.last?.1["input"].array.first?["text"].string,
                       sender.header + "\n\nskill-expanded:Queued body")
        session.receive(item("userMessage", clientId: queued.id))
        XCTAssertEqual(conversation.items.last?.kind, .peerMessage(name: sender.label, body: "Queued body"))
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(transformed, ["/skill body", "Queued body"])
    }

    @MainActor func testPausedPeerMessageSentFromIdleRetainsSender() async throws {
        let sent = expectation(description: "Peer sent from idle")
        let sender = AgentMessageSender(id: "abcd", title: "Sender")
        let session = session { method, params in
            XCTAssertEqual(method, "turn/start")
            XCTAssertEqual(params["input"].array.first?["text"].string, sender.agentText("Peer"))
            sent.fulfill()
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("Hold", [], [])
        session.conversation.onStop?()
        XCTAssertTrue(session.conversation.deliver(.init(text: "Peer", sender: sender)))
        XCTAssertTrue(session.conversation.queuePaused)
        let peer = try XCTUnwrap(session.conversation.queue.last)
        session.receive(turn("turn/completed"))
        session.conversation.onSendQueuedNow?(peer.id)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(session.conversation.items.last?.kind, .peerMessage(name: sender.label, body: "Peer"))
    }

    @MainActor
    private func session(_ writer: @escaping (String, CodexJSON) async throws -> CodexJSON) -> CodexSession {
        CodexSession(request: .init(prompt: "Start", model: "model", effort: "high", cwd: URL(fileURLWithPath: "/tmp")),
            conversation: AgentConversation(), requestWriter: writer)
    }

    private func turn(_ method: String, id: String = "turn", status: String = "completed") -> CodexProcess.Output {
        .message(.object(["method": .string(method), "params": .object([
            "turn": .object(["id": .string(id), "status": .string(status)])])]))
    }

    private func item(_ type: String, clientId: String? = nil, method: String = "item/completed") -> CodexProcess.Output {
        var value: [String: CodexJSON] = ["id": .string(UUID().uuidString), "type": .string(type)]
        if let clientId { value["clientId"] = .string(clientId) }
        return .message(.object(["method": .string(method), "params": .object(["item": .object(value)])]))
    }

    private var startedReply: CodexJSON { .object(["turn": .object(["id": .string("next")])]) }

    @MainActor func testSteerOnlyAfterToolCompletionThenTakeEchoOnce() async throws {
        var requests: [(String, CodexJSON)] = []
        let sent = expectation(description: "Steered")
        let session = session { method, params in requests.append((method, params)); sent.fulfill(); return .object(["turnId": .string("turn")]) }
        let conversation = session.conversation
        session.receive(turn("turn/started"))
        let started = conversation.turnStartedAt
        let image = AgentImageAttachment(data: Data([1]), mediaType: "image/png")
        let mention = AgentTabMention(tabId: 7, title: "Tab", url: "https://example.com", range: NSRange(location: 0, length: 4))
        conversation.onQueue?("@Tab steer", [.image(image)], [mention])
        let id = try XCTUnwrap(conversation.queue.first?.id)
        for type in ["userMessage", "agentMessage", "reasoning", "plan", "hookPrompt"] { session.receive(item(type)) }
        session.receive(item("commandExecution", method: "item/started"))
        XCTAssertTrue(requests.isEmpty)
        session.receive(item("commandExecution"))
        XCTAssertEqual(conversation.queue.first?.delivering, true)
        conversation.onRemoveQueued?(id)
        XCTAssertEqual(conversation.queue.count, 1)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(requests.map(\.0), ["turn/steer"])
        let params = try XCTUnwrap(requests.first?.1)
        XCTAssertEqual(params["clientUserMessageId"].string, id)
        XCTAssertEqual(params["expectedTurnId"].string, "turn")
        XCTAssertEqual(params["threadId"].string, session.threadId)
        XCTAssertEqual(params["input"].array.last?["url"].string, "data:image/png;base64,AQ==")
        XCTAssertTrue(params["input"].array.first?["text"].string?.contains("7 · Tab") == true)
        session.receive(item("userMessage", clientId: id, method: "item/started"))
        session.receive(item("userMessage", clientId: id))
        XCTAssertTrue(conversation.queue.isEmpty)
        XCTAssertEqual(conversation.items.last?.kind, .userMessage(text: "@Tab steer", images: [image]))
        XCTAssertEqual(conversation.items.last?.mentions, [mention])
        XCTAssertEqual(conversation.turnStartedAt, started)
        XCTAssertEqual(conversation.items.filter { if case .userMessage = $0.kind { return true }; return false }.count, 1)
    }

    @MainActor func testEveryToolLikeCompletionCanSteerRowsInOrder() async throws {
        for type in ["mcpToolCall", "fileChange", "futureTool"] {
            var ids: [String] = []
            let sent = expectation(description: type); sent.expectedFulfillmentCount = 2
            let session = session { _, params in ids.append(params["clientUserMessageId"].string!); sent.fulfill(); return .null }
            session.receive(turn("turn/started"))
            session.conversation.onQueue?("One", [], [])
            session.conversation.onQueue?("Two", [], [])
            let expected = session.conversation.queue.map(\.id)
            session.receive(item(type))
            await fulfillment(of: [sent], timeout: 2)
            XCTAssertEqual(ids, expected)
        }
    }

    @MainActor func testSteerFailureReturnsRowsForRetry() async throws {
        let failed = expectation(description: "Failed")
        var count = 0
        let session = session { _, _ in count += 1; failed.fulfill(); throw CodexError.invalidResponse }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("One", [], [])
        session.conversation.onQueue?("Two", [], [])
        session.receive(item("mcpToolCall"))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(session.conversation.queue.map(\.text), ["One", "Two"])
        XCTAssertFalse(session.conversation.queue.contains(where: \.delivering))
        XCTAssertEqual(session.conversation.status, .running)
    }

    @MainActor func testTurnEndReturnsDeliveringRowsAndStartsFirst() async throws {
        var requests: [(String, CodexJSON)] = []
        let steered = expectation(description: "Steered"); steered.expectedFulfillmentCount = 2
        let started = expectation(description: "Started")
        let session = session { method, params in
            requests.append((method, params))
            if method == "turn/steer" { steered.fulfill() } else { started.fulfill() }
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("One", [], [])
        session.conversation.onQueue?("Two", [], [])
        let ids = session.conversation.queue.map(\.id)
        session.receive(item("commandExecution"))
        await fulfillment(of: [steered], timeout: 2)
        session.receive(turn("turn/completed"))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(session.conversation.items.last?.kind, .userMessage(text: "One", images: []))
        XCTAssertEqual(requests.last?.0, "turn/start")
        XCTAssertEqual(requests.last?.1["clientUserMessageId"].string, ids[0])
        XCTAssertEqual(session.conversation.queue.map(\.text), ["Two"])
        XCTAssertEqual(session.conversation.queue.first?.delivering, false)
        XCTAssertEqual(session.conversation.status, .running)
        session.receive(turn("turn/started", id: "next"))
        session.receive(turn("turn/completed"))
        XCTAssertEqual(session.conversation.queue.map(\.text), ["Two"])
        XCTAssertEqual(session.conversation.status, .running)
    }

    @MainActor func testStopPausesQueueAcrossFreshTurnsAndDeleteWithdrawsHeldRows() async throws {
        var methods: [String] = []
        let interrupted = expectation(description: "Interrupted")
        let started = expectation(description: "Fresh turn")
        let session = session { method, _ in
            methods.append(method)
            if method == "turn/interrupt" { interrupted.fulfill() } else { started.fulfill() }
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("Held", [], [])
        session.stop()
        await fulfillment(of: [interrupted], timeout: 2)
        session.receive(turn("turn/completed", status: "interrupted"))
        XCTAssertTrue(session.conversation.queuePaused)
        XCTAssertEqual(session.conversation.status, .idle)
        session.send(text: "Fresh")
        await fulfillment(of: [started], timeout: 2)
        session.receive(turn("turn/started", id: "next"))
        session.conversation.onQueue?("Also held", [], [])
        session.receive(item("commandExecution"))
        XCTAssertEqual(methods, ["turn/interrupt", "turn/start"])
        XCTAssertEqual(session.conversation.queue.count, 2)
        for row in session.conversation.queue { session.conversation.onRemoveQueued?(row.id) }
        XCTAssertTrue(session.conversation.queue.isEmpty)
        XCTAssertFalse(session.conversation.queuePaused)
    }

    @MainActor func testSendNowInterruptsAndPrioritizesSelectedRow() async throws {
        var requests: [(String, CodexJSON)] = []
        let interrupted = expectation(description: "Interrupted"), started = expectation(description: "Started")
        let session = session { method, params in
            requests.append((method, params))
            if method == "turn/interrupt" { interrupted.fulfill() } else { started.fulfill() }
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("Later", [], [])
        session.conversation.onQueue?("Now", [], [])
        let id = try XCTUnwrap(session.conversation.queue.last?.id)
        session.conversation.onSendQueuedNow?(id)
        XCTAssertFalse(session.conversation.queuePaused)
        await fulfillment(of: [interrupted], timeout: 2)
        XCTAssertEqual(requests.first?.1["turnId"].string, "turn")
        session.receive(turn("turn/completed", status: "interrupted"))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(session.conversation.items.last?.kind, .userMessage(text: "Now", images: []))
        XCTAssertEqual(session.conversation.queue.map(\.text), ["Later"])
        XCTAssertFalse(session.conversation.queuePaused)
    }

    @MainActor func testIdleSendNowResumesAndSessionEndClearsQueue() async throws {
        let interrupted = expectation(description: "Interrupted"), started = expectation(description: "Started")
        let session = session { method, _ in
            if method == "turn/interrupt" { interrupted.fulfill() } else { started.fulfill() }
            return self.startedReply
        }
        session.receive(turn("turn/started"))
        session.conversation.onQueue?("One", [], [])
        session.conversation.onQueue?("Two", [], [])
        session.stop()
        await fulfillment(of: [interrupted], timeout: 2)
        session.receive(turn("turn/completed", status: "interrupted"))
        session.conversation.onSendQueuedNow?(try XCTUnwrap(session.conversation.queue.last?.id))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(session.conversation.queuePaused)
        XCTAssertEqual(session.conversation.items.last?.kind, .userMessage(text: "Two", images: []))
        session.close()
        XCTAssertTrue(session.conversation.queue.isEmpty)
    }

    @MainActor func testStopBeforeTurnIdArrivesStillInterruptsAndHoldsMessages() async throws {
        let started = expectation(description: "Started"), interrupted = expectation(description: "Interrupted")
        let session = session { method, _ in
            if method == "turn/start" { started.fulfill() } else { interrupted.fulfill() }
            return self.startedReply
        }
        session.send(text: "Fresh")
        session.conversation.onQueue?("Held", [], [])
        session.stop()
        await fulfillment(of: [started], timeout: 2)
        session.receive(turn("turn/started"))
        await fulfillment(of: [interrupted], timeout: 2)
        XCTAssertTrue(session.conversation.queuePaused)
        session.receive(turn("turn/completed", status: "interrupted"))
        XCTAssertEqual(session.conversation.status, .idle)
        XCTAssertEqual(session.conversation.queue.map(\.text), ["Held"])
    }
}
