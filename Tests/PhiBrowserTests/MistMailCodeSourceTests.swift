import MistMailCore
import XCTest
@testable import Phi

final class MistMailCodeSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func code(_ value: String = "482913", age: TimeInterval = 0, senderDomain: String = "other.com") -> MistMailCode {
        MistMailCode(messageID: UUID(), code: value, sender: senderDomain, senderDomain: senderDomain,
                     date: now.addingTimeInterval(-age))
    }
    private func domain(_ url: String) -> String {
        URL(string: url)?.host?.split(separator: ".").suffix(2).joined(separator: ".") ?? ""
    }

    func testTenMinuteWindow() {
        let fresh = code(age: 599), boundary = code(age: 600), skewed = code(age: -300)
        let result = MistMailCodeSource.filter([code(age: 601), fresh, boundary, skewed, code(age: -301)], now: now,
            expectedLength: 0, pageDomain: "example.com", domain: domain)
        XCTAssertEqual(result, [skewed, fresh, boundary])
    }

    func testDomainMatchBeforeNewer() {
        let match = code(age: 300, senderDomain: "mail.example.com"), newer = code(age: 1)
        XCTAssertEqual(MistMailCodeSource.rank([newer, match], pageDomain: "example.com", domain: domain), [match, newer])
    }

    func testNewestFirstOtherwise() {
        let old = code(age: 100), new = code(age: 1)
        XCTAssertEqual(MistMailCodeSource.rank([old, new], pageDomain: "example.com", domain: domain), [new, old])
    }

    func testExpectedLength() {
        let short = code("1234"), long = code("AB123456", age: 1)
        XCTAssertEqual(MistMailCodeSource.filter([short, long], now: now, expectedLength: 8,
            pageDomain: "example.com", domain: domain), [long])
        for length in [0, 3, 9] {
            XCTAssertEqual(MistMailCodeSource.filter([short, long], now: now, expectedLength: length,
                pageDomain: "example.com", domain: domain), [short, long])
        }
    }

    @MainActor
    func testConsumeMovesTheMessageToTrashRead() async throws {
        let fixture = FixtureMailPageDataSource()
        let inbox = try await fixture.messages(in: .unifiedRole(.inbox), before: nil, limit: 50)
        let unread = try XCTUnwrap(inbox.first { !$0.flags.contains(MailFlags.seen) })
        await MistMailCodeSource(source: fixture).consume(MistMailCode(messageID: unread.id, code: "482913", sender: "Ada",
            senderDomain: "example.com", date: unread.date))
        let consumed = try await fixture.summary(unread.id)
        let trash = try await fixture.snapshot().mailboxes.first { $0.id == consumed.mailboxID }
        XCTAssertEqual(trash?.role, .trash)
        XCTAssertTrue(consumed.flags.contains(MailFlags.seen))
    }

    func testCapsAtThree() {
        let codes = (0..<5).map { code(age: Double($0)) }
        XCTAssertEqual(MistMailCodeSource.filter(codes.reversed(), now: now, expectedLength: 6,
            pageDomain: "example.com", domain: domain), Array(codes.prefix(3)))
    }
}
