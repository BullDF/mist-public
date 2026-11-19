import XCTest
@testable import Phi

final class MistPasswordCSVTests: XCTestCase {
    func testExportRoundTrip() throws {
        let logins = [
            MistLogin(site: "https://example.com", username: "a,b", password: "one, two"),
            MistLogin(site: "http://example.org", username: "a\"\"b", password: "\"quoted\"\"password\""),
            MistLogin(site: "https://example.com:8443", username: "a\r\nb", password: "one\r\ntwo"),
            MistLogin(site: "https://example.net", username: "a\nb", password: "one\ntwo"),
            MistLogin(site: "https://example.edu", username: "", password: "=unchanged\rvalue")
        ]
        let parsed = try MistPasswordCSV.logins(MistPasswordCSV.export(logins))
        let expected = logins.sorted { ($0.host, $0.username) < ($1.host, $1.username) }
        XCTAssertEqual(parsed.skipped, 0)
        XCTAssertEqual(parsed.logins.map(\.site), expected.map(\.site))
        XCTAssertEqual(parsed.logins.map(\.username), expected.map(\.username))
        XCTAssertEqual(parsed.logins.map(\.password), expected.map(\.password))
    }

    func testExportExactOutput() {
        let logins = [
            MistLogin(site: "https://example.com", username: "z", password: "plain"),
            MistLogin(site: "http://example.com:8080", username: "a,b", password: "one\"two\r\nthree")
        ]
        XCTAssertEqual(MistPasswordCSV.export(logins),
                       "name,url,username,password,note\r\n"
                       + "example.com,http://example.com:8080,\"a,b\",\"one\"\"two\r\nthree\",\r\n"
                       + "example.com,https://example.com,z,plain,\r\n")
    }

    func testQuotedCommasNewlinesAndDoubledQuotes() throws {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\r\n\"A, B\",https://example.com,\"a\"\"b\",\"one\r\ntwo\",,\r\n"
        let rows = try MistPasswordCSV.parse(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["A, B", "https://example.com", "a\"b", "one\r\ntwo", "", ""])
        let parsed = try MistPasswordCSV.logins(csv)
        XCTAssertEqual(parsed.logins.count, 1)
        XCTAssertEqual(parsed.logins[0].password, "one\r\ntwo")
    }

    func testBothFormatsBOMCaseInsensitiveAndMissingValues() throws {
        let apple = try MistPasswordCSV.logins("\u{feff}Title,URL,Username,Password,Notes,OTPAuth\nA,https://example.com,a,p,,")
        XCTAssertEqual(apple.logins.count, 1)
        let chrome = try MistPasswordCSV.logins("name,uRl,USERNAME,password,note\nA,https://example.com,a,p,\nB,,a,p,\nC,https://example.com,a,,\nD,https://example.com\n")
        XCTAssertEqual(chrome.logins.count, 1)
        XCTAssertEqual(chrome.skipped, 3)
        XCTAssertThrowsError(try MistPasswordCSV.logins("url,username\nhttps://example.com,a"))
        XCTAssertThrowsError(try MistPasswordCSV.logins("name,url,password\na,https://example.com,p"))
        XCTAssertThrowsError(try MistPasswordCSV.parse("a,\"unfinished"))
        XCTAssertThrowsError(try MistPasswordCSV.parse("\"closed\"garbage,b"))
        XCTAssertEqual(try MistPasswordCSV.parse("\"\""), [[""]])
    }

    func testImportDedupeUpdateAndDowngradeRefusal() throws {
        let original = MistLogin(site: "https://example.com", username: "alice", password: "old")
        var existing = [original]
        let incoming = [MistLogin(site: "https://login.example.com", username: "alice", password: "new"),
                        MistLogin(site: "https://example.com", username: "bob", password: "fixture"),
                        MistLogin(site: "https://example.com", username: "bob", password: "fixture"),
                        MistLogin(site: "http://example.com", username: "alice", password: "insecure")]
        let counts = MistPasswordCSV.merge(incoming, into: &existing, domain: { _ in "example.com" })
        XCTAssertEqual(counts, MistPasswordCSV.Counts(imported: 1, updated: 1, skipped: 2))
        XCTAssertEqual(existing.count, 2)
        XCTAssertEqual(existing[0].id, original.id)
        XCTAssertEqual(existing[0].password, "new")
        XCTAssertTrue(existing[0].site.hasPrefix("https:"))
    }
}
