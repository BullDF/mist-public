import AppKit
import XCTest
@testable import Phi

@MainActor
final class AgentChatMiniatureTests: XCTestCase {
    private func items(_ count: Int) -> [AgentChatItem] {
        var items = [AgentChatItem(id: "user", kind: .userMessage(text: "Check the build", images: []))]
        for index in 0..<count {
            items.append(AgentChatItem(id: "tool\(index)", kind: .toolCall(.init(toolUseId: "tool\(index)", name: "Bash",
                inputSummary: "ls", inputJSON: #"{"command":"ls"}"#, status: .succeeded))))
            items.append(AgentChatItem(id: "text\(index)", kind: .assistantText(text: "Step \(index): **done**, all fine.", isStreaming: false)))
        }
        return items
    }

    private func miniature(_ conversation: AgentConversation) -> AgentChatMiniatureView {
        let view = AgentChatMiniatureView(frame: NSRect(x: 0, y: 0, width: 398, height: 249))
        view.show(.init(conversation: conversation, folder: FileManager.default.temporaryDirectory, engine: .claude))
        return view
    }

    func testPicturesTheTranscriptAndSkipsUnchangedRenders() throws {
        let conversation = AgentConversation()
        conversation.update(items: items(1), status: .idle)
        let view = miniature(conversation)
        view.renderNow()
        XCTAssertEqual(view.renderCount, 1)
        let image = try XCTUnwrap(view.image)
        XCTAssertEqual(image.width, 796, "drawn at the card's pixel width, not scaled again")
        // The rows drew: the picture isn't one flat background.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corner = bitmap.colorAt(x: 0, y: 0)
        var differing = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) where bitmap.colorAt(x: x, y: y) != corner { differing += 1 }
        }
        XCTAssertGreaterThan(differing, 50)
        // A short transcript starts at the top, as in its tab.
        XCTAssertEqual(view.pictureFrame.minY, 0)
        XCTAssertLessThan(view.pictureFrame.height, 249)

        view.renderNow()
        XCTAssertEqual(view.renderCount, 1, "nothing it shows changed")
        conversation.update(items: items(30), status: .idle)
        view.renderNow()
        XCTAssertEqual(view.renderCount, 2)
        // A long one shows its end at the bottom.
        XCTAssertEqual(view.pictureFrame.maxY, 249, accuracy: 0.5)
    }
}
