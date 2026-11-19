import Foundation
import XCTest
#if !MIST_CLAUDE_CODE_HOSTLESS_TESTS
@testable import Phi
#endif

final class DrifterHomeListTests: XCTestCase {
    func testStatusMapping() {
        for status in [AgentConversationStatus.starting, .running] { XCTAssertEqual(DrifterHomeStatus(status), .working) }
        XCTAssertEqual(DrifterHomeStatus(.awaitingPermission), .needsYou)
        for status in [AgentConversationStatus.idle, .dormant, .ended] { XCTAssertEqual(DrifterHomeStatus(status), .idle) }
        XCTAssertEqual(DrifterHomeStatus(.failed("Oops")), .failed)
        XCTAssertEqual(DrifterHomeStatus(.idle, hasBackgroundTasks: true), .background)
        XCTAssertEqual(DrifterHomeStatus(.running, hasBackgroundTasks: true), .working)
        XCTAssertEqual(DrifterHomeStatus(.awaitingPermission, hasBackgroundTasks: true), .needsYou)
        XCTAssertEqual(DrifterHomeStatus(.failed("Oops"), hasBackgroundTasks: true), .failed)
        for status in [AgentConversationStatus.idle, .dormant, .ended] {
            XCTAssertEqual(DrifterHomeStatus(status, hasBackgroundTasks: true, waitsForUser: true), .needsYou)
        }
        XCTAssertEqual(DrifterHomeStatus(.running, waitsForUser: true), .working)
        XCTAssertEqual(DrifterHomeStatus(.failed("Oops"), waitsForUser: true), .failed)
    }

