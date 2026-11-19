import MistMailCore
import XCTest
@testable import Phi

@MainActor
final class MailSearchTests: XCTestCase {
    func testDebouncedSearchNarrowsAndClearRestoresListing() async throws {
        let model = MailPageModel(source: FixtureMailPageDataSource(), defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        XCTAssertEqual(model.messages.count, 200)
        model.setSearchQuery("not a match"); model.setSearchQuery("A message with images")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.messages.map(\.subject), ["A message with images"])
        let message = try XCTUnwrap(model.messages.first)
        model.selectMessage(message.id); XCTAssertEqual(model.selection, message.id)
        model.clearSearch()
        for _ in 0..<100 where model.messages.count != 200 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.messages.count, 200); XCTAssertFalse(model.isSearching)
    }
    func testSearchScopesServerSearchAndPaging() async throws {
        let source = FixtureMailPageDataSource(), model = MailPageModel(source: source, defaults: makeTestDefaults().defaults)
        await model.reloadState(); await model.reloadMessages()
        model.setSearchQuery("ADA"); await model.reloadMessages()
        XCTAssertFalse(model.messages.isEmpty)
        model.loadMore()
        XCTAssertFalse(model.loading); XCTAssertEqual(source.loadOlderCalls, 0)
        await model.searchServer()
        XCTAssertEqual(Set(source.serverSearches), Set(model.mailboxIDs)); XCTAssertFalse(model.searchingServer)
        let sent = try XCTUnwrap(model.state.mailboxes.first { $0.role == .sent })
        model.selectMailbox(sent.id.uuidString)
        XCTAssertEqual(model.searchQuery, "")
        await model.reloadMessages()
        XCTAssertTrue(model.messages.allSatisfy { $0.mailboxID == sent.id })
        model.setSearchQuery("zzzz-no-results"); await model.reloadMessages()
        XCTAssertTrue(model.messages.isEmpty)
    }
    func testFixtureSearchMatchesSnippetAndCapsResults() async throws {
        let source = FixtureMailPageDataSource(), state = try await source.snapshot()
        let ids = state.mailboxes.filter { $0.role == .inbox }.map(\.id)
        let hits = try await source.search("NOTES", in: ids)
        XCTAssertEqual(hits.count, 200)
        XCTAssertTrue(zip(hits, hits.dropFirst()).allSatisfy { $0.date >= $1.date })
        let sent = state.mailboxes.filter { $0.role == .sent }.map(\.id)
        let scoped = try await source.search("Meeting", in: sent)
        XCTAssertEqual(scoped.count, 2); XCTAssertTrue(scoped.allSatisfy { sent.contains($0.mailboxID) })
    }
}
