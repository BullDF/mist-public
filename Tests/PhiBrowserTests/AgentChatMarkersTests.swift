import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentChatMarkersTests: XCTestCase {
    func testGeneratedNameReplacesOnlyAnUnchangedDefault() {
        var markers = [AgentChatMarker(id: "a", name: "Default"), .init(id: "b", name: "My name")]
        AgentChatMarkers.applyGeneratedName(&markers, itemId: "a", name: " \nGenerated \n", replacing: "Default")
        XCTAssertEqual(markers[0].name, "Generated")
        let expected = markers
        AgentChatMarkers.applyGeneratedName(&markers, itemId: "b", name: "Generated", replacing: "Default")
        AgentChatMarkers.applyGeneratedName(&markers, itemId: "missing", name: "Generated", replacing: "Default")
        AgentChatMarkers.applyGeneratedName(&markers, itemId: "a", name: " \n", replacing: "Generated")
        AgentChatMarkers.applyGeneratedName(&markers, itemId: "a", name: "Generated", replacing: "Generated")
        XCTAssertEqual(markers, expected)
    }

    func testNamingInputUsesNearestUserMessageOnlyForReplies() throws {
        let items: [AgentChatItem] = [
            .init(id: "first", kind: .userMessage(text: "First question", images: [])),
            .init(id: "second", kind: .userMessage(text: "Latest question", images: [])),
            .init(id: "notice", kind: .notice(text: "Notice", level: .info)),
            .init(id: "reply", kind: .assistantText(text: "The answer", isStreaming: false)),
        ]
        let reply = try XCTUnwrap(AgentChatMarkers.namingInput(items: items, itemId: "reply"))
        XCTAssertEqual(reply.text, "The answer")
        XCTAssertEqual(reply.context, "Latest question")
        let user = try XCTUnwrap(AgentChatMarkers.namingInput(items: items, itemId: "second"))
        XCTAssertEqual(user.text, "Latest question")
        XCTAssertNil(user.context)
        XCTAssertNil(AgentChatMarkers.namingInput(items: items, itemId: "notice"))
        XCTAssertNil(AgentChatMarkers.namingInput(items: items, itemId: "missing"))
        XCTAssertNil(AgentChatMarkers.namingInput(items: [items[3]], itemId: "reply")?.context)
    }

    @MainActor func testConversationPublishesOnlyChangedGeneratedNames() {
        let chat = AgentConversation()
        chat.update(items: [.init(id: "reply", kind: .assistantText(text: "Reply", isStreaming: false))], status: .dormant)
        chat.toggleMarker(itemId: "reply", defaultName: "Default")
        var changes = 0
        let binding = chat.$markers.dropFirst().sink { _ in changes += 1 }
        defer { binding.cancel() }
        chat.applyGeneratedMarkerName(itemId: "reply", name: "Generated", replacing: "Default")
        XCTAssertEqual(chat.markers.first?.name, "Generated")
        chat.applyGeneratedMarkerName(itemId: "reply", name: "Other", replacing: "Default")
        XCTAssertEqual(changes, 1)
    }

    func testToggleAndOrder() {
        var markers: [AgentChatMarker] = []
        let ids = ["a", "b", "c"]
        XCTAssertEqual(AgentChatMarkers.toggle(&markers, itemId: "c", defaultName: "Third", itemIDs: ids)?.name, "Third")
        AgentChatMarkers.toggle(&markers, itemId: "a", defaultName: "First", itemIDs: ids)
        AgentChatMarkers.toggle(&markers, itemId: "b", defaultName: "Second", itemIDs: ids)
        XCTAssertEqual(markers.map(\.id), ids)
        XCTAssertNil(AgentChatMarkers.toggle(&markers, itemId: "b", defaultName: "Unused", itemIDs: ids))
        XCTAssertEqual(markers.map(\.id), ["a", "c"])
    }

    func testRename() {
        var markers = [AgentChatMarker(id: "a", name: "Old")]
        AgentChatMarkers.rename(&markers, itemId: "a", to: "  New\n")
        XCTAssertEqual(markers[0].name, "New")
        AgentChatMarkers.rename(&markers, itemId: "a", to: " \n ")
        XCTAssertEqual(markers[0].name, "New")
        AgentChatMarkers.rename(&markers, itemId: "missing", to: "No")
        XCTAssertEqual(markers.count, 1)
    }

    func testDefaultNames() {
        for text in ["## **A heading**", "> - __A heading__", "1. `A heading`", "* A heading", "+ A heading"] {
            XCTAssertEqual(AgentChatMarkers.defaultName(text: text, position: 1), "A heading")
        }
        XCTAssertEqual(AgentChatMarkers.defaultName(text: "```swift\nA    heading\nmore", position: 1), "A heading")
        XCTAssertEqual(AgentChatMarkers.defaultName(text: "I stopped the `main-live` stack, **twice**.", position: 1), "I stopped the main-live stack, twice.")
        XCTAssertEqual(AgentChatMarkers.defaultName(text: "These words make a marker name that is much longer than forty characters", position: 1), "These words make a marker name that is…")
        XCTAssertEqual(AgentChatMarkers.defaultName(text: " \n ", position: 3), AgentChatStrings.markerNumber(3))
        XCTAssertEqual(AgentChatMarkers.defaultName(text: String(repeating: "🐈", count: 41), position: 1), String(repeating: "🐈", count: 40) + "…")
    }

    func testStepsWithoutWrapAndSkipsClampedTarget() {
        let tops: [CGFloat] = [16, 124, 324, 950, 975]
        let targets: [CGFloat] = [0, 100, 300, 900, 900]
        func step(_ current: CGFloat, _ forward: Bool) -> Int? {
            AgentChatMarkerNavigation.step(tops: tops, targets: targets, current: current, anchor: current + 24, forward: forward)
        }
        XCTAssertEqual(step(0, true), 1)
        XCTAssertEqual(step(100, true), 2)
        XCTAssertEqual(step(300, false), 1)
        XCTAssertNil(step(0, false))
        XCTAssertNil(step(900, true))
        XCTAssertEqual(step(900, false), 2)
    }

    @MainActor func testRecordRoundTripAndRestoreDropsMissingItems() throws {
        let items = [AgentChatItem(id: "a", kind: .userMessage(text: "Hello", images: [])),
                     AgentChatItem(id: "b", kind: .assistantText(text: "Reply", isStreaming: false))]
        let markers = [AgentChatMarker(id: "b", name: "Answer"), .init(id: "gone", name: "Gone"), .init(id: "a", name: "Question")]
        let record = AgentChatRecord(title: "Chat", background: "#fff", drifter: .init(), items: items, markers: markers)
        let decoded = try JSONDecoder().decode(AgentChatRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.markers, markers)
        let chat = AgentConversation()
        chat.update(items: decoded.items, status: .dormant)
        chat.restoreMarkers(decoded.markers ?? [])
        XCTAssertEqual(chat.markers.map(\.id), ["a", "b"])
        XCTAssertEqual(chat.markers.map(\.name), ["Question", "Answer"])
        let legacy = AgentChatRecord(title: "Legacy", background: "#fff", drifter: .init())
        XCTAssertNil(try JSONDecoder().decode(AgentChatRecord.self, from: JSONEncoder().encode(legacy)).markers)
    }
}
