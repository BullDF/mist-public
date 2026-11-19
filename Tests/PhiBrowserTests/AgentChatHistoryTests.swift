import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class AgentChatHistoryTests: XCTestCase {
    func testUnusedFreshChatsAreOmittedUntilTheyHaveItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        var record = AgentChatRecord(title: "Claude Code", background: "#000000",
            drifter: .init(folder: directory), items: [], queued: [], draft: "A draft")
        try write(record, id: id, route: route, modified: 100)
        let history = AgentChatHistory(route: route)
        XCTAssertTrue(history.chats().isEmpty)
        record.items = [.init(id: "user", kind: .userMessage(text: "Hello", images: []))]
        try write(record, id: id, route: route, modified: 101)
        XCTAssertEqual(history.chats().map(\.id), [id])
    }

    private func record(title: String, turnEnd: TimeInterval?,
                        folder: URL) -> AgentChatRecord {
        AgentChatRecord(title: title, background: "#000000", drifter: .init(folder: folder),
            items: [.init(id: "user", kind: .userMessage(text: title, images: []))]
                + (turnEnd.map { [.init(id: "end", kind: .turnEnd(durationMilliseconds: 1, finishedAt: Date(timeIntervalSince1970: $0)))] } ?? []),
            queued: [], draft: "")
    }

    private func write(_ record: AgentChatRecord, id: UUID, route: AgentChatRoute, modified: TimeInterval) throws {
        try FileManager.default.createDirectory(at: route.canonicalURL(for: id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try route.writeRecord(record, for: id)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                              ofItemAtPath: route.recordURL(for: id).path)
    }

    func testListsRestorableChatsByLastFinishedTurnAndFollowsFileChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory)
        let older = UUID(), browser = UUID(), unfinished = UUID(), unconfigured = UUID(), broken = UUID()
        try write(record(title: "Older", turnEnd: 200, folder: directory), id: older, route: route, modified: 900)
        try write(record(title: "Browser", turnEnd: 300, folder: directory), id: browser, route: route, modified: 900)
        // No finished turn: its record's last save counts.
        try write(record(title: "Unfinished", turnEnd: nil, folder: directory), id: unfinished, route: route, modified: 250)
        try FileManager.default.createDirectory(at: route.chatDirectory(for: unconfigured), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: route.recordURL(for: unconfigured))
        try FileManager.default.createDirectory(at: route.chatDirectory(for: broken), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: route.recordURL(for: broken))
        // A chat from before records were saved has only its page.
        try Data().write(to: route.placeholderURL(for: UUID()))

        let history = AgentChatHistory(route: route)
        XCTAssertEqual(history.chats(), [
            .init(id: browser, title: "Browser", lastLine: "Browser", engine: .claude, lastActivity: Date(timeIntervalSince1970: 300)),
            .init(id: unfinished, title: "Unfinished", lastLine: "Unfinished", engine: .claude, lastActivity: Date(timeIntervalSince1970: 250)),
            .init(id: older, title: "Older", lastLine: "Older", engine: .claude, lastActivity: Date(timeIntervalSince1970: 200)),
        ])

        try write(record(title: "Renamed", turnEnd: 500, folder: directory), id: older, route: route, modified: 950)
        try FileManager.default.removeItem(at: route.chatDirectory(for: browser))
        XCTAssertEqual(history.chats().map(\.title), ["Renamed", "Unfinished"])
    }

    func testMissingDirectoryListsNothing() {
        let route = AgentChatRoute(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(AgentChatHistory(route: route).chats(), [])
    }

    func testExclusionsKeepCachedRecordsAndRefreshWhenIncludedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = AgentChatRoute(baseDirectory: directory), id = UUID()
        var saved = record(title: "Old", turnEnd: 200, folder: directory)
        saved.drifter.engine = .codex
        saved.items.append(.init(id: "reply", kind: .assistantText(text: "First\n- **Last**", isStreaming: false)))
        try write(saved, id: id, route: route, modified: 300)
        let history = AgentChatHistory(route: route)
        XCTAssertTrue(history.chats(excluding: [id]).isEmpty)
        XCTAssertEqual(history.chats().first?.lastLine, "Last")
        XCTAssertEqual(history.chats().first?.engine, .codex)
        saved.title = "New"
        try write(saved, id: id, route: route, modified: 400)
        XCTAssertTrue(history.chats(excluding: [id]).isEmpty)
        XCTAssertEqual(history.chats().first?.title, "New")
    }
}