    private func row(_ index: Int, date: TimeInterval) -> DrifterHomeChat {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
              title: "Chat \(index)", lastLine: nil, status: .idle, engine: .claude,
              time: Date(timeIntervalSince1970: date), sortDate: Date(timeIntervalSince1970: date))
    }

    func testFamiliesFlattenDepthFirstWithNewestSiblingsFirstAndOrphansAtTop() {
        let root = row(1, date: 30), child = row(2, date: 20), grandchild = row(3, date: 40)
        let sibling = row(4, date: 10), orphan = row(5, date: 50)
        let result = DrifterHomeList.ongoing([child, orphan, sibling, root, grandchild], parent: [
            child.id: root.id, grandchild.id: child.id, sibling.id: root.id, orphan.id: UUID(),
        ])
        XCTAssertEqual(result.map(\.id), [orphan.id, root.id])
        XCTAssertEqual(result[1].children.map(\.id), [child.id, grandchild.id, sibling.id])
        XCTAssertTrue(result[1].children.allSatisfy { $0.children.isEmpty })
        XCTAssertEqual(DrifterHomeList.ongoing([row(1, date: 1), row(2, date: 1)], parent: [:]).map(\.id), [row(2, date: 1).id, row(1, date: 1).id])
    }

    func testArrangementTracksMembershipOrderAndNestingButNotContent() {
        let root = row(1, date: 30), child = row(2, date: 20), sibling = row(3, date: 15), other = row(4, date: 10)
        let parent = [child.id: root.id, sibling.id: root.id]
        let rows = DrifterHomeList.ongoing([root, child, sibling, other], parent: parent)
        let arrangement = DrifterHomeList.arrangement(rows)
        XCTAssertEqual(arrangement, [[root.id, child.id, sibling.id], [other.id]])
        func updated(_ chat: DrifterHomeChat, date: TimeInterval) -> DrifterHomeChat {
            .init(id: chat.id, title: "Renamed", lastLine: "New line", status: .working, engine: .codex,
                  time: Date(timeIntervalSince1970: date), sortDate: Date(timeIntervalSince1970: date))
        }
        // A chat updating in place keeps the arrangement, so streaming never animates.
        let inPlace = DrifterHomeList.ongoing([root, child, sibling, updated(other, date: 10)], parent: parent)
        XCTAssertNotEqual(inPlace, rows)
        XCTAssertEqual(DrifterHomeList.arrangement(inPlace), arrangement)
        // A chat starting a turn moves to the top; so does a child among its siblings.
        let moved = DrifterHomeList.ongoing([root, child, sibling, updated(other, date: 40)], parent: parent)
        XCTAssertEqual(DrifterHomeList.arrangement(moved), [[other.id], [root.id, child.id, sibling.id]])
        let childMoved = DrifterHomeList.ongoing([root, child, updated(sibling, date: 40), other], parent: parent)
        XCTAssertEqual(DrifterHomeList.arrangement(childMoved), [[root.id, sibling.id, child.id], [other.id]])
        // Membership and nesting changes count too, even when the flattened order stays the same.
        XCTAssertEqual(DrifterHomeList.arrangement(DrifterHomeList.ongoing([root, sibling, other], parent: parent)),
                       [[root.id, sibling.id], [other.id]])
        XCTAssertEqual(DrifterHomeList.arrangement(DrifterHomeList.ongoing([root, child, sibling, other], parent: [child.id: root.id])),
                       [[root.id, child.id], [sibling.id], [other.id]])
    }

    func testMalformedCycleDoesNotLoseChats() {
        let a = row(1, date: 1), b = row(2, date: 2)
        let result = DrifterHomeList.ongoing([a, b], parent: [a.id: b.id, b.id: a.id])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, b.id)
        XCTAssertEqual(result[0].children.map(\.id), [a.id])
    }

    func testHistoryFilterAndPagingPreserveInputOrder() {
        let chats = (0..<25).map { index in
            AgentChatHistory.Chat(id: UUID(), title: index == 0 ? "CAFÉ" : "Chat \(index)", lastLine: nil,
                                  engine: .codex, lastActivity: Date(timeIntervalSince1970: Double(25 - index)))
        }
        let first = DrifterHomeList.history(chats, query: " \n", limit: DrifterHomeList.historyPageSize)
        XCTAssertEqual(first.rows, Array(chats.prefix(20)))
        XCTAssertTrue(first.hasMore)
        let all = DrifterHomeList.history(chats, query: "", limit: 40)
        XCTAssertEqual(all.rows, chats)
        XCTAssertFalse(all.hasMore)
        XCTAssertEqual(DrifterHomeList.history(chats, query: " cafe ", limit: 20).rows, [chats[0]])
        XCTAssertTrue(DrifterHomeList.history(chats, query: "missing", limit: 20).rows.isEmpty)
    }

    func testLastLineSkipsBlankAndNonMessageItemsAndStripsMarkdown() {
        func message(_ text: String) -> AgentChatItem { .init(id: UUID().uuidString, kind: .assistantText(text: text, isStreaming: false)) }
        for prefix in ["### ", "> ", "- ", "* ", "+ ", "12. "] {
            XCTAssertEqual(AgentChatTranscriptText.lastLine([message("First\n\(prefix)**Last** __line__ `code`\n \n")]), "Last line code")
        }
        let user = AgentChatItem(id: "user", kind: .userMessage(text: " User \n", images: []))
        let peer = AgentChatItem(id: "peer", kind: .peerMessage(name: "Friend", body: " Peer "))
        XCTAssertEqual(AgentChatTranscriptText.lastLine([user, message(" \n"), .init(id: "notice", kind: .notice(text: "Ignore", level: .info))]), "User")
        XCTAssertEqual(AgentChatTranscriptText.lastLine([user, peer]), "Peer")
        XCTAssertEqual(AgentChatTranscriptText.lastLine([message("Opened [example.com](https://example.com/) in a [tab]().")]),
                       "Opened example.com in a tab.")
        XCTAssertEqual(AgentChatTranscriptText.lastLine([message(String(repeating: "🙂", count: 400))])?.count, 300)
        XCTAssertNil(AgentChatTranscriptText.lastLine([message(" \n")]))
        XCTAssertNil(AgentChatTranscriptText.lastLine([]))
    }

    func testTimeLabelUsesLocalizedCalendarBranches() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let locale = Locale(identifier: "en_US")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 15))!
        }
        let now = date(2026, 11, 8)
        let format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        XCTAssertEqual(DrifterHomeList.timeLabel(now, now: now, calendar: calendar, locale: locale), now.formatted(format.hour().minute()))
        let earlier = date(2026, 2, 3), old = date(2025, 2, 3)
        XCTAssertEqual(DrifterHomeList.timeLabel(earlier, now: now, calendar: calendar, locale: locale), earlier.formatted(format.month(.abbreviated).day()))
        XCTAssertEqual(DrifterHomeList.timeLabel(old, now: now, calendar: calendar, locale: locale), old.formatted(format.month(.abbreviated).day().year()))
        XCTAssertFalse(DrifterHomeList.timeLabel(earlier, now: now, calendar: calendar, locale: locale).contains("2026"))
        XCTAssertTrue(DrifterHomeList.timeLabel(old, now: now, calendar: calendar, locale: locale).contains("2025"))
    }
}
