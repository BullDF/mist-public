import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentMessageQueueTests: XCTestCase {
    func testTaskStatusRoundTripsAndLegacySenderIgnoresRemovedField() throws {
        for status in [AgentTaskFinishStatus.done, .blocked] {
            var sender = AgentMessageSender(id: "abcd", title: "Child", kind: .report)
            sender.taskStatus = status
            XCTAssertEqual(try JSONDecoder().decode(AgentMessageSender.self, from: JSONEncoder().encode(sender)), sender)
        }
        let legacy = Data(#"{"id":"abcd","title":"Child","kind":"report","stillRunning":true}"#.utf8)
        let sender = try JSONDecoder().decode(AgentMessageSender.self, from: legacy)
        XCTAssertNil(sender.taskStatus)
        XCTAssertEqual(sender.header, "[Report from child chat abcd (Child)]")
    }

    func testDraftImageCapKeepsEveryFile() {
        let image = AgentAttachment.image(.init(data: Data([1]), mediaType: "image/png"))
        let file = AgentAttachment.file(.init(url: URL(fileURLWithPath: "/file.txt")))
        let draft = AgentComposerDraft(attachments: Array(repeating: image, count: 10) + [file])
        let merged = draft.prepending(.init(text: "", attachments: [image, file]))
        XCTAssertEqual(merged.attachments.images.count, 10)
        XCTAssertEqual(merged.attachments.files.count, 2)
    }

    func testMoveToFrontPreservesOtherMessagesAndPause() {
        var queue = AgentMessageQueue()
        let messages = (0..<3).map { AgentQueuedMessage(text: String($0)) }
        messages.forEach { queue.enqueue($0) }
        queue.pause()
        queue.moveToFront(messages[2].id)
        XCTAssertEqual(queue.messages.map(\.text), ["2", "0", "1"])
        XCTAssertTrue(queue.paused)
        queue.moveToFront("missing")
        XCTAssertEqual(queue.messages.map(\.text), ["2", "0", "1"])
    }
    func testDeliveringCannotBeRemovedButCanBeTaken() {
        var queue = AgentMessageQueue()
        let message = AgentQueuedMessage(text: "Hello")
        XCTAssertEqual(message.id, message.id.lowercased())
        queue.enqueue(message)
        queue.markDelivering(message.id)
        XCTAssertNil(queue.remove(message.id))
        XCTAssertEqual(queue.take(message.id)?.text, "Hello")
        XCTAssertTrue(queue.messages.isEmpty)
    }

    func testReturningDeliveriesPreservesOrderAheadOfWaitingMessages() {
        var queue = AgentMessageQueue()
        let messages = (0..<4).map { AgentQueuedMessage(text: String($0)) }
        messages.forEach { queue.enqueue($0) }
        queue.markDelivering(messages[1].id)
        queue.markDelivering(messages[3].id)
        queue.returnDelivering()
        XCTAssertEqual(queue.messages.map(\.text), ["1", "3", "0", "2"])
        XCTAssertFalse(queue.messages.contains(where: \.delivering))
    }

    func testPausePersistsAcrossNewMessagesAndResetsWhenEmpty() {
        var queue = AgentMessageQueue()
        let first = AgentQueuedMessage(text: "First"), second = AgentQueuedMessage(text: "Second")
        queue.enqueue(first)
        queue.pause()
        queue.enqueue(second)
        queue.remove(first.id)
        XCTAssertTrue(queue.paused)
        queue.resume()
        XCTAssertFalse(queue.paused)
        queue.pause()
        queue.remove(second.id)
        XCTAssertFalse(queue.paused)
        queue.pause()
        XCTAssertFalse(queue.paused)
    }
}
